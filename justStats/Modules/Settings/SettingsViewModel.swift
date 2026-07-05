import Combine
import Foundation

/// Backs the Settings window's threshold controls (SET-001, PRD FR10). Bridges the
/// two on-disk representations `ThresholdConfiguration` keeps — absolute bytes and a
/// percentage — to the editable fields the UI shows, and persists every edit
/// immediately through `ThresholdConfigurationStore` (the same store the icon tier
/// reads on its next tick, so a changed threshold flips the icon color without a
/// restart — no notification wiring needed because `IconController` reloads the
/// config on every read).
///
/// Design notes:
/// - The UI edits **GB** (decimal, 10^9 bytes — the same `.file` convention
///   `ByteFormat`/`ThresholdConfiguration` defaults use), not raw bytes; conversion
///   lives here so the view stays a thin binding layer.
/// - Both modes' values persist independently (the `ThresholdConfiguration` value type
///   already carries both), so switching modes never discards the other mode's numbers.
/// - Validation is *advisory*, never blocking: the `effectiveYellow = max(yellow, red)`
///   clamp is already the authoritative rule in `ThresholdConfiguration.diskState`
///   (ICON-001), so a "yellow below red" entry is still saved and simply collapses the
///   yellow band. The view model surfaces `validationWarning` so the UI can explain that,
///   but it never rejects or silently rewrites the user's number.
/// - `@MainActor`, matching the other view models — all mutation is main-thread UI state.
@MainActor
final class SettingsViewModel: ObservableObject {
    /// One decimal GB in bytes (10^9), matching `ThresholdConfiguration`'s byte
    /// defaults and `ByteFormat`'s `.file` decimal convention. Used to convert
    /// between the on-disk byte thresholds and the GB values the UI edits.
    static let bytesPerGB: Double = 1_000_000_000

    /// How the thresholds are interpreted (PRD FR10). Bound to the mode picker;
    /// changing it re-persists and swaps which pair of fields the UI shows editable.
    @Published var mode: ThresholdMode {
        didSet { persist() }
    }

    /// Red/yellow thresholds in **decimal GB** (absolute mode). Edited directly by the
    /// UI's number fields; persisted (converted to bytes) on every change. Negative
    /// entries are clamped to zero on persist so a stray minus never writes a
    /// nonsensical negative byte count.
    @Published var redGB: Double {
        didSet { persist() }
    }
    @Published var yellowGB: Double {
        didSet { persist() }
    }

    /// Red/yellow thresholds as a **percentage of capacity** (percentage mode).
    /// Persisted on every change; clamped to `0...100` on persist.
    @Published var redPercent: Double {
        didSet { persist() }
    }
    @Published var yellowPercent: Double {
        didSet { persist() }
    }

