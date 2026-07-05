import AppKit

/// Single-instance owner of the Settings window (SET-003, PRD FR10–FR11).
///
/// Both entry points that open Settings — the popover gear button and the ⌘,
/// menu item — call `openSettings()` here rather than constructing a controller
/// themselves. The presenter lazily builds exactly one `SettingsWindowController`
/// on first request and reuses it forever after, so repeated gear clicks and ⌘,
/// presses re-focus the existing window instead of spawning duplicates
/// (`SettingsWindowController.show()` just re-orders the same window to front).
///
/// The controller is created lazily (not at app launch) so the Settings surface
/// costs nothing until the user actually asks for it — consistent with the
/// menu-bar app's "do the minimum until needed" posture.
///
/// A `make` factory is injected so tests can supply a controller built with an
/// isolated, store-backed `SettingsViewModel` (no `UserDefaults.standard` writes)
/// and assert the same instance is returned across repeated opens. Production uses
/// the default factory, which builds the standard controller.
@MainActor
final class SettingsWindowPresenter {
    private let make: () -> SettingsWindowController
    private var controller: SettingsWindowController?

    /// Seam for tests; production uses `init()` or `init(softwareUpdater:)`.
    init(make: @escaping () -> SettingsWindowController) {
        self.make = make
    }

    convenience init() {
        self.init(make: { SettingsWindowController() })
    }

    /// Production init used by the app: injects the single, app-owned `SoftwareUpdating`
    /// into the Settings controller so the whole app shares one Sparkle updater (UPD-001).
    convenience init(softwareUpdater: SoftwareUpdating) {
        self.init(make: { SettingsWindowController(softwareUpdater: softwareUpdater) })
    }

    /// Opens the Settings window, building it on first call and reusing the same
    /// instance thereafter. Always brings it to the front and activates the app.
    func openSettings() {
        settingsController().show()
    }

    /// The single owned controller, created on demand. Exposed (internal) so the
    /// menu action and tests can reach the same instance the gear does.
    func settingsController() -> SettingsWindowController {
        if let controller {
            return controller
        }
        let created = make()
        controller = created
        return created
    }
}
