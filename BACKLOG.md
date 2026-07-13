# BACKLOG — justStats v1

Sources: `docs/prd.md`, `docs/techspec.md`, `docs/architecture-draft.md`. Scheduling: explicit `Depends on` (no `.ai-task` in this repo — `implement-a-single-task` uses backlog order + explicit deps per `AGENTS.md`).

Legend: `- [ ]` open · `- [x]` done · `- [~]` deferred.

## Phase 0 — Project initialization

- [x] INIT-001 Create Xcode app skeleton with module layout
Task Context: New AppKit-lifecycle macOS app target `justStats`, deployment target macOS 15, universal binary (arm64 + x86_64), `LSUIElement = true` (menu-bar only, no Dock icon). Folder layout per TECHSPEC §1: `App/` (shell), `Kit/` (shared helpers), `Modules/Disk/`. Add empty XCTest target.
Task DOD: Project builds clean from a fresh clone; app launches showing a placeholder status item; test target runs (0 tests OK).
Priority: P1
Size: M
Depends on:
Agent: auto
Verify: xcodebuild -scheme justStats build test

- [x] INIT-002 Repo hygiene: MIT license, README, .gitignore
Task Context: Add MIT `LICENSE`, Xcode-appropriate `.gitignore`, and README with: what the app does, macOS 15+ requirement, unsigned-app install instructions (Gatekeeper right-click → Open flow), build-from-source steps. PRD Goals 5, Risks (Gatekeeper friction).
Task DOD: All three files present; README install section covers the Gatekeeper flow explicitly.
Priority: P1
Size: S
Depends on:
Agent: auto
Verify: files exist; README renders correctly on GitHub

- [x] INIT-003 GitHub Actions CI: build + unit tests
Task Context: Workflow on push/PR to `main`: checkout, select Xcode, `xcodebuild build test` on macos runner. No release automation (TECHSPEC §6 keeps releases manual).
Task DOD: Workflow file committed; run passes on push.
Priority: P1
Size: S
Depends on: INIT-001
Agent: auto
Verify: green Actions run on push

## Phase 1 — Icon tier (always-on status)

- [x] ICON-001 Threshold model and color-state logic with unit tests
Task Context: Pure logic in `Kit`: threshold config from `UserDefaults` (`redThresholdBytes`/`redThresholdPercent`, `yellowThresholdBytes`/`yellowThresholdPercent`, `thresholdMode` absolute|percentage; defaults red <10 GB, yellow <20 GB per PRD FR1/FR10), mapping (freeBytes, totalBytes, config) → state enum green|yellow|red. TECHSPEC §2.
Task DOD: Logic covered by unit tests: both modes, boundary values, zero-free, percent rounding.
Priority: P1
Size: S
Depends on: INIT-001
Agent: auto
Verify: xcodebuild test — threshold tests pass

- [x] ICON-002 Boot-volume reader via statfs
Task Context: `Modules/Disk/IconController`: single `statfs("/")` read returning free/total bytes. No Spotlight, no enumeration — this is the cheap tier (TECHSPEC §3 tier 1). Must be callable off main thread.
Task DOD: Returns plausible values on a real machine; unit-testable via protocol seam (mockable reader).
Priority: P1
Size: S
Depends on: INIT-001
Agent: auto
Verify: xcodebuild test; manual sanity check against `df -h /`

