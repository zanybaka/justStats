import AppKit

/// Builds the minimal main menu that gives an LSUIElement app the standard ⌘,
/// Settings shortcut (SET-003, TECHSPEC §8: "⌘, for Settings" Mac-citizen baseline).
///
/// A menu-bar-only app (`LSUIElement`) shows no menu bar, so this menu is never
/// seen. It exists solely so `NSApplication` has a `mainMenu` through which it can
/// dispatch the ⌘, key equivalent while the app is frontmost — which it is once the
/// popover is open or the Settings window has focus. Without a main menu, AppKit has
/// nowhere to route the shortcut and ⌘, does nothing.
///
/// The menu follows the standard structure (an application menu as the first item,
/// its title ignored by AppKit which substitutes the process name) containing a
/// "Settings…" item with the conventional "," key equivalent and the ⌘ modifier.
/// A "Quit" item is included so the app is quittable via ⌘Q while active — a
/// menu-bar app with no window and no menu is otherwise awkward to quit from the
/// keyboard.
enum SettingsMenu {
    /// The Settings item's key equivalent — the "," half of ⌘, (the ⌘ modifier is
    /// applied separately). Exposed for tests that assert the shortcut is wired.
    static let settingsKeyEquivalent = ","

    /// Builds the main menu. `target`/`action` back the Settings item so it invokes
    /// the caller (the AppDelegate) rather than relying on responder-chain lookup,
    /// which is unreliable for an app whose key window may be a plain SwiftUI-hosting
    /// `NSWindow`.
    static func make(target: AnyObject, action: Selector) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: action,
            keyEquivalent: settingsKeyEquivalent
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = target
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit justStats",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)

        return mainMenu
    }
}
