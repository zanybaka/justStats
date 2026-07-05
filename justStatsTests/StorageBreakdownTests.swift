import XCTest
@testable import justStats

/// SCAN-002: pure-function tests for the residual `System` math and the full
/// five-way reconciliation (`StorageBreakdown.reconciled`). The two invariants
/// every case must hold — all segments `≥ 0`, and the five summing to exactly
/// `total` — are asserted by `assertInvariants` so no case can silently violate
/// them (TECHSPEC §4).
final class StorageBreakdownTests: XCTestCase {
    /// Asserts the class invariants: no negative segment, and the five segments sum
    /// to exactly the (clamped) total.
    private func assertInvariants(
        _ breakdown: StorageBreakdown,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(breakdown.systemBytes, 0, "System must be ≥ 0", file: file, line: line)
        XCTAssertGreaterThanOrEqual(breakdown.appsBytes, 0, "Apps must be ≥ 0", file: file, line: line)
        XCTAssertGreaterThanOrEqual(breakdown.mediaBytes, 0, "Media must be ≥ 0", file: file, line: line)
        XCTAssertGreaterThanOrEqual(breakdown.otherBytes, 0, "Other must be ≥ 0", file: file, line: line)
        XCTAssertGreaterThanOrEqual(breakdown.freeBytes, 0, "Free must be ≥ 0", file: file, line: line)
        let sum = breakdown.systemBytes
            + breakdown.appsBytes
            + breakdown.mediaBytes
            + breakdown.otherBytes
            + breakdown.freeBytes
        XCTAssertEqual(sum, breakdown.totalBytes, "segments must sum to total", file: file, line: line)
    }

    // MARK: - Normal case

