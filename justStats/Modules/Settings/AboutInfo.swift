import AppKit
import Foundation

/// The minimal read-only view of bundle metadata the About section needs (SET-005).
/// Abstracted behind a protocol so the version-string derivation is unit-testable with a
/// mock info dictionary — the tests never depend on the real running bundle, which carries
/// whatever version the test host happens to build with. `Bundle` conforms in production;
/// tests inject a stub.
protocol AboutInfoProviding {
    /// A value from the bundle's Info.plist (`CFBundleShortVersionString`,
    /// `CFBundleVersion`, …), or `nil` when the key is absent.
    func infoValue(forKey key: String) -> String?
}

extension Bundle: AboutInfoProviding {
    func infoValue(forKey key: String) -> String? {
        // `object(forInfoDictionaryKey:)` reads the localized info dictionary when present,
        // which is what we want for user-facing strings. Cast defensively: a non-string
        // value (never expected for these keys) reads as absent rather than crashing.
        object(forInfoDictionaryKey: key) as? String
    }
}

/// Static "About" facts for the Settings section (SET-005): the app's display name and
/// version, its source-repository URL, and its license. Kept as a pure value type with the
/// version derived from an injected `AboutInfoProviding`, so the display string is unit
/// tested without the real bundle.
///
/// Native/minimal by design (macos-app-design: prefer system components) — this type only
/// supplies strings; the SwiftUI `AboutSection` renders them with standard `Form`
/// controls (`LabeledContent`, `Link`).
struct AboutInfo {
    /// The app's display name, e.g. `"justStats"`. Fixed rather than read from the bundle
    /// so the About line reads the same in tests and in every build variant.
    static let appName = "justStats"

    /// The source repository, opened in the default browser by the "View on GitHub" link.
    static let repositoryURL = URL(string: "https://github.com/zanybaka/justStats")!

    /// The license the project ships under (see `LICENSE`). Displayed verbatim.
    static let license = "MIT"

    /// The standard menu-bar quit — `NSApplication.shared.terminate(nil)`, no
    /// confirmation. Factored here as the single source of truth (UX-009) so both the
    /// Settings About section (UX-005) and the popover footer default their "Quit"
    /// control to the *same* action rather than each hardcoding the AppKit call. Both
    /// still inject a seam in tests so the process is never actually terminated.
    @MainActor
    static let quit: () -> Void = { NSApplication.shared.terminate(nil) }

    /// The Info.plist keys the version string is built from — the standard Apple keys for
    /// the marketing version and the build number.
    private static let shortVersionKey = "CFBundleShortVersionString"
    private static let buildVersionKey = "CFBundleVersion"

    /// The full "justStats X.Y.Z (build)" line shown at the top of the About section,
    /// e.g. `"justStats 0.1.0 (1)"`.
    let versionLine: String

    /// The bare marketing version (`CFBundleShortVersionString`), e.g. `"0.1.0"`.
    let shortVersion: String

    /// The build number (`CFBundleVersion`), e.g. `"1"`.
    let buildVersion: String

    /// Derives the About facts from a bundle-like info provider. Defaults to `Bundle.main`
    /// in production; tests pass a stub dictionary so the derivation is verified against
    /// known inputs.
    ///
    /// Missing keys degrade gracefully to placeholders rather than crashing or showing an
    /// empty line: an absent marketing version reads as `"—"` and an absent build number
    /// drops the `(build)` suffix entirely. The About section must always render something
    /// sensible even in a misconfigured build.
    init(provider: AboutInfoProviding = Bundle.main) {
        let short = Self.nonEmpty(provider.infoValue(forKey: Self.shortVersionKey))
        let build = Self.nonEmpty(provider.infoValue(forKey: Self.buildVersionKey))

        shortVersion = short ?? "—"
        buildVersion = build ?? ""

        var line = "\(Self.appName) \(shortVersion)"
        if let build {
            line += " (\(build))"
        }
        versionLine = line
    }

    /// Trims whitespace and treats an empty result as absent, so a blank Info.plist value
    /// is handled the same as a missing key.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
