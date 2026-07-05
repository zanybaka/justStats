import Foundation

/// Seam for the "Hide" action's persistence (UX-015). The largest-files section lets the
/// user hide a row so it stops cluttering the list; that choice must survive across
/// popover opens *and* app launches, so it is persisted rather than kept in memory. The
/// view model depends on this abstraction instead of `UserDefaults` directly, so the
/// filter-and-persist logic is unit-tested against an in-memory or isolated-suite double
/// without touching the user's real defaults.
///
/// A file is identified by its filesystem `path` (the `String` form): the persisted
/// contract is a plain `[String]` (a property-list type; a `URL` is not), and a path is a
/// stable, human-meaningful key that survives serialization. Paths are never logged
/// (TECHSPEC §7).
protocol HiddenFilesStoring: AnyObject {
    /// Every currently-hidden file path. A set — order is irrelevant and membership is the
    /// only question the view model asks (is this row hidden?).
    var hiddenPaths: Set<String> { get }

    /// Marks `path` hidden and persists it. Idempotent — hiding an already-hidden path is
    /// a no-op.
    func hide(_ path: String)

    /// Un-hides `path` (removes it from the hidden set) and persists. Idempotent — a path
    /// that wasn't hidden is left untouched.
    func unhide(_ path: String)

    /// Clears every hidden path — the "un-hide all" escape hatch so the user is never
    /// trapped with rows they can't get back.
    func clear()
}

extension HiddenFilesStoring {
    /// Whether `path` is currently hidden — the membership test the view model uses to
    /// filter a scanned/cached list before publishing it.
    func isHidden(_ path: String) -> Bool { hiddenPaths.contains(path) }
}

/// `UserDefaults`-backed `HiddenFilesStoring` (UX-015). Persists the hidden paths under
/// the single centralized `DefaultsKey.hiddenLargestFilePaths` so the choice survives app
/// launches. Stored as a `[String]` (the persisted property-list shape) and surfaced as a
/// `Set` for O(1) membership; every mutation writes straight back, so a crash right after
/// a hide still leaves the file hidden on next launch.
///
/// `@MainActor`-confined, matching its only caller (`VolumeListViewModel`): the store is
/// touched from the popover's main-actor code only, so no locking is needed.
@MainActor
final class HiddenFilesStore: HiddenFilesStoring {
    private let defaults: UserDefaults

    /// - Parameter defaults: the suite to persist into. Defaults to `.standard`
    ///   (production); tests inject an isolated suite so the real domain is never touched.
    ///
    /// `nonisolated` so it can be used as a default argument for `VolumeListViewModel`'s
    /// initializer (default-argument expressions evaluate in a nonisolated context, like
    /// the other injected seams). Only stores the reference; every read/write stays
    /// main-actor-confined via the type's isolation.
    nonisolated init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hiddenPaths: Set<String> {
        // Read back the persisted array; a missing/incompatible value reads as empty
        // (nothing hidden yet) rather than crashing — the on-disk contract is best-effort.
        let stored = defaults.array(forKey: DefaultsKey.hiddenLargestFilePaths) as? [String]
        return Set(stored ?? [])
    }

    func hide(_ path: String) {
        var paths = hiddenPaths
        guard paths.insert(path).inserted else { return } // already hidden — no write
        persist(paths)
    }

    func unhide(_ path: String) {
        var paths = hiddenPaths
        guard paths.remove(path) != nil else { return } // wasn't hidden — no write
        persist(paths)
    }

    func clear() {
        // Remove the key entirely rather than storing an empty array, so a cleared store
        // reads identically to a never-written one.
        defaults.removeObject(forKey: DefaultsKey.hiddenLargestFilePaths)
    }

    /// Writes the hidden set back as a plain `[String]` under the centralized key. Sorted
    /// so the persisted order is deterministic (nicer for debugging; membership doesn't
    /// depend on it).
    private func persist(_ paths: Set<String>) {
        defaults.set(paths.sorted(), forKey: DefaultsKey.hiddenLargestFilePaths)
    }
}
