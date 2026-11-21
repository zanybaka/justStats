import AppKit
import SwiftUI
import XCTest
@testable import justStats

// MARK: - Shared fakes

final class FakeLocation: LocationAuthorizing {
    var permission: LocationPermission
    private(set) var requestCount = 0
    init(_ permission: LocationPermission) { self.permission = permission }
    func requestAuthorization() { requestCount += 1 }
}

final class SpyMetadataProvider: NetworkMetadataProviding {
    private let lock = NSLock()
    private var reads = 0
    var result = NetworkMetadata(wifi: nil, localIP: "192.168.1.5", dnsServers: ["1.1.1.1"])
    /// When set, `read()` blocks until the test signals — lets a test cancel mid-flight.
    var gate: DispatchSemaphore?
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read() -> NetworkMetadata {
        lock.lock(); reads += 1; lock.unlock()
        gate?.wait()
        return result
    }
}

final class SpyProber: LatencyProbing {
    private let lock = NSLock()
    private var pings = 0
    var result = LatencyResult.reachable(milliseconds: 23.4)
    var pingCount: Int { lock.lock(); defer { lock.unlock() }; return pings }
    func ping() -> LatencyResult {
        lock.lock(); pings += 1; lock.unlock()
        return result
    }
}

/// Never completes until cancelled; records spawn/termination like the real runner would.
final class BlockingNettopRunner: NettopRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var cancelled = 0
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return started }
    var cancelledCount: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
    func run() async throws -> String {
        lock.lock(); started += 1; lock.unlock()
        return try await withTaskCancellationHandler {
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return ""
        } onCancel: {
            lock.lock(); cancelled += 1; lock.unlock()
        }
    }
}

/// Replays queued outputs (or errors), one per run.
final class ScriptedNettopRunner: NettopRunning, @unchecked Sendable {
    var script: [Result<String, Error>]
    private(set) var runCount = 0
    init(_ script: [Result<String, Error>]) { self.script = script }
    func run() async throws -> String {
        runCount += 1
        guard !script.isEmpty else { throw NettopError.failed }
        return try script.removeFirst().get()
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
}

// MARK: - RateFormat

final class RateFormatTests: XCTestCase {
    func testScaling() {
        XCTAssertEqual(RateFormat.text(bytesPerSecond: 0), "0 B/s")
        XCTAssertEqual(RateFormat.text(bytesPerSecond: 812), "812 B/s")
        XCTAssertEqual(RateFormat.text(bytesPerSecond: 1_234), "1.2 KB/s")
        XCTAssertEqual(RateFormat.text(bytesPerSecond: 12_345), "12 KB/s")
        XCTAssertEqual(RateFormat.text(bytesPerSecond: 1_234_567), "1.2 MB/s")
        XCTAssertEqual(RateFormat.text(bytesPerSecond: 2_500_000_000), "2.5 GB/s")
    }

    func testRoundingPromotesInsteadOfPrintingFourDigits() {
        XCTAssertEqual(RateFormat.text(bytesPerSecond: 999_960), "1 MB/s")
    }

    func testNegativeAndNonFiniteReadAsZero() {
        XCTAssertEqual(RateFormat.text(bytesPerSecond: -5), "0 B/s")
        XCTAssertEqual(RateFormat.text(bytesPerSecond: .nan), "0 B/s")
    }
}

// MARK: - Card content (NET-002)

final class NetworkCardContentTests: XCTestCase {
    func testLoadedState() {
        let samples = [NetRate(down: 1_000, up: 10), NetRate(down: 2_500_000, up: 40_000)]
        let content = NetworkCardContent(
            latest: samples.last, samples: samples,
            totals: NetTotals(down: 12_000_000_000, up: 3_000_000_000), totalsWereReset: false
        )
        XCTAssertEqual(content.downText, "2.5 MB/s")
        XCTAssertEqual(content.upText, "40 KB/s")
        XCTAssertEqual(content.chart, .series(down: [1_000, 2_500_000], up: [10, 40_000]))
        XCTAssertEqual(content.totalsLabel, "Since boot")
        XCTAssertEqual(content.totalsDownText, "12 GB")
        XCTAssertEqual(content.totalsUpText, "3 GB")
        XCTAssertEqual(
            content.accessibilitySummary,
            "Network: download 2.5 MB/s, upload 40 KB/s. Since boot: 12 GB downloaded, 3 GB uploaded."
        )
    }

