import Foundation

/// One entry in a volume's "largest files" list (SCAN-003, PRD FR7): a single file
/// with its display name, on-disk size, and location. The `url` is what later tiers
/// act on — Reveal in Finder (ACT-001) and Move to Trash (ACT-002) both operate on
/// it — and `path` is derived from it for display only.
///
/// A file URL, not a raw path string, is carried so downstream file actions get an
/// unambiguous, percent-decoded location (paths with spaces/unicode survive intact,
/// PRD FR7). Paths are never logged as secrets (TECHSPEC §7).
struct LargestFile: Equatable {
    /// The file's display name (last path component), e.g. `"archive.zip"`.
    let displayName: String
    /// On-disk (allocated) size in bytes — the bytes the file actually occupies on the
    /// volume (`.totalFileAllocatedSizeKey`, matching Finder's "on disk"), used for the
    /// size column and to rank the list. This is deliberately NOT the logical
    /// `kMDItemFSSize`: a sparse file (Docker.raw, VM bundles) reports a huge logical
    /// size but occupies little on disk, so ranking by logical size floats those virtual
    /// giants to the top (UX-010). Falls back to logical size when the allocated size is
    /// unreadable. Non-negative.
    let sizeBytes: Int64
    /// The file's location. Load-bearing: Reveal/Trash act on this exact URL.
    let url: URL

    /// Filesystem path of `url`, for display only (never logged as a secret).
    var path: String { url.path }

    /// - Parameters:
    ///   - displayName: last path component; if empty, falls back to `url`'s.
    ///   - sizeBytes: on-disk (allocated) size; negative values (never produced by a real
    ///     read) clamp to zero so a corrupt entry can't sort to the top.
    ///   - url: the file's location.
    init(displayName: String, sizeBytes: Int64, url: URL) {
        self.displayName = displayName.isEmpty ? url.lastPathComponent : displayName
        self.sizeBytes = max(sizeBytes, 0)
        self.url = url
    }
}

/// The result of a largest-files scan for one volume (SCAN-003). Mirrors
/// `CategoryBreakdown`'s shape: a value type carrying the ranked files plus an
/// availability flag, so the same "unindexed volume → degraded state" story applies
/// (TECHSPEC §4). When `isIndexAvailable` is `false`, `files` is empty and the row
/// should show the "Not indexed" notice (SCAN-005) rather than an empty list that
/// looks like "no large files".
struct LargestFilesResult: Equatable {
    /// Top-N files, largest first. Empty when unavailable.
    let files: [LargestFile]
    /// Whether Spotlight returned a usable index for this volume. `false` means the
    /// list is not trustworthy (empty) and the degraded notice should show instead.
    let isIndexAvailable: Bool

    /// The empty result for a volume with no usable Spotlight index — no files,
    /// flagged unavailable.
    static let unavailable = LargestFilesResult(files: [], isIndexAvailable: false)

    /// A resolved list from an available index. The caller passes an already
    /// sort-and-truncated list (see `ranked(from:limit:)`).
    static func available(_ files: [LargestFile]) -> LargestFilesResult {
        LargestFilesResult(files: files, isIndexAvailable: true)
    }

    /// Default number of files to return (PRD FR7 range 10–20). A `NSMetadataQuery`
    /// scoped to a volume returns everything; this cap keeps the list to the handful
    /// the UI shows and bounds the work of ranking.
    static let defaultLimit = 15

    /// Turns a finished query's raw items into a ranked, truncated result — the pure
    /// core of SCAN-003, unit-tested without real Spotlight. The scanner funnels its
    /// `NSMetadataItem` values through here so the sort/truncation/availability logic
    /// is exercised as a plain function (the SCAN-001 "no real Spotlight in tests"
    /// rule).
    ///
    /// `matchedItemCount` is the query's total result count *before* truncation: it
    /// drives availability exactly like `CategoryBreakdown.from` — a query that
    /// matched no item at all is an unusable index (`.unavailable`), whereas any
    /// match yields an available (possibly shorter than `limit`) list. This is why
    /// availability keys off the raw match count, not `files.count`: a volume with
    /// fewer than `limit` files is still indexed.
    ///
    /// Files are sorted by `sizeBytes` descending; ties break by `displayName` then
    /// `path` so the order is deterministic (Spotlight's own result order is not).
    /// A non-positive `limit` yields an empty-but-available list when items matched.
    static func ranked(
        from files: [LargestFile],
        matchedItemCount: Int,
        limit: Int = defaultLimit
    ) -> LargestFilesResult {
        guard matchedItemCount > 0 else { return .unavailable }
        let sorted = files.sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.path < rhs.path
        }
        let capped = limit > 0 ? Array(sorted.prefix(limit)) : []
        return .available(capped)
    }
}

