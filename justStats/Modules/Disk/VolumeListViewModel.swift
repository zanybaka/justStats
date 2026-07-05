import Combine
import Foundation

/// Seam between the view model and `DeferredVolumeResolver` so streaming tests
/// can deliver resolutions synchronously (same pattern as `PopoverPresenting`).
/// Production conformance guarantees main-queue delivery of `onResult`.
protocol DeferredVolumeResolving: AnyObject {
    func resolve(_ volumes: [DeferredVolume], onResult: @escaping (DeferredVolumeResolution) -> Void)
    func invalidate()
}

extension DeferredVolumeResolver: DeferredVolumeResolving {}

/// Popover volume-list state (VOL-004, PRD FR2–FR5): bridges VOL-002's streaming
/// callbacks to `@Published` rows the SwiftUI list renders.
///
/// `load()` runs the synchronous enumeration pass inline — internal volumes are
/// statfs-cheap by classification (VOL-001), so their rows exist before the
/// popover is even shown (FR3). Every deferred external/network volume gets a
/// `.pending` placeholder row immediately; as VOL-002 streams resolutions in on
/// the main queue, each placeholder is replaced *in place* — enumeration order
/// is stable, rows never jump while loading (FR4).
///
/// On top of that, each *loaded* volume kicks off an on-demand Spotlight category
/// scan (SCAN-001) whose result is reconciled with the volume's total/free into a
/// five-way `StorageBreakdown` (SCAN-002) and published per mount URL (SCAN-004).
/// The category bar renders from that; a still-scanning volume shows the plain
/// usage bar until its breakdown lands. Scans run only from `load()`/`refresh()`
/// (popover open / Refresh) — never on a timer (NFR4).
@MainActor
final class VolumeListViewModel: ObservableObject {
    /// One popover row. Keyed by mount URL — the identity `DeferredVolumeResolution`
    /// results carry, so a streamed result always finds its placeholder.
    enum Row: Equatable, Identifiable {
        /// Fully resolved volume with sizes (internal, or a resolved deferred one).
        case loaded(Volume)
        /// Deferred volume whose capacity read is still in flight.
        case pending(DeferredVolume)
        /// Deferred volume whose capacity read failed or timed out (VOL-002).
        case unavailable(DeferredVolume)

        var id: URL {
            switch self {
            case .loaded(let volume): return volume.mountURL
            case .pending(let volume), .unavailable(let volume): return volume.mountURL
            }
        }

        /// Used share of the volume in `0...1` — the sort key for "most-full first"
        /// (PRD FR9). A row with no resolved sizes (`.pending`/`.unavailable`) has
        /// no meaningful fullness, so it counts as `0` and sinks to the bottom;
        /// a resolved row defers to `Volume.usedFraction`, the shared fullness
        /// definition (zero-total safe, clamped).
        var fullness: Double {
            guard case .loaded(let volume) = self else { return 0 }
            return volume.usedFraction
        }
    }

    /// Per-volume category-breakdown state (SCAN-004). One entry per loaded volume,
    /// keyed by mount URL — the row uses it to pick what to draw under the name:
    /// - `.scanning` — the Spotlight scan is in flight; the row keeps the plain
    ///   usage bar until the breakdown lands (no fake segments, no stall).
    /// - `.breakdown` — a reconciled five-way `StorageBreakdown`; the row draws the
    ///   stacked category bar (System/Apps/Media/Other/Free).
    /// - `.notIndexed` — Spotlight has no usable index for the volume; SCAN-005 owns
    ///   the "Not indexed" presentation from this case (kept distinct from a
    ///   resolved breakdown so it is never rendered as a misleading all-System bar).
    /// - `.needsFullDiskAccess` — an unavailable index on the *boot/system volume*,
    ///   which is always Spotlight-indexed under normal conditions: an empty result
    ///   there is permissions-shaped, so SCAN-006 shows the lazy "Grant Full Disk
    ///   Access" affordance instead of the generic "Not indexed" notice. Spotlight
    ///   cannot itself distinguish a permissions block from a genuinely unindexed
    ///   drive (both come back empty with no discriminating error), so the volume's
    ///   role is the signal — see `unavailableState(forBootVolume:)`.
    enum CategoryState: Equatable {
        case scanning
        case breakdown(StorageBreakdown)
        case notIndexed
        case needsFullDiskAccess
    }

    /// Enumeration-ordered rows (internal first, then deferred in mount order) as
    /// produced by `load()` and mutated in place by streaming resolutions. This is
    /// the canonical order; the sort toggle derives `displayRows` from it without
    /// disturbing it, so toggling off restores the default order exactly (FR9).
    @Published private(set) var rows: [Row] = []

    /// Category-breakdown state per volume mount URL (SCAN-004), populated on demand
    /// as each loaded volume's Spotlight scan (SCAN-001) resolves. A volume with no
    /// entry has not started scanning (or its row isn't `.loaded`); the view falls
    /// back to the plain usage bar. Rebuilt from empty on every `load()`/`refresh()`.
    @Published private(set) var categoryStates: [URL: CategoryState] = [:]

