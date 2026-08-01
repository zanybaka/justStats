## Phase 3 — Category breakdown and largest files (Spotlight)

- [x] SCAN-001 CategoryScanner: per-category Spotlight queries
Task Context: `Modules/Disk/CategoryScanner`: `NSMetadataQuery` per TECHSPEC §4 — Apps (`kMDItemContentType == com.apple.application-bundle`), Media (`kMDItemContentTypeTree` ∩ image/movie/audio), Other (user files not Apps/Media, scoped `/Users/*`). Scoped per volume, off main thread, results as aggregated logical sizes. Queries run only on demand (popover open / Refresh), never on a timer (NFR4).
Task DOD: Category sizes returned for the boot volume; queries cancellable; no main-thread execution.
Priority: P2
Size: M
Depends on: VOL-004
Agent: auto
Verify: xcodebuild test with query seam; manual sanity vs Finder storage view