    func testEmptyBufferIsAnExplicitEmptyChartAndPlaceholderRates() {
        let content = NetworkCardContent(latest: nil, samples: [], totals: .zero, totalsWereReset: false)
        XCTAssertEqual(content.chart, .empty)
        XCTAssertEqual(content.downText, NetworkCardContent.placeholder)
        XCTAssertEqual(content.upText, NetworkCardContent.placeholder)
        XCTAssertTrue(content.accessibilitySummary.hasPrefix("Network: measuring."))
    }

    func testResetStateRelabelsTotalsAndShowsZero() {
        let content = NetworkCardContent(latest: NetRate(down: 5, up: 5), samples: [NetRate(down: 5, up: 5)],
                                         totals: .zero, totalsWereReset: true)
        XCTAssertEqual(content.totalsLabel, "Since reset")
        XCTAssertEqual(content.totalsDownText, "0 B")
        XCTAssertEqual(content.totalsUpText, "0 B")
        XCTAssertTrue(content.accessibilitySummary.contains("Since reset"))
    }

    func testDisclosureContentAndAccessibility() {
        let collapsed = NetworkDisclosureContent(title: NetworkDisclosureContent.interfacesTitle, isExpanded: false)
        XCTAssertEqual(collapsed.symbolName, "chevron.right")
        XCTAssertEqual(collapsed.accessibilityLabel, "Interfaces")
        XCTAssertEqual(collapsed.accessibilityValue, "collapsed")
        let expanded = NetworkDisclosureContent(title: NetworkDisclosureContent.processesTitle, isExpanded: true)
        XCTAssertEqual(expanded.symbolName, "chevron.down")
        XCTAssertEqual(expanded.accessibilityLabel, "Top processes")
        XCTAssertEqual(expanded.accessibilityValue, "expanded")
    }

    func testSparklineScaleHasAFloorAndFollowsThePeak() {
        XCTAssertEqual(NetworkSparklineView.scale(down: [10], up: [20]), NetworkSparklineView.minimumScale)
        XCTAssertEqual(NetworkSparklineView.scale(down: [5_000_000], up: [20]), 5_000_000)
    }
}

// MARK: - Sampler → chart honesty, lifecycle spy, view tree

@MainActor
final class NetworkSectionIntegrationTests: XCTestCase {
    private var clock: TimeInterval = 10
    private let source = FakeCounterSource()
    private let scheduler = ManualTickScheduler()

    private func makeSampler() -> NetSampler {
        NetSampler(source: source, scheduler: scheduler, uptime: { [unowned self] in self.clock })
    }

    private func makeSection(sampler: NetSampler, runner: NettopRunning = BlockingNettopRunner(),
                             sampling: NetworkSampling? = nil) -> NetworkSectionViewModel {
        NetworkSectionViewModel(
            sampler: sampler,
            details: NetworkDetailsModel(metadata: SpyMetadataProvider(), prober: SpyProber(), location: FakeLocation(.authorized)),
            processes: ProcessTrafficModel(runner: runner),
            sampling: sampling
        )
    }

    /// The chart plots exactly the real samples — no zero-filled history before or between them.
    func testChartContainsOnlyRealSamples() {
        let sampler = makeSampler()
        func content() -> NetworkCardContent {
            NetworkCardContent(latest: sampler.latest, samples: sampler.samples.map(\.rate),
                               totals: sampler.totals, totalsWereReset: sampler.totalsWereReset)
        }
        XCTAssertEqual(content().chart, .empty)
        source.next = [InterfaceCounters(name: "en0", rxBytes: 0, txBytes: 0, baudrate: 1_000_000_000, isUp: true)]
        sampler.start()
        XCTAssertEqual(content().chart, .empty, "the baseline read is not a sample")
        for step in 1...3 {
            clock += 1
            source.next = [InterfaceCounters(name: "en0", rxBytes: UInt64(step) * 1_000, txBytes: 0, baudrate: 1_000_000_000, isUp: true)]
            scheduler.fire()
        }
        guard case .series(let down, let up) = content().chart else { return XCTFail("expected a series") }
        XCTAssertEqual(down, [1_000, 1_000, 1_000])
        XCTAssertEqual(up.count, 3)
    }

    private func makeCoordinator(spy: SamplingSpy) -> VolumeListPopoverCoordinator {
        VolumeListPopoverCoordinator(
            makeModel: {
                VolumeListViewModel(enumerate: { VolumeEnumerator.Snapshot(internalVolumes: [], deferredVolumes: []) },
                                    resolver: MockDeferredVolumeResolver(), scanner: MockCategoryScanner(),
                                    largestFilesScanner: MockLargestFilesScanner())
            },
            makeNetworkSection: { [unowned self] in self.makeSection(sampler: self.makeSampler(), sampling: spy) }
        )
    }

