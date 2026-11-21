import DiskArbitration
import Darwin
import Foundation

/// The process that refused to let a volume unmount (VOL-008): the DiskArbitration
/// dissenter's PID plus its short process name when it could be resolved.
struct EjectHolder: Equatable {
    let pid: Int32
    /// Short process name (`mds_stores`, `Finder`); `nil` when the process is already
    /// gone or its name could not be read.
    let processName: String?
}

/// How one eject attempt ended (VOL-008). The ejector reports this on the main queue.
enum EjectResult: Equatable {
    /// The volume (and, for a multi-volume disk, every volume on it) unmounted.
    case success
    /// The system refused because something is using the volume (EBUSY). `holder` is
    /// the dissenting process when DiskArbitration named one, `nil` otherwise.
    case refused(holder: EjectHolder?)
    /// Any other failure (permission, unsupported, vanished mount). `reason` is a short
    /// human string, never a raw status code alone.
    case failed(reason: String)
}

/// Seam between the view model and the OS unmount machinery (VOL-008, ADR-007), mockable
/// like `VolumeInfoProviding`: view-model tests drive refusal, retry and force without a
/// real mount. The production conformance is `DiskArbitrationVolumeEjector`.
protocol VolumeEjecting: AnyObject {
    /// Unmounts the volume at `url` — and ejects the whole disk it lives on, like
    /// Finder. `force` re-issues the unmount with the force option (data the holder is
    /// writing can be lost). `completion` is always delivered on the main queue.
    func eject(volumeAt url: URL, force: Bool, completion: @escaping (EjectResult) -> Void)
}

/// What the refusal panel shows (VOL-008): the message naming the volume and holder, an
/// optional hint, and the warning that precedes a forced eject.
struct EjectRefusal: Equatable {
    let message: String
    let hint: String?
    let warning: String
}

/// Human wording for eject outcomes (VOL-008). Pure and static so every dictionary
/// entry and the unknown-process fallback are covered by plain unit tests (UI is
/// English-only, PRD).
enum EjectMessages {
    /// Known system holders → short phrase, keyed by process name. A process missing
    /// here falls back to its honest name and PID, never to a guess.
    static let knownHolderPhrases: [String: String] = [
        "mds_stores": "Spotlight indexing, usually releases in a minute or two",
        "rsync": "file copy in progress",
        "backupd": "Time Machine backup",
        "Finder": "Finder has this disk or its files open",
        "photoanalysisd": "Photos analyzing",
    ]

    /// The phrase naming `holder`: a known system phrase, or "process <name> (PID <n>)".
    static func holderPhrase(for holder: EjectHolder) -> String {
        if let name = holder.processName, let phrase = knownHolderPhrases[name] {
            return phrase
        }
        if let name = holder.processName, !name.isEmpty {
            return "process \(name) (PID \(holder.pid))"
        }
        return "process (PID \(holder.pid))"
    }

    /// Inline text for a refusal. Names the volume the user pressed Eject on and the
    /// holder; a multi-volume stick is ejected as a whole, so the text says so.
    static func refusal(volumeName: String, holder: EjectHolder?) -> String {
        guard let holder else {
            return "Can’t eject “\(volumeName)”: a program is using it."
        }
        return "Can’t eject “\(volumeName)”: \(holderPhrase(for: holder))."
    }

    /// Holders whose forced eject puts no user data at risk: Spotlight only writes its
    /// own index (`.Spotlight-V100`) on the disk, which is rebuilt on demand.
    static let lowRiskForceHolders: Set<String> = ["mds_stores"]

    /// Everything the refusal panel shows for `holder`: the message, an optional hint
    /// under it (only where Force is known to be low risk) and the warning shown before
    /// a forced eject. The generic warning always applies to every other holder.
    static func refusalDetails(volumeName: String, holder: EjectHolder?) -> EjectRefusal {
        let message = refusal(volumeName: volumeName, holder: holder)
        if let name = holder?.processName, lowRiskForceHolders.contains(name) {
            return EjectRefusal(message: message, hint: spotlightForceHint, warning: spotlightForceWarning)
        }
        return EjectRefusal(message: message, hint: nil, warning: forceWarning)
    }

    /// Shown under a Spotlight refusal: Force is safe here, and Retry usually works too.
    static let spotlightForceHint =
        "Force Eject is safe here: Spotlight only writes its own index, which may need rebuilding."

    /// Shown before a forced eject while Spotlight holds the volume.
    static let spotlightForceWarning =
        "Only Spotlight’s index on this disk may be left unfinished and rebuilt next time. Your files are not affected."

    static func failure(volumeName: String, reason: String) -> String {
        "Can’t eject “\(volumeName)”: \(reason)"
    }

    /// Shown before a forced eject is issued; always present (the holder may be writing).
    static let forceWarning =
        "Forcing can lose data the program is still writing. Force eject only if you accept that."
}

