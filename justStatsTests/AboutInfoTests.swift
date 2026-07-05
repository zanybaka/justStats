import XCTest
@testable import justStats

/// Unit tests for `AboutInfo` (SET-005) — the version-string derivation and the static
/// About facts. The version string is verified against a stubbed info provider so the
/// tests never depend on whatever version the test host bundle happens to build with.
final class AboutInfoTests: XCTestCase {
    /// A stub `AboutInfoProviding` backed by a plain dictionary, standing in for a bundle's
    /// Info.plist. A missing key returns `nil`, matching `Bundle`'s behavior.
    private struct StubInfoProvider: AboutInfoProviding {
        var values: [String: String]
        func infoValue(forKey key: String) -> String? { values[key] }
    }

    private func makeAbout(short: String?, build: String?) -> AboutInfo {
        var values: [String: String] = [:]
        if let short { values["CFBundleShortVersionString"] = short }
        if let build { values["CFBundleVersion"] = build }
        return AboutInfo(provider: StubInfoProvider(values: values))
    }

    // MARK: - Version line

    func testVersionLineCombinesNameShortVersionAndBuild() {
        let about = makeAbout(short: "0.1.0", build: "1")
        XCTAssertEqual(about.versionLine, "justStats 0.1.0 (1)")
        XCTAssertEqual(about.shortVersion, "0.1.0")
        XCTAssertEqual(about.buildVersion, "1")
    }

    func testVersionLineUsesArbitraryVersionAndBuildValues() {
        let about = makeAbout(short: "2.4.11", build: "173")
        XCTAssertEqual(about.versionLine, "justStats 2.4.11 (173)")
    }

    // MARK: - Graceful degradation

    func testMissingBuildDropsTheParenthesizedSuffix() {
        let about = makeAbout(short: "1.2.0", build: nil)
        XCTAssertEqual(about.versionLine, "justStats 1.2.0")
        XCTAssertEqual(about.shortVersion, "1.2.0")
        XCTAssertEqual(about.buildVersion, "")
    }

    func testMissingShortVersionFallsBackToPlaceholder() {
        let about = makeAbout(short: nil, build: "5")
        XCTAssertEqual(about.versionLine, "justStats — (5)")
        XCTAssertEqual(about.shortVersion, "—")
    }

    func testMissingBothVersionsProducesPlaceholderWithoutSuffix() {
        let about = makeAbout(short: nil, build: nil)
        XCTAssertEqual(about.versionLine, "justStats —")
    }

    func testBlankValuesAreTreatedAsMissing() {
        // A whitespace-only Info.plist value degrades the same as an absent key.
        let about = makeAbout(short: "   ", build: "\t")
        XCTAssertEqual(about.versionLine, "justStats —")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        let about = makeAbout(short: " 0.1.0 ", build: " 1 ")
        XCTAssertEqual(about.versionLine, "justStats 0.1.0 (1)")
    }

    // MARK: - Static facts

    func testStaticAboutFacts() {
        XCTAssertEqual(AboutInfo.appName, "justStats")
        XCTAssertEqual(AboutInfo.license, "MIT")
        XCTAssertEqual(
            AboutInfo.repositoryURL.absoluteString,
            "https://github.com/zanybaka/justStats"
        )
    }

    // MARK: - Real bundle

    func testDefaultProviderReadsFromMainBundleWithoutCrashing() {
        // The default `Bundle.main` path must always produce a non-empty, prefixed line —
        // exact numbers depend on the test host build, so only the shape is asserted.
        let about = AboutInfo()
        XCTAssertTrue(about.versionLine.hasPrefix("justStats "))
        XCTAssertFalse(about.shortVersion.isEmpty)
    }
}
