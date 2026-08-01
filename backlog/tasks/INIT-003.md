## Phase 0 — Project initialization

- [x] INIT-003 GitHub Actions CI: build + unit tests
Task Context: Workflow on push/PR to `main`: checkout, select Xcode, `xcodebuild build test` on macos runner. No release automation (TECHSPEC §6 keeps releases manual).
Task DOD: Workflow file committed; run passes on push.
Priority: P1
Size: S
Depends on: INIT-001
Agent: auto
Verify: green Actions run on push
