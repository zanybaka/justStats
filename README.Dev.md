# justStats — developer notes

Technical detail kept out of the [README](README.md).

## Build from source

Requires Xcode 26 or later.

```sh
git clone https://github.com/zanybaka/justStats.git
cd justStats
xcodebuild -project justStats.xcodeproj -scheme justStats -destination 'platform=macOS' build
```

Or open `justStats.xcodeproj` in Xcode and run. VS Code build/test/run tasks are in
`.vscode/tasks.json`.

## Tests

```sh
xcodebuild -project justStats.xcodeproj -scheme justStats -destination 'platform=macOS' \
  build test CODE_SIGNING_ALLOWED=NO
```

Unit tests only (logic, thresholds, scanners via protocol seams, view-model state,
cache). No real Spotlight or filesystem in tests. CI runs the same command on every
push (`.github/workflows/ci.yml`). Manual QA and accessibility checklists live in
[`docs/manual-qa-checklist.md`](docs/manual-qa-checklist.md) and
[`docs/manual-accessibility-test.md`](docs/manual-accessibility-test.md).

## Architecture

AppKit shell (`NSStatusItem` + `NSPopover`) hosting SwiftUI content. One disk module
today; the layout leaves room for RAM/network modules later.

- **Icon tier** — a ~30 s timer does a single `statfs` on the boot volume for the
  icon color. That's the only always-on work (≈0.0% idle CPU).
- **Popover tier** — everything else is computed lazily when the popover opens (plus a
  manual Refresh), never on a timer. Internal volumes resolve synchronously; external
  and network volumes stream in off the main thread so a hung mount can't freeze the UI.
- **Category breakdown & largest files** use Spotlight (`NSMetadataQuery`), not a
  recursive walk. A cascading `kMDItemFSSize > floor` predicate keeps the largest-files
  query fast; sizes are then resolved to **on-disk (allocated)** bytes so sparse files
  (disk images, VM bundles) aren't overstated. Results are cached in memory for 5 minutes.
- No telemetry. Nothing leaves the machine.

Design docs: [`docs/prd.md`](docs/prd.md), [`docs/techspec.md`](docs/techspec.md),
[`docs/architecture-draft.md`](docs/architecture-draft.md), and the decision records in
[`ADR/`](ADR/).

## Repository layout

```
justStats/
  App/            AppKit lifecycle, status item, popover host
  Kit/            shared helpers (thresholds, byte formatting, layout)
  Modules/
    Disk/         enumeration, Spotlight scanners, cache, views
    Settings/     settings window, About section
    Updates/      SoftwareUpdating seam (see auto-update below)
justStatsTests/   XCTest unit tests
docs/             PRD, techspec, checklists, images
ADR/              architecture decision records
scripts/          package.sh (build the .zip), gatekeeper-spike.md
```

## Auto-update (Sparkle)

Sparkle 2.9.4 is linked and embedded (REL-001), so the app uses the real
`SparkleUpdaterController` and verifies EdDSA signatures at runtime. The signing key is
generated and its public half is in `Info.plist`; the private key lives only in the login
keychain. Details — key generation, backup, import/restore, and how the seam works — are in
[`justStats/Modules/Updates/README-sparkle-integration.md`](justStats/Modules/Updates/README-sparkle-integration.md).
Auto-update goes live once a signed `appcast.xml` is published (the first release, REL-005).

Whether a Sparkle-delivered update re-triggers Gatekeeper on an unsigned app is
**unverified** — the reproducible spike procedure is in
[`scripts/gatekeeper-spike.md`](scripts/gatekeeper-spike.md).

## Packaging a release

```sh
./scripts/package.sh   # Release build → dist/justStats.zip (unsigned)
```

The full manual release flow (version bump, EdDSA signature, GitHub Release, appcast)
is in [`docs/release-checklist.md`](docs/release-checklist.md).

## Status

The app is functionally complete and tested. Signing/notarization, the Gatekeeper ×
Sparkle spike, and the first tagged GitHub release remain manual — tracked in
[`BACKLOG.md`](BACKLOG.md).
