## Phase 1 — Icon tier (always-on status)

- [x] ICON-004 Periodic icon refresh timer
Task Context: `DispatchSourceTimer`, fixed ~30s constant (not user-configurable — PRD non-goal), calls ICON-002 off main thread, updates icon on main. TECHSPEC §3 tier 1.
Task DOD: Icon updates within one tick after free space crosses a threshold; timer survives sleep/wake without duplicate firing.
Priority: P1
Size: S
Depends on: ICON-003
Agent: auto
Verify: manual — lower threshold in defaults, observe icon change ≤30s; Instruments: no main-thread statfs
