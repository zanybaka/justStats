## Phase 16 — Reclaimable space cleanup (2026-10-11, from manual cleanup session)

- [ ] CLEAN-002 Reclaimable space section in the popover (read-only)
Task Context
SwiftUI section under largest files per FR14: rows with name, size, tier badge, Reveal in Finder for path-based rules. Shown only when items exist. No Clean action yet. Adaptive light/dark per UX-007 style, hover and cursor per UX-014/016.
Task DOD
Section appears with real data, hidden when empty; VoiceOver labels name+size+tier; Reveal works for path rules; no layout reflow regression (UX-019).
Source: owner
Priority: P2
Size: M
Depends on: CLEAN-001
Agent: auto
Verify: xcodebuild test; manual — popover shows ShipIt/uv rows on this Mac