- [x] ICON-003 Status item with colored icon, dark-mode and accessibility variants
Task Context: `NSStatusItem` with `.button`; non-template `NSImage` (template images can't carry real color — TECHSPEC §8). Render green/yellow/red variants with explicit light/dark + highlighted handling. Red state also changes glyph (e.g. exclamation badge) — color must not be the only signal (PRD FR1 correction). Set VoiceOver label via accessibility API, e.g. "Disk status: critical, 8 GB free".
Task DOD: Icon reflects state from ICON-001/002; readable in light/dark menu bar and when highlighted; VoiceOver announces status text.
Priority: P1
Size: M
Depends on: ICON-001, ICON-002
Agent: auto
Verify: manual — toggle appearance, force each state via lowered thresholds, VoiceOver check

- [x] ICON-004 Periodic icon refresh timer
Task Context: `DispatchSourceTimer`, fixed ~30s constant (not user-configurable — PRD non-goal), calls ICON-002 off main thread, updates icon on main. TECHSPEC §3 tier 1.
Task DOD: Icon updates within one tick after free space crosses a threshold; timer survives sleep/wake without duplicate firing.
Priority: P1
Size: S
Depends on: ICON-003
Agent: auto
Verify: manual — lower threshold in defaults, observe icon change ≤30s; Instruments: no main-thread statfs

- [x] ICON-005 Phase 1 cleanup and quality pass
Task Context: Dead-code sweep, confirm no main-thread blocking in icon tier, extend threshold tests for missed edge cases, extract shared helpers into `Kit` where duplicated.
Task DOD: No compiler warnings in phase files; CPU sampling shows idle activity only from the 30s tick.
Priority: P2
Size: S
Depends on: ICON-004
Agent: auto
Verify: xcodebuild test; Instruments time-profile 5 min idle

- [x] ADR-001 Promote realized architecture decisions to ADR records
Task Context: Per AGENTS.md ADR policy (promote at first implementation). Now realized: native AppKit shell + SwiftUI content, two-tier refresh model. Create `ADR/` records via adr-skill with context/alternatives from `docs/architecture-draft.md` §3.
Task DOD: Two ADR files exist with status Accepted; PRD/TECHSPEC ADR-CANDIDATE entries reference them.
Priority: P2
Size: S
Depends on: ICON-004
Agent: auto
Verify: ADR files lint against adr-skill checklist

## Phase 2 — Volume enumeration and popover

- [x] VOL-001 VolumeEnumerator: internal-volume fast path
Task Context: `Modules/Disk/VolumeEnumerator`: `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options: [.skipHiddenVolumes])` with resource keys for name, internal/removable flags; `DiskArbitration` (`DADiskCreateFromVolumePath`) for BSD name/metadata only — no event subscriptions (TECHSPEC §3, verified Stats pattern). Filter APFS service volumes (Preboot/Recovery/VM — PRD Assumptions). Volume model struct: name, total, free, used, kind (internal|external|network).
Task DOD: Internal volumes returned synchronously with correct sizes; service volumes absent; unit tests on classification/filtering via seam.
Priority: P1
Size: M
Depends on: INIT-001
Agent: auto
Verify: xcodebuild test; manual compare with Finder volume list

- [x] VOL-002 Async external/network enumeration with hung-mount isolation
Task Context: External/network volumes resolved on `DispatchQueue.global(qos: .utility)`, streamed per-volume via callback as each resolves (TECHSPEC §3 tier 2). A hung SMB `statfs` may delay only its own row — never the callback pipeline or internal results. Row-level timeout → "unavailable" placeholder.
Task DOD: Internal results delivered even when a network volume mock hangs; per-volume streaming works; no main-thread filesystem calls.
Priority: P1
Size: M
Depends on: VOL-001
Agent: auto
Verify: xcodebuild test with hung-reader mock; manual with real USB + network volume

- [x] VOL-003 Popover shell: NSPopover hosting SwiftUI content
Task Context: Wire status-item click to toggle a transient `NSPopover` containing `NSHostingView` (TECHSPEC §1 refinement: AppKit shell, SwiftUI content, thin bridge). Fixed width constant, dynamic height from content (Stats `recalculateHeight` precedent, TECHSPEC §8).
Task DOD: Click opens/closes popover; ESC and outside-click dismiss; height adapts to content; no retain cycles on repeated open/close.
Priority: P1
Size: M
Depends on: ICON-003
Agent: auto
Verify: manual open/close cycles; Instruments leaks check

- [x] VOL-004 Volume list SwiftUI view with streaming append
Task Context: One row per volume: name, total/used/free (formatted via `Kit` byte-formatter), usage bar. Internal rows render immediately on open; external/network rows append as VOL-002 streams them, with a loading placeholder per pending volume (PRD FR2–FR5).
Task DOD: Popover opens with internal rows instantly; external rows appear without UI stall; row data matches `df` output.
Priority: P1
Size: M
Depends on: VOL-002, VOL-003
Agent: auto
Verify: manual with USB drive attach; visual check against df -h

- [x] VOL-005 Sort by fullness and manual Refresh
Task Context: Sort toggle (most-full first, PRD FR9) applied client-side to the loaded list; "Refresh" button re-runs enumeration without closing the popover (PRD FR13, the user-requested explicit-button model).
Task DOD: Sort reorders rows correctly; Refresh re-enumerates and cancels in-flight prior work.
Priority: P2
Size: S
Depends on: VOL-004
Agent: auto
Verify: manual; unit test for sort comparator

- [x] VOL-006 Phase 2 cleanup and thread-safety audit
Task Context: Audit streaming append for data races (main-actor isolation on UI-facing state), release enumeration state on popover close, dedupe helpers into `Kit`.
Task DOD: Thread Sanitizer clean on open/refresh/close cycles; memory returns to baseline after close.
Priority: P2
Size: S
Depends on: VOL-005
Agent: auto
Verify: xcodebuild test -enableThreadSanitizer YES; Instruments allocations

## Phase 3 — Category breakdown and largest files (Spotlight)

- [x] SCAN-001 CategoryScanner: per-category Spotlight queries
Task Context: `Modules/Disk/CategoryScanner`: `NSMetadataQuery` per TECHSPEC §4 — Apps (`kMDItemContentType == com.apple.application-bundle`), Media (`kMDItemContentTypeTree` ∩ image/movie/audio), Other (user files not Apps/Media, scoped `/Users/*`). Scoped per volume, off main thread, results as aggregated logical sizes. Queries run only on demand (popover open / Refresh), never on a timer (NFR4).
Task DOD: Category sizes returned for the boot volume; queries cancellable; no main-thread execution.
Priority: P2
Size: M
Depends on: VOL-004
Agent: auto
Verify: xcodebuild test with query seam; manual sanity vs Finder storage view

- [x] SCAN-002 Residual System category math with unit tests
Task Context: `System = Total − Free − Apps − Media − Other`, clamped ≥ 0 (TECHSPEC §4). Pure function in `Kit`.
Task DOD: Unit tests cover clamp-to-zero, zero-total, categories-exceed-total cases.
Priority: P2
Size: S
Depends on: SCAN-001
Agent: auto
Verify: xcodebuild test

- [x] SCAN-003 Largest-files query (top N)
Task Context: Spotlight query sorted by `kMDItemFSSize` desc, limit via constant (default 15, PRD FR7 range 10–20), returning name/size/path model per volume. Same on-demand lifecycle as SCAN-001.
Task DOD: Returns correct top-N for a volume with known contents; results stream without blocking popover.
Priority: P2
Size: M
Depends on: SCAN-001
Agent: auto
Verify: xcodebuild test; manual spot-check sizes vs Finder Get Info

- [x] SCAN-004 Category breakdown bar UI
Task Context: Stacked horizontal bar per volume row (System/Apps/Media/Other/Free), system colors, labels/tooltips with sizes (PRD FR6; layout skeleton TECHSPEC §8). Values from SCAN-001/002.
Task DOD: Bar proportions match computed values; readable in light/dark; VoiceOver reads per-segment values.
Priority: P2
Size: M
Depends on: SCAN-002, VOL-004
Agent: auto
Verify: manual visual + VoiceOver check

- [x] SCAN-005 "Not indexed" degraded state
Task Context: Detect unusable Spotlight index per volume (empty/unavailable results consistent with `mdutil -i off`); show "Not indexed — category breakdown unavailable" in that row instead of misleading zeros (TECHSPEC §4). No raw-scan fallback (NFR4).
Task DOD: Volume with indexing disabled shows the notice; other volumes unaffected.
Priority: P2
Size: M
Depends on: SCAN-004
Agent: auto
Verify: manual — mdutil -i off on a test USB volume

- [x] SCAN-006 Lazy Full Disk Access notice
Task Context: When Spotlight results are incomplete in a permissions-shaped way, show inline notice "Grant Full Disk Access for complete data" with button opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` (TECHSPEC §7, lazy per user decision). Never prompt at first launch.
Task DOD: Without FDA: notice appears, deep link opens correct pane; after granting: notice gone on next Refresh.
Priority: P2
Size: M
Depends on: SCAN-003
Agent: auto
Verify: manual — revoke/grant FDA in System Settings

- [x] SCAN-007 Phase 3 cleanup: query lifecycle and memory
Task Context: Stop/release `NSMetadataQuery` instances on popover close; cancel in-flight queries on Refresh; confirm no query leaks across open/close cycles.
Task DOD: Instruments shows query objects released after close; no accumulating observers.
Priority: P2
Size: S
Depends on: SCAN-005, SCAN-006
Agent: auto
Verify: Instruments allocations/leaks over 20 open-close cycles

- [x] ADR-002 ADR record: Spotlight-based scanning
Task Context: Promote the Spotlight-vs-raw-walk ADR-CANDIDATE (PRD, TECHSPEC §4) to an ADR record now that it is realized.
Task DOD: ADR file exists, Accepted, cross-referenced from PRD/TECHSPEC.
Priority: P3
Size: S
Depends on: SCAN-005
Agent: auto
Verify: adr-skill checklist

## Phase 4 — File actions

- [x] ACT-001 Largest-files section UI with Reveal in Finder
Task Context: Section below volume rows scoped to the selected/relevant volume (TECHSPEC §8 layout point 3): top-N rows with name/size/path; Reveal via `NSWorkspace.activateFileViewerSelecting` (PRD FR7–FR8).
Task DOD: Rows render from SCAN-003 data; Reveal opens Finder with file selected.
Priority: P2
Size: M
Depends on: SCAN-003, VOL-004
Agent: auto
Verify: manual reveal on several files incl. paths with spaces/unicode

- [x] ACT-002 Move to Trash with inline confirmation
Task Context: Trash action per row: first click flips row into inline confirm state (not a modal — TECHSPEC §8), confirm calls `FileManager.trashItem(at:resultingItemURL:)` — never `removeItem` (PRD FR8, TECHSPEC §7). On success remove row and show freed space.
Task DOD: File lands in Trash and is restorable; cancel path works; error (e.g. locked file) surfaces inline without crash.
Priority: P2
Size: M
Depends on: ACT-001
Agent: auto
Verify: manual trash/restore cycle; unit test for confirm-state machine

- [x] ACT-003 Destructive-action safety review
Task Context: Audit: no code path reaches permanent delete; confirmation state is VoiceOver-announced and keyboard-operable; double-activation cannot bypass confirm.
Task DOD: Review notes committed to task report; issues fixed.
Priority: P2
Size: S
Depends on: ACT-002
Agent: auto
Verify: keyboard-only + VoiceOver manual pass on trash flow

## Phase 5 — Settings

- [x] SET-001 Settings window with threshold configuration
Task Context: Separate Settings window (SwiftUI): red/yellow thresholds each configurable as absolute GB or percentage (PRD FR10), persisted via plain `UserDefaults` keys from ICON-001 (no schema versioning — TECHSPEC §2). Changes apply to icon on next tick without restart.
Task DOD: Both modes editable with validation (yellow ≥ red sanity); icon reacts to changed thresholds.
Priority: P2
Size: M
Depends on: ICON-004
Agent: auto
Verify: manual threshold change → icon color flips; defaults survive relaunch

- [x] SET-002 Launch at Login via SMAppService
Task Context: Toggle in Settings calling `SMAppService.mainApp.register()`/`.unregister()`, state read from `.status` (TECHSPEC §5 — deliberately not Stats' legacy helper pattern).
Task DOD: Toggle reflects real registration state; app appears/disappears in System Settings Login Items.
Priority: P2
Size: S
Depends on: SET-001
Agent: auto
Verify: manual logout/login cycle with toggle on and off

- [x] SET-003 Settings affordance: popover gear and ⌘,
Task Context: Gear button top-right of popover opens Settings window; ⌘, works while popover/settings has focus (macos-app-design skill baseline). Single window instance (no duplicates).
Task DOD: Both entry points open the same window; repeated invocation focuses existing window.
Priority: P2
Size: S
Depends on: VOL-003, SET-001
Agent: auto
Verify: manual — gear click, ⌘,, repeat-open behavior

- [x] SET-004 Phase 5 cleanup: defaults and window lifecycle
Task Context: Centralize all `UserDefaults` keys in one `Kit` namespace; verify Settings window releases on close; remove any stray/dead keys.
Task DOD: Single source of truth for keys; no leaked window controllers.
Priority: P3
Size: S
Depends on: SET-003
Agent: auto
Verify: grep for scattered key literals; Instruments after close

## Phase 6 — Distribution and updates

- [x] UPD-001 Sparkle integration with self-managed EdDSA key
Task Context: Add Sparkle 2.x via SPM. Generate EdDSA key pair with Sparkle's `generate_keys`; embed public key (`SUPublicEDKey`) and feed URL (`SUFeedURL` → `https://raw.githubusercontent.com/<org>/justStats/main/appcast.xml`) in Info.plist. Private key stored outside repo (document location — keychain), never committed (TECHSPEC §6, architecture-draft §7). "Check for Updates" action in Settings.
Task DOD: Update check runs against a test appcast without errors; no private key material anywhere in repo or history.
Priority: P2
Size: M
Depends on: INIT-001
Agent: auto
Verify: manual update check against test appcast; git log -p search for key material

- [x] UPD-002 Appcast skeleton and release checklist
Task Context: Commit `appcast.xml` skeleton; write `docs/release-checklist.md`: `ditto` zip of .app, create GitHub Release with asset, add appcast entry with EdDSA signature, bump version. Manual process by design (TECHSPEC §6).
Task DOD: Checklist executable start-to-finish by the author; appcast validates against Sparkle format.
Priority: P2
Size: S
Depends on: UPD-001
Agent: auto
Verify: dry-run the checklist for a 0.0.x tag

- [x] UPD-003 Spike: Gatekeeper behavior on unnotarized Sparkle updates
Task Context: The unresolved risk from PRD/TECHSPEC §6: build two real versions, publish test appcast, run actual Sparkle upgrade on a machine that Gatekeeper-approved v1 — record whether the update relaunches without new Gatekeeper blocks. Document findings in TECHSPEC §6; if blocked, define fallback messaging (point users to manual download).
Task DOD: Findings written into TECHSPEC §6 with a clear go/no-go for Sparkle-based public releases.
Priority: P1
Size: M
Depends on: UPD-002
Agent: auto
Verify: documented real-machine test result, not simulation

- [x] UPD-004 Distribution security review
Task Context: Confirm: no secrets in repo history, appcast served over HTTPS only, Sparkle signature verification enabled (no `SUSkipSignatureValidation`-style bypasses), README warns app is unsigned.
Task DOD: Review notes committed; all checks pass.
Priority: P2
Size: S
Depends on: UPD-003
Agent: auto
Verify: checklist in task report with evidence

- [x] ADR-003 ADR records: Sparkle without notarization, SMAppService
Task Context: Promote remaining realized ADR-CANDIDATEs (Sparkle w/o Developer ID — PRD; SMAppService over Stats helper — TECHSPEC §5) to ADR records.
Task DOD: ADR files exist, Accepted, cross-referenced.
Priority: P3
Size: S
Depends on: UPD-001, SET-002
Agent: auto
Verify: adr-skill checklist

## Phase 7 — Release quality gate

- [x] QA-001 Accessibility pass
Task Context: Full pass per TECHSPEC §9 item 9 and macos-app-design baseline: VoiceOver labels on every interactive element (status item, rows, bars, Reveal/Trash/Refresh/gear), full keyboard navigation, reduced-transparency usability, color-not-sole-signal verified.
Task DOD: VoiceOver user can complete: check status → open popover → read volumes → trash a file. Keyboard-only likewise.
Priority: P2
Size: M
Depends on: ACT-002, SET-003
Agent: auto
Verify: manual VoiceOver + keyboard-only session, findings fixed

- [x] QA-002 Performance measurement and NFR pinning
Task Context: Measure idle CPU %, idle memory MB, cold-launch time; compare against a real exelban/stats install on the same machine (PRD NFR1–NFR3 open question). Record actual numbers into TECHSPEC §7 as the pinned ceilings.
Task DOD: TECHSPEC updated with measured numbers; justStats ≤ Stats disk-module footprint; launch perceived instant.
Priority: P2
Size: S
Depends on: ICON-004, VOL-005
Agent: auto
Verify: Activity Monitor / Instruments data attached to task report

- [x] QA-003 Manual QA checklist execution
Task Context: Execute TECHSPEC §9 checklist items 1–9 end-to-end on a real machine (cold launch, popover, USB attach, hung network volume, threshold color flip, reveal/trash, login item, FDA degraded state, VoiceOver). Fix blockers; file follow-ups for non-blockers.
Task DOD: All 9 items pass or have explicit follow-up tasks; results recorded.
Priority: P1
Size: M
Depends on: QA-001, UPD-003, SCAN-005, SCAN-006
Agent: auto
Verify: checklist results in task report

- [x] QA-004 Docs sync and CHANGELOG
Task Context: Create `CHANGELOG.md` for v1.0; update README (screenshots, features, install); sync TECHSPEC/PRD with any drift found during implementation (per AGENTS.md workflow step 5).
Task DOD: Docs match shipped behavior; CHANGELOG covers v1.0.
Priority: P2
Size: S
Depends on: QA-003
Agent: auto
Verify: doc review against running app

## Phase 8 — Manual verification & release debts

These make explicit the human-only tails behind earlier `[x]` tasks (UPD-001, UPD-003, QA-001, QA-003). The automatable code/harness/docs are done; the manual execution below is not, and was previously only implied. Do not treat v1 as released until REL-001..REL-003 and REL-005 pass.

- [x] REL-001 Link Sparkle SPM package + generate EdDSA signing key
Task Context: Converts UPD-001 from seam to real. In Xcode add the Sparkle 2.x SPM package to the `justStats` target, swap the factory from `NoopSoftwareUpdater` to the guarded `SparkleUpdaterController`, run Sparkle's `generate_keys`, and replace the placeholder `SUPublicEDKey` in `Info.plist`. Private key stays OUT of the repo (keychain/password manager). Steps: `justStats/Modules/Updates/README-sparkle-integration.md`.
Note (2026-07-05): a headless SPM integration was attempted and **rolled back** — hand-editing the filesystem-synchronized/hand-written `project.pbxproj` produced two fragilities (per-file non-deterministic `#if canImport(Sparkle)` → undefined `SparkleUpdaterController` symbols; and a malformed Embed Frameworks copy phase resolving `Debug/Sparkle` instead of `Sparkle.framework`). Tree restored to the green Noop baseline (251 tests). **Do this via Xcode's File → Add Package Dependencies… UI**, which configures link + Embed & Sign + module search paths correctly; hand-editing the pbxproj is not worth the thrash.
Task DOD: Real "Check for Updates…" runs against a test appcast without error; no private key material in repo/history; build stays green.
Priority: P1
Size: M
Depends on: UPD-001
Agent: manual
Verify: manual update check against a test appcast; `git log -p` / tree scan shows no key material

- [x] REL-002 Run Gatekeeper × Sparkle spike and record verdict
Task Context: The PENDING verdict in TECHSPEC §6. Execute `scripts/gatekeeper-spike.md` on a real Apple Silicon Mac (build v1, approve via Gatekeeper, publish v2 to a local test appcast, trigger the Sparkle upgrade, observe re-block via `xattr`/`spctl`). Replace the PENDING note in TECHSPEC §6 with the GO/NO-GO verdict + evidence; if NO-GO, wire the documented manual-download fallback copy.
Task DOD: TECHSPEC §6 carries a real GO/NO-GO verdict with machine/OS and xattr/spctl evidence.
Priority: P1
Size: M
Depends on: REL-001
Agent: manual
Verify: verdict + evidence recorded in TECHSPEC §6

- [x] REL-003 Execute manual QA checklist on real hardware
Task Context: The human-only tail of QA-003. Run `docs/manual-qa-checklist.md` items 1–9 (cold launch, popover, USB attach, hung network volume, threshold color flip, reveal/trash, login item logout/login, FDA degraded state) on a real machine. File follow-up tasks for any blocker.
Task DOD: All checklist items pass or have explicit follow-up tasks; results recorded.
Priority: P1
Size: M
Depends on: REL-001
Agent: manual
Verify: completed checklist with pass/fail recorded

- [~] REL-004 Manual VoiceOver + keyboard-only accessibility pass
Task Context: The human-only tail of QA-001 (code-side a11y is done; script in `docs/manual-accessibility-test.md`). DEFERRED per user 2026-07-05 — VoiceOver verification not needed for now. Re-open before a public/App Store-facing release.
Task DOD: VoiceOver user completes check-status → open popover → read volumes → trash a file; keyboard-only likewise.
Priority: P3
Size: S
Depends on: REL-003
Agent: manual
Verify: manual VoiceOver + keyboard-only session

- [x] DEV-001 Local build tooling: VS Code tasks + packaging script
Task Context: Make local build/test/run/package one-command. Add `.vscode/tasks.json` with xcodebuild tasks (build, test, run the built .app, clean) and `scripts/package.sh` producing `dist/justStats.zip` (Release build + ditto). Add `dist/` to `.gitignore`. Requested by user 2026-07-05 (the "dist + tasks.json" question — meaning local build convenience, not the task tracker).
Task DOD: `.vscode/tasks.json` build+test tasks run green; `scripts/package.sh` produces `dist/justStats.zip`; `dist/` gitignored.
Priority: P2
Size: S
Depends on:
Agent: auto
Verify: run each tasks.json task; run scripts/package.sh and confirm the zip

- [x] REL-005 Cut first GitHub Release (v1.0.0)
Task Context: Per `docs/release-checklist.md`: bump version, build Release `.app`, `ditto` to `.zip`, sign with `sign_update`, `gh release create` with the asset, add the signed `appcast.xml` `<item>`, push. Requires REL-001 (key) and a passing REL-002 verdict (or documented fallback).
Task DOD: A v1.0.0 GitHub Release exists with a `.zip` asset and a matching signed appcast entry served from `raw.githubusercontent.com`.
Priority: P2
Size: S
Depends on: REL-001, REL-002, REL-003
Agent: manual
Verify: release visible on GitHub; Sparkle sees it from the appcast

- [~] REL-006 Hardware/session-dependent manual QA (deferred from REL-003)
Task Context: The three `docs/manual-qa-checklist.md` items that couldn't run in the 2026-07-05 REL-003 session for lack of hardware/session access: item 3 (attach a real USB volume → row appears without freezing the UI), item 4 (a genuinely slow/dead SMB/AFP mount → popover doesn't freeze, stalled row shows unavailable), and the full item 7 confirmation (leave Launch at Login ON, real logout/login → justStats auto-launches). Their logic is already unit-tested (streaming append, hung-mount isolation, SMAppService register/unregister); this is live-hardware confirmation only. Run opportunistically when a USB device / network share / a convenient logout is available.
Task DOD: Checklist items 3, 4, and the item-7 logout/login confirmation run on real hardware with results recorded in the checklist run log.
Priority: P3
Size: S
Depends on: REL-003
Agent: manual
Verify: checklist run-log updated with the three items' live results

