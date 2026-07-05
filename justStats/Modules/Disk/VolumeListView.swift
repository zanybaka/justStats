import SwiftUI

extension View {
    /// Shows the pointing-hand ("link") cursor while the pointer is over a clickable
    /// control (UX-014, TECHSPEC §9): the popover's buttons look like plain SF Symbols,
    /// so without this a user gets no cursor feedback that a glyph is actionable. Apply it
    /// to *every* clickable control in the popover — the header sort/refresh/gear, the
    /// footer GitHub/Quit, and the largest-files row Reveal/Trash actions — and to any
    /// clickable control future popover work adds, so cursor feedback stays uniform from
    /// one shared source (no per-site cursor plumbing).
    ///
    /// Uses SwiftUI's `.pointerStyle(.link)` (macOS 15+, the app's deployment floor), which
    /// the framework scopes to the modified view's hover region and resets automatically on
    /// leave — so there is no manual `NSCursor` push/pop to get wrong and no stuck cursor.
    /// It layers on top of a control's own behavior (hover reveal, focus ring, a11y label),
    /// changing only the cursor.
    func clickableCursor() -> some View {
        pointerStyle(.link)
    }
}

/// Subtle, appearance-adaptive hover feedback for the popover's icon buttons (UX-016):
/// the header sort/refresh/gear, the footer GitHub/Quit, and the largest-files row
/// Reveal/Hide/Trash actions all look like plain SF Symbols, so — like the pointer cursor
/// (UX-014) — they give no sign they are pressable until acted on. This style paints a
/// gentle rounded fill behind the glyph and lifts its opacity while the pointer is over
/// it, so a resting control reads as flat chrome and lights up only under the pointer.
///
/// One shared style so every icon button lights up identically from a single source (no
/// per-site hover plumbing), mirroring how `clickableCursor()` centralizes the cursor.
/// It changes only appearance: the control keeps its own action, focus ring, and a11y
/// label untouched, and the fill uses the `.quaternary` system material so light/dark
/// adapt automatically with no hardcoded color. A `.link` pointer pairs with it so hover
/// feedback and cursor stay consistent (the task's "reuse UX-014's cursor" requirement).
struct HoverFillButtonStyle: ButtonStyle {
    /// Whether the pointer is over the button — drives the fill and the glyph's opacity
    /// lift. Kept as its own small `View` because `ButtonStyle.makeBody` can't own `@State`;
    /// the wrapper tracks hover and hands it down. (Not named `Body` — that name matches the
    /// protocol's `Body` associatedtype requirement, which would force it non-private.)
    struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                // Pressed reads slightly dimmer for tactile feedback; hover lifts a resting
                // glyph from secondary-weight to full so it "wakes up" under the pointer.
                .opacity(configuration.isPressed ? 0.55 : (isHovering ? 1 : 0.85))
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        // Quaternary system fill: barely-there on a resting control,
                        // enough to read as an actionable target once hovered/pressed.
                        // Zero opacity when idle keeps the glyph on a clean background.
                        .fill(.quaternary)
                        .opacity(configuration.isPressed ? 0.9 : (isHovering ? 0.6 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.easeInOut(duration: 0.12), value: isHovering)
                .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }
}

extension View {
    /// Applies the shared hover fill (UX-016) *and* the shared link cursor (UX-014) to an
    /// icon button in one call, so every pressable SF-Symbol control in the popover gets
    /// consistent hover + pointer feedback from a single site. Use in place of
    /// `.buttonStyle(.borderless).clickableCursor()` on the popover's icon buttons.
    func hoverIconButtonStyle() -> some View {
        buttonStyle(HoverFillButtonStyle()).clickableCursor()
    }

    /// A gentle, appearance-adaptive hover highlight for a whole row/card (UX-016): fades a
    /// gentle secondary system fill in behind the row while the pointer is over it, so the
    /// row the pointer is on reads as "live" without a hard border or any layout shift (the
    /// fill sits behind existing content, changing no sizes). Kept subtle on purpose — a
    /// volume card already has its own resting fill, so this only nudges it a shade.
    ///
    /// `active` gates it so a caller can suppress the highlight in states where it would be
    /// noise (e.g. a row that is mid-confirm). The fill uses the `.secondary` system material
    /// at a low opacity so light/dark adapt with no hardcoded color, and animates in/out.
    func rowHoverHighlight(_ isHovering: Bool, cornerRadius: CGFloat, active: Bool = true) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.secondary)
                .opacity(active && isHovering ? 0.10 : 0)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
    }
}

