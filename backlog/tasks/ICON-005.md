## Phase 1 — Icon tier (always-on status)

- [x] ICON-005 Phase 1 cleanup and quality pass
Task Context: Dead-code sweep, confirm no main-thread blocking in icon tier, extend threshold tests for missed edge cases, extract shared helpers into `Kit` where duplicated.
Task DOD: No compiler warnings in phase files; CPU sampling shows idle activity only from the 30s tick.
Priority: P2
Size: S
Depends on: ICON-004
Agent: auto
Verify: xcodebuild test; Instruments time-profile 5 min idle
