import Foundation

/// Resolves a file's **on-disk (allocated) size** — the bytes it actually occupies on
/// the volume, matching Finder's "on disk" figure — so ranking and display never trust a
/// file's *logical* size (UX-010).
///
/// **Why this exists (the sparse-file bug):** logical size (`kMDItemFSSize` /
/// `.fileSizeKey`) is the byte length a file *reports*, which for a sparse file wildly
/// overstates what it costs on disk. A `Docker.raw` can report 345 GB logically while
/// occupying 3.25 GB on disk; VM `.bundle`s do the same. Ranking "largest files" by
/// logical size floats those virtual giants to the top and buries the files a user can
/// actually reclaim space by deleting. Allocated size — `.totalFileAllocatedSizeKey`,
/// the "total bytes allocated including metadata/resource forks" that Finder reports —
/// is the honest number, so the largest-files tier ranks and displays *that*.
///
/// **Protocol seam (`OnDiskSizing`):** the concrete `OnDiskSizeResolver` reads the URL's
/// resource values off the real filesystem, which unit tests must never do (there is no
/// controllable filesystem in a hermetic test). The protocol lets tests inject a
/// canned-sizes stub so the scanner's re-rank-by-allocated logic is exercised without
/// touching disk — the same "no real Spotlight / no real filesystem in tests" discipline
/// the scanners already follow.
///
/// **Logical fallback:** allocated size can be unreadable (permissions, a file that
/// vanished between the Spotlight match and this read, or a volume that doesn't report
/// the key). When it is `nil` the caller falls back to the logical size it already has —
/// a best-effort figure is better than dropping the file or ranking it as zero. This
/// helper does *not* itself hold the logical value; it returns `nil` and the caller
/// substitutes its known logical size (see `SpotlightLargestFilesScanner`).
protocol OnDiskSizing {
    /// The on-disk (allocated) size of the file at `url` in bytes, or `nil` when it
    /// cannot be read. Non-negative when non-`nil`. Callers fall back to the file's
    /// logical size on `nil`.
    ///
    /// This performs a synchronous filesystem stat and must never run on the main
    /// thread (NFR4) — the largest-files scanner calls it only on its off-main run-loop
    /// / state path.
    func onDiskSizeBytes(of url: URL) -> Int64?
}

/// Production `OnDiskSizing`: reads `URLResourceValues([.totalFileAllocatedSizeKey])`,
/// the allocated byte count that matches Finder's "on disk" size (UX-010).
///
/// `.totalFileAllocatedSizeKey` is preferred over `.fileAllocatedSizeKey` because
/// "total" includes metadata and resource-fork allocation, exactly the figure Finder
/// shows — so a file's reported on-disk size lines up with what the user sees in Finder's
/// Get Info. A negative value (never produced by a real read) clamps to `nil` so a corrupt
/// stat can't rank a file to the top; the caller then falls back to logical size.
struct OnDiskSizeResolver: OnDiskSizing {
    /// The single resource key read per file. Kept as a static set so the (immutable)
    /// request isn't rebuilt on every call.
    private static let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]

    init() {}

    func onDiskSizeBytes(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: Self.keys),
              let allocated = values.totalFileAllocatedSize
        else { return nil }
        // `totalFileAllocatedSize` is an `Int` (bytes); guard against a nonsense
        // negative so a corrupt read never sorts a file to the top of the list.
        return allocated >= 0 ? Int64(allocated) : nil
    }
}
