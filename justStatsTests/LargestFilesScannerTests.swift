import XCTest
@testable import justStats

// The `LargestFilesScanning` test double (`MockLargestFilesScanner`) used here now
// lives in shared `TestSupport.swift`: ACT-001 made `VolumeListViewModel.load()` start
// a largest-files scan, so every view-model-building test needs the same inert double to
// stay hermetic, and a single shared definition avoids a duplicate symbol in the target.

/// SCAN-003: mock-based tests of the `LargestFile`/`LargestFilesResult` models, the
/// pure sort/truncation/availability logic (`LargestFilesResult.ranked`), and the
/// `LargestFilesScanning` seam contract. No real Spotlight (`NSMetadataQuery`) runs
/// here — the ranking logic is exercised as a pure function.
final class LargestFilesScannerTests: XCTestCase {
    private func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    private func volumeURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private func file(_ name: String, _ size: Int64, path: String? = nil) -> LargestFile {
        LargestFile(displayName: name, sizeBytes: size, url: fileURL(path ?? "/Users/me/\(name)"))
    }

    // MARK: - LargestFile model

    func testFileCarriesNameSizeAndURLWithDerivedPath() {
        let f = LargestFile(displayName: "archive.zip", sizeBytes: 1_234, url: fileURL("/Users/me/archive.zip"))
        XCTAssertEqual(f.displayName, "archive.zip")
        XCTAssertEqual(f.sizeBytes, 1_234)
        XCTAssertEqual(f.url, fileURL("/Users/me/archive.zip"))
        XCTAssertEqual(f.path, "/Users/me/archive.zip")
    }

    /// Negative sizes (never produced by a real query) clamp to zero so a corrupt
    /// entry can't sort to the top of the list.
    func testNegativeSizeClampsToZero() {
        let f = LargestFile(displayName: "weird.bin", sizeBytes: -99, url: fileURL("/tmp/weird.bin"))
        XCTAssertEqual(f.sizeBytes, 0)
    }

    /// An empty display name falls back to the URL's last path component so a row is
    /// never blank.
    func testEmptyDisplayNameFallsBackToURLLastComponent() {
        let f = LargestFile(displayName: "", sizeBytes: 10, url: fileURL("/Users/me/photo.heic"))
        XCTAssertEqual(f.displayName, "photo.heic")
    }

    // MARK: - LargestFilesResult model / factories

    func testUnavailableIsEmptyAndFlaggedUnavailable() {
        let result = LargestFilesResult.unavailable
        XCTAssertFalse(result.isIndexAvailable)
        XCTAssertTrue(result.files.isEmpty)
    }

    func testAvailableFactoryFlagsIndexAvailableAndCarriesFiles() {
        let files = [file("a", 10), file("b", 5)]
        let result = LargestFilesResult.available(files)
        XCTAssertTrue(result.isIndexAvailable)
        XCTAssertEqual(result.files, files)
    }

    func testDefaultLimitIsWithinPRDRange() {
        // PRD FR7: "top N, e.g. 10–20".
        XCTAssertGreaterThanOrEqual(LargestFilesResult.defaultLimit, 10)
        XCTAssertLessThanOrEqual(LargestFilesResult.defaultLimit, 20)
    }

    // MARK: - Ranking: sort by size descending

    func testRankedSortsBySizeDescending() {
        let result = LargestFilesResult.ranked(
            from: [file("small", 100), file("huge", 9_000), file("mid", 500)],
            matchedItemCount: 3
        )
        XCTAssertTrue(result.isIndexAvailable)
        XCTAssertEqual(result.files.map(\.displayName), ["huge", "mid", "small"])
        XCTAssertEqual(result.files.map(\.sizeBytes), [9_000, 500, 100])
    }

    /// Ties on size break deterministically by name then path so the order never
    /// depends on Spotlight's (unspecified) result order.
    func testRankedBreaksSizeTiesByNameThenPath() {
        let result = LargestFilesResult.ranked(
            from: [
                file("beta", 500, path: "/z/beta"),
                file("alpha", 500, path: "/a/alpha"),
                file("alpha", 500, path: "/b/alpha"),
            ],
            matchedItemCount: 3
        )
        XCTAssertEqual(result.files.map(\.path), ["/a/alpha", "/b/alpha", "/z/beta"])
    }

    // MARK: - Ranking: truncation to limit

    func testRankedTruncatesToLimitKeepingLargest() {
        let files = (1...10).map { file("f\($0)", Int64($0 * 100)) }
        let result = LargestFilesResult.ranked(from: files, matchedItemCount: 10, limit: 3)
        XCTAssertEqual(result.files.count, 3)
        XCTAssertEqual(result.files.map(\.sizeBytes), [1_000, 900, 800])
    }

