import Foundation

/// Traffic-light state of the boot volume shown in the menu bar icon (PRD FR1, TECHSPEC §2).
enum DiskState: String {
    case green
    case yellow
    case red
}

/// How the red/yellow thresholds are interpreted (PRD FR10, TECHSPEC §2).
enum ThresholdMode: String {
    case absolute
    case percentage
}

/// Plain value type holding both modes' thresholds so switching modes never loses the
/// other mode's values.
struct ThresholdConfiguration: Equatable {
    var mode: ThresholdMode
    var redBytes: Int64
    var yellowBytes: Int64
    var redPercent: Double
    var yellowPercent: Double

    /// PRD FR1/FR10 defaults: red below 10 GB free, yellow below 20 GB free, absolute mode.
    /// Decimal GB (10^9 bytes), matching how Finder and `statfs` report disk sizes.
    /// Percent values (10 / 20) only apply once the user switches to percentage mode.
    static let `default` = ThresholdConfiguration(
        mode: .absolute,
        redBytes: 10_000_000_000,
        yellowBytes: 20_000_000_000,
        redPercent: 10,
        yellowPercent: 20
    )
}

extension ThresholdConfiguration {
    /// Pure mapping (freeBytes, totalBytes, config) → `DiskState`.
    ///
    /// Rules:
    /// - `free < red` → `.red`; else `free < effectiveYellow` → `.yellow`; else `.green`.
    ///   A value exactly at a threshold is not below it ("red < 10 GB" means 10 GB even is not red).
    /// - Misconfiguration guard: `effectiveYellow = max(yellow, red)` — a yellow threshold set
    ///   below red collapses the yellow band instead of inverting the scale.
    /// - Percentage mode compares exact ratios (`free * 100` vs `percent * total`); no rounding
    ///   to whole percents, so 9.6% free against a 10% red threshold is red.
    /// - Percentage mode with a non-positive total has no defined ratio; treated as 0% free → `.red`.
    /// - Negative free byte counts are clamped to zero.
    func diskState(freeBytes: Int64, totalBytes: Int64) -> DiskState {
        let free = max(freeBytes, 0)
        switch mode {
        case .absolute:
            let effectiveYellow = max(yellowBytes, redBytes)
            if free < redBytes { return .red }
            if free < effectiveYellow { return .yellow }
            return .green
        case .percentage:
            guard totalBytes > 0 else { return .red }
            let effectiveYellow = max(yellowPercent, redPercent)
            let scaledFree = Double(free) * 100
            let total = Double(totalBytes)
            if scaledFree < redPercent * total { return .red }
            if scaledFree < effectiveYellow * total { return .yellow }
            return .green
        }
    }
}

/// Loads and persists `ThresholdConfiguration` in `UserDefaults` (injectable for tests).
/// Plain keys, no schema versioning — explicit simplicity call in TECHSPEC §2.
struct ThresholdConfigurationStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Missing or malformed values fall back per-field to `ThresholdConfiguration.default`.
    func load() -> ThresholdConfiguration {
        let fallback = ThresholdConfiguration.default
        let mode = defaults.string(forKey: DefaultsKey.thresholdMode)
            .flatMap(ThresholdMode.init(rawValue:)) ?? fallback.mode
        return ThresholdConfiguration(
            mode: mode,
            redBytes: int64(forKey: DefaultsKey.redThresholdBytes) ?? fallback.redBytes,
            yellowBytes: int64(forKey: DefaultsKey.yellowThresholdBytes) ?? fallback.yellowBytes,
            redPercent: double(forKey: DefaultsKey.redThresholdPercent) ?? fallback.redPercent,
            yellowPercent: double(forKey: DefaultsKey.yellowThresholdPercent) ?? fallback.yellowPercent
        )
    }

    func save(_ configuration: ThresholdConfiguration) {
        defaults.set(configuration.mode.rawValue, forKey: DefaultsKey.thresholdMode)
        defaults.set(configuration.redBytes, forKey: DefaultsKey.redThresholdBytes)
        defaults.set(configuration.yellowBytes, forKey: DefaultsKey.yellowThresholdBytes)
        defaults.set(configuration.redPercent, forKey: DefaultsKey.redThresholdPercent)
        defaults.set(configuration.yellowPercent, forKey: DefaultsKey.yellowThresholdPercent)
    }

    private func int64(forKey key: String) -> Int64? {
        (defaults.object(forKey: key) as? NSNumber)?.int64Value
    }

    private func double(forKey key: String) -> Double? {
        (defaults.object(forKey: key) as? NSNumber)?.doubleValue
    }
}