## Phase 9 — Post-v1 UX (from live-run feedback 2026-07-05)

Raised while running the built app. UX-001..004 are being delivered together; UX-005 follows (it shares Settings files with UX-004, so it runs after to avoid conflicts).

- [x] UX-001 Speed up largest-files scan with a cascading size-floor predicate
Task Context: The Spotlight largest-files query gathers ALL indexed files on the volume then sorts (no server-side top-N), so it is slow on full volumes. AND a size floor into the predicate (`kMDItemFSSize > floor`) and cascade floors (e.g. 100MB→10MB→1MB→0): highest floor first, drop only if fewer than the limit matched; floor-0 no-match still means `.unavailable` (not "empty"). Scoped to the volume, off-main, cancellable, released (NFR4). `SpotlightLargestFilesScanner` + `LargestFilesScanning` seam.
Task DOD: Largest-files list appears quickly on a real volume; "not indexed" vs "few large files" still distinguished; cascade logic unit-tested (mock, no real Spotlight).
Priority: P1
Size: M
Depends on:
Agent: auto
Verify: xcodebuild test; manual timing on a real volume

- [x] UX-002 In-memory TTL cache for scan results (largest files + categories)
Task Context: No cache today — each popover open re-scans from scratch. Add a `ScanResultCache` (keyed by volume URL) held by `VolumeListPopoverCoordinator` (outlives popover open/close), injected into `VolumeListViewModel`. **TTL = 5 min (300s), thrift model chosen 2026-07-05 from measured cost** (largest-files with UX-001 floor ≈ 0.3s, but the category pass is ≈ 3–6s of Spotlight daemon work — worth avoiding on frequent reopens under the "не грузить систему" constraint). On open: if a cache entry is FRESH (within TTL), show it and **do NOT re-scan** (zero Spotlight work); if stale/absent → scan normally. The explicit Refresh button (VOL-005) forces an on-demand re-scan regardless of cache. Never query Spotlight while the popover is closed — cache stores RESULTS only (NFR4). Inject the clock for testability.
Task DOD: Reopening within 5 min shows results instantly with NO new Spotlight query; entries older than 5 min re-scan; Refresh always re-scans; cache never triggers a query while closed; unit-tested (fresh vs stale via injected clock).
Priority: P1
Size: M
Depends on: UX-001
Agent: auto
Verify: xcodebuild test; manual reopen-is-instant check

