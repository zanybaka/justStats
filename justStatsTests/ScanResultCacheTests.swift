import XCTest
@testable import justStats

/// A `MonotonicClock` the test drives by hand, so TTL freshness is deterministic
/// without sleeping. Time only moves when the test advances it.
final class FakeMonotonicClock: MonotonicClock {
    private var current: TimeInterval
    init(_ start: TimeInterval = 1_000) { current = start }
    func now() -> TimeInterval { current }
    /// Moves the clock forward by `seconds`.
    func advance(_ seconds: TimeInterval) { current += seconds }
}

@MainActor
final class ScanResultCacheTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private func breakdown() -> CategoryBreakdown {
        .available(apps: 10, media: 20, other: 30)
    }

    private func largestFiles() -> LargestFilesResult {
        .available([LargestFile(displayName: "big.zip", sizeBytes: 999, url: url("/Users/me/big.zip"))])
    }

    // MARK: - Freshness within TTL

    func testCategoriesFreshWithinTTLAreReturned() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let volume = url("/")

        cache.storeCategories(breakdown(), forVolumeAt: volume)
        clock.advance(89) // still within the 90s window

        XCTAssertEqual(cache.categories(forVolumeAt: volume), breakdown())
    }

    func testLargestFilesFreshWithinTTLAreReturned() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let volume = url("/")

        cache.storeLargestFiles(largestFiles(), forVolumeAt: volume)
        clock.advance(89)

        XCTAssertEqual(cache.largestFiles(forVolumeAt: volume), largestFiles())
    }

    // MARK: - Staleness past TTL

    func testCategoriesPastTTLAreIgnored() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let volume = url("/")

        cache.storeCategories(breakdown(), forVolumeAt: volume)
        clock.advance(90) // exactly at the boundary → stale (strict `<`)

        XCTAssertNil(cache.categories(forVolumeAt: volume),
                     "an entry at/after the TTL boundary is stale and must be ignored")
    }

    func testLargestFilesPastTTLAreIgnored() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let volume = url("/")

        cache.storeLargestFiles(largestFiles(), forVolumeAt: volume)
        clock.advance(120)

        XCTAssertNil(cache.largestFiles(forVolumeAt: volume))
    }

    // MARK: - Absence

    func testAbsentEntriesReturnNil() {
        let cache = ScanResultCache(ttl: 90, clock: FakeMonotonicClock())
        XCTAssertNil(cache.categories(forVolumeAt: url("/nope")))
        XCTAssertNil(cache.largestFiles(forVolumeAt: url("/nope")))
    }

    // MARK: - Per-URL isolation

    func testEntriesAreKeyedPerVolumeURL() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let boot = url("/")
        let usb = url("/Volumes/USB")

        cache.storeCategories(.available(apps: 1, media: 2, other: 3), forVolumeAt: boot)
        cache.storeCategories(.unavailable, forVolumeAt: usb)

        XCTAssertEqual(cache.categories(forVolumeAt: boot), .available(apps: 1, media: 2, other: 3))
        XCTAssertEqual(cache.categories(forVolumeAt: usb), .unavailable)
    }

    // MARK: - Independent halves

    func testCategoryAndLargestFilesHalvesExpireIndependently() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let volume = url("/")

        cache.storeCategories(breakdown(), forVolumeAt: volume) // t=0
        clock.advance(60)
        cache.storeLargestFiles(largestFiles(), forVolumeAt: volume) // t=60
        clock.advance(40) // categories at 100s (stale), largest files at 40s (fresh)

        XCTAssertNil(cache.categories(forVolumeAt: volume),
                     "the older half is stale")
        XCTAssertEqual(cache.largestFiles(forVolumeAt: volume), largestFiles(),
                       "the newer half is still fresh — halves expire independently")
    }

    // MARK: - Overwrite refreshes the timestamp

    func testStoringAgainRefreshesFreshness() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 90, clock: clock)
        let volume = url("/")

        cache.storeCategories(.available(apps: 1, media: 1, other: 1), forVolumeAt: volume)
        clock.advance(80)
        // Re-store just before expiry: the timestamp resets, so the new value is fresh
        // for another full TTL.
        cache.storeCategories(breakdown(), forVolumeAt: volume)
        clock.advance(80) // 160s since the first write, but only 80s since the second

        XCTAssertEqual(cache.categories(forVolumeAt: volume), breakdown(),
                       "re-storing resets freshness to the latest write")
    }

    // MARK: - Default TTL is the 5-minute thrift window

    /// The default freshness window is 5 minutes (UX-002 thrift model): a reopen within
    /// 300s paints from cache and does no Spotlight work.
    func testDefaultTTLIsFiveMinutes() {
        XCTAssertEqual(ScanResultCache.defaultTTL, 300)
    }

    /// An entry is fresh right up to — but not including — the 300s boundary, using the
    /// production default TTL and an injected clock (no sleeping). Just before 300s the
    /// entry is served from cache; at exactly 300s it is stale (strict `<`).
    func test300sTTLBoundary() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: ScanResultCache.defaultTTL, clock: clock)
        let volume = url("/")

        cache.storeCategories(breakdown(), forVolumeAt: volume)
        cache.storeLargestFiles(largestFiles(), forVolumeAt: volume)

        clock.advance(299) // one second inside the 5-minute window → still fresh
        XCTAssertEqual(cache.categories(forVolumeAt: volume), breakdown(),
                       "an entry 299s old is within the 300s window and served from cache")
        XCTAssertEqual(cache.largestFiles(forVolumeAt: volume), largestFiles())

        clock.advance(1) // now exactly 300s → at the boundary, stale (strict `<`)
        XCTAssertNil(cache.categories(forVolumeAt: volume),
                     "an entry at the 300s boundary is stale and triggers a fresh scan")
        XCTAssertNil(cache.largestFiles(forVolumeAt: volume))
    }

    // MARK: - Non-positive TTL disables the fast path

    func testNonPositiveTTLIsAlwaysStale() {
        let clock = FakeMonotonicClock()
        let cache = ScanResultCache(ttl: 0, clock: clock)
        let volume = url("/")

        cache.storeCategories(breakdown(), forVolumeAt: volume)
        cache.storeLargestFiles(largestFiles(), forVolumeAt: volume)
        // No time advance at all — still stale, because TTL 0 disables the fast path.

        XCTAssertNil(cache.categories(forVolumeAt: volume))
        XCTAssertNil(cache.largestFiles(forVolumeAt: volume))
    }
}
