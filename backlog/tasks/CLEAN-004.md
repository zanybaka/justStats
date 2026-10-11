## Phase 16 — Reclaimable space cleanup (2026-10-11, from manual cleanup session)

- [ ] CLEAN-004 Clean action: allowlisted external commands (docker, uv, npm, brew)
Task Context
FR15 command path: AllowedCommand enum with fixed argv, no shell, timeout, stdout/stderr tail shown on failure, tool presence probed before the row is offered, Docker requires a running daemon (probe docker info). Confirmation shows the exact command. Freed bytes computed before/after.
Task DOD
Only enum commands can run; argv contains no user data; timeout kills the process; missing/stopped tool yields no Clean button; tests use an injected Process runner; manual run of uv cache prune frees space.
Source: owner
Priority: P2
Size: M
Depends on: CLEAN-003
Agent: auto
Verify: xcodebuild test; manual — uv cache prune from the app
