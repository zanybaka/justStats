import Foundation

/// Reverse-DNS labels for the app's private serial/utility dispatch queues
/// (TECHSPEC §1: shared constants live in Kit). Centralizing the prefix keeps
/// every background queue under one identifiable namespace in Instruments and
/// crash logs, and stops the same literal being retyped per module.
enum QueueLabels {
    /// Shared reverse-DNS prefix for every private queue the app creates.
    private static let prefix = "com.zanybaka.justStats"

    /// Icon tier (TECHSPEC §3 tier 1): serial utility queue for the off-main
    /// boot-volume `statfs` read and its refresh timer.
    static let iconRefresh = "\(prefix).icon-refresh"

    /// Popover tier (TECHSPEC §3 tier 2): serial queue guarding
    /// `DeferredVolumeResolver`'s generation/pending/in-flight state.
    static let deferredVolumeState = "\(prefix).deferred-volume-state"

    /// Popover tier (TECHSPEC §4): serial queue guarding
    /// `SpotlightCategoryScanner`'s generation/active-query state.
    static let categoryScanState = "\(prefix).category-scan-state"

    /// Popover tier (TECHSPEC §4): the dedicated background thread that owns the
    /// run loop `NSMetadataQuery` posts its gathering notifications on — Spotlight
    /// queries never run on the main thread (NFR4).
    static let categoryScanRunLoop = "\(prefix).category-scan-runloop"
}