    /// System is the residual `Total − Free − Apps − Media − Other`, and the five
    /// segments sum to Total.
    func testNormalCaseComputesResidualSystemAndSumsToTotal() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .available(apps: 30, media: 40, other: 20),
            totalBytes: 200,
            freeBytes: 50
        )
        // used = 200 − 50 = 150; system = 150 − (30+40+20) = 60.
        XCTAssertEqual(breakdown.systemBytes, 60)
        XCTAssertEqual(breakdown.appsBytes, 30)
        XCTAssertEqual(breakdown.mediaBytes, 40)
        XCTAssertEqual(breakdown.otherBytes, 20)
        XCTAssertEqual(breakdown.freeBytes, 50)
        XCTAssertEqual(breakdown.totalBytes, 200)
        assertInvariants(breakdown)
    }

    /// Categories exactly fill the used space → System is 0 but the volume is still
    /// consistent (this is the boundary between the normal and overflow branches).
    func testCategoriesExactlyFillUsedGivesZeroSystem() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .available(apps: 60, media: 60, other: 30),
            totalBytes: 200,
            freeBytes: 50
        )
        // used = 150; apps+media+other = 150 → system = 0.
        XCTAssertEqual(breakdown.systemBytes, 0)
        XCTAssertEqual(breakdown.appsBytes, 60)
        XCTAssertEqual(breakdown.mediaBytes, 60)
        XCTAssertEqual(breakdown.otherBytes, 30)
        assertInvariants(breakdown)
    }

    // MARK: - Clamp-to-zero (categories exceed Total − Free)

    /// TECHSPEC §4: when the classified categories claim more than the used space
    /// (logical sizes overcount physical usage), System clamps to 0 rather than going
    /// negative, and the categories are scaled down to fit — the sum invariant holds.
    func testCategoriesExceedUsedClampsSystemToZeroAndFits() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .available(apps: 100, media: 100, other: 100),
            totalBytes: 200,
            freeBytes: 50
        )
        // used = 150; categorySum = 300 > 150 → system = 0, categories scaled to
        // fill 150. Equal inputs scale to equal shares (50 each).
        XCTAssertEqual(breakdown.systemBytes, 0)
        XCTAssertEqual(breakdown.appsBytes, 50)
        XCTAssertEqual(breakdown.mediaBytes, 50)
        XCTAssertEqual(breakdown.otherBytes, 50)
        XCTAssertEqual(breakdown.freeBytes, 50)
        assertInvariants(breakdown)
    }

    /// Free alone exceeding used leaves no room; any category bytes are scaled to
    /// zero and System stays 0.
    func testCategoriesPresentButNoUsedSpaceScalesCategoriesToZero() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .available(apps: 10, media: 20, other: 30),
            totalBytes: 100,
            freeBytes: 100
        )
        // used = 0; categorySum = 60 > 0 → everything but Free is 0.
        XCTAssertEqual(breakdown.systemBytes, 0)
        XCTAssertEqual(breakdown.appsBytes, 0)
        XCTAssertEqual(breakdown.mediaBytes, 0)
        XCTAssertEqual(breakdown.otherBytes, 0)
        XCTAssertEqual(breakdown.freeBytes, 100)
        assertInvariants(breakdown)
    }

    // MARK: - Zero-total volume

    /// A zero-total volume yields an all-zero breakdown; nothing divides by zero and
    /// the (trivial) sum invariant holds.
    func testZeroTotalVolumeIsAllZero() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .available(apps: 10, media: 20, other: 30),
            totalBytes: 0,
            freeBytes: 0
        )
        XCTAssertEqual(breakdown.systemBytes, 0)
        XCTAssertEqual(breakdown.appsBytes, 0)
        XCTAssertEqual(breakdown.mediaBytes, 0)
        XCTAssertEqual(breakdown.otherBytes, 0)
        XCTAssertEqual(breakdown.freeBytes, 0)
        XCTAssertEqual(breakdown.totalBytes, 0)
        assertInvariants(breakdown)
    }

    /// Zero total with nonsense free reported: total clamps the frame, so free can't
    /// exceed it and no segment goes negative.
    func testZeroTotalWithReportedFreeStillAllZero() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .unavailable,
            totalBytes: 0,
            freeBytes: 500
        )
        XCTAssertEqual(breakdown.freeBytes, 0)
        assertInvariants(breakdown)
    }

    // MARK: - Rounding reconciliation

    /// When scaling categories to fit, the integer shares must still sum to exactly
    /// the used space — the leftover from flooring is handed out (largest-remainder),
    /// never dropped. Here 3+3+4 = 10 exactly, not 9.
    func testScalingReconcilesRoundingSoSumIsExact() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .available(apps: 100, media: 100, other: 100),
            totalBytes: 10,
            freeBytes: 0
        )
        // used = 10; three equal categories of 100 each → ideal share 3.33…; floors
        // are 3/3/3 (=9), one leftover unit goes to the first by the tie-break.
        XCTAssertEqual(breakdown.systemBytes, 0)
        XCTAssertEqual(
            breakdown.appsBytes + breakdown.mediaBytes + breakdown.otherBytes,
            10,
            "scaled categories must sum to used exactly"
        )
        XCTAssertEqual([breakdown.appsBytes, breakdown.mediaBytes, breakdown.otherBytes], [4, 3, 3])
        assertInvariants(breakdown)
    }

    /// Largest-remainder distribution favours the entries whose proportional share
    /// had the biggest dropped fraction, so the extra unit lands where it best
    /// preserves proportionality — and the sum still equals used.
    func testRoundingLeftoverGoesToLargestFraction() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .available(apps: 1, media: 1, other: 4),
            totalBytes: 3,
            freeBytes: 0
        )
        // used = 3; sum = 6. Shares: apps 0.5, media 0.5, other 2.0 → floors 0/0/2
        // (=2), one leftover. Fractions: 0.5, 0.5, 0.0 → the unit goes to apps
        // (first of the tied 0.5 fractions).
        XCTAssertEqual(
            breakdown.appsBytes + breakdown.mediaBytes + breakdown.otherBytes,
            3,
            "scaled categories must sum to used exactly"
        )
        XCTAssertEqual([breakdown.appsBytes, breakdown.mediaBytes, breakdown.otherBytes], [1, 0, 2])
        assertInvariants(breakdown)
    }

    // MARK: - Frame clamping (defensive inputs)

    /// Free reported above total is clamped to total (used = 0), so free never
    /// exceeds the capacity and no segment goes negative.
    func testFreeExceedingTotalIsClampedToTotal() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .available(apps: 5, media: 5, other: 5),
            totalBytes: 100,
            freeBytes: 250
        )
        XCTAssertEqual(breakdown.freeBytes, 100)
        XCTAssertEqual(breakdown.systemBytes, 0)
        assertInvariants(breakdown)
    }

    /// Negative free and negative category bytes (never produced by real readers, but
    /// the function must not trust its inputs) are clamped up to zero.
    func testNegativeInputsAreClampedNonNegative() {
        let breakdown = StorageBreakdown.reconciled(
            categories: CategoryBreakdown(
                appsBytes: -10, mediaBytes: 20, otherBytes: -5, isIndexAvailable: true
            ),
            totalBytes: 100,
            freeBytes: -30
        )
        // free clamps to 0 → used = 100; apps −10→0, other −5→0, media 20 →
        // system = 100 − 20 = 80.
        XCTAssertEqual(breakdown.freeBytes, 0)
        XCTAssertEqual(breakdown.appsBytes, 0)
        XCTAssertEqual(breakdown.otherBytes, 0)
        XCTAssertEqual(breakdown.mediaBytes, 20)
        XCTAssertEqual(breakdown.systemBytes, 80)
        assertInvariants(breakdown)
    }

    /// Negative total collapses the whole frame to zero.
    func testNegativeTotalCollapsesToZero() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .available(apps: 10, media: 10, other: 10),
            totalBytes: -100,
            freeBytes: 50
        )
        XCTAssertEqual(breakdown.totalBytes, 0)
        assertInvariants(breakdown)
    }

    // MARK: - Unavailable categories

    /// An `.unavailable` breakdown (no usable index) still reconciles into a valid
    /// bar: its zero categories mean the whole used space falls into System. Callers
    /// choose whether to render this or the "Not indexed" notice (SCAN-005); the math
    /// must not crash on it.
    func testUnavailableCategoriesPutAllUsedIntoSystem() {
        let breakdown = StorageBreakdown.reconciled(
            categories: .unavailable,
            totalBytes: 500,
            freeBytes: 120
        )
        XCTAssertEqual(breakdown.appsBytes, 0)
        XCTAssertEqual(breakdown.mediaBytes, 0)
        XCTAssertEqual(breakdown.otherBytes, 0)
        XCTAssertEqual(breakdown.systemBytes, 380) // 500 − 120
        XCTAssertEqual(breakdown.freeBytes, 120)
        assertInvariants(breakdown)
    }

    // MARK: - Large-volume overflow safety

    /// On a multi-terabyte volume the scaling arithmetic (`value * capacity`) would
    /// overflow a 64-bit product; the full-width path must still produce exact,
    /// non-negative shares that sum to used. Uses values whose naïve product exceeds
    /// `Int64.max`.
    func testLargeVolumeScalingDoesNotOverflowAndSumsExactly() {
        let tb: Int64 = 1_000_000_000_000
        let breakdown = StorageBreakdown.reconciled(
            // Three ~4 TB categories on an 8 TB volume with 2 TB free → 6 TB used,
            // 12 TB claimed. value*capacity ≈ 4e12 * 6e12 = 2.4e25 ≫ Int64.max (~9.2e18).
            categories: .available(apps: 4 * tb, media: 4 * tb, other: 4 * tb),
            totalBytes: 8 * tb,
            freeBytes: 2 * tb
        )
        XCTAssertEqual(breakdown.systemBytes, 0)
        XCTAssertEqual(
            breakdown.appsBytes + breakdown.mediaBytes + breakdown.otherBytes,
            6 * tb,
            "scaled categories must sum to used exactly even past 64-bit product range"
        )
        // Equal inputs → equal 2 TB shares.
        XCTAssertEqual(breakdown.appsBytes, 2 * tb)
        XCTAssertEqual(breakdown.mediaBytes, 2 * tb)
        XCTAssertEqual(breakdown.otherBytes, 2 * tb)
        assertInvariants(breakdown)
    }
}
