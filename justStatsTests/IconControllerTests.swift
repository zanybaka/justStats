import AppKit
import XCTest
@testable import justStats

final class IconControllerTests: XCTestCase {
    /// Thread-safe mock for the timer tests: reads happen on the controller's
    /// utility queue while the test mutates `result` / polls `readCount` on main.
    private final class CountingVolumeSpaceReader: VolumeSpaceReading {
        private let lock = NSLock()
        private var _result: VolumeSpace?
        private var _readCount = 0

        init(result: VolumeSpace?) {
            _result = result
        }

        var result: VolumeSpace? {
            get { lock.withLock { _result } }
            set { lock.withLock { _result = newValue } }
        }

        var readCount: Int {
            lock.withLock { _readCount }
        }

        func readBootVolume() -> VolumeSpace? {
            lock.withLock {
                _readCount += 1
                return _result
            }
        }
    }

    // MARK: - IconStatus (pure state + VoiceOver sentence)

    func testIconStatusMapsFreeSpaceThroughThresholds() {
        let config = ThresholdConfiguration.default
        XCTAssertEqual(status(free: 8_000_000_000, configuration: config).state, .red)
        XCTAssertEqual(status(free: 15_000_000_000, configuration: config).state, .yellow)
        XCTAssertEqual(status(free: 250_000_000_000, configuration: config).state, .green)
    }

    func testAccessibilityLabelIsHumanSentenceWithStateAndFreeSpace() {
        // Assert against the shared Kit formatter — the single byte-formatting
        // source of truth the label now uses — so the popover rows and the spoken
        // free-space figure can never drift apart.
        let formattedFree = ByteFormat.text(fromBytes: 8_000_000_000)
        XCTAssertEqual(
            status(free: 8_000_000_000, configuration: .default).accessibilityLabel,
            "Disk status: critical, \(formattedFree) free"
        )
    }

    func testSpokenDescriptionsCoverAllStates() {
        XCTAssertEqual(DiskState.green.spokenDescription, "OK")
        XCTAssertEqual(DiskState.yellow.spokenDescription, "low")
        XCTAssertEqual(DiskState.red.spokenDescription, "critical")
    }

    // MARK: - StatusIconRenderer

    func testRenderedImagesAreNonTemplateAtMenuBarSize() {
        let renderer = StatusIconRenderer()
        for state in [DiskState.green, .yellow, .red] {
            let image = renderer.image(
                for: state,
                variant: StatusIconRenderer.Variant(isDark: false, isHighlighted: false)
            )
            XCTAssertFalse(image.isTemplate, "\(state) icon must be non-template to carry real color")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        }
    }

    func testEachStateRendersDistinctly() {
        let variant = StatusIconRenderer.Variant(isDark: false, isHighlighted: false)
        let green = pixels(state: .green, variant: variant)
        let yellow = pixels(state: .yellow, variant: variant)
        let red = pixels(state: .red, variant: variant)
        XCTAssertNotEqual(green, yellow)
        XCTAssertNotEqual(green, red)
        XCTAssertNotEqual(yellow, red, "red must differ in shape, not only hue")
    }

    func testLightDarkAndHighlightedVariantsRenderDistinctly() {
        let light = pixels(state: .green, variant: StatusIconRenderer.Variant(isDark: false, isHighlighted: false))
        let dark = pixels(state: .green, variant: StatusIconRenderer.Variant(isDark: true, isHighlighted: false))
        let highlighted = pixels(state: .green, variant: StatusIconRenderer.Variant(isDark: false, isHighlighted: true))
        XCTAssertNotEqual(light, dark)
        XCTAssertNotEqual(light, highlighted)
    }

    // MARK: - IconController against a real status bar button

