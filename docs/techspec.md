# TECHSPEC — justStats (macOS menu bar disk monitor)

Status: v1 build-complete (Phases 0-6 shipped; Phase 7 release QA in progress). Last updated: 2026-07-05. Traces to `docs/prd.md`.

## 1. Architecture Overview

Native macOS menu bar app, AppKit-based (not SwiftUI `MenuBarExtra`), mirroring the proven module structure of [exelban/stats](https://github.com/exelban/stats) (MIT), verified directly against its source rather than assumed.

```
justStats.app
├── App (AppKit lifecycle, NSStatusItem, NSPopover host)
├── Kit (shared helpers: extensions, formatting, UserDefaults wrapper — pattern borrowed from Stats' Kit)
└── Modules
    ├── Net (phase 18; sampler-on-open, see §14)
    └── Disk (v1; RAM module added later following the same shape)
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
| FR14 (reclaimable section) | `CleanupCatalog` — static table of `CleanupRule` values (id, name, detection, size probe, safety tier, action). `ReclaimableScanner` evaluates rules lazily on popover open, off the main thread, like the other scanners. See §12. |
| FR15 (Clean action) | `CleanupExecutor` — `.deleteDirectory(URL)` via `FileManager.removeItem` after the guard checks, or `.runCommand(AllowedCommand)` via `Process` with a fixed argv, timeout and no shell. See §12. |
| FR16 (AI prompt) | `AIPromptBuilder` — pure function producing the English prompt text from scanner output; copied with `NSPasteboard`. See §12. |
| FR17 (eject volume) | `VolumeEjecting` seam; production `DiskArbitrationVolumeEjector` (`DADiskUnmount` on the whole disk) names the refusing process via the dissenter PID. `VolumeListViewModel` holds per-volume `EjectState` and drops rows on `NSWorkspace.didUnmountNotification`. See §13. |
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

  **Network section (NET-005) — measured 2026-11-22.** Same machine and OS as the pinned baseline (Apple M1 Pro, macOS 15.7.5 (24G624)), same method (`-configuration Release`, `CODE_SIGNING_ALLOWED=NO`, launched directly, 8 s settle, then `top -l 61 -s 1 -pid <pid>`; the first `top` sample is cumulative and dropped, leaving 60 one-second samples; popover never opened). A same-session A/B: the pre-network commit (`cebd2ef`) versus this change, one 60 s run each.

  | Build (popover closed) | CPU, 60 samples | MEM (`top`) | `footprint` | Threads |
  |---|---|---|---|---|
  | Before network (`cebd2ef`) | 59 × 0.0%, one 44.1% sample at the ~30 s mark (avg 0.74%) | 9.78–9.83 MB for 19 samples, 12 MB for the other 41 | 12 MB | 5–7 |
  | With network section | 59 × 0.0%, one 0.1% sample (avg 0.002%, max 0.1%) | 10 MB, flat across all 60 samples | 10 MB | 5–6 |
  | **Pinned baseline (2026-07-05)** | 32 of 34 samples 0.0%, max 0.2% | ≈ 9.9 MB | — | 4–5 |

  **Closed-popover delta: none attributable to the network section.** The new build sits at the baseline's numbers (idle CPU 0.0% in 59 of 60 samples, the one exception 0.1% against the baseline's 0.2% max; 10 MB footprint against 9.9 MB pinned). By construction nothing network-related exists while the popover is closed: no sampler timer, no `nettop`, no CoreWLAN/Location access (`NetSamplerTests.testNoTimerExistsOrFiresUntilStart`, coordinator spy). Caveat, stated plainly: the *pre-network* build showed one 44.1% sample and a 12 MB footprint in this run; that is a transient of the unchanged baseline code (it appears in the build without the net module, near the 30 s mark, not reproduced in the second run), so the A/B is "within run-to-run noise", not "the new build is leaner". n = 1 run per build.

  **Expanded state — cost of the pieces that run (popover open, section expanded).** Not measured through the GUI (the status item cannot be driven headlessly here), so the components were measured and the duty cycle derived:
  - **`nettop` pass** (`-P -L 1 -n -k …`, 20 passes, the real argument list): **10.7 ms CPU per pass** (user+sys), 10–18 ms wall (avg 12), 4.7 MB peak RSS for the child, 1.4 KB of CSV. At the 4 s interval that is **≈ 0.27% of one core on average**, as a burst of ≈ 11 ms every 4 s; the child exists only for that pass.
  - **Sampler tick** (sysctl `NET_RT_IFLIST2` read of 23 interfaces + `NetThroughputEngine.ingest`, 5000 ticks, in the *Debug* unit-test build, so an upper bound): **≈ 405 µs CPU per tick**, i.e. **≈ 0.04% of one core at 1 Hz**, only while the popover is open.
  - **ICMP echo + metadata read:** once per expand/Refresh; the echo has a 2 s timeout and measured 10 ms round trip on this network; the CoreWLAN/SystemConfiguration reads are one-shot.
  - **Not measured:** phys footprint with the popover open and the section expanded, and CPU of the SwiftUI sparkle redraw once per second. Both run only while the popover is on screen and are covered by no number here; a manual `top` pass with the section expanded is the follow-up if the owner wants them pinned.

- **NFR3 (launch time):** `NSStatusItem` creation and icon rendering happen at app launch before any Spotlight/enumeration work — nothing blocks icon appearance. The status item and its first `statfs`-driven icon refresh are created synchronously in `applicationDidFinishLaunching` (see `justStats/App/AppDelegate.swift`) before the popover/enumeration seams are wired, so the glanceable icon is present as soon as the process is up (measured cold-launch-to-pid ≈ 0.12 s above). A precise on-screen "status item visible" timestamp requires a GUI/accessibility observation and is a manual follow-up.
- **Reliability — external/network volumes:** all `statfs`/Spotlight calls for non-internal volumes run off the main thread (`DispatchQueue.global(qos: .utility)`); a hung SMB mount can only delay that specific row's data, never the popover's initial render or the internal-disk rows.
- **Security — Full Disk Access:** requested **lazily**, not at first launch. The app attempts Spotlight/category queries normally; if a volume's results come back empty/incomplete in a way consistent with a permissions block, the popover shows an inline notice ("Grant Full Disk Access for complete data") with a button opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` directly.
- **Security — Move to Trash:** uses `FileManager.trashItem(at:resultingItemURL:)` (recoverable via macOS Trash, never `removeItem` / permanent delete), gated by an inline confirmation dialog before the call (PRD FR8).
- **Security — Eject:** unmounting uses DiskArbitration with the current user's rights (no sudo, no helper, no shell, no `lsof`). Force Eject is a second explicit tap after a data-loss warning (PRD FR17). Process names/PIDs of other programs are shown in the UI only, never logged or sent anywhere.
- **Data at rest:** no telemetry, no network calls except Sparkle's update check and GitHub Release asset download, plus the single ICMP echo behind the network section's expanded "Internet" row (§14: one echo per expand or Refresh, never periodic, no public-IP lookup) — nothing else leaves the machine.

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
- Eject with holder naming via the DiskArbitration dissenter PID (resolved at runtime), no `lsof`/sudo — §13. Promoted to ADR: `ADR/007-diskarbitration-eject-with-holder.md` (Accepted).
- Rule-catalog cleanup (directory delete + allowlisted commands, no heuristics, no AI) — §12. Promoted to ADR: `ADR/006-rule-catalog-cleanup.md` (Deferred 2026-11-21).

## 12. Reclaimable Space Cleanup (FR14–FR16)

> Deferred 2026-11-21 (owner decision): cleanup moves to the separate macos-cleanup
> app; justStats stays statistics-only. FR14–FR16 and the backlog branch ADR-004 +
> CLEAN-001…006 are deferred with it. This section stays as the design reference the
> cleanup app can build on.

### 12.1 Rule model

```swift
struct CleanupRule {
    let id: String              // stable, e.g. "vscode-shipit"
    let title: String
    let detect: Detection       // .path(URL) | .tool(binary: String, probe: AllowedCommand)
    let tier: SafetyTier        // .green (one-click) | .yellow (explain only)
    let action: CleanupAction   // .deleteDirectory(URL) | .runCommand(AllowedCommand)
    let guardrail: Guardrail?   // e.g. .processNotRunning("Visual Studio Code")
    let note: String            // shown in the confirmation
}
```

- Rules are data in one file. Adding a rule never touches executor logic.
- Initial catalog (all green unless noted): VS Code ShipIt leftovers (`~/Library/Caches/com.microsoft.VSCode.ShipIt`), uv cache (`uv cache prune`), npm cache (`npm cache clean --force`), Homebrew cache (`brew cleanup`), Docker (`docker system prune -a -f`, requires a running daemon), Xcode DerivedData. Yellow, explain-only: Hugging Face model cache (`~/.cache/huggingface`), app VM bundles.
- Sizes come from a bounded directory-size walk (allocated size, consistent with UX-010/UX-011) or the tool's own report; results are cached with the existing TTL cache (UX-002).

### 12.2 Execution safety

- No shell. Commands are fixed argv arrays from the `AllowedCommand` enum; user data never reaches argv.
- `deleteDirectory` only accepts a URL that equals a rule's declared path after standardizing; symlinks are not followed; the path must be inside the user's home and must not be the home itself.
- A rule with a guardrail refuses to run while the guarded process is running and says why in the row.
- Every action needs the inline confirmation (same pattern as ACT-002), is keyboard- and VoiceOver-operable, and reports bytes freed measured before/after.

### 12.3 AI prompt

`AIPromptBuilder` output (English) has four parts: (1) role and hard rules — analysis is read-only first, report before proposing, never delete without explicit confirmation, never run `rm -rf` on a variable or home-level path, measure with allocated size and beware symlink double counting, check last-used time before calling something stale; (2) the machine facts the app already knows — volume, total/free, category breakdown, largest files (paths); (3) what the catalog already offered and what was cleaned; (4) the ask — find the next biggest safe wins and list them with size, last-used date and how to reverse.

The preview dialog shows the full text before it is copied; file paths in the prompt are the only personal data and nothing leaves the Mac unless the user pastes it.

## 13. Volume Eject (FR17)

**UI.** External and network volume rows (and `.unavailable` deferred rows — a hung share is the mount most worth unmounting) show an eject glyph button (`HoverFillButtonStyle`, revealed on row hover). It is never offered on the boot volume — checked by path `/`, so macOS booted from an external SSD is covered too — nor on internal fixed disks or `.pending` rows (`VolumeListViewModel.Row.isEjectable`). The panel under a row follows the Move-to-Trash inline-confirmation pattern (§8), not a modal.

**State machine** (`VolumeListViewModel.EjectState`, per mount URL): idle → `.ejecting` → success (row removed) | `.refused(message)` | `.failed(message)`. From `.refused`: Retry re-issues the plain unmount; Force Eject → `.confirmingForce` (shows the data-loss warning) → second tap re-issues with the force option. A late completion for a state that is no longer `.ejecting` is dropped; state survives Refresh for rows that still exist.

**Removal.** The model observes `NSWorkspace.didUnmountNotification` (through an injected `NotificationCenter`) while the popover is open and drops the row for each unmounted URL — so every volume of an ejected multi-volume stick leaves the list, and a volume ejected from Finder disappears too. The observer is removed in `invalidate()`.

**Seam: `VolumeEjecting`** — `eject(volumeAt:force:completion:)` delivering `EjectResult` (`success` | `refused(holder:)` | `failed(reason:)`) on the main queue. Mockable like `VolumeInfoProviding` (`MockVolumeEjector`); the view model never touches DiskArbitration.

**Production: `DiskArbitrationVolumeEjector`.**
- The volume's `DADisk` comes from `DADiskCreateFromVolumePath`; `DADiskCopyWholeDisk` + `kDADiskUnmountOptionWhole` unmounts every volume on the physical disk, like Finder; `kDADiskUnmountOptionForce` is added for Force Eject. After a successful unmount a best-effort `DADiskEject` powers the media off. Callbacks run on a private queue (`QueueLabels.volumeEject`) and complete on main.
- **Holder.** On dissent the status is `EBUSY` (observed `0xc010`, no status string). The holder PID comes from `DADissenterGetProcessID`: exported by the DiskArbitration framework (present in its `.tbd`) but **not in the public headers**, so it is resolved with `dlsym` at first use; if absent, the refusal reads "a program is using it". Verified on macOS 15.7.5 / SDK 26.2 with a real mounted image held by a process: the PID matches `diskutil unmount`'s "dissented by PID …".
- **Process name.** `proc_name` returns nothing for other users' processes (it is empty for `mds_stores`, the usual holder), so the name falls back to `sysctl(kern.proc.pid)` `p_comm`, which any user can read.
- **Network mounts** have no DiskArbitration disk: plain eject uses `FileManager.unmountVolume(at:options:)`, Force uses `unmount(2)` with `MNT_FORCE`. These paths name no holder (a busy network volume reads "a program is using it"). Not exercised against a real SMB/NFS share in this task.
- **Which sibling refused.** On a multi-volume stick the dissenter does not say which volume's holder dissented; the message names the volume the user pressed Eject on plus the holder.

**Holder phrases** (`EjectMessages.knownHolderPhrases`, English only): `mds_stores` → Spotlight indexing, usually releases in a minute or two; `rsync` → file copy in progress; `backupd` → Time Machine backup; `Finder` → Finder has this disk or its files open; `photoanalysisd` → Photos analyzing. Anything else: `process <name> (PID <n>)`.

**Spotlight hint.** When the holder is `mds_stores` (`EjectMessages.lowRiskForceHolders`), the refusal panel adds a line saying Force Eject is safe here (Spotlight only writes its own index on the disk), and the force warning says so instead of the generic data-loss text. Every other holder, known or not, keeps the generic warning.

**Timing.** A busy volume takes about 11 s to refuse (measured), so the row shows an "Ejecting…" spinner for that long.

- **ADR-CANDIDATE: Eject via DiskArbitration `DADiskUnmount`, naming the holder through the dissenter's process ID (resolved at runtime, no `lsof`/sudo).** Promoted to ADR: `ADR/007-diskarbitration-eject-with-holder.md` (Accepted). Rationale and alternatives: `docs/prd.md`.

## 14. Network Monitoring (NET-001…005, phase 18)

Owner decisions of 2026-11-21: **no menu bar item**; the section lives in the existing disk popover, as a **Network tab** (Disks | Network switch under the header; the popover always opens on Disks, so a fresh open never touches the network code); **no public-IP row**; **no network-related work while the popover is closed**. Source mechanics were verified against exelban/stats `Modules/Net/readers.swift` (MIT, read 2026-11-21).

**Two-tier note (ADR-002).** The net module keeps the two-tier shape with *sampler-on-open as its only live tier*: there is no icon-tier equivalent, so nothing network-related exists at launch or at idle. `NetSampler` is created idle by `VolumeListPopoverCoordinator`; its timer is created in `start()` when the Network tab is selected (`NetworkSectionViewModel.activate()` via `PopoverTabsModel.select`) and cancelled in `stop()` when the user switches back to Disks or the popover closes (`popoverDidClose`, every close route). The two disclosures — **Interfaces** and **Top processes**, expanded independently — are a third, lazier level: nothing is read until the respective disclosure is expanded, and all of it stops on collapse, tab switch or popover close.

### 14.1 Layout (`justStats/Modules/Net/`)

| File | Role |
|---|---|
| `NetCounters.swift` | `InterfaceCounters`, the `NetCounterSource` seam, `NetInterfaceKind` (name-prefix filter), `SysctlNetCounterSource` (thin sysctl layer) |
| `NetThroughputEngine.swift` | Pure core: delta, clamp, plausibility cutoff, physical/virtual split, since-boot totals, reset offset |
| `NetSampler.swift` | `RingBuffer` (180 samples), `NetTickScheduling` seam (real `Timer`), `NetworkSampling` lifecycle protocol, `NetSampler` |
| `NetworkCardContent.swift`, `NetworkSectionView.swift`, `NetworkSectionViewModel.swift` | Card, sparkline, the two disclosures, `PopoverTabsModel`; pure state → content mapping (pattern of `VolumeRowView.Content`) |
| `NetworkMetadata.swift`, `NetworkDetails.swift` | Wi-Fi / local IP / DNS / ICMP / Location seams and production implementations; details state mapping and `NetworkDetailsModel` |
| `NettopParser.swift`, `ProcessTraffic.swift` | nettop CSV parser, process runner, ranking, `ProcessTrafficModel` |

### 14.2 Sampler (NET-001)

- **Counters:** `sysctl([CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0])`, parsing `RTM_IFINFO2` (`if_msghdr2`) for the 64-bit `ifi_ibytes` / `ifi_obytes`, plus `ifi_baudrate` and `IFF_UP|IFF_RUNNING`. One read costs microseconds and touches no network.
- **Rates** are deltas against the previous totals divided by the measured elapsed time, clamped to ≥ 0 (counter reset). A one-shot jump above `baudrate / 8 × elapsed × 1.5` (fixed 5 GB/s cap when the driver reports no link rate) is zeroed rather than plotted, as in Stats.
- **Physical vs virtual:** names starting `utun ipsec ppp tun tap gif stf wg` are virtual — they keep their own counters and rows and are never merged into the physical aggregate. `lo*` is loopback and excluded from both. Headline rates and since-boot totals cover physical interfaces only.
- **Totals:** since-boot totals are the sum of the monotonic physical counters (no accumulation work). Reset stores an offset (in memory; a reboot restarts the counters, and an interface that disappears can lower the sum, in which case the offset is rebased so the total never goes negative).
- **Baseline:** `start()` takes one baseline read (so totals show immediately); the first rate needs a second read one second later. `stop()` clears the ring buffer and forgets the previous counters so a reopen minutes later never produces one giant rate or a chart with a gap. The chart plots real samples only — an empty buffer renders an explicit empty track.

### 14.3 Expanded details (NET-003)

- **Wi-Fi:** CoreWLAN (`CWWiFiClient.shared().interface()`): SSID, channel, RSSI. **SSID needs Location authorization on modern macOS**, so Location is requested lazily on the *first expand* (never at launch; `NSLocationWhenInUseUsageDescription` in `Info.plist`), following the SCAN-006 Full Disk Access pattern: without the permission the row shows the interface name (plus channel/RSSI when CoreWLAN returns them) and a bordered grant button — the system prompt while undetermined, the `Privacy_LocationServices` pane once denied. It never blocks. The app never reads the device location.
- **Rates per interface:** the Wi-Fi row shows its own live down/up rate; other wired `en*` links that have carried traffic get a row with rates. **Tunnels:** virtual interfaces carrying traffic right now get rows with their own rates; tunnels that are up but idle (the system `utun*` ones) collapse into one muted `Idle tunnels: …` line. **Down interfaces:** one muted line (`Inactive: en1, en2 …`), never polled.
- **Connection rows:** Internet (one ICMP echo, below), Local IP (System Configuration `State:/Network/Global/IPv4` → primary interface address), DNS servers (`State:/Network/Global/DNS`). No public-IP row, ever.
- **ICMP:** one echo request to 1.1.1.1 over an unprivileged `SOCK_DGRAM`/`IPPROTO_ICMP` socket (no root, no helper, 2 s timeout). Exactly one per expand or Refresh; no periodic ping. This is the only network request the module makes (`NetworkModuleSurfaceTests` scans the module sources for any other network API).
- **Threading:** metadata read and echo run off-main (`Task.detached(priority: .utility)`) and are generation-guarded: collapse/close invalidates the generation, a cancelled expand never sends the echo, and a late result is never published.

### 14.4 Top processes (NET-004)

While — and only while — the Top processes disclosure is expanded, the Network tab is shown **and** the popover is open, `ProcessTrafficModel` runs `/usr/bin/nettop -P -L 1 -n -k <excluded columns>` (env `NSUnbufferedIO=YES`, 5 s timeout) every 4 s. Cancelling the loop (collapse, tab switch or close) terminates the process immediately. The CSV is parsed header-driven (`name.pid`, `bytes_in`, `bytes_out`, quoting honoured); rates are deltas between consecutive passes (first pass shows "Measuring…"), friendly names come from `NSRunningApplication`, rows are ranked by `max(down, up)` and truncated to 5. A missing/failing/timed-out nettop or unparsable output shows a single muted notice and is retried on the next interval silently (no logging). nettop is the only heavyweight piece of the module, which is why it sits in the most lazy corner.

### 14.5 Verification

Unit tests: `NetThroughputTests` (delta/clamp/cutoff/filter/totals/reset, no timer before `start()`), `NetworkSectionTests` (card mapping loaded/empty/reset, chart honesty, coordinator start-on-open/stop-on-close spy, expand/collapse/close spawn-and-terminate spies, one metadata read + one echo per expand/Refresh), `NetworkDetailsTests` (permission → row mapping, down-interface row, lazy Location, cancellation, network-API surface scan), `NettopTests` (parser fixtures, ranking, rates, failure path). SwiftUI's accessibility tree is not materialised without a live AX client, so — as in `RowAccessibilityLabelTests` — the label sources (`NetworkCardContent.accessibilitySummary`, `NetworkDisclosureContent`) are asserted instead of walking the view tree; the visual pass (light/dark; collapsed, expanded, Location-denied, empty-buffer) was rendered through `NSHostingView` to PNG.
