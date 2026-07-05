import AppKit
import XCTest
@testable import justStats

/// SET-003: ⌘, must open Settings while the app is active. For an LSUIElement app
/// with no visible menu bar, that shortcut is delivered through a programmatic
/// `NSApp.mainMenu` whose application submenu holds a "Settings…" item with the
/// "," key equivalent and the ⌘ modifier. These tests verify that item is wired
/// correctly. The final leg — AppKit actually dispatching a physical ⌘, keystroke
/// to this item — is manual (needs a frontmost running app) and noted in the task
/// report.
final class SettingsMenuTests: XCTestCase {
    /// A throwaway target with a selector matching the AppDelegate's menu action
    /// shape, so the menu can be built without standing up the whole app.
    private final class SpyTarget {
        private(set) var openCount = 0
        @objc func openSettings(_ sender: Any?) { openCount += 1 }
    }

    private func settingsItem(in menu: NSMenu) -> NSMenuItem? {
        // The application menu is the first top-level item's submenu.
        menu.items.first?.submenu?.items.first { $0.title == "Settings…" }
    }

    func testMenuExposesASettingsItemWithCommandComma() {
        let target = SpyTarget()
        let menu = SettingsMenu.make(target: target, action: #selector(SpyTarget.openSettings(_:)))

        let item = settingsItem(in: menu)
        XCTAssertNotNil(item, "The application submenu must contain a Settings… item")
        XCTAssertEqual(item?.keyEquivalent, ",")
        XCTAssertEqual(item?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(SettingsMenu.settingsKeyEquivalent, ",")
    }

    func testSettingsItemTargetsTheProvidedActionAndTarget() {
        let target = SpyTarget()
        let menu = SettingsMenu.make(target: target, action: #selector(SpyTarget.openSettings(_:)))

        let item = settingsItem(in: menu)
        XCTAssertTrue(item?.target === target)
        XCTAssertEqual(item?.action, #selector(SpyTarget.openSettings(_:)))
    }

    func testTriggeringTheSettingsItemInvokesTheAction() {
        let target = SpyTarget()
        let menu = SettingsMenu.make(target: target, action: #selector(SpyTarget.openSettings(_:)))

        guard let item = settingsItem(in: menu), let action = item.action else {
            return XCTFail("Settings item or action missing")
        }
        // Simulate AppKit dispatching the item's action to its target (what a real
        // ⌘, keystroke ultimately does once the app is frontmost).
        _ = (item.target as AnyObject).perform(action, with: item)

        XCTAssertEqual(target.openCount, 1)
    }

    func testMenuIncludesAQuitItemWithCommandQ() {
        let target = SpyTarget()
        let menu = SettingsMenu.make(target: target, action: #selector(SpyTarget.openSettings(_:)))

        let quit = menu.items.first?.submenu?.items.first { $0.title == "Quit justStats" }
        XCTAssertNotNil(quit)
        XCTAssertEqual(quit?.keyEquivalent, "q")
        XCTAssertEqual(quit?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(quit?.action, #selector(NSApplication.terminate(_:)))
    }
}
