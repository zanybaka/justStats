import Foundation

/// The full five-way storage breakdown of a volume shown in the stacked usage bar
/// (SCAN-004): the three Spotlight-classified categories, the residual `System`
/// bucket, and `Free`. Every segment is non-negative and the five sum *exactly* to
/// `total` — so a bar built from these fills the track with no gap or overflow, and
/// no segment ever renders a negative width.
///
/// This is the resolved counterpart to `CategoryBreakdown` (SCAN-001), which is the
/// partial, Spotlight-only input (Apps/Media/Other + an availability flag). The join
/// with the volume's `total`/`free` (from `statfs`, `VolumeSpace`) and the residual
/// `System` computation happen here in `StorageBreakdown.reconciled(...)`.
struct StorageBreakdown: Equatable {
    /// Residual bucket: everything not positively classified as Apps/Media/Other and
    /// not free. `Total − Free − Apps − Media − Other`, clamped to ≥ 0 (TECHSPEC §4).
    let systemBytes: Int64
    /// Application bundles (from `CategoryBreakdown.appsBytes`), after fitting.
    let appsBytes: Int64
    /// Images, movies, audio (from `CategoryBreakdown.mediaBytes`), after fitting.
    let mediaBytes: Int64
    /// User files that are neither Apps nor Media (from `CategoryBreakdown.otherBytes`),
    /// after fitting.
    let otherBytes: Int64
    /// Free space (from `VolumeSpace.free`), clamped into `[0, total]`.
    let freeBytes: Int64
    /// The volume's total capacity. The five segments above sum to exactly this.
    let totalBytes: Int64

    /// Computes the full five-way breakdown from the partial Spotlight categories and
    /// the volume's total/free capacity (TECHSPEC §4 residual-System math).
    ///
    /// Guarantees, for *any* input (including nonsense from mocks or logical sizes
    /// that overcount physical usage — APFS clones/sparse files, Spotlight vs
    /// `statfs` disagreement):
    ///
    /// - every returned segment is `≥ 0`;
    /// - `system + apps + media + other + free == max(total, 0)` exactly.
    ///
    /// `System` is the residual and absorbs all reconciliation, so rounding never
    /// leaks into the categories or free. Method, in order:
    ///
    /// 1. `total` and `free` are clamped into a sane frame: `total ← max(total, 0)`,
    ///    `free ← min(max(free, 0), total)`. A volume reporting more free than total
    ///    (or negative either) can't produce a negative or oversized segment.
    /// 2. The used space the categories share is `used = total − free` (`≥ 0`).
    /// 3. Apps/Media/Other are clamped to `≥ 0`. If their sum already fits within
    ///    `used`, `System = used − (apps + media + other)` (`≥ 0`) takes the slack —
    ///    this is the normal case and the residual holds all unclassified/OS bytes.
    /// 4. If the categories *exceed* `used` (overcount), `System` would go negative,
    ///    so it clamps to `0` and the categories are scaled down to fit `used`
    ///    exactly (largest-remainder, so the integer parts still sum to `used` with
    ///    no drift). The categories then remain proportional and nothing overflows.
    ///
    /// - Parameters:
    ///   - categories: partial Spotlight breakdown (Apps/Media/Other). Its
    ///     availability flag is not consulted here — callers decide whether to show
    ///     the bar at all (SCAN-005 renders "Not indexed" for `.unavailable` instead
    ///     of calling this); passed a `.unavailable` value, this still returns a
    ///     valid all-in-`System`/`Free` breakdown rather than crashing.
    ///   - totalBytes: the volume's total capacity (`VolumeSpace.total`).
    ///   - freeBytes: the volume's free space (`VolumeSpace.free`).
    static func reconciled(
        categories: CategoryBreakdown,
        totalBytes: Int64,
        freeBytes: Int64
    ) -> StorageBreakdown {
        let total = max(totalBytes, 0)
        let free = min(max(freeBytes, 0), total)
        let used = total - free

        let apps = max(categories.appsBytes, 0)
        let media = max(categories.mediaBytes, 0)
        let other = max(categories.otherBytes, 0)
        let categorySum = apps &+ media &+ other

        if categorySum <= used {
            // Normal case: the residual System takes the slack. The five segments
            // sum to total by construction (system + apps+media+other == used, and
            // used + free == total).
            return StorageBreakdown(
                systemBytes: used - categorySum,
                appsBytes: apps,
                mediaBytes: media,
                otherBytes: other,
                freeBytes: free,
                totalBytes: total
            )
        }

        // Overcount: categories claim more than the used space. System clamps to 0
        // and the categories are scaled down to fill exactly `used`.
        let fitted = Self.scaleToFit([apps, media, other], sum: categorySum, capacity: used)
        return StorageBreakdown(
            systemBytes: 0,
            appsBytes: fitted[0],
            mediaBytes: fitted[1],
            otherBytes: fitted[2],
            freeBytes: free,
            totalBytes: total
        )
    }

    /// Scales `values` (whose total is `sum`, `> capacity ≥ 0`) down proportionally so
    /// the results are non-negative integers summing to exactly `capacity`. Uses the
    /// largest-remainder method: floor each proportional share, then hand the leftover
    /// units (from flooring) to the entries with the largest dropped fractions, so no
    /// rounding drift accumulates and the sum lands on `capacity` precisely.
    ///
    /// Preconditions the caller guarantees: `sum > 0` (it exceeds a `≥ 0` capacity)
    /// and every value `≥ 0`. `Double` is used only to order the fractional parts;
    /// the floors and the final distribution are exact `Int64` arithmetic, so the sum
    /// invariant does not depend on floating-point accuracy.
    private static func scaleToFit(_ values: [Int64], sum: Int64, capacity: Int64) -> [Int64] {
        precondition(sum > 0, "scaleToFit requires a positive sum")
        // floor(value * capacity / sum) via 128-bit-safe path: value and capacity are
        // each ≤ total (fits Int64), but their product can overflow Int64, so multiply
        // in Double for the quotient's integer part is unsafe for very large disks.
        // Use full-width multiplication instead.
        var floors: [Int64] = []
        var remainders: [(index: Int, remainder: UInt64)] = []
        floors.reserveCapacity(values.count)
        var distributed: Int64 = 0
        for (index, value) in values.enumerated() {
            let (quotient, remainder) = Self.mulDiv(value, capacity, sum)
            floors.append(quotient)
            remainders.append((index: index, remainder: remainder))
            distributed &+= quotient
        }
        // Leftover units to hand out so the total reaches `capacity` exactly.
        var leftover = capacity - distributed
        // Largest dropped fraction first; ties broken by index for determinism.
        remainders.sort { lhs, rhs in
            lhs.remainder != rhs.remainder ? lhs.remainder > rhs.remainder : lhs.index < rhs.index
        }
        var slot = 0
        while leftover > 0 && slot < remainders.count {
            floors[remainders[slot].index] &+= 1
            leftover -= 1
            slot += 1
        }
        return floors
    }

    /// Returns `(quotient, remainder)` of `value * capacity / divisor` computed at
    /// full width so the intermediate product never overflows `Int64` even on
    /// multi-terabyte volumes. All inputs are non-negative; `divisor > 0`.
    private static func mulDiv(_ value: Int64, _ capacity: Int64, _ divisor: Int64) -> (Int64, UInt64) {
        let product = value.multipliedFullWidth(by: capacity) // (high, low), 128-bit
        let (q, r) = UInt64(divisor).dividingFullWidth(
            (high: UInt64(bitPattern: product.high), low: product.low)
        )
        return (Int64(q), r)
    }
}