/// Production `VolumeEjecting`: `DADiskUnmount` on the whole disk (so a multi-volume
/// stick ejects together, like Finder), then a best-effort `DADiskEject`. Network
/// mounts have no DiskArbitration disk and go through `FileManager.unmountVolume`.
///
/// **The dissenter PID.** On refusal the completion callback carries a `DADissenter`.
/// The public SDK exposes only its status (`EBUSY`, no string), but `diskutil` names the
/// holder, and the framework exports `DADissenterGetProcessID` for it — missing from the
/// public headers. It is resolved with `dlsym` at runtime, so a future macOS that drops
/// the symbol degrades to "a program is using it" instead of failing to launch
/// (ADR-007). No sudo, no `lsof` parsing.
final class DiskArbitrationVolumeEjector: VolumeEjecting {
    /// Heap box carrying the Swift completion through DiskArbitration's C context.
    private final class CallbackBox {
        let handle: (DADissenter?) -> Void
        init(_ handle: @escaping (DADissenter?) -> Void) { self.handle = handle }
    }

    private typealias GetProcessID = @convention(c) (DADissenter) -> Int32

    /// `DADissenterGetProcessID`, or `nil` if this macOS does not export it.
    private static let getProcessID: GetProcessID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "DADissenterGetProcessID")
        else { return nil }
        return unsafeBitCast(symbol, to: GetProcessID.self)
    }()

    /// Created lazily on the first eject so merely constructing a view model (every
    /// popover open, every test) costs nothing.
    private lazy var session: DASession? = {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        DASessionSetDispatchQueue(session, queue)
        return session
    }()

    private let queue = DispatchQueue(label: QueueLabels.volumeEject, qos: .userInitiated)

    init() {}

    func eject(volumeAt url: URL, force: Bool, completion: @escaping (EjectResult) -> Void) {
        let deliver: (EjectResult) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        queue.async { [self] in
            guard let session,
                  let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL)
            else {
                // No DiskArbitration disk: a network mount (SMB/NFS/AFP).
                unmountNetworkVolume(at: url, force: force, deliver: deliver)
                return
            }
            let whole = DADiskCopyWholeDisk(disk) ?? disk
            var options = DADiskUnmountOptions(kDADiskUnmountOptionWhole)
            if force { options |= DADiskUnmountOptions(kDADiskUnmountOptionForce) }
            let box = CallbackBox { dissenter in
                guard let dissenter else {
                    // Unmounted. Powering the media off is best effort: the volumes are
                    // already gone from the list via didUnmount, which is what matters.
                    DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), nil, nil)
                    deliver(.success)
                    return
                }
                deliver(Self.result(for: dissenter))
            }
            DADiskUnmount(whole, options, { _, dissenter, context in
                guard let context else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(context).takeRetainedValue()
                box.handle(dissenter)
            }, Unmanaged.passRetained(box).toOpaque())
        }
    }

    /// Maps a dissenter to the outcome: EBUSY (or DiskArbitration's own busy code) is a
    /// refusal naming the holder; everything else is a generic failure.
    private static func result(for dissenter: DADissenter) -> EjectResult {
        let status = DADissenterGetStatus(dissenter)
        let isBusy = status == DAReturn(kDAReturnBusy) || status == Self.unixBusyStatus
        guard isBusy else {
            let text = (DADissenterGetStatusString(dissenter) as String?) ?? "the system refused (code \(status))"
            return .failed(reason: text)
        }
        guard let getProcessID else { return .refused(holder: nil) }
        let pid = getProcessID(dissenter)
        guard pid > 0 else { return .refused(holder: nil) }
        return .refused(holder: EjectHolder(pid: pid, processName: processName(pid: pid)))
    }

    /// `EBUSY` as DiskArbitration reports it: a Unix errno wrapped in the `err_local`
    /// system/subsystem bits (0xc000 | errno), observed as 0xc010 on macOS 15.
    private static let unixBusyStatus = DAReturn(0xc000 | UInt32(EBUSY))

    /// Short name of a process, root daemons included. `proc_name` is refused for
    /// other users' processes (it returns nothing for `mds_stores`, the usual holder),
    /// so `sysctl(kern.proc.pid)` — readable for every process — is the fallback; it
    /// reports the 16-character kernel command name, enough for the phrase dictionary.
    static func processName(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        var comm = info.kp_proc.p_comm
        let name = withUnsafePointer(to: &comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
        return name.isEmpty ? nil : name
    }

    private func unmountNetworkVolume(
        at url: URL, force: Bool, deliver: @escaping (EjectResult) -> Void
    ) {
        if force {
            // FileManager has no force option; MNT_FORCE via unmount(2) is the equivalent.
            if Darwin.unmount(url.path, MNT_FORCE) == 0 {
                deliver(.success)
            } else {
                deliver(.failed(reason: String(cString: strerror(errno))))
            }
            return
        }
        FileManager.default.unmountVolume(at: url, options: [.withoutUI]) { error in
            guard let error else { deliver(.success); return }
            let nsError = error as NSError
            // EBUSY on a network mount names no holder: report it honestly as busy.
            let isBusy = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EBUSY)
                || nsError.code == Int(EBUSY)
            deliver(isBusy ? .refused(holder: nil) : .failed(reason: error.localizedDescription))
        }
    }
}
