import XCTest
@testable import justStats

/// UX-005: the About section hosts a "Quit justStats" button so the menu-bar
/// (LSUIElement) app — which has no Dock icon or app menu — can be quit with the
/// pointer. The button's action is injected as a seam so a test can assert it is
/// invoked without terminating the test process. The final leg (a real click calling
/// `NSApplication.shared.terminate(nil)`, and the ⌘Q key equivalent) is manual and
/// noted in the task report.
@MainActor
final class AboutSectionTests: XCTestCase {
    func testQuitActionSeamIsInvokedWhenTriggered() {
        var quitCount = 0
        let section = AboutSection(quit: { quitCount += 1 })

        // Invoke the injected seam directly — this is exactly what the button's
        // action closure calls when pressed.
        section.quit()

        XCTAssertEqual(quitCount, 1)
    }
}
