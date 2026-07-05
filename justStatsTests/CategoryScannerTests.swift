import XCTest
@testable import justStats

/// SCAN-001: mock-based tests of the `CategoryBreakdown` model, the availability
/// heuristic (`CategoryBreakdown.from`), the category taxonomy predicates, and the
/// `CategoryScanning` seam contract. No real Spotlight (`NSMetadataQuery`) runs
/// here — the aggregation/availability logic is exercised as pure functions.
final class CategoryScannerTests: XCTestCase {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - CategoryBreakdown model

    func testAvailableFactoryFlagsIndexAvailableAndCarriesBytes() {
        let breakdown = CategoryBreakdown.available(apps: 10, media: 20, other: 30)
        XCTAssertTrue(breakdown.isIndexAvailable)
        XCTAssertEqual(breakdown.appsBytes, 10)
        XCTAssertEqual(breakdown.mediaBytes, 20)
        XCTAssertEqual(breakdown.otherBytes, 30)
    }

    func testUnavailableIsZeroedAndFlaggedUnavailable() {
        let breakdown = CategoryBreakdown.unavailable
        XCTAssertFalse(breakdown.isIndexAvailable)
        XCTAssertEqual(breakdown.appsBytes, 0)
        XCTAssertEqual(breakdown.mediaBytes, 0)
        XCTAssertEqual(breakdown.otherBytes, 0)
    }

    // MARK: - Availability heuristic (CategoryBreakdown.from)

    func testFromWithMatchedItemsProducesAvailableBreakdownSummingPerCategory() {
        let breakdown = CategoryBreakdown.from(
            apps: .init(bytes: 5_000, itemCount: 3),
            media: .init(bytes: 40_000, itemCount: 120),
            other: .init(bytes: 12_000, itemCount: 60)
        )
        XCTAssertEqual(breakdown, .available(apps: 5_000, media: 40_000, other: 12_000))
        XCTAssertTrue(breakdown.isIndexAvailable)
    }

    /// TECHSPEC §4 degraded state: no category matched a single item → the index is
    /// unusable, so the breakdown is `.unavailable` (SCAN-005 renders "Not indexed"
    /// from this), never an all-zero "available" bar.
    func testFromWithNoMatchedItemsIsUnavailable() {
        let breakdown = CategoryBreakdown.from(
            apps: .init(bytes: 0, itemCount: 0),
            media: .init(bytes: 0, itemCount: 0),
            other: .init(bytes: 0, itemCount: 0)
        )
        XCTAssertEqual(breakdown, .unavailable)
        XCTAssertFalse(breakdown.isIndexAvailable)
    }

    /// A single matched item anywhere means the index is usable — even if that
    /// category's summed size is zero (an empty app bundle still proves indexing).
    func testFromWithItemsButZeroBytesIsAvailable() {
        let breakdown = CategoryBreakdown.from(
            apps: .init(bytes: 0, itemCount: 1),
            media: .init(bytes: 0, itemCount: 0),
            other: .init(bytes: 0, itemCount: 0)
        )
        XCTAssertTrue(breakdown.isIndexAvailable)
        XCTAssertEqual(breakdown, .available(apps: 0, media: 0, other: 0))
    }

    /// Availability keys off item *count*, not bytes: a defensively-negative count
    /// (never produced by a real query) clamps to zero and cannot fake availability.
    func testNegativeItemCountClampsAndDoesNotFakeAvailability() {
        XCTAssertEqual(CategoryBreakdown.CategoryResult(bytes: 99, itemCount: -5).itemCount, 0)
        let breakdown = CategoryBreakdown.from(
            apps: .init(bytes: 99, itemCount: -5),
            media: .init(bytes: 0, itemCount: 0),
            other: .init(bytes: 0, itemCount: 0)
        )
        XCTAssertEqual(breakdown, .unavailable)
    }

    // MARK: - Category taxonomy (TECHSPEC §4 predicates)

    func testAppsPredicateMatchesApplicationBundleContentType() {
        XCTAssertEqual(
            FileCategory.apps.predicateFormat,
            "kMDItemContentType == 'com.apple.application-bundle'"
        )
    }

