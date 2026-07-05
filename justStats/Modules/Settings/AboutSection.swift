import AppKit
import SwiftUI

/// The "About" section of the Settings window (SET-005): the app name and version, a link
/// to the source repository on GitHub, the license line, and a "Quit justStats" button
/// (UX-005). Rendered as a standard grouped `Form` `Section` so it inherits the window's
/// native light/dark styling and matches the threshold/General/Updates sections above it.
///
/// Native and minimal by design (macos-app-design: prefer system components):
/// - `LabeledContent` for the version and license rows — the system's label/value layout.
/// - SwiftUI `Link` for GitHub, which opens the URL in the default browser via the system
///   open handler (no `NSWorkspace` plumbing, no in-app web view) and is keyboard- and
///   VoiceOver-accessible out of the box; an explicit accessibility label names the
///   destination.
///
/// The facts come from `AboutInfo` (version derived from the bundle behind a testable
/// seam), so this view is a thin presentation layer.
struct AboutSection: View {
    /// Injected so previews and tests can supply a known version; production uses the
    /// default `AboutInfo(provider: Bundle.main)`.
    let about: AboutInfo

    /// The action run when the "Quit justStats" button is pressed. Injected as a seam
    /// (UX-005) so a test can assert the button is wired without actually terminating the
    /// test process; production defaults to the shared `AboutInfo.quit` — the standard
    /// menu-bar quit (no confirmation) that the popover footer (UX-009) also uses, one
    /// source of truth. ⌘Q is provided separately by the app's main menu (`SettingsMenu`),
    /// so this button is the pointer affordance.
    let quit: () -> Void

    init(
        about: AboutInfo = AboutInfo(),
        quit: @escaping () -> Void = AboutInfo.quit
    ) {
        self.about = about
        self.quit = quit
    }

    var body: some View {
        Section {
            LabeledContent("Version") {
                Text(about.versionLine)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Version")
            .accessibilityValue(about.versionLine)

            // Real GitHub brand mark (UX-012) rather than a generic external-link glyph:
            // SF Symbols has no GitHub logo, so this uses the shared `GitHubMarkLabel`
            // (the Octocat `Shape`) that the popover footer renders too — one source of
            // truth. It's tintable, so it inherits the link's color and adapts to
            // light/dark like the rest of the label.
            Link(destination: AboutInfo.repositoryURL) {
                GitHubMarkLabel(title: "View on GitHub")
            }
            .accessibilityLabel("View justStats on GitHub")
            .accessibilityHint("Opens the source repository in your browser")

            LabeledContent("License") {
                Text(AboutInfo.license)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("License")
            .accessibilityValue(AboutInfo.license)

            // Quit control (UX-005): a menu-bar (LSUIElement) app has no Dock or app
            // menu, so this is the pointer way to quit; ⌘Q is wired separately via the
            // app's main menu. No confirmation — standard for a menu-bar quit.
            Button("Quit justStats", role: .destructive) {
                quit()
            }
            .accessibilityLabel("Quit justStats")
            .accessibilityHint("Quits the app")
        } header: {
            Text("About")
                .font(.headline)
        }
    }
}
