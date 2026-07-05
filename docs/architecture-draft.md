# Architecture Draft — justStats (macOS menu bar disk monitor)

Status: draft for review. Last updated: 2026-07-04. Traces to `docs/prd.md` and `docs/techspec.md`.

## 1. Proposed Solution Scope

A native macOS menu bar utility (v1: disk monitoring only; v2 roadmap: RAM, network) that:

- Shows a color-coded status icon (system/boot volume health) without requiring any click.
- On click, shows all mounted volumes (internal first, external/network appended async) with total/used/free, a category breakdown (System/Apps/Media/Other/Free), and a "largest files" list with Reveal-in-Finder / Move-to-Trash actions.
- Ships unsigned/unnotarized (no Apple Developer Program membership), MIT-licensed, distributed via GitHub Releases, self-updating via Sparkle.

**Constraints (binding, not aspirational):**
- Platform baseline: macOS 15 (Sequoia)+; broader OS/arch support dropped first if it costs complexity or performance.
- Performance: minimal idle CPU/memory, near-instant launch (NFR1–NFR4 in PRD) — the primary constraint shaping every architecture choice below.
- No Apple Developer Program membership → no notarization, no Mac App Store, no sandboxing.
- No telemetry/analytics (privacy-first personal/OSS tool).

## 2. Proposed Architecture

```
justStats.app
├── App shell (AppKit: NSStatusItem, NSPopover host, app lifecycle)
├── Kit (shared helpers — pattern mirrored from exelban/stats' Kit)
└── Modules
    └── Disk (v1)
        ├── IconController   — cheap periodic boot-volume statfs → icon color (+ shape/VoiceOver signal)
        ├── VolumeEnumerator — FileManager + DiskArbitration metadata, on-demand
        ├── CategoryScanner  — Spotlight (NSMetadataQuery) category + largest-files, on-demand
        └── FileActions      — Reveal in Finder / Move to Trash
```

- **Shell:** AppKit (`NSStatusItem`/`NSPopover`) for full control over a dense, interactive popover; **content:** SwiftUI views hosted via `NSHostingView` inside that popover (thin AppKit↔SwiftUI bridge).
- **Refresh model:** two independent tiers — a lightweight always-on timer drives only the icon (single `statfs` call, ~30s interval); everything else (full volume list, categories, largest files) computes lazily on popover open plus an explicit manual "Refresh" button. No background polling for the expensive tier, no `DiskArbitration` event subscriptions.
- **Category/largest-files data:** Spotlight (`NSMetadataQuery`) queries, not a recursive filesystem walk — degrades to an explicit "not indexed" state per volume rather than falling back to an expensive scan.
- **Launch at login:** `SMAppService.mainApp.register()` (macOS 13+ API), no helper executable.
- **Updates:** Sparkle, self-managed EdDSA key, `appcast.xml` served from `raw.githubusercontent.com`, `.zip` release artifacts on GitHub Releases.
- **Settings persistence:** plain `UserDefaults`, no schema versioning.
- **Full Disk Access:** requested lazily — only surfaced when Spotlight data comes back incomplete, with a direct link to the relevant System Settings pane.

Full detail and requirement traceability: `docs/techspec.md`.

## 3. Alternatives Considered and Trade-offs