    func testMediaPredicateCoversImageMovieAndAudioSubtrees() {
        let format = FileCategory.media.predicateFormat
        XCTAssertTrue(format.contains("kMDItemContentTypeTree == 'public.image'"))
        XCTAssertTrue(format.contains("kMDItemContentTypeTree == 'public.movie'"))
        XCTAssertTrue(format.contains("kMDItemContentTypeTree == 'public.audio'"))
    }

    func testOtherPredicateExcludesAppsAndMedia() {
        let format = FileCategory.other.predicateFormat
        XCTAssertTrue(format.contains("kMDItemContentType != 'com.apple.application-bundle'"))
        XCTAssertTrue(format.contains("kMDItemContentTypeTree != 'public.image'"))
        XCTAssertTrue(format.contains("kMDItemContentTypeTree != 'public.movie'"))
        XCTAssertTrue(format.contains("kMDItemContentTypeTree != 'public.audio'"))
    }

    /// Every taxonomy predicate must be a valid `NSMetadataQuery` predicate string —
    /// guards against a typo silently producing a query that matches nothing (which
    /// would masquerade as an "unindexed" volume).
    func testEveryCategoryPredicateParsesAsAMetadataQueryPredicate() {
        for category in FileCategory.allCases {
            XCTAssertNotNil(
                NSPredicate(fromMetadataQueryString: category.predicateFormat),
                "\(category) predicate must parse: \(category.predicateFormat)"
            )
        }
    }

    // MARK: - CategoryScanning seam contract (via mock)

    func testSeamDeliversBreakdownOnceIntoLatestScan() {
        let scanner = MockCategoryScanner()
        var delivered: [CategoryBreakdown] = []
        scanner.scan(volumeURL: url("/")) { delivered.append($0) }

        scanner.deliver(.available(apps: 1, media: 2, other: 3))

        XCTAssertEqual(scanner.scanRequests, [url("/")])
        XCTAssertEqual(delivered, [.available(apps: 1, media: 2, other: 3)])
    }

    func testSeamCancelDropsPendingDelivery() {
        let scanner = MockCategoryScanner()
        var delivered: [CategoryBreakdown] = []
        scanner.scan(volumeURL: url("/")) { delivered.append($0) }

        scanner.cancel()
        scanner.deliver(.available(apps: 1, media: 2, other: 3))

        XCTAssertEqual(scanner.cancelCount, 1)
        XCTAssertTrue(delivered.isEmpty, "a cancelled scan must not deliver its result")
    }

    // MARK: - On-disk (allocated) category sums (UX-011)

    /// The real scanner must sum each item's ON-DISK (allocated) size, not the logical
    /// `kMDItemFSSize`. A Media category holding one sparse file with a huge logical size
    /// (a `.raw` typed `public.image`: ~215 GB logical / ~3.25 GB on disk) must sum to the
    /// ALLOCATED bytes, so the category reflects reclaimable disk rather than the inflated
    /// logical figure. The item count still marks the index available.
    func testCategorySumsAllocatedNotLogical() {
        let mediaLogical: Int64 = 215_000_000_000 // sparse .raw over-reports this
        let mediaOnDisk: Int64 = 3_250_000_000     // what it actually occupies
        let items: [FileCategory: [FakeMetadataItem]] = [
            .apps: [FakeMetadataItem(size: 500_000_000, path: "/Applications/App.app")],
            .media: [FakeMetadataItem(size: mediaLogical, path: "/Users/me/Docker.raw")],
            .other: [FakeMetadataItem(size: 12_000, path: "/Users/me/notes.txt")],
        ]
        let onDisk = MockOnDiskSizing(sizes: [
            fileURL("/Applications/App.app"): 500_000_000, // dense: on disk == logical
            fileURL("/Users/me/Docker.raw"): mediaOnDisk,  // sparse: small on disk
            fileURL("/Users/me/notes.txt"): 8_000,         // dense-ish, allocated < logical
        ])

        let breakdown = runRealCategoryScan(items: items, onDiskSizing: onDisk)

        XCTAssertTrue(breakdown.isIndexAvailable)
        // Media sums the ALLOCATED 3.25 GB, not the sparse 215 GB logical size.
        XCTAssertEqual(breakdown.mediaBytes, mediaOnDisk,
                       "media must sum on-disk (allocated) size, not the inflated logical size")
        XCTAssertEqual(breakdown.appsBytes, 500_000_000)
        XCTAssertEqual(breakdown.otherBytes, 8_000)
    }

