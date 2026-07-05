import XCTest
@testable import justStats

final class DeferredVolumeResolverTests: XCTestCase {
    // MARK: - Helpers

    /// Timeout for events that MUST happen — generous so CI load can't flake it.
    private let eventTimeout: TimeInterval = 5
    /// Wait for inverted expectations (events that must NOT happen).
    private let quietTimeout: TimeInterval = 0.5
    /// Resolver timeout for tests where the row timeout must NEVER fire.
    private let neverFires: TimeInterval = 60

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private func usbStub() -> DeferredVolume {
        DeferredVolume(name: "USB", mountURL: url("/Volumes/USB"), kind: .external)
    }

    private func nasStub() -> DeferredVolume {
        DeferredVolume(name: "NAS", mountURL: url("/Volumes/NAS"), kind: .network)
    }

    /// Provider whose hangs are always released on teardown, so no blocked
    /// global-queue thread outlives the test.
    private func makeProvider() -> HangingVolumeInfoProvider {
        let provider = HangingVolumeInfoProvider()
        addTeardownBlock { provider.releaseAllHangs() }
        return provider
    }

    // MARK: - Happy path

    func testResolvedVolumeDeliversOnMainWithSizesAndBSDName() {
        let provider = makeProvider()
        provider.setCapacity(VolumeSpace(free: 100, total: 500), for: url("/Volumes/USB"))
        provider.setBSDName("disk4s1", for: url("/Volumes/USB"))
        let resolver = DeferredVolumeResolver(provider: provider, timeout: neverFires)

        let delivered = expectation(description: "USB resolved")
        var results: [DeferredVolumeResolution] = []
        resolver.resolve([usbStub()]) { result in
            XCTAssertTrue(Thread.isMainThread, "deliveries are UI-facing and must arrive on main")
            results.append(result)
            delivered.fulfill()
        }

        wait(for: [delivered], timeout: eventTimeout)
        XCTAssertEqual(results, [.resolved(Volume(
            name: "USB",
            mountURL: url("/Volumes/USB"),
            totalBytes: 500,
            freeBytes: 100,
            kind: .external,
            bsdName: "disk4s1"
        ))])
        XCTAssertTrue(provider.capacityReadsOnMainThread.isEmpty,
                      "no filesystem call may run on the main thread in this path")
    }

    func testFailedCapacityReadDeliversUnavailableWithoutWaitingForTimeout() {
        let provider = makeProvider()
        // No capacity entry: the read fails fast (nil), it does not hang.
        let resolver = DeferredVolumeResolver(provider: provider, timeout: neverFires)

        let delivered = expectation(description: "NAS unavailable")
        resolver.resolve([nasStub()]) { result in
            XCTAssertEqual(result, .unavailable(self.nasStub()))
            delivered.fulfill()
        }

        // Must arrive long before the 60s row timeout — from the failed read itself.
        wait(for: [delivered], timeout: eventTimeout)
    }

    // MARK: - Hung-mount isolation