    /// Bound to the "Launch at Login" toggle (SET-002, PRD FR10, TECHSPEC §5). Whenever
    /// the toggle flips, `didSet` calls `register()`/`unregister()` through the
    /// `LaunchAtLoginControlling` seam, then re-reads the *real* service status and writes
    /// it back here — so this value always mirrors what the system actually has registered
    /// rather than an optimistic cached bool. If registration fails or the item is left in
    /// a non-`.enabled` state (e.g. awaiting the user's approval in System Settings), the
    /// toggle snaps back to reflect the true status.
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// Bound to the "Automatically check for updates" toggle (UPD-001, PRD FR12). Whenever
    /// the toggle flips, `didSet` writes the new value through the `SoftwareUpdating` seam,
    /// which (in the Sparkle build) persists it via Sparkle's own setting so it survives
    /// relaunch. Seeded from the seam's current value in `init`, so this always mirrors the
    /// real persisted state rather than an app-local duplicate.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { applyAutomaticUpdateChecks() }
    }

    private let store: ThresholdConfigurationStore
    private let launchAtLoginController: LaunchAtLoginControlling
    private let softwareUpdater: SoftwareUpdating
    /// Guards `persist()` and `applyLaunchAtLogin()` during the initial hydration so
    /// setting the published fields in `init` doesn't write back a round-tripped copy or
    /// re-register the login item before the user has touched anything.
    private var isHydrating = true

    init(
        store: ThresholdConfigurationStore = ThresholdConfigurationStore(),
        launchAtLoginController: LaunchAtLoginControlling = SMAppServiceLaunchAtLogin(),
        softwareUpdater: SoftwareUpdating? = nil
    ) {
        self.store = store
        self.launchAtLoginController = launchAtLoginController
        // Built here rather than as a default argument because `SoftwareUpdaterFactory`
        // (and the Sparkle controller it may return) is `@MainActor`-isolated, and a
        // default-argument expression runs in a nonisolated context — same reason
        // `SettingsWindowController` builds its view model in its body. Tests inject a mock.
        self.softwareUpdater = softwareUpdater ?? SoftwareUpdaterFactory.makeUpdater()
        let configuration = store.load()
        mode = configuration.mode
        redGB = Self.gb(fromBytes: configuration.redBytes)
        yellowGB = Self.gb(fromBytes: configuration.yellowBytes)
        redPercent = configuration.redPercent
        yellowPercent = configuration.yellowPercent
        // Seed the toggle from the real registration status, not a persisted flag —
        // `UserDefaults` is never the source of truth for login-item state (TECHSPEC §5).
        launchAtLogin = launchAtLoginController.isEnabled
        // Seed from the updater's current (Sparkle-persisted) value, so the toggle mirrors
        // the real setting rather than an app-local copy.
        automaticallyChecksForUpdates = self.softwareUpdater.automaticallyChecksForUpdates
        isHydrating = false
    }

    /// The advisory validation message for the *current* mode, or `nil` when the
    /// thresholds are ordered sanely (yellow ≥ red). Non-blocking: the value is still
    /// saved; this only explains the `effectiveYellow = max(yellow, red)` clamp
    /// (ICON-001) so the UI can show why a lower yellow won't widen the warning band.
    var validationWarning: String? {
        switch mode {
        case .absolute:
            return yellowGB < redGB ? Self.yellowBelowRedWarning : nil
        case .percentage:
            return yellowPercent < redPercent ? Self.yellowBelowRedWarning : nil
        }
    }

    /// Advisory text shown when yellow is set below red. Explains the clamp rather
    /// than blocking the entry (the value is still persisted).
    static let yellowBelowRedWarning =
        "Yellow is below red, so the yellow warning band is disabled until yellow is at least red."

    /// The current editable state as a persistable `ThresholdConfiguration`, with the
    /// UI's GB/percent fields converted and clamped to sane ranges. Exposed for tests
    /// and reused by `persist()`; building the value here keeps the clamp rules in one
    /// place.
    var currentConfiguration: ThresholdConfiguration {
        ThresholdConfiguration(
            mode: mode,
            redBytes: Self.bytes(fromGB: redGB),
            yellowBytes: Self.bytes(fromGB: yellowGB),
            redPercent: Self.clampPercent(redPercent),
            yellowPercent: Self.clampPercent(yellowPercent)
        )
    }

    /// Writes the current fields to `UserDefaults` immediately (SET-001: "changes
    /// persist immediately"). A no-op during initial hydration.
    private func persist() {
        guard !isHydrating else { return }
        store.save(currentConfiguration)
    }

    /// A human-readable message when the last Launch-at-Login change failed, or `nil` when
    /// the toggle applied cleanly. Advisory, non-blocking — surfaced next to the toggle so
    /// the user learns why the item didn't register (e.g. permission denied) without a
    /// modal. Cleared on the next successful apply.
    @Published private(set) var launchAtLoginError: String?

    /// Applies a `launchAtLogin` toggle change by registering/unregistering through the
    /// `LaunchAtLoginControlling` seam (TECHSPEC §5), then re-reading the *real* service
    /// status and reconciling `launchAtLogin` to it. This is what makes the toggle reflect
    /// the true system state rather than an optimistic cached bool: if `enable()`/
    /// `disable()` throws, or the item ends up in a non-`.enabled` state (e.g. awaiting
    /// approval in System Settings), the toggle snaps back to the actual status.
    ///
    /// A no-op during initial hydration (the toggle was just seeded from the live status,
    /// so there's nothing to apply). Reconciliation writes to `launchAtLogin` inside a
    /// re-entrancy guard so its own `didSet` doesn't recurse into another apply.
    private func applyLaunchAtLogin() {
        guard !isHydrating, !isReconcilingLaunchAtLogin else { return }

        let desired = launchAtLogin
        do {
            if desired {
                try launchAtLoginController.enable()
            } else {
                try launchAtLoginController.disable()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = Self.launchAtLoginFailure(enabling: desired)
        }

        // Reconcile to the real status regardless of success: the seam is the source of
        // truth, so the toggle shows what the system actually registered.
        reconcileLaunchAtLogin()
    }

    /// Guards the reconciliation write to `launchAtLogin` so setting it from the true
    /// status doesn't re-trigger `applyLaunchAtLogin()` via the property's `didSet`.
    private var isReconcilingLaunchAtLogin = false

    /// Snaps `launchAtLogin` to the live registration status. Only writes when the value
    /// actually differs (so a clean, already-consistent apply doesn't publish a redundant
    /// change), and shields the write from its own `didSet`.
    private func reconcileLaunchAtLogin() {
        let actual = launchAtLoginController.isEnabled
        guard actual != launchAtLogin else { return }
        isReconcilingLaunchAtLogin = true
        launchAtLogin = actual
        isReconcilingLaunchAtLogin = false
    }

    // MARK: - Software updates (UPD-001)

    /// Runs a user-initiated update check through the `SoftwareUpdating` seam (the
    /// "Check for Updates…" button). In the Sparkle build this shows Sparkle's standard
    /// update UI; in a Sparkle-less build the no-op updater only logs. A no-op during
    /// hydration is unnecessary here (nothing seeds a check), so this always forwards.
    func checkForUpdates() {
        softwareUpdater.checkForUpdates()
    }

    /// Applies an `automaticallyChecksForUpdates` toggle change by writing it through the
    /// seam (which persists it via Sparkle's own setting in the real build). A no-op during
    /// initial hydration — the toggle was just seeded from the seam's current value, so
    /// there is nothing to write back.
    private func applyAutomaticUpdateChecks() {
        guard !isHydrating else { return }
        softwareUpdater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    /// Advisory failure text shown next to the toggle when a register/unregister throws.
    static func launchAtLoginFailure(enabling: Bool) -> String {
        enabling
            ? "Couldn't enable Launch at Login. Check Login Items in System Settings."
            : "Couldn't disable Launch at Login. Check Login Items in System Settings."
    }

    // MARK: - Conversions (pure, testable)

    /// Bytes → GB for display. Decimal GB (10^9); negative byte counts (never expected)
    /// clamp to zero so the field never shows a negative capacity.
    static func gb(fromBytes bytes: Int64) -> Double {
        max(Double(bytes), 0) / bytesPerGB
    }

    /// GB → bytes for persistence. Negative GB entries clamp to zero; the result is
    /// rounded to the nearest whole byte so the stored `Int64` is stable across a
    /// save/load round-trip.
    static func bytes(fromGB gb: Double) -> Int64 {
        Int64((max(gb, 0) * bytesPerGB).rounded())
    }

    /// Clamps a percentage entry to `0...100` — a threshold outside that range has no
    /// meaning against a capacity ratio.
    static func clampPercent(_ percent: Double) -> Double {
        min(max(percent, 0), 100)
    }
}
