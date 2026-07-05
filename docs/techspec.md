# TECHSPEC — justStats (macOS menu bar disk monitor)

Status: v1 build-complete (Phases 0-6 shipped; Phase 7 release QA in progress). Last updated: 2026-07-05. Traces to `docs/prd.md`.

## 1. Architecture Overview

Native macOS menu bar app, AppKit-based (not SwiftUI `MenuBarExtra`), mirroring the proven module structure of [exelban/stats](https://github.com/exelban/stats) (MIT), verified directly against its source rather than assumed.

```
justStats.app
├── App (AppKit lifecycle, NSStatusItem, NSPopover host)
├── Kit (shared helpers: extensions, formatting, UserDefaults wrapper — pattern borrowed from Stats' Kit)
└── Modules
    └── Disk (v1; RAM/Net modules added in v2 following the same shape)
        ├── IconController   — cheap periodic boot-volume statfs → icon color
        ├── VolumeEnumerator — FileManager + DiskArbitration metadata (on-demand)
        ├── CategoryScanner  — Spotlight (NSMetadataQuery) category + largest-files (on-demand)
        └── FileActions      — Reveal in Finder / Move to Trash
```

**Why AppKit, not SwiftUI `MenuBarExtra`:** `NSStatusItem` + `NSPopover` gives full control over a dense, scrollable, interactive list (category bars, largest-files rows with action buttons) that `MenuBarExtra`'s popover model handles less predictably. It's also the exact shape of the reference project we're already borrowing patterns from.

**Refinement (per the installed `macos-app-design` skill, which defaults to "prefer SwiftUI, drop to AppKit only when needed"):** the AppKit choice is for the **shell** only — `NSStatusItem` creation, `.button`/`NSStatusBarButton`, and `NSPopover` lifecycle. The popover's actual **content** (volume rows, category bars, largest-files list) is a SwiftUI view tree hosted via `NSHostingView` inside that popover — matches the skill's own default (SwiftUI first) plus the real-world pattern already confirmed in the `multi.app` NSStatusItem article. Keep the AppKit↔SwiftUI bridging layer thin, per the skill's explicit rule ("if using AppKit, keep bridging layer thin and well-tested").

App archetype (per the skill's own taxonomy): **Menu-bar app** — "lives in menu bar, minimal UI." This means the skill's full "Mac Citizen" baseline (standard App/File/Edit/View/Window/Help menu, multi-window support) does **not** apply — those are for windowed archetypes. What still applies regardless of archetype: keyboard accessibility, VoiceOver labels, and Settings reachable via ⌘, (already covered by our separate Settings window, FR10–FR11).

## 2. Requirement → Decision Traceability

| PRD Requirement | Technical Decision |
|---|---|
| FR1 (icon color from boot volume) | `IconController` — lightweight background timer, single `statfs()` call on boot volume only. See §3. |
| FR2–FR5 (popover, internal-first, async external, per-row data) | `VolumeEnumerator` runs on popover open: `FileManager.default.mountedVolumeURLs` for the full list, internal volumes resolved and rendered first (synchronous, cheap), external/network volumes resolved on a background `DispatchQueue` and appended as they complete. |
| FR6 (category breakdown) | `CategoryScanner` — `NSMetadataQuery` (Spotlight) predicates per category, computed lazily on open. See §4. |
| FR7–FR8 (largest files, reveal/trash) | `CategoryScanner` largest-N query + `FileActions` using `NSWorkspace.activateFileViewerSelecting` (reveal) and `FileManager.trashItem(at:resultingItemURL:)` (trash — goes to Trash, not permanent delete). Confirmation alert required before `trashItem` call. |
| FR9 (sort by fullness) | Client-side sort on the already-fetched volume list; no extra data cost. |
| FR10 (configurable thresholds) | Plain `UserDefaults` keys: `redThresholdBytes`/`redThresholdPercent`, `yellowThresholdBytes`/`yellowThresholdPercent`, `thresholdMode` (`.absolute`/`.percentage`). No schema versioning (explicit simplicity call). |
| FR11 (launch at login) | `SMAppService.mainApp.register()` / `.unregister()` (macOS 13+ API) — no helper executable, unlike Stats' legacy pattern. See §5. |
| FR12 (Sparkle auto-update) | Sparkle framework, self-generated EdDSA key pair, `appcast.xml` served from `raw.githubusercontent.com` on the `main` branch, updated per release. Artifact: `.zip`. See §6. |
| FR13 (refresh model) | Two-tier: `IconController` timer (icon only) + lazy full compute on popover open + manual "Refresh" button. See §3. |
| NFR1–NFR4 (performance) | Enforced by design: only one cheap `statfs` call runs continuously; all expensive work (Spotlight queries, full enumeration) is on-demand and off the main thread. See §7. |

## 3. Refresh Model (resolved architecture question)

Two independent data tiers, deliberately decoupled because their cost profiles differ by orders of magnitude:

1. **Icon tier** (must be live without any click — PRD Goal 2): a single lightweight repeating timer (`Timer`/`DispatchSourceTimer`) calls `statfs()` on the boot volume only. Cost: sub-millisecond per tick. Interval: default 30s (tunable constant, not user-facing — no config UI for this, per PRD non-goal on configurable refresh interval).
2. **Popover tier** (everything else — full volume list, category breakdown, largest files): computed **only** when the popover opens, plus on explicit "Refresh" button press. No background polling for this tier at all.
   - Internal volumes: resolved synchronously (fast, local `statfs`) — render immediately.
   - External/network volumes: resolved on `DispatchQueue.global(qos: .utility)`, appended to the UI as each resolves — protects against a hung SMB mount blocking anything.
   - Category breakdown + largest files: `NSMetadataQuery` per volume, also off the main thread, streamed into the UI per volume as results arrive.

This resolves PRD's former open question ("should mount/unmount trigger an immediate refresh?") — **no dedicated mount/unmount listener in v1.** Opening the popover always re-enumerates current volumes, which is equivalent in practice and matches Stats' own verified approach (timer + re-enumerate, not `DARegisterDiskAppearedCallback` event subscriptions).

- **ADR-CANDIDATE: Split data into a "live, cheap, always-on" tier (icon) and a "lazy, expensive, on-demand" tier (popover contents), rather than one uniform background-refresh loop.**
  Context: PRD required both "icon glanceable without opening" and strict low CPU/memory NFRs; a single uniform poll loop would force a choice between staleness (long interval) and system load (short interval) for data that's expensive to compute (Spotlight queries).
  Alternatives considered: one interval driving everything (simpler, but forces the expensive Spotlight/enumeration work to run on a timer even when nobody's looking); full event-driven `DiskArbitration` mount/unmount subscription (more "real-time," but adds complexity Stats itself doesn't carry, for a benefit — instant mount detection — the user didn't ask for and popover-open already provides in practice).
  Chosen: two-tier split, confirmed with the user directly.
  Promoted to ADR: `ADR/002-two-tier-refresh-model.md` (Accepted).

## 4. Category Breakdown — Default Taxonomy (resolves PRD open question)

Concrete default mapping, computed via `NSMetadataQuery` scoped to the volume:

| Category | Query / method |
|---|---|
| Apps | `kMDItemContentType == 'com.apple.application-bundle'`, summed logical size. |
| Media | `kMDItemContentTypeTree` intersects `public.image`, `public.movie`, `public.audio`. |
| Free | `statfs` free bytes (not a Spotlight query). |
| System | **Residual**: `Total − Free − Apps − Media − Other`, clamped to ≥ 0. Avoids needing to positively classify every OS/cache/hidden file — matches the "large residual bucket" approach Finder's own "About This Mac → Storage" view uses. |
| Other | User-owned files not matching Apps or Media (documents, archives, code, etc.) via one additional Spotlight predicate scoped to `/Users/*`. |

This is a default, not exhaustively validated — flagged for adjustment once real data is seen during implementation (e.g., if "System" ends up absurdly large due to a missed bucket, or "Other" query is too expensive, simplify further).

**Degraded state:** if `NSMetadataQuery` returns no usable index for a volume (external/network drives are frequently unindexed), show "Not indexed — category breakdown unavailable" in that volume's row instead of a zero/misleading bar. No automatic fallback to a raw recursive scan (would violate NFR1–NFR4); if this proves insufficient in practice, an opt-in manual "scan anyway" action is a candidate for a later backlog item, not v1.

## 5. Launch at Login

`SMAppService.mainApp.register()` called from Settings toggle; `.unregister()` to disable. Status read via `SMAppService.mainApp.status`. No separate helper target, no embedded login-item executable — this **corrects** the PRD's original plan to reuse Stats' `LaunchAtLogin` module, made after reading Stats' actual source: that module is a legacy helper-executable pattern needed only for macOS versions older than our Sequoia-15+ baseline, so copying it would add unnecessary complexity here.

## 6. Distribution & Update Mechanism

- **Code signing:** none (no Apple Developer Program membership) — ad-hoc/unsigned build. Gatekeeper will require a manual right-click → Open on first launch; documented in README.
- **Update framework:** Sparkle, with a self-generated EdDSA key pair (`generate_keys` tool from Sparkle) — public key embedded in `Info.plist`, private key kept outside the repo (never committed).
- **Appcast hosting:** `appcast.xml` committed to the repo, served via `https://raw.githubusercontent.com/<org>/justStats/main/appcast.xml`. Updated as part of the release process (manual step, documented in a release checklist).
- **Release artifact:** `.zip` of the `.app` bundle, attached to a GitHub Release; Sparkle points at the GitHub Release asset URL.
- **Gatekeeper × Sparkle upgrade — VERDICT: GO (with an install requirement).** Spike run 2026-07-05 (REL-002) on **macOS 15.7.5, Apple Silicon (arm64), Gatekeeper enabled** (`spctl --status` = assessments enabled). Built v0.0.1 + v0.0.2 (unsigned), served a local signed test appcast, installed v1, approved it via right-click → Open, and triggered the real Sparkle upgrade. Result: **the update installed and relaunched to 0.0.2 silently — no fresh Gatekeeper block, no re-prompt.** Evidence on the updated bundle: `com.apple.quarantine` is **absent** (Sparkle strips the quarantine xattr on the replacement bundle; only a benign `com.apple.provenance` remains). Note: `spctl -a -vvv` reports "rejected: no usable signature" — that is the *expected* static assessment for an unsigned app and is **not** a launch block; the operative runtime gate is the quarantine flag, which is gone. Silent Sparkle auto-update for the unsigned build is therefore **GO**.
  - **Install requirement uncovered by the spike (must be in the README):** the **first** Sparkle update only works if the user moved the app into `/Applications` **via a Finder drag**. A quarantined app launched from where it was extracted/copied (or copied with `ditto`/`cp` on the CLI) is subject to **App Translocation** (Gatekeeper path randomization) — it runs from a read-only randomized path, and Sparkle refuses to update it with *"justStats can't be updated if it's running from the location it was downloaded to."* Moving the app in Finder clears translocation; after that the silent-update path above works. This is a documentation/UX requirement, not a code change.
  - **Fallback (not needed — spike passed):** had the spike returned FAIL (a re-block), the plan was to keep Sparkle for *detection* only and point users to a manual `.zip` re-download. Retained here for the record; the proper long-term removal of all Gatekeeper friction is Developer ID signing + notarization, still out of scope for v1.

## 7. Performance, Reliability, Security

- **NFR1/NFR2 (CPU/memory):** enforced structurally by the two-tier refresh model (§3) — the only continuously-running work is one `statfs` call every ~30s.

  **Pinned baseline — measured on Apple Silicon (2026-07-05).** Environment: Apple M1 Pro, macOS 15.7.5 (24G624), Xcode 26.3; a `-configuration Release` build (`CODE_SIGNING_ALLOWED=NO`), launched via `open`, left to idle, sampled with `ps -o %cpu,rss` and `top -l … -s 1` while nothing but the 30s icon timer was running (no popover opened, no Spotlight/enumeration work). The app is `LSUIElement`, so the pid was found with `pgrep -x justStats`.

  | NFR | Metric | Measured (idle) |
  |---|---|---|
  | NFR1 | Idle CPU | **≈ 0.0%.** Over a 34-sample, 1-second-interval window spanning a full 30s timer tick, 32 of 34 samples read 0.0%; the two nonzero samples were 0.2% and 0.1% (max 0.2%). `ps` reported a steady 0.0% across a full minute. |
  | NFR2 | Idle memory | **≈ 9.9 MB phys footprint** (`top` MEM/`rsize`, stable ~9.87–9.92 MB). `ps` RSS was ≈ 38–43 MB — that figure includes shared framework/dyld pages counted per-process and is expected to be larger than the phys footprint. Thread count: 4–5. |
  | NFR3 | Cold-launch perception | **≈ 0.12 s** from the `open` call to the process pid existing (best-effort wall-clock; the status item is created synchronously in `applicationDidFinishLaunching` immediately after process start — see below). This number includes `open`/`LaunchServices` and process-spawn overhead, so it is a loose upper bound on "time to status item", not a precise render timestamp. |

  These absolute numbers are consistent with the "one cheap `statfs` per 30s" design intent: idle CPU sits at 0.0% between ticks with only sub-0.3% momentary blips (the periodic statfs plus normal runloop wakeups), and there is no background Spotlight/enumeration activity when the popover is closed. Idle memory (~10 MB phys footprint) is small for an AppKit + SwiftUI-hosted menu-bar app.

  **Stats side-by-side comparison — MANUAL FOLLOW-UP, not done here.** exelban/stats is **not installed** on the measurement machine, so the PRD NFR1–NFR3 "≤ Stats disk-module footprint" comparison could **not** be run and no comparison numbers are recorded (deliberately not fabricated). To close the PRD open question, a human should install Stats with only its Disk module enabled on the same Mac and compare its idle CPU / idle memory against the justStats baseline above. On current evidence justStats' absolute idle footprint is already very low (idle CPU ≈ 0%), so the comparison is expected to pass, but it remains unverified until run.

- **NFR3 (launch time):** `NSStatusItem` creation and icon rendering happen at app launch before any Spotlight/enumeration work — nothing blocks icon appearance. The status item and its first `statfs`-driven icon refresh are created synchronously in `applicationDidFinishLaunching` (see `justStats/App/AppDelegate.swift`) before the popover/enumeration seams are wired, so the glanceable icon is present as soon as the process is up (measured cold-launch-to-pid ≈ 0.12 s above). A precise on-screen "status item visible" timestamp requires a GUI/accessibility observation and is a manual follow-up.
- **Reliability — external/network volumes:** all `statfs`/Spotlight calls for non-internal volumes run off the main thread (`DispatchQueue.global(qos: .utility)`); a hung SMB mount can only delay that specific row's data, never the popover's initial render or the internal-disk rows.
- **Security — Full Disk Access:** requested **lazily**, not at first launch. The app attempts Spotlight/category queries normally; if a volume's results come back empty/incomplete in a way consistent with a permissions block, the popover shows an inline notice ("Grant Full Disk Access for complete data") with a button opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` directly.
- **Security — Move to Trash:** uses `FileManager.trashItem(at:resultingItemURL:)` (recoverable via macOS Trash, never `removeItem` / permanent delete), gated by an inline confirmation dialog before the call (PRD FR8).
- **Data at rest:** no telemetry, no network calls except Sparkle's update check and GitHub Release asset download — nothing else leaves the machine.

## 8. UI/Layout Notes (grounded in verified sources, not invented)

Sourced from two places only: (a) a technical article on `NSStatusItem` that directly quotes Apple's HIG (Apple's own HIG pages are JS-rendered and could not be fetched as text — flagged, not substituted with invented content), and (b) exelban/stats' actual `Modules/Disk/popup.swift` source, read directly.

**Hard API constraints (verified, not a design choice):**
- Menu bar status items are a fixed **24pt tall**; only width is flexible (`NSStatusItem.variableLength`).
- The `NSStatusItem.view` property has been **deprecated since macOS 10.14** — only `.button` (`NSStatusBarButton`) is viable. This is the entry point for icon rendering and popover attachment.
- Standard menu bar icons use **template images** (black + transparent; macOS auto-adapts them to light/dark mode and the highlighted state). **This does not work for FR1**, which requires an actual green/yellow/red icon — a real color can't be a template image. Consequence: the icon must be a non-template `NSImage`, and light/dark-mode + highlighted-state appearance must be handled explicitly in code (not automatic) — e.g., render two icon variants (normal/highlighted) per color state, similar to how colored menu-bar indicators (e.g., battery icon) already do this in practice. Flagging as a real implementation detail, not a nice-to-have.
- Apple's HIG explicitly says **"avoid relying on the presence of menu bar extras"** (quoted from the sourced article) — i.e., HIG's default position is that core functionality shouldn't live *only* in the menu bar. justStats is a menu-bar-only utility by design (PRD Goal 1), same accepted trade-off every comparable app in this space makes (Stats, iStat Menus, diskbar.app all have no meaningful window/Dock-icon alternative either) — noted as a known, deliberate deviation from HIG's general preference, not an oversight.

**Structural precedent from Stats' actual popup code (`Modules/Disk/popup.swift`):**
- Popup content is a single vertical `NSStackView` (`orientation = .vertical`), fixed popup **width** as a shared constant, **height computed dynamically** from summed subview heights (`recalculateHeight()`), resized on content change rather than fixed up front.
- Each volume is one row inside that stack; a secondary list section (in their case, top-N I/O-heavy processes) is appended **below** the volume rows, with a configurable row count and a computed height per row.

**Applying this to justStats' popover (structure, not visual polish):**
1. Vertical `NSStackView`, dynamic height (matches Stats' own approach) — avoids guessing a fixed popup size that won't fit varying volume counts.
2. One row per volume (internal rows populate first, external/network rows appended below as they resolve — per §3), each row containing: name, total/used/free (FR5), and the category breakdown bar (FR6) inline in the same row — mirrors diskbar.app's single-row-per-volume layout rather than a separate screen per volume.
3. A "largest files" section **below the volume rows**, scoped to the currently-relevant volume (structurally identical to Stats' below-the-list processes section) — top-N rows, each with Reveal/Trash actions (FR7–FR8) and an inline delete-confirmation state rather than a separate modal, to stay consistent with Stats' compact-popup precedent.
4. A settings-gear affordance (opens the separate Settings window, FR10–FR11) — a standard, low-risk placement (top-right corner of the popup), not specified further here.

**Explicitly not decided here (real open item, not filled in with invented specifics):** exact spacing/padding values and typography beyond "use system text styles and default spacing" (the skill's own rule) — these remain a deferred, iterative design pass during implementation (per PRD Assumptions), now at least working from a structurally grounded skeleton instead of a blank page.

**Two corrections from the installed `macos-app-design` skill, both substantive:**

1. **Liquid Glass is out of scope for v1.** It's Apple's new material system introduced with **macOS Tahoe 26**, not available on our Sequoia-15+ baseline. (This also explains why diskbar.app itself requires macOS 26+ — it's likely built around this exact material.) v1 uses standard system materials/vibrancy, which render correctly across the whole 15–26 range without any conditional code. Revisit Liquid Glass only if/when the OS baseline is raised — explicit non-goal for now, not an oversight.
2. **Icon color must not be the only signal (accessibility rule: "don't encode meaning by color alone").** FR1 as written relies solely on hue (green/yellow/red) — this excludes colorblind users and provides nothing for VoiceOver. Concrete fix: pair the color with (a) a distinct glyph/shape change at the red/critical state (e.g., an exclamation badge or a visibly different icon fill, not just a color swap) and (b) an accessibility label on the status item (`NSStatusBarButton.setAccessibilityLabel`, e.g. "Disk status: critical, 8 GB free") so VoiceOver announces the actual state, not just an unnamed colored icon. Added as a correction to FR1 in the PRD (color-only was the original gap).

**Iconography:** prefer **SF Symbols** for in-popover icons (gear for Settings, trash/Finder-reveal glyphs) per the skill's guidance ("use SF Symbols for system concepts, only design custom symbols when domain requires"). The colored status-bar icon itself is the one deliberately custom element (SF Symbols don't natively support arbitrary per-state fill colors the way we need for the traffic-light indicator), built as described above (non-template image, explicit light/dark + highlighted variants, now also with the redundant non-color cue from point 2).

## 9. Verification Strategy

- **Unit tests (XCTest):** pure logic only — used/free/percentage math, threshold → color mapping (absolute and percentage modes), category-residual math (`System` clamp-to-zero edge case), largest-files sort/truncation. No UI automation (`XCUITest` against `NSStatusItem`/`NSPopover` is fragile and explicitly out of scope, confirmed with the user).
- **CI:** GitHub Actions — build + run unit tests on every push/PR. No release automation in this pipeline yet (release/appcast update stays a manual, documented step per §6).
- **Manual QA checklist (pre-release, minimum set):**
  1. Cold launch — icon appears immediately, correct color for current boot-volume free space.
  2. Open popover — internal disks appear first with no visible delay.
  3. Attach an external (USB) volume — appears in the list without blocking the rest of the UI.
  4. Simulate/mock a disconnected or slow network volume — popover still renders internal + external rows without freezing.
  5. Volume with abundant free space → green icon; force free space under yellow/red thresholds (or lower thresholds in Settings) → icon color updates within one timer tick.
  6. Largest-files → Reveal in Finder opens the correct file; Move to Trash prompts for confirmation and actually moves the file to Trash (verify recoverability).
  7. Toggle Launch at Login on/off, log out/in, confirm actual behavior matches the toggle.
  8. Volume without Full Disk Access granted → degraded notice shown, granting access and reopening resolves it.
  9. VoiceOver on → status item announces actual disk state (not just "button"); every popover control (rows, Reveal, Trash, Refresh, Settings gear) is reachable and operable via keyboard alone.

## 10. Assumptions & Open Questions Carried Forward

- Exact idle CPU/memory numbers: measured and pinned in §7 (2026-07-05, Apple Silicon — idle CPU ≈ 0.0%, idle memory ≈ 9.9 MB phys footprint). Remaining open item: the side-by-side comparison against a real exelban/stats install, which is a manual follow-up (Stats is not installed on the measurement machine).
- Gatekeeper + Sparkle upgrade-flow behavior: unverified, needs a spike before public release (see §6).
- Category taxonomy (§4) is a first-pass default, expected to be refined once real volumes are tested.
- Whether an opt-in manual raw-scan fallback is needed for unindexed volumes: deferred, default is to only show the degraded state in v1.
- Non-template colored icon needs explicit normal/highlighted (and possibly light/dark) variants handled in code, since macOS's automatic template-image adaptation doesn't apply to a real-color icon (see §8) — needs a concrete implementation pass, not fully specified here.

## 11. ADR-Candidate Summary (see also `docs/prd.md`)

- Native AppKit (`NSStatusItem`/`NSPopover`) over SwiftUI `MenuBarExtra` — §1. Promoted to ADR: `ADR/001-native-appkit-shell-swiftui-content.md` (Accepted).
- Two-tier refresh model (live icon timer vs. lazy on-demand popover compute) — §3. Promoted to ADR: `ADR/002-two-tier-refresh-model.md` (Accepted).
- Spotlight-based category/largest-files computation, with explicit degraded state instead of raw-scan fallback — §4 (refines PRD's original ADR-CANDIDATE). Promoted to ADR: `ADR/003-spotlight-based-scanning.md` (Accepted).
- Sparkle auto-update with a self-managed EdDSA key, no Apple notarization/Developer ID — §6. Promoted to ADR: `ADR/004-sparkle-without-notarization.md` (Accepted).
- `SMAppService` for launch-at-login instead of reusing Stats' legacy helper-executable pattern — §5 (corrects PRD's original ADR-CANDIDATE after source inspection). Promoted to ADR: `ADR/005-smappservice-launch-at-login.md` (Accepted).
- Mirror Stats' `Kit`/`Modules` structural pattern for the module boundary, without adopting its `DiskArbitration`-as-event-source approach (Stats itself doesn't use it that way either) — §1, §3.
