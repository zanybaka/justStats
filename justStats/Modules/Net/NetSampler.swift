import Combine
import Foundation

/// Fixed-capacity FIFO: appending past capacity drops the oldest element.
struct RingBuffer<Element: Equatable>: Equatable {
    let capacity: Int
    private(set) var elements: [Element] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity { elements.removeFirst(elements.count - capacity) }
    }

    mutating func removeAll() { elements.removeAll() }
}

/// A repeating tick source. The real one is a main-run-loop `Timer`; tests substitute
/// one they fire by hand, so "nothing is scheduled until start()" is assertable.
protocol NetTickScheduling {
    /// Schedules `handler` every `interval` seconds on the main thread. Cancelling the
    /// returned token stops it.
    func schedule(interval: TimeInterval, handler: @escaping @MainActor () -> Void) -> AnyCancellable
}

struct TimerNetTickScheduler: NetTickScheduling {
    func schedule(interval: TimeInterval, handler: @escaping @MainActor () -> Void) -> AnyCancellable {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { handler() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        return AnyCancellable { timer.invalidate() }
    }
}

/// Lifecycle surface the popover coordinator drives (NET-002): started on open, stopped
/// on close. A protocol so the coordinator test uses a spy.
@MainActor
protocol NetworkSampling: AnyObject {
    func start()
    func stop()
}

/// Live throughput sampler (NET-001). Created idle: no timer exists until `start()`, and
/// `stop()` removes it, so nothing network-related runs at launch or while the popover
/// is closed (owner decision 2026-11-21; the net module keeps ADR-002's two-tier shape
/// with sampler-on-open as its only live tier).
@MainActor
final class NetSampler: ObservableObject, NetworkSampling {
    static let ringCapacity = 180
    static let interval: TimeInterval = 1.0

    /// One point of the chart.
    struct Sample: Equatable {
        let rate: NetRate
    }

    /// The last `ringCapacity` real samples, oldest first. Empty until the first tick
    /// after `start()` — never zero-filled history.
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var latest: NetRate?
    @Published private(set) var totals: NetTotals = .zero
    @Published private(set) var interfaces: [InterfaceRate] = []
    /// True once the user pressed Reset: the totals label then reads "Since reset".
    @Published private(set) var totalsWereReset = false

    private let source: NetCounterSource
    private let scheduler: NetTickScheduling
    private let uptime: () -> TimeInterval
    private var engine = NetThroughputEngine()
    private var ring = RingBuffer<Sample>(capacity: NetSampler.ringCapacity)
    private var tick: AnyCancellable?
    private var lastReadUptime: TimeInterval?

    var isRunning: Bool { tick != nil }

    init(
        source: NetCounterSource = SysctlNetCounterSource(),
        scheduler: NetTickScheduling = TimerNetTickScheduler(),
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.source = source
        self.scheduler = scheduler
        self.uptime = uptime
    }

    func start() {
        guard tick == nil else { return }
        // Baseline read: gives since-boot totals immediately; the first rate needs a second read.
        read()
        tick = scheduler.schedule(interval: Self.interval) { [weak self] in self?.read() }
    }

    func stop() {
        tick?.cancel()
        tick = nil
        lastReadUptime = nil
        // History from a previous open would show a stale chart with a gap in it.
        ring.removeAll()
        samples = []
        latest = nil
        // Forget previous counters so the next start() re-baselines instead of computing
        // one rate over the whole closed interval.
        engine.forgetPrevious()
    }

    /// "Reset" next to the since-boot totals.
    func resetTotals() {
        engine.resetTotals()
        totals = engine.totals
        totalsWereReset = true
    }

    private func read() {
        let now = uptime()
        let elapsed = lastReadUptime.map { now - $0 } ?? 0
        lastReadUptime = now
        let reading = engine.ingest(source.readCounters(), elapsed: elapsed)
        interfaces = reading.interfaces
        totals = reading.totals
        if let rate = reading.physicalRate {
            let sample = Sample(rate: rate)
            ring.append(sample)
            samples = ring.elements
            latest = rate
        }
    }
}
