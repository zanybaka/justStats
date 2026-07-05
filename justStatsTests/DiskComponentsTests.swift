import XCTest
@testable import justStats

/// UX-007: pure-logic tests for the shared disk components. The SwiftUI rendering
/// isn't unit-tested (no host), but the two pieces that must be exactly right — the
/// `DiskGlyph` kind→symbol map and the `UsageBarView` pixel-width settlement — are
/// pure static functions and covered here. (The category bar's settlement is also
/// still covered end-to-end through `CategoryBarView.pixelWidths` in
/// `CategoryBarViewTests`, which now forwards to the same function.)
final class DiskComponentsTests: XCTestCase {

    // MARK: - DiskGlyph kind → SF Symbol

    /// Each volume kind maps to its approved SF Symbol: internal → `internaldrive`,
    /// external → the connected-external-drive symbol, network → `network`.
    func testDiskGlyphSymbolPerKind() {
        XCTAssertEqual(DiskGlyph.symbolName(for: .internal), "internaldrive")
        XCTAssertEqual(DiskGlyph.symbolName(for: .external), "externaldrive.connected.to.line.below")
        XCTAssertEqual(DiskGlyph.symbolName(for: .network), "network")
    }

    /// Every kind resolves to a distinct, non-empty symbol name — a new kind can't
    /// silently reuse another's glyph or fall through to an empty string.
    func testDiskGlyphSymbolsAreDistinctAndNonEmpty() {
        let names = [Volume.Kind.internal, .external, .network].map(DiskGlyph.symbolName(for:))
        XCTAssertFalse(names.contains(where: \.isEmpty), "no kind maps to an empty symbol")
        XCTAssertEqual(Set(names).count, names.count, "each kind has a distinct symbol")
    }

    // MARK: - UsageBarView pixel-width settlement

    /// Multi-segment widths sum to exactly the track width — no trailing gap or
    /// overflow — using shares and a width that don't divide evenly.
    func testUsageBarWidthsSumToTrackWidthExactly() {
        let widths = UsageBarView.pixelWidths(for: [250, 100, 200, 50, 400], total: 1000, trackWidth: 317)
        XCTAssertEqual(widths.reduce(0, +), 317, accuracy: 0.0001)
        for width in widths {
            XCTAssertGreaterThanOrEqual(width, 0)
        }
    }

    /// A zero total or zero track yields all-zero widths — no divide by zero.
    func testUsageBarZeroTotalOrTrackYieldsZeroWidths() {
        XCTAssertEqual(UsageBarView.pixelWidths(for: [10, 20], total: 0, trackWidth: 100), [0, 0])
        XCTAssertEqual(UsageBarView.pixelWidths(for: [10, 20], total: 30, trackWidth: 0), [0, 0])
    }

    // MARK: - UsageBarView.singleFill

    /// A single-fill bar clamps its fraction into `0...1` and settles the fill exactly:
    /// half-full is half the track, and out-of-range fractions saturate at the ends.
    func testSingleFillClampsAndSettlesFraction() {
        let track: CGFloat = 200

        let half = UsageBarView.singleFill(usedFraction: 0.5)
        let halfWidths = UsageBarView.pixelWidths(for: half.segments.map(\.bytes), total: half.total, trackWidth: track)
        XCTAssertEqual(halfWidths[0], 100, accuracy: 0.5, "half-full fills half the track")

        let over = UsageBarView.singleFill(usedFraction: 1.7)
        let overWidths = UsageBarView.pixelWidths(for: over.segments.map(\.bytes), total: over.total, trackWidth: track)
        XCTAssertEqual(overWidths[0], track, accuracy: 0.0001, "a fraction above 1 saturates at full")

        let under = UsageBarView.singleFill(usedFraction: -0.3)
        let underWidths = UsageBarView.pixelWidths(for: under.segments.map(\.bytes), total: under.total, trackWidth: track)
        XCTAssertEqual(underWidths[0], 0, accuracy: 0.0001, "a negative fraction saturates at empty")
    }

    /// `singleFill` builds a fill segment plus a transparent remainder, and the two
    /// shares always sum to the bar's total — so the fill keeps its exact proportional
    /// width and the settlement never inflates it to the whole track.
    func testSingleFillIsFillPlusRemainderSummingToTotal() {
        let bar = UsageBarView.singleFill(usedFraction: 0.25)
        XCTAssertEqual(bar.segments.count, 2)
        XCTAssertEqual(bar.segments.map(\.bytes).reduce(0, +), bar.total)
        XCTAssertEqual(bar.segments[1].color, .clear, "the remainder is transparent so the track shows through")
    }
}
