#if canImport(Sparkle)
import Foundation
import Sparkle

/// Production `SoftwareUpdating` backed by Sparkle (UPD-001, PRD FR12, TECHSPEC §6). Wraps
/// `SPUStandardUpdaterController`, Sparkle's batteries-included controller that owns an
/// `SPUUpdater` plus the standard user-driver (the update dialogs). The feed URL and the
/// EdDSA public key that Sparkle verifies downloads against are read from `Info.plist`
/// (`SUFeedURL`, `SUPublicEDKey`), not set here — see the app's `Info.plist`.
///
/// The whole file is behind `#if canImport(Sparkle)` so the app still compiles when the
/// Sparkle package is not linked (integration path B); in that configuration
/// `SoftwareUpdaterFactory` returns `NoopSoftwareUpdater` instead. Adding the Sparkle SPM
/// package to the app target is all it takes to switch from the no-op to this controller —
/// no call-site changes.
///
/// `startingUpdater: true` lets Sparkle begin its normal scheduled-check lifecycle at
/// construction (subject to the user's automatic-check preference below);
/// `updaterDelegate`/`userDriverDelegate` are left nil to use Sparkle's standard behavior.
@MainActor
final class SparkleUpdaterController: NSObject, SoftwareUpdating {
    private let controller: SPUStandardUpdaterController

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Runs a user-initiated update check, showing Sparkle's standard progress and
    /// available-update UI. Safe to call while a check is already in flight — Sparkle
    /// coalesces it.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Bridges the Settings toggle to Sparkle's own persisted automatic-check setting, so
    /// the user's choice is stored by Sparkle (in `UserDefaults` under its own key) and
    /// survives relaunch without any extra wiring.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
#endif