    func testRankedFewerFilesThanLimitReturnsAllAndStaysAvailable() {
        let result = LargestFilesResult.ranked(
            from: [file("a", 30), file("b", 10)],
            matchedItemCount: 2,
            limit: 15
        )
        XCTAssertTrue(result.isIndexAvailable)
        XCTAssertEqual(result.files.count, 2)
    }

    /// A non-positive limit yields an empty list but stays available when items
    /// matched (the index is usable; the caller just asked for zero rows).
    func testRankedZeroLimitIsEmptyButAvailableWhenItemsMatched() {
        let result = LargestFilesResult.ranked(
            from: [file("a", 30)],
            matchedItemCount: 1,
            limit: 0
        )
        XCTAssertTrue(result.isIndexAvailable)
        XCTAssertTrue(result.files.isEmpty)
    }

    func testRankedUsesDefaultLimitWhenUnspecified() {
        let files = (1...30).map { file("f\($0)", Int64($0)) }
        let result = LargestFilesResult.ranked(from: files, matchedItemCount: 30)
        XCTAssertEqual(result.files.count, LargestFilesResult.defaultLimit)
    }

    // MARK: - Ranking: availability heuristic

    /// TECHSPEC §4 degraded state: the query matched no item at all → unusable index
    /// → `.unavailable` (SCAN-005 renders "Not indexed"), never an empty "available"
    /// list that reads as "no large files".
    func testRankedWithNoMatchedItemsIsUnavailable() {
        let result = LargestFilesResult.ranked(from: [], matchedItemCount: 0)
        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(result.isIndexAvailable)
    }

    /// Availability keys off the raw match count, not `files.count`: a matched-but-
    /// -unextractable set (e.g. all items lacked a size/URL, so `files` is empty) is
    /// still an available index, not the degraded state.
    func testRankedWithMatchesButEmptyFilesStaysAvailable() {
        let result = LargestFilesResult.ranked(from: [], matchedItemCount: 7)
        XCTAssertTrue(result.isIndexAvailable)
        XCTAssertTrue(result.files.isEmpty)
    }

    // MARK: - Predicate sanity (the query's own predicate string)

    /// The scanner's per-floor predicate must be a valid `NSMetadataQuery` predicate
    /// string at every floor — a typo would silently produce a query that matches
    /// nothing, masquerading as an "unindexed" volume. We reconstruct the same shape the
    /// scanner builds (`kMDItemFSSize > floor` AND not-a-folder) since it keeps the
    /// builder private, and assert it parses for the no-floor case and each real floor.
    func testFileSizeFlooredPredicateParsesAtEveryFloor() {
        func format(floor: Int64) -> String {
            "(kMDItemFSSize > \(floor)) && (kMDItemContentTypeTree != 'public.folder')"
        }
        // The floor-0 predicate is the original unfloored predicate.
        XCTAssertEqual(format(floor: 0), "(kMDItemFSSize > 0) && (kMDItemContentTypeTree != 'public.folder')")
        for floor in LargestFilesCascade.defaultFloors {
            XCTAssertNotNil(
                NSPredicate(fromMetadataQueryString: format(floor: floor)),
                "predicate for floor \(floor) must parse"
            )
        }
    }

    // MARK: - Size-floor cascade (A1)

    /// The default floors are the documented decimal magnitudes, highest first, ending
    /// at the `0` no-floor sentinel.
    func testCascadeDefaultFloorsAreHighestFirstEndingAtZero() {
        XCTAssertEqual(LargestFilesCascade.defaultFloors, [100_000_000, 10_000_000, 1_000_000, 0])
        XCTAssertEqual(LargestFilesCascade.defaultFloors.last, 0, "cascade must end at the no-floor pass")
    }

    /// A high floor that already matched ≥ `limit` files satisfies the request — stop
    /// there (available), never descend. Higher floors are strict subsets of lower ones,
    /// so this floor already holds the globally-largest `limit` files.
    func testCascadeStopsAtFirstFloorWithEnoughMatches() {
        let step = LargestFilesCascade.step(
            floorIndex: 0,
            matchedItemCount: 20,
            limit: 15,
            floors: [100_000_000, 10_000_000, 1_000_000, 0]
        )
        XCTAssertEqual(step, .deliver(unavailable: false))
    }

    /// Exactly `limit` matches is "enough" — deliver, don't descend.
    func testCascadeStopsWhenMatchesExactlyEqualLimit() {
        let step = LargestFilesCascade.step(
            floorIndex: 0,
            matchedItemCount: 15,
            limit: 15,
            floors: [100_000_000, 10_000_000, 1_000_000, 0]
        )
        XCTAssertEqual(step, .deliver(unavailable: false))
    }

    /// Fewer than `limit` matches at a non-final floor → descend to the next lower floor
    /// to widen the net.
    func testCascadeDescendsWhenTooFewMatchesAndFloorsRemain() {
        let step = LargestFilesCascade.step(
            floorIndex: 0,
            matchedItemCount: 3,
            limit: 15,
            floors: [100_000_000, 10_000_000, 1_000_000, 0]
        )
        XCTAssertEqual(step, .descend(nextIndex: 1))
    }