    /// The largest-files section's state (ACT-001, PRD FR7). The section sits below
    /// the volume rows, scoped to one volume (`largestFilesVolumeURL`):
    /// - `.scanning(partial:)` — the Spotlight largest-files scan (SCAN-003) is in
    ///   flight. `partial` is the best-so-far top-N delivered progressively during the
    ///   query's gathering phase (A2): empty at the very start (the section shows a
    ///   lightweight loading state), then a growing largest-first list as Spotlight
    ///   reports progress — so the section fills in before the full gather finishes.
    ///   Never fabricated rows: every entry in `partial` is a real gathered file.
    /// - `.available` — the final ranked top-N files, largest first, ready to render.
    /// - `.unavailable` — the scoped volume has no usable Spotlight index; the section
    ///   shows the same "Not indexed" story as the category bar (SCAN-005) rather than
    ///   an empty list that reads as "no large files".
    ///
    /// `.idle` is the pre-scan state (no scoped volume yet, e.g. before `load()` or
    /// when no volume is loaded); the section renders nothing. Rebuilt on every
    /// `load()`/`refresh()`; a stale delivery (partial or final) from a superseded pass
    /// is dropped by the generation guard.
    enum LargestFilesState: Equatable {
        case idle
        /// In flight; `partial` is the progressively-delivered best-so-far top-N (A2),
        /// empty until the first gathering-progress tick lands.
        case scanning(partial: [LargestFile])
        case available([LargestFile])
        case unavailable

        /// The initial in-flight state before any progressive partial has arrived — an
        /// empty best-so-far. Existing call sites that just mean "scanning, nothing yet"
        /// use this instead of spelling out `.scanning(partial: [])`.
        static let scanning = LargestFilesState.scanning(partial: [])
    }

    /// Largest-files section state for the scoped volume (ACT-001). Populated lazily
    /// from `load()`/`refresh()` — never on a timer (NFR4). See `LargestFilesState`.
    ///
    /// This is the **visible** state: entries the user has hidden (UX-015) are filtered
    /// out of the `.scanning`/`.available` files before it is published, so the section
    /// never renders a hidden row. The unfiltered list is kept in `rawLargestFiles` so the
    /// "N hidden" affordance can reconstruct and un-hide those rows.
    @Published private(set) var largestFilesState: LargestFilesState = .idle

    /// The last full largest-files list delivered by the scanner (or painted from cache),
    /// **before** the hidden-path filter (UX-015). Kept so the hidden entries can be
    /// reconstructed for the "N hidden — Show" affordance and so re-filtering (after a
    /// hide/unhide) doesn't need a re-scan. Empty until the scoped volume delivers a list;
    /// a `.unavailable`/`.scanning`-with-no-partial state leaves it empty.
    private var rawLargestFiles: [LargestFile] = []

    /// The scoped volume's largest files the user has hidden (UX-015), reconstructed from
    /// the raw list — the rows the "Show hidden" affordance reveals so the user is never
    /// trapped. Largest-first (the raw list is already ranked). Empty when nothing in the
    /// current list is hidden.
    var hiddenLargestFiles: [LargestFile] {
        let hidden = hiddenFilesStore.hiddenPaths
        return rawLargestFiles.filter { hidden.contains($0.path) }
    }

    /// How many entries in the current largest-files list are hidden (UX-015) — drives the
    /// "N hidden" affordance in the section header. Zero when nothing is hidden (the
    /// affordance is then absent).
    var hiddenLargestFilesCount: Int { hiddenLargestFiles.count }

    /// The largest-files row currently awaiting a Move-to-Trash confirmation (ACT-002),
    /// keyed by file URL, or `nil` when no row is in the two-step confirm state. Exactly
    /// one row can be pending at a time: activating Trash on a second row moves the
    /// pending state to it (the first silently reverts), so a destructive confirm is
    /// never ambiguous about which file it applies to. The confirmation is inline in the
    /// row (TECHSPEC §8) — this drives that in-row state, not a modal.
    @Published private(set) var pendingTrashConfirmationURL: URL?

    /// Per-file inline error text from a failed Move-to-Trash (ACT-002), keyed by file
    /// URL: a locked file, a permission denial, or a file already gone surfaces here so
    /// the row shows it inline instead of crashing (TECHSPEC §7). Cleared when the user
    /// re-activates Trash on that row (a fresh attempt) or on any `load()`/`refresh()`.
    @Published private(set) var trashErrorMessages: [URL: String] = [:]

    /// The volume whose largest files the section shows (ACT-001). Scoped to the boot
    /// volume when present, else the first loaded volume in row order (no per-row
    /// selection model exists yet — kept simple per the task). `nil` when no volume is
    /// loaded. Exposed so the section can name the volume it is scoped to.
    @Published private(set) var largestFilesVolumeURL: URL?

