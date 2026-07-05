import AppKit

/// Pure per-refresh snapshot for the icon tier: the traffic-light state plus the
/// human VoiceOver sentence (PRD FR1 + its accessibility correction).
struct IconStatus: Equatable {
    let state: DiskState
    let freeBytes: Int64

    init(space: VolumeSpace, configuration: ThresholdConfiguration) {
        state = configuration.diskState(freeBytes: space.free, totalBytes: space.total)
        freeBytes = space.free
    }

    /// Spoken when the boot-volume read failed and no fresh state is known.
    static let unavailableAccessibilityLabel = "Disk status: unavailable"

    /// Human sentence for VoiceOver, e.g. "Disk status: critical, 8 GB free".
    /// Byte formatting goes through the shared `Kit` helper so the spoken free-space
    /// figure matches the popover rows exactly (same decimal `.file` style, same
    /// pinned locale) — one formatting source of truth across the app.
    var accessibilityLabel: String {
        "Disk status: \(state.spokenDescription), \(ByteFormat.text(fromBytes: freeBytes)) free"
    }
}

extension DiskState {
    /// Human word used in the VoiceOver sentence.
    var spokenDescription: String {
        switch self {
        case .green: return "OK"
        case .yellow: return "low"
        case .red: return "critical"
        }
    }
}

/// Icon tier (TECHSPEC §3, tier 1): a fixed-interval timer reads the boot volume
/// off the main thread and applies the colored status icon + VoiceOver label on
/// the main thread. Callers may also invoke `refresh()` for an immediate update.
final class IconController {
    /// Fixed icon-tier cadence (TECHSPEC §3 tier 1). Internal constant by design —
    /// the refresh interval is not user-configurable (PRD non-goal).
    static let defaultRefreshInterval: TimeInterval = 30

    private let reader: VolumeSpaceReading
    private let thresholdStore: ThresholdConfigurationStore
    private let renderer = StatusIconRenderer()
    private let refreshInterval: TimeInterval
    private let workspaceNotificationCenter: NotificationCenter
    /// statfs is sub-millisecond, but it still never runs on the main thread (NFR3).
    private let readQueue = DispatchQueue(label: QueueLabels.iconRefresh, qos: .utility)
    private weak var button: NSStatusBarButton?
    private var lastStatus: IconStatus?
    /// True while the accessibility label reports "unavailable" after a failed
    /// read; gates repeated failures and forces a label restore on recovery.
    private var isShowingUnavailableLabel = false
    private var appearanceObservation: NSKeyValueObservation?
    private var timer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?

    init(
        button: NSStatusBarButton,
        reader: VolumeSpaceReading = StatfsBootVolumeReader(),
        thresholdStore: ThresholdConfigurationStore = ThresholdConfigurationStore(),
        refreshInterval: TimeInterval = IconController.defaultRefreshInterval,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.button = button
        self.reader = reader
        self.thresholdStore = thresholdStore
        self.refreshInterval = refreshInterval
        self.workspaceNotificationCenter = workspaceNotificationCenter

        // Draw immediately so the status item is never blank (NFR3); the first
        // refresh() replaces this within milliseconds.
        applyImages(for: .green)
        button.setAccessibilityLabel("Disk status: checking")

        // A non-template image gets no automatic light/dark adaptation (TECHSPEC §8),
        // so re-render whenever the menu bar's effective appearance flips.
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyImages(for: self.lastStatus?.state ?? .green)
            }
        }
    }

    deinit {
        timer?.cancel()
        if let wakeObserver {
            workspaceNotificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Re-reads the boot volume off-main and hops back to the main thread to update
    /// the icon and accessibility label.
    func refresh() {
        readQueue.async { [weak self] in
            self?.readAndApply()
        }
    }

    /// Starts the fixed-interval icon refresh plus an immediate refresh on wake
    /// from sleep (timers don't fire while the Mac sleeps, so a disk that filled
    /// up overnight is reflected right away instead of a tick later).
    /// Idempotent: repeated calls never create duplicate timers or observers.
    func startPeriodicRefresh() {
        guard timer == nil else { return }

        let source = DispatchSource.makeTimerSource(queue: readQueue)
        // Generous leeway (10% of the interval — 3s at the default 30s) lets the
        // system coalesce wakeups; the icon doesn't need second-exact ticks.
        source.schedule(
            deadline: .now() + refreshInterval,
            repeating: refreshInterval,
            leeway: .milliseconds(max(1, Int(refreshInterval * 100)))
        )
        // Fires on the serial readQueue, so a tick can never overlap an in-flight
        // read; missed ticks are coalesced by the source, never queued up.
        source.setEventHandler { [weak self] in
            self?.readAndApply()
        }
        source.activate()
        timer = source

        wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Runs on `readQueue`: reads the boot volume, then hops to main to update UI.
    private func readAndApply() {
        // NFR3 invariant: no filesystem call in the icon tier ever runs on the
        // main thread. Debug-build check; free in release.
        dispatchPrecondition(condition: .notOnQueue(.main))
        let space = reader.readBootVolume()
        let configuration = thresholdStore.load()
        let status = space.map { IconStatus(space: $0, configuration: configuration) }
        DispatchQueue.main.async { [weak self] in
            self?.apply(status)
        }
    }

    // MARK: - Main-thread UI application

    private func apply(_ status: IconStatus?) {
        guard let status else {
            // Read failed: keep the last known icon, but tell VoiceOver the truth
            // (once — repeated failures must not re-set the same label every tick).
            if !isShowingUnavailableLabel {
                isShowingUnavailableLabel = true
                button?.setAccessibilityLabel(IconStatus.unavailableAccessibilityLabel)
            }
            return
        }
        // Change gate (TECHSPEC §7): the steady idle state — identical
        // back-to-back reads — must not rebuild images or reassign the label.
        guard status != lastStatus || isShowingUnavailableLabel else { return }
        let stateChanged = status.state != lastStatus?.state
        lastStatus = status
        isShowingUnavailableLabel = false
        if stateChanged {
            applyImages(for: status.state)
        }
        button?.setAccessibilityLabel(status.accessibilityLabel)
    }

    private func applyImages(for state: DiskState) {
        guard let button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        button.image = renderer.image(
            for: state,
            variant: StatusIconRenderer.Variant(isDark: isDark, isHighlighted: false)
        )
        // Shown while the item is pressed/open — the system draws a dark selection
        // behind the button, so hand it the high-contrast highlighted variant.
        button.alternateImage = renderer.image(
            for: state,
            variant: StatusIconRenderer.Variant(isDark: isDark, isHighlighted: true)
        )
    }
}