    /// Opening the popover starts nothing network-related: it opens on Disks.
    func testOpeningPopoverStartsNoNetworkWork() throws {
        let spy = SamplingSpy()
        let coordinator = makeCoordinator(spy: spy)
        let hosting = try XCTUnwrap(coordinator.makeContentViewController() as? NSHostingController<VolumeListView>)
        coordinator.popoverDidOpen()
        XCTAssertEqual(hosting.rootView.tabs.selected, .disks)
        XCTAssertEqual(spy.events, [], "the default Disks tab never touches the network sampler")
        coordinator.popoverDidClose()
        XCTAssertEqual(spy.events, [], "nothing was started, so nothing needs stopping")
    }

    /// Selecting the Network tab starts the sampler; leaving it, or closing the popover, stops it.
    func testSamplerStartsOnNetworkTabAndStopsOnLeavingAndOnClose() throws {
        let spy = SamplingSpy()
        let coordinator = makeCoordinator(spy: spy)
        let hosting = try XCTUnwrap(coordinator.makeContentViewController() as? NSHostingController<VolumeListView>)
        coordinator.popoverDidOpen()
        hosting.rootView.tabs.select(.network)
        XCTAssertEqual(spy.events, ["start"])
        hosting.rootView.tabs.select(.disks)
        XCTAssertEqual(spy.events, ["start", "stop"])
        hosting.rootView.tabs.select(.network)
        coordinator.popoverDidClose()
        XCTAssertEqual(spy.events, ["start", "stop", "start", "stop"], "close stops the sampler on every route")
    }

    func testTabsWithoutNetworkModelStayOnDisks() {
        let tabs = PopoverTabsModel(network: nil)
        XCTAssertFalse(tabs.showsTabs)
        tabs.select(.network)
        XCTAssertEqual(tabs.selected, .disks)
    }

    func testCoordinatorWithoutNetworkWiringHasNoNetworkSection() throws {
        let coordinator = VolumeListPopoverCoordinator(makeModel: {
            VolumeListViewModel(enumerate: { VolumeEnumerator.Snapshot(internalVolumes: [], deferredVolumes: []) },
                                resolver: MockDeferredVolumeResolver(), scanner: MockCategoryScanner(),
                                largestFilesScanner: MockLargestFilesScanner())
        })
        let hosting = try XCTUnwrap(coordinator.makeContentViewController() as? NSHostingController<VolumeListView>)
        XCTAssertNil(hosting.rootView.network)
        XCTAssertFalse(hosting.rootView.tabs.showsTabs)
    }

    // MARK: Expansion lifecycle (NET-003/004)

    /// Interfaces and Top processes expand independently; each starts only its own work.
    func testDisclosuresAreIndependentAndLazy() async {
        let runner = BlockingNettopRunner()
        let metadata = SpyMetadataProvider()
        let prober = SpyProber()
        let section = NetworkSectionViewModel(
            sampler: makeSampler(),
            details: NetworkDetailsModel(metadata: metadata, prober: prober, location: FakeLocation(.authorized)),
            processes: ProcessTrafficModel(runner: runner)
        )
        section.activate()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(runner.startedCount, 0, "activating the tab alone starts neither metadata nor nettop")
        XCTAssertEqual(metadata.readCount, 0)
        XCTAssertEqual(prober.pingCount, 0)

        section.expandInterfaces()
        await waitUntil { prober.pingCount == 1 }
        XCTAssertEqual(metadata.readCount, 1)
        XCTAssertEqual(prober.pingCount, 1)
        XCTAssertEqual(runner.startedCount, 0, "expanding Interfaces never spawns nettop")

        section.expandProcesses()
        await waitUntil { runner.startedCount == 1 }
        XCTAssertEqual(runner.startedCount, 1, "nettop is spawned only for the expanded Top processes")

        section.collapseProcesses()
        await waitUntil { runner.cancelledCount == 1 }
        XCTAssertEqual(runner.cancelledCount, 1, "collapsing Top processes terminates nettop")
        XCTAssertFalse(section.processes.isRunning)
        XCTAssertNotEqual(section.details.phase, .idle, "Interfaces stays loaded")

        section.collapseInterfaces()
        XCTAssertEqual(section.details.phase, .idle)
        section.invalidate()
    }