/// Hides already-discarded files from the largest-files LIST (UX-018).
///
/// Files sitting in a Trash directory are, by definition, things the user already threw
/// away; surfacing them as "your largest files" is noise — the user can't act on them in a
/// meaningful new way and doesn't want to be told the space is "used by" something they
/// already deleted. So the ranked list filters them out. (This is *only* the list: the
/// category breakdown still counts Trash as occupied space, because those bytes really are
/// still on the volume until the Trash is emptied.)
///
/// **How the Trash location is found:** not by guessing `.Trash`/`.Trashes` from path
/// spelling, but by asking the SYSTEM for the real Trash directory of a given volume via
/// `FileManager`. For the boot volume that resolves to `~/.Trash`; for another volume it
/// resolves to that volume's per-user Trash (`/Volumes/X/.Trashes/<uid>`), spelled by the
/// OS rather than assembled from hardcoded names. The scanner resolves this once per scan
/// (the single filesystem touch, done off-main) and then filters candidates against it with
/// a pure containment check, so all the decision logic stays unit-testable without disk.
enum TrashFilter {
    /// Resolves the current user's Trash directory for the volume mounted at `volumeURL`,
    /// asked of the system rather than guessed. Returns `~/.Trash` for the boot volume and
    /// the volume's own per-user Trash (`/Volumes/X/.Trashes/<uid>`) for others — spelled by
    /// macOS. `nil` when the system can't resolve one (e.g. a volume with no Trash support);
    /// callers treat `nil` as "filter nothing".
    ///
    /// This is the module's ONE filesystem access for Trash detection. The scanner calls it
    /// once per scan (off-main, like the rest of the Spotlight work) and threads the result
    /// through the pure `isInTrash(_:trashURL:)` check for every candidate.
    static func resolveTrashURL(for volumeURL: URL) -> URL? {
        try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: volumeURL,
            create: false
        )
    }

    /// Whether `url` sits inside `trashURL`. Pure: decides purely from the two URLs'
    /// standardized path components, no filesystem access — so it is exercised as a plain
    /// function (the module's "no real filesystem in tests" rule).
    ///
    /// Returns `true` iff `trashURL` is non-`nil` and `url` is at or below it. Comparison is
    /// a component-wise prefix on the standardized paths, which avoids the string-prefix
    /// trap where a sibling sharing a textual prefix (`/V/.Trashes/501` vs
    /// `/V/.Trashes/5011/x`) would falsely match: `"5011"` is a different path component than
    /// `"501"`, so the prefix check rejects it. A `nil` `trashURL` (the system couldn't
    /// resolve a Trash) filters nothing.
    static func isInTrash(_ url: URL, trashURL: URL?) -> Bool {
        guard let trashURL else { return false }
        let trashComponents = trashURL.standardizedFileURL.pathComponents
        guard !trashComponents.isEmpty else { return false }
        let urlComponents = url.standardizedFileURL.pathComponents
        // `url` must have at least the Trash's components (a file INSIDE it, so strictly more,
        // but at-or-below is enough for the prefix test) and share every one of them in order.
        guard urlComponents.count >= trashComponents.count else { return false }
        return Array(urlComponents.prefix(trashComponents.count)) == trashComponents
    }

    /// Keeps only the files NOT inside `trashURL`, preserving order (UX-018). The scanner
    /// resolves `trashURL` once per scan (via `resolveTrashURL(for:)`) and calls this on its
    /// candidates before ranking/truncating so discarded files never reach the list. A `nil`
    /// `trashURL` keeps everything.
    static func excludingTrash(_ files: [LargestFile], trashURL: URL?) -> [LargestFile] {
        files.filter { !isInTrash($0.url, trashURL: trashURL) }
    }
}

/// The size-floor cascade that makes the largest-files query fast (A1).
///
/// `NSMetadataQuery` has no server-side top-N: a query scoped to a volume *gathers
/// every matching item* before we can rank it, so an unfloored "all files" query on a
/// full volume is O(all indexed files). The fix is to AND a `kMDItemFSSize > floor`
/// clause into the predicate so Spotlight only gathers *large* files, then cascade the
/// floor downward only if the high floor didn't yield enough: on most volumes the
/// first (highest) floor already returns ≥ `limit` items and the scan finishes having
/// touched a tiny fraction of the index.
///
/// The floors are gigabyte/megabyte magnitudes in *decimal* bytes (matching `ByteFormat`
/// and Finder's 1 MB = 10^6 convention). `0` is the sentinel final floor: a floor-0
/// query uses no size gate at all (it is the original unfloored predicate) and its match
/// count is the ground truth for availability — mirroring `LargestFilesResult.ranked`'s
/// `matchedItemCount` heuristic.
///
/// This type is pure and has no Spotlight dependency, so the cascade decision (stop at
/// the first floor with ≥ `limit` matches; fall through otherwise; unavailable only when
/// the floor-0 query matches nothing) is unit-tested as plain logic (SCAN-003 "no real
/// Spotlight in tests").
enum LargestFilesCascade {
    /// Size floors in bytes, highest first, ending at the `0` sentinel (no floor).
    /// `100 MB → 10 MB → 1 MB → 0`, decimal like `ByteFormat`. Only descended into when
    /// a higher floor returned fewer than `limit` items, so the common case (a volume
    /// with ≥ `limit` files over 100 MB) runs exactly one cheap query.
    static let defaultFloors: [Int64] = [100_000_000, 10_000_000, 1_000_000, 0]

    /// What to do after a floored query at `floors[index]` finished with
    /// `matchedItemCount` results, given the target `limit`.
    enum Step: Equatable {
        /// Enough (or the last floor): stop and rank these results into the delivered
        /// list. `unavailable` is `true` only for the floor-0 case that matched nothing
        /// — the degraded "Not indexed" state (SCAN-005). A short-but-nonempty list, or
        /// a fall-through that reached floor 0 with any matches, is available.
        case deliver(unavailable: Bool)
        /// Not enough yet and a lower floor remains: run the query again at
        /// `floors[nextIndex]`.
        case descend(nextIndex: Int)
    }

