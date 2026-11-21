import AppKit
import SwiftUI

/// Glue between the popover shell (VOL-003) and the volume-list content
/// (VOL-004): builds a fresh SwiftUI tree + view model per open via the shell's
/// content factory, starts enumeration from `onOpen`, and tears per-open state
/// down from `onClose`.
///
/// The default configuration shares one `DeferredVolumeResolver`, one
/// `SpotlightCategoryScanner`, and one `SpotlightLargestFilesScanner` across all opens
/// — the resolver's hung-read dedupe (VOL-002) and the scanners' dedicated run-loop
/// thread (SCAN-001/003) are only worth their setup cost if the instances outlive
/// individual popover sessions. The scanners are cancelled on close via the model's
/// `invalidate()`, so no query keeps gathering between opens.
///
/// It also owns the single `ScanResultCache` (A2): because the cache must outlive an
/// individual popover open to make the *next* open instant, it lives here — above the
/// per-open `VolumeListViewModel` — and is injected into every model built. The cache
/// stores results only (never a live query), so nothing queries Spotlight while the
/// popover is closed (NFR4).
@MainActor
final class VolumeListPopoverCoordinator {
    private let makeModel: () -> VolumeListViewModel
    /// Opens the Settings window from the popover's header gear (SET-003). Passed
    /// into every freshly built `VolumeListView`; nil (no-op) when unset, e.g. in
    /// tests that only exercise enumeration. Production wires the shared
    /// `SettingsWindowPresenter` here from `AppDelegate`.
    private let onOpenSettings: () -> Void
    /// The model driving the currently presented content; nil while closed.
    private var activeModel: VolumeListViewModel?
    /// Network tab (NET-002): builds the per-open section model; nil when not wired (most
    /// coordinator tests), in which case the popover has no tabs. The sampler is *not*
    /// started on open — only selecting the Network tab starts it, and close stops it.
    private let makeNetworkSection: (() -> NetworkSectionViewModel)?
    private var activeNetworkSection: NetworkSectionViewModel?

    /// Seam for tests; production uses `init()`. `onOpenSettings` defaults to a
    /// no-op so existing coordinator tests need no change.
    init(
        makeModel: @escaping () -> VolumeListViewModel,
        onOpenSettings: @escaping () -> Void = {},
        makeNetworkSection: (() -> NetworkSectionViewModel)? = nil
    ) {
        self.makeModel = makeModel
        self.onOpenSettings = onOpenSettings
        self.makeNetworkSection = makeNetworkSection
    }

    convenience init(onOpenSettings: @escaping () -> Void = {}) {
        let resolver = DeferredVolumeResolver()
        let scanner = SpotlightCategoryScanner()
        let largestFilesScanner = SpotlightLargestFilesScanner()
        // One cache for the coordinator's whole lifetime, so a reopen paints the last
        // scan's results instantly while a fresh scan runs (A2).
        let cache = ScanResultCache()
        // One ejector too (VOL-008): its DiskArbitration session is created lazily and
        // reused across opens.
        let ejector = DiskArbitrationVolumeEjector()
        // One idle sampler for the app lifetime (NET-001/002): no timer exists until the
        // popover opens, and it is stopped again on close.
        let netSampler = NetSampler()
        self.init(
            makeModel: {
                VolumeListViewModel(
                    resolver: resolver,
                    scanner: scanner,
                    largestFilesScanner: largestFilesScanner,
                    ejector: ejector,
                    cache: cache
                )
            },
            onOpenSettings: onOpenSettings,
            makeNetworkSection: { NetworkSectionViewModel.makeProduction(sampler: netSampler) }
        )
    }

    /// `PopoverController.makeContentViewController` hook: fresh model + view
    /// per open (no stale state across opens). `.preferredContentSize` keeps
    /// the popover height tracking the streaming content (TECHSPEC §8). The
    /// header gear routes through `onOpenSettings` (SET-003).
    func makeContentViewController() -> NSViewController {
        let model = makeModel()
        activeModel = model
        let network = makeNetworkSection?()
        activeNetworkSection = network
        let hosting = NSHostingController(
            rootView: VolumeListView(model: model, tabs: PopoverTabsModel(network: network), openSettings: onOpenSettings)
        )
        hosting.sizingOptions = [.preferredContentSize]
        return hosting
    }

    /// `PopoverController.onOpen` hook: fires after the content exists, before
    /// the popover shows — internal rows are already populated when it appears.
    func popoverDidOpen() {
        activeModel?.load()
    }

    /// `PopoverController.onClose` hook: undelivered resolutions are dropped and
    /// the model released alongside the shell's content teardown.
    func popoverDidClose() {
        activeModel?.invalidate()
        activeModel = nil
        // NET-002/003/004: stop the sampler and everything behind the disclosures.
        activeNetworkSection?.invalidate()
        activeNetworkSection = nil
    }
}
