## Phase 1 — Icon tier (always-on status)

- [x] ICON-001 Threshold model and color-state logic with unit tests
Task Context: Pure logic in `Kit`: threshold config from `UserDefaults` (`redThresholdBytes`/`redThresholdPercent`, `yellowThresholdBytes`/`yellowThresholdPercent`, `thresholdMode` absolute|percentage; defaults red <10 GB, yellow <20 GB per PRD FR1/FR10), mapping (freeBytes, totalBytes, config) → state enum green|yellow|red. TECHSPEC §2.
Task DOD: Logic covered by unit tests: both modes, boundary values, zero-free, percent rounding.
Priority: P1
Size: S
Depends on: INIT-001
Agent: auto
Verify: xcodebuild test — threshold tests pass
