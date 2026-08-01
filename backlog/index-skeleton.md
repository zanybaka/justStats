# BACKLOG — justStats v1

Sources: `docs/prd.md`, `docs/techspec.md`, `docs/architecture-draft.md`. Scheduling: explicit `Depends on` (no `.ai-task` in this repo — `implement-a-single-task` uses backlog order + explicit deps per `AGENTS.md`).

Legend: `- [ ]` open · `- [x]` done · `- [~]` deferred.

## Phase 0 — Project initialization

## Phase 1 — Icon tier (always-on status)

## Phase 2 — Volume enumeration and popover

## Phase 3 — Category breakdown and largest files (Spotlight)

## Phase 4 — File actions

## Phase 5 — Settings

## Phase 6 — Distribution and updates

## Phase 7 — Release quality gate

## Phase 8 — Manual verification & release debts

These make explicit the human-only tails behind earlier `[x]` tasks (UPD-001, UPD-003, QA-001, QA-003). The automatable code/harness/docs are done; the manual execution below is not, and was previously only implied. Do not treat v1 as released until REL-001..REL-003 and REL-005 pass.

## Phase 9 — Post-v1 UX (from live-run feedback 2026-07-05)

Raised while running the built app. UX-001..004 are being delivered together; UX-005 follows (it shares Settings files with UX-004, so it runs after to avoid conflicts).

## Phase 10 — Visual redesign (approved 2026-07-05 from mockup)

User feedback: the current UI is plain (flat 8px segmented bar + system ProgressView spinners). Approved direction: a Stats-inspired, dense, polished popover — see the mockup proposal. Appearance-ADAPTIVE (system materials/colors, correct in light AND dark), not hardcoded dark. Reuse SF Symbols. All three tasks edit the shared view layer → run sequentially (UX-007 → UX-008 → UX-009), not in parallel.

## Phase 11 — Fixes from live-run feedback (2026-07-05, screenshots)

Running 0.3.0 surfaced a real correctness bug (sizes) plus an icon regression. Build the .zip after these land (build-on-every-change).

## Phase 12 — Interaction polish (2026-07-05 feedback)

Running 0.3.1: the popover needs standard interaction affordances (dismissal, cursor, hover) and a way to hide always-fine files.

## Phase 13 — Bug fixes (2026-07-05, from running 0.3.2)

## Phase 14 — Branding & doc assets (2026-07-05, before public release)

The app ships with the generic default icon and the README uses placeholder
screenshots. Both should be real before the repo goes public / v1.0.0 is announced.

## Phase 15 — Bug fixes (2026-07-12, from crash-report analysis)
