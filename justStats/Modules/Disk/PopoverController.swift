import AppKit
import SwiftUI

/// Abstraction over the popover surface (`NSPopover` in production) so the
/// open/close toggle state machine is unit-testable without a status-bar window.
protocol PopoverPresenting: AnyObject {
    var isShown: Bool { get }
    var contentViewController: NSViewController? { get set }
    /// The popover's content size. Set to a valid fitting size before the first
    /// show so it doesn't flash at a zero/stale size (UX-019).
    var contentSize: NSSize { get set }
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge)
    func close()
}

extension NSPopover: PopoverPresenting {}

/// Popover shell (VOL-003, TECHSPEC §1 refinement): owns a transient `NSPopover`
/// anchored to the status-bar button and toggles it on click. The popover's
/// content is a SwiftUI view tree hosted in an `NSHostingController`, recreated
/// fresh on every open — `VolumeListPopoverCoordinator` (VOL-004) plugs into
/// that recreation plus `onOpen`/`onClose` to drive volume enumeration.
///
/// The popover tier is fully independent of the icon tier: `IconController`'s
/// timer keeps refreshing the status icon whether or not the popover is open.
///
/// Transient re-toggle: a `.transient` popover is dismissed by AppKit's own event
/// monitor on the mouse-down that lands on the status button, so `popoverDidClose`
/// fires *before* the button `action` (`toggle`). `toggle` therefore cannot read
/// `isShown` as the sole truth — it would already be `false` and the click would
/// re-open the popover it was meant to close. A short close-timestamp guard
/// (`reopenSuppressionInterval`) swallows the open that immediately follows a
/// transient dismissal so the button reliably closes an open popover.
final class PopoverController: NSObject, NSPopoverDelegate {
    private let popover: PopoverPresenting
    private let makeContentViewController: () -> NSViewController

    /// A click arriving within this window of a `popoverDidClose` is treated as
    /// the trailing edge of a transient dismissal (AppKit closed the popover on
    /// mouse-down, then the button action fired), not a request to re-open.
    private static let reopenSuppressionInterval: TimeInterval = 0.2
    /// Monotonic timestamp of the last `popoverDidClose`, or nil if never closed
    /// (or if a subsequent open already consumed it). Uptime clock is unaffected
    /// by wall-clock changes.
    private var lastCloseUptime: TimeInterval?

    /// Fires on every open, before the popover is shown, so enumeration can
    /// start while the (fresh) content appears (VOL-004).
    var onOpen: (() -> Void)?
    /// Fires after the popover closed by any route — toggle click, ESC, or
    /// outside click (`.transient` dismissal). Hook for releasing per-open state.
    var onClose: (() -> Void)?

    /// Monotonic clock (`ProcessInfo.systemUptime` in production). Injected so the
    /// transient re-toggle guard can be exercised deterministically in tests.
    private let uptime: () -> TimeInterval

    /// Center the resign-active observer is registered on (default in production).
    /// Injected so tests can post `didResignActive` deterministically, or drive the
    /// close path via the `appDidResignActive` seam directly.
    private let notificationCenter: NotificationCenter
    /// Token for the block-based `didResignActive` observer, removed on `deinit`.
    /// The observation captures `self` weakly, so `NotificationCenter` retaining the
    /// block never keeps this controller alive.
    private var resignActiveObserver: NSObjectProtocol?

    /// Installs a global mouse-down monitor and returns its token (UX-017). Injected
    /// so tests can substitute a stub and fire the handler deterministically —
    /// `NSEvent`'s real global monitor only observes events destined for *other*
    /// apps and can't be exercised in a headless test.
    private let installGlobalClickMonitor: (@escaping () -> Void) -> Any?
    /// Removes a monitor token returned by `installGlobalClickMonitor`.
    private let removeGlobalClickMonitor: (Any?) -> Void
    /// The live global monitor token while the popover is shown, else nil.
    private var globalClickMonitor: Any?

