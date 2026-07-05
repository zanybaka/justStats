import SwiftUI
import UniformTypeIdentifiers

/// The "largest files" section (ACT-001, PRD FR7, TECHSPEC §8 layout point 3): sits
/// below the volume rows, scoped to one volume (the boot volume by default), listing
/// the top-N largest files with name, size, and a truncated path. Each row offers a
/// Reveal in Finder action; ACT-002 slots a Move-to-Trash action beside it (the row's
/// trailing area is built to take a second control without reshaping).
///
/// SwiftUI is allowed here because this tree lives inside the popover's
/// `NSHostingController` (TECHSPEC §1 refinement: AppKit shell, SwiftUI content).
///
/// State-driven, never on a timer: the view model populates it lazily from
/// `load()`/`refresh()` and this view just renders whatever `LargestFilesState` it is
/// handed — a loading state while the Spotlight scan runs, the ranked rows when it
/// lands, or the "Not indexed" degraded notice (SCAN-005 story) when the scoped volume
/// has no usable index. The `.idle` state renders nothing (no volume scoped yet).
struct LargestFilesSection: View {
    /// The scoped volume's largest-files scan state (ACT-001).
    let state: VolumeListViewModel.LargestFilesState
    /// The scoped volume's display name, for the header and accessibility — `nil`
    /// while no volume is scoped (paired with `.idle`, so nothing renders).
    let volumeName: String?
    /// Reveals a file in Finder. Injected so the section is previewable/testable
    /// without activating Finder; defaults to the production `NSWorkspace` revealer.
    var reveal: (URL) -> Void = { WorkspaceFinderRevealer().reveal($0) }
    /// The file URL currently awaiting a Move-to-Trash confirmation (ACT-002), or
    /// `nil` when no row is armed. The matching row renders its inline confirm buttons
    /// instead of the plain Trash button. Sourced from the view model so exactly one
    /// row is ever in this state.
    var pendingTrashURL: URL?
    /// Inline Move-to-Trash error text per file URL (ACT-002): a locked/permission/
    /// missing failure shows on that row without a modal or crash (TECHSPEC §7).
    var trashErrorMessages: [URL: String] = [:]
    /// First Trash activation for a row — flips it into the inline confirm state.
    var onTrashRequest: (URL) -> Void = { _ in }
    /// Confirm the pending trash — moves the file to the Trash (recoverable).
    var onTrashConfirm: (URL) -> Void = { _ in }
    /// Cancel the pending trash — backs out of the confirm, file untouched.
    var onTrashCancel: (URL) -> Void = { _ in }

    /// Whether the "N hidden" affordance is expanded to reveal the hidden rows (UX-015).
    /// Local view state: a resting section shows only the count + "Show"; expanding lists
    /// the hidden rows with per-row un-hide buttons so the user can bring specific files
    /// back. Collapses back to just the count on "Hide".
    @State private var showingHidden = false

    /// Hide a row (UX-015): removes it from the list and persists the choice so it stays
    /// hidden across sessions. The row can be brought back via the "N hidden" affordance.
    var onHide: (URL) -> Void = { _ in }
    /// The scoped volume's currently-hidden files (UX-015), reconstructed by the view
    /// model — the rows the "N hidden — Show" affordance reveals so the user is never
    /// trapped. Empty when nothing in the current list is hidden (the affordance is absent).
    var hiddenFiles: [LargestFile] = []
    /// Un-hide a single hidden row (UX-015) — restores it to the visible list.
    var onUnhide: (URL) -> Void = { _ in }
    /// Un-hide every hidden row at once (UX-015) — the "un-hide all" escape hatch.
    var onUnhideAll: () -> Void = {}

    /// What the section draws, derived purely from `LargestFilesState`. Extracted as a
    /// plain enum — the same pattern as `VolumeRowView.Content` — so the state → what's-
    /// rendered decision is unit-testable without a SwiftUI host. It collapses the two
    /// in-flight shapes the view cares about (nothing gathered yet vs. a growing best-so-
    /// far list) that the model's single `.scanning(partial:)` case carries.
    enum Presentation: Equatable {
        /// Nothing to show — no volume scoped yet (`.idle`). The section renders nothing.
        case hidden
        /// Scan in flight with no partial gathered yet — the lightweight loading spinner.
        case loading
        /// Scan in flight with a progressive best-so-far list (A2/A3): show these rows now,
        /// under a "Scanning… N found" caption, and keep filling in.
        case scanning([LargestFile])
        /// The final ranked list (possibly empty for an indexed-but-nothing-large volume).
        case available([LargestFile])
        /// The scoped volume has no usable Spotlight index — the "Not indexed" notice.
        case notIndexed