/// Popover content (VOL-004, TECHSPEC §8): one row per volume in a vertical
/// stack — internal rows first, deferred rows streaming from placeholder to
/// loaded/unavailable in place. Width is pinned to the shared Kit constant;
/// height stays content-driven so the hosting controller's
/// `preferredContentSize` tracks it dynamically.
///
/// SwiftUI is allowed here because this tree lives inside the popover's
/// `NSHostingController` (TECHSPEC §1 refinement: AppKit shell, SwiftUI content).
struct VolumeListView: View {
    @ObservedObject var model: VolumeListViewModel

    /// Opens the Full Disk Access pane when a row's SCAN-006 notice button is tapped.
    /// Defaults to the production `NSWorkspace` opener; injectable so the view can be
    /// built in previews/tests without launching System Settings.
    var openFullDiskAccessSettings: () -> Void = { SystemSettingsOpener().openFullDiskAccessSettings() }

    /// Reveals a largest-files entry in Finder (ACT-001). Defaults to the production
    /// `NSWorkspace` revealer; injectable so the popover can be built in previews/tests
    /// without activating Finder.
    var revealInFinder: (URL) -> Void = { WorkspaceFinderRevealer().reveal($0) }

    /// Opens the Settings window from the header gear (SET-003, TECHSPEC §8 point 4).
    /// Defaults to a no-op so the view builds in previews/tests without touching the
    /// AppKit window layer; production injects the shared `SettingsWindowPresenter`.
    var openSettings: () -> Void = {}

    /// Quits the app from the footer's "Quit" control (UX-009). Defaults to the shared
    /// `AboutInfo.quit` — the same standard menu-bar quit the Settings About section
    /// uses — so the popover footer and Settings agree on one action. Injectable so
    /// previews/tests can assert the wiring without terminating the process.
    var quit: () -> Void = AboutInfo.quit

    /// The About facts (version line, GitHub URL) the footer renders. Injected so a
    /// preview/test can pin a known version; production reads `Bundle.main` — the very
    /// same source the Settings About section uses (one source of truth, UX-009).
    var about: AboutInfo = AboutInfo()

    /// The red/yellow thresholds that decide a row's "running low" accent (UX-008).
    /// Loaded once from the very same `ThresholdConfigurationStore` the menu-bar icon
    /// tier reads (see `IconController`), so a row turns red exactly when the icon does
    /// — one source of truth, no hardcoded limits. Injectable so previews/tests can pin
    /// a configuration without touching `UserDefaults`.
    var thresholdConfiguration: ThresholdConfiguration = ThresholdConfigurationStore().load()