    func testHungReadTimesOutToUnavailablePlaceholder() {
        let provider = makeProvider()
        provider.setCapacity(VolumeSpace(free: 1, total: 2), for: url("/Volumes/NAS"))
        provider.hangCapacityReads(for: url("/Volumes/NAS"))
        let resolver = DeferredVolumeResolver(provider: provider, timeout: 0.2)

        let delivered = expectation(description: "NAS placeholder after row timeout")
        resolver.resolve([nasStub()]) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result, .unavailable(self.nasStub()))
            delivered.fulfill()
        }

        wait(for: [delivered], timeout: eventTimeout)
    }

    /// Task DOD: internal results deliver even when a network volume hangs, and a
    /// hung mount delays only its own row — the fast external volume streams in
    /// while the NAS read stays blocked.
    func testInternalAndFastExternalResultsDeliverWhileNetworkMountHangs() {
        let provider = makeProvider()
        provider.setMountedVolumes([
            VolumeInfo(mountURL: url("/"), name: "Macintosh HD",
                       isInternal: true, isLocal: true, isRemovable: false, isEjectable: false),
            VolumeInfo(mountURL: url("/Volumes/USB"), name: "USB",
                       isInternal: false, isLocal: true, isRemovable: true, isEjectable: true),
            VolumeInfo(mountURL: url("/Volumes/NAS"), name: "NAS", isLocal: false),
        ])
        provider.setCapacity(VolumeSpace(free: 400, total: 1_000), for: url("/"))
        provider.setCapacity(VolumeSpace(free: 10, total: 64), for: url("/Volumes/USB"))
        provider.setCapacity(VolumeSpace(free: 1, total: 2), for: url("/Volumes/NAS"))
        provider.hangCapacityReads(for: url("/Volumes/NAS")) // released only in teardown

        // Synchronous pass returns immediately: it never reads deferred capacities,
        // so the hung NAS cannot delay the internal row (VOL-001 invariant).
        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()
        XCTAssertEqual(snapshot.internalVolumes.map(\.name), ["Macintosh HD"])
        XCTAssertEqual(snapshot.deferredVolumes.map(\.name), ["USB", "NAS"])

        let resolver = DeferredVolumeResolver(provider: provider, timeout: neverFires)
        let usbDelivered = expectation(description: "USB resolves while NAS is still hung")
        resolver.resolve(snapshot.deferredVolumes) { result in
            if case .resolved(let volume) = result, volume.name == "USB" {
                XCTAssertEqual(volume.totalBytes, 64)
                XCTAssertEqual(volume.freeBytes, 10)
                usbDelivered.fulfill()
            } else {
                XCTFail("only USB may deliver while NAS hangs and no timeout fires, got \(result)")
            }
        }

        wait(for: [usbDelivered], timeout: eventTimeout)
        // The test itself ran the synchronous pass on main (reading "/"); the
        // resolver's deferred reads must never have touched main.
        XCTAssertEqual(provider.capacityReadsOnMainThread, [url("/")])
    }

    // MARK: - Generation / cancellation

    func testStaleGenerationResultsAreDropped() {
        let provider = makeProvider()
        provider.setCapacity(VolumeSpace(free: 1, total: 2), for: url("/Volumes/NAS"))
        provider.setCapacity(VolumeSpace(free: 10, total: 64), for: url("/Volumes/USB"))
        let gate = provider.hangCapacityReads(for: url("/Volumes/NAS"))
        let resolver = DeferredVolumeResolver(provider: provider, timeout: neverFires)

        let staleDelivery = expectation(description: "generation-1 callback fires")
        staleDelivery.isInverted = true
        resolver.resolve([nasStub()]) { _ in staleDelivery.fulfill() }

        // A new refresh (without NAS) supersedes generation 1 before its read ends.
        let freshDelivery = expectation(description: "generation-2 USB resolved")
        resolver.resolve([usbStub()]) { result in
            XCTAssertEqual(result.mountURL, self.url("/Volumes/USB"))
            freshDelivery.fulfill()
        }
        gate.signal() // the hung NAS read now completes — into a stale generation

        wait(for: [freshDelivery], timeout: eventTimeout)
        wait(for: [staleDelivery], timeout: quietTimeout)
    }

    func testInvalidateDropsPendingDeliveries() {
        let provider = makeProvider()
        provider.setCapacity(VolumeSpace(free: 1, total: 2), for: url("/Volumes/NAS"))
        let gate = provider.hangCapacityReads(for: url("/Volumes/NAS"))
        let resolver = DeferredVolumeResolver(provider: provider, timeout: neverFires)

        let delivery = expectation(description: "callback fires after invalidate")
        delivery.isInverted = true
        resolver.resolve([nasStub()]) { _ in delivery.fulfill() }
        resolver.invalidate()
        gate.signal()

        wait(for: [delivery], timeout: quietTimeout)
    }

    // MARK: - In-flight dedupe across refreshes

    func testRepeatedRefreshDoesNotRedispatchHungRead() {
        let provider = makeProvider()
        provider.setCapacity(VolumeSpace(free: 1, total: 2), for: url("/Volumes/NAS"))
        provider.hangCapacityReads(for: url("/Volumes/NAS"))
        let resolver = DeferredVolumeResolver(provider: provider, timeout: 0.2)

        let firstTimeout = expectation(description: "generation-1 placeholder")
        resolver.resolve([nasStub()]) { result in
            XCTAssertEqual(result, .unavailable(self.nasStub()))
            firstTimeout.fulfill()
        }
        wait(for: [firstTimeout], timeout: eventTimeout)

        // Second refresh while the first read is still blocked: the volume must
        // not get a second blocked thread — its row just times out again.
        let secondTimeout = expectation(description: "generation-2 placeholder")
        resolver.resolve([nasStub()]) { result in
            XCTAssertEqual(result, .unavailable(self.nasStub()))
            secondTimeout.fulfill()
        }
        wait(for: [secondTimeout], timeout: eventTimeout)

        XCTAssertEqual(provider.capacityRequestCount(for: url("/Volumes/NAS")), 1,
                       "a hung read must never be re-dispatched by later refreshes")
    }

    func testAgedOutInFlightSlotIsReDispatchedInsteadOfPoisoningThePathForever() {
        // A dead mount at /Volumes/NAS hangs forever, marking its in-flight slot.
        // testRepeatedRefreshDoesNotRedispatchHungRead proves a *fresh* slot blocks
        // re-dispatch; this proves the slot ages out so a volume later mounted at
        // the same path is not poisoned into permanent "Unavailable". A fake clock
        // drives the aging deterministically (no real 60s wait). The hang gate stays
        // in place, so the re-dispatched read also blocks and times out — but the
        // key observable is that a SECOND read was dispatched at all.
        let provider = makeProvider()
        provider.setCapacity(VolumeSpace(free: 5, total: 20), for: url("/Volumes/NAS"))
        provider.hangCapacityReads(for: url("/Volumes/NAS"))
        var now: TimeInterval = 1_000
        let resolver = DeferredVolumeResolver(
            provider: provider,
            timeout: 0.2,
            staleReadThreshold: 30,
            uptime: { now }
        )

        let firstTimeout = expectation(description: "dead mount times out, slot marked in-flight")
        resolver.resolve([nasStub()]) { result in
            XCTAssertEqual(result, .unavailable(self.nasStub()))
            firstTimeout.fulfill()
        }
        wait(for: [firstTimeout], timeout: eventTimeout)
        XCTAssertEqual(provider.capacityRequestCount(for: url("/Volumes/NAS")), 1)

        // Advance past the stale threshold: the abandoned slot must be re-dispatched.
        now += 31
        let secondTimeout = expectation(description: "re-dispatched read times out again")
        resolver.resolve([nasStub()]) { result in
            XCTAssertEqual(result, .unavailable(self.nasStub()))
            secondTimeout.fulfill()
        }
        wait(for: [secondTimeout], timeout: eventTimeout)

        XCTAssertEqual(provider.capacityRequestCount(for: url("/Volumes/NAS")), 2,
                       "an aged-out in-flight slot must allow exactly one fresh re-dispatch")
    }

    /// Regression: an aged-out re-dispatch must not let the superseded old (dead)
    /// read consume the fresh healthy read's pending slot. Old read T1 (dead NAS,
    /// capacity nil) hangs past the stale threshold; a re-mounted healthy volume
    /// gets a fresh read T2. T1 is released to complete FIRST — it no longer owns
    /// the in-flight slot, so it must deliver nothing and leave T2's pending slot
    /// intact. T2 then delivers the healthy `.resolved` for the current generation.
    /// Before the ownership gate on delivery, T1 consumed the slot and delivered a
    /// stale `.unavailable`, dropping T2's healthy result (poisoned for one cycle).
    func testAgedOutOldReadDoesNotStealFreshReadsPendingSlot() {
        let provider = SequencedCapacityProvider(url: url("/Volumes/NAS"))
        var now: TimeInterval = 1_000
        let resolver = DeferredVolumeResolver(
            provider: provider,
            timeout: 0.2,
            staleReadThreshold: 30,
            uptime: { now }
        )
        addTeardownBlock { provider.releaseAll() }

        // Generation 1: dead mount. T1 dispatched, hangs, row times out.
        let firstTimeout = expectation(description: "dead mount times out")
        resolver.resolve([nasStub()]) { result in
            XCTAssertEqual(result, .unavailable(self.nasStub()))
            firstTimeout.fulfill()
        }
        wait(for: [firstTimeout], timeout: eventTimeout)
        provider.waitForNextDispatch() // T1 is parked on its gate

        // Healthy volume remounted at the same path; slot ages out.
        now += 31
        let healthy = expectation(description: "healthy volume resolves")
        var results: [DeferredVolumeResolution] = []
        resolver.resolve([nasStub()]) { result in
            results.append(result)
            healthy.fulfill()
        }
        provider.waitForNextDispatch() // T2 (healthy) is parked on its gate

        // Release the OLD dead read first: it must NOT deliver — it no longer owns
        // the slot. Then release the fresh read: it delivers the healthy row.
        provider.release(readIndex: 0)
        provider.release(readIndex: 1)

        wait(for: [healthy], timeout: eventTimeout)
        XCTAssertEqual(results, [.resolved(Volume(
            name: "NAS",
            mountURL: url("/Volumes/NAS"),
            totalBytes: 20,
            freeBytes: 5,
            kind: .network,
            bsdName: nil
        ))], "the fresh healthy read must win; the aged-out dead read must not poison the row")
    }

    func testHungReadCompletionHandsOffToLatestGeneration() {
        let provider = makeProvider()
        provider.setCapacity(VolumeSpace(free: 1, total: 8), for: url("/Volumes/NAS"))
        provider.setBSDName("disk9s1", for: url("/Volumes/NAS"))
        let gate = provider.hangCapacityReads(for: url("/Volumes/NAS"))
        let resolver = DeferredVolumeResolver(provider: provider, timeout: neverFires)

        let staleDelivery = expectation(description: "generation-1 callback fires")
        staleDelivery.isInverted = true
        resolver.resolve([nasStub()]) { _ in staleDelivery.fulfill() }

        // Refresh with the same still-hung volume, then let the original read
        // finish: its result belongs to the NEWEST generation's callback.
        let handedOff = expectation(description: "generation-2 receives the resolved volume")
        resolver.resolve([nasStub()]) { result in
            XCTAssertEqual(result, .resolved(Volume(
                name: "NAS",
                mountURL: self.url("/Volumes/NAS"),
                totalBytes: 8,
                freeBytes: 1,
                kind: .network,
                bsdName: "disk9s1"
            )))
            handedOff.fulfill()
        }
        gate.signal()

        wait(for: [handedOff], timeout: eventTimeout)
        wait(for: [staleDelivery], timeout: quietTimeout)
        XCTAssertEqual(provider.capacityRequestCount(for: url("/Volumes/NAS")), 1)
    }
}

