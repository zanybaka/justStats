## Phase 15 — Bug fixes (2026-07-12, from crash-report analysis)

- [x] SCAN-009 Same deinit trap as SCAN-008 in SpotlightCategoryScanner
Progress: 2026-11-22, DONE. SpotlightCategoryScanner state (generation, current) moved behind OSAllocatedUnfairLock; stateQueue kept for ordering only; deinit takes the lock and no longer dispatches onto stateQueue (same fix as SCAN-008). Regression test SpotlightScannerLifecycleTests.testCategoryScannerDeinitRunningInsideStateQueueBlockDoesNotTrap pauses inside makeQuery in the scan block, drops the last external reference, lets the block finish so deinit runs on the stateQueue thread; verified it crashes on the old code and passes on the fix. No TECHSPEC change (it does not describe scanner teardown).
Task Context: BUG, same class as SCAN-008 (found while fixing it). `SpotlightCategoryScanner.deinit` tears down via `stateQueue.sync` (`justStats/Modules/Disk/SpotlightCategoryScanner.swift:117`), and its `stateQueue.async { [weak self] in guard let self … }` blocks (~lines 129, 143, 229) hold a temporary strong reference while executing. If the owner releases the scanner while such a block is in flight, `deinit` runs ON the stateQueue thread and its `stateQueue.sync` traps — libdispatch "dispatch_sync called on queue already owned by current thread". Repro direction: release the category scanner while a scan/follow-up block is executing on its state queue (e.g. popover teardown racing a category scan). Fix the same way SCAN-008 was fixed in `SpotlightLargestFilesScanner`: move `generation`/`current` behind `OSAllocatedUnfairLock`, keep `stateQueue` for ordering only, `deinit` takes the lock from any thread. Mirror the SCAN-008 regression test (pause inside an injectable seam while the block runs, drop the last external reference, let the block finish).
Task DOD: `deinit` contains no dispatch onto `stateQueue`; a regression test drives the release-from-stateQueue path via the existing seams and does not trap; existing category scanner tests stay green.
Priority: P2
Size: S
Depends on: SCAN-008
Agent: auto
Verify: xcodebuild test; regression test for deinit-on-stateQueue path passes
