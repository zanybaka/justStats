import XCTest
@testable import justStats

/// SCAN-006: the lazy Full Disk Access notice. When the boot volume's Spotlight
/// index comes back empty — the permissions-shaped case, since the system volume is
/// always indexed under normal conditions — the row shows "Grant Full Disk Access
/// for complete data" with a button opening the FDA privacy pane (TECHSPEC §7),
/// instead of the generic "Not indexed" notice SCAN-005 shows for genuinely
/// unindexed drives.
///
/// Spotlight cannot itself distinguish a permissions block from an unindexed drive
/// (both come back empty, no discriminating error), so the volume's role is the
/// signal. That decision, the state → content mapping, and the notice content/deep
/// link are all pure and covered here; the actual System Settings launch is verified
/// manually (there is no automatable way to confirm the pane opened).
final class FullDiskAccessNoticeViewTests: XCTestCase {
    // MARK: - Boot-volume detection & classification (the SCAN-005 vs SCAN-006 fork)

    /// The root presentation `/` is the boot volume — the only place an empty index
    /// is permissions-shaped.
    func testBootVolumeIsDetectedByRootMountPath() {
        let boot = volume(path: "/")
        XCTAssertTrue(VolumeListViewModel.isBootVolume(boot))
    }

    /// Any non-root mount is not the boot volume, so its empty index is a plain
    /// unindexed drive, not a permissions block.
    func testNonRootVolumeIsNotTheBootVolume() {
        XCTAssertFalse(VolumeListViewModel.isBootVolume(volume(path: "/Volumes/USB")))
        XCTAssertFalse(VolumeListViewModel.isBootVolume(volume(path: "/Volumes/Data")))
    }

    /// An unavailable index on the boot volume classifies as `.needsFullDiskAccess`
    /// (SCAN-006) — the permissions-shaped case.
    func testUnavailableOnBootVolumeClassifiesAsNeedsFullDiskAccess() {
        XCTAssertEqual(VolumeListViewModel.unavailableState(forBootVolume: true),
                       .needsFullDiskAccess)
    }

    /// An unavailable index on a non-boot volume classifies as `.notIndexed`
    /// (SCAN-005) — a genuinely unindexed drive.
    func testUnavailableOnNonBootVolumeClassifiesAsNotIndexed() {
        XCTAssertEqual(VolumeListViewModel.unavailableState(forBootVolume: false),
                       .notIndexed)
    }

    // MARK: - Pure state → row-content mapping

    /// The `.needsFullDiskAccess` state selects the Full Disk Access notice — never a
    /// bar, never the plain "Not indexed" text, never the usage bar.
    func testNeedsFullDiskAccessStateSelectsTheFullDiskAccessNotice() {
        let content = VolumeRowView.Content(categoryState: .needsFullDiskAccess)
        XCTAssertEqual(content, .fullDiskAccessNotice)
    }

    /// The neighbouring states are unchanged by SCAN-006: `.notIndexed` still maps to
    /// the plain notice, so the two degraded states stay distinct in the UI.
    func testNotIndexedStateStillSelectsThePlainNotice() {
        let content = VolumeRowView.Content(categoryState: .notIndexed)
        XCTAssertEqual(content, .notIndexedNotice)
    }

    // MARK: - Notice content & deep link

    /// The notice text is exactly the TECHSPEC §7 wording — asserted so a drift is
    /// caught, not just "some string".
    func testNoticeMessageMatchesTechspecWording() {
        XCTAssertEqual(
            FullDiskAccessNoticeView.message,
            "Grant Full Disk Access for complete data"
        )
    }