        /// Maps a model state to what the section draws. An in-flight scan splits on
        /// whether any progressive partial has landed: an empty best-so-far is still the
        /// plain `.loading` spinner (no "0 found" caption over an empty list), while a
        /// non-empty one shows those rows progressively. The final states map straight
        /// through. Pure, so the mapping is pinned in tests without rendering the view.
        init(state: VolumeListViewModel.LargestFilesState) {
            switch state {
            case .idle:
                self = .hidden
            case .scanning(let partial):
                self = partial.isEmpty ? .loading : .scanning(partial)
            case .available(let files):
                self = .available(files)
            case .unavailable:
                self = .notIndexed
            }
        }
    }

    var body: some View {
        switch Presentation(state: state) {
        case .hidden:
            // No volume scoped yet (before load, or nothing loaded) — render nothing
            // so the section never shows an empty header.
            EmptyView()
        case .loading:
            // Scan in flight with nothing gathered yet — the lightweight spinner, so
            // the section explains itself instead of appearing empty (A3).
            section { LargestFilesLoadingView() }
        case .scanning(let files):
            // Progressive best-so-far (A2/A3): render the rows AS THEY COME beneath a
            // subtle "Scanning… N found" caption, instead of a blank spinner until the
            // gather finishes. The rows are real gathered files; only the caption marks
            // the list as still filling in.
            section {
                VStack(alignment: .leading, spacing: 6) {
                    LargestFilesScanningCaption(foundCount: files.count)
                    fileRows(files)
                    hiddenAffordance
                }
            }
        case .available(let files):
            section {
                if files.isEmpty && hiddenFiles.isEmpty {
                    // Indexed volume with no rankable files (rare, but real): say so
                    // plainly rather than showing a bare header.
                    LargestFilesEmptyView()
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        fileRows(files)
                        hiddenAffordance
                    }
                }
            }
        case .notIndexed:
            section { LargestFilesNotIndexedView(volumeName: volumeName) }
        }
    }

    /// The list of largest-file rows, shared by the progressive `.scanning` partial and
    /// the final `.available` states so a row renders identically whether it arrived as a
    /// best-so-far partial or in the final list — keyed by `url`, so as progressive rows
    /// are inserted/reordered SwiftUI keeps each existing row's identity and VoiceOver
    /// focus doesn't churn (A3 accessibility rule).
    @ViewBuilder
    private func fileRows(_ files: [LargestFile]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(files, id: \.url) { file in
                LargestFileRow(
                    file: file,
                    reveal: reveal,
                    isConfirmingTrash: pendingTrashURL == file.url,
                    trashError: trashErrorMessages[file.url],
                    onTrashRequest: onTrashRequest,
                    onTrashConfirm: onTrashConfirm,
                    onTrashCancel: onTrashCancel,
                    onHide: onHide
                )
            }
        }
    }

    /// The "N hidden — Show/Hide" affordance and, when expanded, the hidden rows with
    /// per-row un-hide buttons (UX-015). Rendered beneath the visible list so a user who
    /// hid a file is never trapped: the count is always visible when anything is hidden,
    /// and expanding it lets them restore a specific file or all of them. Absent entirely
    /// when nothing is hidden.
    @ViewBuilder
    private var hiddenAffordance: some View {
        if !hiddenFiles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: DiskMetrics.inlineSpacing) {
                    Button {
                        showingHidden.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showingHidden ? "chevron.down" : "chevron.right")
                                .imageScale(.small)
                            Text(Self.hiddenCountText(hiddenFiles.count))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .clickableCursor()
                    .accessibilityLabel(Self.hiddenToggleAccessibilityLabel(
                        count: hiddenFiles.count, expanded: showingHidden
                    ))
                    if showingHidden {
                        Button("Unhide all") { onUnhideAll() }
                            .buttonStyle(.borderless)
                            .clickableCursor()
                            .font(.caption)
                            .accessibilityLabel("Unhide all \(hiddenFiles.count) hidden files")
                    }
                }
                if showingHidden {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(hiddenFiles, id: \.url) { file in
                            HiddenFileRow(file: file, onUnhide: onUnhide)
                        }
                    }
                }
            }
        }
    }

    /// "1 hidden" / "N hidden" — the resting affordance label. Pure/static so the exact
    /// wording (including the singular/plural) is unit-testable without a SwiftUI host.
    static func hiddenCountText(_ count: Int) -> String {
        count == 1 ? "1 hidden" : "\(count) hidden"
    }

    /// Spoken label for the show/hide toggle, spelling out the action so VoiceOver reads
    /// "Show 2 hidden files" rather than a bare chevron + count. Pure/static for testing.
    static func hiddenToggleAccessibilityLabel(count: Int, expanded: Bool) -> String {
        let noun = count == 1 ? "hidden file" : "hidden files"
        return expanded ? "Hide the \(count) \(noun)" : "Show \(count) \(noun)"
    }

    /// Header ("Largest files on <volume>") plus the state-specific content beneath it,
    /// shared by every non-idle case so the header is written once.
    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerText)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Largest files on Macintosh HD", or a bare "Largest files" if the volume name
    /// isn't known yet (shouldn't happen in a non-idle state, but kept safe).
    private var headerText: String {
        if let volumeName { return "Largest files on \(volumeName)" }
        return "Largest files"
    }
}

