# PRD — justStats (macOS menu bar disk monitor)

Status: v1 build-complete (Phases 0-6 shipped; Phase 7 release QA in progress). Last updated: 2026-07-05.

## Problem Statement

Checking free disk space today requires switching context — opening Finder ("Об этом Mac"), Дисковую утилиту, or Информацию о системе. The user wants disk status (total / used / free, per volume) available in one click from the menu bar, without ever leaving the current app.

Reference product: [diskbar.app](https://diskbar.app) (menu bar disk monitor for macOS).

## Target Users

- Primary: the author (vaspo), for daily personal use across their own Mac(s) — mixed Apple Silicon / Intel where feasible.
- Secondary: GitHub open-source consumers who clone/build the app themselves. They are technical enough to accept an unsigned/unnotarized app (Gatekeeper "right-click → Open" friction) since there is no Apple Developer Program membership backing this project.

## Goals (v1)

1. One-click, always-available menu bar access to disk status — no context switch.
2. Menu bar icon reflects system (boot) volume health at a glance via color (green/yellow/red), without opening the menu.
3. Opening the menu shows full detail (name, total, used, free) for every visible volume, with internal disks appearing instantly and external/network volumes appended without blocking the UI.
4. Help the user understand *what* is consuming space (category breakdown) and act on it (largest files, quick cleanup) — not just show a passive total, matching the core value proposition of diskbar.app.
5. Ship as a free, MIT-licensed, native macOS app distributed via GitHub Releases.

## Non-Goals (v1)

- RAM monitoring (planned v2).
- Network monitoring (planned v2).
- Whole-volume actions: eject, format, rename, encrypt, etc. — only file-level actions (reveal, trash) are in scope, see Functional Requirements.
- S.M.A.R.T./disk health diagnostics.
- Historical usage graphs or trend tracking over time (only current-state category breakdown, not a timeline).
- Low-space push notifications/alerts (only the passive icon color signal).
- Mac App Store distribution, sandboxing, or Apple notarization (no Developer Program membership available).
- Localization beyond a single UI language (assumption: English; see Assumptions).
- User-configurable refresh interval (fixed default in v1; see Open Questions).

## Scope Boundary

**In scope for v1:**
- Physical/built-in (internal) disks and volumes — fetched and rendered first, with minimal latency.
- External (USB/Thunderbolt), network (SMB/AFP/NAS), and other mounted volumes — appended to the same list asynchronously; must never block or delay the internal-disk view.
- Menu bar status icon, color-coded from the **system/boot volume's** free space only.
- Per-volume category breakdown of used space (System / Apps / Media / Other / Free), shown as a visual bar — diskbar.app's signature "what's eating my space" feature.
- A "largest files" list per volume (top N), with **Reveal in Finder** and **Move to Trash** actions directly from the dropdown.
- Ability to sort the volume list by fullness (most-full first).
- A Settings/Preferences window to configure the yellow/red thresholds, selectable as either an absolute size (GB) or a percentage of total capacity.
- "Launch at Login" toggle.
- Sparkle-based auto-update (self-signed EdDSA key, no Apple notarization required).

**Explicitly out of scope for v1:** see Non-Goals above.

## Functional Requirements

| # | Requirement |
|---|---|
| FR1 | Menu bar status item shows an icon color-coded by the system/boot volume's free space: red if free space < configured red threshold (default 10 GB absolute), yellow if < configured yellow threshold (default 20 GB absolute), green otherwise. Color is never the only signal (accessibility correction, see TECHSPEC §8): the icon also changes shape/glyph at the critical (red) state, and carries a VoiceOver accessibility label describing the actual status in words. |
| FR2 | Clicking the status item opens a dropdown/popover listing all detected volumes. |
| FR3 | Internal (built-in) volumes render first, with no perceptible delay after click. |
| FR4 | External/network/other volumes are enumerated asynchronously and appended to the list as they resolve, without blocking or delaying the internal-disk rows already shown. |
| FR5 | Each volume row displays: name, total capacity, used space, free space. |
| FR6 | Each volume shows a category breakdown of used space (System / Apps / Media / Other / Free) as a stacked visual bar. |
| FR7 | Each volume exposes a "largest files" list (top N, e.g. 10–20), showing file name, size, and path. |
| FR8 | Each largest-file entry supports **Reveal in Finder** and **Move to Trash**, actioned directly from the dropdown. Move to Trash requires an inline confirmation before executing (destructive action guard). |
| FR9 | The volume list can be sorted by fullness (most-full first). No whole-volume actions (eject, format, rename) are supported in v1. |
| FR10 | A Settings window exposes red/yellow thresholds, each configurable as absolute GB or percentage of total capacity. |
| FR11 | A "Launch at Login" toggle is available in Settings. |
| FR12 | The app checks for and can install updates via Sparkle, using a self-signed update feed (no Apple Developer ID/notarization dependency). |
| FR13 | Icon color (FR1) is refreshed by a lightweight periodic background timer (single cheap `statfs` call on the boot volume only). All other data (full volume list, category breakdown, largest files) is computed on demand when the popover opens, plus via an explicit in-popover "Refresh" button — not via continuous background polling. See TECHSPEC for the full rationale. |

## ADR-Candidate Decisions

- **ADR-CANDIDATE: Native Swift/AppKit+SwiftUI app instead of a cross-platform framework (Electron/Tauri/Flutter).**
  Rationale: user explicitly prioritized low system footprint ("не нагружать систему") and tight menu-bar integration (`NSStatusItem`); native gives instant startup and minimal idle CPU/memory.
  Alternatives considered: Electron (fastest to build, but heavy memory/CPU footprint — conflicts with the core constraint); Tauri (lighter, but immature for native macOS menu-bar patterns and adds a Rust↔Swift boundary); Flutter desktop (limited/awkward `NSStatusItem`-style menu bar support).
  Promoted to ADR: `ADR/001-native-appkit-shell-swiftui-content.md` (Accepted).

- **ADR-CANDIDATE: Ship Sparkle-based auto-update without Apple notarization/Developer ID.**
  Rationale: user has no Apple Developer Program membership but still wants low-friction updates; Sparkle supports a self-managed EdDSA signing key independent of Apple's notarization pipeline.
  Alternatives considered: manual-download-only updates (simplest, no key management, but higher update friction for every release); Mac App Store distribution (would require sandboxing, review process, and a paid Developer account — rejected given constraints and MIT/open-source intent).
  Promoted to ADR: `ADR/004-sparkle-without-notarization.md` (Accepted).

- **ADR-CANDIDATE: Volume enumeration split into a fast synchronous path (internal disks) and an async, non-blocking path (external/network/other).**
  Rationale: network-mounted volumes can hang on `statfs`-style calls (e.g., stale SMB mounts); this must not block the UI or the internal-disk list. This boundary also sets the pattern future v2 work (RAM/network stats) should follow — same "fast local + async extended" data-collection shape.
  Alternatives considered: single synchronous enumeration pass for all volumes (simpler, but violates the non-blocking requirement and risks UI freezes on flaky network mounts).

- **ADR-CANDIDATE: Category breakdown and "largest files" computed via Spotlight metadata queries (`NSMetadataQuery`/`mdfind`), not a raw recursive filesystem walk.**
  Rationale: a full recursive walk of an internal SSD (let alone an external/network volume) to categorize and rank files is slow and CPU/IO-heavy, directly conflicting with the "don't load the system" constraint and the "internal disks must render instantly" requirement (FR3). Spotlight's pre-built index answers both category-by-kind and largest-file queries near-instantly with negligible extra load.
  Trade-off accepted: results depend on Spotlight indexing state — volumes with indexing disabled (common for some external/network drives) or paths excluded from Spotlight (e.g., via `mdutil -i off`, `.metadata_never_index`) will show as partial/unavailable rather than fully accurate; the UI must communicate a degraded/"not indexed" state rather than silently showing wrong numbers or blocking to force a raw scan.
  Alternatives considered: raw recursive directory walk (accurate and always available, but slow, high I/O, and violates the non-blocking/low-load constraints — especially bad on network volumes); hybrid background indexer built into the app (accurate and independent of Spotlight, but a large engineering investment disproportionate to v1 scope).
  Promoted to ADR: `ADR/003-spotlight-based-scanning.md` (Accepted).

## Non-Functional Requirements (baseline, all v1 work)

These apply to every feature above, not just disk enumeration — added explicitly because "не нагружать систему" was recurring feedback throughout this PRD, and both reference combines (Stats, iStat Menus) treat this as a first-class constraint, not an afterthought.

| # | Requirement |
|---|---|
| NFR1 | **Idle CPU usage** must stay at or below the ~1% idle bar publicly reported by exelban/stats for a single active module — justStats ships only one module (disk) in v1, so it must not exceed what Stats spends on disk alone. Exact number to be measured/pinned at techspec stage. |
| NFR2 | **Idle memory footprint** must be minimized — no numeric target fixed yet (see Open Questions), but the app must stay leaner than a full multi-module combine like Stats/iStat Menus, since v1 monitors only disks. |
| NFR3 | **Cold launch time** (icon appears and is interactive in the menu bar) must be near-instant — perceived as instant by the user, no visible delay or placeholder state before the icon renders. |
| NFR4 | Category-breakdown and largest-files computation (Spotlight-based, see ADR below) must never regress NFR1–NFR3; if Spotlight is unavailable/unindexed, the app must degrade gracefully (show "not indexed") rather than fall back to an expensive raw scan that violates these budgets. |

## Prior Art & Reuse

Both reference products are general system-monitoring "combines" (CPU/GPU/RAM/disk/network/sensors/battery/Bluetooth), not disk-focused tools — confirming the suspicion that raised this question:

- **[iStat Menus](https://bjango.com/mac/istatmenus/)** — closed-source, commercial ($14.99). Nothing is reusable at the code level. Its main differentiators (historical graphs, weather, notifications) are already explicit v1 non-goals here, so there is little to borrow beyond high-level UX inspiration already captured (color-coded status, compact popover).
- **[Stats (exelban/stats)](https://github.com/exelban/stats)** — MIT-licensed, open source Swift, ~40k GitHub stars. Genuinely reusable:
  - Its **`LaunchAtLogin` module** is a small, self-contained implementation of exactly FR11 — safe to adapt directly under MIT terms (with attribution), instead of reimplementing `SMAppService` boilerplate from scratch.
  - Its **`Kit` + `Modules/*` architecture** (a shared kit of extensions/helpers/widget scaffolding, with each stat — CPU, RAM, Disk, Net, etc. — as an independent module) is a good structural reference for justStats' own v1→v2 roadmap (disk now, RAM/network later): adopting a similar module boundary now avoids a rework when v2 adds new modules.
  - Its published performance bar (**<1% idle CPU**; project's own notes flag Sensors/Bluetooth as the "expensive" modules) confirms that a lean, single-purpose module (disk-only, our v1) should cost meaningfully less than their full combine — used as the basis for NFR1 above.
  - Its **`Modules/Disk`** implementation is capacity/used/free + notifications/widget only — it does **not** do category breakdown or largest-files/cleanup, so justStats' diskbar-inspired features (FR6–FR9) remain differentiated even against this reuse.

- **ADR-CANDIDATE: Mirror exelban/stats' `Kit` + per-stat `Modules` architecture pattern; use `SMAppService` directly for launch-at-login instead of reusing Stats' `LaunchAtLogin` module.**
  Rationale: mirroring the modular architecture (one module per stat type) sets up a clean seam for the already-committed v2 roadmap (RAM, network) without an architecture rework. However, inspection of Stats' actual `LaunchAtLogin` code (see TECHSPEC) showed it is a separate helper-executable pattern built for compatibility with macOS versions older than our Sequoia-15+ baseline. Since we don't carry that constraint, the modern one-call `SMAppService.mainApp.register()` API (macOS 13+) is simpler and needs no extra target — superseding the earlier plan to copy Stats' helper code.
  Alternatives considered: copy Stats' helper-executable `LaunchAtLogin` pattern as originally planned (unnecessary complexity given our narrower OS support); design a bespoke architecture unrelated to Stats' module boundaries (fully independent, but no proven precedent and higher risk of a v2 rework).
  Promoted to ADR (launch-at-login decision): `ADR/005-smappservice-launch-at-login.md` (Accepted).

## Constraints

- Platform baseline: macOS 15 (Sequoia)+. Broader OS/CPU-architecture support (older macOS, Intel) is desirable but must be dropped first if it adds meaningful complexity or hurts performance — Sequoia+ is the only hard requirement.
- No Apple Developer Program membership: app ships unsigned and unnotarized; Gatekeeper friction on first launch is accepted.
- License: MIT, distributed via GitHub.
- Background refresh and volume enumeration must not noticeably load the system (CPU/battery) — concrete budget not yet pinned down (see Open Questions).
- External/network volume enumeration must never block rendering of internal-disk data.
- All Non-Functional Requirements above are binding constraints, not aspirational goals.

## Assumptions

- UI language: English only for v1 (no localization requested; open-source audience is technical/English-comfortable).
- System/service APFS containers not meaningful to an end user (Preboot, Recovery, VM, hidden Data volume internals) are filtered out; only user-facing mounted volumes are shown. Internal boot volume itself is always shown and drives icon color.
- Visual design (a polished, high-quality UX) is deferred to implementation/design pass — expected direction: per-row usage bar + color coding, consistent with the diskbar.app reference, refined during build rather than specified exhaustively here.
- Default thresholds: red < 10 GB free, yellow < 20 GB free, both on the system/boot volume, both user-overridable (absolute GB or %) via Settings.
- No telemetry/analytics is added — this is a privacy-first personal/OSS utility; success is judged qualitatively by the author, not via instrumented events (explicit deviation from the standard measurement-plan bar, see below).
- Distribution artifact: a `.zip` or `.dmg` attached to GitHub Releases (exact packaging left to techspec).

## Risks

- **Gatekeeper friction on unsigned builds** may deter non-technical GitHub users from installing at all. Mitigation: clear README install instructions; consider notarization later if a paid Developer account is obtained.
- **Sparkle + unnotarized app interaction is unverified** — first launch will still require manual Gatekeeper approval regardless of Sparkle; whether Sparkle-delivered subsequent updates trigger repeated Gatekeeper prompts needs prototyping before relying on it (see Open Questions).
- **Async enumeration correctness** — if external/network volume enumeration isn't properly isolated from the main thread, a hung network mount could still freeze the UI, defeating the "always instantly available" goal (FR1's whole premise).
- **Scope drift on "great UX"** — without a concrete visual spec, design quality is subjective and could expand indefinitely; treated as a deferred, iterative design task rather than a fixed v1 requirement.
- **Move to Trash is a destructive action** — even though Trash is recoverable, an accidental click could feel like real data loss to the user. Mitigation: inline confirmation step per FR8; no bulk/multi-select delete in v1.
- **Full Disk Access / privacy permissions** — reading Spotlight metadata and file paths across the user's whole home folder (Mail, Photos Library, Desktop/Documents under newer macOS privacy protections) may require the user to grant Full Disk Access manually in System Settings; without it, category/largest-files data will be incomplete. Needs a clear onboarding prompt.
- **Spotlight index gaps** — many external/network/USB drives are not Spotlight-indexed by default, so category breakdown and largest-files may be empty or stale for those volumes until indexing is enabled (see ADR-CANDIDATE above); this must be surfaced to the user, not hidden.
- **v1 scope grew substantially** by folding in diskbar.app's category-breakdown and largest-files/cleanup features — original ask was closer to a simple `df`-style menu bar readout. Flagging explicitly since it changes effort/complexity, per the user's direct request to include "everything useful from diskbar.app."

## Open Questions

Resolved during TECHSPEC (see `docs/techspec.md`): refresh model (icon-only timer + on-demand full compute), mount/unmount handling (no event listener — relies on lazy compute at open, matching Stats' own proven approach), Full Disk Access flow (lazy, prompted only on incomplete data), category taxonomy default mapping, and appcast/artifact packaging.

Still open:
- Exact Gatekeeper behavior for Sparkle-delivered updates on an unnotarized app (needs a spike/prototype before relying on it).
- Exact numeric targets for NFR1 (idle CPU %) and NFR2 (idle memory MB) — to be measured against a real Stats/iStat Menus install on the author's own Mac during implementation, rather than assumed from published marketing figures.
- Whether the "not indexed" Spotlight state should offer an opt-in on-demand raw scan as a fallback, or only ever show the degraded state (leaning toward the latter for v1 simplicity — confirm during implementation if it feels insufficient).

## Success Metric & Measurement Plan

Per the standard PRD bar, metrics should be tied to an instrumented data source with a named owner and check-back date. Given the "no telemetry" assumption above, v1 intentionally uses a qualitative, self-reported metric instead — flagged here as a deliberate deviation, not an oversight.

| Metric | Data source | Owner | Check-back date |
|---|---|---|---|
| Author no longer opens Finder/Дисковая утилита to check free space during normal daily use | Self-observation by the author (no instrumentation) | vaspo | 14 days after v1 first release (date TBD — pin once release ships) |

Any future decision to add real instrumentation (e.g., a local, non-networked usage counter) becomes an ordinary backlog task, with its check-back review routed through the metrics-review flow once instrumented.
