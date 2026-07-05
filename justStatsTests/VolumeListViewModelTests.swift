import Combine
import XCTest
@testable import justStats

/// Test double for `LargestFilesScanning` (ACT-001) that, like `MockCategoryScanner`,
/// keeps *every* scan's delivery closure so a test can replay a stale delivery from a
/// superseded pass and prove the view model's generation guard drops it. `deliver`
/// targets the latest, uncancelled scan (the seam contract: a cancelled scan never
/// delivers); `deliver(_:toScanAt:)` replays an earlier scan regardless of cancellation.
///
/// Lives here (not shared `TestSupport`) so the view-model tests own their own double,
/// separate from SCAN-003's minimal `MockLargestFilesScanner`.
final class ReplayableLargestFilesScanner: LargestFilesScanning {
    private(set) var scanRequests: [(url: URL, limit: Int)] = []
    private(set) var cancelCount = 0
    private var resultCallbacks: [(LargestFilesResult) -> Void] = []
    private var partialCallbacks: [([LargestFile]) -> Void] = []
    private var currentResult: ((LargestFilesResult) -> Void)?
    private var currentPartial: (([LargestFile]) -> Void)?

    func scan(
        volumeURL: URL,
        limit: Int,
        onPartial: @escaping ([LargestFile]) -> Void,
        onResult: @escaping (LargestFilesResult) -> Void
    ) {
        scanRequests.append((url: volumeURL, limit: limit))
        resultCallbacks.append(onResult)
        partialCallbacks.append(onPartial)
        currentResult = onResult
        currentPartial = onPartial
    }

    func cancel() {
        cancelCount += 1
        currentResult = nil
        currentPartial = nil
    }

    /// Delivers a progressive best-so-far partial into the latest, uncancelled scan.
    func deliverPartial(_ files: [LargestFile]) {
        currentPartial?(files)
    }

    /// Replays a *stale* progressive partial into the scan at `index` (0-based, in call
    /// order), regardless of cancellation — the model's generation guard must drop it.
    func deliverPartial(_ files: [LargestFile], toScanAt index: Int) {
        guard partialCallbacks.indices.contains(index) else { return }
        partialCallbacks[index](files)
    }

    /// Delivers into the latest, uncancelled scan. A no-op after `cancel()`.
    func deliver(_ result: LargestFilesResult) {
        currentResult?(result)
    }

    /// Replays a *stale* delivery into the scan at `index` (0-based, in call order),
    /// regardless of cancellation — the model's generation guard must drop it.
    func deliver(_ result: LargestFilesResult, toScanAt index: Int) {
        guard resultCallbacks.indices.contains(index) else { return }
        resultCallbacks[index](result)
    }
}

@MainActor
final class VolumeListViewModelTests: XCTestCase {
    // MARK: - Fixtures

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private func bootVolume() -> Volume {
        Volume(
            name: "Macintosh HD",
            mountURL: url("/"),
            totalBytes: 1_000_000_000_000,
            freeBytes: 400_000_000_000,
            kind: .internal,
            bsdName: "disk3s5"
        )
    }

    private func usbStub() -> DeferredVolume {
        DeferredVolume(name: "USB", mountURL: url("/Volumes/USB"), kind: .external)
    }

    private func nasStub() -> DeferredVolume {
        DeferredVolume(name: "NAS", mountURL: url("/Volumes/NAS"), kind: .network)
    }

    private func resolvedUSB() -> Volume {
        Volume(
            name: "USB",
            mountURL: url("/Volumes/USB"),
            totalBytes: 64_000_000_000,
            freeBytes: 10_000_000_000,
            kind: .external,
            bsdName: "disk4s1"
        )
    }

    private func resolvedNAS() -> Volume {
        Volume(
            name: "NAS",
            mountURL: url("/Volumes/NAS"),
            totalBytes: 8_000_000_000_000,
            freeBytes: 2_000_000_000_000,
            kind: .network,
            bsdName: nil
        )
    }

    private func largestFile(_ name: String, _ size: Int64, path: String? = nil) -> LargestFile {
        LargestFile(displayName: name, sizeBytes: size,
                    url: URL(fileURLWithPath: path ?? "/Users/me/\(name)"))
    }

    private func makeModel(
        internalVolumes: [Volume],
        deferredVolumes: [DeferredVolume],
        resolver: MockDeferredVolumeResolver,
        scanner: MockCategoryScanner = MockCategoryScanner(),
        largestFilesScanner: ReplayableLargestFilesScanner = ReplayableLargestFilesScanner(),
        fileTrasher: FileTrashing = MockFileTrasher(),
        hiddenFilesStore: HiddenFilesStoring = MockHiddenFilesStore(),
        cache: ScanResultCache? = nil
    ) -> VolumeListViewModel {
        let snapshot = VolumeEnumerator.Snapshot(
            internalVolumes: internalVolumes,
            deferredVolumes: deferredVolumes
        )
        return VolumeListViewModel(
            enumerate: { snapshot },
            resolver: resolver,
            scanner: scanner,
            largestFilesScanner: largestFilesScanner,
            fileTrasher: fileTrasher,
            hiddenFilesStore: hiddenFilesStore,
            cache: cache
        )
    }

    // MARK: - Initial load (FR3: internal rows immediately, placeholders for the rest)

    func testLoadShowsInternalRowsImmediatelyAndPlaceholdersForDeferred() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(
            internalVolumes: [bootVolume()],
            deferredVolumes: [usbStub(), nasStub()],
            resolver: resolver
        )

        model.load()

