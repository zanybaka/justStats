## Phase 3 — Category breakdown and largest files (Spotlight)

- [x] SCAN-006 Lazy Full Disk Access notice
Task Context: When Spotlight results are incomplete in a permissions-shaped way, show inline notice "Grant Full Disk Access for complete data" with button opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` (TECHSPEC §7, lazy per user decision). Never prompt at first launch.
Task DOD: Without FDA: notice appears, deep link opens correct pane; after granting: notice gone on next Refresh.
Priority: P2
Size: M
Depends on: SCAN-003
Agent: auto
Verify: manual — revoke/grant FDA in System Settings
