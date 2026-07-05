import AppKit
import SwiftUI

/// Owns the Settings window (SET-001). A plain `NSWindowController` hosting the SwiftUI
/// `SettingsView` in an `NSHostingView`, chosen over a SwiftUI `Settings` scene because
/// the app deliberately keeps its `NSApplicationMain`/`NSApplicationDelegate` lifecycle
/// (TECHSPEC §1) — a `Settings` scene requires the SwiftUI `App` lifecycle we don't use.
/// This also keeps the popover view layer untouched (VOL-*): the window is a separate,
/// self-contained surface.
///
/// Single-instance by construction: hold one `SettingsWindowController` and call
/// `show()` — the seam SET-003 needs to open from the popover gear and ⌘, without ever
/// spawning a duplicate window (repeated `show()` just re-focuses the existing one).
/// This class does not register any global keyboard shortcut or menu item itself
/// (that's SET-003); it only knows how to present and focus its window.
///
/// The window sizes itself to the SwiftUI content: the hosting view's fitting size sets
/// the initial content size, and the content is fixed-height (`SettingsView` calls
/// `fixedSize` vertically), so the window opens exactly as tall as the controls need.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// Builds the controller with a fresh `SettingsView`/`SettingsViewModel`. The view
    /// model persists to `UserDefaults.standard` by default; inject a store-backed model
    /// (e.g. `SettingsViewModel(store:)`) via `viewModel` in tests or previews if
    /// isolation is needed. The default is built inside the body rather than as a default
    /// argument so the `@MainActor` view-model init isn't called from a nonisolated
    /// default-argument context.
    convenience init(
        viewModel: SettingsViewModel? = nil,
        softwareUpdater: SoftwareUpdating? = nil
    ) {
        // Prefer an explicit view model (tests); otherwise build one, injecting the shared
        // app-owned updater so the whole app uses a single Sparkle controller rather than a
        // fresh one per Settings open.
        let model = viewModel ?? SettingsViewModel(softwareUpdater: softwareUpdater)
        let hostingView = NSHostingView(rootView: SettingsView(model: model))
        // Let the hosting view report the SwiftUI content's fitting size so the window
        // opens at the content's natural size instead of a hard-coded frame.
        hostingView.setContentHuggingPriority(.defaultHigh, for: .vertical)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        // Menu-bar app archetype: not a document window and not part of a window
        // cycle; center it and let it float at the normal level.
        //
        // Lifecycle (SET-004 audit): `isReleasedWhenClosed = false` is deliberate.
        // The single owned controller (held by `SettingsWindowPresenter`) reopens the
        // same window after a close, so the window must survive `close()` — releasing
        // it here would dangle the controller's `window` reference. This does not leak:
        // exactly one controller, one window, and one `SettingsViewModel` exist for the
        // app's lifetime, all reused across opens rather than reallocated per open, so
        // there is no per-open accumulation of view models or observers. The whole
        // graph deallocates when the presenter is released (verified in
        // `SettingsWindowPresenterTests`). The view model holds no `NotificationCenter`
        // observers or retained Combine subscriptions, so nothing outlives it.
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        window.setFrameAutosaveName("SettingsWindow")

        self.init(window: window)
    }

    /// Brings the Settings window to the front, creating nothing new — the controller
    /// already owns exactly one window. Activates the app so the window takes focus even
    /// when invoked from the menu-bar item (a menu-bar-only app isn't frontmost by
    /// default). This is the entry point SET-003 will call from the popover gear and ⌘,.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
