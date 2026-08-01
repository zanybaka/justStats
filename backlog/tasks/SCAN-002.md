## Phase 3 — Category breakdown and largest files (Spotlight)

- [x] SCAN-002 Residual System category math with unit tests
Task Context: `System = Total − Free − Apps − Media − Other`, clamped ≥ 0 (TECHSPEC §4). Pure function in `Kit`.
Task DOD: Unit tests cover clamp-to-zero, zero-total, categories-exceed-total cases.
Priority: P2
Size: S
Depends on: SCAN-001
Agent: auto
Verify: xcodebuild test
