## Phase 3 — Category breakdown and largest files (Spotlight)

- [x] SCAN-007 Phase 3 cleanup: query lifecycle and memory
Task Context: Stop/release `NSMetadataQuery` instances on popover close; cancel in-flight queries on Refresh; confirm no query leaks across open/close cycles.
Task DOD: Instruments shows query objects released after close; no accumulating observers.
Priority: P2
Size: S
Depends on: SCAN-005, SCAN-006
Agent: auto
Verify: Instruments allocations/leaks over 20 open-close cycles
