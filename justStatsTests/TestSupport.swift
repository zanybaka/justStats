import XCTest
@testable import justStats

/// Test double for `VolumeSpaceReading` returning a fixed result, or `nil` to
/// simulate a failed read. Shared by the reader and icon-controller tests.
struct MockVolumeSpaceReader: VolumeSpaceReading {
    var result: VolumeSpace?
    func readBootVolume() -> VolumeSpace? { result }
}

/// Test double for `VolumeInfoProviding` serving canned volume facts, capacities,
/// and BSD names keyed by mount URL. A class so tests can assert which volumes had
/// capacity/BSD-name reads (the deferred kinds must never trigger them — the
/// hung-mount isolation invariant VOL-002 builds on).
final class MockVolumeInfoProvider: VolumeInfoProviding {
    var volumes: [VolumeInfo] = []
    var capacities: [URL: VolumeSpace] = [:]
    var bsdNames: [URL: String] = [:]
    private(set) var capacityRequests: [URL] = []
    private(set) var bsdNameRequests: [URL] = []

    func mountedVolumes() -> [VolumeInfo] { volumes }

    func capacity(forVolumeAt url: URL) -> VolumeSpace? {
        capacityRequests.append(url)
        return capacities[url]
    }

    func bsdName(forVolumeAt url: URL) -> String? {
        bsdNameRequests.append(url)
        return bsdNames[url]
    }
}

/// Thread-safe `VolumeInfoProviding` double whose capacity reads can be made to
/// hang per mount URL — simulates a dead network mount for the VOL-002 hung-mount
/// isolation tests. A hung read blocks on a per-URL gate semaphore until the test
/// (or teardown, via `releaseAllHangs`) signals it.
final class HangingVolumeInfoProvider: VolumeInfoProviding {
    private let lock = NSLock()
    private var volumes: [VolumeInfo] = []
    private var capacities: [URL: VolumeSpace] = [:]
    private var bsdNames: [URL: String] = [:]
    private var gates: [URL: DispatchSemaphore] = [:]
    private var capacityRequestCounts: [URL: Int] = [:]
    private var mainThreadCapacityReadURLs: [URL] = []

    // MARK: Test configuration

    func setMountedVolumes(_ infos: [VolumeInfo]) {
        withLock { volumes = infos }
    }

    func setCapacity(_ space: VolumeSpace, for url: URL) {
        withLock { capacities[url] = space }
    }

    func setBSDName(_ name: String, for url: URL) {
        withLock { bsdNames[url] = name }
    }

