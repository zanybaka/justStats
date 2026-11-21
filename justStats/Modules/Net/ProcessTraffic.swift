import AppKit
import Foundation

/// A process's rate between two consecutive nettop passes.
struct ProcessRate: Equatable, Identifiable {
    var id: String { key }
    let key: String
    let displayName: String
    let down: Double
    let up: Double
}

/// Ranking and truncation of process rates (NET-004).
enum ProcessRanking {
    static let defaultLimit = 5

    /// Sorted by `max(down, up)` descending (ties by name, so the order is stable),
    /// processes with no traffic dropped, truncated to `limit`.
    static func top(_ rates: [ProcessRate], limit: Int = defaultLimit) -> [ProcessRate] {
        rates
            .filter { $0.down > 0 || $0.up > 0 }
            .sorted {
                let lhs = max($0.down, $0.up), rhs = max($1.down, $1.up)
                return lhs != rhs ? lhs > rhs : $0.displayName < $1.displayName
            }
            .prefix(max(limit, 0))
            .map { $0 }
    }
}

/// Runs one `nettop` pass and returns its CSV. A protocol so lifecycle tests use a spy.
protocol NettopRunning {
    /// Throws on a missing binary, a failure, a timeout, or cancellation (which also
    /// terminates the process).
    func run() async throws -> String
}

enum NettopError: Error {
    case unavailable
    case timedOut
    case failed
}

/// Spawns `/usr/bin/nettop -P -L 1 -n -k …` with `NSUnbufferedIO=YES` and a 5 s timeout.
/// The process lives only for the duration of one `run()`: task cancellation (collapse or
/// popover close) terminates it immediately.
struct NettopProcessRunner: NettopRunning {
    static let executable = "/usr/bin/nettop"
    static let timeoutSeconds: TimeInterval = 5
    /// Columns excluded to keep the output small; only the process name and byte counters stay.
    static let excludedColumns = "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch"
    static let arguments = ["-P", "-L", "1", "-n", "-k", excludedColumns]

    func run() async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else { throw NettopError.unavailable }
        let invocation = NettopInvocation()
        return try await withTaskCancellationHandler {
            try await invocation.start()
        } onCancel: {
            invocation.terminate(reason: CancellationError())
        }
    }
}

/// One nettop process and the continuation waiting on it; resumes exactly once.
private final class NettopInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    private var cancelled = false

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()

            process.executableURL = URL(fileURLWithPath: NettopProcessRunner.executable)
            process.arguments = NettopProcessRunner.arguments
            var environment = ProcessInfo.processInfo.environment
            environment["NSUnbufferedIO"] = "YES"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                finish(.failure(NettopError.unavailable))
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + NettopProcessRunner.timeoutSeconds) { [self] in
                terminate(reason: NettopError.timedOut)
            }
            DispatchQueue.global(qos: .utility).async { [self] in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    finish(.success(String(decoding: data, as: UTF8.self)))
                } else {
                    finish(.failure(NettopError.failed))
                }
            }
        }
    }

    func terminate(reason: Error) {
        lock.lock()
        cancelled = cancelled || reason is CancellationError
        let running = process.isRunning && !finished
        lock.unlock()
        if running { process.terminate() }
        finish(.failure(reason))
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

/// Polls nettop only while the network section is expanded and the popover is open
/// (NET-004). `start()` / `stop()` are driven by the section view model; `stop()`
/// cancels the loop, which terminates the running process. A nettop failure shows one
/// muted notice and is retried on the next interval, silently.
@MainActor
final class ProcessTrafficModel: ObservableObject {
    enum State: Equatable {
        case idle
        /// Passes so far cannot yet give a rate (need two).
        case measuring
        case ready([ProcessRate])
        case unavailable
    }

    static let interval: TimeInterval = 4

    @Published private(set) var state: State = .idle

    private let runner: NettopRunning
    private let resolveName: (Int32) -> String?
    private let uptime: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private let limit: Int
    private var task: Task<Void, Never>?
    private var previous: [String: ProcessTraffic] = [:]
    private var previousUptime: TimeInterval?

    var isRunning: Bool { task != nil }

    init(
        runner: NettopRunning = NettopProcessRunner(),
        resolveName: @escaping (Int32) -> String? = { NSRunningApplication(processIdentifier: $0)?.localizedName },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        limit: Int = ProcessRanking.defaultLimit
    ) {
        self.runner = runner
        self.resolveName = resolveName
        self.uptime = uptime
        self.sleep = sleep
        self.limit = limit
    }

    func start() {
        guard task == nil else { return }
        state = .measuring
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pass()
                if Task.isCancelled { return }
                try? await self.sleep(Self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        previous = [:]
        previousUptime = nil
        state = .idle
    }

    /// One run + publish. Internal so tests can step it without the loop.
    func pass() async {
        let output: String
        do {
            output = try await runner.run()
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { fail() }
            return
        }
        if Task.isCancelled { return }
        guard let rows = NettopParser.parse(output) else {
            fail()
            return
        }
        let now = uptime()
        defer {
            previous = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
            previousUptime = now
        }
        guard let before = previousUptime, now > before, !previous.isEmpty else {
            state = .measuring
            return
        }
        let elapsed = now - before
        let rates = rows.compactMap { row -> ProcessRate? in
            guard let old = previous[row.key] else { return nil }
            return ProcessRate(
                key: row.key,
                displayName: resolveName(row.pid) ?? row.name,
                down: NetThroughputEngine.rate(from: old.bytesIn, to: row.bytesIn, baudrate: 0, elapsed: elapsed),
                up: NetThroughputEngine.rate(from: old.bytesOut, to: row.bytesOut, baudrate: 0, elapsed: elapsed)
            )
        }
        state = .ready(ProcessRanking.top(rates, limit: limit))
    }

    private func fail() {
        previous = [:]
        previousUptime = nil
        state = .unavailable
    }
}

/// What the "Top processes" block draws (NET-004), pure for tests.
struct ProcessesContent: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let name: String
        let downText: String
        let upText: String
    }

    static let notice = "Per-app traffic is unavailable right now"
    static let measuringText = "Measuring…"
    static let emptyText = "No app traffic in the last few seconds"

    enum Body: Equatable {
        case hidden
        case measuring
        case empty
        case rows([Row])
        /// Single muted line replacing the block; retried on the next interval.
        case notice(String)
    }

    let body: Body

    init(state: ProcessTrafficModel.State) {
        switch state {
        case .idle: body = .hidden
        case .measuring: body = .measuring
        case .unavailable: body = .notice(Self.notice)
        case .ready(let rates):
            body = rates.isEmpty ? .empty : .rows(rates.map {
                Row(
                    id: $0.id, name: $0.displayName,
                    downText: RateFormat.text(bytesPerSecond: $0.down),
                    upText: RateFormat.text(bytesPerSecond: $0.up)
                )
            })
        }
    }
}
