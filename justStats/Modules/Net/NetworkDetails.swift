import Foundation

/// Pure mapping from the lazily-read metadata (+ the sampler's per-interface rates) to
/// the rows the expanded section draws (NET-003). Unit-tested without SwiftUI.
struct NetworkDetailsContent: Equatable {
    struct WiFiRow: Equatable {
        /// SSID when known, else the interface name ("en0").
        let title: String
        /// "Wi-Fi · ch 36 · −52 dBm" (parts omitted when unknown).
        let detail: String
        /// True when the SSID is hidden for lack of Location access: the row shows a
        /// grant button instead of blocking.
        let showsGrantAction: Bool
        let grantActionTitle: String
        /// "↓ 16 KB/s  ↑ 9.2 KB/s" for this interface, from the sampler; nil when unknown.
        let rateText: String?
    }

    /// An interface row with its own live rate (a tunnel, or a wired link).
    struct RateRow: Equatable {
        let name: String
        let downText: String
        let upText: String
    }

    struct ConnectionRow: Equatable {
        let label: String
        let value: String
    }

    let wifi: WiFiRow?
    /// Other physical links that have carried traffic (Ethernet, Thunderbolt), with rates.
    let wired: [RateRow]
    /// Tunnels carrying traffic right now, with their own rates.
    let tunnels: [RateRow]
    /// One muted line naming tunnels that are up but idle (system tunnels sit at 0 B/s).
    let idleTunnelsLine: String?
    /// One muted line for every interface that is down; never polled.
    let inactiveLine: String?
    let connection: [ConnectionRow]

    static let grantTitleNotDetermined = "Allow Location to show the network name"
    static let grantTitleDenied = "Open Location settings to show the network name"
    static let maxListedInactive = 4

    enum Phase: Equatable {
        /// Collapsed or not read yet.
        case idle
        /// Reads in flight; `metadata` is filled as soon as the (fast) read lands.
        case loading(metadata: NetworkMetadata?)
        case loaded(metadata: NetworkMetadata, latency: LatencyResult)
    }

    init(phase: Phase, permission: LocationPermission, interfaces: [InterfaceRate]) {
        let metadata: NetworkMetadata?
        var latencyRow: String
        switch phase {
        case .idle:
            metadata = nil
            latencyRow = "—"
        case .loading(let loaded):
            metadata = loaded
            latencyRow = "Checking…"
        case .loaded(let loaded, let latency):
            metadata = loaded
            switch latency {
            case .reachable(let milliseconds): latencyRow = "Online · \(Int(milliseconds.rounded())) ms"
            case .unreachable: latencyRow = "Offline"
            }
        }

        wifi = metadata?.wifi.map { Self.wifiRow($0, permission: permission, interfaces: interfaces) }
        let wifiName = metadata?.wifi?.interfaceName

        func rateRow(_ interface: InterfaceRate) -> RateRow {
            RateRow(
                name: interface.name,
                downText: RateFormat.text(bytesPerSecond: interface.rate.down),
                upText: RateFormat.text(bytesPerSecond: interface.rate.up)
            )
        }

        wired = interfaces
            .filter { $0.kind == .physical && $0.isUp && $0.name.hasPrefix("en") && $0.name != wifiName && $0.totalBytes > 0 }
            .sorted { $0.name < $1.name }
            .map(rateRow)

        let liveTunnels = interfaces.filter { $0.kind == .virtual && $0.isUp && $0.totalBytes > 0 }
        let busy = liveTunnels.filter { $0.rate.down > 0 || $0.rate.up > 0 }
        tunnels = busy.sorted { $0.name < $1.name }.map(rateRow)
        let idle = liveTunnels.filter { $0.rate.down == 0 && $0.rate.up == 0 }.map(\.name).sorted()
        if idle.isEmpty {
            idleTunnelsLine = nil
        } else {
            let listed = idle.prefix(Self.maxListedInactive).joined(separator: ", ")
            let extra = idle.count - Self.maxListedInactive
            idleTunnelsLine = "Idle tunnels: \(listed)" + (extra > 0 ? " +\(extra) more" : "")
        }

        let down = interfaces.filter { $0.kind == .physical && !$0.isUp }.map(\.name).sorted()
        if down.isEmpty {
            inactiveLine = nil
        } else {
            let listed = down.prefix(Self.maxListedInactive).joined(separator: ", ")
            let extra = down.count - Self.maxListedInactive
            inactiveLine = "Inactive: \(listed)" + (extra > 0 ? " +\(extra) more" : "")
        }

        var rows = [ConnectionRow(label: "Internet", value: latencyRow)]
        if let metadata {
            rows.append(ConnectionRow(label: "Local IP", value: metadata.localIP ?? "—"))
            rows.append(ConnectionRow(
                label: "DNS",
                value: metadata.dnsServers.isEmpty ? "—" : metadata.dnsServers.prefix(3).joined(separator: ", ")
            ))
        }
        connection = rows
    }