    func testRefreshUpdatesIconAndAccessibilityLabel() {
        let button = makeButton()
        let controller = IconController(
            button: button,
            reader: MockVolumeSpaceReader(result: VolumeSpace(free: 8_000_000_000, total: 500_000_000_000)),
            thresholdStore: makeStore()
        )
        let initialImage = button.image?.tiffRepresentation
        XCTAssertNotNil(initialImage, "icon must be drawn immediately, before the first read")
        controller.refresh()
        withExtendedLifetime(controller) {
            XCTAssertTrue(waitUntil { button.accessibilityLabel()?.contains("critical") == true })
            let label = button.accessibilityLabel() ?? ""
            XCTAssertTrue(label.hasPrefix("Disk status: critical, "), "unexpected label: \(label)")
            XCTAssertTrue(label.hasSuffix(" free"), "unexpected label: \(label)")
            XCTAssertNotEqual(button.image?.tiffRepresentation, initialImage, "red icon must replace the initial one")
            XCTAssertNotNil(button.alternateImage, "highlighted variant must be provided")
        }
    }

    func testFailedReadKeepsIconAndReportsUnavailable() {
        let button = makeButton()
        let controller = IconController(
            button: button,
            reader: MockVolumeSpaceReader(result: nil),
            thresholdStore: makeStore()
        )
        let initialImage = button.image?.tiffRepresentation
        controller.refresh()
        withExtendedLifetime(controller) {
            XCTAssertTrue(waitUntil { button.accessibilityLabel() == IconStatus.unavailableAccessibilityLabel })
            XCTAssertEqual(button.image?.tiffRepresentation, initialImage, "keep last known icon on a failed read")
        }
    }

    func testAppearanceFlipRedrawsIcon() {
        let button = makeButton()
        button.appearance = NSAppearance(named: .aqua)
        let controller = IconController(
            button: button,
            reader: MockVolumeSpaceReader(result: VolumeSpace(free: 250_000_000_000, total: 500_000_000_000)),
            thresholdStore: makeStore()
        )
        controller.refresh()
        withExtendedLifetime(controller) {
            XCTAssertTrue(waitUntil { button.accessibilityLabel()?.contains("OK") == true })
            let lightImage = button.image?.tiffRepresentation
            button.appearance = NSAppearance(named: .darkAqua)
            XCTAssertTrue(
                waitUntil { button.image?.tiffRepresentation != lightImage },
                "icon must re-render when the effective appearance changes"
            )
        }
    }

    // MARK: - Periodic refresh timer (ICON-004)

    func testPeriodicTimerRefreshesIconWithoutManualRefresh() {
        let button = makeButton()
        let reader = CountingVolumeSpaceReader(
            result: VolumeSpace(free: 8_000_000_000, total: 500_000_000_000)
        )
        let controller = IconController(
            button: button,
            reader: reader,
            thresholdStore: makeStore(),
            refreshInterval: 0.05,
            workspaceNotificationCenter: NotificationCenter()
        )
        controller.startPeriodicRefresh()
        withExtendedLifetime(controller) {
            XCTAssertTrue(
                waitUntil { button.accessibilityLabel()?.contains("critical") == true },
                "timer tick must refresh the icon without a manual refresh() call"
            )
            // Free space crosses back above the thresholds → next tick must pick it up.
            reader.result = VolumeSpace(free: 250_000_000_000, total: 500_000_000_000)
            XCTAssertTrue(
                waitUntil { button.accessibilityLabel()?.contains("OK") == true },
                "icon must update within one tick after free space changes"
            )
        }
    }

    func testUnchangedStatusDoesNotRebuildIconImages() {
        let button = makeButton()
        let reader = CountingVolumeSpaceReader(
            result: VolumeSpace(free: 8_000_000_000, total: 500_000_000_000)
        )
        let controller = IconController(
            button: button,
            reader: reader,
            thresholdStore: makeStore(),
            refreshInterval: 0.05,
            workspaceNotificationCenter: NotificationCenter()
        )
        controller.startPeriodicRefresh()
        withExtendedLifetime(controller) {
            XCTAssertTrue(waitUntil { button.accessibilityLabel()?.contains("critical") == true })
            let appliedImage = button.image
            let appliedAlternateImage = button.alternateImage
            let ticksSoFar = reader.readCount
            XCTAssertTrue(waitUntil { reader.readCount >= ticksSoFar + 2 }, "timer must keep ticking")
            // Drain the main queue so those ticks' apply() calls have landed.
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertTrue(
                button.image === appliedImage && button.alternateImage === appliedAlternateImage,
                "an unchanged status must not rebuild or reassign the icon images"
            )
        }
    }

