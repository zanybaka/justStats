import AppKit
import Foundation

/// Opens the macOS **Full Disk Access** privacy pane in System Settings (SCAN-006,
/// TECHSPEC §7). Kept behind a tiny protocol so the notice's "Open Settings" button
/// depends on an abstraction: tests assert *which* URL would be opened without
/// actually launching System Settings, and only the real deep link is verified
/// manually (there is no automatable way to confirm the pane opened).
protocol FullDiskAccessSettingsOpening {
    /// Opens the Full Disk Access pane. Called on the main thread from the notice's
    /// button action; does no work off the caller's thread.
    func openFullDiskAccessSettings()
}

/// The exact System Settings deep link for the Full Disk Access privacy pane
/// (TECHSPEC §7). A `URL`-safe constant so the string is written once and asserted
/// in tests, never retyped at a call site.
enum SystemSettingsLink {
    /// `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` —
    /// the Full Disk Access pane. Force-unwrapped only because it is a compile-time
    /// literal known to parse; a test guards the exact string so a typo is caught
    /// before it can crash.
    static let fullDiskAccess = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
}

/// Production opener: hands the deep link to `NSWorkspace`, which launches System
/// Settings on the correct pane. No fallback UI — if the OS can't open the URL there
/// is nothing meaningful the app can do, and the notice text already tells the user
/// where to go.
struct SystemSettingsOpener: FullDiskAccessSettingsOpening {
    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(SystemSettingsLink.fullDiskAccess)
    }
}