/// One file in the largest-files list (ACT-001/002): its name, formatted size, and a
/// middle-truncated path, plus Reveal-in-Finder and Move-to-Trash actions. The trailing
/// controls live in their own `HStack` so the two actions sit side by side without
/// touching the name/size/path layout.
///
/// **Inline trash confirmation (ACT-002, TECHSPEC §8):** the Trash button is a two-step
/// affordance, never a modal. First click (`onTrashRequest`) flips the row into a
/// confirm state — `isConfirmingTrash` — where the trailing cluster shows "Move to
/// Trash?" with inline Confirm/Cancel controls. Confirm (`onTrashConfirm`) moves the
/// file to the Trash (recoverable — the view model uses `FileManager.trashItem`, never
/// a permanent delete); Cancel (`onTrashCancel`) backs out untouched. A failure surfaces
/// as `trashError` text on the row, no crash.
///
/// Accessibility: the whole row is one VoiceOver element reading the file name and
/// size (path is decorative detail, not read out); each action button is a separate,
/// individually-labelled control (TECHSPEC §8 correction 2 / §9 keyboard rule). The
/// confirm state's label announces that the row is awaiting confirmation.
struct LargestFileRow: View {
    let file: LargestFile
    /// Reveals this file in Finder. Injected from the section (defaults there to the
    /// production revealer) so the button is testable without activating Finder.
    let reveal: (URL) -> Void
    /// `true` when this row is the one awaiting a Move-to-Trash confirmation (ACT-002):
    /// the trailing cluster swaps the plain Trash button for the inline Confirm/Cancel
    /// prompt. Exactly one row is ever confirming (the view model enforces that).
    var isConfirmingTrash = false
    /// Inline error text from a failed trash of this file (locked/permission/missing),
    /// or `nil` when the last attempt succeeded or none was made. Shown beneath the row.
    var trashError: String?
    /// First Trash activation — asks the view model to arm this row's confirm state.
    var onTrashRequest: (URL) -> Void = { _ in }
    /// Confirm the pending trash — the view model moves the file to the Trash.
    var onTrashConfirm: (URL) -> Void = { _ in }
    /// Cancel the pending trash — the view model disarms this row, file untouched.
    var onTrashCancel: (URL) -> Void = { _ in }
    /// Hide this row (UX-015) — the view model drops it from the list and persists the
    /// choice; it can be brought back via the section's "N hidden" affordance.
    var onHide: (URL) -> Void = { _ in }

    /// Whether the pointer is over the row. The Reveal/Trash cluster is revealed on
    /// hover so a resting row reads as a clean name/size/path line; the confirm prompt
    /// is exempt (it must stay visible once armed, even if the pointer drifts off).
    @State private var isHovering = false

