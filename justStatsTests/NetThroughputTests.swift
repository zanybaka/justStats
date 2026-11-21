import Combine
import XCTest
@testable import justStats

/// NET-001: delta math, clamp, plausibility cutoff, virtual filter, totals/reset, and the
/// "idle until start()" lifecycle — all with fake counter feeds, no sysctl.
final class NetThroughputEngineTests: XCTestCase {
    private func c(_ name: String, rx: UInt64, tx: UInt64, baud: UInt64 = 1_000_000_000, up: Bool = true) -> InterfaceCounters {
        InterfaceCounters(name: name, rxBytes: rx, txBytes: tx, baudrate: baud, isUp: up)
    }

    func testBaselineReadHasNoRateButHasTotals() {
        var engine = NetThroughputEngine()
        let reading = engine.ingest([c("en0", rx: 5_000, tx: 2_000)], elapsed: 0)
        XCTAssertNil(reading.physicalRate)
        XCTAssertEqual(reading.totals, NetTotals(down: 5_000, up: 2_000))
    }

    func testRateIsDeltaOverElapsed() throws {
        var engine = NetThroughputEngine()
        _ = engine.ingest([c("en0", rx: 1_000, tx: 500)], elapsed: 0)
        let reading = engine.ingest([c("en0", rx: 4_000, tx: 1_500)], elapsed: 2)
        let rate = try XCTUnwrap(reading.physicalRate)
        XCTAssertEqual(rate.down, 1_500, accuracy: 0.001)
        XCTAssertEqual(rate.up, 500, accuracy: 0.001)
    }

    func testNegativeDeltaClampsToZero() throws {
        var engine = NetThroughputEngine()
        _ = engine.ingest([c("en0", rx: 9_000, tx: 9_000)], elapsed: 0)
        let reading = engine.ingest([c("en0", rx: 100, tx: 50)], elapsed: 1)
        XCTAssertEqual(try XCTUnwrap(reading.physicalRate), .zero)
    }

    func testImplausibleJumpAboveLinkRateIsZeroed() throws {
        var engine = NetThroughputEngine()
        // 8 Mbit/s link = 1 MB/s; limit is 1 MB/s × 1 s × 1.5.
        _ = engine.ingest([c("en0", rx: 0, tx: 0, baud: 8_000_000)], elapsed: 0)
        let within = engine.ingest([c("en0", rx: 1_400_000, tx: 0, baud: 8_000_000)], elapsed: 1)
        XCTAssertEqual(try XCTUnwrap(within.physicalRate).down, 1_400_000, accuracy: 0.001)
        let beyond = engine.ingest([c("en0", rx: 1_400_000 + 1_600_000, tx: 0, baud: 8_000_000)], elapsed: 1)
        XCTAssertEqual(try XCTUnwrap(beyond.physicalRate).down, 0)
    }

    func testUnknownLinkRateUsesFixedCap() {
        let cap = NetThroughputEngine.fallbackMaxBytesPerSecond
        XCTAssertEqual(NetThroughputEngine.rate(from: 0, to: UInt64(cap), baudrate: 0, elapsed: 1), cap)
        XCTAssertEqual(NetThroughputEngine.rate(from: 0, to: UInt64(cap * 2), baudrate: 0, elapsed: 1), 0)
    }

    func testVirtualPrefixFilter() {
        for name in ["utun3", "ipsec0", "ppp0", "tun1", "tap0", "gif0", "stf0", "wg0"] {
            XCTAssertEqual(NetInterfaceKind.kind(forName: name), .virtual, name)
        }
        for name in ["en0", "en5", "bridge0", "awdl0", "llw0", "anpi0"] {
            XCTAssertEqual(NetInterfaceKind.kind(forName: name), .physical, name)
        }
        XCTAssertEqual(NetInterfaceKind.kind(forName: "lo0"), .loopback)
    }

    func testVirtualInterfacesKeepOwnRowsAndAreNotMergedIntoPhysical() throws {
        var engine = NetThroughputEngine()
        _ = engine.ingest([c("en0", rx: 0, tx: 0), c("utun2", rx: 0, tx: 0), c("lo0", rx: 0, tx: 0)], elapsed: 0)
        let reading = engine.ingest(
            [c("en0", rx: 1_000, tx: 100), c("utun2", rx: 800, tx: 80), c("lo0", rx: 50_000, tx: 50_000)],
            elapsed: 1
        )
        XCTAssertEqual(try XCTUnwrap(reading.physicalRate), NetRate(down: 1_000, up: 100))
        let tunnel = try XCTUnwrap(reading.interfaces.first { $0.name == "utun2" })
        XCTAssertEqual(tunnel.kind, .virtual)
        XCTAssertEqual(tunnel.rate, NetRate(down: 800, up: 80))
        XCTAssertEqual(reading.totals, NetTotals(down: 1_000, up: 100), "totals are physical only")
    }

    func testSinceBootTotalsAreTheSumOfPhysicalCounters() {
        var engine = NetThroughputEngine()
        let reading = engine.ingest([c("en0", rx: 10, tx: 1), c("en1", rx: 20, tx: 2), c("utun0", rx: 999, tx: 999)], elapsed: 0)
        XCTAssertEqual(reading.totals, NetTotals(down: 30, up: 3))
    }