    /// Display name of the volume the largest-files section is scoped to, for the
    /// section header (e.g. "Largest files on Macintosh HD"). `nil` when no volume is
    /// scoped yet. Derived from the current rows so it always matches the live name.
    var largestFilesVolumeName: String? {
        guard let url = largestFilesVolumeURL else { return nil }
        for case .loaded(let volume) in rows where volume.mountURL == url {
            return volume.name
        }
        return nil
    }

    /// "Most-full first" sort toggle (PRD FR9). Off by default: `displayRows`
    /// equals the enumeration order. On: rows are ordered by descending fullness,
    /// stably (equal-fullness rows keep enumeration order).
    @Published var sortMostFullFirst = false

    /// Rows in the order the view should render them. Off → enumeration order; on →
    /// stable sort by descending fullness. Swift's `sorted(by:)` is a stable sort,
    /// so equal-fullness rows (including all size-less rows, which share fullness 0)
    /// keep their relative enumeration order — no jumping between refreshes.
    var displayRows: [Row] {
        guard sortMostFullFirst else { return rows }
        return rows.sorted { $0.fullness > $1.fullness }
    }

    private let enumerate: () -> VolumeEnumerator.Snapshot
    private let resolver: DeferredVolumeResolving
    private let scanner: CategoryScanning
    private let largestFilesScanner: LargestFilesScanning
    /// In-memory TTL cache of the last scan results, keyed by volume URL (A2). Held by
    /// `VolumeListPopoverCoordinator` and injected here, so it outlives this per-open
    /// model. Thrift model: on `load()` a *fresh* cached breakdown/list paints instantly
    /// AND its Spotlight scan is skipped entirely (zero NSMetadataQuery work). Only a
    /// stale/absent entry — or a forced `refresh()` — runs a scan, which then rewrites the
    /// cache. Results only — never a live query — so the on-demand Spotlight invariant
    /// (NFR4) holds while the popover is closed. Nil (default) disables the cache path
    /// entirely (every open scans); tests that don't exercise caching leave it nil so
    /// their scan expectations are unchanged.
    private let cache: ScanResultCache?
    /// Moves a largest-files entry to the Trash (ACT-002). Injected behind the
    /// `FileTrashing` seam so the confirm-state machine is unit-tested without ever
    /// touching the real filesystem; the production default is the recoverable
    /// `FileManager.trashItem` wrapper.
    private let fileTrasher: FileTrashing
    /// Persists which largest-files rows the user has hidden (UX-015). Injected behind the
    /// `HiddenFilesStoring` seam so the filter-and-persist logic is unit-tested against an
    /// isolated defaults suite; the production default persists to `.standard`. The hidden
    /// set is applied on every scan/cache delivery before publishing, so a hidden row stays
    /// hidden across popover opens and app launches.
    private let hiddenFilesStore: HiddenFilesStoring
    /// Bumped on every `load()`. A scan result carrying an older generation is a
    /// stale delivery from a superseded pass (the single shared scanner only tracks
    /// its latest scan, but reconciliation happens here on delivery, so the view
    /// model guards its own generation too) and is dropped rather than published.
    private var scanGeneration: UInt64 = 0
    /// Bumped on every `load()`, independent of `scanGeneration`. Guards the
    /// largest-files scan (ACT-001) the same way: a delivery tagged with an older
    /// generation is a superseded pass's result and is dropped.
    private var largestFilesGeneration: UInt64 = 0
    /// Whether the current pass bypasses the thrift cache and forces a full Spotlight
    /// re-scan. Set by `load(forceRescan:)` at the start of each pass: `false` for a
    /// normal open (a fresh cache entry is painted and its scan skipped), `true` for
    /// `refresh()` (always re-scan and rewrite the cache). Read by the scan-launch paths
    /// so a scan that spans a streamed resolution honours the pass it belongs to.
    private var forceRescan = false

    init(
        enumerate: @escaping () -> VolumeEnumerator.Snapshot = { VolumeEnumerator().enumerateSynchronously() },
        resolver: DeferredVolumeResolving = DeferredVolumeResolver(),
        scanner: CategoryScanning = SpotlightCategoryScanner(),
        largestFilesScanner: LargestFilesScanning = SpotlightLargestFilesScanner(),
        fileTrasher: FileTrashing = FileManagerFileTrasher(),
        hiddenFilesStore: HiddenFilesStoring = HiddenFilesStore(),
        cache: ScanResultCache? = nil
    ) {
        self.enumerate = enumerate
        self.resolver = resolver
        self.scanner = scanner
        self.largestFilesScanner = largestFilesScanner
        self.fileTrasher = fileTrasher
        self.hiddenFilesStore = hiddenFilesStore
        self.cache = cache
    }