    /// Decides the next cascade step. Pure — no query, no Spotlight.
    ///
    /// - A query that matched ≥ `limit` items *and* whose delivered on-disk top-`limit`
    ///   is safe for the current floor → `.deliver` (available). "Safe" means the
    ///   `limit`-th largest **on-disk** size (`smallestTopOnDiskSize`) is ≥ the current
    ///   floor: because the floor gates on *logical* size and a file's on-disk size is
    ///   ≤ its logical size, any file NOT gathered at this floor has logical ≤ floor and
    ///   therefore on-disk ≤ floor. So once the `limit`-th delivered file already occupies
    ///   ≥ `floor` on disk, no un-gathered file can outrank it — the on-disk top-N is
    ///   final and we stop. If that boundary is BELOW the floor, a smaller-logical file
    ///   below the floor could still be larger on disk (a floor full of sparse giants),
    ///   so we must `.descend` to gather it — even though `matchedItemCount ≥ limit`.
    /// - Fewer than `limit` matches (or a top-N not yet floor-safe) and a lower floor
    ///   remains → `.descend` to widen the net. (A non-positive `limit` is treated as
    ///   already satisfied, so a zero-row request runs a single cheap query rather than
    ///   cascading to floor 0.)
    /// - Fewer than `limit` matches at the *last* floor (`0`, no size gate) → `.deliver`,
    ///   marked `unavailable` exactly when that floor-0 query matched nothing: zero items
    ///   with no floor means the index is unusable (`.unavailable`, SCAN-005), whereas any
    ///   match is a small-but-indexed volume (available, possibly short list). At floor 0
    ///   the on-disk safety check is moot: every indexed file was gathered, so nothing
    ///   un-gathered can outrank the delivered list.
    ///
    /// - Parameter smallestTopOnDiskSize: the on-disk (allocated) size of the `limit`-th
    ///   largest delivered file at this floor, i.e. the smallest size in the on-disk
    ///   top-`limit`. `nil` means "not applicable" — fewer than `limit` files were
    ///   delivered, or the caller is exercising the pure logic without on-disk sizes — and
    ///   disables the floor-safety gate (backward-compatible with the count-only rule).
    static func step(
        floorIndex: Int,
        matchedItemCount: Int,
        limit: Int,
        floors: [Int64] = defaultFloors,
        smallestTopOnDiskSize: Int64? = nil
    ) -> Step {
        let isLastFloor = floorIndex >= floors.count - 1
        // A high floor with enough matches is a definitive top-N only if the delivered
        // on-disk top-N is itself floor-safe (its smallest member ≥ floor): otherwise a
        // sparse-giant floor can hide genuinely-large-on-disk files below it.
        if limit <= 0 || matchedItemCount >= limit {
            let floor = floors[floorIndex]
            // Descend when the on-disk top-N boundary sits below the floor and a lower
            // floor remains — those below-floor-but-large-on-disk files weren't gathered.
            if !isLastFloor, let boundary = smallestTopOnDiskSize, boundary < floor {
                return .descend(nextIndex: floorIndex + 1)
            }
            // Only a floor-0 query that matched nothing signals an unusable index.
            let unavailable = isLastFloor && matchedItemCount == 0
            return .deliver(unavailable: unavailable)
        }
        guard isLastFloor else { return .descend(nextIndex: floorIndex + 1) }
        return .deliver(unavailable: matchedItemCount == 0)
    }
}

/// Seam between the popover/view model and the Spotlight largest-files tier so the
/// UI depends on an abstraction and tests inject a mock — real `NSMetadataQuery`
/// never runs in unit tests (SCAN-003). Mirrors `CategoryScanning`: on-demand start,
/// main-queue delivery, explicit cancellation.
protocol LargestFilesScanning: AnyObject {
    /// Starts an on-demand largest-files scan of the volume mounted at `volumeURL`
    /// (popover open / Refresh only — never a timer, NFR4).
    ///
    /// - `onPartial` may be called *zero or more* times on the main queue while the
    ///   query is still gathering, each time with the best-so-far top-N (largest first,
    ///   possibly fewer than `limit`) — the progressive "instant-ish" feedback (A2).
    ///   Every partial is a monotonically improving snapshot of the same running scan;
    ///   a superseded scan (a newer `scan`/`cancel()`) delivers no more partials.
    /// - `onResult` is called on the main queue *exactly once* at the end: a resolved
    ///   `LargestFilesResult` (top-N, largest first), or `.unavailable` if the volume
    ///   has no usable Spotlight index. It always follows the last partial (if any).
    ///
    /// Starting a new scan or calling `cancel()` supersedes any in-flight scan (its
    /// partials and result are dropped, its query stopped and released).
    ///
    /// `limit` caps the number of returned files (default `LargestFilesResult
    /// .defaultLimit`, PRD FR7 range 10–20). Callable from any thread; does no
    /// Spotlight work on the caller's thread.
    func scan(
        volumeURL: URL,
        limit: Int,
        onPartial: @escaping ([LargestFile]) -> Void,
        onResult: @escaping (LargestFilesResult) -> Void
    )

    /// Cancels the in-flight scan (e.g. popover close): stops and releases the live
    /// `NSMetadataQuery` and drops its undelivered partials and result. Idempotent.
    func cancel()
}

extension LargestFilesScanning {
    /// Convenience overload using the default limit and ignoring progressive partials
    /// (PRD FR7). Kept so call sites that only want the final result — and every mock
    /// that predates the progressive `onPartial` path — stay unchanged.
    func scan(volumeURL: URL, onResult: @escaping (LargestFilesResult) -> Void) {
        scan(volumeURL: volumeURL, limit: LargestFilesResult.defaultLimit,
             onPartial: { _ in }, onResult: onResult)
    }

    /// Convenience overload with an explicit `limit` but no partial handler.
    func scan(
        volumeURL: URL,
        limit: Int,
        onResult: @escaping (LargestFilesResult) -> Void
    ) {
        scan(volumeURL: volumeURL, limit: limit, onPartial: { _ in }, onResult: onResult)
    }
}

