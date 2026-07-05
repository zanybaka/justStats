import Foundation

/// Real Spotlight implementation of `CategoryScanning` (SCAN-001, TECHSPEC §4).
///
/// Runs one `NSMetadataQuery` per `FileCategory`, each given a single search scope:
/// Apps/Media scan the target volume (`searchScopes = [volumeURL]`), "Other" scans
/// only that volume's `<volume>/Users` subtree so it stays user-owned files. Each
/// query sums its result set's **on-disk (allocated) size** — the bytes the files
/// actually occupy — and the scanner delivers a partial `CategoryBreakdown` on the
/// main queue.
///
/// **On-disk sums (UX-011):** the per-item size is the allocated size
/// (`.totalFileAllocatedSizeKey`, matching Finder's "on disk"), resolved through the
/// shared `OnDiskSizing` helper (UX-010), *not* the logical `kMDItemFSSize`. Logical
/// size wildly overstates a sparse file: a `Docker.raw` typed `public.image` reports
/// ~215 GB logically while occupying ~3.25 GB on disk, which would inflate the "Media"
/// category by hundreds of gigabytes. Summing allocated size makes each category reflect
/// reclaimable disk. Because allocated ≤ logical for every file, the corrected sums are
/// smaller, so the residual `System = Total − Free − Apps − Media − Other`
/// (`StorageBreakdown.reconciled`) only gains slack and stays ≥ 0. The extra per-item
/// `stat` runs off-main on the run-loop thread and the whole breakdown is cached
/// (UX-002, 5-min TTL), so the added cost is infrequent. A file whose allocated size is
/// unreadable falls back to its logical size, so it is never dropped from its category.
///
/// **Threading (NFR4 — never on the main thread, never on a timer):**
/// `NSMetadataQuery` posts its `…DidFinishGathering` notification on the run loop
/// of the thread that called `start()`. To keep every bit of Spotlight work off
/// main, this scanner owns one long-lived background `Thread` running its own run
/// loop; all queries are started, observed, stopped, and released there. Only the
/// final aggregated `CategoryBreakdown` hops to the main queue.
///
/// **On-demand only:** nothing starts a scan except an explicit `scan(volumeURL:)`
/// call (popover open / Refresh). No timer, no polling.
///
/// **Cancellation & release:** each `scan` starts a new generation; a newer `scan`
/// or `cancel()` invalidates the prior one — its queries are `stop()`-ed, their
/// notification observers removed, and the query objects dropped so nothing leaks
/// or keeps gathering after the popover closes (SCAN-007 relies on this). A
/// superseded generation's result is never delivered.
///
/// **Availability:** an unindexed volume (`mdutil -i off`, or an external/network
/// drive Spotlight never indexed) returns zero items from every query without
/// erroring. When *no* category yields a single result the index is treated as
/// unusable and `.unavailable` is delivered, so SCAN-005 shows "Not indexed"
/// instead of a misleading all-zero bar (TECHSPEC §4 degraded state). The scanner
/// never throws and never blocks the caller.
final class SpotlightCategoryScanner: CategoryScanning {
    /// One category's running query plus its observer token, so the scanner can
    /// stop and unobserve exactly what it started.
    private struct ActiveQuery {
        let category: FileCategory
        let query: NSMetadataQuery
        let observer: NSObjectProtocol
    }

    /// All state below is confined to `stateQueue`. Grouped per generation so a
    /// superseded scan tears down cleanly.
    private final class Scan {
        let generation: UInt64
        let volumeURL: URL
        let deliver: (CategoryBreakdown) -> Void
        var active: [ActiveQuery] = []
        var results: [FileCategory: (bytes: Int64, count: Int)] = [:]

        init(generation: UInt64, volumeURL: URL, deliver: @escaping (CategoryBreakdown) -> Void) {
            self.generation = generation
            self.volumeURL = volumeURL
            self.deliver = deliver
        }
    }