    /// Runs the synchronous pass and kicks off streaming resolution of the
    /// deferred volumes. Callable again for a fresh pass (VOL-005 Refresh):
    /// the resolver's generation bump drops stale in-flight deliveries.
    ///
    /// Category scans (SCAN-004) start here too, but only for volumes whose sizes
    /// are already known: internal volumes scan on open; a deferred volume scans
    /// once its capacity resolves (`apply`). Scans run one at a time through the
    /// single shared scanner seam (`scanNextPending`), so no two Spotlight passes
    /// overlap — the on-demand, bounded model NFR4 requires.
    ///
    /// **Thrift.** When a volume's cached Spotlight results are *fresh* (within the
    /// cache TTL), `load()` paints them and runs *no* Spotlight scan for that data —
    /// zero NSMetadataQuery work — since a category scan is seconds of daemon work and a
    /// reopen within minutes should cost nothing. Only a stale or absent cache triggers a
    /// fresh scan. Volume *enumeration* (free/used via statfs) is cheap and always runs,
    /// so sizes are current even when the Spotlight data is served from cache. `refresh()`
    /// bypasses the cache entirely and forces a full re-scan (see `forceRescan`).
    func load() {
        load(forceRescan: false)
    }

    /// Shared body of `load()`/`refresh()`. `forceRescan` bypasses the thrift cache: a
    /// forced pass always runs the Spotlight scans and rewrites the cache, even when the
    /// cached results are still fresh (the Refresh button, VOL-005). A non-forced pass
    /// honours the cache — a fresh entry is painted and its scan is skipped entirely.
    private func load(forceRescan: Bool) {
        self.forceRescan = forceRescan
        // A fresh pass supersedes any in-flight scan: bump the generation (stale
        // results are dropped) and, if a scan is actually running, cancel its live
        // queries and clear the in-flight marker so the new pass starts from the top.
        // Nothing is cancelled on a first load with no scan in flight.
        scanGeneration &+= 1
        largestFilesGeneration &+= 1
        if scanningURL != nil {
            scanner.cancel()
            scanningURL = nil
        }
        // A fresh pass supersedes any in-flight largest-files scan too; its stale
        // delivery is dropped by the generation guard, but cancel the live query so
        // nothing keeps gathering (SCAN-007) and reset the section to a clean state.
        largestFilesScanner.cancel()
        largestFilesState = .idle
        rawLargestFiles = []
        largestFilesVolumeURL = nil
        // A fresh pass rebuilds the largest-files list, so any in-row Trash confirm or
        // error from the prior pass is stale (it referred to the old list) — clear it
        // so the section never opens with a dangling confirm/error on a row that may no
        // longer exist (ACT-002).
        pendingTrashConfirmationURL = nil
        trashErrorMessages = [:]
        let snapshot = enumerate()
        rows = snapshot.internalVolumes.map(Row.loaded)
            + snapshot.deferredVolumes.map(Row.pending)
        categoryStates = [:]
        scanNextPending()
        startLargestFilesScanIfNeeded()
        guard !snapshot.deferredVolumes.isEmpty else { return }
        resolver.resolve(snapshot.deferredVolumes) { [weak self] resolution in
            self?.apply(resolution)
        }
    }

    /// Manual "Refresh" (VOL-005, PRD FR13): re-runs enumeration in place without
    /// closing the popover. Delegates to the shared load body with `forceRescan: true`,
    /// so it *always* bypasses the thrift cache and runs a full Spotlight re-scan even
    /// when the cached results are still fresh — Refresh means "get me current data now".
    /// The fresh `resolve` pass bumps the resolver's generation and drops every stale
    /// in-flight delivery from the prior pass; the sort toggle is preserved (only the
    /// data is refreshed).
    func refresh() {
        load(forceRescan: true)
    }

    /// Drops undelivered resolutions and cancels the in-flight Spotlight scan
    /// (popover closed — no UI left to update, and no query should keep gathering).
    func invalidate() {
        scanGeneration &+= 1
        largestFilesGeneration &+= 1
        resolver.invalidate()
        scanner.cancel()
        largestFilesScanner.cancel()
    }

    /// Replaces the streamed volume's placeholder row in place. A resolution
    /// with no matching row (stale delivery after rows were rebuilt) is ignored.
    /// A newly-resolved volume becomes eligible for a category scan, so the scan
    /// queue is nudged — if nothing is scanning, this volume's scan starts now.
    private func apply(_ resolution: DeferredVolumeResolution) {
        guard let index = rows.firstIndex(where: { $0.id == resolution.mountURL }) else { return }
        switch resolution {
        case .resolved(let volume):
            rows[index] = .loaded(volume)
            scanNextPending()
            // If load() found no loaded volume to scope the largest-files section to
            // (every row was still pending), this newly-resolved one becomes the
            // scope. Once a scope is chosen it never changes for this pass.
            startLargestFilesScanIfNeeded()
        case .unavailable(let volume):
            rows[index] = .unavailable(volume)
        }
    }

    // MARK: - Category scanning (SCAN-004)

    /// The volume that currently has a scan in flight (nil when idle). Scans run
    /// strictly one at a time through the single shared scanner seam, so a result
    /// always maps back to exactly this volume.
    private var scanningURL: URL?

