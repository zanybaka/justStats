## Phase 1 — Icon tier (always-on status)

- [x] ICON-002 Boot-volume reader via statfs
Task Context: `Modules/Disk/IconController`: single `statfs("/")` read returning free/total bytes. No Spotlight, no enumeration — this is the cheap tier (TECHSPEC §3 tier 1). Must be callable off main thread.
Task DOD: Returns plausible values on a real machine; unit-testable via protocol seam (mockable reader).
Priority: P1
Size: S
Depends on: INIT-001
Agent: auto
Verify: xcodebuild test; manual sanity check against `df -h /`