- [x] UX-003 Progressive largest-files display
Task Context: Currently a single `.scanning → .available` transition (spinner until done). Add `.scanning(partial:)` — a running top-N delivered during the query's gathering phase (observe `NSMetadataQueryGatheringProgress`, maintain best-so-far), rendered in `LargestFilesSection` as rows-as-they-come with a "Scanning… N found" caption. Stale-generation partials dropped; UI updates on main; VoiceOver labels preserved.
Task DOD: Largest-files rows populate progressively instead of a blank spinner; final list correct; state transitions unit-tested; a11y intact.
Priority: P2
Size: M
Depends on: UX-002
Agent: auto
Verify: xcodebuild test; manual visual on a slow volume

- [x] UX-004 About section in Settings (version + GitHub link + license)
Task Context: No About/version/GitHub anywhere; version exists in the bundle (`MARKETING_VERSION 0.1.0`) but is not shown. Add an About group to `SettingsView`: app name + version from `CFBundleShortVersionString`/`CFBundleVersion` (behind a testable helper), an accessible GitHub link to `https://github.com/zanybaka/justStats` (opens in browser), and a "MIT" license line. Native/minimal per macos-app-design; dark/light + VoiceOver.
Task DOD: Settings shows version, a working GitHub link, and license; version-string helper unit-tested; no regression to existing settings.
Priority: P2
Size: S
Depends on:
Agent: auto
Verify: xcodebuild test; manual — link opens repo, version correct