    /// Advances the category-scan walk to the next loaded volume that has no
    /// `categoryStates` entry yet, if the scanner is idle. Called after `load()` and after
    /// each streamed resolution and scan result, so scanning walks the loaded volumes one
    /// by one until every one has a breakdown (or "Not indexed"). Idempotent while a scan
    /// is in flight.
    ///
    /// **Thrift (the whole point of the 5-minute cache).** For each pending volume, if
    /// this is not a forced refresh and the volume's cached categories are *fresh*, the
    /// cached breakdown is painted and the volume is settled *without any Spotlight scan* —
    /// a fresh cache costs zero NSMetadataQuery work. Such volumes are skipped over here in
    /// a loop; only the first volume that actually needs a scan (forced refresh, or a
    /// stale/absent cache) launches one and returns. A cache-painted volume never occupies
    /// the single-scan slot, so a run of fresh volumes doesn't stall the walk.
    private func scanNextPending() {
        guard scanningURL == nil else { return }
        while let volume = nextVolumeToScan() {
            let url = volume.mountURL
            let total = volume.totalBytes
            let free = volume.freeBytes
            // The boot/system volume is the permissions-shaped case (SCAN-006): an empty
            // Spotlight index there means Full Disk Access, not an unindexed drive.
            let isBootVolume = Self.isBootVolume(volume)

            // Thrift: a fresh cache (and not a forced refresh) paints instantly and runs
            // NO scan — re-reconciled with this volume's *current* total/free (the raw
            // categories are cached, not the fitted bar, so sizes that moved since don't
            // produce a stale bar). This volume is settled; keep walking for the next one.
            if !forceRescan, let cached = cache?.categories(forVolumeAt: url) {
                categoryStates[url] = breakdownState(
                    for: cached, total: total, free: free, isBootVolume: isBootVolume
                )
                continue
            }

            // Stale/absent cache, or a forced refresh: this volume must scan. Show the
            // `.scanning` placeholder and launch the one in-flight Spotlight pass.
            let generation = scanGeneration
            scanningURL = url
            categoryStates[url] = .scanning
            scanner.scan(volumeURL: url) { [weak self] categories in
                self?.applyScan(
                    categories,
                    forVolumeAt: url,
                    total: total,
                    free: free,
                    isBootVolume: isBootVolume,
                    generation: generation
                )
            }
            return
        }
    }

    /// Turns a partial Spotlight `CategoryBreakdown` into the `CategoryState` the row
    /// shows: a reconciled five-way `StorageBreakdown` when the index is available, or
    /// the degraded state the volume's role selects otherwise. Shared by the fresh-scan
    /// delivery (`applyScan`) and the instant cache paint (`scanNextPending`), so both
    /// paths present a cached and a freshly-scanned breakdown identically.
    private func breakdownState(
        for categories: CategoryBreakdown,
        total: Int64,
        free: Int64,
        isBootVolume: Bool
    ) -> CategoryState {
        guard categories.isIndexAvailable else {
            return Self.unavailableState(forBootVolume: isBootVolume)
        }
        return .breakdown(
            StorageBreakdown.reconciled(categories: categories, totalBytes: total, freeBytes: free)
        )
    }

    /// Whether `volume` is the boot/system volume, presented at `/` (VolumeEnumerator
    /// keeps only the root presentation and drops the `/System/Volumes/*` service
    /// mounts). The root volume is always Spotlight-indexed under normal conditions,
    /// so an unavailable index there is the permissions-shaped signal that drives the
    /// Full Disk Access notice (SCAN-006) rather than the generic "Not indexed" one.
    nonisolated static func isBootVolume(_ volume: Volume) -> Bool {
        volume.mountURL.path == "/"
    }

    /// Classifies an *unavailable* Spotlight index (SCAN-005/006). Both a genuinely
    /// unindexed drive and a Full Disk Access block surface as an empty index with no
    /// discriminating error, so the volume's role is the only available signal:
    /// on the boot/system volume — always indexed by default — an empty result is
    /// permissions-shaped → `.needsFullDiskAccess`; anywhere else it is a plain
    /// unindexed drive → `.notIndexed`. Pure and unit-tested; the actual System
    /// Settings deep link is verified manually.
    nonisolated static func unavailableState(forBootVolume isBootVolume: Bool) -> CategoryState {
        isBootVolume ? .needsFullDiskAccess : .notIndexed
    }

    /// The first loaded volume, in row order, that has no category state yet — the
    /// next one to scan. Only `.loaded` rows have known sizes to reconcile against.
    private func nextVolumeToScan() -> Volume? {
        for case .loaded(let volume) in rows where categoryStates[volume.mountURL] == nil {
            return volume
        }
        return nil
    }