    /// A full descent: each floor short of `limit` steps to the next until the last
    /// (no-floor) floor is reached.
    func testCascadeDescendsFloorByFloorToTheLastFloor() {
        let floors: [Int64] = [100_000_000, 10_000_000, 1_000_000, 0]
        XCTAssertEqual(
            LargestFilesCascade.step(floorIndex: 1, matchedItemCount: 5, limit: 15, floors: floors),
            .descend(nextIndex: 2)
        )
        XCTAssertEqual(
            LargestFilesCascade.step(floorIndex: 2, matchedItemCount: 5, limit: 15, floors: floors),
            .descend(nextIndex: 3)
        )
    }

    /// The floor-0 (no-floor) query matched nothing → unusable index → deliver flagged
    /// unavailable (SCAN-005 "Not indexed"), never a further descend.
    func testCascadeFloorZeroWithNoMatchesIsUnavailable() {
        let floors: [Int64] = [100_000_000, 10_000_000, 1_000_000, 0]
        let step = LargestFilesCascade.step(
            floorIndex: 3, // the last floor (0)
            matchedItemCount: 0,
            limit: 15,
            floors: floors
        )
        XCTAssertEqual(step, .deliver(unavailable: true))
    }

    /// A small but indexed volume: the floor-0 query matched a few files (< `limit`).
    /// That is "available, short list", NOT the degraded state — distinguishing
    /// "small volume, few large files" from "not indexed".
    func testCascadeFloorZeroWithFewMatchesStaysAvailable() {
        let floors: [Int64] = [100_000_000, 10_000_000, 1_000_000, 0]
        let step = LargestFilesCascade.step(
            floorIndex: 3,
            matchedItemCount: 4,
            limit: 15,
            floors: floors
        )
        XCTAssertEqual(step, .deliver(unavailable: false))
    }

    /// A non-final floor that matched nothing but has lower floors left still descends —
    /// zero matches only means "unavailable" at the *final* (no-floor) floor, since a
    /// high size floor legitimately excludes every file on a small volume.
    func testCascadeNonFinalFloorWithNoMatchesDescendsNotUnavailable() {
        let floors: [Int64] = [100_000_000, 10_000_000, 1_000_000, 0]
        let step = LargestFilesCascade.step(
            floorIndex: 0,
            matchedItemCount: 0,
            limit: 15,
            floors: floors
        )
        XCTAssertEqual(step, .descend(nextIndex: 1))
    }

    /// A non-positive `limit` is already satisfied, so the cascade never descends — a
    /// zero-row request runs a single cheap query and delivers (available when the floor
    /// matched anything, else the floor-0 unavailable rule still applies).
    func testCascadeZeroLimitDeliversWithoutDescending() {
        let floors: [Int64] = [100_000_000, 10_000_000, 1_000_000, 0]
        XCTAssertEqual(
            LargestFilesCascade.step(floorIndex: 0, matchedItemCount: 0, limit: 0, floors: floors),
            .deliver(unavailable: false),
            "a zero-limit request stops at the first floor, not floor-0's unavailable rule"
        )
    }

    /// On-disk safety gate: a high floor with ≥ `limit` LOGICAL matches must still
    /// `.descend` when its delivered on-disk top-N boundary sits BELOW the floor — the
    /// sparse-giant regression. A dev volume with ≥ `limit` files over the 100 MB *logical*
    /// floor whose allocated sizes are tiny (sparse VM images) would otherwise deliver at
    /// that floor and omit genuinely large-on-disk files whose logical size is below the
    /// floor and so were never gathered. The gate forces a descent to gather them.
    func testCascadeDescendsWhenOnDiskTopNBoundaryBelowFloor() {
        let floors: [Int64] = [100_000_000, 10_000_000, 1_000_000, 0]
        let step = LargestFilesCascade.step(
            floorIndex: 0,
            matchedItemCount: 20, // plenty of files over the 100 MB LOGICAL floor…
            limit: 15,
            floors: floors,
            smallestTopOnDiskSize: 2_000_000 // …but the 15th on disk is only 2 MB (< floor)
        )
        XCTAssertEqual(step, .descend(nextIndex: 1),
                       "an on-disk top-N boundary below the floor must descend, not deliver")
    }

    /// The gate does NOT over-descend: when the on-disk top-N boundary is at or above the
    /// floor, the top-N is final (no un-gathered below-floor file can outrank it), so the
    /// cascade stops at this floor exactly as before.
    func testCascadeDeliversWhenOnDiskTopNBoundaryAtOrAboveFloor() {
        let floors: [Int64] = [100_000_000, 10_000_000, 1_000_000, 0]
        XCTAssertEqual(
            LargestFilesCascade.step(
                floorIndex: 0, matchedItemCount: 20, limit: 15, floors: floors,
                smallestTopOnDiskSize: 100_000_000 // exactly the floor: safe
            ),
            .deliver(unavailable: false)
        )
        XCTAssertEqual(
            LargestFilesCascade.step(
                floorIndex: 0, matchedItemCount: 20, limit: 15, floors: floors,
                smallestTopOnDiskSize: 500_000_000 // well above the floor: safe
            ),
            .deliver(unavailable: false)
        )
    }

