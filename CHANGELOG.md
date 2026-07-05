# Changelog

All notable changes to justStats are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-07-05

First public release — a native macOS menu bar disk monitor.

### Added

- **Menu bar status icon** colored by the boot volume's free space (green / yellow /
  red), with a distinct shape at the critical state and a VoiceOver label, refreshed
  by a lightweight ~30s timer (single `statfs`, ~0% idle CPU, ~10 MB).
- **Popover volume list** — internal disks render instantly; external and network
  volumes stream in without blocking, and a hung network mount can't freeze the UI.
- **Category breakdown** (System / Apps / Media / Other / Free) and a **largest files**
  list, both via Spotlight, sized by actual on-disk (allocated) bytes so sparse files
  (disk images, VM bundles) aren't overstated; results cached 5 minutes.
- **File actions** — Reveal in Finder, Move to Trash (inline confirm, recoverable),
  and Hide (remembered) on largest-file rows; sort by fullness; on-demand Refresh.
- **Settings** — warning/critical thresholds (GB or %), Launch at Login (`SMAppService`),
  About with version + GitHub link, Quit; opens with ⌘,.
- **Auto-update** via Sparkle (EdDSA-signed) — verified to install silently with no
  Gatekeeper re-block (see TECHSPEC §6); install by dragging to Applications in Finder.
- Native AppKit shell + SwiftUI content, appearance-adaptive (light/dark), accessible.

The detailed development history of the pre-1.0 milestones follows below.

## [0.3.1] - Unreleased

Correctness fixes (Phase 11), from feedback running the redesigned build.

### Fixed

- **Sizes now reflect actual disk usage** — the largest-files list and the category
  breakdown used a file's *logical* size, so sparse files (a `Docker.raw` disk image
  reads 345 GB logical but only 3.25 GB on disk; VM bundles similarly) appeared
  enormous and, because a `.raw` is Spotlight-typed as an image, inflated "Media" to
  hundreds of phantom gigabytes. Both now use the on-disk (allocated) size that
  Finder reports.
- **GitHub link** shows the actual GitHub mark again instead of a generic
  external-link square.

## [0.3.0] - Unreleased

Visual redesign (Phase 10), from feedback that the UI looked plain.

### Changed

- **Redesigned popover** — a denser, Stats-inspired look: appearance-adaptive
  segmented usage bars (rounded, on a track), volume rows as cards with a
  kind-tinted disk icon (internal / external / network) and a "running low" flag
  when free space is under the yellow threshold, largest-files rows with per-file
  SF Symbols and hover-revealed reveal/trash actions, a header (sort · refresh ·
  settings) and an integrated footer (version · GitHub · Quit). Fully adaptive to
  light and dark; the low-space cue is never color-only.

## [0.2.0] - Unreleased

Post-v1 UX pass (Phase 9), from feedback running the built app.

### Added

- **Settings → About** — the app version, a link to the GitHub repository, the MIT
  license line, and a **Quit justStats** control (a menu-bar app has no Dock or
  app-menu quit; ⌘Q also works via a Quit menu item).

### Changed

- **Largest-files scan is much faster** — a cascading size-floor Spotlight
  predicate (`kMDItemFSSize > floor`, 100 MB → 10 MB → 1 MB → 0) replaces gathering
  every indexed file, cutting a full-volume scan from ~17 s to ~0.3 s on a 500 GB
  disk, and removing the transient memory spike from holding hundreds of thousands
  of results.
- **Scan results are cached** — an in-memory cache (5-minute TTL) shows the last
  breakdown and largest-files list instantly on reopen and skips the Spotlight
  scan entirely while fresh; the Refresh button forces a re-scan. Volume free/used
  figures still refresh on every open.
- **Largest files appear progressively** — a running best-so-far list with a
  "Scanning… N found" caption replaces the blank spinner.

### Fixed

- De-flaked the Spotlight scanner lifecycle tests so they no longer time out under
  heavy CPU load (deterministic drain instead of a wall-clock wait).

## [0.1.0] - Unreleased

First feature-complete build: a native macOS menu bar app that monitors disk health.

### Added

- **Menu bar status icon** — colored disk-status icon reflecting the boot volume
  at a glance (green / yellow / red), with a shape change in addition to color so
  the state is distinguishable without relying on color alone, and a descriptive
  VoiceOver label.
- **Popover volume list** — click the icon to open an `NSPopover` with a SwiftUI
  volume list. Internal volumes appear immediately (streaming, internal-first);
  external and network volumes are enumerated asynchronously and appended without
  blocking the UI.
- **Per-volume category breakdown** — each volume shows a bar breakdown across
  System / Apps / Media / Other / Free.
- **Largest files** — per volume, a list of the largest files with quick actions:
  **Reveal in Finder** and **Move to Trash** (with an inline confirmation step
  before deleting).
- **Sort and refresh** — volumes are sorted by fullness; a **Refresh** action
  re-runs the scan on demand.
- **Settings window** — configurable warning/critical thresholds (by GB and by
  percentage) and **Launch at Login** (via `SMAppService`). Reachable via ⌘,.
- **Accessibility** — VoiceOver labels throughout and full keyboard navigation.
- **Auto-update seam** — a `SoftwareUpdating` protocol abstraction with a guarded
  `SparkleUpdaterController` and a manual integration guide. The shipped build
  wires the `NoopSoftwareUpdater` (Sparkle is not linked yet — see Limitations).

### Known limitations

- **Unsigned and unnotarized.** There is no Apple Developer ID backing this build,
  so Gatekeeper requires a right-click → **Open** on first launch. See the README
  install steps.
- **Auto-update is not active.** The Sparkle package is not yet linked into the
  build; the app ships the no-op updater. Enabling live updates requires adding the
  Sparkle Swift package — see
  `justStats/Modules/Updates/README-sparkle-integration.md`.
- **Performance numbers are self-measured.** NFR measurements were taken against
  justStats alone. A side-by-side comparison with exelban/stats was **not** run
  (Stats is not installed on the build machine) and remains a manual follow-up.

[1.0.0]: https://github.com/zanybaka/justStats/releases