    /// Makes every capacity read for `url` block until the returned gate is
    /// signalled (once per blocked read).
    @discardableResult
    func hangCapacityReads(for url: URL) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        withLock { gates[url] = gate }
        return gate
    }

    /// Unblocks any reads still parked on hang gates. Call from teardown so no
    /// blocked global-queue thread outlives the test.
    func releaseAllHangs() {
        let gates = withLock { Array(self.gates.values) }
        for gate in gates {
            for _ in 0..<32 { gate.signal() } // over-signalling a semaphore is safe
        }
    }

    // MARK: Test assertions

    func capacityRequestCount(for url: URL) -> Int {
        withLock { capacityRequestCounts[url] ?? 0 }
    }

    /// Mount URLs whose capacity was read on the main thread. Deferred volumes
    /// must never appear here (TECHSPEC §3 tier 2 forbids filesystem calls on
    /// main in the async path); the synchronous pass may, when a test itself
    /// invokes it on main.
    var capacityReadsOnMainThread: [URL] {
        withLock { mainThreadCapacityReadURLs }
    }

    // MARK: VolumeInfoProviding

    func mountedVolumes() -> [VolumeInfo] {
        withLock { volumes }
    }

    func capacity(forVolumeAt url: URL) -> VolumeSpace? {
        lock.lock()
        capacityRequestCounts[url, default: 0] += 1
        if Thread.isMainThread { mainThreadCapacityReadURLs.append(url) }
        let gate = gates[url]
        let result = capacities[url]
        lock.unlock()
        gate?.wait() // outside the lock: a hung read must not block other volumes
        return result
    }

    func bsdName(forVolumeAt url: URL) -> String? {
        withLock { bsdNames[url] }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Test double for `DeferredVolumeResolving`: records requests and lets tests
/// stream resolutions synchronously (production delivers on the main queue;
/// tests call `deliver` from the main thread to match).
final class MockDeferredVolumeResolver: DeferredVolumeResolving {
    private(set) var resolveRequests: [[DeferredVolume]] = []
    private(set) var invalidateCount = 0
    private var onResult: ((DeferredVolumeResolution) -> Void)?

    func resolve(_ volumes: [DeferredVolume], onResult: @escaping (DeferredVolumeResolution) -> Void) {
        resolveRequests.append(volumes)
        self.onResult = onResult
    }

    func invalidate() {
        invalidateCount += 1
        onResult = nil
    }

    /// Simulates one VOL-002 streamed delivery into the latest `resolve` call.
    func deliver(_ resolution: DeferredVolumeResolution) {
        onResult?(resolution)
    }
}

/// Test double for `CategoryScanning` (SCAN-001): records scan/cancel requests and
/// lets tests deliver a `CategoryBreakdown` synchronously into the latest scan.
/// No real Spotlight — the whole point of the seam. Mirrors
/// `MockDeferredVolumeResolver`; production delivers on the main queue, so tests
/// call `deliver` from the main thread to match.
final class MockCategoryScanner: CategoryScanning {
    private(set) var scanRequests: [URL] = []
    private(set) var cancelCount = 0
    /// Every scan's delivery closure, in `scan` call order — so a test can replay an
    /// older scan's result (a stale delivery) after a newer `scan` supersedes it,
    /// mirroring the real scanner where a late notification can still fire.
    private var callbacks: [(CategoryBreakdown) -> Void] = []
    /// The current (latest, uncancelled) scan's closure. `deliver` uses this so a
    /// `cancel()` drops the pending delivery — matching the seam contract that a
    /// cancelled scan never delivers.
    private var current: ((CategoryBreakdown) -> Void)?

    func scan(volumeURL: URL, onResult: @escaping (CategoryBreakdown) -> Void) {
        scanRequests.append(volumeURL)
        callbacks.append(onResult)
        current = onResult
    }

    func cancel() {
        cancelCount += 1
        current = nil // a cancelled scan must not deliver (seam contract)
    }

    /// Simulates the scanner delivering its breakdown into the latest, uncancelled
    /// `scan` call. A no-op after `cancel()` (the pending delivery was dropped).
    func deliver(_ breakdown: CategoryBreakdown) {
        current?(breakdown)
    }

    /// Delivers into the scan at `index` (0-based, in `scan` call order) regardless
    /// of cancellation — used to replay a *stale* late delivery from an earlier,
    /// superseded scan (the model's own generation guard must drop it).
    func deliver(_ breakdown: CategoryBreakdown, toScanAt index: Int) {
        guard callbacks.indices.contains(index) else { return }
        callbacks[index](breakdown)
    }
}

/// Test double for `FullDiskAccessSettingsOpening` (SCAN-006): records how many
/// times the Full Disk Access pane would have been opened, without launching System
/// Settings. The real deep link is verified manually — the seam exists so the notice
/// button's *wiring* is unit-testable.
final class MockFullDiskAccessSettingsOpener: FullDiskAccessSettingsOpening {
    private(set) var openCount = 0
    func openFullDiskAccessSettings() { openCount += 1 }
}

/// Inert `LargestFilesScanning` double (ACT-001) shared across view-model-building
/// tests. Its whole purpose is to keep a `VolumeListViewModel` hermetic: `load()` now
/// starts a largest-files scan through this seam, so any test that builds a model and
/// isn't exercising the largest-files section must inject this to avoid spinning up a
/// real `NSMetadataQuery` (the SCAN-001/003 "no real Spotlight in tests" rule). It
/// records scan/cancel calls and can deliver a canned result on demand.
final class MockLargestFilesScanner: LargestFilesScanning {
    private(set) var scanRequests: [(url: URL, limit: Int)] = []
    private(set) var cancelCount = 0
    private var onPartial: (([LargestFile]) -> Void)?
    private var onResult: ((LargestFilesResult) -> Void)?

    func scan(
        volumeURL: URL,
        limit: Int,
        onPartial: @escaping ([LargestFile]) -> Void,
        onResult: @escaping (LargestFilesResult) -> Void
    ) {
        scanRequests.append((url: volumeURL, limit: limit))
        self.onPartial = onPartial
        self.onResult = onResult
    }

    func cancel() {
        cancelCount += 1
        onPartial = nil
        onResult = nil
    }

    /// Delivers a progressive best-so-far partial into the latest, uncancelled scan.
    func deliverPartial(_ files: [LargestFile]) {
        onPartial?(files)
    }

    /// Delivers the final result into the latest, uncancelled scan. A no-op after `cancel()`.
    func deliver(_ result: LargestFilesResult) {
        onResult?(result)
    }
}

/// Test double for `FileTrashing` (ACT-002): records the URLs it was asked to trash
/// and, per the test's configuration, either succeeds (recording the URL) or throws a
/// canned error to exercise the inline error path. It never touches the real
/// filesystem — no test moves a real file to the Trash (TECHSPEC §7 destructive-action
/// discipline extended to tests). There is no permanent-delete method here, mirroring
/// the production seam: a test literally cannot express one.
final class MockFileTrasher: FileTrashing {
    /// URLs the trasher was asked to move to the Trash, in call order — including ones
    /// that then threw (the *attempt* is recorded before the outcome).
    private(set) var trashRequests: [URL] = []
    /// When non-nil, every `trash` call throws this error instead of succeeding — the
    /// locked-file / permission-denied path (ACT-002 error surfacing).
    var errorToThrow: Error?
    /// URLs to fail for, when only *some* files should throw; overrides `errorToThrow`
    /// scoping. If a URL is a key here, its `trash` throws that error; otherwise the
    /// call succeeds. Empty by default (use `errorToThrow` for a blanket failure).
    var perURLErrors: [URL: Error] = [:]

    func trash(_ url: URL) throws {
        trashRequests.append(url)
        if let error = perURLErrors[url] { throw error }
        if let errorToThrow { throw errorToThrow }
    }
}

/// In-memory `HiddenFilesStoring` double (UX-015): holds the hidden set in a plain `Set`
/// so view-model tests exercise the filter/hide/unhide logic without touching real
/// `UserDefaults`. Mirrors the production store's semantics (idempotent hide/unhide,
/// clear) but never persists — the persistence itself is covered by `HiddenFilesStoreTests`
/// against an isolated defaults suite. Seedable via `init` so a test can start with a
/// path already hidden ("hidden survives a reopen" from the model's side).
@MainActor
final class MockHiddenFilesStore: HiddenFilesStoring {
    private(set) var hiddenPaths: Set<String>

    /// `nonisolated` so it works as a default argument in the (main-actor) test helpers —
    /// default-argument expressions evaluate in a nonisolated context, mirroring the
    /// production `HiddenFilesStore.init`.
    nonisolated init(hidden: Set<String> = []) {
        hiddenPaths = hidden
    }

    func hide(_ path: String) { hiddenPaths.insert(path) }
    func unhide(_ path: String) { hiddenPaths.remove(path) }
    func clear() { hiddenPaths.removeAll() }
}

/// Test double for `LaunchAtLoginControlling` (SET-002). Simulates `SMAppService`
/// registration in memory: `enable()`/`disable()` flip a backing flag (unless configured
/// to throw), and `isEnabled` reads that flag back — mirroring the production seam where
/// `isEnabled` reflects the *real* status rather than a cached optimistic bool. It never
/// touches the user's actual Login Items (real registration is manual to verify).
final class MockLaunchAtLoginController: LaunchAtLoginControlling {
    /// The simulated registration status `isEnabled` reports. Seeded via `init` for the
    /// "toggle reads initial state from status" test; mutated by `enable()`/`disable()`.
    private var registered: Bool

    /// When non-nil, `enable()` throws this instead of registering — the failed-register
    /// path that must leave the toggle reflecting the true (still-off) status.
    var enableError: Error?
    /// When non-nil, `disable()` throws this instead of unregistering.
    var disableError: Error?

    /// When non-nil, `isEnabled` returns this fixed value *after* a successful
    /// enable/disable instead of the flag the call set — models the system landing in a
    /// non-`.enabled` state (e.g. awaiting approval) so the toggle must snap back to the
    /// real status rather than the value the user picked.
    var forcedStatusAfterChange: Bool?

    private(set) var enableCount = 0
    private(set) var disableCount = 0

    init(initiallyEnabled: Bool = false) {
        registered = initiallyEnabled
    }

    var isEnabled: Bool { registered }

    func enable() throws {
        enableCount += 1
        if let enableError { throw enableError }
        registered = forcedStatusAfterChange ?? true
    }

    func disable() throws {
        disableCount += 1
        if let disableError { throw disableError }
        registered = forcedStatusAfterChange ?? false
    }
}

/// Test double for `SoftwareUpdating` (UPD-001). Records how many times a user-initiated
/// update check was requested and holds the automatic-check flag in memory, mirroring the
/// production seam where `automaticallyChecksForUpdates` reflects the real (Sparkle-)
/// persisted value. It never touches Sparkle or the network — the whole point of the seam
/// is that the UI wiring is testable without a real update check.
@MainActor
final class MockSoftwareUpdater: SoftwareUpdating {
    private(set) var checkForUpdatesCount = 0
    /// Backing value for `automaticallyChecksForUpdates`; seeded via `init` so a test can
    /// assert the model hydrates its toggle from the seam's current value.
    var automaticallyChecksForUpdates: Bool

    init(automaticallyChecksForUpdates: Bool = false) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        checkForUpdatesCount += 1
    }
}

extension XCTestCase {
    /// Fresh `UserDefaults` suite isolated per test class + function, wiped before
    /// use and again on teardown, so the standard domain is never touched.
    func makeIsolatedDefaults(function: String = #function) -> UserDefaults {
        let suiteName = "justStatsTests.\(type(of: self)).\(function)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
