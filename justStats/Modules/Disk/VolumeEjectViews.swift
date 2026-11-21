import SwiftUI

/// What a volume row needs to offer Eject (VOL-008): the current eject state plus the
/// callbacks into the view model. A row with no `EjectControls` (boot volume, internal
/// fixed disks, pending rows) draws no button and no panel.
struct EjectControls {
    let state: VolumeListViewModel.EjectState?
    let onEject: () -> Void
    let onRetry: () -> Void
    let onForce: () -> Void
    let onConfirmForce: () -> Void
    let onCancel: () -> Void
}

/// The eject glyph on an external/network row (VOL-008): hover-revealed like the other
/// icon buttons' lift (UX-016) so a resting row stays quiet, but always laid out (no
/// shift on hover) and always reachable by keyboard/VoiceOver.
struct EjectButton: View {
    let volumeName: String
    /// Whether the glyph is visible (pointer over the row); focus/VoiceOver reach it anyway.
    let isRevealed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eject.fill")
        }
        .hoverIconButtonStyle()
        .opacity(isRevealed ? 1 : 0)
        .help("Eject “\(volumeName)”")
        .accessibilityLabel("Eject \(volumeName)")
        .accessibilityHint("Unmounts the volume; if something is using it, names what")
    }
}

/// The inline panel under a row while ejecting or after a refusal (VOL-008) — same
/// in-row pattern as the Move-to-Trash confirmation, not a modal (TECHSPEC §8). It is
/// drawn as its own tinted, outlined plate so a message never reads as part of the
/// row's usage lines, and its actions are real bordered buttons (not link-styled text,
/// which only reads as clickable on hover).
struct EjectPanelView: View {
    let volumeName: String
    let state: VolumeListViewModel.EjectState
    let controls: EjectControls

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .ejecting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Ejecting “\(volumeName)”…")
                        .foregroundStyle(.secondary)
                }
            case .refused(let refusal):
                notice(refusal.message)
                if let hint = refusal.hint {
                    Text(hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions {
                    button("Retry", controls.onRetry)
                    button("Force Eject…", controls.onForce)
                    button("Dismiss", controls.onCancel)
                }
            case .confirmingForce(let refusal):
                notice(refusal.message)
                Text(refusal.warning)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions {
                    button("Force Eject", controls.onConfirmForce, tint: .red)
                    button("Cancel", controls.onCancel)
                }
            case .failed(let message):
                notice(message)
                actions {
                    button("Retry", controls.onRetry)
                    button("Dismiss", controls.onCancel)
                }
            }
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.top, 2)
    }

    /// A real bordered button. `tint` marks the one destructive step (the second tap of
    /// Force Eject) as a filled, red button so it cannot be mistaken for Cancel.
    @ViewBuilder
    private func button(_ title: String, _ action: @escaping () -> Void, tint: Color? = nil) -> some View {
        if let tint {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(tint)
                .clickableCursor()
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .clickableCursor()
        }
    }
}