    var body: some View {
        let sizeText = ByteFormat.text(fromBytes: file.sizeBytes)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: DiskMetrics.inlineSpacing) {
                // Leading kind glyph (UX-008): an SF Symbol keyed to the file's type so
                // the row reads at a glance. Decorative — the row's spoken label names
                // the file, so a "photo"/"film" glyph before it would just be noise.
                Image(systemName: Self.symbolName(for: file.url))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: DiskMetrics.inlineSpacing) {
                        Text(file.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: DiskMetrics.inlineSpacing)
                        Text(sizeText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Text(file.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Trailing action cluster: Reveal + Trash, or the inline confirm prompt.
                trailingControls
                    .fixedSize()
            }
            if let trashError {
                LargestFileTrashErrorView(message: trashError)
            }
        }
        // Subtle hover highlight (UX-016): the pointer's row lifts a shade so it reads as
        // "live" while its Reveal/Hide/Trash actions fade in. Padded slightly wider than the
        // text so the fill frames the whole row, and inset back by the same amount so no
        // layout shifts. Suppressed while the row is mid-confirm — the armed destructive
        // prompt is the row's focus then, and a highlight under it would just be noise.
        .padding(.horizontal, 4)
        .rowHoverHighlight(isHovering, cornerRadius: 6, active: !isConfirmingTrash)
        .padding(.horizontal, -4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Name + size are the row's identity for VoiceOver; the path/buttons are
        // exposed as their own elements (each action button carries its own label).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.rowAccessibilityLabel(
            fileName: file.displayName, sizeText: sizeText, isConfirmingTrash: isConfirmingTrash
        ))
    }

    /// The row's identity for VoiceOver — file name and size, plus an explicit note
    /// when the row is awaiting a trash confirmation so a screen-reader user knows the
    /// destructive prompt is active. Pure and static so the exact wording (including
    /// the confirm-state announcement) is unit-testable without a SwiftUI host.
    static func rowAccessibilityLabel(fileName: String, sizeText: String, isConfirmingTrash: Bool) -> String {
        let base = "\(fileName), \(sizeText)"
        return isConfirmingTrash ? "\(base), confirm move to Trash" : base
    }

    /// The trailing controls: the two-step Trash swaps the whole cluster between its
    /// resting state (Reveal + Trash) and its confirm state (Move to Trash? / Confirm /
    /// Cancel), so the confirm prompt reads as one unit and can't be mistaken for the
    /// resting buttons.
    ///
    /// The resting cluster is *revealed on hover* (UX-008) so a settled list reads as
    /// clean name/size/path rows. It stays in the view tree (faded, not removed) so
    /// keyboard focus and VoiceOver still reach both actions when the pointer is away —
    /// the buttons keep their labels and become fully visible on focus/hover. The confirm
    /// prompt is always shown once armed: a pending destructive action must never hide.
    @ViewBuilder
    private var trailingControls: some View {
        if isConfirmingTrash {
            HStack(spacing: DiskMetrics.inlineSpacing) {
                Text("Move to Trash?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button("Cancel") { onTrashCancel(file.url) }
                    .buttonStyle(.borderless)
                    .clickableCursor()
                    .font(.caption)
                    .accessibilityLabel("Cancel moving \(file.displayName) to Trash")
                Button("Move to Trash") { onTrashConfirm(file.url) }
                    .buttonStyle(.borderless)
                    .clickableCursor()
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Confirm moving \(file.displayName) to Trash")
                    .accessibilityHint("Moves the file to the Trash. Recoverable from the Trash.")
            }
        } else {
            HStack(spacing: DiskMetrics.inlineSpacing) {
                Button(action: { reveal(file.url) }) {
                    Image(systemName: "folder")
                }
                .hoverIconButtonStyle()
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(file.displayName) in Finder")
                Button(action: { onHide(file.url) }) {
                    Image(systemName: "eye.slash")
                }
                .hoverIconButtonStyle()
                .help("Hide from this list")
                .accessibilityLabel("Hide \(file.displayName)")
                Button(action: { onTrashRequest(file.url) }) {
                    Image(systemName: "trash")
                }
                .hoverIconButtonStyle()
                .help("Move to Trash")
                .accessibilityLabel("Move \(file.displayName) to Trash")
            }
            // Revealed on hover, but kept in the tree (opacity, not removal) so keyboard
            // and VoiceOver users still reach the actions; focusing a button re-renders
            // with hover semantics and the standard focus ring makes it visible.
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
    }

    /// SF Symbol for a file, keyed to its type (UX-008): archives → `doc.zip`, images →
    /// `photo`, movies → `film`, audio → `music.note`, folders → `folder`, everything
    /// else → a generic `doc`. Resolved through `UTType` (from the path extension) so it
    /// classifies by real type, not just a hardcoded extension list. Pure and static so
    /// the mapping is unit-testable without a SwiftUI host (same pattern as
    /// `DiskGlyph.symbolName`).
    static func symbolName(for url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        if let type {
            if type.conforms(to: .directory) { return "folder" }
            if type.conforms(to: .archive) { return "doc.zip" }
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .movie) { return "film" }
            if type.conforms(to: .audio) { return "music.note" }
        }
        // A trailing path separator (or a bare directory URL) has no extension/type but is
        // still a folder — catch it so directories don't fall through to the doc glyph.
        if url.hasDirectoryPath { return "folder" }
        return "doc"
    }
}

