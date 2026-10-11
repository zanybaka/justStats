## Phase 16 — Reclaimable space cleanup (2026-10-11, from manual cleanup session)

- [ ] CLEAN-001 Cleanup rule model, catalog and detection with unit tests
Task Context
Implement CleanupRule/CleanupCatalog/ReclaimableScanner per TECHSPEC §12.1. Initial rules: VS Code ShipIt, uv, npm, Homebrew, Docker, Xcode DerivedData (green); Hugging Face cache, app VM bundles (yellow, explain-only). Detection by fixed path or tool probe; size by allocated-size walk or tool report; evaluated lazily, off the main thread, via the TTL cache (UX-002). No UI, no actions.
Task DOD
Catalog is data in one file; scanner returns (rule, size, present) for items above the size floor; missing tool or path yields no row; unit tests cover detection, size floor, absent tool, symlink not followed; no main-thread I/O.
Source: owner
Priority: P2
Size: M
Depends on: ADR-004
Agent: auto
Verify: xcodebuild test
