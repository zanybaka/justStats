import SwiftUI

/// Shared visual foundation for the disk popover (UX-007, APPROVED DESIGN
/// DIRECTION): one place that owns the category palette and the bar/spacing/type
/// metrics so every disk view — the usage bar, the volume rows (UX-008), and the
/// largest-files section (UX-009) — draws from the same, appearance-adaptive source.
///
/// Everything here resolves through system/semantic colors so light and dark adapt
/// automatically; no hardcoded RGB. Color is always a *secondary* cue — segments are
/// still named and sized in the legend and spoken by VoiceOver (no-meaning-by-color).
enum DiskPalette {
    /// Semantic color for each storage category (APPROVED DESIGN DIRECTION):
    /// System = secondary gray, Apps = blue, Media = indigo, Other = orange,
    /// Free = the quaternary track fill. All are SwiftUI/system semantic colors so
    /// they track the current appearance without any dark-mode hardcoding.
    static func color(for category: CategorySegment.Category) -> Color {
        switch category {
        case .system: return Color(nsColor: .secondaryLabelColor)
        case .apps: return .blue
        case .media: return .indigo
        case .other: return .orange
        case .free: return Color(nsColor: .quaternaryLabelColor)
        }
    }

    /// The muted track a usage/category bar sits on — the same quaternary fill used
    /// for the `Free` segment, so an all-free bar reads as one continuous track.
    static let track = Color(nsColor: .quaternaryLabelColor)
}

/// Layout metrics for the disk popover's dense, Stats-inspired look (UX-007). Kept
/// as one small constant table so the bar height/radius, standard paddings, and the
/// type sizes stay consistent across the usage bar, rows, and largest-files section
/// (later UX tasks read these rather than sprinkling literals).
enum DiskMetrics {
    // MARK: Usage / category bar
    /// Bar (and its track) height. ~9pt reads as a solid segmented bar rather than a
    /// hairline, per the approved direction.
    static let barHeight: CGFloat = 9
    /// Corner radius of the bar/track. ~5pt gives a fully rounded ~9pt-tall capsule.
    static let barCornerRadius: CGFloat = 5

    // MARK: Card / row
    /// Corner radius of a volume row's card fill (~10pt, approved direction).
    static let cardCornerRadius: CGFloat = 10
    /// Inner padding of a volume row card (~10–11pt, approved direction).
    static let cardPadding: CGFloat = 11

    // MARK: Spacing
    /// Vertical spacing between a row's stacked lines (name / bar / caption).
    static let rowSpacing: CGFloat = 4
    /// Horizontal spacing between inline controls/text on a single line.
    static let inlineSpacing: CGFloat = 8
    /// Spacing between the bar and its legend / between legend chips.
    static let legendSpacing: CGFloat = 6

    // MARK: Type
    /// The volume name's point size (13pt medium, approved direction).
    static let nameFontSize: CGFloat = 13
}