    func testDisclosuresCannotExpandBeforeTheTabIsActive() async {
        let runner = BlockingNettopRunner()
        let section = makeSection(sampler: makeSampler(), runner: runner)
        section.expandProcesses()
        section.expandInterfaces()
        XCTAssertFalse(section.isProcessesExpanded)
        XCTAssertFalse(section.isInterfacesExpanded)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(runner.startedCount, 0)
    }

    func testLeavingTheTabCollapsesAndStopsEverything() async {
        let runner = BlockingNettopRunner()
        let spy = SamplingSpy()
        let section = makeSection(sampler: makeSampler(), runner: runner, sampling: spy)
        section.activate()
        section.expandProcesses()
        section.expandInterfaces()
        await waitUntil { runner.startedCount == 1 }
        section.deactivate()
        await waitUntil { runner.cancelledCount == 1 }
        XCTAssertEqual(runner.cancelledCount, 1)
        XCTAssertFalse(section.isProcessesExpanded)
        XCTAssertFalse(section.isInterfacesExpanded)
        XCTAssertEqual(spy.events, ["start", "stop"])
    }

    func testPopoverCloseTerminatesNettopAndBlocksReactivation() async {
        let runner = BlockingNettopRunner()
        let section = makeSection(sampler: makeSampler(), runner: runner)
        section.activate()
        section.expandProcesses()
        await waitUntil { runner.startedCount == 1 }
        section.invalidate()
        await waitUntil { runner.cancelledCount == 1 }
        XCTAssertEqual(runner.cancelledCount, 1)
        section.activate()
        section.expandProcesses()
        XCTAssertFalse(section.isActive)
        XCTAssertFalse(section.isProcessesExpanded)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(runner.startedCount, 1, "a closed popover never respawns nettop")
    }

    func testRefreshReadsMetadataAndPingsOncePerRefresh() async {
        let metadata = SpyMetadataProvider()
        let prober = SpyProber()
        let section = NetworkSectionViewModel(
            sampler: makeSampler(),
            details: NetworkDetailsModel(metadata: metadata, prober: prober, location: FakeLocation(.authorized)),
            processes: ProcessTrafficModel(runner: BlockingNettopRunner())
        )
        section.activate()
        section.expandInterfaces()
        await waitUntil { prober.pingCount == 1 }
        section.refreshDetails()
        await waitUntil { prober.pingCount == 2 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(metadata.readCount, 2)
        XCTAssertEqual(prober.pingCount, 2, "exactly one echo per expand/Refresh, no periodic ping")
        section.invalidate()
    }

    // MARK: Rendering + accessibility

    /// The section lays out inside a hosting view at the popover width, and the strings the
    /// view hands to VoiceOver come from the same content structs asserted here. (SwiftUI
    /// only materialises its accessibility tree for a live AX client, so a headless test
    /// cannot walk it; the label sources are pinned instead, as in `RowAccessibilityLabelTests`.)
    func testSectionRendersAtPopoverWidthAndSpeaksOneSummarySentence() {
        let sampler = makeSampler()
        source.next = [InterfaceCounters(name: "en0", rxBytes: 0, txBytes: 0, baudrate: 1_000_000_000, isUp: true)]
        sampler.start()
        clock += 1
        source.next = [InterfaceCounters(name: "en0", rxBytes: 2_000_000, txBytes: 40_000, baudrate: 1_000_000_000, isUp: true)]
        scheduler.fire()

        let host = NSHostingView(rootView: NetworkSectionView(model: makeSection(sampler: sampler)).frame(width: PopoverLayout.contentWidth))
        XCTAssertEqual(host.fittingSize.width, PopoverLayout.contentWidth, accuracy: 0.5)
        XCTAssertGreaterThan(host.fittingSize.height, 80)

        let content = NetworkCardContent(latest: sampler.latest, samples: sampler.samples.map(\.rate),
                                         totals: sampler.totals, totalsWereReset: sampler.totalsWereReset)
        XCTAssertEqual(
            content.accessibilitySummary,
            "Network: download 2.0 MB/s, upload 40 KB/s. Since boot: 2 MB downloaded, 40 kB uploaded."
        )
        XCTAssertEqual(NetworkCardContent.resetAccessibilityLabel, "Reset network totals")
        XCTAssertEqual(NetworkDisclosureContent(title: NetworkDisclosureContent.processesTitle, isExpanded: false).accessibilityLabel, "Top processes")
        sampler.stop()
    }
}

@MainActor
final class SamplingSpy: NetworkSampling {
    private(set) var events: [String] = []
    func start() { events.append("start") }
    func stop() { events.append("stop") }
}
