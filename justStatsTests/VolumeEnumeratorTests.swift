import XCTest
@testable import justStats

final class VolumeEnumeratorTests: XCTestCase {
    // MARK: - Helpers

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// A plausible internal boot volume ("/") with 400 GB free of 1 TB.
    private func bootVolumeInfo() -> VolumeInfo {
        VolumeInfo(
            mountURL: url("/"),
            name: "Macintosh HD",
            isInternal: true,
            isLocal: true,
            isRemovable: false,
            isEjectable: false
        )
    }

    // MARK: - Internal fast path (via the provider seam)

    func testInternalVolumeIsResolvedSynchronouslyWithSizesAndBSDName() {
        let provider = MockVolumeInfoProvider()
        provider.volumes = [bootVolumeInfo()]
        provider.capacities = [url("/"): VolumeSpace(free: 400_000_000_000, total: 1_000_000_000_000)]
        provider.bsdNames = [url("/"): "disk3s5"]

        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertEqual(snapshot.internalVolumes, [Volume(
            name: "Macintosh HD",
            mountURL: url("/"),
            totalBytes: 1_000_000_000_000,
            freeBytes: 400_000_000_000,
            kind: .internal,
            bsdName: "disk3s5"
        )])
        XCTAssertEqual(snapshot.internalVolumes.first?.usedBytes, 600_000_000_000)
        XCTAssertTrue(snapshot.deferredVolumes.isEmpty)
    }

    func testInternalVolumeWithoutReadableCapacityIsOmitted() {
        let provider = MockVolumeInfoProvider()
        provider.volumes = [bootVolumeInfo()]
        // No capacity entry: the read failed. A row with made-up zeros would be
        // worse than no row.
        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertTrue(snapshot.internalVolumes.isEmpty)
        XCTAssertTrue(snapshot.deferredVolumes.isEmpty)
    }

    func testMissingBSDNameStaysNil() {
        let provider = MockVolumeInfoProvider()
        provider.volumes = [bootVolumeInfo()]
        provider.capacities = [url("/"): VolumeSpace(free: 1, total: 2)]

        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertEqual(snapshot.internalVolumes.count, 1)
        XCTAssertNil(snapshot.internalVolumes.first?.bsdName)
    }

    // MARK: - Classification

    func testNetworkVolumeIsDeferredAndNotLocalWinsOverOtherFlags() {
        let provider = MockVolumeInfoProvider()
        provider.volumes = [VolumeInfo(
            mountURL: url("/Volumes/NAS"),
            name: "NAS",
            isInternal: true, // contradictory flag must not beat isLocal == false
            isLocal: false,
            isRemovable: false,
            isEjectable: false
        )]

        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertTrue(snapshot.internalVolumes.isEmpty)
        XCTAssertEqual(snapshot.deferredVolumes, [
            DeferredVolume(name: "NAS", mountURL: url("/Volumes/NAS"), kind: .network),
        ])
    }

    func testExternalLocalVolumeIsDeferred() {
        let provider = MockVolumeInfoProvider()
        provider.volumes = [VolumeInfo(
            mountURL: url("/Volumes/Backup"),
            name: "Backup",
            isInternal: false,
            isLocal: true,
            isRemovable: true,
            isEjectable: true
        )]

        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertEqual(snapshot.deferredVolumes, [
            DeferredVolume(name: "Backup", mountURL: url("/Volumes/Backup"), kind: .external),
        ])
    }

    func testRemovableOrEjectableInternalMediaClassifiesAsExternal() {
        let provider = MockVolumeInfoProvider()
        provider.volumes = [
            VolumeInfo(mountURL: url("/Volumes/SDCard"), name: "SDCard",
                       isInternal: true, isLocal: true, isRemovable: true, isEjectable: false),
            VolumeInfo(mountURL: url("/Volumes/DiskImage"), name: "DiskImage",
                       isInternal: true, isLocal: true, isRemovable: false, isEjectable: true),
        ]

        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertTrue(snapshot.internalVolumes.isEmpty)
        XCTAssertEqual(snapshot.deferredVolumes.map(\.kind), [.external, .external])
    }

    func testUnknownFlagsClassifyAsExternalNotInternal() {
        // Only provably local fixed disks may take the synchronous path; a volume
        // that reports nothing goes to the deferred (isolated) path instead.
        let provider = MockVolumeInfoProvider()
        provider.volumes = [VolumeInfo(mountURL: url("/Volumes/Mystery"), name: "Mystery")]

        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertTrue(snapshot.internalVolumes.isEmpty)
        XCTAssertEqual(snapshot.deferredVolumes.map(\.kind), [.external])
    }

    // MARK: - Filtering (PRD Assumptions: service volumes are not user-facing)

    func testServiceVolumesUnderSystemVolumesAreFilteredButRootIsKept() {
        let provider = MockVolumeInfoProvider()
        let servicePaths = [
            "/System/Volumes/Preboot",
            "/System/Volumes/Recovery",
            "/System/Volumes/VM",
            "/System/Volumes/Update",
            "/System/Volumes/Data", // raw mount backing the root presentation
            "/System/Volumes/Update/mnt1",
        ]
        provider.volumes = [bootVolumeInfo()] + servicePaths.map {
            VolumeInfo(mountURL: url($0), name: ($0 as NSString).lastPathComponent,
                       isInternal: true, isLocal: true, isRemovable: false, isEjectable: false)
        }
        provider.capacities = [url("/"): VolumeSpace(free: 1, total: 2)]

        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertEqual(snapshot.internalVolumes.map(\.mountURL.path), ["/"])
        XCTAssertTrue(snapshot.deferredVolumes.isEmpty)
    }

