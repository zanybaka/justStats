import XCTest
@testable import justStats

/// QA-001 (accessibility pass): the spoken-summary strings for the popover rows are
/// what a VoiceOver user actually hears, so — like the pixel-width settlement and the
/// state → content mapping — they are factored into pure static functions and pinned
/// here. The SwiftUI rendering has no unit-test host; these functions carry the wording
/// that must be exactly right, independently of the view tree.
final class RowAccessibilityLabelTests: XCTestCase {
    // MARK: - Volume row header line (VolumeRowView.headerAccessibilityLabel)

    /// The volume row's single spoken summary names the volume and states both the free
    /// space and the used-of-total — so every content case (bar, notice, usage bar) reads
    /// the same coherent identity instead of fragmenting into "name" + "X free".
    func testVolumeHeaderLabelNamesVolumeFreeAndUsedOfTotal() {
        let label = VolumeRowView.headerAccessibilityLabel(
            volumeName: "Macintosh HD",
            free: "100 GB",
            used: "400 GB",
            total: "500 GB",
            isRunningLow: false
        )
        XCTAssertEqual(label, "Macintosh HD, 100 GB free, 400 GB used of 500 GB")
    }

    /// The summary is a single comma-separated sentence (one VoiceOver utterance),
    /// not a bare volume name — a regression to "just the name" would drop the numbers
    /// a low-vision user relies on.
    func testVolumeHeaderLabelIsOneSentenceWithAllFigures() {
        let label = VolumeRowView.headerAccessibilityLabel(
            volumeName: "Data", free: "1 GB", used: "9 GB", total: "10 GB",
            isRunningLow: false
        )
        XCTAssertTrue(label.contains("Data"))
        XCTAssertTrue(label.contains("1 GB free"))
        XCTAssertTrue(label.contains("9 GB used of 10 GB"))
    }

    /// A running-low volume appends "running low" to its spoken summary — the same at-risk
    /// warning the sighted "Running low" text+icon flag carries — so the low state is never
    /// signalled by the red accent alone. This must hold in every content case (bar, notice,
    /// usage bar), which all route through this one label.
    func testVolumeHeaderLabelAnnouncesRunningLow() {
        let label = VolumeRowView.headerAccessibilityLabel(
            volumeName: "Macintosh HD",
            free: "5 GB",
            used: "495 GB",
            total: "500 GB",
            isRunningLow: true
        )
        XCTAssertEqual(label, "Macintosh HD, 5 GB free, 495 GB used of 500 GB, running low")
    }

    /// A healthy volume never says "running low" — the warning is reserved for the at-risk
    /// state, so a green volume's summary stays the plain usage sentence.
    func testVolumeHeaderLabelOmitsRunningLowWhenHealthy() {
        let label = VolumeRowView.headerAccessibilityLabel(
            volumeName: "Data", free: "1 GB", used: "9 GB", total: "10 GB",
            isRunningLow: false
        )
        XCTAssertFalse(label.contains("running low"))
    }

    // MARK: - Largest-file row (LargestFileRow.rowAccessibilityLabel)

    /// At rest, a largest-file row speaks its name and size only — the path and the
    /// action buttons are separate elements, so the row identity stays terse.
    func testLargestFileRowLabelIsNameAndSizeAtRest() {
        let label = LargestFileRow.rowAccessibilityLabel(
            fileName: "movie.mov", sizeText: "4.2 GB", isConfirmingTrash: false
        )
        XCTAssertEqual(label, "movie.mov, 4.2 GB")
    }

    /// While the destructive Move-to-Trash confirm is armed, the row announces that a
    /// confirmation is pending — a VoiceOver user must not enter the confirm state
    /// silently, since the next control is a destructive action (TECHSPEC §9 item 9).
    func testLargestFileRowLabelAnnouncesPendingTrashConfirmation() {
        let label = LargestFileRow.rowAccessibilityLabel(
            fileName: "movie.mov", sizeText: "4.2 GB", isConfirmingTrash: true
        )
        XCTAssertEqual(label, "movie.mov, 4.2 GB, confirm move to Trash")
    }
}
