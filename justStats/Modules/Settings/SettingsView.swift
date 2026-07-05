import SwiftUI

/// Settings window content (SET-001, PRD FR10, TECHSPEC §1 refinement: AppKit shell,
/// SwiftUI content hosted in an `NSHostingView`). Edits the red/yellow disk thresholds,
/// each as an absolute GB value or a percentage of capacity depending on the mode
/// picker. Every edit is persisted immediately by `SettingsViewModel` and picked up by
/// the icon tier on its next refresh (no restart, no explicit notification).
///
/// SwiftUI is allowed here for the same reason as the popover: this tree lives inside an
/// AppKit-hosted surface (`SettingsWindowController`'s `NSHostingView`), not a SwiftUI
/// `App`/`Settings` scene — the app keeps its `NSApplicationMain` lifecycle (§1).
///
/// A "Launch at Login" toggle (SET-002) sits in its own `General` section below the
/// thresholds, backed by `SMAppService` through the `LaunchAtLoginControlling` seam and
/// reflecting the real registration status (TECHSPEC §5).
///
/// Seam left for the rest of Phase 5 (deliberately not wired here):
/// - SET-003 (open from popover gear / ⌘,): this view is presentation-only; the window
///   controller owns activation, so nothing here needs to change to be opened.
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("Warn based on", selection: $model.mode) {
                    Text("Free space (GB)").tag(ThresholdMode.absolute)
                    Text("Free space (%)").tag(ThresholdMode.percentage)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Threshold mode")
            } header: {
                Text("Disk thresholds")
                    .font(.headline)
            } footer: {
                Text("The menu bar icon turns red below the red threshold and yellow below the yellow threshold.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                switch model.mode {
                case .absolute:
                    ThresholdField(
                        title: "Red below",
                        unit: "GB",
                        value: $model.redGB,
                        range: 0...100_000,
                        step: 1,
                        accessibilityLabel: "Red threshold in gigabytes"
                    )
                    ThresholdField(
                        title: "Yellow below",
                        unit: "GB",
                        value: $model.yellowGB,
                        range: 0...100_000,
                        step: 1,
                        accessibilityLabel: "Yellow threshold in gigabytes"
                    )
                case .percentage:
                    ThresholdField(
                        title: "Red below",
                        unit: "%",
                        value: $model.redPercent,
                        range: 0...100,
                        step: 1,
                        accessibilityLabel: "Red threshold percentage"
                    )
                    ThresholdField(
                        title: "Yellow below",
                        unit: "%",
                        value: $model.yellowPercent,
                        range: 0...100,
                        step: 1,
                        accessibilityLabel: "Yellow threshold percentage"
                    )
                }

                if let warning = model.validationWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(warning)
                }
            }

            Section {
                Toggle("Launch at Login", isOn: $model.launchAtLogin)
                    .accessibilityLabel("Launch at login")

                if let error = model.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(error)
                }
            } header: {
                Text("General")
                    .font(.headline)
            } footer: {
                Text("Start justStats automatically when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically check for updates", isOn: $model.automaticallyChecksForUpdates)
                    .accessibilityLabel("Automatically check for updates")

                Button("Check for Updates…") {
                    model.checkForUpdates()
                }
                .accessibilityLabel("Check for updates")
            } header: {
                Text("Updates")
                    .font(.headline)
            } footer: {
                Text("justStats updates itself from GitHub. The app is unsigned, so the first launch of an update may require right-click \u{2192} Open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AboutSection()
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("justStats settings")
    }
}

/// One labelled threshold input: a title, a numeric field, its unit, and a stepper —
/// factored out so the GB and percentage variants share exactly one layout and only
/// differ in unit, range, and accessibility label. The `TextField` and `Stepper` bind
/// to the same value so typing and stepping stay in sync; the field parses as a plain
/// decimal (locale-independent) so entry is predictable.
private struct ThresholdField: View {
    let title: String
    let unit: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            TextField(
                title,
                value: $value,
                format: .number.precision(.fractionLength(0...2))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 72)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(accessibilityLabel)
            Text(unit)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Stepper(title, value: $value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel("\(accessibilityLabel) stepper")
        }
    }
}