/// Real Spotlight implementation of `LargestFilesScanning` (SCAN-003, TECHSPEC §4).
///
/// Runs an `NSMetadataQuery` scoped to the target volume, sorted by `kMDItemFSSize`
/// descending, and delivers the top-N files as a `LargestFilesResult` on the main
/// queue. Structurally a sibling of `SpotlightCategoryScanner`; it reuses that module's
/// `MetadataQueryRunLoopThread` so all Spotlight work stays off the main thread on one
/// long-lived background run loop (NFR4).
///
/// **Size-floor cascade (A1 — the speedup):** an unfloored query gathers *every*
/// indexed file on the volume before it can be ranked, because `NSMetadataQuery` has no
/// server-side top-N. Instead this scanner ANDs a `kMDItemFSSize > floor` clause into the
/// predicate and cascades the floor downward (`100 MB → 10 MB → 1 MB → 0`, per
/// `LargestFilesCascade`): it runs the highest floor first and, only if that query
/// matched fewer than `limit` files, tears it down and retries at the next lower floor,
/// until a floor yields ≥ `limit` matches or the `0` (no-floor) floor is reached. On a
/// typical volume the first floor already returns enough, so one cheap query touches a
/// tiny slice of the index. Every floor query is volume-scoped, off-main, cancellable,
/// and released — the same lifecycle discipline as the category scanner.
///
/// **On-disk ranking (UX-010):** the `kMDItemFSSize > floor` cascade GATHERS candidates
/// by *logical* size, which is a safe superset — a file's allocated (on-disk) size is
/// always ≤ its logical size, so any file large on disk still passes the logical floor.
/// But the logical size is NOT trusted for ranking or display: a sparse file (Docker.raw
/// reporting 345 GB logical / ~3.25 GB on disk, VM `.bundle`s) would otherwise float to
/// the top while costing little disk. For each gathered candidate the scanner resolves
/// the on-disk (allocated) size via the injected `OnDiskSizing` seam and the delivered
/// `LargestFile.sizeBytes` carries THAT — so the list is ranked and displayed by what a
/// file actually occupies. Because Spotlight sorts by logical size, the true top-`limit`
/// by allocated size can sit below the logical top-`limit`; the scanner re-ranks a
/// bounded superset of logical-largest candidates (`extractTopFiles`) to recover it.
///
/// **On-demand only:** nothing starts a scan except an explicit `scan(volumeURL:)`
/// call (popover open / Refresh). No timer, no polling.
///
/// **Cancellation & release:** each `scan` starts a new generation; a newer `scan`
/// or `cancel()` invalidates the prior one — its live floor query is `stop()`-ed, its
/// observer removed, and the query object dropped so nothing leaks or keeps gathering
/// after the popover closes (SCAN-007 relies on this). A whole cascade runs under one
/// generation, so a superseding scan drops it mid-descent; a superseded generation's
/// result is never delivered.
///
/// **Availability:** an unindexed volume returns zero items from every floor without
/// erroring; only when the final `0`-floor (no size gate) query matches no item at all is
/// the index treated as unusable and `.unavailable` delivered (SCAN-005 "Not indexed").
/// A small volume with a handful of large files still reaches the floor-0 pass with a
/// nonzero match count and is delivered as available (short list). The scanner never
/// throws and never blocks the caller.
final class SpotlightLargestFilesScanner: LargestFilesScanning {
    /// Builds the query predicate for a given size floor (A1). Excludes directories —
    /// ranking whole folders by aggregate size would bury the individual files the user
    /// can act on; only regular files (`kMDItemFSSize` reflects one file's bytes) are
    /// ranked. The `kMDItemFSSize > floor` clause is the speedup: Spotlight gathers only
    /// files larger than `floor`, not the whole index. A `floor` of `0` reproduces the
    /// original unfloored predicate (every non-empty regular file), which is the
    /// cascade's final ground-truth pass for availability.
    private static func predicateFormat(floor: Int64) -> String {
        "(kMDItemFSSize > \(floor)) && (kMDItemContentTypeTree != 'public.folder')"
    }

    /// The one running query plus its observer tokens, so the scanner can stop and
    /// unobserve exactly what it started. Two observers: the terminal
    /// `…DidFinishGathering` (drives the cascade decision) and, for the progressive path
    /// (A2), the repeated `…GatheringProgress` (drives best-so-far partials).
    private struct ActiveQuery {
        let query: NSMetadataQuery
        let finishObserver: NSObjectProtocol
        let progressObserver: NSObjectProtocol
    }

    /// State for one generation, confined to `stateQueue`. A single generation can run
    /// several queries in sequence — one per cascade floor (A1) — but only ever one at a
    /// time (`active`); `floorIndex` tracks how far down the floors it has descended.
    private final class Scan {
        let generation: UInt64
        let volumeURL: URL
        let limit: Int
        let floors: [Int64]
        /// The system-resolved Trash directory for `volumeURL`, resolved ONCE when the scan
        /// starts (the only filesystem touch for Trash detection, UX-018) and threaded through
        /// every candidate's pure `TrashFilter.isInTrash(_:trashURL:)` check. `nil` when the
        /// system couldn't resolve one — then nothing is filtered as Trash.
        let trashURL: URL?
        /// Progressive best-so-far, delivered on the deliver queue while gathering (A2).
        let deliverPartial: ([LargestFile]) -> Void
        let deliver: (LargestFilesResult) -> Void
        var active: ActiveQuery?
        /// Index into `floors` of the query currently running (or about to run).
        var floorIndex: Int = 0
        /// Fingerprint of the last partial actually forwarded to the UI, so a progress
        /// tick that hasn't changed the visible top-N is coalesced away rather than
        /// re-published. `nil` means "nothing forwarded yet".
        var lastPartialSignature: PartialSignature?

