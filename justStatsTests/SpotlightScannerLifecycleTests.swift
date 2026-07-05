import XCTest
@testable import justStats

/// SCAN-007: lifecycle/memory coverage for the real Spotlight scanners
/// (`SpotlightCategoryScanner`, `SpotlightLargestFilesScanner`). The other Phase 3
/// tests exercise the pure model/aggregation logic through the mock seams; these drive
/// the *real* scanner objects — generation bookkeeping, `NSMetadataQuery` start/stop,
/// and `NSMetadataQueryDidFinishGathering` observer registration/removal — to prove
/// nothing accumulates or leaks across open/refresh/close cycles.
///
/// No real Spotlight index is touched. Two injected seams keep it hermetic:
/// - `StubRunLoopExecutor` replaces the dedicated run-loop thread, running `perform`
///   blocks synchronously on a private off-main serial queue (so the scanners'
///   `dispatchPrecondition(.notOnQueue(.main))` holds and `start()`/`stop()` run where
///   production runs them).
/// - `makeQuery` builds `CountingMetadataQuery` instances the test retains, so it can
///   count `start()`/`stop()` per query and post the "finished gathering" notification
///   with the exact query object each observer is scoped to.
final class SpotlightScannerLifecycleTests: XCTestCase {
    private func volumeURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Test doubles

    /// An `NSMetadataQuery` that counts `start()`/`stop()` and never queries Spotlight.
    /// `resultCount` stays 0, so the scanners take their "no items matched → unavailable"
    /// path — enough to drive a full scan→deliver cycle. Registered with the factory so
    /// the test holds every query the scanner created and can assert each was stopped.
    final class CountingMetadataQuery: NSMetadataQuery, @unchecked Sendable {
        private let lock = NSLock()
        private var _startCount = 0
        private var _stopCount = 0

        var startCount: Int { lock.withLock { _startCount } }
        var stopCount: Int { lock.withLock { _stopCount } }

        override func start() -> Bool {
            lock.withLock { _startCount += 1 }
            return true
        }

        override func stop() {
            lock.withLock { _stopCount += 1 }
        }

        // Never started against Spotlight, so there are never any results.
        override var resultCount: Int { 0 }
    }

    /// Synchronous `MetadataQueryRunLoopExecuting` stub: runs `perform` blocks inline on
    /// a private serial queue (off the main thread, like the real run-loop thread) so
    /// the scanners' `.notOnQueue(.main)` preconditions hold and query start/stop calls
    /// happen where production runs them. Counts `stop()` for idempotence assertions.
    final class StubRunLoopExecutor: MetadataQueryRunLoopExecuting, @unchecked Sendable {
        // High QoS so the executor's serial queue isn't starved under a saturated
        // parallel test runner — keeps the query start/stop hops prompt.
        private let queue = DispatchQueue(label: "test.metadata-runloop-stub", qos: .userInitiated)
        private let lock = NSLock()
        private var _stopCount = 0

        var stopCount: Int { lock.withLock { _stopCount } }

        func perform(_ block: @escaping () -> Void) {
            queue.sync(execute: block)
        }

        func stop() {
            lock.withLock { _stopCount += 1 }
        }

        /// Flushes any queued `perform` blocks so the test can assert after teardown.
        func drain() {
            queue.sync {}
        }
    }

    /// Retains every `CountingMetadataQuery` a scanner builds and posts the finish
    /// notification with the correct query object. Thread-safe: the scanner builds
    /// queries on its state queue.
    final class QueryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var queries: [CountingMetadataQuery] = []

        func make() -> NSMetadataQuery {
            let query = CountingMetadataQuery()
            lock.withLock { queries.append(query) }
            return query
        }

        var all: [CountingMetadataQuery] { lock.withLock { queries } }