| Decision | Chosen | Alternative(s) | Why chosen wins here |
|---|---|---|---|
| Runtime/language | Native Swift (AppKit shell + SwiftUI content) | Electron / Tauri / Flutter | Cross-platform frameworks conflict directly with the core low-CPU/low-memory constraint; native has the lowest floor for idle footprint and launch time. |
| Menu bar shell | `NSStatusItem` + `NSPopover` (AppKit), SwiftUI content inside | Pure SwiftUI `MenuBarExtra` | `MenuBarExtra`'s popover model is less predictable for a dense, scrollable, action-heavy list; AppKit shell gives full control while still using SwiftUI for the content layer (per the installed `macos-app-design` skill's own default: prefer SwiftUI, drop to AppKit only where needed). |
| Volume/change detection | `FileManager.mountedVolumeURLs` + `DiskArbitration` for metadata only, on a timer | Full `DiskArbitration` event-driven mount/unmount subscriptions | Verified against exelban/stats' actual source: the 40k-star reference app doesn't use event-driven `DiskArbitration` either — it polls and re-enumerates. Adopting the proven-at-scale pattern instead of a more complex event pipeline for a benefit (instant mount detection) not requested and already covered in practice by popover-open re-enumeration. |
| Refresh strategy | Two-tier (cheap icon timer + lazy on-demand full compute) | One uniform polling loop for all data | A single interval forces a choice between staleness (long interval) and system load (short interval, since Spotlight/enumeration is comparatively expensive); splitting by cost profile avoids that trade-off entirely. |
| Category/largest-files computation | Spotlight (`NSMetadataQuery`) | Raw recursive filesystem walk; custom background indexer | A full walk is slow/IO-heavy and conflicts with the "internal disks render instantly" requirement and the low-load NFRs, especially on network volumes. A custom indexer is disproportionate engineering investment for v1. Trade-off accepted: degraded/partial data on unindexed volumes. |
| Launch at login | `SMAppService.mainApp.register()` | Reuse Stats' legacy helper-executable `LaunchAtLogin` module | Stats' helper-executable pattern exists for macOS versions older than our Sequoia-15+ baseline; unnecessary here. The modern one-call API is simpler and needs no extra build target. (Originally planned to reuse Stats' module; corrected after reading its actual source.) |
| Update distribution | Sparkle, self-signed EdDSA, no notarization | Manual-download-only updates; Mac App Store | No Apple Developer Program membership rules out notarization/App Store distribution and its sandboxing requirement. Sparkle gives low-friction updates without that dependency; manual-only was rejected as unnecessary friction given Sparkle doesn't require it. |
| Settings persistence | Plain `UserDefaults`, no schema versioning | Versioned JSON schema with migration support | Explicit simplicity call for a handful of scalar settings — versioning would be over-engineering at this scale; confirmed directly with the requester. |

## 4. Assumptions

- UI language: English only for v1.
- System/service APFS containers (Preboot, Recovery, VM, hidden Data internals) filtered from the volume list; only user-facing mounted volumes shown.
- Category taxonomy (System/Apps/Media/Other/Free) is a first-pass default (System as a residual bucket), expected to be refined once real volumes are tested.
- Distribution artifact is `.zip`; appcast served from a raw GitHub file, not a dedicated hosting service.
- No telemetry — success is judged qualitatively by the author (self-observation), not instrumented events.

## 5. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Gatekeeper friction on unsigned builds deters non-technical GitHub users | Clear README install instructions; revisit notarization if a paid Developer account is obtained later. |
| Sparkle + unnotarized-app upgrade behavior is unverified | Spike/prototype the real upgrade flow (two versions, real Gatekeeper test) before relying on it for a public release. |
| Hung network volume could still block UI if async isolation is done incorrectly | All non-internal volume calls run off the main thread (`DispatchQueue.global(qos: .utility)`); internal-disk rendering path never depends on their completion. |
| Move to Trash is a destructive-feeling action | Inline confirmation before every `trashItem` call; no bulk/multi-select delete in v1; uses `FileManager.trashItem` (recoverable), never permanent delete. |
| Spotlight index gaps on external/network volumes | Explicit "not indexed" UI state instead of silently wrong or empty data; no automatic fallback to an expensive raw scan. |
| Full Disk Access not granted | Lazy request only when data comes back incomplete, with a direct System Settings deep link — avoids an unnecessary permissions prompt at first launch. |
| Color-only status signal excludes colorblind users and VoiceOver | Corrected in FR1: icon also changes shape/glyph at critical state, plus a VoiceOver accessibility label describing status in words. |
| v1 scope grew substantially (category breakdown, largest-files/cleanup) vs. the original simple `df`-style ask | Explicitly flagged in PRD; confirmed directly with the requester as an intentional scope expansion, not creep. |

## 6. Open Architecture Questions

- Exact numeric ceilings for NFR1 (idle CPU %) and NFR2 (idle memory MB) — to be measured against a real Stats/iStat Menus install during implementation, not assumed from marketing figures.
- Whether an opt-in manual raw-scan fallback is ever needed for unindexed volumes, or the degraded state is sufficient indefinitely.
- Exact category-taxonomy edge cases (e.g., what lands in "Other" vs. residual "System") — first-pass default, to be refined against real disk contents.

## 7. Open Information Security Questions

- Gatekeeper behavior on Sparkle-delivered updates to an already-approved, unnotarized app — unverified; if updates unexpectedly re-trigger full Gatekeeper blocks (not just a warning), the update UX degrades and needs a fallback message pointing users to manual download.
- Sparkle private signing key handling: must never be committed to the repo; needs a documented, out-of-band storage location (e.g., local keychain/password manager) since there is no CI secrets vault in scope for this project.
- Full Disk Access grants the app read access to the user's entire home folder (Mail, Photos, Messages, etc.) for Spotlight queries — scope is broader than disk-space math alone requires; no data leaves the machine (no telemetry/network calls beyond Sparkle + GitHub asset download), but this is worth stating explicitly since it's a meaningful permission for an unsigned, unnotarized third-party binary.
- Move-to-Trash file actions run with the current user's full filesystem permissions — no additional sandboxing layer (rejected earlier due to no Developer Program membership); relies entirely on the inline confirmation step as the safety control.

## 8. Decision Request

Requesting sign-off to proceed to backlog decomposition and implementation on the architecture above. Specific decisions needing explicit confirmation (all previously discussed directly with the requester, restated here for a single point of approval):

1. Native Swift, AppKit shell + SwiftUI content, over any cross-platform framework.
2. Two-tier refresh model (live icon timer only; everything else lazy on-demand) over continuous background polling.
3. Spotlight-based category/largest-files computation with an explicit degraded state, no raw-scan fallback in v1.
4. Sparkle-based auto-update without Apple notarization/Developer ID, accepting the associated Gatekeeper friction and the still-unverified upgrade-flow risk (§7).
5. No sandboxing / no Mac App Store distribution for v1.

**Approvals required:** vaspo (sole author/decision-maker — no formal committee for this project; this document substitutes for one, per the repo's solo-maintainer context).
