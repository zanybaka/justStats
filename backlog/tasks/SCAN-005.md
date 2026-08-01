## Phase 3 — Category breakdown and largest files (Spotlight)

- [x] SCAN-005 "Not indexed" degraded state
Task Context: Detect unusable Spotlight index per volume (empty/unavailable results consistent with `mdutil -i off`); show "Not indexed — category breakdown unavailable" in that row instead of misleading zeros (TECHSPEC §4). No raw-scan fallback (NFR4).
Task DOD: Volume with indexing disabled shows the notice; other volumes unaffected.
Priority: P2
Size: M
Depends on: SCAN-004
Agent: auto
Verify: manual — mdutil -i off on a test USB volume
