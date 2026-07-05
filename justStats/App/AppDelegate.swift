import AppKit

// `@MainActor`: all `NSApplicationDelegate` callbacks arrive on the main thread,
// and the delegate owns main-actor-isolated collaborators (the Settings presenter,
// which touches the `@MainActor` window controller). Annotating the class lets it
// call those APIs synchronously without hopping actors.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Never read back, but not dead code: these strong references keep the
    // status item (and its refresh timer) alive for the app's lifetime —
    // a deallocated NSStatusItem disappears from the menu bar. The popover
    // controller must also stay retained: the button's target is weak.
    private var statusItem: NSStatusItem?
    private var iconController: IconController?
    private var popoverController: PopoverController?
    private var volumeListCoordinator: VolumeListPopoverCoordinator?

    // The single, app-owned software updater (UPD-001). Held for the app's lifetime so
    // the Sparkle controller (in a Sparkle-linked build) stays alive to run its scheduled
    // background checks — a `SPUStandardUpdaterController` created lazily and released would
    // stop checking. `SoftwareUpdaterFactory` returns the real Sparkle updater when the
    // package is linked, else a logging no-op, so this line is safe either way.
    private let softwareUpdater: SoftwareUpdating = SoftwareUpdaterFactory.makeUpdater()

    // Single-instance owner of the Settings window (SET-003). Both the popover
    // gear and the ⌘, menu item route through this presenter so repeated opens
    // re-focus the one window instead of spawning duplicates. Built with the shared
    // updater so the Settings "Check for Updates…" action drives that one instance.
    private lazy var settingsPresenter = SettingsWindowPresenter(softwareUpdater: softwareUpdater)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Minimal main menu so ⌘, opens Settings while the app is active. An
        // LSUIElement app has no menu bar of its own, but AppKit still routes
        // key equivalents through `NSApp.mainMenu` whenever the app is frontmost
        // (which it is after the popover opens or a window is focused). This is
        // the standard Mac-citizen affordance (⌘, → Settings) for an app that
        // otherwise has no menu bar — see docs/techspec.md §8. The menu is
        // invisible in the UI (LSUIElement hides the bar); it exists purely to
        // host the ⌘, key equivalent.
        NSApp.mainMenu = SettingsMenu.make(target: self, action: #selector(openSettings(_:)))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            let controller = IconController(button: button)
            iconController = controller
            // One manual refresh so the icon is correct immediately on launch (NFR3),
            // then the fixed 30s icon tier keeps it live (TECHSPEC §3 tier 1).
            controller.refresh()
            controller.startPeriodicRefresh()

            // Popover tier (TECHSPEC §3 tier 2): click toggles the transient
            // popover; the icon tier above keeps refreshing independently.
            // The coordinator (VOL-004) supplies fresh volume-list content per
            // open and drives enumeration through the shell's seams. The header
            // gear (SET-003) opens the shared Settings window via the presenter.
            let coordinator = VolumeListPopoverCoordinator(
                // The gear routes here; `openSettings` (below) closes the popover
                // first so no orphaned popover is left behind the Settings window
                // (UX-013). `self` is the retained owner of the popover controller.
                onOpenSettings: { [weak self] in self?.openSettings(nil) }
            )
            volumeListCoordinator = coordinator
            let popover = PopoverController(
                makeContentViewController: { coordinator.makeContentViewController() }
            )
            popover.onOpen = { coordinator.popoverDidOpen() }
            popover.onClose = { coordinator.popoverDidClose() }
            popover.attach(to: button)
            popoverController = popover
        }
    }

    /// The single settings-open path (SET-003, UX-013): both the popover gear and
    /// the ⌘, menu item land here. Closes the popover first — a `.transient`
    /// popover is not dismissed by programmatically bringing up an in-app window,
    /// so without this the popover would be orphaned behind the Settings window —
    /// then opens (or re-focuses) the single Settings window and makes it key.
    @objc private func openSettings(_ sender: Any?) {
        popoverController?.close()
        settingsPresenter.openSettings()
    }
}
