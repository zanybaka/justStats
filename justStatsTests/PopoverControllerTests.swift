import AppKit
import SwiftUI
import XCTest
@testable import justStats

final class PopoverControllerTests: XCTestCase {
    /// Mock presenter for the toggle state machine. `close()` only flips
    /// `isShown` — tests simulate the AppKit `popoverDidClose` delegate callback
    /// explicitly, mirroring how a real `NSPopover` reports dismissal.
    private final class MockPopoverPresenter: PopoverPresenting {
        private(set) var isShown = false
        var contentViewController: NSViewController?
        var contentSize: NSSize = .zero
        private(set) var showCount = 0
        private(set) var closeCount = 0
        private(set) var lastPositioningView: NSView?
        private(set) var lastPreferredEdge: NSRectEdge?
        /// The content view's fitting size captured at the instant `show` fired.
        /// UX-019 requires the content to be laid out to its real size *before* the
        /// single `show`, so this must already be non-zero / correctly-sized then.
        private(set) var contentFittingSizeAtShow: NSSize?
        /// The `contentSize` the controller assigned before `show` — UX-019 sets it
        /// from the measured fitting size so the first frame is already correct.
        private(set) var contentSizeAtShow: NSSize?

        func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
            isShown = true
            showCount += 1
            lastPositioningView = positioningView
            lastPreferredEdge = preferredEdge
            contentFittingSizeAtShow = contentViewController?.view.fittingSize
            contentSizeAtShow = contentSize
        }

