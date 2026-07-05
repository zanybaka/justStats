import AppKit
import SwiftUI
import XCTest
@testable import justStats

@MainActor
final class VolumeListPopoverCoordinatorTests: XCTestCase {
    // MARK: - Fixtures

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private func snapshot() -> VolumeEnumerator.Snapshot {
        VolumeEnumerator.Snapshot(
            internalVolumes: [Volume(
                name: "Macintosh HD",
                mountURL: url("/"),
                totalBytes: 1_000_000_000_000,
                freeBytes: 400_000_000_000,
                kind: .internal,
                bsdName: "disk3s5"
            )],
            deferredVolumes: [DeferredVolume(name: "USB", mountURL: url("/Volumes/USB"), kind: .external)]
        )
    }

    private func makeCoordinator(
        resolver: MockDeferredVolumeResolver = MockDeferredVolumeResolver(),
        onModelCreated: @escaping (VolumeListViewModel) -> Void = { _ in }
    ) -> VolumeListPopoverCoordinator {
        let snapshot = snapshot()
        return VolumeListPopoverCoordinator(makeModel: {
            // Inject mock scanners so opening the popover in tests never starts real
            // Spotlight (NSMetadataQuery) work — category breakdown (SCAN-004) and the
            // largest-files section (ACT-001) both run through their seams on load().
            let model = VolumeListViewModel(enumerate: { snapshot }, resolver: resolver,
                                            scanner: MockCategoryScanner(),
                                            largestFilesScanner: MockLargestFilesScanner())
            onModelCreated(model)
            return model
        })
    }

    // MARK: - Content factory (hosting contract carried over from VOL-003)

    func testContentIsHostingControllerWithDynamicHeightSizing() throws {
        let coordinator = makeCoordinator()
        let viewController = coordinator.makeContentViewController()
        let hosting = try XCTUnwrap(
            viewController as? NSHostingController<VolumeListView>,
            "popover content must be the SwiftUI volume list in NSHostingController (TECHSPEC §1)"
        )
        XCTAssertTrue(
            hosting.sizingOptions.contains(.preferredContentSize),
            "height must track SwiftUI content via preferredContentSize (TECHSPEC §8)"
        )
    }

    func testContentUsesSharedFixedWidth() {
        let coordinator = makeCoordinator()
        let viewController = coordinator.makeContentViewController()
        viewController.loadView()
        XCTAssertEqual(
            viewController.view.fittingSize.width,
            PopoverLayout.contentWidth,
            "popover content width must come from the shared Kit constant"
        )
        XCTAssertGreaterThan(viewController.view.fittingSize.height, 0)
    }

    // MARK: - Open/close lifecycle

    func testOpenLoadsTheFreshModelSoInternalRowsExistBeforeShow() {
        var models: [VolumeListViewModel] = []
        let coordinator = makeCoordinator { models.append($0) }

        let viewController = coordinator.makeContentViewController()
        XCTAssertEqual(models.count, 1, "one fresh model per open")
        XCTAssertTrue(models[0].rows.isEmpty, "enumeration waits for the onOpen seam")

        coordinator.popoverDidOpen()

        XCTAssertEqual(models[0].rows.count, 2,
                       "internal row + deferred placeholder populated on open (FR3)")
        _ = viewController // keep the content alive for the duration of the test
    }

    func testEveryOpenGetsAFreshModel() {
        var models: [VolumeListViewModel] = []
        let coordinator = makeCoordinator { models.append($0) }

        _ = coordinator.makeContentViewController()
        coordinator.popoverDidOpen()
        coordinator.popoverDidClose()
        _ = coordinator.makeContentViewController()
        coordinator.popoverDidOpen()

        XCTAssertEqual(models.count, 2)
        XCTAssertFalse(models[0] === models[1], "no stale state across opens")
    }

    func testCloseInvalidatesResolutionsAndReleasesTheModel() {
        let resolver = MockDeferredVolumeResolver()
        weak var weakModel: VolumeListViewModel?
        let coordinator = makeCoordinator(resolver: resolver) { weakModel = $0 }

        // NSHostingController autoreleases the SwiftUI tree (and the @ObservedObject
        // model it holds) into the current pool during creation; drain it before
        // asserting deallocation so the check reflects real ownership, not
        // pool-lifetime references from building the content.
        autoreleasepool {
            var viewController: NSViewController? = coordinator.makeContentViewController()
            coordinator.popoverDidOpen()
            XCTAssertNotNil(weakModel)

            coordinator.popoverDidClose()
            viewController = nil // the shell drops contentViewController on didClose
            _ = viewController
        }

        XCTAssertEqual(resolver.invalidateCount, 1,
                       "undelivered streaming results must be dropped on close")
        XCTAssertNil(weakModel, "per-open model must not outlive the popover session")
    }

    func testOpenAndCloseWithoutContentDoNothing() {
        let resolver = MockDeferredVolumeResolver()
        let coordinator = makeCoordinator(resolver: resolver)

        coordinator.popoverDidOpen()
        coordinator.popoverDidClose()

        XCTAssertTrue(resolver.resolveRequests.isEmpty)
        XCTAssertEqual(resolver.invalidateCount, 0)
    }
}