    /// Serializes generation bookkeeping and the active-scan slot.
    private let stateQueue = DispatchQueue(label: QueueLabels.categoryScanState)
    /// The background run loop `NSMetadataQuery` notifications are delivered on.
    private let runLoopThread: MetadataQueryRunLoopExecuting
    private let deliverQueue: DispatchQueue
    /// Builds each per-category query. Injectable so lifecycle tests (SCAN-007) can
    /// supply a counting `NSMetadataQuery` subclass they retain and drive to
    /// "finished", verifying every started query is stopped and its observer removed
    /// across open/refresh/close cycles — without a real Spotlight index.
    private let makeQuery: () -> NSMetadataQuery
    /// Resolves each item's on-disk (allocated) size so category sums reflect what files
    /// actually occupy on disk, not their (possibly sparse) logical size (UX-011).
    /// Injectable behind the shared `OnDiskSizing` seam (UX-010) so tests supply canned
    /// sizes without touching the real filesystem; the default reads
    /// `.totalFileAllocatedSizeKey`.
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
    ///   - makeQuery: builds each category's `NSMetadataQuery`; the default is a plain
    ///     `NSMetadataQuery()`. Injectable only for lifecycle tests.
    ///   - onDiskSizing: resolves each item's on-disk (allocated) size for the category
    ///     sums (UX-011). Defaults to the real `OnDiskSizeResolver`; injectable so tests
    ///     supply canned sizes without touching the filesystem.
    init(
        runLoopThread: MetadataQueryRunLoopExecuting = MetadataQueryRunLoopThread(),
        deliverQueue: DispatchQueue = .main,
        makeQuery: @escaping () -> NSMetadataQuery = { NSMetadataQuery() },
        onDiskSizing: OnDiskSizing = OnDiskSizeResolver()
    ) {
        self.runLoopThread = runLoopThread
        self.deliverQueue = deliverQueue
        self.makeQuery = makeQuery
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

    // MARK: - CategoryScanning

    func scan(volumeURL: URL, onResult: @escaping (CategoryBreakdown) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if let previous = self.current {
                self.tearDown(previous)
                self.current = nil
            }
            self.generation &+= 1
            let scan = Scan(generation: self.generation, volumeURL: volumeURL, deliver: onResult)
            self.current = scan
            self.startQueries(for: scan)
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
    /// `finishGathering` follow-up that runs the aggregation and enqueues delivery) has
    /// finished. Test-only (SCAN-007): after a lifecycle test posts the "finished
    /// gathering" notification — which runs each observer synchronously and enqueues one
    /// `stateQueue.async` follow-up per query — this lets the test flush that follow-up
    /// with a `sync` barrier instead of polling a wall-clock expectation, so delivery is
    /// driven to completion independent of scheduler latency. Pair with
    /// `deliverQueue.sync {}` to also flush the delivery hop. Never called in production.
    func settleForTesting() {
        stateQueue.sync {}
    }
    #endif

    // MARK: - stateQueue internals

    /// Builds and starts one query per category on the run-loop thread. Queries are
    /// created here (on `stateQueue`) but must be started where their run loop
    /// lives, so `start()`/observer registration hops to `runLoopThread`.
    private func startQueries(for scan: Scan) {
        let generation = scan.generation
        for category in FileCategory.allCases {
            let query = makeQuery()
            query.predicate = NSPredicate(fromMetadataQueryString: category.predicateFormat)
            query.searchScopes = Self.searchScopes(for: category, volumeURL: scan.volumeURL)
            query.valueListAttributes = [] // we only need the aggregate, not per-item value lists
            let observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: nil // delivered on the posting (run-loop) thread
            ) { [weak self] _ in
                self?.finishGathering(category: category, query: query, generation: generation)
            }
            scan.active.append(ActiveQuery(category: category, query: query, observer: observer))
        }
        let queries = scan.active.map(\.query)
        runLoopThread.perform {
            for query in queries { query.start() }
        }
    }

    /// A single Spotlight search scope per category. Apps/Media scan the whole
    /// volume; "Other" scans only the volume's own `<volume>/Users` subtree so it
    /// stays user-owned documents/archives/code rather than every unclassified file
    /// (TECHSPEC §4).
    ///
    /// This is a *single* scope, not two: `NSMetadataQuery.searchScopes` is a UNION
    /// (an item matches if it lives under ANY listed scope), never an intersection —
    /// listing `[volumeURL, "/Users"]` would match every unclassified file on the
    /// volume OR anything under the boot volume's `/Users`, over-counting non-boot
    /// volumes and matching boot-volume files even for an unindexed external drive
    /// (defeating "Not indexed" detection). Restricting to the users subtree is done
    /// by choosing the subtree URL itself as the one scope: for the boot volume that
    /// is `/Users`; for a volume mounted at `/Volumes/USB` it is `/Volumes/USB/Users`
    /// — confined to that volume, so an unindexed drive correctly yields zero items.
    private static func searchScopes(for category: FileCategory, volumeURL: URL) -> [Any] {
        switch category {
        case .apps, .media:
            return [volumeURL]
        case .other:
            return [volumeURL.appendingPathComponent("Users", isDirectory: true)]
        }
    }

    /// A category query finished gathering (on the run-loop thread). Aggregates its
    /// result set, records it, and — once every category of this generation is in —
    /// delivers the combined breakdown. Stale-generation notifications are dropped.
    private func finishGathering(category: FileCategory, query: NSMetadataQuery, generation: UInt64) {
        // NFR4 invariant: Spotlight aggregation never runs on the main thread.
        dispatchPrecondition(condition: .notOnQueue(.main))
        query.disableUpdates()
        let (bytes, count) = aggregate(query)
        query.stop()
        stateQueue.async { [weak self] in
            guard let self, let scan = self.current, scan.generation == generation else { return }
            scan.results[category] = (bytes: bytes, count: count)
            guard scan.results.count == FileCategory.allCases.count else { return }
            self.completeAndDeliver(scan)
        }
    }

    /// All categories are in for `scan`: build the breakdown, deliver it on the
    /// deliver queue (re-checking the generation at the last moment), and release
    /// the scan's queries. Runs on `stateQueue`.
    private func completeAndDeliver(_ scan: Scan) {
        // The availability decision (all-zero results → not indexed) lives in the
        // pure `CategoryBreakdown.from`, which is unit-tested without real Spotlight.
        func result(_ category: FileCategory) -> CategoryBreakdown.CategoryResult {
            let entry = scan.results[category]
            return CategoryBreakdown.CategoryResult(bytes: entry?.bytes ?? 0, itemCount: entry?.count ?? 0)
        }
        let breakdown = CategoryBreakdown.from(
            apps: result(.apps),
            media: result(.media),
            other: result(.other)
        )
        tearDown(scan)
        if current?.generation == scan.generation { current = nil }
        let generation = scan.generation
        let deliver = scan.deliver
        deliverQueue.async { [weak self] in
            guard let self else { return }
            guard self.stateQueue.sync(execute: { self.generation == generation }) else { return }
            deliver(breakdown)
        }
    }

    /// Stops every live query in `scan`, removes its observer, and drops the query
    /// objects — nothing keeps gathering or leaks after this (SCAN-007). Runs on
    /// `stateQueue`; the `stop()` hops to the run-loop thread the queries live on.
    private func tearDown(_ scan: Scan) {
        let active = scan.active
        scan.active.removeAll()
        for entry in active {
            NotificationCenter.default.removeObserver(entry.observer)
        }
        runLoopThread.perform {
            for entry in active { entry.query.stop() }
        }
    }

    /// Upper bound on the number of per-file on-disk (`stat`) syscalls one category
    /// aggregation performs, mirroring the largest-files scanner's `maxCandidateWindow`
    /// so category work stays bounded regardless of index size (NFR4). A cold scan of a
    /// boot volume can match hundreds of thousands of files (`~/Library` caches,
    /// `node_modules`, git object stores); stat'ing every one on the `.utility` run-loop
    /// thread is the unbounded I/O NFR4 forbids. Instead only the largest-by-logical
    /// items — where a sparse file's over-reporting is concentrated and matters (a 2 MB
    /// file cannot overstate by gigabytes) — get an allocated-size `stat`; every smaller
    /// item contributes its already-in-memory logical size with zero I/O.
    private static let maxOnDiskStats = 4_096

    /// Sums each item's **on-disk (allocated) size** across a finished query's results
    /// (UX-011), with a bounded number of filesystem stats (NFR4). Logical sizes come from
    /// the already-indexed `kMDItemFSSize` (zero I/O). The `maxOnDiskStats` largest-by-
    /// logical items get an allocated-size read through the injected `OnDiskSizing` helper
    /// (UX-010) — that is where sparse-file over-reporting lives and where correcting to
    /// allocated size matters; every remaining (smaller) item sums its logical size, whose
    /// gap from allocated is at most a few KB per file. When an allocated read fails
    /// (permissions, a vanished file, a volume that doesn't report the key, or a missing
    /// path) it falls back to that item's logical size so the file still contributes rather
    /// than being dropped. An item with neither a usable allocated nor logical size
    /// contributes zero. Returns the summed bytes and the full result count (the count —
    /// not the bytes — feeds the availability heuristic, so this bounding does not change
    /// availability).
    ///
    /// Runs off-main on the run-loop thread (its caller asserts `.notOnQueue(.main)`), so
    /// the per-item `stat` never touches main; the whole breakdown is cached (UX-002), so
    /// this bounded cost is paid at most once per volume per 5-minute TTL.
    private func aggregate(_ query: NSMetadataQuery) -> (bytes: Int64, count: Int) {
        let count = query.resultCount
        // Read the in-memory logical size and path for every item (no filesystem I/O),
        // keeping the index so the stat budget can be spent on the largest items.
        var items: [(index: Int, logical: Int64, path: String?)] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem else { continue }
            let logical = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
            let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            items.append((index: index, logical: logical, path: path))
        }
        // Spend the bounded stat budget on the largest-by-logical items, where a sparse
        // file's over-reporting is concentrated; smaller items keep their logical size.
        let statBudget = min(items.count, Self.maxOnDiskStats)
        if statBudget < items.count {
            items.sort { $0.logical > $1.logical }
        }
        var total: Int64 = 0
        for (offset, entry) in items.enumerated() {
            // Sum the on-disk (allocated) size for items within the budget, falling back
            // to logical when the read is unavailable; beyond the budget, sum logical.
            var bytes = entry.logical
            if offset < statBudget, let path = entry.path,
               let onDisk = onDiskSizing.onDiskSizeBytes(of: URL(fileURLWithPath: path)) {
                bytes = onDisk
            }
            total &+= bytes
        }
        return (bytes: total, count: count)
    }
}

