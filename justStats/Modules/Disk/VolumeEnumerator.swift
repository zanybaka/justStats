import DiskArbitration
import Foundation

/// One user-facing mounted volume (PRD FR2–FR5, TECHSPEC §2/§3).
struct Volume: Equatable {
    /// Where the volume physically lives. Decides which enumeration tier resolves
    /// it: `.internal` → synchronous fast path, `.external`/`.network` → deferred
    /// async path (TECHSPEC §3 tier 2).
    enum Kind: String {
        case `internal`
        case external
        case network
    }

    let name: String
    let mountURL: URL
    let totalBytes: Int64
    /// Bytes available to the user — same `f_bavail` semantics as `VolumeSpace.free`
    /// (excludes APFS purgeable space, so lower than Finder's "available").
    let freeBytes: Int64
    let kind: Kind
    /// BSD device name (e.g. "disk3s5") from DiskArbitration metadata; `nil` where
    /// none exists (network mounts) or DiskArbitration has no record.
    let bsdName: String?

    var usedBytes: Int64 { max(totalBytes - freeBytes, 0) }

    /// Used share of the volume in `0...1` — the single source of truth for
    /// "fullness", used both as the popover's usage-bar fill and as the
    /// "most-full first" sort key (PRD FR9). A zero-total volume is `0` (never a
    /// divide-by-zero); the ratio is clamped so an over-reported `usedBytes`
    /// can't push a bar past full.
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    /// A copy of this volume with `bytes` more free space — the optimistic freed-space
    /// update after a file is moved to the Trash (ACT-002). `freeBytes` is capped at
    /// `totalBytes` so a stale/over-large size can't report more free than the volume
    /// holds; a non-positive `bytes` is a no-op. The captured free/used figures come
    /// from `statfs`, and re-querying the whole volume set just to reflect one deletion
    /// would be heavier than the task warrants, so the row is nudged locally instead
    /// (the next Refresh reconciles against a real `statfs` read anyway).
    func withFreedBytes(_ bytes: Int64) -> Volume {
        guard bytes > 0 else { return self }
        let newFree = min(freeBytes + bytes, max(totalBytes, 0))
        return Volume(
            name: name,
            mountURL: mountURL,
            totalBytes: totalBytes,
            freeBytes: newFree,
            kind: kind,
            bsdName: bsdName
        )
    }
}

/// A mounted volume classified as external/network by the synchronous pass. Its
/// sizes are deliberately unresolved: a capacity read can hang on a dead network
/// mount, so `DeferredVolumeResolver` resolves it per volume on a background
/// queue with row-level isolation (VOL-002, TECHSPEC §3 tier 2).
struct DeferredVolume: Equatable {
    let name: String
    let mountURL: URL
    /// `.external` or `.network` — never `.internal` (internal resolves inline).
    let kind: Volume.Kind
}

/// Raw, unclassified facts about one mounted volume — the injection seam so
/// classification/filtering tests don't depend on real mounts. `nil` means the
/// filesystem did not report that value.
struct VolumeInfo: Equatable {
    let mountURL: URL
    var name: String? = nil
    var isInternal: Bool? = nil
    var isLocal: Bool? = nil
    var isRemovable: Bool? = nil
    var isEjectable: Bool? = nil
}

/// Seam between `VolumeEnumerator` and the real filesystem (mockable in tests).
protocol VolumeInfoProviding {
    /// Identity and classification facts for every mounted, non-hidden volume.
    func mountedVolumes() -> [VolumeInfo]
    /// Capacity of a single volume. May block on a hung network mount, so callers
    /// choose the queue/timeout policy: the synchronous pass calls this for
    /// internal volumes only; `DeferredVolumeResolver` calls it per volume on
    /// `DispatchQueue.global(qos: .utility)` under a row-level timeout.
    func capacity(forVolumeAt url: URL) -> VolumeSpace?
    /// BSD device name via DiskArbitration metadata, or `nil` if unknown.
    func bsdName(forVolumeAt url: URL) -> String?
}

