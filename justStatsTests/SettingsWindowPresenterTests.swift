import AppKit
import XCTest
@testable import justStats

/// SET-003: the popover gear and ⌘, must both open the *same* Settings window,
/// and repeated invocation must re-focus it rather than spawn duplicates. That
/// single-instance guarantee lives in `SettingsWindowPresenter`; these tests pin
/// it down. Actual ⌘, keypress delivery and window activation are manual (they
/// need a running app that is frontmost) — noted in the task report.
@MainActor
final class SettingsWindowPresenterTests: XCTestCase {
    /// Builds a controller wired to an isolated, store-backed view model so no test
    /// touches `UserDefaults.standard` and the launch controller never touches real
    /// Login Items.
    private func makeIsolatedController() -> SettingsWindowController {
        let defaults = makeIsolatedDefaults()
        let store = ThresholdConfigurationStore(defaults: defaults)
        let model = SettingsViewModel(
            store: store,
            launchAtLoginController: MockLaunchAtLoginController()
        )
        return SettingsWindowController(viewModel: model)
    }

    func testControllerIsBuiltLazilyOnFirstRequest() {
        var buildCount = 0
        let presenter = SettingsWindowPresenter(make: {
            buildCount += 1
            return self.makeIsolatedController()
        })

        XCTAssertEqual(buildCount, 0, "No controller should exist before the first open")

        _ = presenter.settingsController()

        XCTAssertEqual(buildCount, 1)
    }

    func testRepeatedOpenReturnsTheSameControllerInstance() {
        var buildCount = 0
        let presenter = SettingsWindowPresenter(make: {
            buildCount += 1
            return self.makeIsolatedController()
        })

        let first = presenter.settingsController()
        let second = presenter.settingsController()
        let third = presenter.settingsController()

        XCTAssertTrue(first === second)
        XCTAssertTrue(second === third)
        XCTAssertEqual(buildCount, 1, "The factory must run exactly once no matter how often Settings is opened")
    }

    func testRepeatedOpenReusesTheSameWindow() {
        let presenter = SettingsWindowPresenter(make: makeIsolatedController)

        presenter.openSettings()
        let firstWindow = presenter.settingsController().window
        presenter.openSettings()
        let secondWindow = presenter.settingsController().window

        XCTAssertNotNil(firstWindow)
        XCTAssertTrue(firstWindow === secondWindow, "Both opens must present the one owned window")
    }

    func testOpenSettingsOrdersTheWindowFront() {
        let presenter = SettingsWindowPresenter(make: makeIsolatedController)

        presenter.openSettings()

        // show() calls makeKeyAndOrderFront; a borderless test window becomes visible.
        XCTAssertEqual(presenter.settingsController().window?.isVisible, true)
    }

    // MARK: - Lifecycle (SET-004)

    /// Closing the Settings window must not destroy the controller: the single owned
    /// window survives `close()` (it is not released-on-close) so a later open reuses
    /// the same window rather than dangling the controller's `window` reference or
    /// spawning a duplicate. This pins the intentional-retain design SET-004 audits.
    func testWindowSurvivesCloseAndReopenReusesIt() {
        let presenter = SettingsWindowPresenter(make: makeIsolatedController)

        presenter.openSettings()
        let controller = presenter.settingsController()
        let window = controller.window
        XCTAssertNotNil(window)

        window?.performClose(nil)
        window?.close()

        // The controller still owns the very same window after a close — nothing was
        // released — and reopening presents it again.
        XCTAssertTrue(presenter.settingsController() === controller)
        XCTAssertTrue(presenter.settingsController().window === window)

        presenter.openSettings()
        XCTAssertEqual(presenter.settingsController().window?.isVisible, true)
    }

    /// No leaked controller: once the presenter is released, its owned controller
    /// (and, through it, the window and the single `SettingsViewModel`) deallocates.
    /// The presenter is the sole strong owner, so nothing outlives it — the whole
    /// Settings graph is freed rather than leaking a retained `NSWindowController`.
    func testReleasingPresenterDeallocatesTheController() {
        weak var weakController: SettingsWindowController?

        autoreleasepool {
            var presenter: SettingsWindowPresenter? =
                SettingsWindowPresenter(make: makeIsolatedController)
            weakController = presenter?.settingsController()
            XCTAssertNotNil(weakController)

            // Drop the only strong reference — the presenter that owns the controller.
            // Nothing else retains it, so it must deallocate.
            presenter = nil
        }

        XCTAssertNil(weakController, "The controller must deallocate once the presenter is released")
    }
}
