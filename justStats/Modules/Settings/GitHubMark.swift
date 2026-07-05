import SwiftUI

/// The canonical GitHub "mark" (the Octocat silhouette) as a single filled SwiftUI
/// `Shape`, used wherever the app links out to its source repository (UX-012).
///
/// Why a hand-built `Shape` and not an SF Symbol: SF Symbols has **no** GitHub logo, so
/// the redesign's `arrow.up.right.square` was a generic external-link square that no
/// longer read as "GitHub". This restores a real, recognizable brand mark.
///
/// The geometry is the official GitHub mark's own vector outline — the single path
/// GitHub/Primer publishes as the `mark-github` Octocat glyph on a 16×16 canvas —
/// transcribed exactly and stored normalized to a unit square (each authored coordinate
/// divided by 16). `path(in:)` scales that unit path to fit whatever frame the caller
/// gives it, uniformly and centered, so it renders crisply at any size without
/// distortion. It is one filled path, so the silhouette (not a boxed glyph) is what reads.
///
/// Appearance-adaptive and tintable by design: the shape carries no color of its own, so
/// the caller's `.foregroundStyle` (the current label/tint color) fills it and it adapts
/// to light/dark automatically — exactly like the surrounding `Label`/`Link` text.
///
/// One source of truth: both the popover footer (`VolumeListFooterView`) and the Settings
/// About link (`AboutSection`) render *this* view via `GitHubMarkLabel`, so the mark is
/// defined once and stays identical in both places.
struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        // `GitHubMarkPath.octocat` is normalized to a 0...1 unit square; scale it uniformly
        // to fit `rect` (using the shorter side) and center it, so any frame the caller
        // applies renders the mark without stretching.
        let side = min(rect.width, rect.height)
        guard side > 0 else { return Path() }
        let dx = rect.minX + (rect.width - side) / 2
        let dy = rect.minY + (rect.height - side) / 2
        let transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: side, y: side)
        return GitHubMarkPath.octocat.applying(transform)
    }
}

/// A `Link`-ready label pairing the `GitHubMark` glyph with an optional text title,
/// matching the project's other outbound-link labels (an icon leading the text). Factored
/// out so the popover footer and the Settings About row present the **same** mark at the
/// **same** size with the **same** accessibility label — one definition, two call sites
/// (UX-012).
///
/// The mark is sized to the caller-supplied `size` (defaulting to ~16pt, the app's inline
/// glyph size) and tinted by the ambient `foregroundStyle`, so it tracks the label's color
/// and adapts to light/dark. The whole control is exposed to VoiceOver as
/// `"View justStats on GitHub"` (the accessibility contract preserved from the prior
/// SF Symbol link). The visible title is optional so the footer can render an icon-only
/// control while Settings shows "View on GitHub".
struct GitHubMarkLabel: View {
    /// The visible text beside the mark, or `nil` for an icon-only control (the popover
    /// footer). Settings passes "View on GitHub".
    var title: String?
    /// The rendered edge length of the square mark; ~16pt matches the app's inline glyphs.
    var size: CGFloat = 16

    /// The spoken label for the whole control, preserved from the pre-redesign link so
    /// VoiceOver still announces the destination.
    static let accessibilityLabel = "View justStats on GitHub"

    var body: some View {
        Group {
            if let title {
                Label {
                    Text(title)
                } icon: {
                    mark
                }
            } else {
                mark
            }
        }
        .accessibilityLabel(Self.accessibilityLabel)
    }