/// One hidden file inside the expanded "N hidden" affordance (UX-015): the file name and
/// size, muted to read as "set aside", plus a single un-hide (`eye`) button that restores
/// it to the visible list. Deliberately lighter than a `LargestFileRow` — a hidden entry
/// isn't actionable beyond bringing it back, so no Reveal/Trash controls here.
///
/// Accessibility: the whole row is one VoiceOver element naming the hidden file and its
/// size; the un-hide button is its own individually-labelled control ("Unhide <file>").
struct HiddenFileRow: View {
    let file: LargestFile
    /// Restores this file to the visible list (UX-015).
    let onUnhide: (URL) -> Void

    var body: some View {
        let sizeText = ByteFormat.text(fromBytes: file.sizeBytes)
        HStack(alignment: .firstTextBaseline, spacing: DiskMetrics.inlineSpacing) {
            Text(file.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DiskMetrics.inlineSpacing)
            Text(sizeText)
                .fixedSize()
            Button(action: { onUnhide(file.url) }) {
                Image(systemName: "eye")
            }
            .hoverIconButtonStyle()
            .help("Unhide")
            .accessibilityLabel("Unhide \(file.displayName)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.displayName), \(sizeText), hidden")
    }
}

/// Inline error notice for a failed Move-to-Trash (ACT-002, TECHSPEC §7): a locked
/// file, permission denial, or already-gone file surfaces here beneath the row rather
/// than in a modal or a crash. Muted and warning-tinted so it reads as a recoverable
/// hiccup, not a fatal state.
struct LargestFileTrashErrorView: View {
    let message: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .imageScale(.small)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}

/// Loading state for the largest-files section while its Spotlight scan runs — a small
/// spinner with a label, so the section explains itself instead of appearing empty.
struct LargestFilesLoadingView: View {
    static let message = "Scanning for largest files…"

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(Self.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.message)
    }
}

/// Progressive-scan caption (A3): the subtle "Scanning… N found" affordance shown above
/// the best-so-far rows while a largest-files scan is still gathering (the model's
/// `.scanning(partial:)` state with a non-empty partial). A small spinner plus a muted
/// caption tells the user the list is still filling in without hiding the rows already
/// found — the rows render beneath it and grow in place (A2/A3).
///
/// Accessibility: the caption is a single VoiceOver element announcing the live count
/// (e.g. "Scanning for largest files, 3 found so far"). It sits above the rows and never
/// steals focus as the count ticks up — the file rows keep their own per-row labels and
/// stable `url` identity, so VoiceOver focus doesn't churn while the list fills in.
struct LargestFilesScanningCaption: View {
    /// How many best-so-far files have been gathered — the live count in the caption.
    let foundCount: Int

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(Self.captionText(foundCount: foundCount))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(foundCount: foundCount))
    }

    /// The visible caption text — "Scanning… N found". Pure/static so the exact wording
    /// (and its live count) is unit-testable without a SwiftUI host, matching the pattern
    /// used for the other largest-files strings.
    static func captionText(foundCount: Int) -> String {
        "Scanning… \(foundCount) found"
    }

    /// The spoken caption — spelled out for VoiceOver ("N found so far") so the ellipsis
    /// glyph isn't read literally and the "still gathering" meaning is explicit.
    static func accessibilityLabel(foundCount: Int) -> String {
        "Scanning for largest files, \(foundCount) found so far"
    }
}

/// The "Not indexed" degraded state for the largest-files section (ACT-001 reusing the
/// SCAN-005 story, TECHSPEC §4): the scoped volume has no usable Spotlight index, so a
/// ranked list would be a fabrication. Shows a muted notice instead of an empty list
/// that reads as "no large files".
struct LargestFilesNotIndexedView: View {
    let volumeName: String?

    static let message = "Not indexed — largest files unavailable"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
                .imageScale(.small)
            Text(Self.message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let volumeName { return "\(volumeName): \(Self.message)" }
        return Self.message
    }
}

/// The empty-but-indexed state: the scoped volume is indexed but Spotlight returned no
/// rankable file. Distinct from `.unavailable` so the user isn't told the volume is
/// unindexed when it simply has nothing large to show.
struct LargestFilesEmptyView: View {
    static let message = "No large files found"

    var body: some View {
        Text(Self.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Self.message)
    }
}