        init(
            generation: UInt64,
            volumeURL: URL,
            limit: Int,
            floors: [Int64],
            trashURL: URL?,
            deliverPartial: @escaping ([LargestFile]) -> Void,
            deliver: @escaping (LargestFilesResult) -> Void
        ) {
            self.generation = generation
            self.volumeURL = volumeURL
            self.limit = limit
            self.floors = floors
            self.trashURL = trashURL
            self.deliverPartial = deliverPartial
            self.deliver = deliver
        }
    }

    /// Cheap fingerprint of a forwarded partial so a gathering-progress tick that didn't
    /// change the visible top-N is coalesced (not re-published to the UI). Two partials
    /// with the same count and same total bytes are treated as equal — the running top-N
    /// only ever grows or improves, so a matching signature means "no visible change".
    private struct PartialSignature: Equatable {
        let count: Int
        let totalBytes: Int64

        /// Whether a candidate partial is a strict improvement over the last one actually
        /// forwarded to the UI — the guard that keeps the delivered list monotonic.
        ///
        /// Within one `NSMetadataQuery`'s gathering the top-N only ever grows or improves,
        /// so a strictly-better signature is the "visible change worth publishing" test.
        /// The subtlety is *across* a cascade floor descent: when a higher floor
        /// under-fills and the scanner tears it down and restarts at a lower (superset)
        /// floor, that fresh query rebuilds its result set from empty, so its early
        /// progress ticks report a SUBSET of what the prior floor already delivered. A
        /// plain "signature changed" test would forward that subset and the visible list
        /// would shrink (flicker). Requiring a *strict improvement* — more files, or the
        /// same count with a larger total — suppresses those transient regressions until
        /// the lower floor catches up and surpasses what was shown, so the running top-N
        /// never shrinks (the invariant `applyLargestFilesPartial` relies on).
        func improves(over previous: PartialSignature?) -> Bool {
            guard let previous else { return true } // first partial always publishes
            if count != previous.count { return count > previous.count }
            return totalBytes > previous.totalBytes
        }
    }

    /// Reverse-DNS label for this scanner's serial state queue. Kept local rather
    /// than in shared `QueueLabels` so SCAN-003 owns only its own file; it stays
    /// under the same `com.zanybaka.justStats` namespace as the other queues so it's
    /// still identifiable in Instruments/crash logs (TECHSPEC §1).
    private static let stateQueueLabel = "com.zanybaka.justStats.largest-files-scan-state"

    /// Serializes generation bookkeeping and the active-scan slot.
    private let stateQueue = DispatchQueue(label: SpotlightLargestFilesScanner.stateQueueLabel)
    /// The background run loop `NSMetadataQuery` notifications are delivered on.
    private let runLoopThread: MetadataQueryRunLoopExecuting
    private let deliverQueue: DispatchQueue
    /// Builds the sorted query. Injectable so lifecycle tests (SCAN-007) can supply a
    /// counting `NSMetadataQuery` subclass they retain and drive to "finished",
    /// verifying the query is stopped and its observer removed across cycles — without
    /// a real Spotlight index.
    private let makeQuery: () -> NSMetadataQuery
    /// The size-floor cascade (A1), highest floor first, ending at the `0` no-floor
    /// sentinel. Injectable so cascade tests can drive a small deterministic floor set.
    private let floors: [Int64]
    /// Resolves each candidate's on-disk (allocated) size so the list ranks and displays
    /// by what a file actually costs on disk, not its (possibly sparse) logical size
    /// (UX-010). Injectable behind `OnDiskSizing` so tests supply canned sizes without
    /// touching the real filesystem; the default reads `.totalFileAllocatedSizeKey`.
    private let onDiskSizing: OnDiskSizing
    /// Refresh token: notifications tagged with an older generation are ignored.
    private var generation: UInt64 = 0
    private var current: Scan?

    /// - Parameters:
    ///   - runLoopThread: the executor owning the query run loop; the default starts a
    ///     dedicated background thread. Injectable behind `MetadataQueryRunLoopExecuting`
    ///     so tests can substitute a synchronous stub and exercise the query
    ///     start/stop/observer lifecycle (SCAN-007) without a real Spotlight thread.
    ///   - deliverQueue: where results are delivered (main in production).
    ///   - makeQuery: builds the sorted `NSMetadataQuery`; the default is a plain
    ///     `NSMetadataQuery()`. Injectable only for lifecycle tests.
    ///   - floors: the size-floor cascade (A1). Defaults to
    ///     `LargestFilesCascade.defaultFloors`; injectable so lifecycle tests can drive a
    ///     minimal `[0]` cascade (single query) or a custom sequence.
    ///   - onDiskSizing: resolves each candidate's on-disk (allocated) size for ranking
    ///     and display (UX-010). Defaults to the real `OnDiskSizeResolver`; injectable so
    ///     tests supply canned sizes without touching the filesystem.
    init(
        runLoopThread: MetadataQueryRunLoopExecuting = MetadataQueryRunLoopThread(),
        deliverQueue: DispatchQueue = .main,
        makeQuery: @escaping () -> NSMetadataQuery = { NSMetadataQuery() },
        floors: [Int64] = LargestFilesCascade.defaultFloors,
        onDiskSizing: OnDiskSizing = OnDiskSizeResolver()
    ) {
        self.runLoopThread = runLoopThread
        self.deliverQueue = deliverQueue
        self.makeQuery = makeQuery
        // Guard against an empty injected cascade: without a final ground-truth floor
        // there is no availability decision, so fall back to a single no-floor query.
        self.floors = floors.isEmpty ? [0] : floors
        self.onDiskSizing = onDiskSizing
    }