    /// A category scan finished for `url`. Stale deliveries (a scan started before a
    /// `load()`/`invalidate()` bumped the generation) are dropped without touching
    /// state. Otherwise the partial Spotlight categories are reconciled with the
    /// volume's captured total/free into a `StorageBreakdown` (SCAN-002) and
    /// published — or, when the index was unavailable, recorded as the degraded state
    /// the volume's role selects: `.needsFullDiskAccess` on the boot volume (SCAN-006)
    /// or `.notIndexed` elsewhere (SCAN-005) — then the scan queue advances.
    private func applyScan(
        _ categories: CategoryBreakdown,
        forVolumeAt url: URL,
        total: Int64,
        free: Int64,
        isBootVolume: Bool,
        generation: UInt64
    ) {
        guard generation == scanGeneration else { return }
        scanningURL = nil
        // Cache the raw partial categories (not the fitted bar) so the next reopen can
        // re-reconcile against then-current sizes; write even the unavailable result so a
        // reopen paints the same degraded state instantly instead of a scanning flash (A2).
        cache?.storeCategories(categories, forVolumeAt: url)
        categoryStates[url] = breakdownState(
            for: categories, total: total, free: free, isBootVolume: isBootVolume
        )
        scanNextPending()
    }

    // MARK: - Largest files (ACT-001)

    /// Starts the largest-files scan for the scoped volume if one is loaded and no
    /// scope has been chosen yet for this pass. Idempotent: once `largestFilesVolumeURL`
    /// is set it stays put for the rest of the pass, so a later resolution can't retarget
    /// the section or restart the scan. Called from `load()` (after rows are built) and
    /// from `apply` (in case every row was still pending at load time).
    private func startLargestFilesScanIfNeeded() {
        guard largestFilesVolumeURL == nil else { return }
        guard let volume = scopedLargestFilesVolume() else { return }
        let url = volume.mountURL
        largestFilesVolumeURL = url

        // Thrift (the whole point of the 5-minute cache): a fresh cached list/degraded-
        // state (and not a forced refresh) is painted instantly and runs NO Spotlight
        // scan — a fresh cache costs zero NSMetadataQuery work. The scope is fixed above,
        // so a later resolution can't retrigger a scan for this section either.
        if !forceRescan, let cached = cache?.largestFiles(forVolumeAt: url) {
            if cached.isIndexAvailable {
                // Record the raw list and publish the hidden-filtered view (UX-015) so a
                // previously-hidden row stays hidden even when painted straight from cache.
                rawLargestFiles = cached.files
                largestFilesState = .available(visibleLargestFiles(from: cached.files))
            } else {
                rawLargestFiles = []
                largestFilesState = .unavailable
            }
            return
        }

        // Stale/absent cache, or a forced refresh: scan. Show the `.scanning` placeholder
        // (progressive partials fill it in); the final result rewrites the cache.
        let generation = largestFilesGeneration
        largestFilesState = .scanning
        largestFilesScanner.scan(
            volumeURL: url,
            limit: LargestFilesResult.defaultLimit,
            onPartial: { [weak self] partial in
                self?.applyLargestFilesPartial(partial, forVolumeAt: url, generation: generation)
            },
            onResult: { [weak self] result in
                self?.applyLargestFiles(result, forVolumeAt: url, generation: generation)
            }
        )
    }

    /// A progressive best-so-far partial (A2) arrived for `url` while the scan is still
    /// gathering. Published as `.scanning(partial:)` so the section fills in largest-first
    /// before the final result lands. Dropped when:
    /// - the generation is stale (a superseded pass — `load()`/`invalidate()` bumped it);
    /// - it isn't for the currently-scoped volume;
    /// - the section is no longer in a scanning state. That last guard means a partial
    ///   never overwrites a final `.available`/`.unavailable`, and — crucially for the
    ///   cache path — never shrinks an instantly-painted cached list back to a smaller
    ///   in-progress snapshot. Only the final result replaces a cached list.
    /// - it would shrink the partial already shown. The scanner delivers a monotonically
    ///   growing best-so-far, but a size-floor cascade descent restarts gathering from
    ///   empty at a lower floor, so a fresh floor's early tick can momentarily report a
    ///   subset of the prior floor's list. Refusing a regressing partial here keeps the
    ///   visible list from flickering shorter even if a non-monotonic partial slips
    ///   through — defense in depth alongside the scanner's own `improves(over:)` guard.
    private func applyLargestFilesPartial(
        _ partial: [LargestFile],
        forVolumeAt url: URL,
        generation: UInt64
    ) {
        guard generation == largestFilesGeneration else { return }
        guard largestFilesVolumeURL == url else { return }
        guard case .scanning(let current) = largestFilesState else { return }
        // Compare and publish the hidden-filtered view (UX-015): the improvement guard
        // works on what the section actually shows, and a hidden path never appears in a
        // progressive partial. `current` is already the filtered visible list.
        let visible = visibleLargestFiles(from: partial)
        guard Self.partialImproves(visible, over: current) else { return }
        rawLargestFiles = partial
        largestFilesState = .scanning(partial: visible)
    }