/// The small surface `SpotlightCategoryScanner`/`SpotlightLargestFilesScanner` need
/// from the query run-loop thread: "run this block where the query run loop lives"
/// (`perform`) and "let that run loop exit" (`stop`). Depending on this protocol
/// rather than the concrete thread lets tests inject a synchronous stub — so the
/// query start/stop/observer teardown paths (SCAN-007) are exercised without spinning
/// up a real Spotlight thread or touching the real Spotlight index.
protocol MetadataQueryRunLoopExecuting: AnyObject {
    /// Runs `block` on the query run-loop thread. Asynchronous: the caller never
    /// blocks on Spotlight work.
    func perform(_ block: @escaping () -> Void)
    /// Stops the run loop and lets its thread exit. Idempotent.
    func stop()
}

/// A dedicated background thread that owns a live run loop for `NSMetadataQuery` to
/// post its gathering notifications on — so no Spotlight work ever touches the main
/// thread (NFR4). Long-lived: created once per scanner, torn down with it.
///
/// The production `MetadataQueryRunLoopExecuting`: `SpotlightCategoryScanner` depends
/// only on that protocol, so tests can substitute a plain synchronous stub instead of
/// spinning up a real thread.
final class MetadataQueryRunLoopThread: MetadataQueryRunLoopExecuting {
    private let thread: Thread
    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    init() {
        var loopBox: CFRunLoop?
        let ready = self.ready
        let thread = Thread {
            loopBox = CFRunLoopGetCurrent()
            ready.signal()
            // A source keeps the run loop alive with no input; without it
            // `CFRunLoopRun()` returns immediately (no sources → finished).
            let source = CFRunLoopSourceCreate(nil, 0, &Self.noopSourceContext)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = QueueLabels.categoryScanRunLoop
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
        ready.wait()
        runLoop = loopBox
    }

    /// Runs `block` on the query run-loop thread. Async: the caller (usually
    /// `stateQueue`) never blocks on Spotlight work.
    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Stops the run loop and lets the thread exit. Idempotent.
    func stop() {
        guard let runLoop else { return }
        self.runLoop = nil
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Do-nothing run-loop source context — its only job is to keep the run loop
    /// from finishing when it has no other input sources.
    private static var noopSourceContext = CFRunLoopSourceContext()
}