    /// At the final (`0`) floor the on-disk gate is moot — every indexed file was gathered,
    /// so nothing un-gathered can outrank the delivered list. A below-"floor" on-disk
    /// boundary must still deliver (floor 0: everything ≥ 0), never a phantom descent.
    func testCascadeFinalFloorIgnoresOnDiskGate() {
        let floors: [Int64] = [100_000_000, 10_000_000, 1_000_000, 0]
        XCTAssertEqual(
            LargestFilesCascade.step(
                floorIndex: 3, matchedItemCount: 20, limit: 15, floors: floors,
                smallestTopOnDiskSize: 0
            ),
            .deliver(unavailable: false)
        )
    }

    /// Backward compatibility: omitting `smallestTopOnDiskSize` (the count-only rule the
    /// pure cascade tests use, and the path where fewer than `limit` files were delivered)
    /// keeps the original "stop at the first floor with ≥ `limit` matches" behavior.
    func testCascadeWithoutOnDiskBoundaryKeepsCountOnlyRule() {
        let floors: [Int64] = [100_000_000, 10_000_000, 1_000_000, 0]
        XCTAssertEqual(
            LargestFilesCascade.step(floorIndex: 0, matchedItemCount: 20, limit: 15, floors: floors),
            .deliver(unavailable: false),
            "with no on-disk boundary supplied the gate is disabled and the count rule holds"
        )
    }

    /// A single-floor cascade (`[0]`) is both the first and last floor: enough matches
    /// deliver available; no matches deliver unavailable.
    func testCascadeSingleFloorHandlesBothOutcomes() {
        XCTAssertEqual(
            LargestFilesCascade.step(floorIndex: 0, matchedItemCount: 3, limit: 15, floors: [0]),
            .deliver(unavailable: false)
        )
        XCTAssertEqual(
            LargestFilesCascade.step(floorIndex: 0, matchedItemCount: 0, limit: 15, floors: [0]),
            .deliver(unavailable: true)
        )
    }

    // MARK: - LargestFilesScanning seam contract (via mock)

    func testSeamDeliversResultOnceIntoLatestScan() {
        let scanner = MockLargestFilesScanner()
        var delivered: [LargestFilesResult] = []
        scanner.scan(volumeURL: volumeURL("/"), limit: 5) { delivered.append($0) }

        let expected = LargestFilesResult.available([file("big", 42)])
        scanner.deliver(expected)

        XCTAssertEqual(scanner.scanRequests.count, 1)
        XCTAssertEqual(scanner.scanRequests.first?.url, volumeURL("/"))
        XCTAssertEqual(scanner.scanRequests.first?.limit, 5)
        XCTAssertEqual(delivered, [expected])
    }

    func testSeamDefaultLimitOverloadUsesPRDDefault() {
        let scanner = MockLargestFilesScanner()
        scanner.scan(volumeURL: volumeURL("/")) { _ in }
        XCTAssertEqual(scanner.scanRequests.first?.limit, LargestFilesResult.defaultLimit)
    }

    func testSeamCancelDropsPendingDelivery() {
        let scanner = MockLargestFilesScanner()
        var delivered: [LargestFilesResult] = []
        scanner.scan(volumeURL: volumeURL("/"), limit: 5) { delivered.append($0) }

        scanner.cancel()
        scanner.deliver(.available([file("big", 42)]))

        XCTAssertEqual(scanner.cancelCount, 1)
        XCTAssertTrue(delivered.isEmpty, "a cancelled scan must not deliver its result")
    }

    // MARK: - On-disk (allocated) ranking (UX-010)

    /// The real scanner must rank + display by ON-DISK (allocated) size, not the logical
    /// `kMDItemFSSize` Spotlight sorts on. A sparse file with a huge logical size but a
    /// small allocated size (Docker.raw: ~345 GB logical / ~3.25 GB on disk) must rank
    /// BELOW a smaller-logical-but-larger-on-disk file, and the delivered size column
    /// must be the allocated size.
    func testScannerRanksByOnDiskSizeNotLogical() {
        // "sparse" reports a much larger LOGICAL size than "dense", but occupies less on
        // disk. Spotlight would sort sparse first (logical); on-disk ranking must invert
        // that, putting dense on top.
        let items: [NSMetadataItem] = [
            FakeMetadataItem(name: "Docker.raw", size: 345_000_000_000, path: "/vm/Docker.raw"),
            FakeMetadataItem(name: "movie.mov", size: 8_000_000_000, path: "/media/movie.mov"),
        ]
        let onDisk = MockOnDiskSizing(sizes: [
            fileURL("/vm/Docker.raw"): 3_250_000_000,   // sparse: small on disk
            fileURL("/media/movie.mov"): 8_000_000_000, // dense: on disk == logical
        ])

        let result = runRealScan(items: items, limit: 15, onDiskSizing: onDisk)

        XCTAssertTrue(result.isIndexAvailable)
        // Dense (8 GB on disk) ranks above sparse (3.25 GB on disk) despite sparse's far
        // larger logical size.
        XCTAssertEqual(result.files.map(\.displayName), ["movie.mov", "Docker.raw"])
        // The size column carries the ON-DISK (allocated) size, not the logical size.
        XCTAssertEqual(result.files.map(\.sizeBytes), [8_000_000_000, 3_250_000_000])
    }

