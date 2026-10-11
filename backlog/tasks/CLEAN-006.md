## Phase 16 — Reclaimable space cleanup (2026-10-11, from manual cleanup session)

- [ ] CLEAN-006 Destructive-action safety review for cleanup
Task Context
Audit CLEAN-003/004 like ACT-003: every delete and command path, allowlist exhaustiveness, path-guard bypass attempts (symlink, .., case-insensitive volume), confirmation bypass by double activation, accessibility of the confirm flow, behavior when the tool or app is running.
Risk: Executes external programs and permanent deletes; must pass review before release.
Task DOD
Review notes in the task report; found issues fixed; no code path deletes outside a rule-declared path or runs a command outside the enum.
Source: owner
Priority: P1
Size: S
Depends on: CLEAN-003,CLEAN-004
Agent: auto
Verify: keyboard-only + VoiceOver manual pass; xcodebuild test