    var body: some View {
        // Dense, Stats-inspired stack (APPROVED DESIGN DIRECTION): tighter than the
        // outer edge padding so the header, cards, largest-files, and footer read as one
        // compact panel rather than a loosely spaced list.
        VStack(alignment: .leading, spacing: 10) {
            VolumeListHeaderView(
                sortMostFullFirst: $model.sortMostFullFirst,
                onRefresh: { model.refresh() },
                onOpenSettings: openSettings
            )
            if model.rows.isEmpty {
                // Practically unreachable (the boot volume always enumerates),
                // but never render an unexplained empty popover.
                Text("No volumes found")
                    .foregroundStyle(.secondary)
            }
            // `displayRows` applies the sort toggle over the enumeration order
            // without disturbing the model's canonical row order (FR9).
            ForEach(model.displayRows) { row in
                switch row {
                case .loaded(let volume):
                    VolumeRowView(
                        volume: volume,
                        categoryState: model.categoryStates[volume.mountURL],
                        thresholdConfiguration: thresholdConfiguration,
                        openFullDiskAccessSettings: openFullDiskAccessSettings
                    )
                case .pending(let volume):
                    PendingVolumeRowView(volume: volume)
                case .unavailable(let volume):
                    UnavailableVolumeRowView(volume: volume)
                }
            }
            // The largest-files section sits below the volume rows (TECHSPEC §8 layout
            // point 3), scoped to the boot volume by default. Renders nothing until a
            // volume is scoped (`.idle`). The Move-to-Trash confirm state and any inline
            // error come from the model, and the row's Trash actions drive the model's
            // confirm-state machine (ACT-002).
            LargestFilesSection(
                state: model.largestFilesState,
                volumeName: model.largestFilesVolumeName,
                reveal: revealInFinder,
                pendingTrashURL: model.pendingTrashConfirmationURL,
                trashErrorMessages: model.trashErrorMessages,
                onTrashRequest: { model.requestTrashConfirmation(for: $0) },
                onTrashConfirm: { model.confirmTrash(for: $0) },
                onTrashCancel: { model.cancelTrashConfirmation(for: $0) },
                onHide: { model.hide($0) },
                hiddenFiles: model.hiddenLargestFiles,
                onUnhide: { model.unhide($0) },
                onUnhideAll: { model.clearHiddenFiles() }
            )
            // Integrated footer (UX-009, TECHSPEC §8): version · GitHub · Quit, drawn
            // from the same `AboutInfo`/`AboutInfo.quit` the Settings About section uses
            // — one source of truth. A hairline divider separates it from the content.
            Divider()
            VolumeListFooterView(about: about, quit: quit)
        }
        .padding(12)
        // Fixed width (TECHSPEC §8); only height is driven by content.
        .frame(width: PopoverLayout.contentWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("justStats disk overview")
    }
}

/// Header row (VOL-005, UX-009, TECHSPEC §8): the "justStats" app title plus the
/// top-of-popover controls — a "most-full first" sort toggle (PRD FR9), a manual
/// Refresh (PRD FR13), and the Settings gear (SET-003, TECHSPEC §8 point 4: standard
/// top-right placement). The title names the app (13pt medium, APPROVED DESIGN
/// DIRECTION) rather than the section, matching the Stats-inspired chrome. All three
/// controls are SF Symbol buttons (TECHSPEC §8 Iconography) so they adapt to light/dark
/// and stay VoiceOver-labelled. The gear is placed last (trailing edge) per the HIG's
/// top-right convention for settings affordances.
struct VolumeListHeaderView: View {
    @Binding var sortMostFullFirst: Bool
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(AboutInfo.appName)
                .font(.system(size: DiskMetrics.nameFontSize, weight: .medium))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: { sortMostFullFirst.toggle() }) {
                Image(systemName: sortMostFullFirst
                    ? "arrow.down.circle.fill"
                    : "arrow.up.arrow.down.circle")
            }
            .hoverIconButtonStyle()
            .help("Sort by fullness (most full first)")
            .accessibilityLabel("Sort by fullness")
            // The toggle's direction is otherwise conveyed only by the icon shape, so
            // announce the active order as a value — VoiceOver reads it and the on/off
            // state without the user having to interpret the glyph (no meaning by
            // color/shape alone, TECHSPEC §9 item 9).
            .accessibilityValue(sortMostFullFirst ? "Most full first" : "Default order")
            .accessibilityHint("Toggles sorting volumes by how full they are")
            .accessibilityAddTraits(sortMostFullFirst ? [.isSelected] : [])
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .hoverIconButtonStyle()
            .help("Refresh volumes")
            .accessibilityLabel("Refresh")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .hoverIconButtonStyle()
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }
}

/// Integrated popover footer (UX-009, TECHSPEC §8 layout): the app version, a link to
/// the source repository on GitHub, and a "Quit" control — the popover's counterpart to
/// the Settings About section (SET-005/UX-004/005). It deliberately draws every fact
/// from the *same* sources those settings use — `AboutInfo` for the version line and
/// `AboutInfo.repositoryURL`, `AboutInfo.quit` for the default quit action — so there is
/// one source of truth for version/GitHub/quit across the app (no duplicated literals).
///
/// Native and minimal (macos-app-design: prefer system components): a SwiftUI `Link`
/// opens the repo in the default browser via the system open handler (no `NSWorkspace`
/// plumbing), and the borderless SF Symbol buttons adapt to light/dark automatically.
/// Every control keeps an explicit VoiceOver label naming its destination/effect, and
/// the version text is spoken as one element rather than a run of glyphs.
struct VolumeListFooterView: View {
    /// The About facts to display — the version line and GitHub URL. Injected so a
    /// preview/test pins a known version; production passes `AboutInfo()` (Bundle.main).
    let about: AboutInfo
    /// The action run when "Quit" is pressed. Defaults to the shared `AboutInfo.quit`
    /// (the same one Settings-About uses); injectable so tests assert the wiring without
    /// terminating the process.
    var quit: () -> Void = AboutInfo.quit

