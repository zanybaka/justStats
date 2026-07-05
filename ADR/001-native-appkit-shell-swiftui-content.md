# ADR-001: Native AppKit shell with SwiftUI content

Status: Accepted
Date: 2026-07-04
Sources: `docs/architecture-draft.md` §3, `docs/techspec.md` §1, `docs/prd.md` (ADR-CANDIDATE decisions)

## Context

justStats is a macOS menu bar disk monitor whose primary binding constraint is minimal system footprint: minimal idle CPU/memory and near-instant launch (PRD NFR1–NFR4; the user explicitly prioritized "не нагружать систему" and tight menu-bar integration via `NSStatusItem`). The popover UI is a dense, scrollable, action-heavy list (volume rows, category bars, largest-files rows with Reveal/Trash buttons). The project mirrors the proven module structure of exelban/stats (MIT), verified directly against its source. The installed `macos-app-design` skill's default is "prefer SwiftUI, drop to AppKit only where needed."

## Decision

Build a native Swift app with an **AppKit shell** and **SwiftUI content**:

- Shell (AppKit): `NSStatusItem` creation, `.button`/`NSStatusBarButton`, `NSPopover` lifecycle, app lifecycle.
- Content (SwiftUI): the popover's actual content (volume rows, category bars, largest-files list) is a SwiftUI view tree hosted via `NSHostingView` inside that popover.
- Keep the AppKit↔SwiftUI bridging layer thin (and well-tested), per the design skill's explicit rule.
- App archetype: menu-bar app ("lives in menu bar, minimal UI") — the full windowed "Mac Citizen" baseline (standard menus, multi-window) does not apply; keyboard accessibility, VoiceOver labels, and Settings via ⌘, still apply.

## Alternatives considered

- **Electron / Tauri / Flutter (cross-platform frameworks):** rejected. They conflict directly with the core low-CPU/low-memory constraint; native has the lowest floor for idle footprint and launch time. Electron is fastest to build but heavy in memory/CPU; Tauri is lighter but immature for native macOS menu-bar patterns and adds a Rust↔Swift boundary; Flutter desktop has limited/awkward `NSStatusItem`-style menu bar support.
- **Pure SwiftUI `MenuBarExtra`:** rejected. Its popover model is less predictable for a dense, scrollable, action-heavy list; the AppKit shell gives full control while still using SwiftUI for the content layer, and matches the exact shape of the reference project (exelban/stats) whose patterns are already being borrowed.

## Consequences

- Lowest achievable idle footprint and launch time; satisfies NFR1–NFR4 by construction.
- Full control over popover behavior for the dense interactive list.
- Requires a thin, well-tested AppKit↔SwiftUI bridging layer (`NSHostingView` hosting).
- macOS-only by design; broader OS/arch support is out of scope (macOS 15+ baseline).
- Aligns the codebase layout with Stats' `Kit` + `Modules` pattern (App shell / Kit / Modules/Disk), easing future v2 modules (RAM, network).

## Implementation references

- `justStats/App` — AppKit shell (`NSStatusItem`, `NSPopover` host, lifecycle).
- `justStats/Kit`, `justStats/Modules/Disk` — module structure per §1 of the techspec.
