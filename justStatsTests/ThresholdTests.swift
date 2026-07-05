import XCTest
@testable import justStats

final class ThresholdTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000

    // MARK: - Defaults

    func testDefaultConfiguration() {
        let config = ThresholdConfiguration.default
        XCTAssertEqual(config.mode, .absolute)
        XCTAssertEqual(config.redBytes, 10_000_000_000)
        XCTAssertEqual(config.yellowBytes, 20_000_000_000)
        XCTAssertEqual(config.redPercent, 10)
        XCTAssertEqual(config.yellowPercent, 20)
    }

    // MARK: - Absolute mode

    func testAbsoluteBoundaries() {
        let config = ThresholdConfiguration.default

        XCTAssertEqual(config.diskState(freeBytes: 10 * gb - 1, totalBytes: 500 * gb), .red)
        // Exactly at the red threshold is not "below 10 GB" — yellow, not red.
        XCTAssertEqual(config.diskState(freeBytes: 10 * gb, totalBytes: 500 * gb), .yellow)
        XCTAssertEqual(config.diskState(freeBytes: 20 * gb - 1, totalBytes: 500 * gb), .yellow)
        // Exactly at the yellow threshold is green.
        XCTAssertEqual(config.diskState(freeBytes: 20 * gb, totalBytes: 500 * gb), .green)
        XCTAssertEqual(config.diskState(freeBytes: 300 * gb, totalBytes: 500 * gb), .green)
    }

    func testAbsoluteZeroFreeIsRed() {
        let config = ThresholdConfiguration.default
        XCTAssertEqual(config.diskState(freeBytes: 0, totalBytes: 500 * gb), .red)
        // A completely broken statfs result (0/0) must still land on red, not green.
        XCTAssertEqual(config.diskState(freeBytes: 0, totalBytes: 0), .red)
    }

    func testAbsoluteIgnoresTotal() {
        let config = ThresholdConfiguration.default
        XCTAssertEqual(config.diskState(freeBytes: 30 * gb, totalBytes: 0), .green)
    }

    func testNegativeFreeIsClampedToZero() {
        let config = ThresholdConfiguration.default
        XCTAssertEqual(config.diskState(freeBytes: -1, totalBytes: 500 * gb), .red)
    }

    // MARK: - Percentage mode

    private func percentConfig(red: Double = 10, yellow: Double = 20) -> ThresholdConfiguration {
        var config = ThresholdConfiguration.default
        config.mode = .percentage
        config.redPercent = red
        config.yellowPercent = yellow
        return config
    }

    func testPercentageBoundaries() {
        let config = percentConfig()
        let total = 1_000 * gb

        XCTAssertEqual(config.diskState(freeBytes: 100 * gb - 1, totalBytes: total), .red)
        // Exactly 10% free is not below the 10% red threshold — yellow.
        XCTAssertEqual(config.diskState(freeBytes: 100 * gb, totalBytes: total), .yellow)
        XCTAssertEqual(config.diskState(freeBytes: 200 * gb - 1, totalBytes: total), .yellow)
        // Exactly 20% free is green.
        XCTAssertEqual(config.diskState(freeBytes: 200 * gb, totalBytes: total), .green)
        XCTAssertEqual(config.diskState(freeBytes: 500 * gb, totalBytes: total), .green)
    }

    func testPercentageUsesExactRatioWithoutRounding() {
        let config = percentConfig()

        // 9.6% would round to 10% — must still be red because the exact ratio is below 10%.
        XCTAssertEqual(config.diskState(freeBytes: 96, totalBytes: 1_000), .red)
        // 10.4% would round down to 10% — must be yellow, not red.
        XCTAssertEqual(config.diskState(freeBytes: 104, totalBytes: 1_000), .yellow)
        // 19.6% would round to 20% — must still be yellow, not green.
        XCTAssertEqual(config.diskState(freeBytes: 196, totalBytes: 1_000), .yellow)
        // 20.4% would round down to 20% — green either way, exact ratio is above threshold.
        XCTAssertEqual(config.diskState(freeBytes: 204, totalBytes: 1_000), .green)
    }

    func testPercentageZeroFreeIsRed() {
        let config = percentConfig()
        XCTAssertEqual(config.diskState(freeBytes: 0, totalBytes: 1_000 * gb), .red)
    }

    func testPercentageZeroTotalIsRed() {
        let config = percentConfig()
        // No defined ratio without a capacity — treated as 0% free.
        XCTAssertEqual(config.diskState(freeBytes: 0, totalBytes: 0), .red)
        XCTAssertEqual(config.diskState(freeBytes: 50 * gb, totalBytes: 0), .red)
        XCTAssertEqual(config.diskState(freeBytes: 50 * gb, totalBytes: -1), .red)
    }

    func testPercentageExactFractionalBoundaryIsNotBelowThreshold() {
        let config = percentConfig(red: 12.5, yellow: 20)
        // 12.5% of 1000 bytes is exactly 125 bytes: one byte below crosses to red,
        // exactly at the threshold does not ("below" is strict).
        XCTAssertEqual(config.diskState(freeBytes: 124, totalBytes: 1_000), .red)
        XCTAssertEqual(config.diskState(freeBytes: 125, totalBytes: 1_000), .yellow)
        XCTAssertEqual(config.diskState(freeBytes: 126, totalBytes: 1_000), .yellow)
    }

    func testPercentageBoundaryCrossingOnTotalNotDivisibleBy100() {
        let config = percentConfig()
        // 10% of 333 bytes is 33.3 bytes — no whole-percent rounding, so the
        // crossing happens between 33 and 34 free bytes.
        XCTAssertEqual(config.diskState(freeBytes: 33, totalBytes: 333), .red)
        XCTAssertEqual(config.diskState(freeBytes: 34, totalBytes: 333), .yellow)
    }

    func testPercentageFullyFreeDiskIsGreen() {
        let config = percentConfig()
        XCTAssertEqual(config.diskState(freeBytes: 500 * gb, totalBytes: 500 * gb), .green)
    }

    // MARK: - Zero thresholds (strict "below" at the 0 boundary)

    func testZeroThresholdsNeverTriggerEvenAtZeroFree() {
        var config = ThresholdConfiguration.default
        config.redBytes = 0
        config.yellowBytes = 0
        // 0 free is not below a 0 threshold — zero thresholds disable red/yellow.
        XCTAssertEqual(config.diskState(freeBytes: 0, totalBytes: 500 * gb), .green)

        let percent = percentConfig(red: 0, yellow: 0)
        XCTAssertEqual(percent.diskState(freeBytes: 0, totalBytes: 500 * gb), .green)
    }

    // MARK: - Misconfiguration: yellow below red

    func testAbsoluteYellowBelowRedCollapsesYellowBand() {
        var config = ThresholdConfiguration.default
        config.redBytes = 30 * gb
        config.yellowBytes = 20 * gb // misconfigured: effective yellow = max(20, 30) = 30 GB

        XCTAssertEqual(config.diskState(freeBytes: 15 * gb, totalBytes: 500 * gb), .red)
        // Between the stored yellow (20) and red (30): still red, never yellow-inside-red.
        XCTAssertEqual(config.diskState(freeBytes: 25 * gb, totalBytes: 500 * gb), .red)
        // At the red threshold the yellow band has zero width — straight to green.
        XCTAssertEqual(config.diskState(freeBytes: 30 * gb, totalBytes: 500 * gb), .green)
        XCTAssertEqual(config.diskState(freeBytes: 35 * gb, totalBytes: 500 * gb), .green)
    }

    func testPercentageYellowBelowRedCollapsesYellowBand() {
        let config = percentConfig(red: 30, yellow: 20)
        let total = 1_000 * gb

        XCTAssertEqual(config.diskState(freeBytes: 250 * gb, totalBytes: total), .red)
        XCTAssertEqual(config.diskState(freeBytes: 300 * gb, totalBytes: total), .green)
        XCTAssertEqual(config.diskState(freeBytes: 350 * gb, totalBytes: total), .green)
    }

    // MARK: - UserDefaults-backed store

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = makeIsolatedDefaults()
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    func testLoadFromEmptyDefaultsReturnsDefaultConfiguration() {
        let store = ThresholdConfigurationStore(defaults: defaults)
        XCTAssertEqual(store.load(), .default)
    }

    func testLoadReadsExactKeyNames() {
        // Literal key strings on purpose: the key names are a fixed contract (TECHSPEC §2).
        defaults.set("percentage", forKey: "thresholdMode")
        defaults.set(5_000_000_000 as Int64, forKey: "redThresholdBytes")
        defaults.set(15_000_000_000 as Int64, forKey: "yellowThresholdBytes")
        defaults.set(5.5, forKey: "redThresholdPercent")
        defaults.set(25.0, forKey: "yellowThresholdPercent")

        let config = ThresholdConfigurationStore(defaults: defaults).load()
        XCTAssertEqual(config.mode, .percentage)
        XCTAssertEqual(config.redBytes, 5_000_000_000)
        XCTAssertEqual(config.yellowBytes, 15_000_000_000)
        XCTAssertEqual(config.redPercent, 5.5)
        XCTAssertEqual(config.yellowPercent, 25.0)
    }

    func testLoadFallsBackPerFieldForMissingOrMalformedValues() {
        defaults.set("banana", forKey: "thresholdMode") // unknown mode → default (absolute)
        defaults.set("not a number", forKey: "redThresholdBytes") // wrong type → default
        defaults.set(42_000_000_000 as Int64, forKey: "yellowThresholdBytes")

        let config = ThresholdConfigurationStore(defaults: defaults).load()
        XCTAssertEqual(config.mode, .absolute)
        XCTAssertEqual(config.redBytes, ThresholdConfiguration.default.redBytes)
        XCTAssertEqual(config.yellowBytes, 42_000_000_000)
        XCTAssertEqual(config.redPercent, ThresholdConfiguration.default.redPercent)
    }

    func testSaveLoadRoundtrip() {
        let store = ThresholdConfigurationStore(defaults: defaults)
        let config = ThresholdConfiguration(
            mode: .percentage,
            redBytes: 7 * gb,
            yellowBytes: 21 * gb,
            redPercent: 12.5,
            yellowPercent: 33
        )

        store.save(config)
        XCTAssertEqual(store.load(), config)
    }
}