    var body: some View {
        HStack(spacing: DiskMetrics.inlineSpacing) {
            // Version — the same "justStats X.Y.Z (build)" line the Settings About row
            // shows, spoken as a single VoiceOver element.
            Text(about.versionLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Version")
                .accessibilityValue(about.versionLine)

            Spacer(minLength: DiskMetrics.inlineSpacing)

            // GitHub — opens the repo in the default browser via the system open handler,
            // keyboard- and VoiceOver-accessible out of the box. Uses the shared
            // `GitHubMarkLabel` (the Octocat `Shape`, UX-012) as an icon-only control —
            // the same mark the Settings About link renders — instead of the generic
            // external-link square (SF Symbols has no GitHub logo). It's tintable, so it
            // reads as a system control and adapts to light/dark.
            Link(destination: AboutInfo.repositoryURL) {
                GitHubMarkLabel()
            }
            .hoverIconButtonStyle()
            .help("View justStats on GitHub")
            .accessibilityLabel("View justStats on GitHub")
            .accessibilityHint("Opens the source repository in your browser")

            // Quit — the pointer affordance for a menu-bar (LSUIElement) app; ⌘Q is wired
            // separately via the app's main menu. No confirmation (standard menu-bar quit).
            Button(action: quit) {
                Image(systemName: "power")
            }
            .hoverIconButtonStyle()
            .help("Quit justStats")
            .accessibilityLabel("Quit justStats")
            .accessibilityHint("Quits the app")
        }
        .accessibilityElement(children: .contain)
    }
}

/// One resolved volume: name, free space, breakdown bar, "used of total" (PRD
/// FR5–FR6). System colors/text styles only, so light/dark adapt automatically.
///
/// What sits under the name depends on the volume's category-scan state:
/// - `.breakdown` — the five-way category bar (SCAN-004).
/// - `.notIndexed` — the "Not indexed" degraded notice (SCAN-005): Spotlight has
///   no usable index, so a bar would be a lie. The notice replaces it; the free
///   space and "used of total" line still render (those come from `statfs`, not
///   Spotlight, so they stay trustworthy).
/// - `.needsFullDiskAccess` — the lazy Full Disk Access notice (SCAN-006): an empty
///   index on the boot volume is permissions-shaped, so the row offers a button to
///   the FDA pane instead of the plain "Not indexed" text. Same trustworthy
///   free/used line underneath.
/// - anything else (`.scanning`, `nil`) — the plain usage bar while the scan is
///   still in flight. The row never blocks on the scan and never shows fabricated
///   segments.
struct VolumeRowView: View {
    let volume: Volume
    /// This volume's category-breakdown state, or `nil` if scanning hasn't been
    /// recorded yet. See `Content` for how each state maps to what's drawn.
    var categoryState: VolumeListViewModel.CategoryState?
    /// The red/yellow thresholds that decide this row's "running low" accent (UX-008).
    /// Defaults to the same store the icon tier reads so the row is correct standalone;
    /// the list injects a single loaded copy so every row and the menu-bar icon agree.
    var thresholdConfiguration: ThresholdConfiguration = ThresholdConfigurationStore().load()
    /// Opens the Full Disk Access pane from the SCAN-006 notice button. Defaults to
    /// the production opener so the row is usable standalone (previews, and the
    /// list's own default) without wiring a seam every time.
    var openFullDiskAccessSettings: () -> Void = { SystemSettingsOpener().openFullDiskAccessSettings() }

