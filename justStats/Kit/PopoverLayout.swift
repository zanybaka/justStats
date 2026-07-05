import CoreGraphics

/// Shared popover layout constants (TECHSPEC §8: fixed width as a shared
/// constant, height computed dynamically from content — Stats precedent).
enum PopoverLayout {
    /// Fixed popover content width in points. All popover content (VOL-004
    /// volume rows, later sections) pins itself to this width; only height
    /// is driven by the SwiftUI content.
    static let contentWidth: CGFloat = 340
}
