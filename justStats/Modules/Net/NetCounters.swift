import Darwin
import Foundation

/// One interface's cumulative counters at a single read (NET-001). Monotonic since
/// boot (the kernel's 64-bit `if_data64` counters), so a rate is always a delta
/// between two reads and "since boot" totals need no accumulation work.
struct InterfaceCounters: Equatable {
    let name: String
    /// Cumulative bytes received / sent since boot.
    let rxBytes: UInt64
    let txBytes: UInt64
    /// Link rate in bits per second as the driver reports it (0 = unknown).
    let baudrate: UInt64
    /// `IFF_UP && IFF_RUNNING` at read time (NET-003 uses it to find down interfaces).
    let isUp: Bool

    init(name: String, rxBytes: UInt64, txBytes: UInt64, baudrate: UInt64 = 0, isUp: Bool = true) {
        self.name = name
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.baudrate = baudrate
        self.isUp = isUp
    }
}

/// Where the counters come from. The sysctl call is a thin layer behind this seam so
/// the whole delta/clamp/filter core is testable with fake feeds (NET-001).
protocol NetCounterSource {
    func readCounters() -> [InterfaceCounters]
}

/// How an interface is treated by the aggregate rate and totals.
enum NetInterfaceKind: Equatable {
    /// Real hardware (en*, bridge*, awdl*, ...): feeds the headline rates and totals.
    case physical
    /// VPN / tunnel style interface: keeps its own counters and row, never merged
    /// into the physical aggregate (NET-001, NET-003 tunnels).
    case virtual
    /// Loopback: local traffic, excluded from both.
    case loopback

    /// Name prefixes of virtual interfaces (NET-001 owner list).
    static let virtualPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "wg"]

    static func kind(forName name: String) -> NetInterfaceKind {
        if name.hasPrefix("lo") { return .loopback }
        if virtualPrefixes.contains(where: { name.hasPrefix($0) }) { return .virtual }
        return .physical
    }
}

/// Production counter source: `sysctl([CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0])`
/// parsed for `RTM_IFINFO2` messages (`if_msghdr2` → 64-bit byte counters). Microseconds
/// per read; it takes no locks and touches no network, so it is safe on the main thread.
struct SysctlNetCounterSource: NetCounterSource {
    func readCounters() -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }
        // The table can grow between the size query and the read; retry once with slack.
        var buffer = [UInt8](repeating: 0, count: length + length / 8)
        length = buffer.count
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [] }

        var result: [InterfaceCounters] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0, offset + size <= length else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   size >= MemoryLayout<if_msghdr2>.size {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let flags = Int32(info.ifm_flags)
                        result.append(InterfaceCounters(
                            name: String(cString: nameBuffer),
                            rxBytes: info.ifm_data.ifi_ibytes,
                            txBytes: info.ifm_data.ifi_obytes,
                            baudrate: info.ifm_data.ifi_baudrate,
                            isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0
                        ))
                    }
                }
                offset += size
            }
        }
        return result
    }
}