    /// What the row draws below the name line, derived purely from `categoryState`.
    /// Extracted as a plain enum so the state → presentation mapping is unit-testable
    /// without a SwiftUI host (same rationale as `CategoryBarView.pixelWidths`).
    enum Content: Equatable {
        /// The five-way stacked category bar (a resolved breakdown, SCAN-004).
        case categoryBar(StorageBreakdown)
        /// The "Not indexed — category breakdown unavailable" notice (SCAN-005).
        case notIndexedNotice
        /// The lazy "Grant Full Disk Access" notice with its Settings button (SCAN-006).
        case fullDiskAccessNotice
        /// The plain usage bar (scan in flight or not yet started).
        case usageBar

        /// Maps a category-scan state to the row content. A resolved breakdown draws
        /// the bar; an unavailable index draws the degraded notice instead of a
        /// misleading empty bar (TECHSPEC §4) — the Full Disk Access variant on the
        /// boot volume, the plain "Not indexed" one elsewhere; everything else falls
        /// back to the plain usage bar.
        init(categoryState: VolumeListViewModel.CategoryState?) {
            switch categoryState {
            case .breakdown(let breakdown): self = .categoryBar(breakdown)
            case .notIndexed: self = .notIndexedNotice
            case .needsFullDiskAccess: self = .fullDiskAccessNotice
            case .scanning, nil: self = .usageBar
            }
        }
    }

    private var content: Content { Content(categoryState: categoryState) }

    /// `true` when the volume's free space has crossed into the icon tier's warning
    /// band — i.e. its `DiskState` is not green (free below the yellow threshold).
    /// Computed from the injected `ThresholdConfiguration` so the row's red accent
    /// lights up in lockstep with the menu-bar icon, never on a hardcoded limit.
    private var isRunningLow: Bool {
        thresholdConfiguration.diskState(
            freeBytes: volume.freeBytes, totalBytes: volume.totalBytes
        ) != .green
    }

    /// The accent used for the disk glyph and the usage-bar fill: red once the volume
    /// is running low (drawing the eye to the at-risk row), otherwise the standard
    /// accent color so a healthy row reads as a plain system control.
    private var accent: Color { isRunningLow ? .red : .accentColor }

    /// Whether the pointer is over the row's card — drives a gentle hover highlight (UX-016)
    /// so the volume the pointer rests on reads as "live". Purely cosmetic: the row has no
    /// per-row action, so this is a subtle affordance only, never gating behavior or a11y.
    @State private var isHovering = false

