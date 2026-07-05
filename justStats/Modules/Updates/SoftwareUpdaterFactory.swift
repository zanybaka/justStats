import Foundation

/// Chooses the concrete `SoftwareUpdating` at launch (UPD-001). When the Sparkle package is
/// linked (`canImport(Sparkle)`), it builds `SparkleUpdaterController` — the real updater;
/// otherwise it builds `NoopSoftwareUpdater`, so a Sparkle-less build still compiles and the
/// "Check for Updates…" UI degrades gracefully to a no-op that only logs.
///
/// This is the single point where the app decides which updater to use, so the rest of the
/// code (AppDelegate, SettingsViewModel) depends only on the `SoftwareUpdating` seam and
/// never on Sparkle directly. Switching the fallback build to the real Sparkle updater is
/// purely a matter of adding the SPM package — no call-site edits.
///
/// NOTE: as of this commit the Sparkle package is **not** linked (integration path B), so
/// `canImport(Sparkle)` is false and this returns `NoopSoftwareUpdater` — no update check or
/// EdDSA verification runs at runtime. See `README-sparkle-integration.md` to enable path A.
enum SoftwareUpdaterFactory {
    @MainActor
    static func makeUpdater() -> SoftwareUpdating {
        #if canImport(Sparkle)
        return SparkleUpdaterController()
        #else
        return NoopSoftwareUpdater()
        #endif
    }
}