    /// `LargestFile.sizeBytes` (the display + ranking value) is the allocated size the
    /// helper returns, never the logical size — verified on a single file so the display
    /// value is unambiguous.
    func testScannerDisplaySizeIsAllocatedNotLogical() {
        let items = [FakeMetadataItem(name: "sparse.img", size: 100_000_000_000, path: "/vm/sparse.img")]
        let onDisk = MockOnDiskSizing(sizes: [fileURL("/vm/sparse.img"): 512_000_000])

        let result = runRealScan(items: items, limit: 15, onDiskSizing: onDisk)

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.sizeBytes, 512_000_000,
                       "display size must be the allocated (on-disk) size, not logical")
    }

    /// When the allocated size is unreadable (helper returns `nil`), the scanner falls
    /// back to the file's logical size so a file is never dropped or ranked as zero.
    func testScannerFallsBackToLogicalWhenAllocatedIsNil() {
        let items = [
            FakeMetadataItem(name: "known.bin", size: 5_000, path: "/a/known.bin"),
            FakeMetadataItem(name: "unreadable.bin", size: 9_000, path: "/a/unreadable.bin"),
        ]
        // Only "known.bin" has an allocated size; "unreadable.bin" returns nil → logical.
        let onDisk = MockOnDiskSizing(sizes: [fileURL("/a/known.bin"): 1_000])

        let result = runRealScan(items: items, limit: 15, onDiskSizing: onDisk)

        // unreadable.bin falls back to its logical 9_000 (> known.bin's allocated 1_000),
        // so it ranks first and displays its logical size.
        XCTAssertEqual(result.files.map(\.displayName), ["unreadable.bin", "known.bin"])
        XCTAssertEqual(result.files.map(\.sizeBytes), [9_000, 1_000])
    }

    // MARK: - Trash filtering (UX-018)

    // Trash detection no longer guesses `.Trash`/`.Trashes` from path spelling: the scanner
    // asks the system (`FileManager`) for the volume's real Trash directory and passes that
    // resolved URL into the PURE `isInTrash(_:trashURL:)` containment check. These tests
    // exercise that pure containment logic against an explicit `trashURL`, with no filesystem
    // access — the `.Trash`/`.Trashes` spelling below is arbitrary; only the containment
    // relationship between the two URLs matters.

    /// A candidate that sits INSIDE the resolved Trash URL is "in Trash".
    func testIsInTrashDetectsFileInsideResolvedTrash() {
        let trash = fileURL("/Users/me/.Trash")
        XCTAssertTrue(TrashFilter.isInTrash(fileURL("/Users/me/.Trash/archive.zip"), trashURL: trash))
    }

    /// A candidate nested arbitrarily deep inside the resolved Trash is still "in Trash".
    func testIsInTrashDetectsNestedTrashContents() {
        let trash = fileURL("/Users/me/.Trash")
        XCTAssertTrue(TrashFilter.isInTrash(fileURL("/Users/me/.Trash/OldProject/build/big.a"), trashURL: trash))
    }

    /// A per-volume Trash resolves to `/Volumes/X/.Trashes/<uid>`; a file below it matches.
    func testIsInTrashDetectsPerVolumeTrash() {
        let trash = fileURL("/Volumes/X/.Trashes/501")
        XCTAssertTrue(TrashFilter.isInTrash(fileURL("/Volumes/X/.Trashes/501/movie.mov"), trashURL: trash))
    }

    /// A candidate OUTSIDE the resolved Trash is kept — the common case.
    func testIsInTrashKeepsFileOutsideResolvedTrash() {
        let trash = fileURL("/Users/me/.Trash")
        XCTAssertFalse(TrashFilter.isInTrash(fileURL("/Users/me/Movies/movie.mov"), trashURL: trash))
    }

    /// A sibling whose path shares a textual PREFIX with the Trash URL but is a different
    /// directory is NOT falsely matched — component-wise comparison, not string prefix.
    /// `/Volumes/X/.Trashes/501` must not swallow `/Volumes/X/.Trashes/5011/x` (`5011` ≠ `501`).
    func testIsInTrashDoesNotMatchPrefixSiblingDirectory() {
        let trash = fileURL("/Volumes/X/.Trashes/501")
        XCTAssertFalse(TrashFilter.isInTrash(fileURL("/Volumes/X/.Trashes/5011/x"), trashURL: trash))
    }

    /// The Trash directory ITSELF (path equal to `trashURL`) is treated as in-Trash — no
    /// candidate is ever the Trash directory (Spotlight excludes folders), but the at-or-below
    /// prefix must not throw or false-negative on equality.
    func testIsInTrashMatchesTrashDirectoryItself() {
        let trash = fileURL("/Users/me/.Trash")
        XCTAssertTrue(TrashFilter.isInTrash(fileURL("/Users/me/.Trash"), trashURL: trash))
    }

    /// A `nil` resolved Trash URL (the system couldn't resolve one) filters NOTHING — every
    /// candidate is kept, including one whose path merely looks trash-like.
    func testIsInTrashWithNilTrashURLFiltersNothing() {
        XCTAssertFalse(TrashFilter.isInTrash(fileURL("/Users/me/.Trash/archive.zip"), trashURL: nil))
        XCTAssertFalse(TrashFilter.isInTrash(fileURL("/Users/me/Movies/movie.mov"), trashURL: nil))
    }

    /// The list filter drops files inside the resolved Trash and keeps the rest, in order.
    func testExcludingTrashKeepsOnlyNonTrashFilesInOrder() {
        let trash = fileURL("/Users/me/.Trash")
        let files = [
            file("keep1", 10, path: "/Users/me/keep1"),
            file("gone", 20, path: "/Users/me/.Trash/gone"),
            file("keep2", 30, path: "/Users/me/Movies/keep2"),
        ]
        let kept = TrashFilter.excludingTrash(files, trashURL: trash)
        XCTAssertEqual(kept.map(\.displayName), ["keep1", "keep2"])
    }

    /// With a `nil` Trash URL the list filter keeps everything.
    func testExcludingTrashWithNilTrashURLKeepsEverything() {
        let files = [
            file("a", 10, path: "/Users/me/.Trash/a"),
            file("b", 20, path: "/Users/me/b"),
        ]
        XCTAssertEqual(TrashFilter.excludingTrash(files, trashURL: nil).map(\.displayName), ["a", "b"])
    }

    /// Light integration check: resolving the Trash for a real volume ("/") via the system
    /// API returns a non-`nil` URL that actually ends at a Trash directory. This is the one
    /// place the FileManager path is touched; the pure containment logic above is trusted for
    /// everything else.
    func testResolveTrashURLForBootVolumeIsNonNil() {
        let resolved = TrashFilter.resolveTrashURL(for: volumeURL("/"))
        XCTAssertNotNil(resolved, "the boot volume must resolve to a real Trash directory")
        XCTAssertEqual(resolved?.lastPathComponent, ".Trash",
                       "the system-resolved boot-volume Trash is ~/.Trash")
    }

    /// End-to-end through the real scanner scanning the boot volume ("/"): the scanner
    /// resolves the REAL system Trash (~/.Trash) once, and a candidate placed inside it is
    /// filtered out of the delivered list while a normal file is kept — even though the Trash
    /// file is LARGER (it would otherwise top the list). The Trash path is built from the
    /// system-resolved URL, not a guessed spelling.
    func testScannerFiltersTrashCandidatesFromDeliveredList() {
        // Resolve the real boot-volume Trash the scanner will resolve internally, and place a
        // huge candidate inside it so the test's fixture matches the scanner's resolution.
        guard let trash = TrashFilter.resolveTrashURL(for: volumeURL("/")) else {
            return XCTFail("boot volume must resolve a Trash directory")
        }
        let trashedPath = trash.appendingPathComponent("huge-trashed").path
        let items: [NSMetadataItem] = [
            FakeMetadataItem(name: "huge-trashed", size: 9_000_000_000, path: trashedPath),
            FakeMetadataItem(name: "keeper.mov", size: 1_000_000_000, path: "/Users/me/Movies/keeper.mov"),
        ]
        let onDisk = MockOnDiskSizing(sizes: [
            fileURL(trashedPath): 9_000_000_000,
            fileURL("/Users/me/Movies/keeper.mov"): 1_000_000_000,
        ])

        let result = runRealScan(items: items, limit: 15, onDiskSizing: onDisk)

        XCTAssertTrue(result.isIndexAvailable)
        XCTAssertEqual(result.files.map(\.displayName), ["keeper.mov"],
                       "candidates inside the system-resolved Trash must be excluded from the list")
    }

    // MARK: - On-disk ranking test helpers

    /// A fake `NSMetadataItem` returning canned attribute values — no real Spotlight.
    /// Only the attributes the scanner reads (`FSSize`, `Path`, `FSName`) are supported.
    private final class FakeMetadataItem: NSMetadataItem, @unchecked Sendable {
        private let cannedAttributes: [String: Any]

        init(name: String, size: Int64, path: String) {
            cannedAttributes = [
                NSMetadataItemFSNameKey: name,
                NSMetadataItemFSSizeKey: NSNumber(value: size),
                NSMetadataItemPathKey: path,
            ]
            super.init()
        }

        override func value(forAttribute key: String) -> Any? { cannedAttributes[key] }
    }

    /// A fake `NSMetadataQuery` serving canned `FakeMetadataItem`s, already sorted
    /// largest-first by LOGICAL size (as Spotlight would). `start()` posts the finish
    /// notification so the scanner's off-main observer runs the real extract/rank path.
    private final class FakeMetadataQuery: NSMetadataQuery, @unchecked Sendable {
        let items: [NSMetadataItem]

        init(items: [NSMetadataItem]) {
            // Present in Spotlight's own order: descending by logical size.
            self.items = items.sorted {
                let l = ($0.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
                let r = ($1.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
                return l > r
            }
            super.init()
        }

        override var resultCount: Int { items.count }
        override func result(at index: Int) -> Any { items[index] }
        override func disableUpdates() {}
        override func enableUpdates() {}

        override func start() -> Bool {
            // Fire the terminal notification off-main so the scanner's observer (which
            // asserts `.notOnQueue(.main)`) runs its extraction on a background thread.
            DispatchQueue.global(qos: .userInitiated).async {
                NotificationCenter.default.post(name: .NSMetadataQueryDidFinishGathering, object: self)
            }
            return true
        }

        override func stop() {}
    }

    /// Synchronous run-loop executor stub: runs `perform` blocks inline on a private
    /// off-main serial queue so the scanner's `.notOnQueue(.main)` preconditions hold.
    private final class SyncRunLoopExecutor: MetadataQueryRunLoopExecuting, @unchecked Sendable {
        private let queue = DispatchQueue(label: "test.ondisk-runloop", qos: .userInitiated)
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

    /// Drives a *real* `SpotlightLargestFilesScanner` end-to-end against a `FakeMetadataQuery`
    /// and the injected `OnDiskSizing`, using a single-floor (`[0]`) cascade so exactly one
    /// query runs, and returns the delivered result. Blocks on an expectation for delivery
    /// on the deliver queue.
    private func runRealScan(
        items: [NSMetadataItem],
        limit: Int,
        onDiskSizing: OnDiskSizing
    ) -> LargestFilesResult {
        let deliverQueue = DispatchQueue(label: "test.ondisk-deliver")
        let scanner = SpotlightLargestFilesScanner(
            runLoopThread: SyncRunLoopExecutor(),
            deliverQueue: deliverQueue,
            makeQuery: { FakeMetadataQuery(items: items) },
            floors: [0],
            onDiskSizing: onDiskSizing
        )
        let delivered = expectation(description: "result delivered")
        var captured: LargestFilesResult?
        scanner.scan(volumeURL: volumeURL("/"), limit: limit) { result in
            captured = result
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        return captured ?? .unavailable
    }

    // MARK: - Trash inflating the cascade descend gate

    /// Serves a distinct canned item-set per floor query, in the order the cascade asks
    /// for them: each `make()` pops the next set, so floor N's query returns
    /// `floorItemSets[N]`. Mirrors how each descending floor of a real cascade widens the
    /// net (a lower floor matches strictly more files). Thread-safe: the scanner builds
    /// queries on its state queue.
    private final class PerFloorQueryFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [[NSMetadataItem]]

        init(floorItemSets: [[NSMetadataItem]]) { remaining = floorItemSets }

        func make() -> NSMetadataQuery {
            let items: [NSMetadataItem] = lock.withLock {
                remaining.isEmpty ? [] : remaining.removeFirst()
            }
            return FakeMetadataQuery(items: items)
        }
    }

    /// Drives a real scanner through a multi-floor cascade, serving `floorItemSets[i]` for
    /// the i-th floor query, and returns the delivered result.
    private func runRealCascadeScan(
        floors: [Int64],
        floorItemSets: [[NSMetadataItem]],
        limit: Int,
        onDiskSizing: OnDiskSizing
    ) -> LargestFilesResult {
        let deliverQueue = DispatchQueue(label: "test.cascade-deliver")
        let factory = PerFloorQueryFactory(floorItemSets: floorItemSets)
        let scanner = SpotlightLargestFilesScanner(
            runLoopThread: SyncRunLoopExecutor(),
            deliverQueue: deliverQueue,
            makeQuery: factory.make,
            floors: floors,
            onDiskSizing: onDiskSizing
        )
        let delivered = expectation(description: "cascade result delivered")
        var captured: LargestFilesResult?
        scanner.scan(volumeURL: volumeURL("/"), limit: limit) { result in
            captured = result
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        return captured ?? .unavailable
    }

    /// Regression: a Trash-heavy high floor must NOT stop the cascade early. The raw
    /// Spotlight match count at the top floor includes Trash files (which are filtered out
    /// of the delivered list), so counting them toward the "enough matches to stop" gate
    /// would deliver an under-filled list and never descend. The scanner must discount
    /// Trash from the deliverable count and descend to the lower floor where the real
    /// keepers live.
    ///
    /// Floor 0 (100 MB gate, first query): 5 matches — 4 under the real system Trash, 1
    /// keeper. With a limit of 3, the raw count (5) is ≥ limit but only 1 file is
    /// deliverable, so the cascade must descend. Floor 1 (no-floor, second query): 3
    /// non-Trash keepers exist. The correct result is the 3 real keepers, not the single
    /// high-floor survivor. The Trash paths are built from the system-resolved boot-volume
    /// Trash (which the scanner resolves internally), not a guessed spelling.
    func testTrashHeavyHighFloorDoesNotTruncateCascade() {
        guard let trash = TrashFilter.resolveTrashURL(for: volumeURL("/")) else {
            return XCTFail("boot volume must resolve a Trash directory")
        }
        func trashed(_ name: String) -> String { trash.appendingPathComponent(name).path }
        let highFloorItems: [NSMetadataItem] = [
            FakeMetadataItem(name: "trash-a", size: 5_000_000_000, path: trashed("trash-a")),
            FakeMetadataItem(name: "trash-b", size: 4_000_000_000, path: trashed("trash-b")),
            FakeMetadataItem(name: "trash-c", size: 3_000_000_000, path: trashed("trash-c")),
            FakeMetadataItem(name: "trash-d", size: 2_000_000_000, path: trashed("trash-d")),
            FakeMetadataItem(name: "keeper-big.mov", size: 1_000_000_000, path: "/Users/me/Movies/keeper-big.mov"),
        ]
        // The lower (no-floor) floor sees the same Trash plus the smaller real keepers.
        let lowFloorItems: [NSMetadataItem] = highFloorItems + [
            FakeMetadataItem(name: "keeper-mid.zip", size: 500_000_000, path: "/Users/me/keeper-mid.zip"),
            FakeMetadataItem(name: "keeper-small.dmg", size: 200_000_000, path: "/Users/me/keeper-small.dmg"),
        ]
        let onDisk = MockOnDiskSizing(sizes: [
            fileURL(trashed("trash-a")): 5_000_000_000,
            fileURL(trashed("trash-b")): 4_000_000_000,
            fileURL(trashed("trash-c")): 3_000_000_000,
            fileURL(trashed("trash-d")): 2_000_000_000,
            fileURL("/Users/me/Movies/keeper-big.mov"): 1_000_000_000,
            fileURL("/Users/me/keeper-mid.zip"): 500_000_000,
            fileURL("/Users/me/keeper-small.dmg"): 200_000_000,
        ])

        let result = runRealCascadeScan(
            floors: [100_000_000, 0],
            floorItemSets: [highFloorItems, lowFloorItems],
            limit: 3,
            onDiskSizing: onDisk
        )

        XCTAssertTrue(result.isIndexAvailable)
        XCTAssertEqual(
            result.files.map(\.displayName),
            ["keeper-big.mov", "keeper-mid.zip", "keeper-small.dmg"],
            "Trash must not count toward the descend gate: the cascade must descend and fill the list with real keepers"
        )
    }

    /// A floor whose only matches are all in Trash is still an INDEXED volume, not a
    /// degraded "Not indexed" one. The deliverable count is 0, but the raw index count is
    /// nonzero, so the result must be available-but-empty — the degraded flag keys off the
    /// raw count, not the post-Trash deliverable count.
    func testFloorWithOnlyTrashMatchesStaysAvailableNotDegraded() {
        guard let trash = TrashFilter.resolveTrashURL(for: volumeURL("/")) else {
            return XCTFail("boot volume must resolve a Trash directory")
        }
        let goneA = trash.appendingPathComponent("gone-a").path
        let goneB = trash.appendingPathComponent("nested/gone-b").path
        let items: [NSMetadataItem] = [
            FakeMetadataItem(name: "gone-a", size: 9_000_000_000, path: goneA),
            FakeMetadataItem(name: "gone-b", size: 8_000_000_000, path: goneB),
        ]
        let onDisk = MockOnDiskSizing(sizes: [
            fileURL(goneA): 9_000_000_000,
            fileURL(goneB): 8_000_000_000,
        ])

        let result = runRealCascadeScan(
            floors: [0],
            floorItemSets: [items],
            limit: 3,
            onDiskSizing: onDisk
        )

        XCTAssertTrue(result.isIndexAvailable,
                      "an all-Trash but indexed volume is available (empty list), not degraded")
        XCTAssertTrue(result.files.isEmpty)
    }
}