    func testVolumeNamedLikeAServiceVolumeOutsideSystemVolumesIsKept() {
        // Filtering is by mount path, not by name — a USB stick the user named
        // "Recovery" must not disappear.
        let provider = MockVolumeInfoProvider()
        provider.volumes = [VolumeInfo(
            mountURL: url("/Volumes/Recovery"),
            name: "Recovery",
            isInternal: false,
            isLocal: true,
            isRemovable: true,
            isEjectable: true
        )]

        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertEqual(snapshot.deferredVolumes.map(\.name), ["Recovery"])
    }

    func testMissingNameFallsBackToMountPathComponent() {
        let provider = MockVolumeInfoProvider()
        provider.volumes = [VolumeInfo(
            mountURL: url("/Volumes/Untitled"),
            isInternal: false,
            isLocal: true
        )]

        let snapshot = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertEqual(snapshot.deferredVolumes.map(\.name), ["Untitled"])
    }

    // MARK: - Hung-mount isolation invariant (foundation for VOL-002)

    func testCapacityAndBSDNameAreNeverReadForDeferredVolumes() {
        let provider = MockVolumeInfoProvider()
        provider.volumes = [
            bootVolumeInfo(),
            VolumeInfo(mountURL: url("/Volumes/NAS"), name: "NAS", isLocal: false),
            VolumeInfo(mountURL: url("/Volumes/USB"), name: "USB", isInternal: false, isLocal: true),
        ]
        provider.capacities = [url("/"): VolumeSpace(free: 1, total: 2)]

        _ = VolumeEnumerator(provider: provider).enumerateSynchronously()

        XCTAssertEqual(provider.capacityRequests, [url("/")],
                       "the synchronous pass must only touch internal volumes")
        XCTAssertEqual(provider.bsdNameRequests, [url("/")])
    }

    // MARK: - Volume model

    func testUsedBytesClampsToZeroWhenFreeExceedsTotal() {
        let volume = Volume(
            name: "Odd", mountURL: url("/Volumes/Odd"),
            totalBytes: 10, freeBytes: 20, kind: .external, bsdName: nil
        )
        XCTAssertEqual(volume.usedBytes, 0)
    }

    // MARK: - Real enumerator smoke tests

    func testRealEnumeratorIncludesBootVolumeWithPlausibleSizes() {
        let snapshot = VolumeEnumerator().enumerateSynchronously()

        if let boot = snapshot.internalVolumes.first(where: { $0.mountURL.path == "/" }) {
            XCTAssertFalse(boot.name.isEmpty)
            XCTAssertGreaterThan(boot.freeBytes, 0, "boot volume should have some free space")
            XCTAssertGreaterThan(boot.totalBytes, boot.freeBytes, "total capacity must exceed free space")
            XCTAssertEqual(boot.usedBytes, boot.totalBytes - boot.freeBytes)
        } else if snapshot.deferredVolumes.contains(where: { $0.mountURL.path == "/" }) {
            // Virtualized CI runners can report the boot disk as non-internal;
            // sizes then come from the same capacity read VOL-002 will use.
            guard let space = FileManagerVolumeInfoProvider()
                .capacity(forVolumeAt: URL(fileURLWithPath: "/")) else {
                return XCTFail("capacity read for the boot volume failed on a real machine")
            }
            XCTAssertGreaterThan(space.free, 0)
            XCTAssertGreaterThan(space.total, space.free)
        } else {
            XCTFail("boot volume missing from enumeration")
        }
    }

    func testRealEnumeratorFiltersSystemServiceVolumes() {
        let snapshot = VolumeEnumerator().enumerateSynchronously()
        let allPaths = snapshot.internalVolumes.map(\.mountURL.path)
            + snapshot.deferredVolumes.map(\.mountURL.path)

        XCTAssertFalse(allPaths.isEmpty, "at least the boot volume must be present")
        XCTAssertFalse(allPaths.contains { $0.hasPrefix("/System/Volumes") },
                       "APFS service volumes must be filtered out")
    }

    func testRealProviderReturnsBSDNameForBootVolume() {
        let bsdName = FileManagerVolumeInfoProvider().bsdName(forVolumeAt: URL(fileURLWithPath: "/"))
        XCTAssertNotNil(bsdName)
        XCTAssertEqual(bsdName?.hasPrefix("disk"), true)
    }

    // MARK: - Optimistic freed-space update (ACT-002)

    private func volume(total: Int64, free: Int64) -> Volume {
        Volume(name: "V", mountURL: url("/"), totalBytes: total, freeBytes: free,
               kind: .internal, bsdName: nil)
    }

    func testWithFreedBytesAddsToFreeSpace() {
        let updated = volume(total: 1_000, free: 400).withFreedBytes(100)
        XCTAssertEqual(updated.freeBytes, 500)
        XCTAssertEqual(updated.totalBytes, 1_000, "total is unchanged")
    }

    func testWithFreedBytesCapsAtTotal() {
        let updated = volume(total: 1_000, free: 900).withFreedBytes(500)
        XCTAssertEqual(updated.freeBytes, 1_000, "free can never exceed total")
    }

    func testWithFreedBytesIsNoOpForNonPositive() {
        let base = volume(total: 1_000, free: 400)
        XCTAssertEqual(base.withFreedBytes(0), base)
        XCTAssertEqual(base.withFreedBytes(-50), base)
    }
}