    private static func wifiRow(_ status: WiFiStatus, permission: LocationPermission, interfaces: [InterfaceRate]) -> WiFiRow {
        var parts = ["Wi-Fi"]
        if let channel = status.channel { parts.append("ch \(channel)") }
        if let rssi = status.rssi { parts.append("\(rssi) dBm") }
        let granted = permission == .authorized
        let title: String
        if granted, let ssid = status.ssid, !ssid.isEmpty {
            title = ssid
            parts.insert(status.interfaceName, at: 0)
        } else {
            title = status.interfaceName
        }
        let rateText = interfaces.first { $0.name == status.interfaceName }.map {
            "↓ \(RateFormat.text(bytesPerSecond: $0.rate.down))  ↑ \(RateFormat.text(bytesPerSecond: $0.rate.up))"
        }
        return WiFiRow(
            title: title,
            detail: parts.joined(separator: " · "),
            showsGrantAction: !granted,
            grantActionTitle: permission == .notDetermined ? grantTitleNotDetermined : grantTitleDenied,
            rateText: rateText
        )
    }
}

/// Drives the lazy reads behind the disclosure (NET-003). Nothing is read until
/// `begin()`; reads run off-main at `.utility`; `cancel()` (collapse / popover close)
/// drops any pending result. There is no timer: exactly one metadata read and one ICMP
/// echo per `begin()` — expand or Refresh.
@MainActor
final class NetworkDetailsModel: ObservableObject {
    @Published private(set) var phase: NetworkDetailsContent.Phase = .idle
    @Published private(set) var permission: LocationPermission

    private let metadata: NetworkMetadataProviding
    private let prober: LatencyProbing
    private let location: LocationAuthorizing
    private var generation = 0
    private var task: Task<Void, Never>?

    init(metadata: NetworkMetadataProviding, prober: LatencyProbing, location: LocationAuthorizing) {
        self.metadata = metadata
        self.prober = prober
        self.location = location
        self.permission = location.permission
    }

    /// Starts one read cycle. Requests Location lazily the first time it is still undetermined.
    @discardableResult
    func begin() -> Task<Void, Never> {
        cancel()
        if location.permission == .notDetermined { location.requestAuthorization() }
        permission = location.permission
        generation += 1
        let current = generation
        phase = .loading(metadata: nil)
        let metadata = self.metadata
        let prober = self.prober
        let newTask = Task.detached(priority: .utility) { [weak self] in
            let read = metadata.read()
            if Task.isCancelled { return }
            await self?.apply(.loading(metadata: read), generation: current)
            let latency = prober.ping()
            if Task.isCancelled { return }
            await self?.apply(.loaded(metadata: read, latency: latency), generation: current)
        }
        task = newTask
        return newTask
    }

    /// Collapse / popover close: pending work is dropped and nothing is published afterwards.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        if phase != .idle { phase = .idle }
    }

    /// Re-reads the permission after the user returns from System Settings or the prompt.
    func refreshPermission() {
        permission = location.permission
    }

    private func apply(_ newPhase: NetworkDetailsContent.Phase, generation: Int) {
        guard generation == self.generation else { return }
        permission = location.permission
        phase = newPhase
    }
}