    /// The deep link is exactly the TECHSPEC §7 URL for the Full Disk Access pane.
    /// This is the one string a typo would silently break (it force-unwraps at the
    /// call site), so it is pinned here even though the launch itself is manual.
    func testDeepLinkTargetsTheFullDiskAccessPane() {
        XCTAssertEqual(
            SystemSettingsLink.fullDiskAccess.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }

    // MARK: - Button wiring (through the injectable opener seam)

    /// Tapping the notice's button invokes the injected opener exactly once — the
    /// button is wired to the seam, so in production it opens the FDA pane. The real
    /// `NSWorkspace` launch is out of scope for the unit test; only the wiring is.
    @MainActor
    func testNoticeButtonInvokesTheOpener() {
        let opener = MockFullDiskAccessSettingsOpener()
        let notice = FullDiskAccessNoticeView(
            volumeName: "Macintosh HD",
            openSettings: opener.openFullDiskAccessSettings
        )

        // Invoke the same closure the SwiftUI Button is bound to (no host needed).
        notice.openSettings()

        XCTAssertEqual(opener.openCount, 1)
    }

    // MARK: - End-to-end through the model wiring

    /// Boot volume + `.unavailable` scan → the row content resolves to the Full Disk
    /// Access notice, driven through the real view-model → state → content path (task
    /// DOD: "Without FDA: notice appears").
    @MainActor
    func testUnavailableBootVolumeScanDrivesTheFullDiskAccessNotice() {
        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [volume(path: "/")], scanner: scanner)
        model.load()

        scanner.deliver(.unavailable)

        XCTAssertEqual(model.categoryStates[url("/")], .needsFullDiskAccess)
        let content = VolumeRowView.Content(categoryState: model.categoryStates[url("/")])
        XCTAssertEqual(content, .fullDiskAccessNotice,
                       "an empty index on the boot volume is permissions-shaped")
    }

    /// A non-boot volume with the same `.unavailable` scan does NOT show the FDA
    /// notice — it takes SCAN-005's "Not indexed" path. This is the discriminator
    /// that keeps SCAN-006 scoped to the permissions-shaped case.
    @MainActor
    func testUnavailableNonBootVolumeDoesNotShowFullDiskAccessNotice() {
        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [volume(path: "/Volumes/Data")], scanner: scanner)
        model.load()

        scanner.deliver(.unavailable)

        XCTAssertEqual(model.categoryStates[url("/Volumes/Data")], .notIndexed)
        let content = VolumeRowView.Content(categoryState: model.categoryStates[url("/Volumes/Data")])
        XCTAssertEqual(content, .notIndexedNotice)
    }

    /// After access is granted, the next Refresh's scan returns a real index and the
    /// FDA notice is replaced by the category bar — the notice is gone (task DOD:
    /// "after granting: notice gone on next Refresh"). Modelled as: first pass yields
    /// `.needsFullDiskAccess`; `refresh()` re-scans; the second scan is `.available`.
    @MainActor
    func testGrantingAccessRemovesTheNoticeOnNextRefresh() {
        let scanner = MockCategoryScanner()
        let model = makeModel(internalVolumes: [volume(path: "/")], scanner: scanner)

        // First pass: no access → the notice.
        model.load()
        scanner.deliver(.unavailable)
        XCTAssertEqual(model.categoryStates[url("/")], .needsFullDiskAccess)

        // User grants FDA and hits Refresh; the re-scan now sees a real index.
        model.refresh()
        scanner.deliver(.available(apps: 100_000_000_000,
                                   media: 200_000_000_000,
                                   other: 50_000_000_000))

        let content = VolumeRowView.Content(categoryState: model.categoryStates[url("/")])
        if case .categoryBar = content {
            // expected — the notice is gone, the real breakdown is shown
        } else {
            XCTFail("granting access and refreshing replaces the notice with the bar, got \(content)")
        }
    }

    // MARK: - Fixtures

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private func volume(path: String) -> Volume {
        Volume(
            name: path == "/" ? "Macintosh HD" : URL(fileURLWithPath: path).lastPathComponent,
            mountURL: url(path),
            totalBytes: 1_000_000_000_000,
            freeBytes: 400_000_000_000,
            kind: path == "/" ? .internal : .external,
            bsdName: "disk3s5"
        )
    }

    @MainActor
    private func makeModel(
        internalVolumes: [Volume],
        scanner: MockCategoryScanner
    ) -> VolumeListViewModel {
        let snapshot = VolumeEnumerator.Snapshot(
            internalVolumes: internalVolumes,
            deferredVolumes: []
        )
        return VolumeListViewModel(
            enumerate: { snapshot },
            resolver: MockDeferredVolumeResolver(),
            scanner: scanner,
            // Inert largest-files scanner keeps load() hermetic (ACT-001): these tests
            // exercise the Full Disk Access notice path, not the largest-files section.
            largestFilesScanner: MockLargestFilesScanner()
        )
    }
}