    var body: some View {
        let freeText = ByteFormat.text(fromBytes: volume.freeBytes)
        let usedText = ByteFormat.text(fromBytes: volume.usedBytes)
        let totalText = ByteFormat.text(fromBytes: volume.totalBytes)
        let percentText = Self.percentUsedText(usedFraction: volume.usedFraction)
        VStack(alignment: .leading, spacing: DiskMetrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: DiskMetrics.inlineSpacing) {
                DiskGlyph(kind: volume.kind, tint: accent)
                    .imageScale(.large)
                Text(volume.name)
                    .font(.system(size: DiskMetrics.nameFontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DiskMetrics.inlineSpacing)
                Text(percentText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            // The glyph + name + "% used" line is several visual pieces; collapse it into
            // one VoiceOver element carrying the full usage sentence so the row always has
            // a coherent spoken identity — including the `.categoryBar` case, whose
            // used/total figures otherwise live only in the (bar-owned) legend.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.headerAccessibilityLabel(
                volumeName: volume.name, free: freeText, used: usedText, total: totalText,
                isRunningLow: isRunningLow
            ))
            switch content {
            case .categoryBar(let breakdown):
                CategoryBarView(breakdown: breakdown, volumeName: volume.name)
            case .notIndexedNotice:
                NotIndexedNoticeView(volumeName: volume.name)
                freeOfTotalLine(free: freeText, total: totalText)
            case .fullDiskAccessNotice:
                FullDiskAccessNoticeView(
                    volumeName: volume.name,
                    openSettings: openFullDiskAccessSettings
                )
                freeOfTotalLine(free: freeText, total: totalText)
            case .usageBar:
                UsageBarView.singleFill(usedFraction: volume.usedFraction, color: accent)
                freeOfTotalLine(free: freeText, total: totalText)
            }
            // Every content case (bar, notice, or plain usage) carries the same text+icon
            // "Running low" cue when the volume crosses the warning threshold, so the
            // at-risk state is never conveyed by the red accent alone (accessibility rule:
            // no meaning by color alone). It sits below the switch so it applies uniformly.
            if isRunningLow { runningLowFlag }
        }
        .padding(DiskMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Compact card (APPROVED DESIGN DIRECTION): a subtle quaternary fill and ~10pt
        // radius group each volume's lines without a hard border. System fill so it
        // adapts to light/dark automatically.
        .background(
            RoundedRectangle(cornerRadius: DiskMetrics.cardCornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        // Gentle hover highlight (UX-016): nudges the resting card a shade brighter while
        // the pointer is over it, layered above the base fill so no layout shifts. Subtle
        // by design — the card already has a resting fill, so this only lifts it slightly.
        .rowHoverHighlight(isHovering, cornerRadius: DiskMetrics.cardCornerRadius)
        .contentShape(RoundedRectangle(cornerRadius: DiskMetrics.cardCornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
    }

    /// The "X free of Y" caption line shown under the bar/notice. The category-bar case
    /// omits it — that bar's legend already carries every size — so it lives in a shared
    /// builder rather than being duplicated across the notice/usage cases.
    ///
    /// The caption is hidden from VoiceOver here: the row's header line already speaks the
    /// full usage sentence (see `headerAccessibilityLabel`), so exposing the same figures
    /// again would make VoiceOver read the free/total numbers twice per row.
    private func freeOfTotalLine(free: String, total: String) -> some View {
        Text("\(free) free of \(total)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    /// The "Running low" flag shown under the row's content — in every content case (bar,
    /// notice, or plain usage) — when the volume has crossed the warning threshold. An icon
    /// *and* a label — never color alone (accessibility rule) — so the warning reads without
    /// relying on the red hue that also tints the glyph/bar. Hidden from VoiceOver because
    /// the row's spoken summary now appends "running low" itself (see
    /// `headerAccessibilityLabel`), so exposing this too would announce the warning twice.
    private var runningLowFlag: some View {
        Label("Running low", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityHidden(true)
    }

    /// The trailing "NN% used" figure, rounded to a whole percent. Pure and static so the
    /// exact wording/rounding is unit-testable without a SwiftUI host (same rationale as
    /// `CategoryBarView.pixelWidths` / `VolumeRowView.Content`).
    static func percentUsedText(usedFraction: Double) -> String {
        let clamped = min(max(usedFraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))% used"
    }

    /// The row's single spoken summary — volume name, free space, and used-of-total —
    /// built once so every content case (bar, notice, or usage bar) reads identically.
    /// When the volume has crossed the warning threshold it also announces "running low",
    /// so a VoiceOver user gets the same at-risk warning the sighted "Running low" flag
    /// carries — the low state is never conveyed by the red accent alone. Pure and static
    /// so the exact wording is unit-testable without a SwiftUI host (same rationale as
    /// `CategoryBarView.pixelWidths` / `VolumeRowView.Content`).
    static func headerAccessibilityLabel(
        volumeName: String, free: String, used: String, total: String, isRunningLow: Bool
    ) -> String {
        let summary = "\(volumeName), \(free) free, \(used) used of \(total)"
        return isRunningLow ? "\(summary), running low" : summary
    }
}

/// The "Not indexed" degraded state (SCAN-005, TECHSPEC §4). When a volume's
/// Spotlight index is unusable (unindexed external/network drive, or `mdutil -i
/// off`), the category bar would be a fabrication, so the row shows this notice in
/// its place — the exact TECHSPEC wording, muted, with an info glyph. Only the
/// category breakdown is unavailable; the row's free/used figures (from `statfs`)
/// are unaffected, and no raw-scan fallback is attempted (NFR4).
///
/// Componentized like `CategoryBarView`/`UsageBarView` so the row swaps it in for
/// the bar purely by state, without touching the surrounding layout.
struct NotIndexedNoticeView: View {
    /// The owning volume's name, so the notice's VoiceOver label is self-describing
    /// when focused independently of the row.
    let volumeName: String

    /// The user-facing notice text — the exact TECHSPEC §4 degraded-state wording.
    static let message = "Not indexed — category breakdown unavailable"

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
        .accessibilityLabel("\(volumeName): \(Self.message)")
    }
}

/// The lazy Full Disk Access notice (SCAN-006, TECHSPEC §7). When the boot volume's
/// Spotlight index comes back empty, the likeliest cause is a missing Full Disk
/// Access grant (the system volume is always indexed under normal conditions), so —
/// rather than the generic "Not indexed" text — the row shows this notice with a
/// button that opens the FDA privacy pane directly. The app never prompts for the
/// permission at launch; this is surfaced *only* from incomplete scan data (the
/// "lazy" requirement).
///
/// Only the category breakdown is affected; the row's free/used figures (from
/// `statfs`) stay trustworthy and still render beneath. After the user grants access
/// and hits Refresh, the next scan returns a real index and the notice disappears.
///
/// Componentized like `NotIndexedNoticeView` so the row swaps it in purely by state.
struct FullDiskAccessNoticeView: View {
    /// The owning volume's name, so the notice's VoiceOver label is self-describing
    /// when focused independently of the row.
    let volumeName: String
    /// Opens the Full Disk Access pane; injected so the button is testable without
    /// launching System Settings.
    let openSettings: () -> Void

    /// The user-facing notice text — the exact TECHSPEC §7 wording.
    static let message = "Grant Full Disk Access for complete data"
    /// The button title opening the FDA pane.
    static let buttonTitle = "Open Settings"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "lock.circle")
                .imageScale(.small)
            Text(Self.message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(Self.buttonTitle, action: openSettings)
                .buttonStyle(.link)
                .clickableCursor()
                .font(.caption)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(volumeName): \(Self.message)")
        .accessibilityHint("Opens Full Disk Access settings")
    }
}

/// One category in the stacked breakdown bar (SCAN-004). Owns its label, byte
/// value, and color so the bar, legend, and VoiceOver strings all draw from a
/// single ordered source — color is never the sole cue (each segment carries a
/// name and size for the legend and accessibility, per TECHSPEC §8 correction 2).
struct CategorySegment: Identifiable {
    let id: Category
    let bytes: Int64

    enum Category: String, CaseIterable {
        case system = "System"
        case apps = "Apps"
        case media = "Media"
        case other = "Other"
        case free = "Free"

        /// System-palette color per category, resolved through the shared
        /// `DiskPalette` (UX-007) so the row, legend, and any other disk view draw
        /// from one adaptive source. Distinct hues, but every segment is also
        /// labelled in the legend and read out by VoiceOver, so hue is a secondary
        /// cue only (accessibility rule: no meaning by color alone).
        var color: Color { DiskPalette.color(for: self) }
    }

    var name: String { id.rawValue }

    /// The five segments in draw order (used first, Free last), sourced from a
    /// reconciled breakdown. Order is fixed so the bar and legend always align.
    static func segments(from breakdown: StorageBreakdown) -> [CategorySegment] {
        [
            CategorySegment(id: .system, bytes: breakdown.systemBytes),
            CategorySegment(id: .apps, bytes: breakdown.appsBytes),
            CategorySegment(id: .media, bytes: breakdown.mediaBytes),
            CategorySegment(id: .other, bytes: breakdown.otherBytes),
            CategorySegment(id: .free, bytes: breakdown.freeBytes),
        ]
    }
}

/// Stacked five-way breakdown bar (PRD FR6, SCAN-004): System/Apps/Media/Other/Free
/// laid out proportionally in one horizontal track, with a wrapping legend beneath
/// naming each non-empty category and its size. Componentized on purpose — the row
/// swaps in this view for the plain usage bar once a breakdown exists, and SCAN-005
/// swaps in its own notice for the "Not indexed" state without touching either.
///
/// Accessibility: color is never the only signal. The legend labels every visible
/// segment, and the whole bar is one VoiceOver element reading each segment's name
/// and size in order (TECHSPEC §8 correction 2). A tiny category still occupies its
/// exact proportional width in the track (never rounded away to hide it) and is
/// always named in the legend, which lists every non-zero category with its size.
struct CategoryBarView: View {
    let breakdown: StorageBreakdown
    /// The owning volume's name, so the bar's VoiceOver summary is self-describing
    /// when focused independently of the row.
    let volumeName: String

    private var segments: [CategorySegment] { CategorySegment.segments(from: breakdown) }

    /// Non-zero segments, for the legend and the VoiceOver summary — zero-byte
    /// categories are omitted so neither lists an empty "Media 0 bytes".
    private var visibleSegments: [CategorySegment] { segments.filter { $0.bytes > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: DiskMetrics.legendSpacing) {
            bar
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// The proportional track, drawn by the shared `UsageBarView` (UX-007). The five
    /// segments keep their fixed draw order and their `DiskPalette` colors; the
    /// bar owns the largest-remainder pixel settlement so widths sum to exactly the
    /// track width — no sliver gap or 1px overflow at the trailing edge.
    private var bar: some View {
        UsageBarView(
            segments: segments.map { .init(bytes: $0.bytes, color: $0.id.color) },
            total: breakdown.totalBytes
        )
    }

    /// Wrapping legend: a colored swatch, the category name, and its size for every
    /// non-empty segment. This is what makes the bar readable without relying on hue.
    private var legend: some View {
        FlowLayout(spacing: 8, lineSpacing: 2) {
            ForEach(visibleSegments) { segment in
                HStack(spacing: 4) {
                    Circle()
                        .fill(segment.id.color)
                        .frame(width: 7, height: 7)
                    Text("\(segment.name) \(ByteFormat.text(fromBytes: segment.bytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// "Macintosh HD storage breakdown: System 60 GB, Apps 30 GB, Free 50 GB" —
    /// the whole bar spoken as one ordered sentence (TECHSPEC §8 correction 2).
    private var accessibilitySummary: String {
        let parts = visibleSegments.map { "\($0.name) \(ByteFormat.text(fromBytes: $0.bytes))" }
        let list = parts.isEmpty ? "no data" : parts.joined(separator: ", ")
        return "\(volumeName) storage breakdown: \(list)"
    }

    /// Distributes `trackWidth` across the segments proportionally to `bytes`. The
    /// settlement itself now lives on `UsageBarView` (UX-007) so the plain and
    /// category bars round identically; this thin forwarder keeps the settlement's
    /// unit tests anchored to the category bar they were written against.
    static func pixelWidths(for bytes: [Int64], total: Int64, trackWidth: CGFloat) -> [CGFloat] {
        UsageBarView.pixelWidths(for: bytes, total: total, trackWidth: trackWidth)
    }
}

/// Minimal wrapping layout for the legend chips: lays children left to right,
/// wrapping to a new line when the next child would overflow the available width.
/// Kept tiny and local — the legend is the only wrapping content in the popover,
/// and `Layout` avoids the fixed-column rigidity of `Grid`/`HStack` for chips of
/// varying width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth)
        let width = proposal.width ?? maxRowWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Lightweight placeholder for a deferred volume whose sizes are still being
/// resolved off-main (PRD FR4): name plus a small spinner, no fake numbers.
struct PendingVolumeRowView: View {
    let volume: DeferredVolume

    var body: some View {
        HStack(spacing: DiskMetrics.inlineSpacing) {
            DiskGlyph(kind: volume.kind, tint: Color(nsColor: .secondaryLabelColor))
                .imageScale(.large)
            Text(volume.name)
                .font(.system(size: DiskMetrics.nameFontSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: DiskMetrics.inlineSpacing)
            ProgressView()
                .controlSize(.small)
        }
        .padding(DiskMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DiskMetrics.cardCornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume.name), loading")
    }
}

/// Muted row for a deferred volume whose capacity read failed or timed out
/// (hung mount — VOL-002). The volume stays listed; only its sizes are unknown.
struct UnavailableVolumeRowView: View {
    let volume: DeferredVolume

    var body: some View {
        HStack(spacing: DiskMetrics.inlineSpacing) {
            DiskGlyph(kind: volume.kind, tint: Color(nsColor: .tertiaryLabelColor))
                .imageScale(.large)
            Text(volume.name)
                .font(.system(size: DiskMetrics.nameFontSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: DiskMetrics.inlineSpacing)
            Text("Unavailable")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(DiskMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DiskMetrics.cardCornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume.name), size unavailable")
    }
}
