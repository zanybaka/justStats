## Phase 16 — Reclaimable space cleanup (2026-10-11, from manual cleanup session)

- [ ] CLEAN-003 Clean action: delete known directory with inline confirmation
Task Context
FR15 directory-delete path per TECHSPEC §12.2: Clean button, inline confirmation naming path and size, removeItem on a URL equal to the rule's declared path, symlinks not followed, must be inside home and not home itself, guardrail refuses while the guarded process runs, bytes freed shown. Same confirmation pattern as ACT-002.
Task DOD
Clean frees the directory and updates the row; refused paths are unit-tested (outside home, home itself, symlink, mismatch with rule); guardrail test with a fake process list; confirmation is keyboard/VoiceOver operable and cannot be bypassed by double activation.
Source: owner
Priority: P2
Size: M
Depends on: CLEAN-002,ADR-004
Agent: auto
Verify: xcodebuild test; manual — clean ShipIt leftovers
