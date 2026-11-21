import AppKit
import XCTest
@testable import justStats

/// VOL-008: eject button eligibility, the unmount-notification removal path, the
/// refuse → retry → force flow through the `VolumeEjecting` seam, and the holder
/// phrase dictionary. No real mount is touched.
@MainActor
final class VolumeEjectTests: XCTestCase {
    // MARK: - Fixtures

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private func bootVolume() -> Volume {
        Volume(name: "Macintosh HD", mountURL: url("/"), totalBytes: 1_000, freeBytes: 400,
               kind: .internal, bsdName: "disk3s5")
    }

    private func fixedInternal() -> Volume {
        Volume(name: "Data", mountURL: url("/Volumes/Data"), totalBytes: 1_000, freeBytes: 400,
               kind: .internal, bsdName: "disk2s1")
    }

    private func usb() -> Volume {
        Volume(name: "Transcend", mountURL: url("/Volumes/Transcend"), totalBytes: 64_000,
               freeBytes: 10_000, kind: .external, bsdName: "disk4s1")
    }

    private func nas() -> Volume {
        Volume(name: "NAS", mountURL: url("/Volumes/NAS"), totalBytes: 8_000, freeBytes: 2_000,
               kind: .network, bsdName: nil)
    }

    private let usbURL = URL(fileURLWithPath: "/Volumes/Transcend", isDirectory: true)

    private struct Rig {
        let model: VolumeListViewModel
        let ejector: MockVolumeEjector
        let center: NotificationCenter
    }

    /// A model with `internalVolumes` loaded and `resolved` deferred volumes already
    /// resolved (so every row is `.loaded`).
    private func makeRig(internalVolumes: [Volume], resolved: [Volume] = []) -> Rig {
        let resolver = MockDeferredVolumeResolver()
        let ejector = MockVolumeEjector()
        let center = NotificationCenter()
        let stubs = resolved.map { DeferredVolume(name: $0.name, mountURL: $0.mountURL, kind: $0.kind) }
        let snapshot = VolumeEnumerator.Snapshot(internalVolumes: internalVolumes, deferredVolumes: stubs)
        let model = VolumeListViewModel(
            enumerate: { snapshot },
            resolver: resolver,
            scanner: MockCategoryScanner(),
            largestFilesScanner: MockLargestFilesScanner(),
            ejector: ejector,
            unmountNotificationCenter: center
        )
        model.load()
        for volume in resolved { resolver.deliver(.resolved(volume)) }
        return Rig(model: model, ejector: ejector, center: center)
    }