        /// Posts `NSMetadataQueryDidFinishGathering` for every query recorded so far,
        /// off the main thread — exactly what the real run loop does when Spotlight
        /// finishes. Each observer is scoped to its own query object, so the object must
        /// match; a nil-object broadcast would reach none of them.
        func postFinishGatheringOffMain() {
            let snapshot = all
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                for query in snapshot {
                    NotificationCenter.default.post(
                        name: .NSMetadataQueryDidFinishGathering,
                        object: query
                    )
                }
                done.signal()
            }
            done.wait()
        }
    }

    // MARK: - Category scanner lifecycle

    /// Many scan→finish cycles must each start and then stop their queries, with no
    /// query left running after delivery. Every started `NSMetadataQuery` must have been
    /// stopped at least once (finish path + teardown), and each cycle must deliver — a
    /// leaked scan would have kept `current` populated and stalled a later cycle.
    func testCategoryScannerStartsAndStopsEveryQueryAcrossCycles() {
        let executor = StubRunLoopExecutor()
        let recorder = QueryRecorder()
        let deliverQueue = DispatchQueue(label: "test.category-deliver")
        let scanner = SpotlightCategoryScanner(
            runLoopThread: executor,
            deliverQueue: deliverQueue,
            makeQuery: recorder.make
        )

        let cycles = 20
        let perCycle = FileCategory.allCases.count
        for cycle in 1...cycles {
            var deliveredBreakdown: CategoryBreakdown?
            scanner.scan(volumeURL: volumeURL("/")) { breakdown in
                deliveredBreakdown = breakdown
            }
            // Drain the state queue so this cycle's queries are created and started
            // before we signal "finished" — deterministic, no polling.
            scanner.settleForTesting()
            XCTAssertEqual(recorder.all.count, cycle * perCycle)
            // Posting finish runs every observer synchronously (each stops its query and
            // enqueues a state-queue follow-up); draining the state queue then the deliver
            // queue runs the aggregation and the delivery closure to completion. No async
            // hop is left pending, so the result is in hand without a wall-clock wait.
            recorder.postFinishGatheringOffMain()
            scanner.settleForTesting()
            deliverQueue.sync {}
            XCTAssertNotNil(deliveredBreakdown, "cycle \(cycle) must deliver")
            XCTAssertFalse(deliveredBreakdown?.isIndexAvailable ?? true,
                           "zero results → unavailable")
        }

        // Idempotent extra teardown must be a safe no-op.
        scanner.cancel()
        scanner.settleForTesting()
        deliverQueue.sync {}
        executor.drain()

        // One query per category per cycle, each started exactly once and stopped. Every
        // stop has already run synchronously (finish path + teardown, both drained above),
        // so the counters are settled — assert directly, no spin.
        let queries = recorder.all
        XCTAssertEqual(queries.count, cycles * perCycle)
        for query in queries {
            XCTAssertEqual(query.startCount, 1, "each query starts exactly once")
            XCTAssertGreaterThanOrEqual(query.stopCount, 1, "each started query is stopped")
        }
    }

    /// Cancelling an in-flight category scan stops its queries and drops the pending
    /// delivery — repeated across cycles, nothing is delivered and every query the scan
    /// built is still stopped (teardown ran).
    func testCategoryScannerCancelDropsDeliveryAndStopsQueriesEachCycle() {
        let executor = StubRunLoopExecutor()
        let recorder = QueryRecorder()
        let deliverQueue = DispatchQueue(label: "test.category-deliver-cancel")
        let scanner = SpotlightCategoryScanner(
            runLoopThread: executor,
            deliverQueue: deliverQueue,
            makeQuery: recorder.make
        )

        let cycles = 20
        let perCycle = FileCategory.allCases.count
        for cycle in 1...cycles {
            let delivered = LockedBox(false)
            scanner.scan(volumeURL: volumeURL("/")) { _ in delivered.set(true) }
            // Drain so this cycle's queries exist before cancelling — deterministic
            // teardown rather than racing query creation.
            scanner.settleForTesting()
            XCTAssertEqual(recorder.all.count, cycle * perCycle)
            scanner.cancel()
            // Drain the cancel (bumps the generation, tears down every query and removes
            // its observer) before the late notification.
            scanner.settleForTesting()
            // A late "finished" notification must not resurrect the cancelled scan: its
            // observers were removed by teardown, and any stale delivery is generation-
            // gated. Drain both queues to prove no delivery slips through.
            recorder.postFinishGatheringOffMain()
            scanner.settleForTesting()
            deliverQueue.sync {}
            XCTAssertFalse(delivered.get(), "a cancelled scan must never deliver")
        }

        executor.drain()
        // Every query's teardown ran synchronously above, so stop counts are settled.
        let queries = recorder.all
        XCTAssertEqual(queries.count, cycles * perCycle)
        for query in queries {
            XCTAssertGreaterThanOrEqual(query.stopCount, 1, "a cancelled scan stops its queries")
        }
    }

    /// Starting new scans while others are in flight supersedes the old ones: only the
    /// newest delivers, and superseded scans' queries are torn down. Run in a tight
    /// loop, this proves generations don't pile up.
    func testCategoryScannerSupersedesInFlightScans() {
        let executor = StubRunLoopExecutor()
        let recorder = QueryRecorder()
        let deliverQueue = DispatchQueue(label: "test.category-deliver-supersede")
        let scanner = SpotlightCategoryScanner(
            runLoopThread: executor,
            deliverQueue: deliverQueue,
            makeQuery: recorder.make
        )

        let deliveryCount = LockedBox(0)

        let scans = 10
        let perScan = FileCategory.allCases.count
        for _ in 0..<scans {
            scanner.scan(volumeURL: volumeURL("/")) { _ in
                deliveryCount.set(deliveryCount.get() + 1)
            }
        }
        // Drain so all ten scans are processed (each supersedes the prior, tearing its
        // queries down) and every query exists before we signal "finished". Only the
        // final generation's observers are still registered.
        scanner.settleForTesting()
        XCTAssertEqual(recorder.all.count, scans * perScan)
        recorder.postFinishGatheringOffMain()
        scanner.settleForTesting()
        deliverQueue.sync {}

        // Ten scans × three categories all built; every one stopped (nine superseded
        // scans torn down + the final one completing).
        let queries = recorder.all
        XCTAssertEqual(queries.count, scans * perScan)
        for query in queries {
            XCTAssertGreaterThanOrEqual(query.stopCount, 1)
        }
        XCTAssertEqual(deliveryCount.get(), 1, "only the final scan delivers, exactly once")
    }

    // MARK: - Largest-files scanner lifecycle

    /// The largest-files scanner has the same on-demand lifecycle: many scan→finish
    /// cycles each start and stop their single query, unavailable each time (zero
    /// matches), no accumulation.
    ///
    /// A single-floor cascade (`floors: [0]`) is injected so each cycle runs exactly one
    /// query — the lifecycle invariant under test. The multi-floor descent itself is
    /// covered separately by `testLargestFilesCascadeDescendsAndStopsEveryFloorQuery` and
    /// the pure `LargestFilesCascadeTests`.
    func testLargestFilesScannerStartsAndStopsQueryAcrossCycles() {
        let executor = StubRunLoopExecutor()
        let recorder = QueryRecorder()
        let deliverQueue = DispatchQueue(label: "test.largest-deliver")
        let scanner = SpotlightLargestFilesScanner(
            runLoopThread: executor,
            deliverQueue: deliverQueue,
            makeQuery: recorder.make,
            floors: [0]
        )

        let cycles = 20
        for cycle in 1...cycles {
            var deliveredResult: LargestFilesResult?
            scanner.scan(volumeURL: volumeURL("/"), limit: 15) { result in
                deliveredResult = result
            }
            // One query per cycle; drain so it exists before signalling "finished".
            scanner.settleForTesting()
            XCTAssertEqual(recorder.all.count, cycle)
            // Finish runs the observer synchronously; draining the state then deliver
            // queue runs the cascade decision and the delivery closure to completion.
            recorder.postFinishGatheringOffMain()
            scanner.settleForTesting()
            deliverQueue.sync {}
            XCTAssertNotNil(deliveredResult, "cycle \(cycle) must deliver")
            XCTAssertFalse(deliveredResult?.isIndexAvailable ?? true)
        }

        scanner.cancel()
        scanner.settleForTesting()
        deliverQueue.sync {}
        executor.drain()

        let queries = recorder.all
        XCTAssertEqual(queries.count, cycles, "one query per cycle")
        for query in queries {
            XCTAssertEqual(query.startCount, 1)
            XCTAssertGreaterThanOrEqual(query.stopCount, 1)
        }
    }

    /// Cancelling the largest-files scan drops the pending delivery and stops its query
    /// every cycle. Single-floor cascade so each cycle has exactly one query to cancel.
    func testLargestFilesScannerCancelDropsDeliveryAndStopsQueryEachCycle() {
        let executor = StubRunLoopExecutor()
        let recorder = QueryRecorder()
        let deliverQueue = DispatchQueue(label: "test.largest-deliver-cancel")
        let scanner = SpotlightLargestFilesScanner(
            runLoopThread: executor,
            deliverQueue: deliverQueue,
            makeQuery: recorder.make,
            floors: [0]
        )

        let cycles = 20
        for cycle in 1...cycles {
            let delivered = LockedBox(false)
            scanner.scan(volumeURL: volumeURL("/"), limit: 15) { _ in delivered.set(true) }
            // Drain so this cycle's query exists before cancelling — deterministic
            // teardown rather than racing query creation.
            scanner.settleForTesting()
            XCTAssertEqual(recorder.all.count, cycle)
            scanner.cancel()
            scanner.settleForTesting()
            // A late "finished" notification must not resurrect the cancelled scan.
            recorder.postFinishGatheringOffMain()
            scanner.settleForTesting()
            deliverQueue.sync {}
            XCTAssertFalse(delivered.get(), "a cancelled scan must never deliver")
        }

        executor.drain()
        let queries = recorder.all
        XCTAssertEqual(queries.count, cycles)
        for query in queries {
            XCTAssertGreaterThanOrEqual(query.stopCount, 1)
        }
    }

    /// The size-floor cascade (A1) descends through *every* floor when each floor query
    /// matches nothing (`CountingMetadataQuery.resultCount == 0`), running one query per
    /// floor and stopping every one, then delivering `.unavailable` (the floor-0 query
    /// matched nothing → unusable index). Proves the multi-query descent starts and
    /// releases each floor's query with the same lifecycle discipline as a single scan —
    /// no query is left running after the cascade resolves.
    func testLargestFilesCascadeDescendsAndStopsEveryFloorQuery() {
        let executor = StubRunLoopExecutor()
        let recorder = QueryRecorder()
        let deliverQueue = DispatchQueue(label: "test.largest-cascade")
        let floors: [Int64] = [1_000_000, 1_000, 0] // three floors, high → no-floor
        let scanner = SpotlightLargestFilesScanner(
            runLoopThread: executor,
            deliverQueue: deliverQueue,
            makeQuery: recorder.make,
            floors: floors
        )

        let deliveredResult = LockedBox<LargestFilesResult?>(nil)
        scanner.scan(volumeURL: volumeURL("/"), limit: 15) { result in
            deliveredResult.set(result)
        }
        // Drain so the first floor's query is created and started before we post finish.
        scanner.settleForTesting()

        // Each floor's query is created only after the previous floor's finish is
        // processed on the state queue (`advanceCascade` → `startQuery`, which starts the
        // new query synchronously through the stub run-loop). So one finish→settle step
        // advances the cascade exactly one floor deterministically: post finish (runs the
        // live floor's observer synchronously — re-posting for already-torn-down floors is
        // a harmless no-op since their observers were removed), then settle to run the
        // cascade decision and start the next floor's query. Bounded by the floor count
        // plus a margin — no wall clock, no sleep. It resolves within `floors.count`
        // steps; the extra headroom only catches a regression.
        for _ in 0..<(floors.count + 1) where deliveredResult.get() == nil {
            recorder.postFinishGatheringOffMain()
            scanner.settleForTesting()
        }

        deliverQueue.sync {}
        executor.drain()

        XCTAssertEqual(deliveredResult.get(), .unavailable,
                       "floor-0 matched nothing → the cascade delivers unavailable")

        let queries = recorder.all
        XCTAssertEqual(queries.count, floors.count, "exactly one query per floor")
        for query in queries {
            XCTAssertEqual(query.startCount, 1, "each floor query starts exactly once")
            XCTAssertGreaterThanOrEqual(query.stopCount, 1, "each floor query is stopped")
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Minimal thread-safe box for values a scanner writes from a delivery closure (on the
/// deliver queue) while the test reads them from the main thread — a cross-thread
/// read/write that needs a lock even though the drain barriers make the timing
/// deterministic.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
}
