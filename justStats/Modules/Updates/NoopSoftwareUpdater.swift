import Foundation
import OSLog

/// Fallback `SoftwareUpdating` used when Sparkle is not linked into the build (UPD-001,
/// integration path B). It performs no real update check — `checkForUpdates()` only logs
/// that updates are unavailable in this build — but it fully satisfies the seam so the
/// Settings UI (the "Check for Updates…" button and the automatic-check toggle) compiles
/// and behaves predictably with or without Sparkle.
///
/// The automatic-check flag is persisted under an app-owned `UserDefaults` key
/// (`DefaultsKey.automaticallyChecksForUpdates`) so the toggle still round-trips across
/// relaunches in a Sparkle-less build. When Sparkle *is* linked, `SparkleUpdaterController`
/// is used instead and delegates the same flag to Sparkle's own persisted setting.
///
/// `SoftwareUpdaterFactory` selects `SparkleUpdaterController` automatically when
/// `canImport(Sparkle)` holds, falling back to this type otherwise — so wiring the real
/// updater is a package-link change, not a code change at the call sites.
@MainActor
final class NoopSoftwareUpdater: SoftwareUpdating {
    private static let log = Logger(subsystem: "com.zanybaka.justStats", category: "updates")

    private let defaults: UserDefaults

    /// - Parameter defaults: where the automatic-check flag is stored; injectable so tests
    ///   use an isolated suite instead of `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func checkForUpdates() {
        Self.log.info("Update check not available in this build (Sparkle not linked).")
    }

    var automaticallyChecksForUpdates: Bool {
        get { defaults.bool(forKey: DefaultsKey.automaticallyChecksForUpdates) }
        set { defaults.set(newValue, forKey: DefaultsKey.automaticallyChecksForUpdates) }
    }
}
