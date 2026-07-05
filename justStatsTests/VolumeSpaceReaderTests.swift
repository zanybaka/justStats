import XCTest
@testable import justStats

final class VolumeSpaceReaderTests: XCTestCase {
    // MARK: - Protocol seam (shared mock conformer, see TestSupport.swift)

    func testMockReaderReturnsInjectedValues() {
        let reader: VolumeSpaceReading = MockVolumeSpaceReader(result: VolumeSpace(free: 42, total: 100))
        XCTAssertEqual(reader.readBootVolume(), VolumeSpace(free: 42, total: 100))
    }

    func testMockReaderCanSimulateFailure() {
        let reader: VolumeSpaceReading = MockVolumeSpaceReader(result: nil)
        XCTAssertNil(reader.readBootVolume())
    }

    // MARK: - Real reader smoke tests

    func testRealReaderReturnsPlausibleBootVolumeValues() {
        guard let space = StatfsBootVolumeReader().readBootVolume() else {
            XCTFail("statfs(\"/\") failed on a real machine")
            return
        }
        XCTAssertGreaterThan(space.free, 0, "boot volume should have some free space")
        XCTAssertGreaterThan(space.total, space.free, "total capacity must exceed free space")
    }

    func testRealReaderIsCallableOffMainThread() {
        let didRead = expectation(description: "read completes off the main thread")
        DispatchQueue.global(qos: .utility).async {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNotNil(StatfsBootVolumeReader().readBootVolume())
            didRead.fulfill()
        }
        wait(for: [didRead], timeout: 5)
    }
}
