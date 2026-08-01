# BACKLOG — justStats v1

<!-- Generated index (backlog-store). Do not edit by hand: task blocks live in backlog/tasks/<TASK-ID>.md; edit those, then run `python .ai-task/scripts/backlog-store.py regenerate`. Drift fails `backlog-store.py check` and the test suite. -->

Sources: `docs/prd.md`, `docs/techspec.md`, `docs/architecture-draft.md`. Scheduling: explicit `Depends on` (no `.ai-task` in this repo — `implement-a-single-task` uses backlog order + explicit deps per `AGENTS.md`).

Legend: `- [ ]` open · `- [x]` done · `- [~]` deferred.

## Phase 0 — Project initialization

- [x] [INIT-001](backlog/tasks/INIT-001.md) Create Xcode app skeleton with module layout
- [x] [INIT-002](backlog/tasks/INIT-002.md) Repo hygiene: MIT license, README, .gitignore
- [x] [INIT-003](backlog/tasks/INIT-003.md) GitHub Actions CI: build + unit tests

## Phase 1 — Icon tier (always-on status)

- [x] [ADR-001](backlog/tasks/ADR-001.md) Promote realized architecture decisions to ADR records
- [x] [ICON-001](backlog/tasks/ICON-001.md) Threshold model and color-state logic with unit tests
- [x] [ICON-002](backlog/tasks/ICON-002.md) Boot-volume reader via statfs
- [x] [ICON-003](backlog/tasks/ICON-003.md) Status item with colored icon, dark-mode and accessibility variants
- [x] [ICON-004](backlog/tasks/ICON-004.md) Periodic icon refresh timer
- [x] [ICON-005](backlog/tasks/ICON-005.md) Phase 1 cleanup and quality pass

## Phase 2 — Volume enumeration and popover

- [x] [VOL-001](backlog/tasks/VOL-001.md) VolumeEnumerator: internal-volume fast path
- [x] [VOL-002](backlog/tasks/VOL-002.md) Async external/network enumeration with hung-mount isolation
- [x] [VOL-003](backlog/tasks/VOL-003.md) Popover shell: NSPopover hosting SwiftUI content
- [x] [VOL-004](backlog/tasks/VOL-004.md) Volume list SwiftUI view with streaming append
- [x] [VOL-005](backlog/tasks/VOL-005.md) Sort by fullness and manual Refresh
- [x] [VOL-006](backlog/tasks/VOL-006.md) Phase 2 cleanup and thread-safety audit

## Phase 3 — Category breakdown and largest files (Spotlight)

- [x] [ADR-002](backlog/tasks/ADR-002.md) ADR record: Spotlight-based scanning
- [x] [SCAN-001](backlog/tasks/SCAN-001.md) CategoryScanner: per-category Spotlight queries
- [x] [SCAN-002](backlog/tasks/SCAN-002.md) Residual System category math with unit tests
- [x] [SCAN-003](backlog/tasks/SCAN-003.md) Largest-files query (top N)
- [x] [SCAN-004](backlog/tasks/SCAN-004.md) Category breakdown bar UI
- [x] [SCAN-005](backlog/tasks/SCAN-005.md) "Not indexed" degraded state
- [x] [SCAN-006](backlog/tasks/SCAN-006.md) Lazy Full Disk Access notice
- [x] [SCAN-007](backlog/tasks/SCAN-007.md) Phase 3 cleanup: query lifecycle and memory

## Phase 4 — File actions

- [x] [ACT-001](backlog/tasks/ACT-001.md) Largest-files section UI with Reveal in Finder
- [x] [ACT-002](backlog/tasks/ACT-002.md) Move to Trash with inline confirmation
- [x] [ACT-003](backlog/tasks/ACT-003.md) Destructive-action safety review

## Phase 5 — Settings

- [x] [SET-001](backlog/tasks/SET-001.md) Settings window with threshold configuration
- [x] [SET-002](backlog/tasks/SET-002.md) Launch at Login via SMAppService
- [x] [SET-003](backlog/tasks/SET-003.md) Settings affordance: popover gear and ⌘,
- [x] [SET-004](backlog/tasks/SET-004.md) Phase 5 cleanup: defaults and window lifecycle

## Phase 6 — Distribution and updates

- [x] [ADR-003](backlog/tasks/ADR-003.md) ADR records: Sparkle without notarization, SMAppService
- [x] [UPD-001](backlog/tasks/UPD-001.md) Sparkle integration with self-managed EdDSA key
- [x] [UPD-002](backlog/tasks/UPD-002.md) Appcast skeleton and release checklist
- [x] [UPD-003](backlog/tasks/UPD-003.md) Spike: Gatekeeper behavior on unnotarized Sparkle updates
- [x] [UPD-004](backlog/tasks/UPD-004.md) Distribution security review

## Phase 7 — Release quality gate

- [x] [QA-001](backlog/tasks/QA-001.md) Accessibility pass
- [x] [QA-002](backlog/tasks/QA-002.md) Performance measurement and NFR pinning
- [x] [QA-003](backlog/tasks/QA-003.md) Manual QA checklist execution
- [x] [QA-004](backlog/tasks/QA-004.md) Docs sync and CHANGELOG

## Phase 8 — Manual verification & release debts