    init(
        popover: PopoverPresenting = PopoverController.makeTransientPopover(),
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        notificationCenter: NotificationCenter = .default,
        installGlobalClickMonitor: @escaping (@escaping () -> Void) -> Any? = PopoverController.installRealGlobalClickMonitor,
        removeGlobalClickMonitor: @escaping (Any?) -> Void = PopoverController.removeRealMonitor,
        makeContentViewController: @escaping () -> NSViewController
    ) {
        self.popover = popover
        self.uptime = uptime
        self.notificationCenter = notificationCenter
        self.installGlobalClickMonitor = installGlobalClickMonitor
        self.removeGlobalClickMonitor = removeGlobalClickMonitor
        self.makeContentViewController = makeContentViewController
        super.init()
        // NSPopover.delegate is weak, so this creates no retain cycle. Mock
        // presenters in tests invoke the delegate methods directly instead.
        (popover as? NSPopover)?.delegate = self
        // UX-017 (secondary): if justStats ever *is* active — e.g. the Settings
        // window brought it forward — clicking away resigns active and should close
        // the popover too. This alone is NOT enough for a menu-bar (`LSUIElement`)
        // app, which normally never becomes active on a status-item click, so
        // `didResignActive` never fires for the common "click Finder" case — the
        // global click monitor installed on open is what actually handles that.
        resignActiveObserver = notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appDidResignActive()
        }
    }

    deinit {
        if let resignActiveObserver {
            notificationCenter.removeObserver(resignActiveObserver)
        }
        removeGlobalClickMonitor(globalClickMonitor)
    }

    /// Makes this controller the click target of the status-bar button.
    /// `NSControl.target` is weak — the owner (AppDelegate) must keep this
    /// controller alive.
    func attach(to button: NSStatusBarButton) {
        button.target = self
        button.action = #selector(statusButtonClicked(_:))
    }

    /// Click → toggle. `isShown` alone is unreliable for a `.transient` popover:
    /// AppKit dismisses it on the click's mouse-down before this action fires, so
    /// a click meant to close reads `isShown == false`. If the popover just closed
    /// (within `reopenSuppressionInterval`), swallow the click instead of
    /// re-opening — the transient dismissal already did the closing.
    func toggle(relativeTo view: NSView) {
        if popover.isShown {
            popover.close()
        } else if consumeRecentTransientDismissal() {
            return
        } else {
            open(relativeTo: view)
        }
    }

    /// Programmatically dismisses the popover if it is shown (no-op otherwise).
    /// Unlike a `.transient` outside-click dismissal, opening an in-app window does
    /// not reliably tear the popover down, so the settings-open path (UX-013) must
    /// close it explicitly first to avoid leaving an orphaned popover behind the
    /// Settings window. Routing through `NSPopover.close()` still fires
    /// `popoverDidClose`, so the content teardown + `onClose` seam (and the global
    /// monitor removal) run as usual.
    func close() {
        guard popover.isShown else { return }
        popover.close()
    }

    /// UX-017 seam: invoked when justStats resigns active (the user clicked another
    /// application or window while the app was active). Closes an open popover.
    /// Routing through `close()` keeps the guard (no-op when already closed) intact.
    func appDidResignActive() {
        close()
    }

    /// True iff a `popoverDidClose` landed within `reopenSuppressionInterval` of
    /// now. Consumes the timestamp either way, so only the click immediately
    /// following a transient dismissal is suppressed — a later, intentional click
    /// opens normally.
    private func consumeRecentTransientDismissal() -> Bool {
        defer { lastCloseUptime = nil }
        guard let closedAt = lastCloseUptime else { return false }
        return uptime() - closedAt < PopoverController.reopenSuppressionInterval
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Stamp the close so an immediately-following button click is recognised
        // as a transient dismissal rather than a re-open request (see `toggle`).
        lastCloseUptime = uptime()
        // The popover is no longer on screen: tear down the global click monitor so
        // it isn't left observing forever (a new one installs on the next open).
        removeGlobalClickMonitor(globalClickMonitor)
        globalClickMonitor = nil
        // A real NSPopover delivers `didClose` asynchronously; a fast close→open
        // (e.g. the transient re-toggle above, or any programmatic reopen) can let
        // a stale notification arrive after the next open already installed fresh
        // content. Only tear down if the popover is genuinely still closed —
        // otherwise this would nil out a live SwiftUI tree and fire `onClose`
        // against the just-opened session.
        guard !popover.isShown else { return }
        // Drop the SwiftUI tree so closed-popover memory returns to baseline;
        // the next open builds a fresh one.
        popover.contentViewController = nil
        onClose?()
    }

    // MARK: - Private

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        toggle(relativeTo: sender)
    }

    private func open(relativeTo view: NSView) {
        // Fresh content on every open: no stale SwiftUI state across opens,
        // and VOL-004's enumeration-on-open naturally hooks in here.
        let content = makeContentViewController()
        popover.contentViewController = content
        onOpen?()
        // UX-019: give the popover a valid content size *before* the first show. The
        // content is an NSHostingController with `sizingOptions = [.preferredContentSize]`,
        // whose `preferredContentSize` is only populated after SwiftUI lays out. On the
        // first launch that hasn't happened when `show` runs, so AppKit would size the
        // popover from a zero/stale size, anchor it there, then resize and reposition
        // once layout completes — the visible flash-then-reflow. Reading `fittingSize`
        // forces the hosting view to measure the SwiftUI content synchronously (a plain
        // `layoutSubtreeIfNeeded()` does not update `preferredContentSize` in time), and
        // setting `contentSize` from it makes the single `show` below land at the right
        // size and position. Deterministic: no dispatch-to-next-runloop, no show-twice.
        // Later opens still track streaming height via `preferredContentSize` as before.
        let fitting = content.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = fitting
        }
        // .minY: the status item sits in the menu bar, so the popover drops below it.
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        // UX-017: a `.transient` popover closes on in-app outside clicks + ESC, but a
        // menu-bar app normally never becomes active, so clicking *another* app doesn't
        // dismiss it. A global mouse-down monitor observes clicks destined for other
        // apps and closes the popover — installed only while it is shown, removed in
        // `popoverDidClose`. The status-item toggle and clicks inside the popover are
        // local events, so this monitor never fires for them.
        removeGlobalClickMonitor(globalClickMonitor)
        globalClickMonitor = installGlobalClickMonitor { [weak self] in
            self?.close()
        }
    }

    // MARK: - Production factories

    /// `.transient`: ESC and any click outside the popover (within the app) dismiss it.
    static func makeTransientPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        return popover
    }

    /// Real global monitor: observes left/right/other mouse-downs sent to *other*
    /// applications (a passive observer — it never consumes the event). Runs the
    /// handler on the main thread, where `NSEvent` global monitors are delivered.
    private static func installRealGlobalClickMonitor(_ handler: @escaping () -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            handler()
        }
    }

    private static func removeRealMonitor(_ token: Any?) {
        if let token {
            NSEvent.removeMonitor(token)
        }
    }
}
