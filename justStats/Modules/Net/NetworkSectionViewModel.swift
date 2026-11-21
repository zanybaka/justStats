import Foundation

/// Owns the Network tab's lifecycle and the two disclosures' expansion state
/// (NET-002…004). One instance per popover open; the long-lived `NetSampler` is shared.
///
/// Nothing network-related runs until the Network tab is selected (`activate()`): the
/// default Disks tab never touches it. While active, the sampler ticks; the Interfaces
/// disclosure adds one metadata read + ICMP echo per expand/Refresh; the Top processes
/// disclosure adds the `nettop` loop. Leaving the tab or closing the popover stops all of it.
@MainActor
final class NetworkSectionViewModel: ObservableObject {
    /// True while the Network tab is the one shown (and the popover is open).
    @Published private(set) var isActive = false
    @Published private(set) var isInterfacesExpanded = false
    @Published private(set) var isProcessesExpanded = false

    let sampler: NetSampler
    let details: NetworkDetailsModel
    let processes: ProcessTrafficModel
    private let sampling: NetworkSampling
    private var isInvalidated = false

    /// `sampling` defaults to the sampler itself; tests inject a lifecycle spy.
    init(sampler: NetSampler, details: NetworkDetailsModel, processes: ProcessTrafficModel,
         sampling: NetworkSampling? = nil) {
        self.sampler = sampler
        self.details = details
        self.processes = processes
        self.sampling = sampling ?? sampler
    }

    /// Production wiring around the shared sampler.
    static func makeProduction(sampler: NetSampler) -> NetworkSectionViewModel {
        NetworkSectionViewModel(
            sampler: sampler,
            details: NetworkDetailsModel(
                metadata: SystemNetworkMetadataProvider(),
                prober: ICMPLatencyProbe(),
                location: SystemLocationAuthorizer()
            ),
            processes: ProcessTrafficModel()
        )
    }

    // MARK: Tab lifecycle

    /// The Network tab was selected: start sampling.
    func activate() {
        guard !isInvalidated, !isActive else { return }
        isActive = true
        sampling.start()
    }

    /// Another tab was selected: collapse everything and stop sampling.
    func deactivate() {
        guard isActive else { return }
        collapseInterfaces()
        collapseProcesses()
        isActive = false
        sampling.stop()
    }

    /// Popover closed: stop everything and refuse further activation.
    func invalidate() {
        isInvalidated = true
        deactivate()
    }

    // MARK: Interfaces disclosure (NET-003)

    func toggleInterfaces() {
        isInterfacesExpanded ? collapseInterfaces() : expandInterfaces()
    }

    func expandInterfaces() {
        guard isActive, !isInterfacesExpanded else { return }
        isInterfacesExpanded = true
        details.begin()
    }

    func collapseInterfaces() {
        isInterfacesExpanded = false
        details.cancel()
    }

    /// Manual Refresh inside the Interfaces disclosure: one more metadata read and one ICMP echo.
    func refreshDetails() {
        guard isInterfacesExpanded else { return }
        details.begin()
    }

    // MARK: Top processes disclosure (NET-004)

    func toggleProcesses() {
        isProcessesExpanded ? collapseProcesses() : expandProcesses()
    }

    func expandProcesses() {
        guard isActive, !isProcessesExpanded else { return }
        isProcessesExpanded = true
        processes.start()
    }

    func collapseProcesses() {
        isProcessesExpanded = false
        processes.stop()
    }

    func resetTotals() {
        sampler.resetTotals()
    }
}

enum PopoverTab: String, CaseIterable, Identifiable {
    case disks = "Disks"
    case network = "Network"
    var id: String { rawValue }
}

/// Which tab the popover shows. Always opens on Disks, so a fresh open never starts any
/// network work; selecting Network activates the section, leaving it deactivates.
@MainActor
final class PopoverTabsModel: ObservableObject {
    @Published private(set) var selected: PopoverTab = .disks
    let network: NetworkSectionViewModel?

    init(network: NetworkSectionViewModel?) {
        self.network = network
    }

    /// The tab picker only exists when the Network tab does.
    var showsTabs: Bool { network != nil }

    func select(_ tab: PopoverTab) {
        guard tab != selected else { return }
        if tab == .network, network == nil { return }
        selected = tab
        if tab == .network { network?.activate() } else { network?.deactivate() }
    }
}
