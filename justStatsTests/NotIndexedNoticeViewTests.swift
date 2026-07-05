import XCTest
@testable import justStats

/// SCAN-005: the "Not indexed" degraded state. A volume whose Spotlight index is
/// unusable must show the degraded notice instead of a misleading empty/zero bar
/// (TECHSPEC §4). The SwiftUI rendering itself has no host in unit tests, so — as
/// with `CategoryBarView` — the piece that must be exactly right is the pure
/// state → presentation mapping (`VolumeRowView.Content`), covered here. An
/// end-to-end model test drives a mock scanner from `.unavailable`/`.available`
/// through to the state that selects that content, so "unavailable → notice,
/// available → bar" is verified through the real wiring, not just in isolation.
final class NotIndexedNoticeViewTests: XCTestCase {
    // MARK: - Pure state → row-content mapping

    /// An unavailable index selects the degraded notice — never a bar, never the
    /// plain usage bar (which would imply a real breakdown was computed).
    func testNotIndexedStateSelectsTheDegradedNotice() {
        let content = VolumeRowView.Content(categoryState: .notIndexed)
        XCTAssertEqual(content, .notIndexedNotice)
    }

    /// A resolved breakdown selects the category bar, carrying that exact breakdown.
    func testBreakdownStateSelectsTheCategoryBar() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .available(apps: 100, media: 200, other: 50),
            totalBytes: 1000,
            freeBytes: 400
        )
        let content = VolumeRowView.Content(categoryState: .breakdown(breakdown))
        XCTAssertEqual(content, .categoryBar(breakdown))
    }

    /// A scan still in flight falls back to the plain usage bar — no notice, no
    /// fabricated segments while the result is pending.
    func testScanningStateFallsBackToTheUsageBar() {
        let content = VolumeRowView.Content(categoryState: .scanning)
        XCTAssertEqual(content, .usageBar)
    }

    /// No recorded state yet (row loaded before its scan started) also falls back
    /// to the plain usage bar.
    func testNilStateFallsBackToTheUsageBar() {
        let content = VolumeRowView.Content(categoryState: nil)
        XCTAssertEqual(content, .usageBar)
    }

    // MARK: - Notice content

    /// The notice text is exactly the TECHSPEC §4 degraded-state wording — asserted
    /// so a wording drift is caught, not just "some string".
    func testNoticeMessageMatchesTechspecWording() {
        XCTAssertEqual(
            NotIndexedNoticeView.message,
            "Not indexed — category breakdown unavailable"
        )
    }

    // MARK: - End-to-end through the model wiring

    /// Mock scanner returns `.unavailable` for a *non-boot* volume → the row content
    /// resolves to the degraded "Not indexed" notice. Drives the real view-model →
    /// state → content path so the presentation decision is verified through the
    /// wiring, per the task DOD. (An unavailable index on the boot volume instead
    /// takes the SCAN-006 Full Disk Access path — covered in its own test file.)
    @MainActor
    func testUnavailableScanDrivesTheRowToTheNotIndexedNotice() {
        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [dataVolume()], scanner: scanner)
        model.load()

        scanner.deliver(.unavailable)

        let content = VolumeRowView.Content(categoryState: model.categoryStates[dataURL])
        XCTAssertEqual(content, .notIndexedNotice,
                       "an unavailable Spotlight index shows the degraded notice, not a bar")
    }

    /// Mock scanner returns an available breakdown → the volume's row content
    /// resolves to the category bar. The available and unavailable paths diverge
    /// only at the scan result, so this is the positive counterpart of the above.
    @MainActor
    func testAvailableScanDrivesTheRowToTheCategoryBar() {
        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [dataVolume()], scanner: scanner)
        model.load()

        scanner.deliver(.available(apps: 100_000_000_000,
                                   media: 200_000_000_000,
                                   other: 50_000_000_000))

        let content = VolumeRowView.Content(categoryState: model.categoryStates[dataURL])
        if case .categoryBar = content {
            // expected
        } else {
            XCTFail("an available Spotlight index shows the category bar, got \(content)")
        }
    }

    /// One volume being "Not indexed" leaves other volumes' breakdowns intact — the
    /// degraded state is strictly per-row (task DOD: "other volumes unaffected").
    /// Both volumes here are non-boot so the "not indexed" slot stays SCAN-005's
    /// generic path (the boot volume's unavailable index is SCAN-006's, not this).
    @MainActor
    func testNotIndexedVolumeDoesNotAffectAnotherVolumesBar() {
        let scanner = MockCategoryScanner()
        let second = Volume(
            name: "Media", mountURL: url("/Volumes/Media"),
            totalBytes: 500_000_000_000, freeBytes: 100_000_000_000,
            kind: .external, bsdName: "disk5s1"
        )
        let model = makeModel(internalVolumes: [dataVolume(), second], scanner: scanner)
        model.load()

        // First volume: no index. Its result advances the queue to the second.
        scanner.deliver(.unavailable)
        // Second volume: a real breakdown.
        scanner.deliver(.available(apps: 50_000_000_000, media: 60_000_000_000, other: 70_000_000_000))

        let firstContent = VolumeRowView.Content(categoryState: model.categoryStates[dataURL])
        let secondContent = VolumeRowView.Content(categoryState: model.categoryStates[url("/Volumes/Media")])

        XCTAssertEqual(firstContent, .notIndexedNotice)
        if case .categoryBar = secondContent {
            // expected — the second volume's bar is unaffected by the first's degraded state
        } else {
            XCTFail("the indexed volume still shows its bar, got \(secondContent)")
        }
    }

    // MARK: - Fixtures

    private let bootURL = URL(fileURLWithPath: "/", isDirectory: true)
    /// A non-boot volume, used for the SCAN-005 "Not indexed" path — an unavailable
    /// index here is a genuinely unindexed drive, distinct from the boot volume's
    /// permissions-shaped case (SCAN-006).
    private let dataURL = URL(fileURLWithPath: "/Volumes/Data", isDirectory: true)

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private func bootVolume() -> Volume {
        Volume(
            name: "Macintosh HD",
            mountURL: bootURL,
            totalBytes: 1_000_000_000_000,
            freeBytes: 400_000_000_000,
            kind: .internal,
            bsdName: "disk3s5"
        )
    }

    private func dataVolume() -> Volume {
        Volume(
            name: "Data",
            mountURL: dataURL,
            totalBytes: 500_000_000_000,
            freeBytes: 100_000_000_000,
            kind: .external,
            bsdName: "disk4s1"
        )
    }

    @MainActor
    private func makeModel(
        internalVolumes: [Volume]? = nil,
        scanner: MockCategoryScanner
    ) -> VolumeListViewModel {
        let snapshot = VolumeEnumerator.Snapshot(
            internalVolumes: internalVolumes ?? [bootVolume()],
            deferredVolumes: []
        )
        return VolumeListViewModel(
            enumerate: { snapshot },
            resolver: MockDeferredVolumeResolver(),
            scanner: scanner,
            // Inert largest-files scanner keeps load() hermetic (ACT-001): these tests
            // exercise the category-bar/notice path, not the largest-files section.
            largestFilesScanner: MockLargestFilesScanner()
        )
    }
}
