import SwiftUI

/// Reusable segmented usage bar (UX-007): one or more proportional color segments
/// laid out on a muted track, appearance-adaptive and fully rounded. This is the
/// shared primitive behind both the plain single-fill usage bar and the five-way
/// `CategoryBarView` — callers hand it the per-segment byte shares and colors and it
/// owns the pixel-width settlement so the segments sum to exactly the track width.
///
/// Purely decorative: the owning view (row / category bar) carries the numbers and
/// the VoiceOver summary, so this element is hidden from accessibility.
struct UsageBarView: View {
    /// One drawn band of the bar: its byte share and its (appearance-adaptive) color.
    /// Zero-byte segments are allowed — they simply settle to zero width.
    struct Segment: Equatable {
        let bytes: Int64
        let color: Color

        init(bytes: Int64, color: Color) {
            self.bytes = bytes
            self.color = color
        }
    }

    /// The segments in draw order (left → right). The bar renders them contiguously.
    let segments: [Segment]
    /// The denominator the shares are taken against — normally the volume total. A
    /// zero (or negative) total, or an empty `segments`, renders an empty track.
    let total: Int64
    /// Bar (and track) height; defaults to the shared metric.
    var height: CGFloat = DiskMetrics.barHeight
    /// Corner radius of the rounded track/segments; defaults to the shared metric.
    var cornerRadius: CGFloat = DiskMetrics.barCornerRadius

    var body: some View {
        GeometryReader { geometry in
            let widths = Self.pixelWidths(
                for: segments.map(\.bytes),
                total: total,
                trackWidth: geometry.size.width
            )
            ZStack(alignment: .leading) {
                // The muted track shows through wherever segments don't reach (e.g. a
                // single-fill usage bar whose one segment is less than full).
                DiskPalette.track
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        segment.color
                            .frame(width: widths[index])
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(height: height)
        // The owning view speaks the numbers; the bar is a visual echo.
        .accessibilityHidden(true)
    }

    /// Convenience for a plain single-fill usage bar: one accent-colored segment over
    /// the track, filled to `usedFraction` (clamped to `0...1`). Kept so the volume
    /// row's "scan in flight" case reads as clearly as the category case without the
    /// caller assembling a `[Segment]` by hand.
    static func singleFill(usedFraction: Double, color: Color = .accentColor) -> UsageBarView {
        let fraction = min(max(usedFraction, 0), 1)
        // Scaled to a fixed 10_000-unit denominator so the shared settlement math
        // renders the fill exactly (no floating-point drift at the fill edge).
        let scale: Int64 = 10_000
        let used = Int64((fraction * Double(scale)).rounded())
        // A `.clear` remainder segment carries the unfilled share. Without it the
        // largest-remainder settlement would hand the whole track's leftover pixels to
        // the single fill segment (inflating a half-full bar to full); with it the fill
        // keeps its exact proportional width and the muted track shows through the
        // transparent remainder. The two segments sum to `scale`, satisfying the
        // settlement's partition contract.
        return UsageBarView(
            segments: [
                Segment(bytes: used, color: color),
                Segment(bytes: scale - used, color: .clear),
            ],
            total: scale
        )
    }

    /// Distributes `trackWidth` across the segments proportionally to `bytes`,
    /// returning `CGFloat` widths that sum to exactly `trackWidth`. A zero total (or
    /// zero track) yields all-zero widths. Largest-remainder settlement in the pixel
    /// domain keeps the trailing edge flush — no sliver gap or 1px overflow.
    ///
    /// This is the same settlement that lived on `CategoryBarView`; it is hoisted here
    /// so both the plain and category bars settle identically, and so the existing
    /// width-settlement unit tests keep a stable home.
    static func pixelWidths(for bytes: [Int64], total: Int64, trackWidth: CGFloat) -> [CGFloat] {
        guard total > 0, trackWidth > 0 else { return bytes.map { _ in 0 } }
        let exact = bytes.map { CGFloat($0) / CGFloat(total) * trackWidth }
        var floors = exact.map { $0.rounded(.down) }
        let distributed = floors.reduce(0, +)
        var leftover = trackWidth - distributed
        // Hand the sub-pixel leftover to the segments with the largest dropped
        // fraction first, so widths sum to the track width without visible drift.
        let order = exact.indices.sorted { (exact[$0] - floors[$0]) > (exact[$1] - floors[$1]) }
        var slot = 0
        while leftover >= 1, slot < order.count {
            floors[order[slot]] += 1
            leftover -= 1
            slot += 1
        }
        // Any remaining fractional pixel (<1) goes to the segment with the largest
        // dropped fraction so the bar is exactly flush; imperceptible, never negative.
        if leftover > 0, let first = order.first {
            floors[first] += leftover
        }
        return floors
    }
}

/// SF Symbol glyph for a volume's kind (UX-007, APPROVED DESIGN DIRECTION):
/// internal → `internaldrive`, external → `externaldrive.connected.to.line.below`,
/// network → `network`. Used by the volume row (UX-008) to tint a leading icon so the
/// disk kind reads at a glance. Kind → symbol is a pure static map so it is unit
/// testable without a SwiftUI host.
struct DiskGlyph: View {
    let kind: Volume.Kind
    /// Tint applied to the symbol; defaults to the accent color so it reads as a
    /// system control. Callers (e.g. a "running low" row) may override it.
    var tint: Color = .accentColor

    /// SF Symbol name for each volume kind. Static and pure so the mapping is covered
    /// by a plain assertion (no rendering host needed).
    static func symbolName(for kind: Volume.Kind) -> String {
        switch kind {
        case .internal: return "internaldrive"
        case .external: return "externaldrive.connected.to.line.below"
        case .network: return "network"
        }
    }

    var body: some View {
        Image(systemName: Self.symbolName(for: kind))
            .foregroundStyle(tint)
            // Decorative: the row's accessibility label already names the volume; a
            // spoken "internal drive" glyph would just be noise before the name.
            .accessibilityHidden(true)
    }
}