- [x] UX-005 Quit button (кнопка выхода)
Task Context: A menu-bar (`LSUIElement`) app has no Dock/menu entry to quit — add an explicit "Quit justStats" control. Place it in the Settings About area (with UX-004) and/or the popover footer; wire to `NSApplication.shared.terminate(nil)`. Standard ⌘Q should also quit while the app is active. Keyboard/VoiceOver accessible; a menu-bar Quit is a destructive-ish action but standard — no confirmation needed.
Task DOD: A visible Quit control terminates the app; ⌘Q works; accessible. Shares `SettingsView`/popover with UX-004 — run after UX-004 to avoid file conflicts.
Priority: P2
Size: S
Depends on: UX-004
Agent: auto
Verify: xcodebuild test; manual — click Quit exits, ⌘Q exits

- [x] UX-006 De-flake SpotlightScannerLifecycleTests under load
Task Context: Found 2026-07-05: `SpotlightScannerLifecycleTests` (fully stubbed — `StubRunLoopExecutor`/`QueryRecorder`, no real Spotlight) passes 3/3 in isolation but its 20-cycle cross-queue delivery tests occasionally hit their `wait(for:, timeout: 30)` and time out during a FULL-suite run under heavy CPU load (concurrent builds saturated the machine). Not a product regression — the tip is green when not saturated — but a real CI flake risk. Make these tests deterministic under load: replace the 30s wall-clock waits with deterministic synchronization (drive the stub executor to completion rather than polling), and/or reduce cycle count, so delivery does not depend on scheduler latency. Keep the lifecycle coverage (every query started once + stopped) intact.
Task DOD: The lifecycle tests pass reliably even under artificial CPU load (e.g. run the full suite with a parallel `yes >/dev/null` load a few times, 0 flakes); no wall-clock-timeout-dependent assertions remain.
Priority: P2
Size: S
Depends on:
Agent: auto
Verify: xcodebuild test repeated under load; 0 flakes

