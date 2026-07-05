import XCTest
@testable import justStats

@MainActor
final class SmokeTests: XCTestCase {
    func testAppDelegateCanBeCreated() {
        XCTAssertNotNil(AppDelegate())
    }
}
