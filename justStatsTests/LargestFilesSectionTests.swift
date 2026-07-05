import XCTest
@testable import justStats

/// A3 (progressive/cached largest-files UI): the section renders the model's
/// `LargestFilesState` — including the progressive `.scanning(partial:)` state — into
/// best-so-far rows, a loading spinner, the final list, or the "Not indexed" notice.
/// The SwiftUI rendering has no unit-test host, so — exactly like `VolumeRowView.Content`
/// and the accessibility-label functions — the piece that must be right is the pure
/// state → presentation mapping (`LargestFilesSection.Presentation`) plus the caption
/// wording, both covered here. A view-model-driven test then drives a real scan lifecycle
/// (empty-scanning → partial → final) through the wiring so the transitions are verified
/// end to end, not just in isolation.
final class LargestFilesSectionTests: XCTestCase {
    private typealias Presentation = LargestFilesSection.Presentation

    // MARK: - Pure state → presentation mapping

    /// The pre-scan `.idle` state renders nothing — no scoped volume, so the section is
    /// hidden entirely (never a bare header).
    func testIdleStateIsHidden() {
        XCTAssertEqual(Presentation(state: .idle), .hidden)
    }

    /// A scan in flight with *no* partial gathered yet is the plain loading spinner, not a
    /// "0 found" caption over an empty list — the section explains itself while it waits.
    func testEmptyScanningStateIsLoading() {
        XCTAssertEqual(Presentation(state: .scanning), .loading)
        XCTAssertEqual(Presentation(state: .scanning(partial: [])), .loading)
    }

    /// A scan in flight with a non-empty best-so-far shows those rows progressively (A2/A3)
    /// — the partial carries straight through to `.scanning`, so the rows render AS THEY
    /// COME beneath the "Scanning… N found" caption instead of a blank spinner.
    func testNonEmptyScanningStateShowsProgressiveRows() {
        let partial = [file("a.mov", 9), file("b.zip", 4)]
        XCTAssertEqual(Presentation(state: .scanning(partial: partial)), .scanning(partial))
    }

    /// The final ranked list maps straight to `.available` with the same files — the
    /// progressive partial and the final list render through the identical row builder.
    func testAvailableStateShowsTheFinalList() {
        let files = [file("a.mov", 9), file("b.zip", 4)]
        XCTAssertEqual(Presentation(state: .available(files)), .available(files))
    }

    /// An indexed volume with no rankable file is still `.available`, with an empty list —
    /// the section shows its "No large files found" line, distinct from the not-indexed
    /// notice (the view branches on `files.isEmpty` inside the available case).
    func testEmptyAvailableStateStaysAvailable() {
        XCTAssertEqual(Presentation(state: .available([])), .available([]))
    }

    /// An unavailable Spotlight index maps to the "Not indexed" notice — never an empty
    /// list that would read as "no large files" (the SCAN-005 story, reused here).
    func testUnavailableStateIsNotIndexed() {
        XCTAssertEqual(Presentation(state: .unavailable), .notIndexed)
    }

    // MARK: - Progressive-scan caption wording

    /// The visible caption reads "Scanning… N found" with the live count — asserted so a
    /// wording or count-formatting drift is caught, not just "some string".
    func testScanningCaptionShowsLiveFoundCount() {
        XCTAssertEqual(LargestFilesScanningCaption.captionText(foundCount: 0), "Scanning… 0 found")
        XCTAssertEqual(LargestFilesScanningCaption.captionText(foundCount: 3), "Scanning… 3 found")
    }

    /// The spoken caption spells the state out for VoiceOver ("N found so far") rather than
    /// reading the ellipsis glyph — the "still gathering" meaning must be explicit, and the
    /// count updates in place without the caption being a bare glyph.
    func testScanningCaptionAccessibilityLabelSpellsOutTheState() {
        XCTAssertEqual(
            LargestFilesScanningCaption.accessibilityLabel(foundCount: 3),
            "Scanning for largest files, 3 found so far"
        )
    }

    // MARK: - View-model-driven lifecycle (transitions through the real wiring)