    /// The corrected (smaller) allocated sums must still satisfy the residual-System
    /// invariant: `System = Total − Free − Apps − Media − Other ≥ 0` and the five segments
    /// sum to `Total` exactly. With allocated ≤ logical the residual only gains slack, so
    /// a case that would overcount on logical size now fits with a positive System.
    func testResidualSystemMathHoldsWithAllocatedSums() {
        let total: Int64 = 500_000_000_000
        let free: Int64 = 200_000_000_000
        // Media's LOGICAL size (215 GB) plus the others would exceed used (300 GB) and
        // force System to clamp to 0 with scaled-down categories. Its ALLOCATED size
        // (3.25 GB) leaves System comfortably positive.
        let items: [FileCategory: [FakeMetadataItem]] = [
            .apps: [FakeMetadataItem(size: 20_000_000_000, path: "/Applications/Big.app")],
            .media: [FakeMetadataItem(size: 215_000_000_000, path: "/Users/me/Docker.raw")],
            .other: [FakeMetadataItem(size: 10_000_000_000, path: "/Users/me/archive.zip")],
        ]
        let onDisk = MockOnDiskSizing(sizes: [
            fileURL("/Applications/Big.app"): 20_000_000_000,
            fileURL("/Users/me/Docker.raw"): 3_250_000_000,
            fileURL("/Users/me/archive.zip"): 10_000_000_000,
        ])

        let breakdown = runRealCategoryScan(items: items, onDiskSizing: onDisk)
        let storage = StorageBreakdown.reconciled(categories: breakdown, totalBytes: total, freeBytes: free)

        // System is a positive residual (used − allocated categories), never clamped/scaled.
        let categorySum = storage.appsBytes + storage.mediaBytes + storage.otherBytes
        XCTAssertEqual(storage.appsBytes, 20_000_000_000)
        XCTAssertEqual(storage.mediaBytes, 3_250_000_000, "media held its allocated size, unscaled")
        XCTAssertEqual(storage.otherBytes, 10_000_000_000)
        XCTAssertGreaterThan(storage.systemBytes, 0, "residual System stays positive with allocated sums")
        // Every segment ≥ 0 and the five sum to Total exactly.
        for segment in [storage.systemBytes, storage.appsBytes, storage.mediaBytes,
                        storage.otherBytes, storage.freeBytes] {
            XCTAssertGreaterThanOrEqual(segment, 0)
        }
        XCTAssertEqual(storage.systemBytes + categorySum + storage.freeBytes, total,
                       "the five segments sum to Total exactly")
    }

    /// An item whose allocated size is unreadable (helper returns `nil`) falls back to its
    /// logical size, so it still contributes to its category rather than being dropped.
    func testCategoryFallsBackToLogicalWhenAllocatedIsNil() {
        let items: [FileCategory: [FakeMetadataItem]] = [
            .apps: [],
            .media: [],
            .other: [FakeMetadataItem(size: 9_000, path: "/Users/me/unreadable.bin")],
        ]
        // No allocated size for the file → the map returns nil → logical fallback.
        let breakdown = runRealCategoryScan(items: items, onDiskSizing: MockOnDiskSizing(sizes: [:]))

        XCTAssertTrue(breakdown.isIndexAvailable)
        XCTAssertEqual(breakdown.otherBytes, 9_000, "unreadable allocated size falls back to logical")
    }

