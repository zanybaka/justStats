import XCTest
@testable import justStats

/// SCAN-004: pure-logic tests for the category bar's segment model and pixel-width
/// settlement. The SwiftUI rendering itself isn't unit-tested (no host), but the
/// two pieces that must be exactly right — the fixed segment order and the widths
/// summing flush to the track — are pure and covered here.
final class CategoryBarViewTests: XCTestCase {
    private func breakdown(
        system: Int64, apps: Int64, media: Int64, other: Int64, free: Int64
    ) -> StorageBreakdown {
        // Build via the reconciler so the fixture is always a valid breakdown
        // (segments sum to total). total = sum, free carved out, rest classified.
        let total = system + apps + media + other + free
        return StorageBreakdown.reconciled(
            categories: .available(apps: apps, media: media, other: other),
            totalBytes: total,
            freeBytes: free
        )
    }

    // MARK: - Segment ordering

    /// The five segments are always in the fixed System→Apps→Media→Other→Free order,
    /// so the bar and legend align regardless of the byte values.
    func testSegmentsAreInFixedDrawOrder() {
        let bd = breakdown(system: 250, apps: 100, media: 200, other: 50, free: 400)
        let segments = CategorySegment.segments(from: bd)

        XCTAssertEqual(segments.map(\.id),
                       [.system, .apps, .media, .other, .free])
        XCTAssertEqual(segments.map(\.bytes), [250, 100, 200, 50, 400])
        XCTAssertEqual(segments.map(\.name), ["System", "Apps", "Media", "Other", "Free"])
    }

    // MARK: - Pixel-width settlement

    /// Rounded segment widths must sum to exactly the track width — no trailing gap
    /// or overflow. Uses a width and shares that don't divide evenly.
    func testPixelWidthsSumToTrackWidthExactly() {
        let bytes: [Int64] = [250, 100, 200, 50, 400] // sum 1000
        let widths = CategoryBarView.pixelWidths(for: bytes, total: 1000, trackWidth: 317)

        XCTAssertEqual(widths.reduce(0, +), 317, accuracy: 0.0001,
                       "segment widths fill the track with no gap or overflow")
        for width in widths {
            XCTAssertGreaterThanOrEqual(width, 0, "no segment has negative width")
        }
    }

    /// Widths are proportional: a segment that is half the bytes gets about half
    /// the track (within the sub-pixel settlement).
    func testPixelWidthsAreProportional() {
        let widths = CategoryBarView.pixelWidths(for: [500, 500], total: 1000, trackWidth: 200)
        XCTAssertEqual(widths[0], 100, accuracy: 1)
        XCTAssertEqual(widths[1], 100, accuracy: 1)
        XCTAssertEqual(widths.reduce(0, +), 200, accuracy: 0.0001)
    }

    /// A zero-total (or zero-width) track yields all-zero widths — no divide by zero.
    func testZeroTotalOrZeroTrackYieldsZeroWidths() {
        XCTAssertEqual(CategoryBarView.pixelWidths(for: [10, 20], total: 0, trackWidth: 100), [0, 0])
        XCTAssertEqual(CategoryBarView.pixelWidths(for: [10, 20], total: 30, trackWidth: 0), [0, 0])
    }

    /// A single dominant segment takes essentially the whole track; the tiny others
    /// still never overflow the total.
    func testDominantSegmentDoesNotOverflow() {
        let widths = CategoryBarView.pixelWidths(for: [1, 1, 998], total: 1000, trackWidth: 340)
        XCTAssertEqual(widths.reduce(0, +), 340, accuracy: 0.0001)
        XCTAssertGreaterThan(widths[2], widths[0])
        XCTAssertGreaterThan(widths[2], widths[1])
    }
}