        func close() {
            isShown = false
            closeCount += 1
        }
    }

    private let didCloseNotification = Notification(name: NSPopover.didCloseNotification)

    /// Controllable monotonic clock for the transient re-toggle guard: tests set
    /// `now` and read it through the closure passed as `PopoverController.uptime`.
    private final class FakeClock {
        var now: TimeInterval = 1_000
        func read() -> TimeInterval { now }
    }

    // MARK: - Toggle state machine

    func testFirstToggleShowsFreshContentAnchoredBelowTheButton() {
        let presenter = MockPopoverPresenter()
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let controller = PopoverController(popover: presenter) { NSViewController() }

        controller.toggle(relativeTo: anchor)

        XCTAssertTrue(presenter.isShown)
        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertNotNil(presenter.contentViewController, "content must exist before show")
        XCTAssertTrue(presenter.lastPositioningView === anchor)
        XCTAssertEqual(presenter.lastPreferredEdge, .minY, "menu bar popover must drop below the button")
    }

    func testSecondToggleClosesInsteadOfReshowing() {
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let controller = PopoverController(popover: presenter) { NSViewController() }

        controller.toggle(relativeTo: anchor)
        controller.toggle(relativeTo: anchor)

        XCTAssertFalse(presenter.isShown)
        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.closeCount, 1)
    }

    func testContentIsRecreatedOnEachOpen() {
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let clock = FakeClock()
        var factoryCalls = 0
        var created: [NSViewController] = []
        let controller = PopoverController(popover: presenter, uptime: clock.read) {
            factoryCalls += 1
            let viewController = NSViewController()
            created.append(viewController)
            return viewController
        }

        controller.toggle(relativeTo: anchor)
        presenter.close()
        controller.popoverDidClose(didCloseNotification)
        clock.now += 1 // deliberate reopen, past the transient re-open window
        controller.toggle(relativeTo: anchor)

        XCTAssertEqual(factoryCalls, 2, "every open must build fresh content")
        XCTAssertEqual(created.count, 2)
        XCTAssertFalse(created[0] === created[1])
        XCTAssertTrue(presenter.contentViewController === created[1])
    }

    // MARK: - First-launch sizing (UX-019)

    @MainActor
    func testContentIsLaidOutToItsRealSizeBeforeTheFirstShow() {
        // The first-launch reflow bug: the popover content is an NSHostingController
        // with `sizingOptions = [.preferredContentSize]`, which only reports its size
        // after SwiftUI lays out. If `show` runs before that layout, AppKit sizes the
        // popover from a stale (zero) `preferredContentSize`, then resizes/repositions
        // once layout lands — the visible flash-then-reflow. `open` must force the
        // hosting view to lay out first, so the content already has its real fitting
        // size at the single `show`. Uses the production coordinator content to
        // exercise the real NSHostingController sizing path.
        let presenter = MockPopoverPresenter()
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let coordinator = VolumeListPopoverCoordinator()
        let controller = PopoverController(popover: presenter) {
            coordinator.makeContentViewController()
        }

        controller.toggle(relativeTo: anchor)

        let sizeAtShow = presenter.contentFittingSizeAtShow
        XCTAssertNotNil(sizeAtShow, "content must exist and be measured at show time")
        XCTAssertEqual(
            sizeAtShow?.width,
            PopoverLayout.contentWidth,
            "content must already be laid out to the fixed width before the first show (no reflow)"
        )
        XCTAssertGreaterThan(
            sizeAtShow?.height ?? 0,
            0,
            "content height must be established before the first show, not after"
        )
        XCTAssertEqual(presenter.showCount, 1, "the correct size is reached with a single show, no show-twice crutch")
    }

    @MainActor
    func testPopoverContentSizeIsSetToTheFittingSizeBeforeTheFirstShow() {
        // The real fix: `open` must assign the popover a valid `contentSize` (from the
        // measured fitting size) BEFORE `show`, so AppKit anchors the first frame at
        // the right size — reading fittingSize alone (as the prior attempt did via
        // layoutSubtreeIfNeeded) didn't reach the popover's own size in time.
        let presenter = MockPopoverPresenter()
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let coordinator = VolumeListPopoverCoordinator()
        let controller = PopoverController(popover: presenter) {
            coordinator.makeContentViewController()
        }

        controller.toggle(relativeTo: anchor)

        let sizeAtShow = presenter.contentSizeAtShow
        XCTAssertEqual(sizeAtShow?.width, PopoverLayout.contentWidth,
                       "contentSize width must be set to the fixed width before show")
        XCTAssertGreaterThan(sizeAtShow?.height ?? 0, 0,
                             "contentSize height must be set (non-zero) before show, so no reflow/jump")
    }

    // MARK: - Cross-app dismissal via global click monitor (UX-017)

    func testOpeningInstallsAGlobalClickMonitorThatClosesOnAnotherAppClick() {
        // The real cross-app fix: a menu-bar (LSUIElement) app normally never becomes
        // active, so `didResignActive` never fires on a Finder click. A global
        // mouse-down monitor observes clicks in other apps and closes the popover.
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        var installCount = 0
        var capturedHandler: (() -> Void)?
        let controller = PopoverController(
            popover: presenter,
            installGlobalClickMonitor: { handler in
                installCount += 1
                capturedHandler = handler
                return NSObject()
            },
            removeGlobalClickMonitor: { _ in }
        ) { NSViewController() }

        controller.toggle(relativeTo: anchor)
        XCTAssertEqual(installCount, 1, "opening the popover installs a global click monitor")
        XCTAssertTrue(presenter.isShown)

        // Simulate a mouse-down delivered to another application (e.g. Finder).
        capturedHandler?()
        XCTAssertFalse(presenter.isShown, "a click in another app must close the popover")
    }

    func testClosingRemovesTheGlobalClickMonitor() {
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        var removedTokens = 0
        let controller = PopoverController(
            popover: presenter,
            installGlobalClickMonitor: { _ in NSObject() },
            removeGlobalClickMonitor: { token in if token != nil { removedTokens += 1 } }
        ) { NSViewController() }

        controller.toggle(relativeTo: anchor)   // installs a monitor
        presenter.close()
        controller.popoverDidClose(didCloseNotification) // must remove it

        XCTAssertGreaterThanOrEqual(removedTokens, 1, "closing the popover removes its global monitor")
    }

    func testOnOpenFiresBeforeShowOnEveryOpen() {
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let clock = FakeClock()
        let controller = PopoverController(popover: presenter, uptime: clock.read) { NSViewController() }
        var openEvents: [(shownAtCallTime: Bool, contentPresent: Bool)] = []
        controller.onOpen = {
            openEvents.append((presenter.isShown, presenter.contentViewController != nil))
        }

        controller.toggle(relativeTo: anchor)
        presenter.close()
        controller.popoverDidClose(didCloseNotification)
        clock.now += 1 // deliberate reopen, past the transient re-open window
        controller.toggle(relativeTo: anchor)

        XCTAssertEqual(openEvents.count, 2, "onOpen must fire on each open")
        for event in openEvents {
            XCTAssertFalse(event.shownAtCallTime, "onOpen must fire before show (VOL-004 enumeration seam)")
            XCTAssertTrue(event.contentPresent, "content must already exist when onOpen fires")
        }
    }

    func testDidCloseReleasesContentAndFiresOnClose() {
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let controller = PopoverController(popover: presenter) { NSViewController() }
        var closeCount = 0
        controller.onClose = { closeCount += 1 }

        controller.toggle(relativeTo: anchor)
        XCTAssertNotNil(presenter.contentViewController)

        presenter.close()
        controller.popoverDidClose(didCloseNotification)

        XCTAssertNil(presenter.contentViewController, "closed popover must drop its SwiftUI tree")
        XCTAssertEqual(closeCount, 1)
    }

    func testTransientDismissalStillAllowsNextDeliberateToggleToOpen() {
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let clock = FakeClock()
        let controller = PopoverController(popover: presenter, uptime: clock.read) { NSViewController() }

        controller.toggle(relativeTo: anchor)
        // Simulate ESC / outside click: AppKit closes the popover and then
        // notifies the delegate, stamping the close time.
        presenter.close()
        controller.popoverDidClose(didCloseNotification)
        // A deliberate later click (well past the re-open suppression window) must
        // still open — the guard only swallows the click that *caused* a transient
        // dismissal, not an unrelated one that follows an outside click / ESC.
        clock.now += 1
        controller.toggle(relativeTo: anchor)

        XCTAssertTrue(presenter.isShown)
        XCTAssertEqual(presenter.showCount, 2)
    }

    func testClickingButtonOnAnOpenPopoverClosesItInsteadOfReopening() {
        // The transient re-toggle pitfall: AppKit dismisses a `.transient` popover
        // on the click's mouse-down (delivering `popoverDidClose`) *before* the
        // button action fires `toggle`, so `toggle` sees `isShown == false`.
        // Without the close-timestamp guard it would re-open (visible flicker, no
        // way to close via the button). With the guard, the click stays a close.
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let clock = FakeClock()
        let controller = PopoverController(popover: presenter, uptime: clock.read) { NSViewController() }

        controller.toggle(relativeTo: anchor)
        XCTAssertTrue(presenter.isShown)

        // AppKit's transient monitor closes on mouse-down, then the action fires
        // ~instantly (clock barely advances) → the re-open must be suppressed.
        presenter.close()
        controller.popoverDidClose(didCloseNotification)
        clock.now += 0.01
        controller.toggle(relativeTo: anchor)

        XCTAssertFalse(presenter.isShown, "the button click must leave the popover closed")
        XCTAssertEqual(presenter.showCount, 1, "no spurious re-open")
    }

    func testDelayedDidCloseDoesNotTearDownAReopenedPopover() {
        // A real NSPopover delivers `didClose` asynchronously. If a stale
        // `popoverDidClose` arrives after a fresh open already installed content,
        // it must not nil the live SwiftUI tree or fire `onClose` against the
        // just-opened session.
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let controller = PopoverController(popover: presenter) { NSViewController() }
        var closeCount = 0
        controller.onClose = { closeCount += 1 }

        controller.toggle(relativeTo: anchor) // open; presenter.isShown == true
        // Stale didClose from a prior close arrives while the popover is shown.
        controller.popoverDidClose(didCloseNotification)

        XCTAssertNotNil(presenter.contentViewController, "a live popover must keep its content")
        XCTAssertEqual(closeCount, 0, "onClose must not fire for a reopened popover")
    }

    // MARK: - Programmatic close (settings-open path, UX-013)

    func testCloseDismissesAnOpenPopover() {
        // The settings-open path closes the popover explicitly before bringing up
        // the Settings window, so no orphaned popover is left behind it (UX-013).
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let controller = PopoverController(popover: presenter) { NSViewController() }

        controller.toggle(relativeTo: anchor)
        XCTAssertTrue(presenter.isShown)

        controller.close()

        XCTAssertFalse(presenter.isShown, "close() must dismiss the shown popover")
        XCTAssertEqual(presenter.closeCount, 1)
    }

    func testCloseTearsDownContentAndFiresOnCloseViaDelegate() {
        // close() routes through the real NSPopover.close(), which delivers
        // popoverDidClose — so the SwiftUI tree is dropped and onClose runs, same
        // as an ESC / outside-click dismissal.
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let controller = PopoverController(popover: presenter) { NSViewController() }
        var closeCount = 0
        controller.onClose = { closeCount += 1 }

        controller.toggle(relativeTo: anchor)
        controller.close()
        // Mirror AppKit delivering didClose after the popover actually closed.
        controller.popoverDidClose(didCloseNotification)

        XCTAssertNil(presenter.contentViewController, "programmatic close must drop the SwiftUI tree")
        XCTAssertEqual(closeCount, 1, "onClose must fire so per-open state is released")
    }

    func testCloseIsANoOpWhenPopoverIsAlreadyClosed() {
        // The ⌘, menu path can fire while the popover is closed; close() must not
        // touch the presenter or spuriously fire teardown.
        let presenter = MockPopoverPresenter()
        let controller = PopoverController(popover: presenter) { NSViewController() }
        var closeCount = 0
        controller.onClose = { closeCount += 1 }

        controller.close()

        XCTAssertFalse(presenter.isShown)
        XCTAssertEqual(presenter.closeCount, 0, "no close() on an already-closed popover")
        XCTAssertEqual(closeCount, 0, "no teardown when nothing was open")
    }

    // MARK: - Resign-active close (other-app click, UX-017)

    func testResignActiveClosesAnOpenPopover() {
        // Clicking into another application (Finder, another window) deactivates
        // justStats but does not tear down the `.transient` popover. The
        // resign-active seam must close it so it doesn't linger behind the newly
        // focused app.
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let controller = PopoverController(popover: presenter) { NSViewController() }

        controller.toggle(relativeTo: anchor)
        XCTAssertTrue(presenter.isShown)

        controller.appDidResignActive()

        XCTAssertFalse(presenter.isShown, "resign-active must dismiss the shown popover")
        XCTAssertEqual(presenter.closeCount, 1)
    }

    func testResignActiveTearsDownContentAndFiresOnCloseViaDelegate() {
        // Resign-active close routes through the same NSPopover.close() path, so the
        // SwiftUI tree is dropped and onClose runs, same as ESC / outside-click.
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let controller = PopoverController(popover: presenter) { NSViewController() }
        var closeCount = 0
        controller.onClose = { closeCount += 1 }

        controller.toggle(relativeTo: anchor)
        controller.appDidResignActive()
        // Mirror AppKit delivering didClose after the popover actually closed.
        controller.popoverDidClose(didCloseNotification)

        XCTAssertNil(presenter.contentViewController, "resign-active close must drop the SwiftUI tree")
        XCTAssertEqual(closeCount, 1, "onClose must fire so per-open state is released")
    }

    func testResignActiveIsANoOpWhenPopoverIsAlreadyClosed() {
        // The app can resign active while the popover is closed; the seam must not
        // touch the presenter or spuriously fire teardown (no double-close / crash).
        let presenter = MockPopoverPresenter()
        let controller = PopoverController(popover: presenter) { NSViewController() }
        var closeCount = 0
        controller.onClose = { closeCount += 1 }

        controller.appDidResignActive()

        XCTAssertFalse(presenter.isShown)
        XCTAssertEqual(presenter.closeCount, 0, "no close() on an already-closed popover")
        XCTAssertEqual(closeCount, 0, "no teardown when nothing was open")
    }

    func testDidResignActiveNotificationClosesTheOpenPopover() {
        // End-to-end wiring: posting NSApplication.didResignActive on the injected
        // center must reach the seam and close the popover — proving the observer is
        // registered against the right notification name.
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let center = NotificationCenter()
        let controller = PopoverController(popover: presenter, notificationCenter: center) { NSViewController() }
        // Silence the "unused controller" warning while keeping it alive for the post.
        withExtendedLifetime(controller) {
            controller.toggle(relativeTo: anchor)
            XCTAssertTrue(presenter.isShown)

            center.post(name: NSApplication.didResignActiveNotification, object: nil)

            XCTAssertFalse(presenter.isShown, "didResignActive must close the shown popover")
            XCTAssertEqual(presenter.closeCount, 1)
        }
    }

    func testResignActiveObserverDoesNotRetainController() {
        // The block-based observer captures self weakly and is removed on deinit, so
        // registering it must not keep the controller alive even while the injected
        // center (which retains the block) outlives it.
        let presenter = MockPopoverPresenter()
        let center = NotificationCenter()
        weak var weakController: PopoverController?
        autoreleasepool {
            var controller: PopoverController? = PopoverController(
                popover: presenter,
                notificationCenter: center
            ) { NSViewController() }
            weakController = controller
            controller = nil
        }
        XCTAssertNil(weakController, "the resign-active observer must not retain the controller")
        // The stale weak-self block is harmless: posting after dealloc is a no-op.
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
    }

    // MARK: - Lifetime / retain cycles

    func testControllerIsReleasedAfterOpenCloseCycles() {
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let clock = FakeClock()
        var controller: PopoverController? = PopoverController(popover: presenter, uptime: clock.read) { NSViewController() }
        weak var weakController: PopoverController?
        weakController = controller

        for _ in 0..<3 {
            controller?.toggle(relativeTo: anchor)
            presenter.close()
            controller?.popoverDidClose(didCloseNotification)
            clock.now += 1 // each iteration is a genuine reopen, not a suppressed re-toggle
        }
        controller = nil

        XCTAssertNil(weakController, "repeated open/close must leave no retain cycle")
    }

    @MainActor
    func testControllerWithRealNSPopoverIsReleased() {
        // NSPopover.delegate is weak; the controller holding the popover strongly
        // must therefore still deallocate. (The popover is never shown here —
        // showing needs a real status-bar window.) Uses the real NSPopover via the
        // default popover factory and the production content factory (the
        // coordinator), mirroring AppDelegate's wiring — VOL-004 dropped the shell's
        // built-in placeholder default, so a content factory is now required.
        let coordinator = VolumeListPopoverCoordinator()
        var controller: PopoverController? = PopoverController(
            makeContentViewController: { coordinator.makeContentViewController() }
        )
        weak var weakController: PopoverController?
        weakController = controller
        controller = nil
        XCTAssertNil(weakController, "NSPopover delegate wiring must not retain the controller")
    }

    func testAttachedButtonDoesNotRetainController() {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        weak var weakController: PopoverController?
        // NSControl.target is weak, so the strongly-held button must not keep the
        // controller alive. The controller (and the transient objects its factory
        // builds) can land in the current autorelease pool, so drop the strong ref
        // and drain the pool before asserting — otherwise the check races the pool
        // rather than the retain graph (surfaces under Thread Sanitizer, which
        // defers releases past a bare synchronous XCTAssertNil).
        autoreleasepool {
            var controller: PopoverController? = PopoverController(
                popover: MockPopoverPresenter(),
                makeContentViewController: { NSViewController() }
            )
            controller?.attach(to: button)
            XCTAssertNotNil(button.target)
            weakController = controller
            controller = nil
        }
        XCTAssertNil(weakController, "NSControl.target is weak; the owner retains the controller")
    }

    // MARK: - Injected content contract
    //
    // VOL-004 removed PopoverController's built-in placeholder content
    // (PopoverPlaceholderView / makeDefaultContentViewController): the shell is now
    // content-agnostic and presents whatever its injected factory produces
    // (VolumeListPopoverCoordinator supplies the real SwiftUI list in production).
    // The SwiftUI-hosting + dynamic-height + fixed-width contract that those two
    // placeholder tests used to assert now lives against the real content in
    // VolumeListPopoverCoordinatorTests. What stays the shell's responsibility —
    // presenting exactly the factory's product on show — is asserted here.

    func testPopoverPresentsExactlyTheFactoryProducedController() {
        let presenter = MockPopoverPresenter()
        let anchor = NSView()
        let produced = NSViewController()
        let controller = PopoverController(popover: presenter) { produced }

        controller.toggle(relativeTo: anchor)

        XCTAssertTrue(
            presenter.contentViewController === produced,
            "the shell must present exactly the injected factory's controller"
        )
    }

    @MainActor
    func testDefaultInitWiresTheProductionCoordinatorHostingContent() throws {
        // The production convenience init must host real SwiftUI list content
        // (NSHostingController) with dynamic-height sizing and the shared fixed
        // width — the hosting contract VOL-003's removed placeholder used to carry,
        // now carried by the real VolumeListView the coordinator builds.
        let coordinator = VolumeListPopoverCoordinator()
        let viewController = coordinator.makeContentViewController()
        let hosting = try XCTUnwrap(
            viewController as? NSHostingController<VolumeListView>,
            "popover content must be the SwiftUI volume list in NSHostingController (TECHSPEC §1)"
        )
        XCTAssertTrue(
            hosting.sizingOptions.contains(.preferredContentSize),
            "height must track SwiftUI content via preferredContentSize (TECHSPEC §8)"
        )
        viewController.loadView()
        XCTAssertEqual(
            viewController.view.fittingSize.width,
            PopoverLayout.contentWidth,
            "popover content width must come from the shared Kit constant"
        )
        XCTAssertGreaterThan(viewController.view.fittingSize.height, 0)
    }
}