## Phase 10 — Visual redesign (approved 2026-07-05 from mockup)

User feedback: the current UI is plain (flat 8px segmented bar + system ProgressView spinners). Approved direction: a Stats-inspired, dense, polished popover — see the mockup proposal. Appearance-ADAPTIVE (system materials/colors, correct in light AND dark), not hardcoded dark. Reuse SF Symbols. All three tasks edit the shared view layer → run sequentially (UX-007 → UX-008 → UX-009), not in parallel.

- [x] UX-007 Visual foundation: shared style + polished usage/category bar
Task Context: Create a small shared style (a DiskPalette/DiskMetrics: category colors mapped to SYSTEM/semantic colors — System=secondary gray, Apps=blue, Media=indigo, Other=orange, Free=quaternary track; bar height ~9pt, corner radius ~5pt; spacing/typography constants) plus reusable SwiftUI components: a `UsageBarView` (rounded, segmented, on a track, appearance-adaptive) replacing the flat CategoryBarView bar, and a `DiskGlyph` mapping volume kind→SF Symbol (internaldrive / externaldrive / externaldrive.connected / network). Refactor CategoryBarView to use UsageBarView; keep the accessibility summary + largest-remainder segment widths intact. New file(s) in Modules/Disk; edits to VolumeListView.swift CategoryBarView only.
Task DOD: New bar renders segmented + rounded, correct in light/dark; existing bar tests still green (a11y summary + width settlement preserved); no behavior change to data.
Priority: P2
Size: M
Depends on:
Agent: auto
Verify: xcodebuild test; manual visual light/dark

- [x] UX-008 Redesign volume rows and largest-files rows
Task Context: Restyle each volume row as a compact card (subtle quaternary fill, ~10pt radius, ~10–11pt padding) with: a DiskGlyph (UX-007) tinted by kind, the volume name (13pt medium), "X free of Y" (secondary), "% used" trailing, the UsageBarView, and a RED accent line ("running low") when the volume's free space is under the yellow threshold. Restyle the largest-files rows: an SF Symbol per file kind (zip/photo/film/folder/doc), name (truncating), size trailing, and reveal/trash as hover-revealed icon buttons. Replace the two `ProgressView()` spinners with the progressive "Scanning… N found" caption + best-so-far rows already modelled (UX-003). Edits VolumeListView.swift (rows) + LargestFilesSection.swift. Keep all a11y labels + the inline trash-confirm state.
Task DOD: Rows look like the approved mockup, light/dark correct; VoiceOver labels intact; trash-confirm still works; tests green.
Priority: P2
Size: M
Depends on: UX-007
Agent: auto
Verify: xcodebuild test; manual visual + VoiceOver

- [x] UX-009 Popover header and integrated footer
Task Context: Add a compact header row to the popover (title "justStats" + sort / refresh / settings-gear icon buttons, SF Symbols) and an integrated footer (version · GitHub link · Quit) — reuse the AboutSection/version helper + Quit action from UX-004/005 so Settings and the footer share one source. Tighten overall spacing/padding to the mockup density. Edits VolumeListView.swift (header/footer chrome) + reuse Settings/AboutInfo. Do not duplicate the version/quit logic.
Task DOD: Header controls work (sort/refresh/gear wired to existing actions), footer shows version + working GitHub link + Quit; light/dark correct; a11y labels; tests green.
Priority: P2
Size: M
Depends on: UX-008
Agent: auto
Verify: xcodebuild test; manual — header/footer actions, visual

## Phase 11 — Fixes from live-run feedback (2026-07-05, screenshots)

Running 0.3.0 surfaced a real correctness bug (sizes) plus an icon regression. Build the .zip after these land (build-on-every-change).

