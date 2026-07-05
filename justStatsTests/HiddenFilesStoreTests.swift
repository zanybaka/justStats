import XCTest
@testable import justStats

/// `HiddenFilesStore` (UX-015): the `UserDefaults`-backed persistence behind the
/// largest-files "Hide" action. Every test runs against an isolated defaults suite (never
/// `.standard`), so the real domain is never touched and each case starts clean. The
/// view-model's *use* of the store (filtering a scanned list, un-hiding) is covered in
/// `VolumeListViewModelTests`; here the store's own add/persist/clear contract is pinned.
@MainActor
final class HiddenFilesStoreTests: XCTestCase {
    // MARK: - Empty / default state

    /// A never-written store reads as empty — nothing hidden, so the list shows everything.
    func testFreshStoreIsEmpty() {
        let store = HiddenFilesStore(defaults: makeIsolatedDefaults())
        XCTAssertTrue(store.hiddenPaths.isEmpty)
        XCTAssertFalse(store.isHidden("/Users/me/big.mov"))
    }

    // MARK: - Hide

    /// Hiding a path records it and reports it as hidden.
    func testHideRecordsThePath() {
        let store = HiddenFilesStore(defaults: makeIsolatedDefaults())
        store.hide("/Users/me/big.mov")

        XCTAssertEqual(store.hiddenPaths, ["/Users/me/big.mov"])
        XCTAssertTrue(store.isHidden("/Users/me/big.mov"))
    }

    /// Hiding several paths accumulates them all (a set — order irrelevant).
    func testHideAccumulatesMultiplePaths() {
        let store = HiddenFilesStore(defaults: makeIsolatedDefaults())
        store.hide("/a")
        store.hide("/b")
        store.hide("/c")

        XCTAssertEqual(store.hiddenPaths, ["/a", "/b", "/c"])
    }

    /// Hiding an already-hidden path is idempotent — no duplicate, still one entry.
    func testHideIsIdempotent() {
        let store = HiddenFilesStore(defaults: makeIsolatedDefaults())
        store.hide("/a")
        store.hide("/a")

        XCTAssertEqual(store.hiddenPaths, ["/a"])
    }

    // MARK: - Persistence across instances (survives a "reopen"/relaunch)

    /// A hidden path written by one store instance is read back by a *fresh* instance over
    /// the same suite — the "hidden survives across sessions" guarantee (UX-015), modelled
    /// by two stores sharing the defaults suite (a new instance = a relaunch).
    func testHiddenPathPersistsAcrossInstances() {
        let defaults = makeIsolatedDefaults()
        let first = HiddenFilesStore(defaults: defaults)
        first.hide("/Users/me/archive.zip")

        let second = HiddenFilesStore(defaults: defaults)
        XCTAssertTrue(second.isHidden("/Users/me/archive.zip"),
                      "a hidden path is still hidden after a relaunch")
        XCTAssertEqual(second.hiddenPaths, ["/Users/me/archive.zip"])
    }

    // MARK: - Unhide

    /// Un-hiding removes just that path, leaving the rest hidden.
    func testUnhideRemovesOnlyThatPath() {
        let store = HiddenFilesStore(defaults: makeIsolatedDefaults())
        store.hide("/a")
        store.hide("/b")

        store.unhide("/a")

        XCTAssertFalse(store.isHidden("/a"))
        XCTAssertTrue(store.isHidden("/b"))
        XCTAssertEqual(store.hiddenPaths, ["/b"])
    }

    /// Un-hiding a path that wasn't hidden is a harmless no-op.
    func testUnhideOfUnknownPathIsNoOp() {
        let store = HiddenFilesStore(defaults: makeIsolatedDefaults())
        store.hide("/a")

        store.unhide("/never-hidden")

        XCTAssertEqual(store.hiddenPaths, ["/a"])
    }

    /// An un-hide persists too: a fresh instance sees the path gone.
    func testUnhidePersistsAcrossInstances() {
        let defaults = makeIsolatedDefaults()
        let first = HiddenFilesStore(defaults: defaults)
        first.hide("/a")
        first.hide("/b")
        first.unhide("/a")

        let second = HiddenFilesStore(defaults: defaults)
        XCTAssertEqual(second.hiddenPaths, ["/b"],
                       "an un-hide survives a relaunch just like a hide")
    }

    // MARK: - Clear

    /// Clearing removes every hidden path — the "un-hide all" escape hatch.
    func testClearRemovesEverything() {
        let store = HiddenFilesStore(defaults: makeIsolatedDefaults())
        store.hide("/a")
        store.hide("/b")

        store.clear()

        XCTAssertTrue(store.hiddenPaths.isEmpty)
    }

    /// A cleared store persists as empty: a fresh instance over the same suite sees nothing
    /// hidden (clear removes the key rather than storing an empty array — same read result).
    func testClearPersistsAcrossInstances() {
        let defaults = makeIsolatedDefaults()
        let first = HiddenFilesStore(defaults: defaults)
        first.hide("/a")
        first.clear()

        let second = HiddenFilesStore(defaults: defaults)
        XCTAssertTrue(second.hiddenPaths.isEmpty,
                      "a clear survives a relaunch — nothing resurrects")
    }
}