/// Provider that captures each capacity read's result at dispatch time and parks
/// it on a per-read gate, so a test can (a) wait until N reads for a URL have
/// arrived and parked, and (b) release them in an arbitrary order. The first read
/// for `url` returns `nil` (dead mount); every later read returns the healthy
/// capacity — modelling a dead NAS being replaced by a healthy volume at the same
/// path. Deterministic ordering is the whole point: the shared-gate mocks can't
/// force the OLD read to complete before the NEW one.
private final class SequencedCapacityProvider: VolumeInfoProviding {
    private let url: URL
    private let healthy = VolumeSpace(free: 5, total: 20)
    private let lock = NSLock()
    private var gates: [DispatchSemaphore] = []
    private let arrived = DispatchSemaphore(value: 0)

    init(url: URL) { self.url = url }

    func mountedVolumes() -> [VolumeInfo] { [] }

    func capacity(forVolumeAt url: URL) -> VolumeSpace? {
        lock.lock()
        let index = gates.count
        let gate = DispatchSemaphore(value: 0)
        gates.append(gate)
        // First read for this path is the dead mount; later reads are the healthy
        // remount.
        let result: VolumeSpace? = index == 0 ? nil : healthy
        lock.unlock()
        arrived.signal()
        gate.wait() // park until the test releases this specific read
        return result
    }

    func bsdName(forVolumeAt url: URL) -> String? { nil }

    /// Blocks until the next not-yet-observed read has arrived and parked.
    func waitForNextDispatch() {
        arrived.wait()
    }

    /// Releases the read that parked at `readIndex` (0-based dispatch order).
    func release(readIndex: Int) {
        lock.lock()
        let gate = gates[readIndex]
        lock.unlock()
        gate.signal()
    }

    /// Unblocks every parked read so no global-queue thread outlives the test.
    func releaseAll() {
        let all = { () -> [DispatchSemaphore] in
            lock.lock(); defer { lock.unlock() }; return gates
        }()
        for gate in all { for _ in 0..<8 { gate.signal() } }
    }
}
