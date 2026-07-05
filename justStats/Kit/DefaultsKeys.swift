import Foundation

/// The single source of truth for every `UserDefaults` key the app persists
/// (SET-004). All keys live here in one `Kit` namespace so there is exactly one
/// place a key string is written — no literal is duplicated anywhere else in the
/// codebase (grep for the raw strings and only this file plus the wire-contract
/// test in `ThresholdTests` will match).
///
/// These strings are a stable on-disk contract: renaming one silently orphans the
/// value a previous version stored (no schema versioning — the deliberate
/// simplicity call in TECHSPEC §2). Add new keys here rather than inlining a
/// literal at the call site.
enum DefaultsKey {
    // MARK: Disk thresholds (ICON-001 / SET-001)

    /// Red threshold in bytes, used in `.absolute` mode.
    static let redThresholdBytes = "redThresholdBytes"
    /// Red threshold as a percentage of capacity, used in `.percentage` mode.
    static let redThresholdPercent = "redThresholdPercent"
    /// Yellow threshold in bytes, used in `.absolute` mode.
    static let yellowThresholdBytes = "yellowThresholdBytes"
    /// Yellow threshold as a percentage of capacity, used in `.percentage` mode.
    static let yellowThresholdPercent = "yellowThresholdPercent"
    /// How the thresholds are interpreted: `ThresholdMode` raw value
    /// (`absolute` / `percentage`).
    static let thresholdMode = "thresholdMode"

    // MARK: Software updates (UPD-001)

    /// Whether automatic background update checks are enabled, as read/written by
    /// `NoopSoftwareUpdater` when Sparkle is not linked. When Sparkle *is* linked,
    /// `SparkleUpdaterController` uses Sparkle's own persisted setting instead
    /// (`SPUUpdater.automaticallyChecksForUpdates`), not this key — so this exists only so
    /// the toggle still round-trips in the fallback build.
    static let automaticallyChecksForUpdates = "automaticallyChecksForUpdates"

    // MARK: Largest-files "Hide" (UX-015)

    /// Filesystem paths the user has hidden from the largest-files list, persisted as a
    /// `[String]` and used as a set. A hidden path is filtered out of the list on every
    /// scan/display so it stays hidden across sessions; the user can un-hide via the
    /// section's "N hidden" affordance. Paths, not URLs, so the stored contract is a plain
    /// string array (`URL` isn't a property-list type). Never logged (TECHSPEC §7).
    static let hiddenLargestFilePaths = "hiddenLargestFilePaths"
}
