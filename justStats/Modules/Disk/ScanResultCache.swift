import Foundation

/// Monotonic time source for the cache's TTL (A2). Seamed so tests drive freshness
/// deterministically instead of sleeping. Production uses the process's uptime clock,
/// which — unlike wall-clock `Date()` — never jumps backward on an NTP correction or a
/// user changing the system clock, so a cache entry can't be spuriously "fresh forever"
/// or instantly stale because the wall clock moved.
protocol MonotonicClock {
    /// Seconds since an arbitrary fixed reference. Only *differences* are meaningful.
    func now() -> TimeInterval
}

/// Production clock: `ProcessInfo.systemUptime` counts up steadily while the process
/// runs and is immune to wall-clock adjustments — the right source for a short TTL.
struct SystemUptimeClock: MonotonicClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// In-memory, time-to-live cache of the last Spotlight scan results per volume (A2),
/// so reopening the popover shows the previous breakdown and largest-files list
/// *instantly*. Under the "thrift" model, a reopen within the TTL paints from cache and
/// skips the Spotlight scan entirely — no NSMetadataQuery runs for that data at all — so
/// a burst of reopens inside the TTL costs zero Spotlight-daemon work. Only a stale or
/// absent entry triggers a fresh scan (which then rewrites the cache).
///
/// **What it stores — results only, never a live query (NFR4).** Each entry keeps the
/// raw partial `CategoryBreakdown` (Apps/Media/Other + availability, re-reconciled with
/// fresh total/free by the view model at publish time) and the ranked
/// `LargestFilesResult`, each stamped with the monotonic time it was written. Nothing
/// here touches Spotlight; the cache is pure data. The popover is closed between opens,
/// so the cache lets the app show *last-known* results without ever querying Spotlight
/// while closed — the on-demand-only invariant (NFR4) is preserved.
///
/// **Ownership & lifetime.** Held by `VolumeListPopoverCoordinator`, which outlives
/// individual popover opens, and injected into each fresh `VolumeListViewModel`. A per-
/// open view model reads its volumes' entries on `load()` (instant paint), then writes
/// fresh results back as each background scan finishes — so the *next* open is instant too.
///
/// **TTL.** An entry read within `ttl` seconds of being written is *fresh*: it is
/// published immediately and no scan is run for it (thrift). Older entries are ignored (a
/// stale scan is worse than a brief scanning state), so a fresh scan runs and rewrites the
/// entry. `SystemUptimeClock` drives freshness in production; tests inject a fake clock.
///
/// **Concurrency.** `@MainActor`-confined, matching its only callers
/// (`VolumeListViewModel`, `VolumeListPopoverCoordinator`) — no locking needed, and no
/// background thread ever touches it (background scans hop their results to main before
/// the view model writes them here).
@MainActor
final class ScanResultCache {
    /// Default freshness window (A2): 5 minutes. Within this window a reopen paints from
    /// cache *and does no Spotlight work at all* (the "thrift" model): a measured category
    /// scan is ~3–6s of Spotlight-daemon work, so frequent reopens inside 5 minutes must
    /// skip it entirely. Long enough to cover a burst of close/reopens, short enough that a
    /// genuinely stale breakdown isn't shown for long — a stale entry falls back to a fresh
    /// scan. See `VolumeListViewModel.scanNextPending` / `startLargestFilesScanIfNeeded`.
    static let defaultTTL: TimeInterval = 300

    /// One volume's cached scan results. Either half may be absent (e.g. the category
    /// scan finished but the largest-files scan hasn't yet, or vice versa); each carries
    /// its own timestamp so the two halves expire independently.
    private struct Entry {
        var categories: (value: CategoryBreakdown, writtenAt: TimeInterval)?
        var largestFiles: (value: LargestFilesResult, writtenAt: TimeInterval)?
    }

    private let ttl: TimeInterval
    private let clock: MonotonicClock
    private var entries: [URL: Entry] = [:]

    /// - Parameters:
    ///   - ttl: freshness window in seconds (default `defaultTTL`). A non-positive TTL
    ///     makes every entry stale on read — a way to disable the instant-paint path.
    ///   - clock: monotonic time source (default `SystemUptimeClock`). Injected so tests
    ///     advance time without sleeping.
    init(ttl: TimeInterval = defaultTTL, clock: MonotonicClock = SystemUptimeClock()) {
        self.ttl = ttl
        self.clock = clock
    }

    // MARK: - Category breakdown

    /// Stores the raw partial category breakdown for `url`, stamped now. The view model
    /// stores the *unreconciled* `CategoryBreakdown` (not the fitted `StorageBreakdown`)
    /// so a later read can re-reconcile against the volume's then-current total/free.
    func storeCategories(_ breakdown: CategoryBreakdown, forVolumeAt url: URL) {
        entries[url, default: Entry()].categories = (value: breakdown, writtenAt: clock.now())
    }

    /// The cached category breakdown for `url` iff it was written within the TTL, else
    /// `nil` (absent or stale). A non-`nil` return means "paint this and skip the scan"
    /// (thrift); a `nil` return means "run a fresh scan".
    func categories(forVolumeAt url: URL) -> CategoryBreakdown? {
        guard let stamped = entries[url]?.categories, isFresh(stamped.writtenAt) else { return nil }
        return stamped.value
    }

    // MARK: - Largest files

    /// Stores the ranked largest-files result for `url`, stamped now.
    func storeLargestFiles(_ result: LargestFilesResult, forVolumeAt url: URL) {
        entries[url, default: Entry()].largestFiles = (value: result, writtenAt: clock.now())
    }

    /// The cached largest-files result for `url` iff written within the TTL, else `nil`.
    func largestFiles(forVolumeAt url: URL) -> LargestFilesResult? {
        guard let stamped = entries[url]?.largestFiles, isFresh(stamped.writtenAt) else { return nil }
        return stamped.value
    }

    // MARK: - Internals

    /// Whether an entry written at `writtenAt` is still within the TTL as of now. A
    /// non-positive TTL is always stale; the monotonic clock guarantees `now >= writtenAt`
    /// for any entry this cache wrote, so the elapsed span is never negative.
    private func isFresh(_ writtenAt: TimeInterval) -> Bool {
        guard ttl > 0 else { return false }
        return clock.now() - writtenAt < ttl
    }
}