- [x] UX-010 Largest files: rank and show ON-DISK (allocated) size, not logical
Task Context: BUG. `SpotlightLargestFilesScanner` ranks + displays `kMDItemFSSize` (logical). Sparse files (e.g. `Docker.raw` — 345 GB logical but 3.25 GB on disk; VM `.bundle`s) show their huge logical size and sort to the top, which is wrong. Keep the `kMDItemFSSize > floor` cascade to gather CANDIDATES (a logical-size floor is a safe superset since allocated ≤ logical), but for each candidate read `URLResourceValues([.totalFileAllocatedSizeKey])` (matches Finder's "on disk"), then re-rank + display by that on-disk size. Small candidate set (~≤ a few hundred) → cheap. Fall back to logical if allocated is nil. Add a shared on-disk-size helper (reused by UX-011).
Task DOD: A sparse file shows its on-disk size (Docker.raw ≈ 3.25 GB, not 345 GB) and no longer dominates the list; ranking is by on-disk size; unit-tested with a mock (logical vs allocated).
Priority: P1
Size: M
Depends on:
Agent: auto
Verify: xcodebuild test; manual — Docker.raw shows ~3.25 GB

- [x] UX-011 Category breakdown: sum ON-DISK (allocated) size, not logical
Task Context: BUG. `SpotlightCategoryScanner` sums `kMDItemFSSize` (logical) per category, so sparse files inflate categories — e.g. `Docker.raw` (a `.raw`, which Spotlight types as `public.image`) inflated "Media" to ~215 GB though it uses 3.25 GB on disk. Sum the on-disk allocated size instead (reuse the UX-010 helper): enumerate each category's Spotlight result items and sum `.totalFileAllocatedSizeKey`. Runs off-main, cached (5-min TTL from UX-002), progressive-friendly. MEASURE the added cost (per-file stat over large sets, e.g. ~30k images) — if it regresses NFR meaningfully, document the tradeoff and consider a bounded approach, but correctness (not showing phantom 215 GB Media) is the goal. The System residual math then reflects real usage.
Task DOD: Category sizes reflect on-disk usage (Media no longer inflated by sparse VM/Docker images); residual System stays ≥0 and sums to Total; perf impact measured + acceptable under cache; unit-tested.
Priority: P1
Size: M
Depends on: UX-010
Agent: auto
Verify: xcodebuild test; manual — Media size sane vs Finder storage

- [x] UX-012 Restore the GitHub brand mark on the repo link
Task Context: Regression from the redesign (UX-009): the GitHub link now uses the SF Symbol `arrow.up.right.square` (a generic "external link square"), which reads worse than the actual GitHub mark it had before. Render the canonical GitHub logo as a tintable, appearance-adaptive SwiftUI Shape (from the known GitHub mark path) — no SF Symbol (none exists for GitHub) — and use it for BOTH the popover footer link and the Settings → About link (shared component, one source). Keep the accessible label "View justStats on GitHub".
Task DOD: The repo link shows a recognizable GitHub mark (not a square-with-arrow) in both places, tinted correctly in light/dark; a11y label intact; tests green.
Priority: P2
Size: S
Depends on:
Agent: auto
Verify: xcodebuild test; manual — GitHub mark visible in footer + About

- [ ] DOC-001 README: real screenshots + concise description; move dev detail to README.Dev.md
Task Context: README should show the app (current, post-fix screenshots) with a short, water-free description of what it does and how to install (unsigned Gatekeeper flow). Move build-from-source, architecture/technical detail, and the Sparkle/manual-release notes into a new `README.Dev.md`, linked from README. Screenshots go in `docs/images/` (captured from the fixed build — after UX-010/011/012). No fluff, no fabricated claims.
Task DOD: README is concise + has current screenshots + install; README.Dev.md holds the technical/dev content; links between them work.
Priority: P2
Size: S
Depends on: UX-010, UX-011, UX-012
Agent: auto
Verify: README renders on GitHub; screenshots present and current

## Phase 12 — Interaction polish (2026-07-05 feedback)

Running 0.3.1: the popover needs standard interaction affordances (dismissal, cursor, hover) and a way to hide always-fine files.

- [x] UX-013 Dismiss the popover on any outside click, including when Settings opens
Task Context: The transient `NSPopover` should close when the user clicks anywhere outside it — but it currently stays open in some cases, notably when opening the in-app Settings window from the gear (an in-app window is not treated as an "outside" dismissal). Ensure: (a) a click anywhere outside the popover closes it; (b) opening the Settings window (gear / ⌘,) closes the popover first (explicitly close it in the gear action / before/at Settings-window ordering front), and Settings taking focus doesn't leave an orphaned popover. Check `PopoverController` behavior mode and the Settings-open path in the coordinator. Keep the existing close-on-ESC / re-toggle behavior.
Task DOD: Clicking outside closes the popover; opening Settings closes the popover and shows the window; no orphaned popover; existing dismissal (ESC, re-click) still works.
Priority: P2
Size: S
Depends on:
Agent: auto
Verify: manual — outside click, open settings, ESC; unit test the controller state where feasible

- [x] UX-014 Pointing-hand cursor over clickable controls in the popover
Task Context: Clickable icons/controls in the popover (reveal, trash, hide, refresh, sort, gear, GitHub, quit, and any clickable row) don't change the cursor. Add a pointing-hand cursor on hover — on macOS 15 prefer `.pointerStyle(.link)` (SwiftUI) or `.onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }`. Apply consistently via a shared modifier so every interactive control uses it. Do together with UX-016 (same interactive surfaces).
Task DOD: Hovering any clickable control shows the pointing-hand cursor; no cursor stuck after leaving; consistent across the popover.
Priority: P2
Size: S
Depends on:
Agent: auto
Verify: manual — hover each control, cursor changes and resets

- [x] UX-015 "Hide" action for largest-files rows, remembered across sessions
Task Context: Some largest files are obviously fine and the user doesn't want to keep seeing them. Add a "Hide" control next to Reveal/Trash on each largest-file row that removes it from the list and REMEMBERS it (persist a hidden set — by file path, in `UserDefaults`, in a small `HiddenFilesStore` with a protocol seam). Hidden files are filtered out of the largest-files list on every scan. Provide a way back so the user isn't trapped: show a subtle "N hidden — show" affordance (or a Settings entry) to review/clear hidden entries. Use SF Symbol `eye.slash`. Preserve a11y (label "Hide <file>") and the inline trash-confirm flow.
Task DOD: Hide removes a row and persists; hidden files stay hidden across relaunch and re-scan; there is a discoverable way to unhide/clear; unit-tested (store + filter via seam, isolated UserDefaults).
Priority: P2
Size: M
Depends on: UX-014
Agent: auto
Verify: xcodebuild test; manual — hide a file, reopen/relaunch, it stays hidden; unhide works

- [x] UX-016 Hover states across interactive elements
Task Context: Interaction feedback is thin — e.g. largest-files rows and buttons don't highlight on hover. Add tasteful, appearance-adaptive hover states: a subtle row-background highlight on largest-files rows (and volume rows if it reads well), and hover feedback on the icon buttons (reveal/trash/hide/refresh/sort/gear/github/quit). Use `.onHover` state + a quaternary/secondary fill on hover; keep it subtle and light/dark-correct. Reveal the row's hover-only actions (reveal/trash/hide) on hover, as the mockup implied. Coordinate with UX-014 (cursor) — same elements.
Task DOD: Hovering rows/buttons gives clear, subtle feedback; hover-only actions appear on hover; light/dark correct; a11y unaffected; tests green.
Priority: P2
Size: M
Depends on: UX-015
Agent: auto
Verify: xcodebuild test; manual — hover rows and buttons

## Phase 13 — Bug fixes (2026-07-05, from running 0.3.2)

- [x] UX-017 Popover must close when clicking another app (Finder, other windows)
Task Context: BUG. UX-013 made the popover `.transient`, which dismisses on in-app outside clicks and ESC — but clicking into ANOTHER application (Finder, etc.) leaves the popover open. For a menu-bar (`LSUIElement`) app the clean signal is app deactivation: observe `NSApplication.didResignActiveNotification` in `PopoverController` and close the popover when the app resigns active. Keep `.transient` (in-app outside click + ESC + re-toggle) and the close-on-Settings behavior (UX-013). Remove the observer on deinit; no global-event-monitor crutch.
Task DOD: Clicking any other app/window closes the popover; ESC, in-app outside click, re-toggle, and Settings-open dismissal still work; no leaked observer/retain cycle.
Priority: P2
Size: S
Depends on:
Agent: auto
Verify: manual — open popover, click Finder → closes; unit-test the resign-active→close path via a seam where feasible

- [x] UX-018 Exclude Trash from the largest-files list
Task Context: BUG. The largest-files scan lists files inside Trash, which the user doesn't want to see (already discarded). Exclude Trash-located files from the largest-files results during candidate processing (where on-disk size is already resolved, UX-010). Resolve the real Trash location via the SYSTEM API — `FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: volumeURL, create: false)` — which returns the correct trash for that volume (home `~/.Trash` and each volume's `/.Trashes/<uid>`), then test containment against the resolved, standardized trash URL. Do NOT string-match `.Trash`/`.Trashes` path components (guessing is fragile and can false-positive on legit paths). Category breakdown is out of scope (Trash still uses real disk space; only the largest-files LIST hides it).
Task DOD: No Trash-located file appears in the largest-files list; Trash location comes from FileManager `.trashDirectory` (not hardcoded strings); non-Trash files unaffected; unit-tested (a candidate under the resolved trash URL is filtered) via the existing seam.
Priority: P2
Size: S
Depends on:
Agent: auto
Verify: xcodebuild test; manual — a large file in Trash does not appear