    /// Whether a progressive `candidate` partial is worth replacing the `current` one
    /// with — a strict improvement of the visible top-N, never a regression. More files
    /// (the list growing toward the limit) or the same count with a larger total (the
    /// same slots holding bigger files) improves; fewer files, or the same count with an
    /// equal/smaller total, does not, so a transient cascade-floor subset can't shrink or
    /// churn the shown list. Pure and unit-tested (ACT-001, A2 monotonic-partial guard).
    nonisolated static func partialImproves(
        _ candidate: [LargestFile],
        over current: [LargestFile]
    ) -> Bool {
        if candidate.count != current.count { return candidate.count > current.count }
        let candidateTotal = candidate.reduce(Int64(0)) { $0 &+ $1.sizeBytes }
        let currentTotal = current.reduce(Int64(0)) { $0 &+ $1.sizeBytes }
        return candidateTotal > currentTotal
    }

    /// The volume the largest-files section is scoped to: the boot volume when it is
    /// loaded, else the first loaded volume in row order. `nil` when no volume is
    /// loaded yet (every row still pending/unavailable). No per-row selection model
    /// exists, so this is deliberately simple (ACT-001).
    private func scopedLargestFilesVolume() -> Volume? {
        for case .loaded(let volume) in rows where Self.isBootVolume(volume) {
            return volume
        }
        for case .loaded(let volume) in rows {
            return volume
        }
        return nil
    }

    /// A largest-files scan finished for `url`. A stale delivery (a scan started
    /// before a `load()`/`invalidate()` bumped the generation) is dropped without
    /// touching state. Otherwise the ranked list is published, or — when the index
    /// was unavailable — the `.unavailable` degraded state (SCAN-005 "Not indexed"
    /// story) is recorded so the section never shows an empty list as "no large files".
    private func applyLargestFiles(
        _ result: LargestFilesResult,
        forVolumeAt url: URL,
        generation: UInt64
    ) {
        guard generation == largestFilesGeneration else { return }
        guard largestFilesVolumeURL == url else { return }
        // Cache the fresh result (available or unavailable) so the next reopen paints it
        // instantly (A2), then publish it — the final result always supersedes any cached
        // list or in-progress partial for this pass.
        cache?.storeLargestFiles(result, forVolumeAt: url)
        if result.isIndexAvailable {
            // Keep the unfiltered list for the hidden affordance, publish the hidden-
            // filtered view (UX-015). The cache stores the *full* result so a hidden path
            // can still be un-hidden after a reopen.
            rawLargestFiles = result.files
            largestFilesState = .available(visibleLargestFiles(from: result.files))
        } else {
            rawLargestFiles = []
            largestFilesState = .unavailable
        }
    }

    // MARK: - Hide / un-hide (UX-015)

    /// The subset of `files` the user has NOT hidden — what the section renders. Applied on
    /// every scan/cache delivery and after any hide/unhide so a hidden path never shows,
    /// across popover opens and app launches. Order is preserved (the input is ranked).
    private func visibleLargestFiles(from files: [LargestFile]) -> [LargestFile] {
        let hidden = hiddenFilesStore.hiddenPaths
        guard !hidden.isEmpty else { return files }
        return files.filter { !hidden.contains($0.path) }
    }

    /// Re-publishes the current largest-files list through the hidden filter after the
    /// hidden set changed (a hide/unhide/clear), without a re-scan — the raw list is
    /// already held. Only rewrites an `.available`/`.scanning` state (an `.idle`/
    /// `.unavailable` section has no list to re-filter). Keeps any in-flight scan's
    /// progressive shape (`.scanning`) intact.
    private func republishVisibleLargestFiles() {
        switch largestFilesState {
        case .available:
            largestFilesState = .available(visibleLargestFiles(from: rawLargestFiles))
        case .scanning:
            largestFilesState = .scanning(partial: visibleLargestFiles(from: rawLargestFiles))
        case .idle, .unavailable:
            break
        }
    }

    /// Hides the largest-files row at `url` (UX-015): persists the path so it stays hidden
    /// across sessions and re-publishes the list so the row disappears immediately. A hide
    /// also disarms any pending Trash confirm on that row and clears its error — hiding is
    /// a clean exit from the row's interactions. Only acts while the section is showing a
    /// list (`.available` or a progressive `.scanning`); an `.idle`/`.unavailable` section
    /// has nothing to hide, so a spurious call is ignored.
    func hide(_ url: URL) {
        switch largestFilesState {
        case .available, .scanning:
            hiddenFilesStore.hide(url.path)
            if pendingTrashConfirmationURL == url { pendingTrashConfirmationURL = nil }
            trashErrorMessages[url] = nil
            republishVisibleLargestFiles()
        case .idle, .unavailable:
            break
        }
    }

    /// Un-hides the row at `url` (UX-015): removes the path from the persisted hidden set
    /// and re-publishes so the row reappears in the visible list (in its ranked place). The
    /// escape hatch behind the section's "N hidden — Show" affordance.
    func unhide(_ url: URL) {
        hiddenFilesStore.unhide(url.path)
        republishVisibleLargestFiles()
    }