    func testResetStoresOffsetAndTotalsKeepGrowingFromZero() {
        var engine = NetThroughputEngine()
        _ = engine.ingest([c("en0", rx: 1_000, tx: 400)], elapsed: 0)
        engine.resetTotals()
        XCTAssertEqual(engine.totals, .zero)
        let reading = engine.ingest([c("en0", rx: 1_300, tx: 450)], elapsed: 1)
        XCTAssertEqual(reading.totals, NetTotals(down: 300, up: 50))
    }

    func testVanishedInterfaceNeverMakesTotalsNegative() {
        var engine = NetThroughputEngine()
        _ = engine.ingest([c("en0", rx: 100, tx: 100), c("en5", rx: 900, tx: 900)], elapsed: 0)
        engine.resetTotals()
        let reading = engine.ingest([c("en0", rx: 150, tx: 150)], elapsed: 1)
        XCTAssertEqual(reading.totals, .zero)
    }

    func testRingBufferKeepsNewest180() {
        var ring = RingBuffer<Int>(capacity: NetSampler.ringCapacity)
        for i in 0..<200 { ring.append(i) }
        XCTAssertEqual(ring.elements.count, 180)
        XCTAssertEqual(ring.elements.first, 20)
        XCTAssertEqual(ring.elements.last, 199)
    }
}

// MARK: - Sampler lifecycle

final class FakeCounterSource: NetCounterSource {
    var next: [InterfaceCounters] = []
    private(set) var readCount = 0
    func readCounters() -> [InterfaceCounters] {
        readCount += 1
        return next
    }
}

/// Scheduler whose timer is fired by hand; counts how many timers were ever created.
final class ManualTickScheduler: NetTickScheduling {
    private(set) var scheduledCount = 0
    private(set) var cancelledCount = 0
    private var handler: (@MainActor () -> Void)?

    func schedule(interval: TimeInterval, handler: @escaping @MainActor () -> Void) -> AnyCancellable {
        scheduledCount += 1
        self.handler = handler
        return AnyCancellable { [weak self] in
            self?.cancelledCount += 1
            self?.handler = nil
        }
    }

    @MainActor func fire() { handler?() }
    var isArmed: Bool { handler != nil }
}

@MainActor
final class NetSamplerTests: XCTestCase {
    private var clock: TimeInterval = 100
    private let source = FakeCounterSource()
    private let scheduler = ManualTickScheduler()

    private func makeSampler() -> NetSampler {
        NetSampler(source: source, scheduler: scheduler, uptime: { [unowned self] in self.clock })
    }

    func testNoTimerExistsOrFiresUntilStart() {
        let sampler = makeSampler()
        XCTAssertEqual(scheduler.scheduledCount, 0)
        XCTAssertFalse(sampler.isRunning)
        XCTAssertEqual(source.readCount, 0, "creating the sampler reads nothing")
        scheduler.fire()
        XCTAssertEqual(source.readCount, 0)
        XCTAssertTrue(sampler.samples.isEmpty)
    }

    func testStartBaselinesThenTicksProduceRealSamplesOnly() {
        let sampler = makeSampler()
        source.next = [InterfaceCounters(name: "en0", rxBytes: 1_000, tx: 0)]
        sampler.start()
        XCTAssertEqual(scheduler.scheduledCount, 1)
        XCTAssertTrue(sampler.samples.isEmpty, "baseline read must not fabricate a sample")
        XCTAssertEqual(sampler.totals.down, 1_000)

        clock += 1
        source.next = [InterfaceCounters(name: "en0", rxBytes: 3_000, tx: 0)]
        scheduler.fire()
        XCTAssertEqual(sampler.samples.count, 1)
        XCTAssertEqual(sampler.latest?.down ?? -1, 2_000, accuracy: 0.001)
    }

    func testStopCancelsTimerClearsHistoryAndRebaselinesOnNextStart() {
        let sampler = makeSampler()
        source.next = [InterfaceCounters(name: "en0", rxBytes: 0, tx: 0)]
        sampler.start()
        clock += 1
        scheduler.fire()
        XCTAssertEqual(sampler.samples.count, 1)

        sampler.stop()
        XCTAssertFalse(scheduler.isArmed)
        XCTAssertEqual(scheduler.cancelledCount, 1)
        XCTAssertTrue(sampler.samples.isEmpty)
        XCTAssertNil(sampler.latest)

        clock += 600
        source.next = [InterfaceCounters(name: "en0", rxBytes: 9_999_999, tx: 0)]
        sampler.start()
        XCTAssertTrue(sampler.samples.isEmpty, "a closed interval must not become one giant rate")
    }

    func testStartIsIdempotent() {
        let sampler = makeSampler()
        sampler.start()
        sampler.start()
        XCTAssertEqual(scheduler.scheduledCount, 1)
    }

    func testResetTotalsZeroesTotalsWithoutTouchingChart() {
        let sampler = makeSampler()
        source.next = [InterfaceCounters(name: "en0", rxBytes: 500, tx: 100)]
        sampler.start()
        sampler.resetTotals()
        XCTAssertEqual(sampler.totals, .zero)
    }
}

private extension InterfaceCounters {
    init(name: String, rxBytes: UInt64, tx: UInt64) {
        self.init(name: name, rxBytes: rxBytes, txBytes: tx, baudrate: 1_000_000_000, isUp: true)
    }
}

final class SysctlNetCounterSourceTests: XCTestCase {
    /// Smoke test of the thin sysctl layer: the loopback interface always exists.
    func testReadsRealInterfacesIncludingLoopback() {
        let counters = SysctlNetCounterSource().readCounters()
        XCTAssertFalse(counters.isEmpty)
        XCTAssertTrue(counters.contains { $0.name == "lo0" })
    }
}