    /// Availability keys off item *count*, not summed bytes, so switching the sum from
    /// logical to allocated must not change it: a volume with matched items stays
    /// available, and a volume with zero items across every category stays unavailable
    /// (the "Not indexed" degraded state), regardless of on-disk sizes.
    func testAvailabilityUnchangedBySummingAllocated() {
        // Zero items everywhere → unavailable, exactly as before.
        let empty = runRealCategoryScan(
            items: [.apps: [], .media: [], .other: []],
            onDiskSizing: MockOnDiskSizing(sizes: [:])
        )
        XCTAssertEqual(empty, .unavailable)
        XCTAssertFalse(empty.isIndexAvailable)

        // One matched item → available, even with a zero allocated size.
        let items: [FileCategory: [FakeMetadataItem]] = [
            .apps: [FakeMetadataItem(size: 0, path: "/Applications/Empty.app")],
            .media: [],
            .other: [],
        ]
        let onDisk = MockOnDiskSizing(sizes: [fileURL("/Applications/Empty.app"): 0])
        let available = runRealCategoryScan(items: items, onDiskSizing: onDisk)
        XCTAssertTrue(available.isIndexAvailable)
        XCTAssertEqual(available, .available(apps: 0, media: 0, other: 0))
    }

    /// The aggregate must bound its filesystem stats (NFR4): a cold scan of a large home
    /// directory can match hundreds of thousands of files, and stat'ing every one on the
    /// run-loop thread is the unbounded I/O the sibling largest-files path already caps. A
    /// query with far more items than the stat budget must issue at most `maxOnDiskStats`
    /// on-disk reads, spend them on the LARGEST-by-logical items (where sparse over-
    /// reporting matters), and sum the remaining items by their logical size — so the total
    /// is still correct and the sparse-giant correction still lands.
    func testCategoryAggregateBoundsOnDiskStats() {
        let cap = 4_096
        let itemCount = cap + 500
        // One sparse giant that MUST be stat'd (largest logical) and corrected down, plus
        // many small dense files. Small files' allocated ≈ logical, so summing them by
        // logical is correct; the giant is the one that would inflate the category.
        var media: [FakeMetadataItem] = [
            FakeMetadataItem(size: 215_000_000_000, path: "/Users/me/Docker.raw") // sparse giant
        ]
        for i in 0..<(itemCount - 1) {
            media.append(FakeMetadataItem(size: 1_000, path: "/Users/me/small-\(i).bin"))
        }
        // On-disk map: the giant reads far smaller than logical; small files read == logical.
        var sizes: [URL: Int64] = [fileURL("/Users/me/Docker.raw"): 3_250_000_000]
        for i in 0..<(itemCount - 1) {
            sizes[fileURL("/Users/me/small-\(i).bin")] = 1_000
        }
        let counting = CountingOnDiskSizing(sizes: sizes)
        let items: [FileCategory: [FakeMetadataItem]] = [.apps: [], .media: media, .other: []]

        let breakdown = runRealCategoryScan(items: items, onDiskSizing: counting)

        XCTAssertTrue(breakdown.isIndexAvailable)
        // At most `maxOnDiskStats` filesystem reads, regardless of the item count.
        XCTAssertLessThanOrEqual(counting.callCount, cap,
                                 "on-disk stats must be bounded by maxOnDiskStats")
        // The sparse giant (largest logical) was among the stat'd items, so it contributes
        // its ALLOCATED 3.25 GB, not the 215 GB logical size. The remaining small files
        // contribute 1 KB each. Total = 3.25 GB + (itemCount - 1) × 1 KB.
        let expected: Int64 = 3_250_000_000 + Int64(itemCount - 1) * 1_000
        XCTAssertEqual(breakdown.mediaBytes, expected,
                       "the sparse giant is corrected to on-disk; the small tail sums by logical")
    }

    // MARK: - On-disk category-sum test helpers

