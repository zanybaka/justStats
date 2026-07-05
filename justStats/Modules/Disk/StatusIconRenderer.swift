import AppKit

/// Draws the non-template menu bar icon for each `DiskState` (TECHSPEC §8).
///
/// Template images cannot carry a real color, so macOS's automatic light/dark and
/// highlighted-state adaptation does not apply here. Every variant is rendered
/// explicitly with concrete sRGB colors picked for that background, plus a subtle
/// contrast outline so the glyph stays readable on any menu bar tint.
struct StatusIconRenderer {
    /// Menu bar background the icon will sit on.
    struct Variant: Equatable {
        /// Dark menu bar (dark mode or a dark wallpaper tint).
        var isDark: Bool
        /// Pressed/open state — the system draws a dark selection behind the button.
        var isHighlighted: Bool
    }

    /// Point size of the square icon canvas (menu bar is 22 pt tall; ~18 pt is the
    /// conventional status-item glyph size).
    static let canvasSize: CGFloat = 18

    /// Returns a freshly drawn non-template image for the given state and background.
    /// Colors are resolved at creation time, so draw-time appearance never matters.
    func image(for state: DiskState, variant: Variant) -> NSImage {
        let size = NSSize(width: Self.canvasSize, height: Self.canvasSize)
        let palette = Palette(state: state, variant: variant)
        let image = NSImage(size: size, flipped: false) { rect in
            switch state {
            case .green, .yellow:
                Self.drawDisk(in: rect, palette: palette)
            case .red:
                // Red also changes shape (warning triangle + exclamation mark) so the
                // critical state never relies on hue alone (PRD FR1 correction).
                Self.drawWarningTriangle(in: rect, palette: palette)
            }
            return true
        }
        // Explicit: a template image would be flattened to monochrome by the system.
        image.isTemplate = false
        return image
    }

    // MARK: - Colors

    private struct Palette {
        let fill: NSColor
        let outline: NSColor
        /// Exclamation mark on the red warning triangle.
        let glyph: NSColor

        init(state: DiskState, variant: Variant) {
            // Apple system-palette values (light / dark), pinned as concrete sRGB so
            // rendering is deterministic and independent of the current appearance.
            let onDarkBackground = variant.isDark || variant.isHighlighted
            switch state {
            case .green:
                fill = onDarkBackground
                    ? NSColor(srgbRed: 48 / 255, green: 209 / 255, blue: 88 / 255, alpha: 1)
                    : NSColor(srgbRed: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1)
            case .yellow:
                fill = onDarkBackground
                    ? NSColor(srgbRed: 255 / 255, green: 214 / 255, blue: 10 / 255, alpha: 1)
                    : NSColor(srgbRed: 255 / 255, green: 204 / 255, blue: 0 / 255, alpha: 1)
            case .red:
                fill = onDarkBackground
                    ? NSColor(srgbRed: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
                    : NSColor(srgbRed: 255 / 255, green: 59 / 255, blue: 48 / 255, alpha: 1)
            }
            // Subtle outline gives the colored fill contrast against any bar tint:
            // dark stroke on a light bar, light stroke on a dark bar, and a stronger
            // light stroke while the pressed selection is drawn behind the button.
            if variant.isHighlighted {
                outline = NSColor.white.withAlphaComponent(0.55)
            } else if variant.isDark {
                outline = NSColor.white.withAlphaComponent(0.4)
            } else {
                outline = NSColor.black.withAlphaComponent(0.35)
            }
            glyph = .white
        }
    }

    // MARK: - Glyphs

    /// Green/yellow states: a filled disk (circle) with a contrast outline.
    private static func drawDisk(in rect: NSRect, palette: Palette) {
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
        path.lineWidth = 1
        palette.fill.setFill()
        path.fill()
        palette.outline.setStroke()
        path.stroke()
    }

    /// Red state: a warning triangle with an exclamation mark — a distinct shape,
    /// not just a hue change.
    private static func drawWarningTriangle(in rect: NSRect, palette: Palette) {
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: rect.midX, y: rect.maxY - 1.5))
        triangle.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 2))
        triangle.line(to: NSPoint(x: rect.minX + 1, y: rect.minY + 2))
        triangle.close()
        triangle.lineJoinStyle = .round
        triangle.lineWidth = 1
        palette.fill.setFill()
        triangle.fill()
        palette.outline.setStroke()
        triangle.stroke()

        palette.glyph.setFill()
        let bar = NSRect(x: rect.midX - 1, y: rect.minY + 7, width: 2, height: 5.5)
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        let dot = NSRect(x: rect.midX - 1, y: rect.minY + 3.5, width: 2, height: 2)
        NSBezierPath(ovalIn: dot).fill()
    }
}
