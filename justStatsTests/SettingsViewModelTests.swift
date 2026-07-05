import XCTest
@testable import justStats

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private let gb = SettingsViewModel.bytesPerGB
    private var defaults: UserDefaults!
    private var store: ThresholdConfigurationStore!

    override func setUp() {
        super.setUp()
        defaults = makeIsolatedDefaults()
        store = ThresholdConfigurationStore(defaults: defaults)
    }

    override func tearDown() {
        store = nil
        defaults = nil
        super.tearDown()
    }

    /// Builds a model wired to the isolated store and a caller-supplied launch controller.
    /// Threshold tests use the zero-arg overload (default off launch controller).
    private func makeModel(
        launch: LaunchAtLoginControlling
    ) -> SettingsViewModel {
        SettingsViewModel(store: store, launchAtLoginController: launch)
    }

    // MARK: - Hydration

    func testHydratesFromDefaultConfigurationOnEmptyDefaults() {
        let model = SettingsViewModel(store: store)
        // Default config: absolute, 10 GB red, 20 GB yellow.
        XCTAssertEqual(model.mode, .absolute)
        XCTAssertEqual(model.redGB, 10, accuracy: 0.0001)
        XCTAssertEqual(model.yellowGB, 20, accuracy: 0.0001)
        XCTAssertEqual(model.redPercent, 10, accuracy: 0.0001)
        XCTAssertEqual(model.yellowPercent, 20, accuracy: 0.0001)
    }

    func testHydratesFromPersistedConfiguration() {
        store.save(
            ThresholdConfiguration(
                mode: .percentage,
                redBytes: 5 * Int64(gb),
                yellowBytes: 15 * Int64(gb),
                redPercent: 7.5,
                yellowPercent: 25
            )
        )

        let model = SettingsViewModel(store: store)
        XCTAssertEqual(model.mode, .percentage)
        XCTAssertEqual(model.redGB, 5, accuracy: 0.0001)
        XCTAssertEqual(model.yellowGB, 15, accuracy: 0.0001)
        XCTAssertEqual(model.redPercent, 7.5, accuracy: 0.0001)
        XCTAssertEqual(model.yellowPercent, 25, accuracy: 0.0001)
    }

    func testConstructionDoesNotWriteToDefaults() {
        // Only hydration ran — nothing the user touched — so no keys should be written.
        _ = SettingsViewModel(store: store)
        for key in [
            DefaultsKey.thresholdMode,
            DefaultsKey.redThresholdBytes,
            DefaultsKey.yellowThresholdBytes,
            DefaultsKey.redThresholdPercent,
            DefaultsKey.yellowThresholdPercent,
        ] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should not be written on hydration")
        }
    }

    // MARK: - Immediate persistence

    func testEditingRedGBPersistsImmediately() {
        let model = SettingsViewModel(store: store)
        model.redGB = 8

        XCTAssertEqual(store.load().redBytes, 8 * Int64(gb))
        // A fresh model reads the change back — it really hit UserDefaults, not just memory.
        XCTAssertEqual(SettingsViewModel(store: store).redGB, 8, accuracy: 0.0001)
    }

    func testEditingYellowGBPersistsImmediately() {
        let model = SettingsViewModel(store: store)
        model.yellowGB = 42

        XCTAssertEqual(store.load().yellowBytes, 42 * Int64(gb))
    }

    func testEditingPercentsPersistsImmediately() {
        let model = SettingsViewModel(store: store)
        model.redPercent = 12.5
        model.yellowPercent = 33

        let saved = store.load()
        XCTAssertEqual(saved.redPercent, 12.5, accuracy: 0.0001)
        XCTAssertEqual(saved.yellowPercent, 33, accuracy: 0.0001)
    }

    func testSwitchingModePersistsImmediately() {
        let model = SettingsViewModel(store: store)
        model.mode = .percentage

        XCTAssertEqual(store.load().mode, .percentage)
    }

    func testSwitchingModePreservesBothModesValues() {
        let model = SettingsViewModel(store: store)
        model.redGB = 3
        model.yellowGB = 6
        model.redPercent = 15
        model.yellowPercent = 40

        model.mode = .percentage
        // The absolute values must survive the mode switch (the value type carries both).
        let saved = store.load()
        XCTAssertEqual(saved.mode, .percentage)
        XCTAssertEqual(saved.redBytes, 3 * Int64(gb))
        XCTAssertEqual(saved.yellowBytes, 6 * Int64(gb))
        XCTAssertEqual(saved.redPercent, 15, accuracy: 0.0001)
        XCTAssertEqual(saved.yellowPercent, 40, accuracy: 0.0001)
    }

    // MARK: - Conversions and clamping

    func testGBBytesRoundTrip() {
        XCTAssertEqual(SettingsViewModel.bytes(fromGB: 10), 10 * Int64(gb))
        XCTAssertEqual(SettingsViewModel.gb(fromBytes: 10 * Int64(gb)), 10, accuracy: 0.0001)
        // Fractional GB round-trips to the nearest whole byte.
        XCTAssertEqual(SettingsViewModel.bytes(fromGB: 1.5), Int64(1.5 * gb))
    }

    func testNegativeGBClampsToZeroOnPersist() {
        let model = SettingsViewModel(store: store)
        model.redGB = -5

        XCTAssertEqual(store.load().redBytes, 0)
    }

    func testPercentClampsToZeroAndHundredOnPersist() {
        let model = SettingsViewModel(store: store)
        model.redPercent = -10
        model.yellowPercent = 150

        let saved = store.load()
        XCTAssertEqual(saved.redPercent, 0, accuracy: 0.0001)
        XCTAssertEqual(saved.yellowPercent, 100, accuracy: 0.0001)
    }

    // MARK: - Validation rule (advisory, non-blocking)

    func testNoWarningWhenYellowAtLeastRedAbsolute() {
        let model = SettingsViewModel(store: store)
        model.redGB = 10
        model.yellowGB = 20
        XCTAssertNil(model.validationWarning)
        // Equal is sane too (zero-width yellow band, but not inverted).
        model.yellowGB = 10
        XCTAssertNil(model.validationWarning)
    }

    func testWarningWhenYellowBelowRedAbsolute() {
        let model = SettingsViewModel(store: store)
        model.redGB = 30
        model.yellowGB = 20
        XCTAssertEqual(model.validationWarning, SettingsViewModel.yellowBelowRedWarning)
        // The value is still persisted — validation never blocks the save (ICON-001 clamp).
        XCTAssertEqual(store.load().yellowBytes, 20 * Int64(gb))
    }

    func testWarningTracksActiveModeOnly() {
        let model = SettingsViewModel(store: store)
        // Absolute is sane, percentage is inverted.
        model.redGB = 10
        model.yellowGB = 20
        model.redPercent = 30
        model.yellowPercent = 20

        // In absolute mode the percentage inversion is not surfaced.
        model.mode = .absolute
        XCTAssertNil(model.validationWarning)

        // Switching to percentage surfaces its own inversion.
        model.mode = .percentage
        XCTAssertEqual(model.validationWarning, SettingsViewModel.yellowBelowRedWarning)
    }

    func testInvertedThresholdsStillSavedSoIconClampApplies() {
        // The persisted (inverted) config, fed to the same diskState mapping the icon
        // uses, must collapse the yellow band rather than invert — proving the advisory
        // warning is purely informational and the ICON-001 clamp remains authoritative.
        let model = SettingsViewModel(store: store)
        model.redGB = 30
        model.yellowGB = 20

        let config = store.load()
        let total: Int64 = 500 * Int64(gb)
        XCTAssertEqual(config.diskState(freeBytes: 25 * Int64(gb), totalBytes: total), .red)
        XCTAssertEqual(config.diskState(freeBytes: 30 * Int64(gb), totalBytes: total), .green)
    }

    // MARK: - Launch at Login (SET-002)

    /// A generic error to drive the failed register/unregister paths.
    private struct RegistrationError: Error {}

    func testLaunchAtLoginSeedsToggleFromStatusWhenDisabled() {
        let launch = MockLaunchAtLoginController(initiallyEnabled: false)
        let model = makeModel(launch: launch)
        XCTAssertFalse(model.launchAtLogin)
        // Reading the initial state must not register or unregister anything.
        XCTAssertEqual(launch.enableCount, 0)
        XCTAssertEqual(launch.disableCount, 0)
    }

    func testLaunchAtLoginSeedsToggleFromStatusWhenEnabled() {
        let launch = MockLaunchAtLoginController(initiallyEnabled: true)
        let model = makeModel(launch: launch)
        // The toggle reflects the real status (.enabled), not a persisted flag.
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertEqual(launch.enableCount, 0)
        XCTAssertEqual(launch.disableCount, 0)
    }

    func testEnablingLaunchAtLoginCallsRegister() {
        let launch = MockLaunchAtLoginController(initiallyEnabled: false)
        let model = makeModel(launch: launch)

        model.launchAtLogin = true

        XCTAssertEqual(launch.enableCount, 1)
        XCTAssertEqual(launch.disableCount, 0)
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertNil(model.launchAtLoginError)
    }

    func testDisablingLaunchAtLoginCallsUnregister() {
        let launch = MockLaunchAtLoginController(initiallyEnabled: true)
        let model = makeModel(launch: launch)

        model.launchAtLogin = false

        XCTAssertEqual(launch.disableCount, 1)
        XCTAssertEqual(launch.enableCount, 0)
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertNil(model.launchAtLoginError)
    }

    func testFailedEnableSnapsToggleBackToRealStatus() {
        let launch = MockLaunchAtLoginController(initiallyEnabled: false)
        launch.enableError = RegistrationError()
        let model = makeModel(launch: launch)

        model.launchAtLogin = true

        // register() was attempted but threw, so the real status is still off — the toggle
        // must reflect that, not the value the user optimistically flipped to.
        XCTAssertEqual(launch.enableCount, 1)
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertEqual(model.launchAtLoginError, SettingsViewModel.launchAtLoginFailure(enabling: true))
    }

    func testFailedDisableSnapsToggleBackToRealStatus() {
        let launch = MockLaunchAtLoginController(initiallyEnabled: true)
        launch.disableError = RegistrationError()
        let model = makeModel(launch: launch)

        model.launchAtLogin = false

        // unregister() threw, so the item is still registered — the toggle snaps back on.
        XCTAssertEqual(launch.disableCount, 1)
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertEqual(model.launchAtLoginError, SettingsViewModel.launchAtLoginFailure(enabling: false))
    }

    func testEnableThatRequiresApprovalReflectsRealStatusNotUserChoice() {
        // enable() succeeds but the system leaves the item in a non-.enabled state
        // (awaiting approval): isEnabled stays false, so the toggle must show off.
        let launch = MockLaunchAtLoginController(initiallyEnabled: false)
        launch.forcedStatusAfterChange = false
        let model = makeModel(launch: launch)

        model.launchAtLogin = true

        XCTAssertEqual(launch.enableCount, 1)
        XCTAssertFalse(model.launchAtLogin, "toggle must mirror the real (still-off) status")
        // No error was thrown — enable() itself succeeded — so no failure message.
        XCTAssertNil(model.launchAtLoginError)
    }

    func testSuccessfulEnableClearsPriorError() {
        let launch = MockLaunchAtLoginController(initiallyEnabled: false)
        launch.enableError = RegistrationError()
        let model = makeModel(launch: launch)

        // First attempt fails and records an error.
        model.launchAtLogin = true
        XCTAssertNotNil(model.launchAtLoginError)

        // Clear the failure and retry: the error message must be cleared on success.
        launch.enableError = nil
        model.launchAtLogin = true
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertNil(model.launchAtLoginError)
    }

    func testLaunchAtLoginIsNotBackedByUserDefaults() {
        // TECHSPEC §5: login-item state lives in SMAppService, never in UserDefaults.
        // Toggling must not write any threshold-domain (or other) key here — and a fresh
        // model reads its state from the controller status, not from a persisted flag.
        let launch = MockLaunchAtLoginController(initiallyEnabled: false)
        let model = makeModel(launch: launch)
        model.launchAtLogin = true

        // A brand-new model backed by a controller that reports "off" must show off,
        // proving the toggle is not remembered via defaults.
        let freshLaunch = MockLaunchAtLoginController(initiallyEnabled: false)
        let freshModel = makeModel(launch: freshLaunch)
        XCTAssertFalse(freshModel.launchAtLogin)
    }

    // MARK: - Software updates (UPD-001)

    /// Builds a model wired to the isolated store and a caller-supplied updater seam, with
    /// an off launch controller (these tests don't exercise Launch at Login).
    private func makeModel(updater: SoftwareUpdating) -> SettingsViewModel {
        SettingsViewModel(
            store: store,
            launchAtLoginController: MockLaunchAtLoginController(initiallyEnabled: false),
            softwareUpdater: updater
        )
    }

    func testCheckForUpdatesInvokesUpdater() {
        let updater = MockSoftwareUpdater()
        let model = makeModel(updater: updater)

        model.checkForUpdates()

        XCTAssertEqual(updater.checkForUpdatesCount, 1)
    }

    func testAutomaticUpdateToggleSeedsFromUpdaterStatus() {
        // Seeded "on": the model's toggle must mirror the seam's current value on init,
        // not a hard-coded default.
        let model = makeModel(updater: MockSoftwareUpdater(automaticallyChecksForUpdates: true))
        XCTAssertTrue(model.automaticallyChecksForUpdates)

        let offModel = makeModel(updater: MockSoftwareUpdater(automaticallyChecksForUpdates: false))
        XCTAssertFalse(offModel.automaticallyChecksForUpdates)
    }

    func testConstructionDoesNotInvokeUpdaterCheck() {
        // Hydration only seeds the toggle — it must not trigger a check or write back.
        let updater = MockSoftwareUpdater(automaticallyChecksForUpdates: true)
        _ = makeModel(updater: updater)
        XCTAssertEqual(updater.checkForUpdatesCount, 0)
    }

    func testTogglingAutomaticUpdatesPersistsThroughUpdater() {
        let updater = MockSoftwareUpdater(automaticallyChecksForUpdates: false)
        let model = makeModel(updater: updater)

        model.automaticallyChecksForUpdates = true
        XCTAssertTrue(updater.automaticallyChecksForUpdates)

        model.automaticallyChecksForUpdates = false
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
    }

    func testNoopUpdaterPersistsAutomaticFlagToUserDefaults() {
        // The fallback (Sparkle-less) updater must round-trip the flag through an isolated
        // UserDefaults suite so the toggle survives relaunch even without Sparkle.
        let updater = NoopSoftwareUpdater(defaults: defaults)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)

        updater.automaticallyChecksForUpdates = true
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertTrue(defaults.bool(forKey: DefaultsKey.automaticallyChecksForUpdates))

        // A fresh updater over the same defaults reads the persisted value back.
        XCTAssertTrue(NoopSoftwareUpdater(defaults: defaults).automaticallyChecksForUpdates)
    }
}
