import Foundation

/// Free/total bytes for a volume, as reported by the filesystem.
struct VolumeSpace: Equatable {
    /// Bytes available to the user (`f_bavail`). Excludes APFS purgeable space,
    /// so this reads lower than Finder's "available" figure, which includes it.
    let free: Int64
    /// Total capacity in bytes (`f_blocks * f_bsize`).
    let total: Int64
}

/// Protocol seam for the cheap tier-1 boot-volume read (TECHSPEC §3, tier 1).
/// Conformers must be safe to call off the main thread.
protocol VolumeSpaceReading {
    /// Returns the boot volume's space, or `nil` if the read failed.
    func readBootVolume() -> VolumeSpace?
}

/// Reads the boot volume with a single `statfs("/")` call.
/// No Spotlight, no enumeration, no state — sub-millisecond cost per call,
/// safe to invoke from any thread.
struct StatfsBootVolumeReader: VolumeSpaceReading {
    func readBootVolume() -> VolumeSpace? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        let blockSize = Int64(stats.f_bsize)
        // f_bavail (user-available) rather than f_bfree (superuser-available),
        // per TECHSPEC §4. Neither counts APFS purgeable space, so this is
        // lower than Finder's "available", which does include it.
        let free = Int64(stats.f_bavail) * blockSize
        let total = Int64(stats.f_blocks) * blockSize
        return VolumeSpace(free: free, total: total)
    }
}