    func testRecoveryAfterFailedReadRestoresAccessibilityLabel() {
        let button = makeButton()
        let reader = CountingVolumeSpaceReader(
            result: VolumeSpace(free: 8_000_000_000, total: 500_000_000_000)
        )
        let controller = IconController(
            button: button,
            reader: reader,
            thresholdStore: makeStore(),
            refreshInterval: 0.05,
            workspaceNotificationCenter: NotificationCenter()
        )
        controller.startPeriodicRefresh()
        withExtendedLifetime(controller) {
            XCTAssertTrue(waitUntil { button.accessibilityLabel()?.contains("critical") == true })
            reader.result = nil
            XCTAssertTrue(waitUntil { button.accessibilityLabel() == IconStatus.unavailableAccessibilityLabel })
            // Recovery returns the *same* status as before the failure — the
            // change gate must still restore the real label.
            reader.result = VolumeSpace(free: 8_000_000_000, total: 500_000_000_000)
            XCTAssertTrue(
                waitUntil { button.accessibilityLabel()?.contains("critical") == true },
                "recovery with an identical status must replace the unavailable label"
            )
        }
    }

    func testWakeNotificationTriggersImmediateRefresh() {
        let button = makeButton()
        let reader = CountingVolumeSpaceReader(
            result: VolumeSpace(free: 8_000_000_000, total: 500_000_000_000)
        )
        let center = NotificationCenter()
        let controller = IconController(
            button: button,
            reader: reader,
            thresholdStore: makeStore(),
            refreshInterval: 3600, // never ticks within this test
            workspaceNotificationCenter: center
        )
        controller.startPeriodicRefresh()
        withExtendedLifetime(controller) {
            XCTAssertEqual(reader.readCount, 0, "nothing should read before the wake notification")
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            XCTAssertTrue(
                waitUntil { button.accessibilityLabel()?.contains("critical") == true },
                "wake must refresh immediately instead of waiting a full tick"
            )
        }
    }

    func testStartPeriodicRefreshIsIdempotent() {
        let button = makeButton()
        let reader = CountingVolumeSpaceReader(
            result: VolumeSpace(free: 8_000_000_000, total: 500_000_000_000)
        )
        let center = NotificationCenter()
        let controller = IconController(
            button: button,
            reader: reader,
            thresholdStore: makeStore(),
            refreshInterval: 3600, // never ticks within this test
            workspaceNotificationCenter: center
        )
        controller.startPeriodicRefresh()
        controller.startPeriodicRefresh()
        withExtendedLifetime(controller) {
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            XCTAssertTrue(waitUntil { reader.readCount >= 1 })
            // Drain a little longer: a duplicate wake observer or timer would
            // surface as a second read.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(reader.readCount, 1, "duplicate start must not double the firing")
        }
    }

    // MARK: - Helpers

    private func status(free: Int64, configuration: ThresholdConfiguration) -> IconStatus {
        IconStatus(space: VolumeSpace(free: free, total: 500_000_000_000), configuration: configuration)
    }

    private func pixels(state: DiskState, variant: StatusIconRenderer.Variant) -> Data? {
        StatusIconRenderer().image(for: state, variant: variant).tiffRepresentation
    }

    private func makeButton() -> NSStatusBarButton {
        NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    }

    /// Isolated `UserDefaults` suite per test so the standard domain is never touched.
    private func makeStore(function: String = #function) -> ThresholdConfigurationStore {
        ThresholdConfigurationStore(defaults: makeIsolatedDefaults(function: function))
    }

    /// Drains the main run loop until `condition` holds or the timeout passes.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