- [x] UX-019 Fix first-launch popover positioning reflow (no crutches)
Task Context: BUG. On the first launch, the first click on the status item draws the popover at the wrong place (flashes to the right), disappears, then re-renders in the correct spot. Cause: the SwiftUI content is hosted in an `NSHostingController` with `sizingOptions = [.preferredContentSize]`, so its size isn't known until after layout — the popover shows before the size is established, then resizes/repositions. Fix PROPERLY: establish the content size before `popover.show` (force the hosting view to lay out — `layoutSubtreeIfNeeded()` — and/or set `preferredContentSize`/`popover.contentSize` to the fixed width `PopoverLayout.contentWidth` with a laid-out height) so the first show is at the correct size and position. No `DispatchQueue.asyncAfter`/dispatch-to-next-runloop crutches.
Task DOD: First-ever popover open (fresh launch) appears at the correct position with no visible jump/flash; subsequent opens unaffected; positioning is deterministic (content sized before show).
Priority: P2
Size: M
Depends on:
Agent: auto
Verify: manual — fresh launch, first click opens cleanly with no jump

## Phase 14 — Branding & doc assets (2026-07-05, before public release)

The app ships with the generic default icon and the README uses placeholder
screenshots. Both should be real before the repo goes public / v1.0.0 is announced.

- [x] ASSET-001 App icon (disk-monitor motif)
Task Context: The app has no custom icon (no `.icns`, no `AppIcon` in the pbxproj — it shows the generic app icon in Finder / the About panel). Create a macOS app icon on a disk/storage-monitor theme fitting the app's identity (the colored status glyph / segmented usage bar), via the `macos-app-icon` skill: a 1024×1024 source, then `AppIcon.appiconset` (all sizes, HIG safe zone / squircle) + `.icns`, wired into the `justStats` target (`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, an `Assets.xcassets` in the synchronized `justStats/` group). Appearance-adaptive/tinted variants optional.
Task DOD: The built app shows the custom icon in Finder and the About panel; build stays green; icon renders at menu/Finder/Dock-preview sizes without mush.
Priority: P2
Size: M
Depends on:
Agent: auto
Verify: build; inspect `dist/justStats.app` icon in Finder Get Info

- [x] DOC-002 Real README + release screenshots (replace placeholders)
Task Context: `docs/images/popover.png` / `popover-dark.png` are generated placeholders. Capture real screenshots of the redesigned popover (light and dark) — ideally on a machine with a couple of volumes so the category bar + largest files show — at a clean size, and drop them into `docs/images/` (same filenames the README references). Human-captured (an agent can't screenshot the live menu-bar popover). Optionally add a shot to the GitHub Release notes.
Task DOD: `docs/images/popover.png` (+ dark) are real current screenshots; README renders them; placeholders gone.
Priority: P2
Size: S
Depends on: ASSET-001
Agent: manual
Verify: README on GitHub shows the real screenshots

## Phase 15 — Bug fixes (2026-07-12, from crash-report analysis)

- [ ] SCAN-008 Fix deinit deadlock in SpotlightLargestFilesScanner (dispatch_sync on own stateQueue)
Task Context: BUG. `SpotlightLargestFilesScanner.deinit` tears down synchronously via `stateQueue.sync` (`justStats/Modules/Disk/LargestFilesScanner.swift:513`). Four `stateQueue.async { [weak self] in guard let self … }` blocks (~lines 532, 558, 648, 683) hold a temporary strong reference while executing; if the owner releases the scanner during that window, the block's reference becomes the last one, so `deinit` runs ON `stateQueue` and its `stateQueue.sync` traps — libdispatch "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already owned by current thread" (EXC_BREAKPOINT/SIGTRAP). Evidence: 10 crash reports 2026-07-05 02:11–02:17 (v0.1.0, identical stack: closure #1 in `scan` → `_swift_release_dealloc` → `deinit` → `__DISPATCH_WAIT_FOR_QUEUE__`); the pattern is unchanged in 1.0.0. Repro direction: drop the last scanner reference (e.g. close the largest-files UI) while a scan block is in flight on `stateQueue`. Fix properly, no dispatch-later crutches — either (a) mark `stateQueue` via `DispatchQueue.setSpecific` and in `deinit` tear down inline when already on `stateQueue`, else `sync`; or (b) replace the queue-protected state (`current`/`generation`) with `OSAllocatedUnfairLock` so `deinit` takes the lock with no queue-identity hazard. `deinit` also calls `runLoopThread.stop()` — keep that safe if `deinit` ever runs on the run-loop thread.
Task DOD: `deinit` never dispatch_syncs onto a queue it is already running on; a regression unit test drives the release-from-stateQueue path via the existing seams (injectable `makeQuery`/`runLoopThread`) and does not trap; existing scanner tests stay green.
Priority: P2
Size: S
Depends on:
Agent: auto
Verify: xcodebuild test; regression test for deinit-on-stateQueue path passes