    deinit {
        // Tear down synchronously on dealloc so no query outlives the scanner.
        let scan = stateQueue.sync { () -> Scan? in
            let scan = current
            current = nil
            return scan
        }
        if let scan { tearDown(scan) }
        runLoopThread.stop()
    }

    // MARK: - LargestFilesScanning

    func scan(
        volumeURL: URL,
        limit: Int,
        onPartial: @escaping ([LargestFile]) -> Void,
        onResult: @escaping (LargestFilesResult) -> Void
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if let previous = self.current {
                self.tearDown(previous)
                self.current = nil
            }
            self.generation &+= 1
            // Resolve the volume's real Trash directory ONCE per scan, off-main here on the
            // state queue — the single filesystem touch for Trash detection (UX-018). The pure
            // per-candidate containment check reuses this without hitting disk again.
            let trashURL = TrashFilter.resolveTrashURL(for: volumeURL)
            let scan = Scan(
                generation: self.generation,
                volumeURL: volumeURL,
                limit: limit,
                floors: self.floors,
                trashURL: trashURL,
                deliverPartial: onPartial,
                deliver: onResult
            )
            self.current = scan
            self.startQuery(for: scan)
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1 // any in-flight notification is now stale
            if let scan = self.current {
                self.tearDown(scan)
                self.current = nil
            }
        }
    }

    // MARK: - Test seam

    #if DEBUG
    /// Deterministically drains this scanner's serial `stateQueue`, blocking the caller
    /// until every block enqueued so far (`scan`/`cancel` bookkeeping, and the
    /// `finishGathering` follow-up that runs the cascade decision — `advanceCascade`,
    /// which either descends to the next floor or enqueues delivery) has finished.
    /// Test-only (SCAN-007): after a lifecycle test posts the "finished gathering"
    /// notification — which runs the observer synchronously and enqueues one
    /// `stateQueue.async` follow-up — this lets the test flush that follow-up with a
    /// `sync` barrier instead of polling a wall-clock expectation, so delivery (or the
    /// next-floor descent) is driven to completion independent of scheduler latency. Pair
    /// with `deliverQueue.sync {}` to also flush the delivery hop. Never called in
    /// production.
    func settleForTesting() {
        stateQueue.sync {}
    }
    #endif

    // MARK: - stateQueue internals

    /// Builds and starts the sorted query for the scan's current cascade floor (A1) on
    /// the run-loop thread. Created here (on `stateQueue`) but started where its run loop
    /// lives, so `start()`/observer registration hops to `runLoopThread`. Called once per
    /// floor the cascade descends into, always within the same generation.
    private func startQuery(for scan: Scan) {
        let generation = scan.generation
        let floor = scan.floors[scan.floorIndex]
        let query = makeQuery()
        query.predicate = NSPredicate(fromMetadataQueryString: Self.predicateFormat(floor: floor))
        query.searchScopes = [scan.volumeURL]
        // We only read size + name from each result; no per-item value lists needed.
        query.valueListAttributes = []
        // Largest first — the ranking Spotlight can do for us; `ranked(from:)` still
        // re-sorts defensively so the order is deterministic regardless.
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSSizeKey, ascending: false)]
        let finishObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: nil // delivered on the posting (run-loop) thread
        ) { [weak self] _ in
            self?.finishGathering(query: query, generation: generation)
        }
        // Progressive path (A2): Spotlight posts …GatheringProgress repeatedly while it
        // is still gathering. Each tick, read the current best-so-far top-N under
        // `disableUpdates` and forward it — so the section fills in largest-first before
        // the (potentially slow) full gather finishes.
        let progressObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryGatheringProgress,
            object: query,
            queue: nil // delivered on the posting (run-loop) thread
        ) { [weak self] _ in
            self?.progressUpdate(query: query, generation: generation)
        }
        scan.active = ActiveQuery(query: query, finishObserver: finishObserver, progressObserver: progressObserver)
        runLoopThread.perform {
            query.start()
        }
    }

    /// A gathering-progress tick fired for `query` (on the run-loop thread): read the
    /// current best-so-far top-N and, if it improved the visible list, forward it as a
    /// progressive partial (A2). Stale-generation ticks and no-change ticks are dropped
    /// without publishing. The extraction runs under `disableUpdates` so the result set
    /// is stable while we read it, then re-enables so gathering continues.
    private func progressUpdate(query: NSMetadataQuery, generation: UInt64) {
        // NFR4 invariant: Spotlight extraction never runs on the main thread.
        dispatchPrecondition(condition: .notOnQueue(.main))
        // Only do the read if this is still the live generation. Pull the resolved Trash URL
        // alongside `limit` so the extraction filters candidates against it (UX-018).
        let params = stateQueue.sync { () -> (limit: Int, trashURL: URL?)? in
            guard let scan = current, scan.generation == generation else { return nil }
            return (scan.limit, scan.trashURL)
        }
        guard let params else { return }
        query.disableUpdates()
        let (files, _, _) = extractTopFiles(from: query, limit: params.limit, trashURL: params.trashURL)
        query.enableUpdates()
        guard !files.isEmpty else { return }
        let signature = PartialSignature(count: files.count, totalBytes: files.reduce(0) { $0 &+ $1.sizeBytes })
        stateQueue.async { [weak self] in
            guard let self, let scan = self.current, scan.generation == generation else { return }
            // Only forward a partial that strictly improves the visible top-N. This
            // coalesces no-change ticks AND suppresses the transient shrink a fresh lower-
            // floor query produces mid-cascade (its early ticks are a subset of the prior
            // floor's), so the delivered list never shrinks (see `improves(over:)`).
            guard signature.improves(over: scan.lastPartialSignature) else { return }
            scan.lastPartialSignature = signature
            let deliverPartial = scan.deliverPartial
            self.deliverQueue.async { [weak self] in
                guard let self else { return }
                guard self.stateQueue.sync(execute: { self.generation == generation }) else { return }
                deliverPartial(files)
            }
        }
    }

    /// A floored query finished gathering (on the run-loop thread). Extracts the top-N
    /// items and the total match count, then hops to `stateQueue` to run the cascade
    /// decision (A1): deliver, or descend to the next size floor. Stale-generation
    /// notifications are dropped without doing the extraction work.
    private func finishGathering(query: NSMetadataQuery, generation: UInt64) {
        // NFR4 invariant: Spotlight extraction never runs on the main thread.
        dispatchPrecondition(condition: .notOnQueue(.main))
        query.disableUpdates()
        // Pull the resolved Trash URL alongside `limit` so extraction can filter Trash (UX-018).
        let params = stateQueue.sync { () -> (limit: Int, trashURL: URL?)? in
            guard let scan = current, scan.generation == generation else { return nil }
            return (scan.limit, scan.trashURL)
        }
        // If the generation is already stale, skip the extraction work entirely.
        guard let params else { query.stop(); return }
        let (files, matchedCount, trashSkipped) = extractTopFiles(
            from: query, limit: params.limit, trashURL: params.trashURL)
        query.stop()
        stateQueue.async { [weak self] in
            guard let self, let scan = self.current, scan.generation == generation else { return }
            self.advanceCascade(scan, files: files, matchedCount: matchedCount, trashSkipped: trashSkipped)
        }
    }

    /// The current floor's query finished: decide via the pure `LargestFilesCascade`
    /// whether this floor satisfies the request (deliver) or the cascade must widen the
    /// net at a lower floor (descend). Runs on `stateQueue`.
    ///
    /// On descend, the just-finished floor's query is torn down and a fresh query is
    /// started at the next floor *within the same generation*, so a superseding `scan`/
    /// `cancel()` still drops the whole cascade.
    private func advanceCascade(_ scan: Scan, files: [LargestFile], matchedCount: Int, trashSkipped: Int) {
        // On-disk size of the `limit`-th largest delivered file (the top-N boundary), used
        // to decide whether this floor is safe to stop at: if that boundary sits below the
        // floor, below-floor files could still be larger on disk and must be gathered by
        // descending. `nil` when fewer than `limit` files were delivered (gate disabled).
        let smallestTopOnDiskSize: Int64?
        if scan.limit > 0 && files.count >= scan.limit {
            let topSizes = files.map(\.sizeBytes).sorted(by: >)
            smallestTopOnDiskSize = topSizes[scan.limit - 1]
        } else {
            smallestTopOnDiskSize = nil
        }
        // The cascade's "enough to stop" gate must count only DELIVERABLE files. Trash
        // candidates are removed from `files` (UX-018) but still counted in the raw
        // `matchedCount`, so a Trash-heavy floor would otherwise report ≥ `limit` matches,
        // stop early, and deliver an under-filled list — never descending to lower floors
        // where the real keepers live. Subtracting `trashSkipped` makes the gate see the
        // real deliverable count so it descends when Trash inflated the match. Availability
        // (in `completeAndDeliver`) still uses the raw `matchedCount`: a volume whose only
        // large files are trashed is still indexed, not degraded.
        let deliverableCount = max(matchedCount - trashSkipped, 0)
        let step = LargestFilesCascade.step(
            floorIndex: scan.floorIndex,
            matchedItemCount: deliverableCount,
            limit: scan.limit,
            floors: scan.floors,
            smallestTopOnDiskSize: smallestTopOnDiskSize
        )
        switch step {
        case .descend(let nextIndex):
            // Release the finished floor's query before starting the next floor so only
            // one query is ever live per generation.
            tearDown(scan)
            scan.floorIndex = nextIndex
            startQuery(for: scan)
        case .deliver(let unavailable):
            // `step` derives `unavailable` from the DELIVERABLE count, so a floor-0 pass
            // whose only matches were all trashed (deliverableCount == 0 but raw
            // matchedCount > 0) would be flagged unavailable. That volume IS indexed, so
            // gate the degraded flag on the RAW index count: only a genuinely empty index
            // (matchedCount == 0) is "Not indexed"; an all-Trash volume delivers an
            // available (empty) list, exactly as before this cascade change.
            completeAndDeliver(scan, files: files, matchedCount: matchedCount,
                               unavailable: unavailable && matchedCount == 0)
        }
    }

    /// The cascade resolved at the current floor: build the ranked result, deliver it on
    /// the deliver queue (re-checking the generation at the last moment), and release the
    /// query. Runs on `stateQueue`.
    ///
    /// `unavailable` comes from the cascade: it is `true` only when the floor-0
    /// (no-floor) query matched nothing, the unusable-index degraded state (SCAN-005).
    /// Otherwise `LargestFilesResult.ranked` decides availability from `matchedCount`,
    /// which is `> 0` on the deliver path for every non-degraded floor.
    private func completeAndDeliver(
        _ scan: Scan,
        files: [LargestFile],
        matchedCount: Int,
        unavailable: Bool
    ) {
        // Sort/truncation/availability all live in the pure `ranked`, unit-tested
        // without real Spotlight; forcing `matchedItemCount` to 0 routes the degraded
        // floor-0 case to `.unavailable` through the same path.
        let result = LargestFilesResult.ranked(
            from: files,
            matchedItemCount: unavailable ? 0 : matchedCount,
            limit: scan.limit
        )
        tearDown(scan)
        if current?.generation == scan.generation { current = nil }
        let generation = scan.generation
        let deliver = scan.deliver
        deliverQueue.async { [weak self] in
            guard let self else { return }
            guard self.stateQueue.sync(execute: { self.generation == generation }) else { return }
            deliver(result)
        }
    }

    /// Stops the live query, removes its observer, and drops the query object —
    /// nothing keeps gathering or leaks after this (SCAN-007). Runs on `stateQueue`;
    /// the `stop()` hops to the run-loop thread the query lives on.
    private func tearDown(_ scan: Scan) {
        guard let active = scan.active else { return }
        scan.active = nil
        NotificationCenter.default.removeObserver(active.finishObserver)
        NotificationCenter.default.removeObserver(active.progressObserver)
        runLoopThread.perform {
            active.query.stop()
        }
    }

    /// How many logical-largest candidates to gather per requested file before
    /// re-ranking by on-disk size (UX-010). Spotlight sorts by *logical* size, but the
    /// list must be ranked by *allocated* (on-disk) size, and a sparse file's allocated
    /// size can be far below its logical size — so the true top-`limit` by allocated may
    /// sit below position `limit` in the logical order. Because allocated ≤ logical for
    /// every file, gathering a generous multiple of `limit` logical-largest candidates
    /// and re-ranking them by allocated size recovers the correct top-`limit` in the
    /// overwhelmingly common case (only a pathological volume where *many* files past
    /// the window are heavily sparse could hide a straggler, and such a file's on-disk
    /// size is by definition small). The window is also capped (`maxCandidateWindow`) so
    /// a huge `limit` can't make the per-candidate `stat` cost unbounded.
    private static let candidateMultiplier = 4
    /// Absolute cap on the number of candidates whose on-disk size is resolved, so the
    /// per-file `stat` work stays bounded regardless of `limit` (NFR4 keeps scan work
    /// small). At the default limit of 15 the window is 60; this only bites for an
    /// unusually large `limit`.
    private static let maxCandidateWindow = 256

    /// Resolves each candidate's on-disk (allocated) size and re-ranks the list by it
    /// (UX-010). Reads the top logical-largest results from the query (Spotlight sorts by
    /// logical `kMDItemFSSize`), gathers a bounded superset of `limit` candidates
    /// (`candidateMultiplier × limit`, capped), resolves each one's on-disk size via the
    /// injected `OnDiskSizing` seam, and returns them carrying the **on-disk** size in
    /// `LargestFile.sizeBytes` — the value used for both ranking and display. When the
    /// allocated size can't be read, the logical size is used as a fallback so a file is
    /// never dropped or ranked as zero.
    ///
    /// The returned files are NOT yet sorted by on-disk size here — `LargestFilesResult
    /// .ranked` (or the progressive-partial path) does the final descending sort and
    /// truncation to `limit` on the on-disk sizes these carry, keeping all ordering logic
    /// in the one pure, unit-tested place.
    ///
    /// `matchedCount` is the query's *total* match count for the availability decision,
    /// unchanged by re-ranking: it still reflects how many files the index matched (items
    /// without a usable size or URL are skipped from `files` but counted toward the total,
    /// as before, so they prove the index is usable).
    ///
    /// `trashSkipped` counts the candidates dropped by the Trash filter (UX-018) *within
    /// the scanned window*. Trash files are removed from `files` but are still counted in
    /// `matchedCount` (the raw index count), so the cascade must subtract them to know how
    /// many *deliverable* files a floor actually yields — otherwise a Trash-heavy floor
    /// whose raw count is ≥ `limit` stops the cascade early with an under-filled list even
    /// though enough real files exist at a lower floor. Availability still keys off the raw
    /// `matchedCount` (a volume whose only large files are in Trash is still indexed).
    private func extractTopFiles(
        from query: NSMetadataQuery,
        limit: Int,
        trashURL: URL?
    ) -> (files: [LargestFile], matchedCount: Int, trashSkipped: Int) {
        let matchedCount = query.resultCount
        guard limit > 0 else { return (files: [], matchedCount: matchedCount, trashSkipped: 0) }
        // Gather a bounded superset of the logical-largest candidates: the true top-N by
        // on-disk size can sit below the logical top-N (a sparse file's allocated size is
        // far below its logical size), so a larger window is re-ranked by allocated size.
        let window = min(limit * Self.candidateMultiplier, Self.maxCandidateWindow)
        var files: [LargestFile] = []
        files.reserveCapacity(min(window, matchedCount))
        var trashSkipped = 0
        var index = 0
        while index < matchedCount && files.count < window {
            defer { index += 1 }
            guard let item = query.result(at: index) as? NSMetadataItem else { continue }
            guard let size = item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            // Hide already-discarded files (UX-018): a candidate inside the volume's real
            // system-resolved Trash directory (`trashURL`, resolved once per scan) is skipped
            // before it can take a window slot or be ranked. Skipping here (not after ranking)
            // keeps the bounded candidate window filled with keepers, so a Trash-heavy volume
            // still yields a full list. The category breakdown is untouched — Trash still
            // counts as occupied space. Count each skip so the cascade can discount Trash from
            // the deliverable total.
            guard !TrashFilter.isInTrash(url, trashURL: trashURL) else { trashSkipped += 1; continue }
            let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? url.lastPathComponent
            // Rank + display by ON-DISK (allocated) size, not the logical size Spotlight
            // sorted on; fall back to logical when the allocated read is unavailable.
            let logical = size.int64Value
            let onDisk = onDiskSizing.onDiskSizeBytes(of: url) ?? logical
            files.append(LargestFile(displayName: name, sizeBytes: onDisk, url: url))
        }
        return (files: files, matchedCount: matchedCount, trashSkipped: trashSkipped)
    }
}