        XCTAssertEqual(model.rows, [
            .loaded(bootVolume()),
            .pending(usbStub()),
            .pending(nasStub()),
        ])
        XCTAssertEqual(resolver.resolveRequests, [[usbStub(), nasStub()]],
                       "all deferred stubs go to the resolver in one streaming pass")
    }

    func testLoadWithoutDeferredVolumesNeverTouchesTheResolver() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [], resolver: resolver)

        model.load()

        XCTAssertEqual(model.rows, [.loaded(bootVolume())])
        XCTAssertTrue(resolver.resolveRequests.isEmpty)
    }

    // MARK: - Streaming replacement (FR4: rows fill in without reordering)

    func testResolvedVolumeReplacesItsPlaceholderInPlace() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(
            internalVolumes: [bootVolume()],
            deferredVolumes: [usbStub(), nasStub()],
            resolver: resolver
        )
        model.load()

        resolver.deliver(.resolved(resolvedUSB()))

        XCTAssertEqual(model.rows, [
            .loaded(bootVolume()),
            .loaded(resolvedUSB()),
            .pending(nasStub()),
        ], "the resolved volume fills its own slot; the still-pending row is untouched")
    }

    func testOutOfOrderResolutionsKeepEnumerationOrder() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(
            internalVolumes: [bootVolume()],
            deferredVolumes: [usbStub(), nasStub()],
            resolver: resolver
        )
        model.load()

        // NAS answers before USB — row order must not change (no jumping rows).
        resolver.deliver(.resolved(resolvedNAS()))
        resolver.deliver(.resolved(resolvedUSB()))

        XCTAssertEqual(model.rows, [
            .loaded(bootVolume()),
            .loaded(resolvedUSB()),
            .loaded(resolvedNAS()),
        ])
    }

    func testUnavailableResolutionShowsUnavailableRow() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(
            internalVolumes: [bootVolume()],
            deferredVolumes: [nasStub()],
            resolver: resolver
        )
        model.load()

        resolver.deliver(.unavailable(nasStub()))

        XCTAssertEqual(model.rows, [
            .loaded(bootVolume()),
            .unavailable(nasStub()),
        ], "a failed/timed-out volume stays listed as a muted unavailable row")
    }

    func testResolutionForUnknownMountIsIgnored() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(
            internalVolumes: [bootVolume()],
            deferredVolumes: [usbStub()],
            resolver: resolver
        )
        model.load()
        let before = model.rows

        resolver.deliver(.resolved(resolvedNAS())) // never enumerated

        XCTAssertEqual(model.rows, before, "stale deliveries for unknown mounts change nothing")
    }

    // MARK: - Reload & teardown

    func testReloadRebuildsRowsAndStartsAFreshResolvePass() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(
            internalVolumes: [bootVolume()],
            deferredVolumes: [usbStub()],
            resolver: resolver
        )
        model.load()
        resolver.deliver(.resolved(resolvedUSB()))

        model.load()

        XCTAssertEqual(model.rows, [
            .loaded(bootVolume()),
            .pending(usbStub()),
        ], "a reload starts from placeholders again (VOL-005 Refresh semantics)")
        XCTAssertEqual(resolver.resolveRequests.count, 2)
    }

    func testInvalidateForwardsToResolver() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(internalVolumes: [], deferredVolumes: [nasStub()], resolver: resolver)
        model.load()

        model.invalidate()

        XCTAssertEqual(resolver.invalidateCount, 1)
    }

    // MARK: - Sort by fullness (VOL-005, PRD FR9)

    /// Loaded volume fixture with an explicit used share, so tests can pin the
    /// exact fullness ordering the comparator must produce.
    private func loaded(_ name: String, path: String, total: Int64, free: Int64) -> Volume {
        Volume(name: name, mountURL: url(path), totalBytes: total, freeBytes: free,
               kind: .external, bsdName: nil)
    }

    func testSortIsOffByDefaultAndDisplayRowsMatchEnumerationOrder() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [usbStub()],
                              resolver: resolver)
        model.load()

        XCTAssertFalse(model.sortMostFullFirst, "sort toggle defaults off")
        XCTAssertEqual(model.displayRows, model.rows,
                       "with the toggle off, display order is the enumeration order")
    }

    func testSortMostFullFirstOrdersByDescendingFullness() {
        let resolver = MockDeferredVolumeResolver()
        // Enumeration order (least → most full) so a real reorder is observable.
        let quarter = loaded("Quarter", path: "/Volumes/Q", total: 100, free: 75)   // 25% used
        let half = loaded("Half", path: "/Volumes/H", total: 100, free: 50)         // 50% used
        let full = loaded("Full", path: "/Volumes/F", total: 100, free: 10)         // 90% used
        let model = makeModel(internalVolumes: [quarter, half, full], deferredVolumes: [],
                              resolver: resolver)
        model.load()

        model.sortMostFullFirst = true

        XCTAssertEqual(model.displayRows, [.loaded(full), .loaded(half), .loaded(quarter)],
                       "most-full first: 90% → 50% → 25%")
        XCTAssertEqual(model.rows, [.loaded(quarter), .loaded(half), .loaded(full)],
                       "canonical enumeration order is never mutated by sorting")
    }

    func testSortTreatsZeroTotalVolumeAsFullnessZeroWithoutDividing() {
        let resolver = MockDeferredVolumeResolver()
        // A zero-total volume must count as 0% full (never NaN / divide-by-zero),
        // so it sinks below any volume with real usage.
        let empty = loaded("Empty", path: "/Volumes/E", total: 0, free: 0)
        let half = loaded("Half", path: "/Volumes/H", total: 100, free: 50)
        let model = makeModel(internalVolumes: [empty, half], deferredVolumes: [], resolver: resolver)
        model.load()

        model.sortMostFullFirst = true

        XCTAssertEqual(model.displayRows, [.loaded(half), .loaded(empty)],
                       "zero-total volume is fullness 0 and sorts to the bottom")
    }

    func testSortIsStableForEqualFullnessAndSinksSizelessRows() {
        let resolver = MockDeferredVolumeResolver()
        // Two equally-full volumes plus size-less pending/unavailable rows (fullness
        // 0). A stable sort keeps equal-fullness rows in enumeration order and keeps
        // the size-less rows (also 0) below the real ones, in their original order.
        let halfA = loaded("A", path: "/Volumes/A", total: 100, free: 50)
        let halfB = loaded("B", path: "/Volumes/B", total: 200, free: 100) // also 50%
        let pending = DeferredVolume(name: "Pending", mountURL: url("/Volumes/P"), kind: .external)
        let dead = DeferredVolume(name: "Dead", mountURL: url("/Volumes/D"), kind: .network)
        let model = VolumeListViewModel(
            enumerate: {
                VolumeEnumerator.Snapshot(internalVolumes: [halfA, halfB],
                                          deferredVolumes: [pending, dead])
            },
            resolver: resolver,
            scanner: MockCategoryScanner(),
            largestFilesScanner: MockLargestFilesScanner()
        )
        model.load()
        // Turn the second deferred row into an unavailable one; the first stays pending.
        resolver.deliver(.unavailable(dead))

        model.sortMostFullFirst = true

        XCTAssertEqual(model.displayRows, [
            .loaded(halfA), .loaded(halfB),   // equal fullness, enumeration order preserved
            .pending(pending), .unavailable(dead), // size-less rows sink, order preserved
        ])
    }

    func testTogglingSortOffRestoresTheDefaultEnumerationOrder() {
        let resolver = MockDeferredVolumeResolver()
        let quarter = loaded("Quarter", path: "/Volumes/Q", total: 100, free: 75)
        let full = loaded("Full", path: "/Volumes/F", total: 100, free: 10)
        let model = makeModel(internalVolumes: [quarter, full], deferredVolumes: [], resolver: resolver)
        model.load()
        let defaultOrder = model.displayRows

        model.sortMostFullFirst = true
        XCTAssertEqual(model.displayRows, [.loaded(full), .loaded(quarter)])

        model.sortMostFullFirst = false
        XCTAssertEqual(model.displayRows, defaultOrder,
                       "turning the toggle off restores the exact default order")
    }

    // MARK: - Manual Refresh (VOL-005, PRD FR13)

    func testRefreshReenumeratesFromPlaceholdersAndStartsAFreshResolvePass() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [usbStub()],
                              resolver: resolver)
        model.load()
        resolver.deliver(.resolved(resolvedUSB())) // first pass fully resolved

        model.refresh()

        XCTAssertEqual(model.rows, [.loaded(bootVolume()), .pending(usbStub())],
                       "refresh rebuilds rows from placeholders (re-enumerates in place)")
        XCTAssertEqual(resolver.resolveRequests.count, 2,
                       "refresh starts a second resolve pass (generation bump lives in the resolver)")
    }

    func testRefreshPreservesTheSortToggle() {
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [], resolver: resolver)
        model.load()
        model.sortMostFullFirst = true

        model.refresh()

        XCTAssertTrue(model.sortMostFullFirst, "refresh re-runs enumeration only; the sort stays on")
    }

    /// Refresh must cancel in-flight prior work: with the *real* resolver, a USB
    /// read still hanging from the pre-refresh generation must be dropped — not
    /// applied — when the refresh re-enumerates a volume set the USB is no longer
    /// part of (it was unmounted between opens). This exercises the generation
    /// bump + stale-delivery drop that Refresh relies on end to end.
    func testRefreshDropsStaleInFlightDeliveriesFromThePriorGeneration() {
        let provider = HangingVolumeInfoProvider()
        addTeardownBlock { provider.releaseAllHangs() }
        provider.setCapacity(VolumeSpace(free: 10_000_000_000, total: 64_000_000_000),
                             for: url("/Volumes/USB"))
        provider.setBSDName("disk4s1", for: url("/Volumes/USB"))
        // First-generation USB read hangs; refresh happens while it is still blocked.
        let gate = provider.hangCapacityReads(for: url("/Volumes/USB"))
        let resolver = DeferredVolumeResolver(provider: provider, timeout: 60)

        // load() sees USB; the refresh re-enumeration no longer does (USB removed),
        // so the still-hung generation-1 read has no generation-2 slot to land in.
        var snapshots = [
            VolumeEnumerator.Snapshot(internalVolumes: [bootVolume()], deferredVolumes: [usbStub()]),
            VolumeEnumerator.Snapshot(internalVolumes: [bootVolume()], deferredVolumes: []),
        ]
        let model = VolumeListViewModel(enumerate: { snapshots.removeFirst() }, resolver: resolver,
                                        scanner: MockCategoryScanner(),
                                        largestFilesScanner: MockLargestFilesScanner())

        model.load() // generation 1, USB read parked on the gate
        XCTAssertEqual(model.rows, [.loaded(bootVolume()), .pending(usbStub())])

        model.refresh() // generation 2 — supersedes generation 1; USB is gone
        XCTAssertEqual(model.rows, [.loaded(bootVolume())],
                       "refresh rebuilt rows without the now-absent USB")

        // Let generation 1's hung read finish: its delivery is stale (no gen-2 slot)
        // and must be dropped, so no stray USB row can reappear.
        gate.signal()
        let staleApplied = expectation(description: "a stale generation-1 delivery reaches the model")
        staleApplied.isInverted = true
        let cancellable = model.$rows.sink { rows in
            if rows.count > 1 { staleApplied.fulfill() }
        }
        wait(for: [staleApplied], timeout: 1)
        XCTAssertEqual(model.rows, [.loaded(bootVolume())],
                       "the pre-refresh in-flight result was dropped, not applied")
        cancellable.cancel()
    }

    // MARK: - Integration with the real resolver (streaming stays on main)

    func testStreamingFromRealResolverUpdatesRowsOnMain() {
        let provider = HangingVolumeInfoProvider()
        addTeardownBlock { provider.releaseAllHangs() }
        provider.setCapacity(VolumeSpace(free: 10_000_000_000, total: 64_000_000_000),
                             for: url("/Volumes/USB"))
        provider.setBSDName("disk4s1", for: url("/Volumes/USB"))
        let resolver = DeferredVolumeResolver(provider: provider, timeout: 60)
        let snapshot = VolumeEnumerator.Snapshot(
            internalVolumes: [bootVolume()],
            deferredVolumes: [usbStub()]
        )
        let model = VolumeListViewModel(enumerate: { snapshot }, resolver: resolver,
                                        scanner: MockCategoryScanner(),
                                        largestFilesScanner: MockLargestFilesScanner())

        model.load()
        XCTAssertEqual(model.rows, [.loaded(bootVolume()), .pending(usbStub())],
                       "placeholder must be visible before the async resolution lands")

        let resolved = expectation(description: "USB row streams in")
        let cancellable = model.$rows.sink { rows in
            if rows == [.loaded(self.bootVolume()), .loaded(self.resolvedUSB())] {
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 5)
        cancellable.cancel()
    }

    // MARK: - Category breakdown scanning (SCAN-004)

    /// A loaded internal volume starts a category scan on open, and the delivered
    /// Spotlight categories are reconciled with its total/free into a five-way
    /// breakdown published under the volume's mount URL.
    func testLoadScansLoadedVolumeAndPublishesReconciledBreakdown() {
        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner)
        model.load()

        // The boot volume is scanned, and until the result lands its state is .scanning.
        XCTAssertEqual(scanner.scanRequests, [url("/")])
        XCTAssertEqual(model.categoryStates[url("/")], .scanning)

        scanner.deliver(.available(apps: 100_000_000_000, media: 200_000_000_000, other: 50_000_000_000))

        // total 1 TB, free 400 GB → used 600 GB; system = 600 − (100+200+50) = 250 GB.
        let expected = StorageBreakdown.reconciled(
            categories: .available(apps: 100_000_000_000, media: 200_000_000_000, other: 50_000_000_000),
            totalBytes: 1_000_000_000_000,
            freeBytes: 400_000_000_000
        )
        XCTAssertEqual(model.categoryStates[url("/")], .breakdown(expected))
    }

    /// An unavailable index on a *non-boot* volume resolves to `.notIndexed`, not a
    /// misleading breakdown — the distinct case SCAN-005 renders its notice from
    /// (TECHSPEC §4). (The boot volume takes the SCAN-006 Full Disk Access path
    /// instead — asserted in `FullDiskAccessNoticeViewTests`.)
    func testUnavailableIndexRecordsNotIndexedState() {
        let scanner = MockCategoryScanner()
        let data = loaded("Data", path: "/Volumes/Data", total: 500, free: 100)
        let model = makeModel(internalVolumes: [data], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner)
        model.load()

        scanner.deliver(.unavailable)

        XCTAssertEqual(model.categoryStates[url("/Volumes/Data")], .notIndexed)
    }

    /// Scans run one at a time through the single shared scanner seam: the second
    /// volume is not scanned until the first volume's result arrives, and each ends
    /// up with its own breakdown.
    func testMultipleVolumesScanSequentiallyOneAtATime() {
        let scanner = MockCategoryScanner()
        let second = loaded("Data", path: "/Volumes/Data", total: 500, free: 100)
        let model = makeModel(internalVolumes: [bootVolume(), second], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner)
        model.load()

        // Only the first volume is scanning; the second waits its turn.
        XCTAssertEqual(scanner.scanRequests, [url("/")])
        XCTAssertNil(model.categoryStates[url("/Volumes/Data")])

        scanner.deliver(.available(apps: 100_000_000_000, media: 0, other: 0))

        // First is resolved; the second's scan now starts.
        XCTAssertEqual(scanner.scanRequests, [url("/"), url("/Volumes/Data")])
        XCTAssertEqual(model.categoryStates[url("/Volumes/Data")], .scanning)

        scanner.deliver(.available(apps: 10, media: 20, other: 30))

        // used = 500 − 100 = 400; system = 400 − 60 = 340.
        let expectedSecond = StorageBreakdown.reconciled(
            categories: .available(apps: 10, media: 20, other: 30),
            totalBytes: 500,
            freeBytes: 100
        )
        XCTAssertEqual(model.categoryStates[url("/Volumes/Data")], .breakdown(expectedSecond))
    }

    /// A deferred volume is not scanned while pending (its sizes are unknown); it is
    /// scanned only once its capacity resolves, so the reconciliation has real
    /// total/free to work from.
    func testDeferredVolumeIsScannedOnlyAfterItResolves() {
        let scanner = MockCategoryScanner()
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [usbStub()],
                              resolver: resolver, scanner: scanner)
        model.load()

        // Boot volume scans immediately; the pending USB has not (and cannot yet).
        scanner.deliver(.available(apps: 0, media: 0, other: 0))
        XCTAssertEqual(scanner.scanRequests, [url("/")],
                       "the pending USB is not scanned before its sizes resolve")

        resolver.deliver(.resolved(resolvedUSB()))

        // Now the resolved USB is scanned.
        XCTAssertEqual(scanner.scanRequests, [url("/"), url("/Volumes/USB")])
        scanner.deliver(.available(apps: 5_000_000_000, media: 0, other: 0))
        XCTAssertNotNil(model.categoryStates[url("/Volumes/USB")])
        if case .breakdown = model.categoryStates[url("/Volumes/USB")] {} else {
            XCTFail("resolved USB should carry a breakdown")
        }
    }

    /// A volume whose capacity read failed (unavailable row) is never scanned — a
    /// hung mount must not trigger a Spotlight pass.
    func testUnavailableRowIsNotScanned() {
        let scanner = MockCategoryScanner()
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(internalVolumes: [], deferredVolumes: [nasStub()],
                              resolver: resolver, scanner: scanner)
        model.load()
        resolver.deliver(.unavailable(nasStub()))

        XCTAssertTrue(scanner.scanRequests.isEmpty,
                      "an unavailable volume has no sizes to reconcile and is never scanned")
        XCTAssertNil(model.categoryStates[nasStub().mountURL])
    }

    /// Refresh while a scan is still in flight cancels that scan, clears breakdown
    /// state, and restarts scanning from the top.
    func testRefreshWhileScanningCancelsAndRescans() {
        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner)
        model.load() // boot scan in flight (not delivered)
        XCTAssertEqual(model.categoryStates[url("/")], .scanning)

        model.refresh()

        XCTAssertEqual(scanner.cancelCount, 1, "an in-flight scan is cancelled on refresh")
        XCTAssertEqual(model.categoryStates[url("/")], .scanning,
                       "breakdown state is cleared and the volume is rescanned")
        XCTAssertEqual(scanner.scanRequests, [url("/"), url("/")],
                       "refresh starts a fresh scan pass")
    }

    /// Refresh after all scans have completed doesn't cancel (nothing is in flight),
    /// but still clears breakdown state and rescans every volume.
    func testRefreshAfterScanCompletionClearsAndRescansWithoutRedundantCancel() {
        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner)
        model.load()
        scanner.deliver(.available(apps: 1, media: 1, other: 1))
        XCTAssertNotNil(model.categoryStates[url("/")])

        model.refresh()

        XCTAssertEqual(scanner.cancelCount, 0, "no cancel when no scan is in flight")
        XCTAssertEqual(model.categoryStates[url("/")], .scanning,
                       "breakdown state is cleared and the volume is rescanned")
        XCTAssertEqual(scanner.scanRequests, [url("/"), url("/")])
    }

    /// A scan result delivered after a refresh bumped the generation is stale and
    /// must not overwrite the fresh pass's state, nor stall the scan queue.
    func testStaleScanResultAfterRefreshIsDropped() {
        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner)
        model.load()    // scan index 0 = generation 1, boot scanning
        model.refresh() // generation 2: cancels, clears, rescans → scan index 1

        XCTAssertEqual(model.categoryStates[url("/")], .scanning)

        // The pre-refresh (index 0) scan finishes late — its delivery is stale and
        // must be dropped: the volume stays in the fresh `.scanning` state.
        scanner.deliver(.available(apps: 999, media: 999, other: 999), toScanAt: 0)
        XCTAssertEqual(model.categoryStates[url("/")], .scanning,
                       "a stale generation-1 delivery does not overwrite the fresh scan")

        // The fresh (index 1) scan still resolves normally afterwards.
        scanner.deliver(.available(apps: 5, media: 5, other: 5), toScanAt: 1)
        if case .breakdown = model.categoryStates[url("/")] {} else {
            XCTFail("the current-generation scan resolves normally")
        }
    }

    /// Invalidate (popover close) cancels the scanner so no query keeps gathering.
    func testInvalidateCancelsScanner() {
        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner)
        model.load()

        model.invalidate()

        XCTAssertEqual(scanner.cancelCount, 1)
    }

    /// No loaded volumes → nothing to scan; the scanner is never touched.
    func testNoLoadedVolumesNeverScans() {
        let scanner = MockCategoryScanner()
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(internalVolumes: [], deferredVolumes: [nasStub()],
                              resolver: resolver, scanner: scanner)
        model.load()

        XCTAssertTrue(scanner.scanRequests.isEmpty)
    }

    // MARK: - Largest files section (ACT-001, PRD FR7)

    /// On load the section scopes to the boot volume, starts a largest-files scan, and
    /// sits in `.scanning` until the result lands.
    func testLoadScopesLargestFilesToBootVolumeAndScans() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()

        XCTAssertEqual(largest.scanRequests.map(\.url), [url("/")])
        XCTAssertEqual(model.largestFilesVolumeURL, url("/"))
        XCTAssertEqual(model.largestFilesVolumeName, "Macintosh HD")
        XCTAssertEqual(model.largestFilesState, .scanning)
    }

    /// The delivered ranked files populate the section's `.available` state, in the
    /// order the scanner delivered them (the scanner already ranks; the model doesn't
    /// re-sort).
    func testLargestFilesPopulatedFromScanner() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()

        let files = [largestFile("huge.zip", 9_000), largestFile("big.mov", 5_000)]
        largest.deliver(.available(files))

        XCTAssertEqual(model.largestFilesState, .available(files))
    }

    /// An unavailable index for the scoped volume records `.unavailable` (the "Not
    /// indexed" degraded state), never an empty `.available` list that reads as "no
    /// large files".
    func testLargestFilesUnavailableIndexRecordsUnavailableState() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()

        largest.deliver(.unavailable)

        XCTAssertEqual(model.largestFilesState, .unavailable)
    }

    /// With no boot volume, the section scopes to the first loaded volume in row order.
    func testLargestFilesScopesToFirstLoadedVolumeWhenNoBootVolume() {
        let largest = ReplayableLargestFilesScanner()
        let first = loaded("Data", path: "/Volumes/Data", total: 500, free: 100)
        let second = loaded("Extra", path: "/Volumes/Extra", total: 500, free: 100)
        let model = makeModel(internalVolumes: [first, second], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()

        XCTAssertEqual(largest.scanRequests.map(\.url), [url("/Volumes/Data")],
                       "scopes to the first loaded volume, not the boot volume (there is none)")
        XCTAssertEqual(model.largestFilesVolumeURL, url("/Volumes/Data"))
        XCTAssertEqual(model.largestFilesVolumeName, "Data")
    }

    /// No loaded volume at load time → nothing to scope; the section stays `.idle` and
    /// the scanner is never touched.
    func testLargestFilesIdleWhenNoLoadedVolume() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [], deferredVolumes: [nasStub()],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()

        XCTAssertTrue(largest.scanRequests.isEmpty)
        XCTAssertEqual(model.largestFilesState, .idle)
        XCTAssertNil(model.largestFilesVolumeURL)
        XCTAssertNil(model.largestFilesVolumeName)
    }

    /// When every row is pending at load time, the section scopes to the first deferred
    /// volume once it resolves — so an all-external mount set still gets a section.
    func testLargestFilesScopesToFirstResolvedVolumeWhenAllRowsStartPending() {
        let largest = ReplayableLargestFilesScanner()
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(internalVolumes: [], deferredVolumes: [usbStub()],
                              resolver: resolver, largestFilesScanner: largest)
        model.load()

        // Nothing loaded yet → no scope, no scan.
        XCTAssertTrue(largest.scanRequests.isEmpty)
        XCTAssertEqual(model.largestFilesState, .idle)

        resolver.deliver(.resolved(resolvedUSB()))

        XCTAssertEqual(largest.scanRequests.map(\.url), [url("/Volumes/USB")])
        XCTAssertEqual(model.largestFilesVolumeURL, url("/Volumes/USB"))
        XCTAssertEqual(model.largestFilesState, .scanning)
    }

    /// Once the section is scoped, a later-resolving volume does not retarget it or
    /// start a second scan — the scope is fixed for the pass.
    func testLargestFilesScopeIsFixedAfterFirstLoadedVolume() {
        let largest = ReplayableLargestFilesScanner()
        let resolver = MockDeferredVolumeResolver()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [usbStub()],
                              resolver: resolver, largestFilesScanner: largest)
        model.load()
        XCTAssertEqual(largest.scanRequests.map(\.url), [url("/")])

        resolver.deliver(.resolved(resolvedUSB()))

        XCTAssertEqual(largest.scanRequests.map(\.url), [url("/")],
                       "a later resolution never retargets the scoped volume or rescans")
        XCTAssertEqual(model.largestFilesVolumeURL, url("/"))
    }

    /// Refresh cancels the in-flight largest-files scan, resets the section, and starts
    /// a fresh scan for the (re-scoped) boot volume.
    func testRefreshCancelsAndRestartsLargestFilesScan() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()
        largest.deliver(.available([largestFile("a", 10)]))
        XCTAssertEqual(model.largestFilesState, .available([largestFile("a", 10)]))

        model.refresh()

        XCTAssertGreaterThanOrEqual(largest.cancelCount, 1, "refresh cancels the prior scan")
        XCTAssertEqual(model.largestFilesState, .scanning, "the section restarts scanning")
        XCTAssertEqual(largest.scanRequests.map(\.url), [url("/"), url("/")],
                       "refresh starts a fresh largest-files scan pass")
    }

    /// A largest-files result delivered after a refresh bumped the generation is stale
    /// and must not overwrite the fresh pass's state, then the fresh pass still resolves.
    func testStaleLargestFilesResultAfterRefreshIsDropped() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()    // scan index 0 = generation 1, in flight
        model.refresh() // generation 2: cancels, resets, rescans → scan index 1

        XCTAssertEqual(model.largestFilesState, .scanning)

        // The pre-refresh (index 0) scan finishes late — its delivery is stale and must
        // be dropped: the section stays in the fresh `.scanning` state.
        largest.deliver(.available([largestFile("stale", 999)]), toScanAt: 0)
        XCTAssertEqual(model.largestFilesState, .scanning,
                       "a stale generation-1 delivery does not overwrite the fresh scan")

        // The fresh (index 1) scan still resolves normally afterwards.
        largest.deliver(.available([largestFile("fresh", 1)]), toScanAt: 1)
        XCTAssertEqual(model.largestFilesState, .available([largestFile("fresh", 1)]),
                       "the current-generation scan resolves normally")
    }

    /// Invalidate (popover close) cancels the largest-files scanner so no query keeps
    /// gathering between opens.
    func testInvalidateCancelsLargestFilesScanner() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()

        model.invalidate()

        XCTAssertGreaterThanOrEqual(largest.cancelCount, 1)
    }

    // MARK: - Move to Trash: confirm-state machine (ACT-002, PRD FR8, TECHSPEC §7/§8)

    /// Builds a boot-volume model whose largest-files section is already in `.available`
    /// with `files`, so the trash tests start from a rendered ranked list. Returns the
    /// model plus the trasher double so tests can assert what was (or wasn't) trashed.
    private func modelWithLargestFiles(
        _ files: [LargestFile],
        boot: Volume? = nil,
        fileTrasher: MockFileTrasher = MockFileTrasher(),
        hiddenFilesStore: HiddenFilesStoring = MockHiddenFilesStore()
    ) -> (VolumeListViewModel, MockFileTrasher) {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(
            internalVolumes: [boot ?? bootVolume()], deferredVolumes: [],
            resolver: MockDeferredVolumeResolver(),
            largestFilesScanner: largest, fileTrasher: fileTrasher,
            hiddenFilesStore: hiddenFilesStore
        )
        model.load()
        largest.deliver(.available(files))
        return (model, fileTrasher)
    }

    /// No row is armed for confirmation and no error is shown before any interaction.
    func testTrashConfirmationStartsClear() {
        let (model, _) = modelWithLargestFiles([largestFile("a.zip", 10)])

        XCTAssertNil(model.pendingTrashConfirmationURL)
        XCTAssertTrue(model.trashErrorMessages.isEmpty)
    }

    /// First activation flips *that* row into the inline confirm state without trashing
    /// anything — the file is untouched until an explicit confirm.
    func testActivateArmsRowConfirmWithoutTrashing() {
        let file = largestFile("a.zip", 10)
        let (model, trasher) = modelWithLargestFiles([file])

        model.requestTrashConfirmation(for: file.url)

        XCTAssertEqual(model.pendingTrashConfirmationURL, file.url)
        XCTAssertTrue(trasher.trashRequests.isEmpty, "arming never trashes")
        XCTAssertEqual(model.largestFilesState, .available([file]), "row is still listed")
    }

    /// activate → confirm → trashed: the file is moved to the Trash (recoverable), the
    /// row is dropped from the list, and the confirm state clears.
    func testConfirmTrashesRemovesRowAndClearsConfirm() {
        let a = largestFile("a.zip", 10)
        let b = largestFile("b.mov", 20)
        let (model, trasher) = modelWithLargestFiles([a, b])

        model.requestTrashConfirmation(for: a.url)
        model.confirmTrash(for: a.url)

        XCTAssertEqual(trasher.trashRequests, [a.url], "the confirmed file was moved to Trash")
        XCTAssertNil(model.pendingTrashConfirmationURL, "confirm clears the armed state")
        XCTAssertEqual(model.largestFilesState, .available([b]), "the trashed row is gone")
        XCTAssertNil(model.trashErrorMessages[a.url], "no error on success")
    }

    /// activate → cancel → reverted: the row backs out of confirm, the file is never
    /// trashed, and the row stays in the list.
    func testCancelRevertsConfirmWithoutTrashing() {
        let file = largestFile("a.zip", 10)
        let (model, trasher) = modelWithLargestFiles([file])

        model.requestTrashConfirmation(for: file.url)
        model.cancelTrashConfirmation(for: file.url)

        XCTAssertNil(model.pendingTrashConfirmationURL, "cancel disarms the row")
        XCTAssertTrue(trasher.trashRequests.isEmpty, "cancel never trashes")
        XCTAssertEqual(model.largestFilesState, .available([file]), "row is still listed")
    }

    /// Only one row can be in the confirm state at a time: arming a second row moves the
    /// pending confirm to it (the first silently reverts).
    func testOnlyOneRowConfirmsAtATime() {
        let a = largestFile("a.zip", 10)
        let b = largestFile("b.mov", 20)
        let (model, _) = modelWithLargestFiles([a, b])

        model.requestTrashConfirmation(for: a.url)
        XCTAssertEqual(model.pendingTrashConfirmationURL, a.url)

        model.requestTrashConfirmation(for: b.url)
        XCTAssertEqual(model.pendingTrashConfirmationURL, b.url,
                       "arming a second row moves the confirm to it")
    }

    /// A confirm only fires for the currently-armed row: confirming a *different* URL
    /// (a stale/double activation) trashes nothing and leaves the real armed row intact.
    func testConfirmForUnarmedRowIsIgnored() {
        let a = largestFile("a.zip", 10)
        let b = largestFile("b.mov", 20)
        let (model, trasher) = modelWithLargestFiles([a, b])

        model.requestTrashConfirmation(for: a.url)
        model.confirmTrash(for: b.url) // b is not the armed row

        XCTAssertTrue(trasher.trashRequests.isEmpty, "an unarmed row's confirm trashes nothing")
        XCTAssertEqual(model.pendingTrashConfirmationURL, a.url, "the real armed row is untouched")
        XCTAssertEqual(model.largestFilesState, .available([a, b]))
    }

    /// A second confirm for the same row (double-activation) can't re-trash: the first
    /// confirm cleared the armed state, so the second is a no-op.
    func testDoubleConfirmDoesNotTrashTwice() {
        let a = largestFile("a.zip", 10)
        let b = largestFile("b.mov", 20)
        let (model, trasher) = modelWithLargestFiles([a, b])

        model.requestTrashConfirmation(for: a.url)
        model.confirmTrash(for: a.url)
        model.confirmTrash(for: a.url) // stale repeat

        XCTAssertEqual(trasher.trashRequests, [a.url], "the file is trashed exactly once")
        XCTAssertEqual(model.largestFilesState, .available([b]))
    }

    /// Cancelling a row that isn't the armed one can't disarm a different row's confirm.
    func testCancelForUnarmedRowLeavesArmedRowIntact() {
        let a = largestFile("a.zip", 10)
        let b = largestFile("b.mov", 20)
        let (model, _) = modelWithLargestFiles([a, b])

        model.requestTrashConfirmation(for: a.url)
        model.cancelTrashConfirmation(for: b.url) // b is not armed

        XCTAssertEqual(model.pendingTrashConfirmationURL, a.url,
                       "a stale cancel does not disarm the real armed row")
    }

    /// A successful trash reflects the freed space on the scoped volume's row
    /// (optimistic update): free bytes rise by the trashed file's size.
    func testTrashReflectsFreedSpaceOnScopedVolume() {
        let boot = bootVolume() // free 400 GB of 1 TB
        let file = largestFile("huge.bin", 50_000_000_000)
        let (model, _) = modelWithLargestFiles([file], boot: boot)

        model.requestTrashConfirmation(for: file.url)
        model.confirmTrash(for: file.url)

        guard case .loaded(let updated)? = model.rows.first(where: { $0.id == boot.mountURL }) else {
            return XCTFail("scoped boot row should still be loaded")
        }
        XCTAssertEqual(updated.freeBytes, boot.freeBytes + file.sizeBytes,
                       "freed space is credited to the scoped volume")
        XCTAssertEqual(updated.totalBytes, boot.totalBytes, "total is unchanged")
    }

    /// A trash failure (locked/permission) surfaces an inline error on the row without
    /// crashing, leaves the file in place, and keeps the row in the list.
    func testTrashErrorSurfacesInlineAndKeepsRow() {
        let file = largestFile("locked.dat", 10)
        let trasher = MockFileTrasher()
        trasher.errorToThrow = CocoaError(.fileWriteNoPermission)
        let (model, _) = modelWithLargestFiles([file], fileTrasher: trasher)

        model.requestTrashConfirmation(for: file.url)
        model.confirmTrash(for: file.url)

        XCTAssertNotNil(model.trashErrorMessages[file.url], "the failure is surfaced inline")
        XCTAssertNil(model.pendingTrashConfirmationURL, "confirm still clears the armed state")
        XCTAssertEqual(model.largestFilesState, .available([file]),
                       "a failed trash keeps the row listed")
    }

    /// Re-arming a row after a failed attempt clears the stale error so the fresh
    /// attempt starts clean.
    func testReArmingAfterErrorClearsIt() {
        let file = largestFile("locked.dat", 10)
        let trasher = MockFileTrasher()
        trasher.errorToThrow = CocoaError(.fileWriteNoPermission)
        let (model, _) = modelWithLargestFiles([file], fileTrasher: trasher)

        model.requestTrashConfirmation(for: file.url)
        model.confirmTrash(for: file.url)
        XCTAssertNotNil(model.trashErrorMessages[file.url])

        model.requestTrashConfirmation(for: file.url) // re-arm

        XCTAssertNil(model.trashErrorMessages[file.url], "re-arming clears the stale error")
        XCTAssertEqual(model.pendingTrashConfirmationURL, file.url)
    }

    /// A refresh rebuilds the section, so any pending confirm or inline error from the
    /// prior pass is cleared (it referred to the old list).
    func testRefreshClearsPendingConfirmAndErrors() {
        let file = largestFile("locked.dat", 10)
        let trasher = MockFileTrasher()
        trasher.perURLErrors[file.url] = CocoaError(.fileWriteNoPermission)
        let (model, _) = modelWithLargestFiles([file], fileTrasher: trasher)

        model.requestTrashConfirmation(for: file.url)
        model.confirmTrash(for: file.url) // records an error
        model.requestTrashConfirmation(for: file.url) // re-arm → pending set again
        XCTAssertEqual(model.pendingTrashConfirmationURL, file.url)

        model.refresh()

        XCTAssertNil(model.pendingTrashConfirmationURL, "refresh clears the pending confirm")
        XCTAssertTrue(model.trashErrorMessages.isEmpty, "refresh clears inline errors")
    }

    /// Requesting confirmation is a no-op when the section isn't showing a ranked list
    /// (nothing to trash) — a guard against a spurious call while scanning/unavailable.
    func testRequestConfirmationIsNoOpWhenNoRankedList() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load() // section is .scanning, not .available

        model.requestTrashConfirmation(for: url("/Users/me/whatever"))

        XCTAssertNil(model.pendingTrashConfirmationURL)
    }

    // MARK: - In-memory TTL cache (A2)

    /// Expected reconciled breakdown for the boot volume (1 TB / 400 GB free) given a
    /// set of Spotlight categories — the shape both the cache-paint and fresh-scan paths
    /// must produce.
    private func bootBreakdown(_ categories: CategoryBreakdown) -> StorageBreakdown {
        StorageBreakdown.reconciled(
            categories: categories,
            totalBytes: 1_000_000_000_000,
            freeBytes: 400_000_000_000
        )
    }

    /// Thrift (UX-002): a fresh cached category breakdown paints *instantly* on load AND
    /// no Spotlight scan runs for it — the scanner is never invoked. A reopen within the
    /// TTL must cost zero NSMetadataQuery work.
    func testFreshCachedCategoriesPaintInstantlyAndSkipTheScan() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let cached: CategoryBreakdown = .available(apps: 100_000_000_000, media: 0, other: 0)
        cache.storeCategories(cached, forVolumeAt: url("/"))

        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner, cache: cache)
        model.load()

        // Instant paint: the cached breakdown is shown right away, not a scanning flash.
        XCTAssertEqual(model.categoryStates[url("/")], .breakdown(bootBreakdown(cached)),
                       "a fresh cached breakdown paints immediately on load")
        // Thrift: the fresh cache skips the scan entirely — no Spotlight work at all.
        XCTAssertTrue(scanner.scanRequests.isEmpty,
                      "a fresh cache skips the Spotlight scan — zero NSMetadataQuery work")
        XCTAssertEqual(scanner.cancelCount, 0)
    }

    /// Thrift + multiple volumes: a fresh-cached volume is settled without a scan, and the
    /// scan walk does not stall on it — a *second*, stale-cached volume still scans. The
    /// cache-painted volume never occupies the single in-flight scan slot.
    func testFreshCachedVolumeDoesNotStallScanOfStaleSibling() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        // Boot volume is freshly cached; the second (Data) volume is not cached at all.
        let cachedBoot: CategoryBreakdown = .available(apps: 1, media: 2, other: 3)
        cache.storeCategories(cachedBoot, forVolumeAt: url("/"))

        let scanner = MockCategoryScanner()
        let second = loaded("Data", path: "/Volumes/Data", total: 500, free: 100)
        let model = makeModel(internalVolumes: [bootVolume(), second], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner, cache: cache)
        model.load()

        // Boot painted from cache with no scan; the walk advanced straight to Data, which
        // has no cache and so is the only volume that scans.
        XCTAssertEqual(model.categoryStates[url("/")], .breakdown(bootBreakdown(cachedBoot)),
                       "the fresh-cached boot volume paints from cache")
        XCTAssertEqual(scanner.scanRequests, [url("/Volumes/Data")],
                       "only the uncached sibling scans; the cached boot volume did not")
        XCTAssertEqual(model.categoryStates[url("/Volumes/Data")], .scanning)
    }

    /// A stale cached category breakdown (past the TTL) is ignored: the volume shows the
    /// normal `.scanning` placeholder, exactly as if the cache were empty.
    func testStaleCachedCategoriesAreIgnored() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        cache.storeCategories(.available(apps: 1, media: 2, other: 3), forVolumeAt: url("/"))
        clock.advance(120) // past the TTL

        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner, cache: cache)
        model.load()

        XCTAssertEqual(model.categoryStates[url("/")], .scanning,
                       "a stale cache entry is ignored — the volume scans fresh")
        XCTAssertEqual(scanner.scanRequests, [url("/")],
                       "a stale cache triggers a real Spotlight scan")
    }

    /// A completed category scan writes its raw result into the cache, so a *subsequent*
    /// model (the next popover open) paints it instantly.
    func testCompletedCategoryScanPopulatesCacheForNextOpen() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)

        // First "open": scan and deliver.
        let scanner1 = MockCategoryScanner()
        let model1 = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                               resolver: MockDeferredVolumeResolver(), scanner: scanner1, cache: cache)
        model1.load()
        let delivered: CategoryBreakdown = .available(apps: 50_000_000_000, media: 0, other: 0)
        scanner1.deliver(delivered)

        // Second "open" a moment later: a fresh model sharing the same cache paints the
        // stored breakdown instantly (no scanning flash) and — thrift — runs no scan.
        clock.advance(10)
        let scanner2 = MockCategoryScanner()
        let model2 = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                               resolver: MockDeferredVolumeResolver(), scanner: scanner2, cache: cache)
        model2.load()

        XCTAssertEqual(model2.categoryStates[url("/")], .breakdown(bootBreakdown(delivered)),
                       "the next open paints the previous scan's cached breakdown instantly")
        XCTAssertTrue(scanner2.scanRequests.isEmpty,
                      "the next open within the TTL does no Spotlight work (thrift)")
    }

    /// Thrift (UX-002): a fresh cached largest-files list paints instantly on load AND no
    /// Spotlight scan runs for it — the largest-files scanner is never invoked.
    func testFreshCachedLargestFilesPaintInstantlyAndSkipTheScan() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let cachedFiles = [largestFile("cached.zip", 9_000)]
        cache.storeLargestFiles(.available(cachedFiles), forVolumeAt: url("/"))

        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(),
                              largestFilesScanner: largest, cache: cache)
        model.load()

        XCTAssertEqual(model.largestFilesState, .available(cachedFiles),
                       "a fresh cached list paints immediately, no scanning state")
        XCTAssertTrue(largest.scanRequests.isEmpty,
                      "a fresh cache skips the largest-files scan — zero Spotlight work")
    }

    /// Thrift: a fresh cached *unavailable* largest-files entry paints the degraded state
    /// instantly and still skips the scan — the "Not indexed" story is served from cache.
    func testFreshCachedUnavailableLargestFilesPaintsAndSkipsScan() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        cache.storeLargestFiles(.unavailable, forVolumeAt: url("/"))

        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(),
                              largestFilesScanner: largest, cache: cache)
        model.load()

        XCTAssertEqual(model.largestFilesState, .unavailable,
                       "a fresh cached unavailable state paints from cache")
        XCTAssertTrue(largest.scanRequests.isEmpty,
                      "a fresh cache skips the scan even for the unavailable state")
    }

    /// A completed largest-files scan populates the cache for the next open.
    func testCompletedLargestFilesScanPopulatesCacheForNextOpen() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)

        let largest1 = ReplayableLargestFilesScanner()
        let model1 = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                               resolver: MockDeferredVolumeResolver(),
                               largestFilesScanner: largest1, cache: cache)
        model1.load()
        let files = [largestFile("keep.zip", 7_000)]
        largest1.deliver(.available(files))

        clock.advance(10)
        let largest2 = ReplayableLargestFilesScanner()
        let model2 = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                               resolver: MockDeferredVolumeResolver(),
                               largestFilesScanner: largest2, cache: cache)
        model2.load()

        XCTAssertEqual(model2.largestFilesState, .available(files),
                       "the next open paints the previous scan's cached list instantly")
        XCTAssertTrue(largest2.scanRequests.isEmpty,
                      "the next open within the TTL does no Spotlight work (thrift)")
    }

    /// Trashing a file keeps the cache consistent: the next open's instant paint does not
    /// resurrect the just-trashed row.
    func testTrashUpdatesCacheSoNextOpenDoesNotResurrectRow() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let keep = largestFile("keep.zip", 5_000)
        let doomed = largestFile("doomed.zip", 9_000)

        let largest1 = ReplayableLargestFilesScanner()
        let model1 = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                               resolver: MockDeferredVolumeResolver(),
                               largestFilesScanner: largest1, cache: cache)
        model1.load()
        largest1.deliver(.available([doomed, keep]))

        model1.requestTrashConfirmation(for: doomed.url)
        model1.confirmTrash(for: doomed.url)
        XCTAssertEqual(model1.largestFilesState, .available([keep]), "doomed row is gone")

        // Next open: the cache reflects the removal — the trashed row does not come back.
        clock.advance(5)
        let largest2 = ReplayableLargestFilesScanner()
        let model2 = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                               resolver: MockDeferredVolumeResolver(),
                               largestFilesScanner: largest2, cache: cache)
        model2.load()
        XCTAssertEqual(model2.largestFilesState, .available([keep]),
                       "the cache is consistent with the trash — no resurrected row")
    }

    // MARK: - Refresh bypasses the thrift cache (UX-002 / VOL-005)

    /// Refresh must ALWAYS force a full re-scan regardless of cache freshness. Even with a
    /// fresh cached category breakdown that `load()` would serve from cache without
    /// scanning, `refresh()` runs a real Spotlight scan for the category data.
    func testRefreshForcesCategoryRescanEvenWhenCacheFresh() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let cached: CategoryBreakdown = .available(apps: 100_000_000_000, media: 0, other: 0)
        cache.storeCategories(cached, forVolumeAt: url("/"))

        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner, cache: cache)

        // A normal open serves from cache and does NOT scan (thrift).
        model.load()
        XCTAssertTrue(scanner.scanRequests.isEmpty, "the fresh cache skips the scan on load")
        XCTAssertEqual(model.categoryStates[url("/")], .breakdown(bootBreakdown(cached)))

        // Refresh forces a real scan even though the cache is still fresh (clock unmoved).
        model.refresh()
        XCTAssertEqual(scanner.scanRequests, [url("/")],
                       "refresh always re-scans, bypassing the fresh cache")
        XCTAssertEqual(model.categoryStates[url("/")], .scanning,
                       "refresh clears to scanning and runs a fresh scan, not the cached paint")

        // The forced scan resolves and rewrites the cache with the fresh data.
        let refreshed: CategoryBreakdown = .available(apps: 0, media: 200_000_000_000, other: 0)
        scanner.deliver(refreshed)
        XCTAssertEqual(model.categoryStates[url("/")], .breakdown(bootBreakdown(refreshed)),
                       "the forced scan's result replaces the cached breakdown")
    }

    /// Refresh forces a largest-files re-scan too, even when a fresh cached list exists
    /// that `load()` would have served without scanning.
    func testRefreshForcesLargestFilesRescanEvenWhenCacheFresh() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let cachedFiles = [largestFile("cached.zip", 9_000)]
        cache.storeLargestFiles(.available(cachedFiles), forVolumeAt: url("/"))

        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(),
                              largestFilesScanner: largest, cache: cache)

        model.load()
        XCTAssertTrue(largest.scanRequests.isEmpty, "the fresh cache skips the scan on load")
        XCTAssertEqual(model.largestFilesState, .available(cachedFiles))

        model.refresh()
        XCTAssertEqual(largest.scanRequests.map(\.url), [url("/")],
                       "refresh always re-scans the largest files, bypassing the fresh cache")
        XCTAssertEqual(model.largestFilesState, .scanning,
                       "refresh resets the section to scanning and runs a fresh scan")

        let fresh = [largestFile("fresh.mov", 8_000)]
        largest.deliver(.available(fresh))
        XCTAssertEqual(model.largestFilesState, .available(fresh),
                       "the forced scan's result replaces the cached list")
    }

    /// A *second* normal `load()` after a forced refresh (once the refresh's scan wrote
    /// the cache) goes back to serving from cache — refresh forces one pass, it does not
    /// permanently disable the cache.
    func testLoadAfterRefreshServesFromCacheAgain() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        cache.storeCategories(.available(apps: 1, media: 1, other: 1), forVolumeAt: url("/"))

        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), scanner: scanner, cache: cache)
        model.refresh() // forced: scans and rewrites the cache
        let refreshed: CategoryBreakdown = .available(apps: 9, media: 9, other: 9)
        scanner.deliver(refreshed)
        XCTAssertEqual(scanner.scanRequests, [url("/")])

        model.load() // normal open: cache is fresh again → no new scan
        XCTAssertEqual(scanner.scanRequests, [url("/")],
                       "a normal open after refresh serves from cache; no second scan")
        XCTAssertEqual(model.categoryStates[url("/")], .breakdown(bootBreakdown(refreshed)),
                       "it paints the freshly-scanned cached breakdown")
    }

    // MARK: - Enumeration always runs, even on a fresh cache (UX-002)

    /// The thrift cache covers only the Spotlight-backed data. Volume enumeration
    /// (free/used via statfs) is cheap and must STILL run on every open so sizes are
    /// current — even when the category/largest-files caches are fresh and their scans are
    /// skipped. Here enumeration returns changed sizes on the second open; the rows must
    /// reflect the new sizes despite both caches being fresh (no scan runs).
    func testEnumerationStillRunsWhenSpotlightCacheIsFresh() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        cache.storeCategories(.available(apps: 1, media: 1, other: 1), forVolumeAt: url("/"))
        cache.storeLargestFiles(.available([largestFile("c.zip", 1)]), forVolumeAt: url("/"))

        let scanner = MockCategoryScanner()
        let largest = ReplayableLargestFilesScanner()
        // Enumeration yields different free bytes on each call — statfs re-read every open.
        let firstBoot = bootVolume() // free 400 GB
        let secondBoot = Volume(name: "Macintosh HD", mountURL: url("/"),
                                totalBytes: 1_000_000_000_000, freeBytes: 250_000_000_000,
                                kind: .internal, bsdName: "disk3s5")
        var snapshots = [
            VolumeEnumerator.Snapshot(internalVolumes: [firstBoot], deferredVolumes: []),
            VolumeEnumerator.Snapshot(internalVolumes: [secondBoot], deferredVolumes: []),
        ]
        let model = VolumeListViewModel(
            enumerate: { snapshots.removeFirst() },
            resolver: MockDeferredVolumeResolver(),
            scanner: scanner,
            largestFilesScanner: largest,
            cache: cache
        )

        model.load()
        XCTAssertEqual(model.rows, [.loaded(firstBoot)], "first open enumerates the first sizes")

        model.load()
        XCTAssertEqual(model.rows, [.loaded(secondBoot)],
                       "the second open re-enumerates: sizes update even though caches are fresh")
        // The Spotlight caches are fresh, so neither scanner ever ran across both opens.
        XCTAssertTrue(scanner.scanRequests.isEmpty,
                      "a fresh category cache means no Spotlight category scan on either open")
        XCTAssertTrue(largest.scanRequests.isEmpty,
                      "a fresh largest-files cache means no Spotlight largest-files scan")
    }

    // MARK: - Progressive largest-files partials (A2)

    /// A progressive partial delivered while scanning publishes `.scanning(partial:)` with
    /// the best-so-far list, largest-first as the scanner delivered it.
    func testProgressivePartialPublishesScanningPartial() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()
        XCTAssertEqual(model.largestFilesState, .scanning, "starts empty-scanning")

        let firstBatch = [largestFile("huge.zip", 9_000)]
        largest.deliverPartial(firstBatch)
        XCTAssertEqual(model.largestFilesState, .scanning(partial: firstBatch),
                       "the best-so-far is published as a scanning partial")

        // A second, larger partial (more files, still largest-first) supersedes the first.
        let secondBatch = [largestFile("huge.zip", 9_000), largestFile("big.mov", 5_000)]
        largest.deliverPartial(secondBatch)
        XCTAssertEqual(model.largestFilesState, .scanning(partial: secondBatch),
                       "a later partial replaces the earlier best-so-far")

        // The final result then supersedes the partials.
        largest.deliver(.available(secondBatch))
        XCTAssertEqual(model.largestFilesState, .available(secondBatch),
                       "the final result supersedes the last partial")
    }

    /// Partials are ordered exactly as the scanner delivers them (largest-first); the
    /// model does not reorder — the scanner already ranks.
    func testProgressivePartialPreservesLargestFirstOrder() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()

        let ordered = [largestFile("a", 9_000), largestFile("b", 5_000), largestFile("c", 1_000)]
        largest.deliverPartial(ordered)

        guard case .scanning(let partial) = model.largestFilesState else {
            return XCTFail("expected a scanning partial")
        }
        XCTAssertEqual(partial, ordered, "partial preserves the scanner's largest-first order")
    }

    /// A stale-generation partial (from a scan superseded by refresh) is dropped and does
    /// not overwrite the fresh pass's scanning state.
    func testStaleGenerationPartialIsDropped() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()    // scan index 0 = generation 1
        model.refresh() // generation 2: cancels + rescans → scan index 1
        XCTAssertEqual(model.largestFilesState, .scanning)

        // A late partial from the superseded generation-1 scan must be dropped.
        largest.deliverPartial([largestFile("stale", 999)], toScanAt: 0)
        XCTAssertEqual(model.largestFilesState, .scanning,
                       "a stale-generation partial does not overwrite the fresh scan")

        // The fresh (index 1) scan's partials still land.
        let fresh = [largestFile("fresh", 1)]
        largest.deliverPartial(fresh, toScanAt: 1)
        XCTAssertEqual(model.largestFilesState, .scanning(partial: fresh),
                       "the current-generation partial is published")
    }

    /// A partial never overwrites a final `.available` — once the result lands, later
    /// partials (e.g. a race with teardown) are ignored so the list can't flicker shorter.
    func testPartialAfterFinalResultIsIgnored() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()

        let finalFiles = [largestFile("a", 9), largestFile("b", 5)]
        largest.deliver(.available(finalFiles))
        XCTAssertEqual(model.largestFilesState, .available(finalFiles))

        // A late partial with fewer files must not shrink the finished list.
        largest.deliverPartial([largestFile("a", 9)])
        XCTAssertEqual(model.largestFilesState, .available(finalFiles),
                       "a partial after the final result is ignored")
    }

    /// Thrift: when a fresh cached list paints instantly (`.available`), no scan runs, so
    /// no partial can ever arrive to shrink it — the shown list stays put and the scanner
    /// is never invoked. (This is the thrift counterpart of the old "partial doesn't
    /// overwrite the cached list" guard: under thrift the guard is moot because there is
    /// no background scan producing partials at all.)
    func testFreshCachedListSkipsScanSoNoPartialCanShrinkIt() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let cachedFiles = [largestFile("cached1", 9), largestFile("cached2", 5)]
        cache.storeLargestFiles(.available(cachedFiles), forVolumeAt: url("/"))

        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(),
                              largestFilesScanner: largest, cache: cache)
        model.load()

        XCTAssertEqual(model.largestFilesState, .available(cachedFiles), "cached list painted")
        XCTAssertTrue(largest.scanRequests.isEmpty,
                      "no scan runs for a fresh cache, so no partial can shrink the list")
    }

    /// A size-floor cascade descent restarts gathering from empty at a lower floor, so a
    /// fresh floor's early progress tick can report a SUBSET of the prior floor's list.
    /// That shrinking partial must not replace the larger one already shown — the visible
    /// list never flickers shorter mid-scan.
    func testProgressivePartialDoesNotShrinkAcrossCascadeDescent() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()

        // High-floor gather delivered three files.
        let highFloor = [largestFile("A", 200), largestFile("B", 150), largestFile("C", 120)]
        largest.deliverPartial(highFloor)
        XCTAssertEqual(model.largestFilesState, .scanning(partial: highFloor))

        // Cascade descends: the fresh lower-floor query's first tick has only two files so
        // far — a subset. It must be dropped, not published.
        largest.deliverPartial([largestFile("A", 200), largestFile("B", 150)])
        XCTAssertEqual(model.largestFilesState, .scanning(partial: highFloor),
                       "a cross-floor subset partial does not shrink the shown list")

        // Once the lower floor catches up and surpasses the prior list, it publishes again.
        let grown = [largestFile("A", 200), largestFile("B", 150), largestFile("C", 120),
                     largestFile("D", 90)]
        largest.deliverPartial(grown)
        XCTAssertEqual(model.largestFilesState, .scanning(partial: grown),
                       "a strictly larger partial resumes publishing")
    }

    /// A same-count partial whose top-N improved (bigger files in the same slots) does
    /// replace the shown one, but a same-count partial that got smaller/equal in total is
    /// dropped — the monotonic guard keys off count then total bytes, not identity.
    func testProgressivePartialImprovesOnSameCountLargerTotalOnly() {
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(), largestFilesScanner: largest)
        model.load()

        let base = [largestFile("A", 100), largestFile("B", 50)]
        largest.deliverPartial(base)
        XCTAssertEqual(model.largestFilesState, .scanning(partial: base))

        // Same count, larger total (a bigger file displaced a smaller one) → improves.
        let improved = [largestFile("A", 100), largestFile("X", 80)]
        largest.deliverPartial(improved)
        XCTAssertEqual(model.largestFilesState, .scanning(partial: improved))

        // Same count, smaller total → a regression, dropped.
        largest.deliverPartial([largestFile("A", 100), largestFile("Y", 10)])
        XCTAssertEqual(model.largestFilesState, .scanning(partial: improved),
                       "a same-count smaller-total partial does not replace the shown list")
    }

    // MARK: - Monotonic partial guard (pure)

    func testPartialImprovesGrowsWithMoreFiles() {
        let one = [largestFile("A", 100)]
        let two = [largestFile("A", 100), largestFile("B", 50)]
        XCTAssertTrue(VolumeListViewModel.partialImproves(two, over: one), "more files improves")
        XCTAssertFalse(VolumeListViewModel.partialImproves(one, over: two), "fewer files regresses")
    }

    func testPartialImprovesOnLargerTotalAtEqualCount() {
        let smaller = [largestFile("A", 100), largestFile("B", 50)]
        let larger = [largestFile("A", 100), largestFile("B", 90)]
        XCTAssertTrue(VolumeListViewModel.partialImproves(larger, over: smaller),
                      "same count, larger total improves")
        XCTAssertFalse(VolumeListViewModel.partialImproves(smaller, over: larger),
                       "same count, smaller total regresses")
        XCTAssertFalse(VolumeListViewModel.partialImproves(smaller, over: smaller),
                       "an identical partial is not an improvement")
    }

    func testPartialImprovesFromEmpty() {
        XCTAssertTrue(VolumeListViewModel.partialImproves([largestFile("A", 1)], over: []),
                      "any nonempty partial improves over the empty best-so-far")
        XCTAssertFalse(VolumeListViewModel.partialImproves([], over: []),
                       "an empty partial over empty is not an improvement")
    }

    // MARK: - Hide / un-hide largest files (UX-015)

    /// Hiding a row drops it from the visible list, persists it to the store, and moves it
    /// into the reconstructed hidden set — so the section stops showing it immediately.
    func testHideRemovesRowFromVisibleListAndPersists() {
        let a = largestFile("a.zip", 30)
        let b = largestFile("b.mov", 20)
        let store = MockHiddenFilesStore()
        let (model, _) = modelWithLargestFiles([a, b], hiddenFilesStore: store)

        model.hide(a.url)

        XCTAssertEqual(model.largestFilesState, .available([b]), "the hidden row is gone from the list")
        XCTAssertTrue(store.isHidden(a.path), "the choice is persisted to the store")
        XCTAssertEqual(model.hiddenLargestFiles, [a], "the hidden row is reconstructable")
        XCTAssertEqual(model.hiddenLargestFilesCount, 1)
    }

    /// A path already in the store at load time is filtered out of the very first published
    /// list — the "hidden survives across sessions" guarantee, seen from the model's side.
    func testHiddenPathIsFilteredOnFirstScanDelivery() {
        let a = largestFile("a.zip", 30)
        let b = largestFile("b.mov", 20)
        let store = MockHiddenFilesStore(hidden: [a.path])
        let (model, _) = modelWithLargestFiles([a, b], hiddenFilesStore: store)

        XCTAssertEqual(model.largestFilesState, .available([b]),
                       "a pre-hidden path never appears in the delivered list")
        XCTAssertEqual(model.hiddenLargestFiles, [a])
    }

    /// A pre-hidden path is also filtered out of progressive best-so-far partials, not just
    /// the final list — the section never flashes a hidden row while scanning.
    func testHiddenPathIsFilteredFromProgressivePartials() {
        let a = largestFile("a.zip", 30)
        let b = largestFile("b.mov", 20)
        let store = MockHiddenFilesStore(hidden: [a.path])
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(),
                              largestFilesScanner: largest, hiddenFilesStore: store)
        model.load()

        largest.deliverPartial([a, b])

        XCTAssertEqual(model.largestFilesState, .scanning(partial: [b]),
                       "a hidden path is filtered from the progressive partial too")
    }

    /// Un-hiding a row restores it to the visible list in its ranked place and clears it
    /// from the hidden set.
    func testUnhideRestoresRowToVisibleList() {
        let a = largestFile("a.zip", 30)
        let b = largestFile("b.mov", 20)
        let store = MockHiddenFilesStore(hidden: [a.path])
        let (model, _) = modelWithLargestFiles([a, b], hiddenFilesStore: store)
        XCTAssertEqual(model.largestFilesState, .available([b]))

        model.unhide(a.url)

        XCTAssertEqual(model.largestFilesState, .available([a, b]),
                       "the un-hidden row returns in its ranked place")
        XCTAssertFalse(store.isHidden(a.path), "the store no longer hides it")
        XCTAssertTrue(model.hiddenLargestFiles.isEmpty)
    }

    /// Clearing hidden files brings every hidden row back at once and empties the store.
    func testClearHiddenFilesRestoresEverything() {
        let a = largestFile("a.zip", 30)
        let b = largestFile("b.mov", 20)
        let c = largestFile("c.dmg", 10)
        let store = MockHiddenFilesStore(hidden: [a.path, c.path])
        let (model, _) = modelWithLargestFiles([a, b, c], hiddenFilesStore: store)
        XCTAssertEqual(model.largestFilesState, .available([b]))

        model.clearHiddenFiles()

        XCTAssertEqual(model.largestFilesState, .available([a, b, c]),
                       "every hidden row returns in ranked order")
        XCTAssertTrue(store.hiddenPaths.isEmpty)
        XCTAssertEqual(model.hiddenLargestFilesCount, 0)
    }

    /// Hiding the currently-armed Trash row disarms the confirm and clears its error —
    /// hiding is a clean exit from the row's interactions, never a dangling confirm.
    func testHideDisarmsPendingTrashConfirmOnThatRow() {
        let a = largestFile("a.zip", 30)
        let b = largestFile("b.mov", 20)
        let (model, trasher) = modelWithLargestFiles([a, b])

        model.requestTrashConfirmation(for: a.url)
        XCTAssertEqual(model.pendingTrashConfirmationURL, a.url)

        model.hide(a.url)

        XCTAssertNil(model.pendingTrashConfirmationURL, "hiding the armed row disarms its confirm")
        XCTAssertTrue(trasher.trashRequests.isEmpty, "hiding never trashes")
        XCTAssertEqual(model.largestFilesState, .available([b]))
    }

    /// A hidden row that is then trashed (via the hidden affordance is out of scope, but the
    /// raw list must stay consistent): trashing a *visible* row removes it from both the
    /// visible list and the raw list, so it can't resurface via the hidden reconstruction.
    func testTrashedRowDoesNotResurfaceInHiddenReconstruction() {
        let a = largestFile("a.zip", 30)
        let b = largestFile("b.mov", 20)
        let store = MockHiddenFilesStore(hidden: [b.path])
        let (model, _) = modelWithLargestFiles([a, b], hiddenFilesStore: store)
        XCTAssertEqual(model.largestFilesState, .available([a]), "b starts hidden")

        model.requestTrashConfirmation(for: a.url)
        model.confirmTrash(for: a.url)

        XCTAssertEqual(model.largestFilesState, .available([]), "the trashed visible row is gone")
        XCTAssertEqual(model.hiddenLargestFiles, [b], "the still-hidden row is untouched")
    }

    /// Hiding is a no-op when the section isn't showing a list (nothing to hide) — a guard
    /// against a spurious call while scanning-with-no-partial or unavailable.
    func testHideIsNoOpWhenNoList() {
        let store = MockHiddenFilesStore()
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(),
                              largestFilesScanner: largest, hiddenFilesStore: store)
        model.load()
        largest.deliver(.unavailable) // section is .unavailable — no list

        model.hide(url("/Users/me/whatever"))

        XCTAssertTrue(store.hiddenPaths.isEmpty, "hiding is ignored when there is no list")
        XCTAssertEqual(model.largestFilesState, .unavailable)
    }

    /// A refresh re-applies the persisted hidden set to the fresh scan — a row hidden in a
    /// prior pass stays hidden after Refresh.
    func testHiddenPathStaysHiddenAcrossRefresh() {
        let a = largestFile("a.zip", 30)
        let b = largestFile("b.mov", 20)
        let store = MockHiddenFilesStore()
        let largest = ReplayableLargestFilesScanner()
        let model = makeModel(internalVolumes: [bootVolume()], deferredVolumes: [],
                              resolver: MockDeferredVolumeResolver(),
                              largestFilesScanner: largest, hiddenFilesStore: store)
        model.load()
        largest.deliver(.available([a, b]))
        model.hide(a.url)
        XCTAssertEqual(model.largestFilesState, .available([b]))

        model.refresh()
        largest.deliver(.available([a, b])) // the fresh scan returns the full list again

        XCTAssertEqual(model.largestFilesState, .available([b]),
                       "the hidden path is re-filtered after a refresh")
    }
}
