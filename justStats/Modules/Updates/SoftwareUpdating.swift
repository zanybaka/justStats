import Foundation

/// Seam for the "Check for Updates…" action and the automatic-update-check setting
/// (UPD-001, PRD FR12, TECHSPEC §6). The Settings view model drives updates through this
/// abstraction rather than calling Sparkle directly, so the UI wiring — the "Check for
/// Updates…" button and the "automatically check" toggle — is unit-testable without a hard
/// compile dependency on Sparkle and without a real network update check in tests.
///
/// TECHSPEC §6: updates are delivered by Sparkle against an `appcast.xml` served over HTTPS
/// from `raw.githubusercontent.com`, verified with a self-managed EdDSA key. The concrete
/// `SparkleUpdaterController` (guarded by `#if canImport(Sparkle)`) wraps
/// `SPUStandardUpdaterController`; when Sparkle is not linked, `NoopSoftwareUpdater` stands
/// in so the rest of the app compiles and the seam still exists. `SoftwareUpdaterFactory`
/// picks the right one at launch.
@MainActor
protocol SoftwareUpdating: AnyObject {
    /// Kicks off a user-initiated update check (the "Check for Updates…" action). In the
    /// Sparkle implementation this shows Sparkle's own progress/available-update UI; in the
    /// no-op implementation it only logs that updates are unavailable in this build.
    func checkForUpdates()

    /// Whether Sparkle checks for updates automatically in the background. Reads and writes
    /// Sparkle's own persisted setting (`SPUUpdater.automaticallyChecksForUpdates`), which
    /// Sparkle stores in `UserDefaults` under its own key — the Settings toggle binds to
    /// this so the user's choice survives relaunch. The no-op implementation persists the
    /// value under an app-owned `UserDefaults` key so the toggle still round-trips.
    var automaticallyChecksForUpdates: Bool { get set }
}