These make explicit the human-only tails behind earlier `[x]` tasks (UPD-001, UPD-003, QA-001, QA-003). The automatable code/harness/docs are done; the manual execution below is not, and was previously only implied. Do not treat v1 as released until REL-001..REL-003 and REL-005 pass.

- [x] [DEV-001](backlog/tasks/DEV-001.md) Local build tooling: VS Code tasks + packaging script
- [x] [REL-001](backlog/tasks/REL-001.md) Link Sparkle SPM package + generate EdDSA signing key
- [x] [REL-002](backlog/tasks/REL-002.md) Run Gatekeeper × Sparkle spike and record verdict
- [x] [REL-003](backlog/tasks/REL-003.md) Execute manual QA checklist on real hardware
- [~] [REL-004](backlog/tasks/REL-004.md) Manual VoiceOver + keyboard-only accessibility pass
- [x] [REL-005](backlog/tasks/REL-005.md) Cut first GitHub Release (v1.0.0)
- [~] [REL-006](backlog/tasks/REL-006.md) Hardware/session-dependent manual QA (deferred from REL-003)

## Phase 9 — Post-v1 UX (from live-run feedback 2026-07-05)

Raised while running the built app. UX-001..004 are being delivered together; UX-005 follows (it shares Settings files with UX-004, so it runs after to avoid conflicts).

- [x] [UX-001](backlog/tasks/UX-001.md) Speed up largest-files scan with a cascading size-floor predicate
- [x] [UX-002](backlog/tasks/UX-002.md) In-memory TTL cache for scan results (largest files + categories)
- [x] [UX-003](backlog/tasks/UX-003.md) Progressive largest-files display
- [x] [UX-004](backlog/tasks/UX-004.md) About section in Settings (version + GitHub link + license)
- [x] [UX-005](backlog/tasks/UX-005.md) Quit button (кнопка выхода)
- [x] [UX-006](backlog/tasks/UX-006.md) De-flake SpotlightScannerLifecycleTests under load

## Phase 10 — Visual redesign (approved 2026-07-05 from mockup)

User feedback: the current UI is plain (flat 8px segmented bar + system ProgressView spinners). Approved direction: a Stats-inspired, dense, polished popover — see the mockup proposal. Appearance-ADAPTIVE (system materials/colors, correct in light AND dark), not hardcoded dark. Reuse SF Symbols. All three tasks edit the shared view layer → run sequentially (UX-007 → UX-008 → UX-009), not in parallel.

- [x] [UX-007](backlog/tasks/UX-007.md) Visual foundation: shared style + polished usage/category bar
- [x] [UX-008](backlog/tasks/UX-008.md) Redesign volume rows and largest-files rows
- [x] [UX-009](backlog/tasks/UX-009.md) Popover header and integrated footer

## Phase 11 — Fixes from live-run feedback (2026-07-05, screenshots)

Running 0.3.0 surfaced a real correctness bug (sizes) plus an icon regression. Build the .zip after these land (build-on-every-change).

- [ ] [DOC-001](backlog/tasks/DOC-001.md) README: real screenshots + concise description; move dev detail to README.Dev.md
- [x] [UX-010](backlog/tasks/UX-010.md) Largest files: rank and show ON-DISK (allocated) size, not logical
- [x] [UX-011](backlog/tasks/UX-011.md) Category breakdown: sum ON-DISK (allocated) size, not logical
- [x] [UX-012](backlog/tasks/UX-012.md) Restore the GitHub brand mark on the repo link

## Phase 12 — Interaction polish (2026-07-05 feedback)

Running 0.3.1: the popover needs standard interaction affordances (dismissal, cursor, hover) and a way to hide always-fine files.

- [x] [UX-013](backlog/tasks/UX-013.md) Dismiss the popover on any outside click, including when Settings opens
- [x] [UX-014](backlog/tasks/UX-014.md) Pointing-hand cursor over clickable controls in the popover
- [x] [UX-015](backlog/tasks/UX-015.md) "Hide" action for largest-files rows, remembered across sessions
- [x] [UX-016](backlog/tasks/UX-016.md) Hover states across interactive elements

## Phase 13 — Bug fixes (2026-07-05, from running 0.3.2)

- [x] [UX-017](backlog/tasks/UX-017.md) Popover must close when clicking another app (Finder, other windows)
- [x] [UX-018](backlog/tasks/UX-018.md) Exclude Trash from the largest-files list
- [x] [UX-019](backlog/tasks/UX-019.md) Fix first-launch popover positioning reflow (no crutches)

## Phase 14 — Branding & doc assets (2026-07-05, before public release)

The app ships with the generic default icon and the README uses placeholder
screenshots. Both should be real before the repo goes public / v1.0.0 is announced.

- [x] [ASSET-001](backlog/tasks/ASSET-001.md) App icon (disk-monitor motif)
- [x] [DOC-002](backlog/tasks/DOC-002.md) Real README + release screenshots (replace placeholders)

## Phase 15 — Bug fixes (2026-07-12, from crash-report analysis)

- [ ] [SCAN-008](backlog/tasks/SCAN-008.md) Fix deinit deadlock in SpotlightLargestFilesScanner (dispatch_sync on own stateQueue)