    /// Drives a real scan through the model: empty-scanning → a growing partial → the final
    /// list, asserting what the section would draw at each step. This is the progressive UI
    /// path A3 renders — the loading spinner first, then best-so-far rows that grow, then
    /// the final list — verified through `VolumeListViewModel` rather than by hand-building
    /// states.
    @MainActor
    func testProgressiveScanLifecycleDrivesTheSectionPresentation() {
        let scanner = ReplayableLargestFilesScanner()
        let model = makeModel(scanner: scanner)
        model.load()

        // Nothing gathered yet → the loading spinner.
        XCTAssertEqual(Presentation(state: model.largestFilesState), .loading,
                       "an in-flight scan with no partial shows the loading spinner")

        // First best-so-far batch → progressive rows.
        let firstBatch = [file("big.mov", 9)]
        scanner.deliverPartial(firstBatch)
        XCTAssertEqual(Presentation(state: model.largestFilesState), .scanning(firstBatch),
                       "the first partial shows the best-so-far rows, not the spinner")

        // A larger best-so-far batch → the rows grow in place.
        let secondBatch = [file("big.mov", 9), file("medium.zip", 4)]
        scanner.deliverPartial(secondBatch)
        XCTAssertEqual(Presentation(state: model.largestFilesState), .scanning(secondBatch),
                       "a later partial grows the visible rows")

        // Final result → the final list.
        scanner.deliver(.available(secondBatch))
        XCTAssertEqual(Presentation(state: model.largestFilesState), .available(secondBatch),
                       "the final result replaces the partial with the ranked list")
    }

    /// A cached list paints instantly on reopen (A2): the model opens straight in
    /// `.available`, so the section shows the ranked rows immediately — never the loading
    /// spinner — while a background refresh runs. This is the "cached-then-refreshing feels
    /// instant" requirement, seen from the view's side.
    @MainActor
    func testCachedListPaintsInstantlyAsAvailable() {
        let cache = ScanResultCache()
        let cached = [file("cached.mov", 9)]
        cache.storeLargestFiles(.available(cached), forVolumeAt: bootURL)

        let scanner = ReplayableLargestFilesScanner()
        let model = makeModel(scanner: scanner, cache: cache)
        model.load()

        XCTAssertEqual(Presentation(state: model.largestFilesState), .available(cached),
                       "a fresh cached list paints instantly as the final list, not a spinner")
    }

    /// An unavailable scan result drives the section to the "Not indexed" notice through
    /// the real wiring — the positive/negative counterpart of the available lifecycle.
    @MainActor
    func testUnavailableScanDrivesTheSectionToNotIndexed() {
        let scanner = ReplayableLargestFilesScanner()
        let model = makeModel(scanner: scanner)
        model.load()

        scanner.deliver(.unavailable)

        XCTAssertEqual(Presentation(state: model.largestFilesState), .notIndexed,
                       "an unavailable index shows the Not indexed notice, not an empty list")
    }

    // MARK: - Fixtures

    private let bootURL = URL(fileURLWithPath: "/", isDirectory: true)

    private func file(_ name: String, _ size: Int64) -> LargestFile {
        LargestFile(displayName: name, sizeBytes: size, url: URL(fileURLWithPath: "/Users/me/\(name)"))
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

    /// A `VolumeListViewModel` scoped to the boot volume, with the category scan kept
    /// inert (this file exercises the largest-files section, not the category bar).
    @MainActor
    private func makeModel(
        scanner: ReplayableLargestFilesScanner,
        cache: ScanResultCache? = nil
    ) -> VolumeListViewModel {
        let snapshot = VolumeEnumerator.Snapshot(
            internalVolumes: [bootVolume()],
            deferredVolumes: []
        )
        return VolumeListViewModel(
            enumerate: { snapshot },
            resolver: MockDeferredVolumeResolver(),
            scanner: MockCategoryScanner(),
            largestFilesScanner: scanner,
            hiddenFilesStore: MockHiddenFilesStore(),
            cache: cache
        )
    }

    // MARK: - Hidden-files affordance wording (UX-015)

    /// The resting "N hidden" affordance label uses the singular for one file and the
    /// plural otherwise — asserted so a count-formatting drift is caught.
    func testHiddenCountTextSingularAndPlural() {
        XCTAssertEqual(LargestFilesSection.hiddenCountText(1), "1 hidden")
        XCTAssertEqual(LargestFilesSection.hiddenCountText(2), "2 hidden")
        XCTAssertEqual(LargestFilesSection.hiddenCountText(0), "0 hidden")
    }

    /// The show/hide toggle's spoken label spells out the action and count (never a bare
    /// chevron), and flips between "Show N" and "Hide the N" as it expands/collapses.
    func testHiddenToggleAccessibilityLabelSpellsOutTheAction() {
        XCTAssertEqual(
            LargestFilesSection.hiddenToggleAccessibilityLabel(count: 1, expanded: false),
            "Show 1 hidden file"
        )
        XCTAssertEqual(
            LargestFilesSection.hiddenToggleAccessibilityLabel(count: 3, expanded: false),
            "Show 3 hidden files"
        )
        XCTAssertEqual(
            LargestFilesSection.hiddenToggleAccessibilityLabel(count: 2, expanded: true),
            "Hide the 2 hidden files"
        )
    }
}
