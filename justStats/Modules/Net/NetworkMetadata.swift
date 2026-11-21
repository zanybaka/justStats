import CoreLocation
import CoreWLAN
import Foundation
import SystemConfiguration

// Metadata sources for the expanded network details (NET-003). Everything here is a
// blocking read meant to run off the main thread, and none of it touches the network
// except the single ICMP echo in `ICMPLatencyProbe`.

/// The Wi-Fi interface as CoreWLAN reports it. `ssid` is nil unless Location access
/// has been granted (macOS 14+).
struct WiFiStatus: Equatable {
    let interfaceName: String
    let ssid: String?
    let channel: Int?
    let rssi: Int?
}

struct NetworkMetadata: Equatable {
    let wifi: WiFiStatus?
    let localIP: String?
    let dnsServers: [String]
}

protocol NetworkMetadataProviding {
    /// One blocking read of Wi-Fi, local IP and DNS. Called once per expand/Refresh.
    func read() -> NetworkMetadata
}

enum LatencyResult: Equatable {
    case reachable(milliseconds: Double)
    case unreachable
}

protocol LatencyProbing {
    /// Exactly one ICMP echo, blocking up to its timeout.
    func ping() -> LatencyResult
}

enum LocationPermission: Equatable {
    case notDetermined
    case denied
    case authorized
}

protocol LocationAuthorizing: AnyObject {
    var permission: LocationPermission { get }
    /// Shows the system prompt. Only called lazily, from the first expand.
    func requestAuthorization()
}

// MARK: - Production implementations

struct SystemNetworkMetadataProvider: NetworkMetadataProviding {
    func read() -> NetworkMetadata {
        NetworkMetadata(wifi: readWiFi(), localIP: readLocalIP(), dnsServers: readDNS())
    }

    private func readWiFi() -> WiFiStatus? {
        guard let interface = CWWiFiClient.shared().interface(),
              let name = interface.interfaceName,
              interface.powerOn() else { return nil }
        let rssi = interface.rssiValue()
        return WiFiStatus(
            interfaceName: name,
            ssid: interface.ssid(),
            channel: interface.wlanChannel()?.channelNumber,
            // CoreWLAN reports 0 when not associated.
            rssi: rssi == 0 ? nil : rssi
        )
    }

    private func readLocalIP() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "justStats" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String,
              let state = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(primary)/IPv4" as CFString) as? [String: Any],
              let addresses = state["Addresses"] as? [String] else { return nil }
        return addresses.first
    }

    private func readDNS() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "justStats" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        else { return [] }
        return dns["ServerAddresses"] as? [String] ?? []
    }
}

/// One ICMP echo request to a well-known anycast address, over an unprivileged
/// `SOCK_DGRAM`/`IPPROTO_ICMP` socket (no root, no helper). The only network request the
/// module ever makes: one per expand or Refresh, never periodic. No public-IP lookup.
struct ICMPLatencyProbe: LatencyProbing {
    static let target = "1.1.1.1"
    static let timeoutSeconds = 2

    func ping() -> LatencyResult {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return .unreachable }
        defer { close(fd) }

        var timeout = timeval(tv_sec: Self.timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, Self.target, &address.sin_addr) == 1 else { return .unreachable }

        let sequence = UInt16.random(in: 1...UInt16.max)
        let packet = Self.echoRequest(identifier: UInt16(truncatingIfNeeded: getpid()), sequence: sequence)
        let started = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return .unreachable }

        var reply = [UInt8](repeating: 0, count: 256)
        let deadline = started + UInt64(Self.timeoutSeconds) * 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let received = recv(fd, &reply, reply.count, 0)
            if received < 0 { return .unreachable }  // timeout or error
            if Self.isMatchingReply(Array(reply.prefix(received)), sequence: sequence) {
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                return .reachable(milliseconds: Double(elapsed) / 1_000_000)
            }
        }
        return .unreachable
    }

    /// ICMP echo request (type 8) with an 8-byte payload and a valid checksum.
    static func echoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                               UInt8(sequence >> 8), UInt8(sequence & 0xFF),
                               0x6A, 0x53, 0x74, 0x61, 0x74, 0x73, 0x00, 0x00]
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    /// The datagram socket may hand back the IP header too; skip it, then require an echo
    /// reply (type 0) carrying our sequence number (the kernel may rewrite the identifier).
    static func isMatchingReply(_ datagram: [UInt8], sequence: UInt16) -> Bool {
        var offset = 0
        if let first = datagram.first, first >> 4 == 4 { offset = Int(first & 0x0F) * 4 }
        guard datagram.count >= offset + 8, datagram[offset] == 0 else { return false }
        let replySequence = UInt16(datagram[offset + 6]) << 8 | UInt16(datagram[offset + 7])
        return replySequence == sequence
    }
}

/// Lazy Location request (NET-003): the SSID needs Location authorization on modern
/// macOS, so the prompt appears on the first expand — never at launch — following the
/// SCAN-006 Full Disk Access pattern. Without it the Wi-Fi row degrades to the interface
/// name plus a grant path.
final class SystemLocationAuthorizer: NSObject, LocationAuthorizing {
    private var manager: CLLocationManager?

    var permission: LocationPermission {
        switch (manager ?? CLLocationManager()).authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorizedAlways, .authorized: return .authorized
        default: return .denied
        }
    }

    func requestAuthorization() {
        // Keep the manager alive until the user answers the prompt.
        let manager = self.manager ?? CLLocationManager()
        self.manager = manager
        manager.requestWhenInUseAuthorization()
    }
}