    private func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path) }

    /// `OnDiskSizing` double that counts how many times it is asked to stat a file, so a
    /// test can assert the aggregate's per-file I/O stays within `maxOnDiskStats`. Thread-
    /// safe because the real aggregate runs on the off-main run-loop thread.
    private final class CountingOnDiskSizing: OnDiskSizing, @unchecked Sendable {
        private let sizes: [URL: Int64]
        private let lock = NSLock()
        private var count = 0
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }

        init(sizes: [URL: Int64]) { self.sizes = sizes }

        func onDiskSizeBytes(of url: URL) -> Int64? {
            lock.lock(); count += 1; lock.unlock()
            return sizes[url]
        }
    }

    /// A fake `NSMetadataItem` returning canned attribute values — no real Spotlight.
    /// Only the attributes the scanner's `aggregate` reads (`FSSize`, `Path`) are
    /// supported.
    private final class FakeMetadataItem: NSMetadataItem, @unchecked Sendable {
        private let cannedAttributes: [String: Any]

        init(size: Int64, path: String) {
            cannedAttributes = [
                NSMetadataItemFSSizeKey: NSNumber(value: size),
                NSMetadataItemPathKey: path,
            ]
            super.init()
        }

        override func value(forAttribute key: String) -> Any? { cannedAttributes[key] }
    }

    /// A fake `NSMetadataQuery` serving one category's canned items. `start()` posts the
    /// finish notification off-main so the scanner's `.notOnQueue(.main)` observer runs the
    /// real aggregate path on a background thread.
    private final class FakeCategoryQuery: NSMetadataQuery, @unchecked Sendable {
        let items: [NSMetadataItem]

        init(items: [NSMetadataItem]) {
            self.items = items
            super.init()
        }

        override var resultCount: Int { items.count }
        override func result(at index: Int) -> Any { items[index] }
        override func disableUpdates() {}
        override func enableUpdates() {}

        override func start() -> Bool {
            DispatchQueue.global(qos: .userInitiated).async {
                NotificationCenter.default.post(name: .NSMetadataQueryDidFinishGathering, object: self)
            }
            return true
        }

        override func stop() {}
    }

    /// Synchronous run-loop executor stub: runs `perform` blocks on a private off-main
    /// serial queue so the scanner's `.notOnQueue(.main)` preconditions hold.
    private final class SyncRunLoopExecutor: MetadataQueryRunLoopExecuting, @unchecked Sendable {
        private let queue = DispatchQueue(label: "test.category-ondisk-runloop", qos: .userInitiated)
        func perform(_ block: @escaping () -> Void) { queue.async(execute: block) }
        func stop() {}
    }

    /// `OnDiskSizing` double returning canned allocated sizes keyed by URL; a URL absent
    /// from the map returns `nil` (the logical-fallback path). Never touches the
    /// filesystem.
    private struct MockOnDiskSizing: OnDiskSizing {
        let sizes: [URL: Int64]
        func onDiskSizeBytes(of url: URL) -> Int64? { sizes[url] }
    }

    /// Drives a *real* `SpotlightCategoryScanner` end-to-end. The scanner runs one query
    /// per `FileCategory.allCases` (order `[.apps, .media, .other]`); the injected factory
    /// hands out a `FakeCategoryQuery` carrying that category's canned items, so each
    /// category's `aggregate` runs against known items and the delivered breakdown reflects
    /// the on-disk sums. Blocks on an expectation for main-queue-style delivery.
    private func runRealCategoryScan(
        items: [FileCategory: [FakeMetadataItem]],
        onDiskSizing: OnDiskSizing
    ) -> CategoryBreakdown {
        let deliverQueue = DispatchQueue(label: "test.category-ondisk-deliver")
        let ordered = FileCategory.allCases.map { items[$0] ?? [] }
        let nextIndex = NSLock()
        var index = 0
        let scanner = SpotlightCategoryScanner(
            runLoopThread: SyncRunLoopExecutor(),
            deliverQueue: deliverQueue,
            makeQuery: {
                nextIndex.lock()
                defer { nextIndex.unlock() }
                let items = index < ordered.count ? ordered[index] : []
                index += 1
                return FakeCategoryQuery(items: items)
            },
            onDiskSizing: onDiskSizing
        )
        let delivered = expectation(description: "breakdown delivered")
        var captured: CategoryBreakdown?
        scanner.scan(volumeURL: url("/")) { breakdown in
            captured = breakdown
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        return captured ?? .unavailable
    }
}
