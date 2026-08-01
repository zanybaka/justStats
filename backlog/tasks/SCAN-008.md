## Phase 15 — Bug fixes (2026-07-12, from crash-report analysis)

- [ ] SCAN-008 Fix deinit deadlock in SpotlightLargestFilesScanner (dispatch_sync on own stateQueue)
Task Context: BUG. `SpotlightLargestFilesScanner.deinit` tears down synchronously via `stateQueue.sync` (`justStats/Modules/Disk/LargestFilesScanner.swift:513`). Four `stateQueue.async { [weak self] in guard let self … }` blocks (~lines 532, 558, 648, 683) hold a temporary strong reference while executing; if the owner releases the scanner during that window, the block's reference becomes the last one, so `deinit` runs ON `stateQueue` and its `stateQueue.sync` traps — libdispatch "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already owned by current thread" (EXC_BREAKPOINT/SIGTRAP). Evidence: 10 crash reports 2026-07-05 02:11–02:17 (v0.1.0, identical stack: closure #1 in `scan` → `_swift_release_dealloc` → `deinit` → `__DISPATCH_WAIT_FOR_QUEUE__`); the pattern is unchanged in 1.0.0. Repro direction: drop the last scanner reference (e.g. close the largest-files UI) while a scan block is in flight on `stateQueue`. Fix properly, no dispatch-later crutches — either (a) mark `stateQueue` via `DispatchQueue.setSpecific` and in `deinit` tear down inline when already on `stateQueue`, else `sync`; or (b) replace the queue-protected state (`current`/`generation`) with `OSAllocatedUnfairLock` so `deinit` takes the lock with no queue-identity hazard. `deinit` also calls `runLoopThread.stop()` — keep that safe if `deinit` ever runs on the run-loop thread.
Task DOD: `deinit` never dispatch_syncs onto a queue it is already running on; a regression unit test drives the release-from-stateQueue path via the existing seams (injectable `makeQuery`/`runLoopThread`) and does not trap; existing scanner tests stay green.
Priority: P2
Size: S
Depends on:
Agent: auto
Verify: xcodebuild test; regression test for deinit-on-stateQueue path passes