    /// Clears every hidden path (UX-015) so all hidden rows reappear at once — the "un-hide
    /// all" escape hatch. Re-publishes the visible list from the raw one.
    func clearHiddenFiles() {
        hiddenFilesStore.clear()
        republishVisibleLargestFiles()
    }

    // MARK: - Move to Trash (ACT-002)

    /// First activation of a row's Trash action: flip *that* row into the inline
    /// confirm state ("Move to Trash?"), not a modal (TECHSPEC §8). Only one row is
    /// ever pending — this replaces any prior pending row, so a second activation moves
    /// the confirm rather than leaving two rows armed. Clears any stale error on the
    /// row so the fresh attempt starts clean. A no-op if the section isn't showing a
    /// ranked list (nothing to trash) — a guard against a spurious call.
    func requestTrashConfirmation(for url: URL) {
        guard case .available = largestFilesState else { return }
        trashErrorMessages[url] = nil
        pendingTrashConfirmationURL = url
    }

    /// Cancel path: back out of the inline confirm for `url` without trashing anything.
    /// Only clears the pending state if `url` is the one currently armed, so a cancel
    /// from a stale row can't disarm a different row's confirm. The file is untouched.
    func cancelTrashConfirmation(for url: URL) {
        guard pendingTrashConfirmationURL == url else { return }
        pendingTrashConfirmationURL = nil
    }

    /// Confirm path: move `url` to the Trash (recoverable, never a permanent delete —
    /// the `FileTrashing` seam has no delete method) and, on success, drop the row from
    /// the list and reflect the freed space on the scoped volume. On failure the error
    /// is surfaced inline on the row (locked/permission/missing) and the file is left in
    /// place — never a crash (TECHSPEC §7).
    ///
    /// Guarded to the currently-armed row: a confirm only fires for the row that is
    /// actually pending, so a double-activation or a stale confirm can't trash a
    /// different (or already-handled) file. The pending state is cleared either way.
    func confirmTrash(for url: URL) {
        guard pendingTrashConfirmationURL == url else { return }
        pendingTrashConfirmationURL = nil
        guard case .available(let files) = largestFilesState else { return }
        do {
            try fileTrasher.trash(url)
            removeTrashedFile(url, from: files)
            trashErrorMessages[url] = nil
        } catch {
            trashErrorMessages[url] = Self.trashErrorText(for: error)
        }
    }

    /// Removes the just-trashed file from the ranked list and reflects its freed bytes
    /// on the scoped volume's row (optimistic update — no re-query, ACT-002). If the URL
    /// isn't in the list (already handled), nothing changes.
    private func removeTrashedFile(_ url: URL, from files: [LargestFile]) {
        guard let trashed = files.first(where: { $0.url == url }) else { return }
        // Drop the trashed file from the *raw* list too (UX-015), then re-publish through
        // the hidden filter: a trashed row must vanish from both the visible list and the
        // "N hidden" reconstruction, and the cache must store the raw remaining list so
        // hidden-but-not-trashed rows aren't dropped from the cache.
        rawLargestFiles.removeAll { $0.url == url }
        largestFilesState = .available(visibleLargestFiles(from: rawLargestFiles))
        // Keep the cache consistent with the optimistic removal so a reopen within the TTL
        // doesn't resurrect the just-trashed row (A2). Cache the raw list (hidden entries
        // included) so a reopen can still un-hide them.
        if let scopedURL = largestFilesVolumeURL {
            cache?.storeLargestFiles(.available(rawLargestFiles), forVolumeAt: scopedURL)
        }
        applyFreedSpace(trashed.sizeBytes)
    }

    /// Optimistically credits `bytes` of freed space to the scoped volume's row after a
    /// trash, so the free/used figures update without a full re-enumeration. Scoped to
    /// the largest-files volume (the only volume whose files the section lists). A next
    /// Refresh reconciles against a real `statfs` read regardless.
    private func applyFreedSpace(_ bytes: Int64) {
        guard bytes > 0, let scopedURL = largestFilesVolumeURL else { return }
        guard let index = rows.firstIndex(where: { $0.id == scopedURL }) else { return }
        guard case .loaded(let volume) = rows[index] else { return }
        rows[index] = .loaded(volume.withFreedBytes(bytes))
    }

    /// Turns a trash failure into a short inline message. `CocoaError`s from
    /// `trashItem` carry a localized reason (e.g. permission, locked, not found); fall
    /// back to the error's own description otherwise. Kept generic on purpose — the row
    /// shows a one-line notice, and the file path is never logged (TECHSPEC §7).
    nonisolated static func trashErrorText(for error: Error) -> String {
        let reason = (error as NSError).localizedFailureReason
        if let reason, !reason.isEmpty { return "Couldn't move to Trash: \(reason)" }
        return "Couldn't move to Trash"
    }
}