/// Real provider: `FileManager.mountedVolumeURLs` for enumeration + resource
/// values, DiskArbitration strictly for per-volume metadata (BSD name) — no event
/// subscriptions (TECHSPEC §3, verified Stats pattern).
struct FileManagerVolumeInfoProvider: VolumeInfoProviding {
    /// All keys are prefetched in one enumeration call (TECHSPEC §3); the per-URL
    /// reads below then hit the cached values.
    private static let prefetchKeys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeIsInternalKey,
        .volumeIsLocalKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
    ]

    private static let identityKeys: Set<URLResourceKey> = [
        .volumeNameKey,
        .volumeIsInternalKey,
        .volumeIsLocalKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
    ]

    /// Metadata-only DiskArbitration session; never handed a dispatch queue or
    /// runloop, so no callbacks can ever fire.
    private let session = DASessionCreate(kCFAllocatorDefault)

    init() {}

    func mountedVolumes() -> [VolumeInfo] {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.prefetchKeys,
            options: [.skipHiddenVolumes]
        ) else { return [] }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Self.identityKeys)
            return VolumeInfo(
                mountURL: url,
                name: values?.volumeName,
                isInternal: values?.volumeIsInternal,
                isLocal: values?.volumeIsLocal,
                isRemovable: values?.volumeIsRemovable,
                isEjectable: values?.volumeIsEjectable
            )
        }
    }

    func capacity(forVolumeAt url: URL) -> VolumeSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacity
        else { return nil }
        return VolumeSpace(free: Int64(free), total: Int64(total))
    }

    func bsdName(forVolumeAt url: URL) -> String? {
        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let cString = DADiskGetBSDName(disk)
        else { return nil }
        return String(cString: cString)
    }
}

/// Popover-tier volume enumeration (TECHSPEC §3 tier 2). This type owns the
/// synchronous half: filtering, classification, and immediate resolution of
/// internal volumes. External/network volumes come back as `DeferredVolume` stubs;
/// `DeferredVolumeResolver` streams their async resolution on top of the same
/// provider seam without reshaping this API.
struct VolumeEnumerator {
    /// Everything the synchronous pass produces.
    struct Snapshot: Equatable {
        /// Fully resolved internal volumes, ready to render immediately (PRD FR3).
        let internalVolumes: [Volume]
        /// Classified external/network mounts awaiting async size resolution.
        let deferredVolumes: [DeferredVolume]
    }

    private let provider: VolumeInfoProviding

    init(provider: VolumeInfoProviding = FileManagerVolumeInfoProvider()) {
        self.provider = provider
    }

    /// Internal-volume fast path. Internal volumes are local, non-removable media
    /// whose statfs-backed reads are fast, so they resolve inline; capacity and BSD
    /// name are never requested here for external/network volumes — a hung mount
    /// cannot delay this call's per-volume work (TECHSPEC §7).
    ///
    /// Callable from any thread; the popover glue decides the queue.
    func enumerateSynchronously() -> Snapshot {
        var internalVolumes: [Volume] = []
        var deferredVolumes: [DeferredVolume] = []
        for info in provider.mountedVolumes() where Self.isUserFacing(info) {
            let name = info.name ?? info.mountURL.lastPathComponent
            let kind = Self.kind(of: info)
            switch kind {
            case .internal:
                // A user-facing internal volume with unreadable capacity has no
                // renderable row — skip it rather than showing zeros.
                guard let space = provider.capacity(forVolumeAt: info.mountURL) else { continue }
                internalVolumes.append(Volume(
                    name: name,
                    mountURL: info.mountURL,
                    totalBytes: space.total,
                    freeBytes: space.free,
                    kind: .internal,
                    bsdName: provider.bsdName(forVolumeAt: info.mountURL)
                ))
            case .external, .network:
                deferredVolumes.append(DeferredVolume(name: name, mountURL: info.mountURL, kind: kind))
            }
        }
        return Snapshot(internalVolumes: internalVolumes, deferredVolumes: deferredVolumes)
    }
}

// MARK: - Filtering & classification (pure logic)

extension VolumeEnumerator {
    /// Mount-path prefix for APFS service volumes (Preboot, Recovery, VM, Update,
    /// the raw Data volume, etc.) on the macOS 15+ baseline.
    private static let systemVolumesPrefix = "/System/Volumes"

    /// PRD Assumptions: only user-facing volumes are shown. The root presentation
    /// `/` (backed by the Data volume) is kept; everything mounted under
    /// `/System/Volumes` — including the raw `/System/Volumes/Data` mount that
    /// backs it — is a service volume and dropped. Hidden volumes never reach this
    /// filter (`.skipHiddenVolumes` in the provider).
    static func isUserFacing(_ info: VolumeInfo) -> Bool {
        let path = info.mountURL.path
        if path == "/" { return true }
        if path == systemVolumesPrefix || path.hasPrefix(systemVolumesPrefix + "/") { return false }
        return true
    }

    /// Classification (TECHSPEC §2): network = not local (wins over every other
    /// flag); internal requires an explicit internal flag and fixed media —
    /// removable/ejectable media (e.g. a card in a built-in reader) and volumes
    /// with unknown flags classify as external, so only provably-fast local fixed
    /// disks take the synchronous path.
    static func kind(of info: VolumeInfo) -> Volume.Kind {
        if info.isLocal == false { return .network }
        if info.isInternal == true, info.isRemovable != true, info.isEjectable != true {
            return .internal
        }
        return .external
    }
}
