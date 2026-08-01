## Phase 1 — Icon tier (always-on status)

- [x] ICON-003 Status item with colored icon, dark-mode and accessibility variants
Task Context: `NSStatusItem` with `.button`; non-template `NSImage` (template images can't carry real color — TECHSPEC §8). Render green/yellow/red variants with explicit light/dark + highlighted handling. Red state also changes glyph (e.g. exclamation badge) — color must not be the only signal (PRD FR1 correction). Set VoiceOver label via accessibility API, e.g. "Disk status: critical, 8 GB free".
Task DOD: Icon reflects state from ICON-001/002; readable in light/dark menu bar and when highlighted; VoiceOver announces status text.
Priority: P1
Size: M
Depends on: ICON-001, ICON-002
Agent: auto
Verify: manual — toggle appearance, force each state via lowered thresholds, VoiceOver check
