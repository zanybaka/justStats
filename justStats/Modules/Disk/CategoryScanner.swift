import Foundation

/// Partial per-volume storage breakdown produced by the Spotlight tier (SCAN-001,
/// TECHSPEC §4). Deliberately incomplete: it carries only the categories a
/// `NSMetadataQuery` can positively classify — Apps, Media, and Other (user files
/// under `/Users` that are neither). `System` and `Free` are *not* here:
///
/// - `Free` comes from `statfs` (`VolumeSpace.free`), never a Spotlight query.
/// - `System` is the residual `Total − Free − Apps − Media − Other`, computed
///   later (SCAN-002) once free/total are joined in — this type doesn't know the
///   volume's total, so it cannot and must not compute it.
///
/// A breakdown is meaningful only when `isIndexAvailable` is `true`. When Spotlight
/// has no usable index for the volume (external/network drives are frequently
/// unindexed, or `mdutil -i off`), the scanner reports `.unavailable` instead of
/// zeroed byte counts — SCAN-005 renders the "Not indexed" state from that flag
/// rather than showing a misleading empty bar (TECHSPEC §4 degraded state).
struct CategoryBreakdown: Equatable {
    /// Summed logical size of application bundles (`com.apple.application-bundle`).
    let appsBytes: Int64
    /// Summed logical size of images, movies, and audio (`public.image` /
    /// `public.movie` / `public.audio` content-type subtrees).
    let mediaBytes: Int64
    /// Summed logical size of user files under `/Users` that are neither Apps nor
    /// Media (documents, archives, code, etc. — TECHSPEC §4 "Other").
    let otherBytes: Int64
    /// Whether Spotlight returned a usable index for this volume. `false` means the
    /// byte counts above are not trustworthy (all zero) and the row should show the
    /// degraded "Not indexed" notice instead (SCAN-005).
    let isIndexAvailable: Bool

    /// The empty breakdown for a volume with no usable Spotlight index — all zero,
    /// flagged unavailable. Byte counts must be ignored when `isIndexAvailable` is
    /// `false`; they are zero only so the type stays a plain value.
    static let unavailable = CategoryBreakdown(
        appsBytes: 0, mediaBytes: 0, otherBytes: 0, isIndexAvailable: false
    )

    /// A resolved breakdown from an available index.
    static func available(apps: Int64, media: Int64, other: Int64) -> CategoryBreakdown {
        CategoryBreakdown(appsBytes: apps, mediaBytes: media, otherBytes: other, isIndexAvailable: true)
    }

    /// One category's aggregated Spotlight result: its summed logical bytes and how
    /// many items matched. The item count drives the availability decision below.
    struct CategoryResult: Equatable {
        let bytes: Int64
        /// Number of Spotlight items matched. Negative counts (never produced by a
        /// real query) clamp to zero so they can't fake availability.
        let itemCount: Int

        init(bytes: Int64, itemCount: Int) {
            self.bytes = bytes
            self.itemCount = max(itemCount, 0)
        }
    }

    /// Turns the per-category Spotlight aggregates into a breakdown, applying the
    /// availability heuristic (TECHSPEC §4). Pure — the whole reason
    /// `SpotlightCategoryScanner` funnels its results through here is so this
    /// decision is unit-testable without touching real Spotlight (SCAN-001).
    ///
    /// If *no* category matched a single item, the volume has no usable Spotlight
    /// index (unindexed drive, or `mdutil -i off`): `.unavailable`, so SCAN-005
    /// shows "Not indexed" rather than a misleading all-zero bar. Otherwise the
    /// summed bytes per category form an available breakdown.
    static func from(
        apps: CategoryResult,
        media: CategoryResult,
        other: CategoryResult
    ) -> CategoryBreakdown {
        let totalItems = apps.itemCount + media.itemCount + other.itemCount
        guard totalItems > 0 else { return .unavailable }
        return .available(apps: apps.bytes, media: media.bytes, other: other.bytes)
    }
}

/// The Spotlight category taxonomy (TECHSPEC §4). Each case owns its
/// `NSMetadataQuery` predicate; the scanner runs one query per case, scoped to the
/// target volume, and sums each result set's logical file sizes.
enum FileCategory: CaseIterable {
    /// Application bundles.
    case apps
    /// Images, movies, audio.
    case media
    /// User files under `/Users` that are neither Apps nor Media.
    case other

    /// The `NSMetadataQuery`-format predicate string for this category. Kept as a
    /// string (not a live `NSPredicate`) so it is inspectable in unit tests without
    /// constructing a query or touching Spotlight — the aggregation/model logic is
    /// what the tests exercise, per the SCAN-001 "no real Spotlight in tests" rule.
    ///
    /// `kMDItemContentTypeTree` matches an item whose UTI conforms to (is a subtype
    /// of) the listed type, so `public.image`/`public.movie`/`public.audio` catch
    /// every concrete image/movie/audio format without enumerating them.
    var predicateFormat: String {
        switch self {
        case .apps:
            return "kMDItemContentType == 'com.apple.application-bundle'"
        case .media:
            return "(kMDItemContentTypeTree == 'public.image' || "
                + "kMDItemContentTypeTree == 'public.movie' || "
                + "kMDItemContentTypeTree == 'public.audio')"
        case .other:
            // User files that are neither an app bundle nor media. Confined to the
            // volume's own `<volume>/Users` subtree by the query's single search
            // scope (see `SpotlightCategoryScanner.searchScopes`), so "Other" stays
            // user-owned documents/archives/code rather than every unclassified
            // system file.
            return "(kMDItemContentType != 'com.apple.application-bundle') && "
                + "(kMDItemContentTypeTree != 'public.image') && "
                + "(kMDItemContentTypeTree != 'public.movie') && "
                + "(kMDItemContentTypeTree != 'public.audio')"
        }
    }
}

/// Seam between the popover/view model and the Spotlight tier so the UI can depend
/// on an abstraction and tests inject a mock — real `NSMetadataQuery` never runs in
/// unit tests (SCAN-001). Mirrors `DeferredVolumeResolving`: on-demand start, main-
/// queue delivery, explicit cancellation.
protocol CategoryScanning: AnyObject {
    /// Starts an on-demand category scan of the volume mounted at `volumeURL`
    /// (popover open / Refresh only — never a timer, NFR4). `onResult` is called on
    /// the main queue exactly once: a resolved `CategoryBreakdown`, or
    /// `.unavailable` if the volume has no usable Spotlight index. Starting a new
    /// scan or calling `cancel()` supersedes any in-flight scan (its result is
    /// dropped, its queries stopped and released).
    ///
    /// Callable from any thread; does no Spotlight work on the caller's thread.
    func scan(volumeURL: URL, onResult: @escaping (CategoryBreakdown) -> Void)

    /// Cancels the in-flight scan (e.g. popover close): stops and releases every
    /// live `NSMetadataQuery` and drops its undelivered result. Idempotent.
    func cancel()
}
