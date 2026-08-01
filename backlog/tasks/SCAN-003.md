## Phase 3 — Category breakdown and largest files (Spotlight)

- [x] SCAN-003 Largest-files query (top N)
Task Context: Spotlight query sorted by `kMDItemFSSize` desc, limit via constant (default 15, PRD FR7 range 10–20), returning name/size/path model per volume. Same on-demand lifecycle as SCAN-001.
Task DOD: Returns correct top-N for a volume with known contents; results stream without blocking popover.
Priority: P2
Size: M
Depends on: SCAN-001
Agent: auto
Verify: xcodebuild test; manual spot-check sizes vs Finder Get Info