    private func postUnmount(_ rig: Rig, _ mount: URL) {
        rig.center.post(
            name: NSWorkspace.didUnmountNotification, object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: mount]
        )
    }

    // MARK: - Button eligibility

    func testEjectOfferedOnExternalAndNetworkOnly() {
        XCTAssertTrue(VolumeListViewModel.Row.loaded(usb()).isEjectable)
        XCTAssertTrue(VolumeListViewModel.Row.loaded(nas()).isEjectable)
        XCTAssertFalse(VolumeListViewModel.Row.loaded(bootVolume()).isEjectable, "never the boot volume")
        XCTAssertFalse(VolumeListViewModel.Row.loaded(fixedInternal()).isEjectable, "never internal fixed disks")
    }

    func testBootVolumeIsNeverEjectableEvenWhenClassifiedExternal() {
        // macOS booted from an external SSD: `/` carries no internal flag → `.external`.
        let externalBoot = Volume(name: "Boot SSD", mountURL: url("/"), totalBytes: 1_000,
                                  freeBytes: 400, kind: .external, bsdName: "disk5s1")
        XCTAssertFalse(VolumeListViewModel.Row.loaded(externalBoot).isEjectable)
    }

    func testPendingRowOffersNoEjectAndUnavailableRowDoes() {
        let stub = DeferredVolume(name: "NAS", mountURL: url("/Volumes/NAS"), kind: .network)
        XCTAssertFalse(VolumeListViewModel.Row.pending(stub).isEjectable)
        XCTAssertTrue(VolumeListViewModel.Row.unavailable(stub).isEjectable, "a hung share is worth unmounting")
    }

    func testRequestEjectIgnoredForBootAndInternalRows() {
        let rig = makeRig(internalVolumes: [bootVolume(), fixedInternal()])
        rig.model.requestEject(for: url("/"))
        rig.model.requestEject(for: url("/Volumes/Data"))
        XCTAssertTrue(rig.ejector.requests.isEmpty)
        XCTAssertTrue(rig.model.ejectStates.isEmpty)
    }

    // MARK: - Success path

    func testUnmountNotificationDropsTheRowWithoutReopening() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb(), nas()])
        postUnmount(rig, usbURL)
        XCTAssertEqual(rig.model.rows.map(\.id), [url("/"), url("/Volumes/NAS")])
        XCTAssertNil(rig.model.categoryStates[usbURL])
    }

    func testUnmountNotificationDropsEverySiblingVolumeOfAStick() {
        let second = Volume(name: "Transcend 2", mountURL: url("/Volumes/Transcend 2"), totalBytes: 1_000,
                            freeBytes: 500, kind: .external, bsdName: "disk4s2")
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb(), second])
        postUnmount(rig, usbURL)
        postUnmount(rig, second.mountURL)
        XCTAssertEqual(rig.model.rows.map(\.id), [url("/")])
    }

    func testNotificationStopsAfterInvalidate() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.invalidate()
        postUnmount(rig, usbURL)
        XCTAssertEqual(rig.model.rows.count, 2, "a closed popover no longer observes")
    }

    func testSuccessfulEjectRemovesRowAndClearsState() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        XCTAssertEqual(rig.model.ejectStates[usbURL], .ejecting)
        XCTAssertEqual(rig.ejector.requests.map(\.force), [false])
        rig.ejector.completeNext(with: .success)
        XCTAssertEqual(rig.model.rows.map(\.id), [url("/")])
        XCTAssertNil(rig.model.ejectStates[usbURL])
    }

    func testSecondRequestWhileEjectingIsIgnored() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        rig.model.requestEject(for: usbURL)
        XCTAssertEqual(rig.ejector.requests.count, 1)
    }

    // MARK: - Refusal, retry, force

    func testRefusalShowsPanelNamingVolumeAndHolder() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        rig.ejector.completeNext(with: .refused(holder: EjectHolder(pid: 436, processName: "mds_stores")))
        XCTAssertEqual(
            rig.model.ejectStates[usbURL],
            .refused(EjectRefusal(
                message: "Can’t eject “Transcend”: Spotlight indexing, usually releases in a minute or two.",
                hint: EjectMessages.spotlightForceHint,
                warning: EjectMessages.spotlightForceWarning
            ))
        )
        XCTAssertEqual(rig.model.rows.count, 2, "the row stays")
    }

    func testRefusalWithoutHolderIsHonest() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        rig.ejector.completeNext(with: .refused(holder: nil))
        XCTAssertEqual(rig.model.ejectStates[usbURL],
                       .refused(EjectRefusal(
                           message: "Can’t eject “Transcend”: a program is using it.",
                           hint: nil,
                           warning: EjectMessages.forceWarning
                       )))
    }

    func testRetryReissuesPlainUnmount() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        rig.ejector.completeNext(with: .refused(holder: nil))
        rig.model.requestEject(for: usbURL)
        XCTAssertEqual(rig.ejector.requests.map(\.force), [false, false])
        XCTAssertEqual(rig.model.ejectStates[usbURL], .ejecting)
    }

    func testForceNeedsWarningThenReissuesWithForce() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        rig.ejector.completeNext(with: .refused(holder: nil))

        rig.model.requestForceEject(for: usbURL)
        guard case .confirmingForce = rig.model.ejectStates[usbURL] else {
            return XCTFail("force must show its warning first")
        }
        XCTAssertEqual(rig.ejector.requests.count, 1, "the warning issues nothing")

        rig.model.confirmForceEject(for: usbURL)
        XCTAssertEqual(rig.ejector.requests.map(\.force), [false, true])
        XCTAssertEqual(rig.model.ejectStates[usbURL], .ejecting)
    }

    func testConfirmForceWithoutWarningIsIgnored() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        rig.ejector.completeNext(with: .refused(holder: nil))
        rig.model.confirmForceEject(for: usbURL)
        XCTAssertEqual(rig.ejector.requests.count, 1)
    }

    func testCancelBacksOutOfWarningThenClosesPanel() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        rig.ejector.completeNext(with: .refused(holder: nil))
        rig.model.requestForceEject(for: usbURL)
        rig.model.cancelEject(for: usbURL)
        guard case .refused = rig.model.ejectStates[usbURL] else { return XCTFail("back to refusal") }
        rig.model.cancelEject(for: usbURL)
        XCTAssertNil(rig.model.ejectStates[usbURL])
    }

    func testOtherFailureShowsReasonAndOffersRetry() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        rig.ejector.completeNext(with: .failed(reason: "Not permitted."))
        XCTAssertEqual(rig.model.ejectStates[usbURL],
                       .failed(message: "Can’t eject “Transcend”: Not permitted."))
        rig.model.requestForceEject(for: usbURL)
        XCTAssertEqual(rig.model.ejectStates[usbURL],
                       .failed(message: "Can’t eject “Transcend”: Not permitted."), "no force after a non-busy failure")
    }

    func testLateCompletionAfterRowVanishedIsDropped() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        postUnmount(rig, usbURL)
        rig.ejector.completeNext(with: .refused(holder: nil))
        XCTAssertTrue(rig.model.ejectStates.isEmpty)
    }

    func testEjectStateSurvivesRefresh() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        rig.model.refresh()
        XCTAssertEqual(rig.model.ejectStates[usbURL], .ejecting, "in-flight unmount keeps its spinner")
    }

    // MARK: - Spotlight force hint

    func testOnlySpotlightGetsTheLowRiskHintAndWarning() {
        let spotlight = EjectMessages.refusalDetails(
            volumeName: "USB", holder: EjectHolder(pid: 1, processName: "mds_stores"))
        XCTAssertEqual(spotlight.hint, EjectMessages.spotlightForceHint)
        XCTAssertEqual(spotlight.warning, EjectMessages.spotlightForceWarning)

        for holder in [EjectHolder(pid: 2, processName: "rsync"), EjectHolder(pid: 3, processName: nil), nil] {
            let other = EjectMessages.refusalDetails(volumeName: "USB", holder: holder)
            XCTAssertNil(other.hint, "no reassurance unless the holder is known to be low risk")
            XCTAssertEqual(other.warning, EjectMessages.forceWarning)
        }
    }

    func testSpotlightWarningSurvivesTheForceConfirmStep() {
        let rig = makeRig(internalVolumes: [bootVolume()], resolved: [usb()])
        rig.model.requestEject(for: usbURL)
        rig.ejector.completeNext(with: .refused(holder: EjectHolder(pid: 436, processName: "mds_stores")))
        rig.model.requestForceEject(for: usbURL)
        guard case .confirmingForce(let refusal) = rig.model.ejectStates[usbURL] else {
            return XCTFail("force must show its warning first")
        }
        XCTAssertEqual(refusal.warning, EjectMessages.spotlightForceWarning)
    }

    // MARK: - Holder phrases (mapper)

    func testEveryKnownHolderMapsToItsPhrase() {
        let expected = [
            "mds_stores": "Spotlight indexing, usually releases in a minute or two",
            "rsync": "file copy in progress",
            "backupd": "Time Machine backup",
            "Finder": "Finder has this disk or its files open",
            "photoanalysisd": "Photos analyzing",
        ]
        XCTAssertEqual(EjectMessages.knownHolderPhrases, expected)
        for (name, phrase) in expected {
            XCTAssertEqual(EjectMessages.holderPhrase(for: EjectHolder(pid: 1, processName: name)), phrase)
        }
    }

    func testUnknownHolderRendersNameAndPID() {
        XCTAssertEqual(EjectMessages.holderPhrase(for: EjectHolder(pid: 4242, processName: "weirdd")),
                       "process weirdd (PID 4242)")
        XCTAssertEqual(EjectMessages.holderPhrase(for: EjectHolder(pid: 4242, processName: nil)),
                       "process (PID 4242)")
    }

    // MARK: - Process name lookup (real processes)

    func testProcessNameResolvesRootAndOwnProcesses() {
        // launchd (PID 1) is root-owned: `proc_name` is refused for it, so this covers
        // the sysctl fallback that names `mds_stores` and the other root holders.
        XCTAssertEqual(DiskArbitrationVolumeEjector.processName(pid: 1), "launchd")
        let own = DiskArbitrationVolumeEjector.processName(pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(own?.isEmpty ?? true)
    }

    func testProcessNameOfMissingProcessIsNil() {
        XCTAssertNil(DiskArbitrationVolumeEjector.processName(pid: 999_999))
    }
}