    /// The tintable mark itself, fixed to a square `size × size` frame. No color of its own
    /// — the ambient `foregroundStyle` fills it, so it adapts to light/dark and to any tint
    /// the enclosing `Link`/`Label` applies.
    private var mark: some View {
        GitHubMark()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The GitHub mark's outline as a unit-normalized `Path` (coordinates in `0...1`).
///
/// Isolated in its own namespace so the (long, machine-like) coordinate list stays out of
/// the readable view code above, and so `GitHubMark` shares a single cached geometry.
///
/// The points are the official GitHub `mark-github` (Octocat) glyph, authored on a 16×16
/// canvas and stored here as `authored / 16` so the shape fits exactly inside a unit
/// square and scales to any size without distortion. It is a single closed subpath (the
/// published mark is one compound path), filled by the caller with the ambient color.
enum GitHubMarkPath {
    /// The normalized Octocat silhouette, built once and reused by every `GitHubMark`.
    static let octocat: Path = {
        var path = Path()
        // Local shorthand for a normalized point, so the transcribed coordinate list below
        // reads as a compact list of `n(x, y)` control points.
        func n(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

        path.move(to: n(0.422875, 0.708000))
        path.addCurve(to: n(0.203125, 0.479500), control1: n(0.293937, 0.692375), control2: n(0.203125, 0.599625))
        path.addCurve(to: n(0.250000, 0.342750), control1: n(0.203125, 0.430687), control2: n(0.220688, 0.377937))
        path.addCurve(to: n(0.253937, 0.213875), control1: n(0.237313, 0.310562), control2: n(0.239250, 0.242187))
        path.addCurve(to: n(0.376937, 0.257812), control1: n(0.293000, 0.209000), control2: n(0.345687, 0.229500))
        path.addCurve(to: n(0.501000, 0.240250), control1: n(0.414062, 0.246125), control2: n(0.453125, 0.240250))
        path.addCurve(to: n(0.623062, 0.256812), control1: n(0.548813, 0.240250), control2: n(0.587875, 0.246125))
        path.addCurve(to: n(0.746125, 0.213875), control1: n(0.653312, 0.229500), control2: n(0.707062, 0.209000))
        path.addCurve(to: n(0.749000, 0.341812), control1: n(0.759750, 0.240250), control2: n(0.761750, 0.308562))
        path.addCurve(to: n(0.796875, 0.479500), control1: n(0.780250, 0.378875), control2: n(0.796875, 0.428687))
        path.addCurve(to: n(0.575187, 0.707000), control1: n(0.796875, 0.599625), control2: n(0.706062, 0.690437))
        path.addCurve(to: n(0.630812, 0.829125), control1: n(0.608375, 0.728500), control2: n(0.630812, 0.775375))
        path.addLine(to: n(0.630812, 0.930687))
        path.addCurve(to: n(0.684562, 0.964875), control1: n(0.630812, 0.959937), control2: n(0.655250, 0.976562))
        path.addCurve(to: n(1.000000, 0.501875), control1: n(0.861313, 0.897437), control2: n(1.000000, 0.720625))
        path.addCurve(to: n(0.499000, 0.000000), control1: n(1.000000, 0.225625), control2: n(0.775375, 0.000000))
        path.addCurve(to: n(0.000000, 0.501938), control1: n(0.222688, 0.000000), control2: n(0.000000, 0.225625))
        path.addCurve(to: n(0.323250, 0.965813), control1: n(-0.000576, 0.709171), control2: n(0.128636, 0.894596))
        path.addCurve(to: n(0.375000, 0.931625), control1: n(0.349625, 0.975562), control2: n(0.375000, 0.958000))
        path.addLine(to: n(0.375000, 0.853500))
        path.addCurve(to: n(0.328125, 0.863250), control1: n(0.361312, 0.859375), control2: n(0.343750, 0.863250))
        path.addCurve(to: n(0.198250, 0.762687), control1: n(0.263688, 0.863250), control2: n(0.225625, 0.828125))
        path.addCurve(to: n(0.153313, 0.717750), control1: n(0.187500, 0.736312), control2: n(0.175750, 0.720687))
        path.addCurve(to: n(0.137688, 0.706063), control1: n(0.141625, 0.716812), control2: n(0.137688, 0.711938))
        path.addCurve(to: n(0.176750, 0.685563), control1: n(0.137688, 0.694312), control2: n(0.157250, 0.685563))
        path.addCurve(to: n(0.254875, 0.739313), control1: n(0.205063, 0.685563), control2: n(0.229500, 0.703125))
        path.addCurve(to: n(0.319312, 0.780250), control1: n(0.274438, 0.767563), control2: n(0.294875, 0.780250))
        path.addCurve(to: n(0.381812, 0.749000), control1: n(0.343750, 0.780250), control2: n(0.359375, 0.771500))
        path.addCurve(to: n(0.422875, 0.708000), control1: n(0.398438, 0.732437), control2: n(0.411187, 0.717750))
        path.closeSubpath()

        return path
    }()
}
