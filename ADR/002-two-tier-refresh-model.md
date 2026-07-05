# ADR-002: Two-tier refresh model

Status: Accepted
Date: 2026-07-04
Sources: `docs/architecture-draft.md` §3, `docs/techspec.md` §3

## Context

The PRD requires both a status icon that is glanceable without opening anything (Goal 2, FR1) and strict low CPU/memory NFRs (NFR1–NFR4). The data the app shows has cost profiles that differ by orders of magnitude: a single boot-volume `statfs()` is sub-millisecond, while full volume enumeration and Spotlight (`NSMetadataQuery`) category/largest-files queries are comparatively expensive. A single uniform poll loop would force a choice between staleness (long interval) and system load (short interval) for data that is expensive to compute. The PRD also had an open question: should mount/unmount trigger an immediate refresh?

## Decision

Split data into two independent, deliberately decoupled tiers:

1. **Icon tier (live, cheap, always-on):** a single lightweight repeating timer (`Timer`/`DispatchSourceTimer`) calls `statfs()` on the boot volume only and drives the icon color. Interval: default 30s, a tunable constant, not user-facing (PRD non-goal on a configurable refresh interval).
2. **Popover tier (lazy, expensive, on-demand):** full volume list, category breakdown, and largest files are computed only when the popover opens, plus on an explicit manual "Refresh" button press. No background polling for this tier.
   - Internal volumes: resolved synchronously (fast, local `statfs`) and rendered immediately.
   - External/network volumes: resolved on `DispatchQueue.global(qos: .utility)` and appended as each resolves, so a hung SMB mount cannot block anything.
   - Categories + largest files: `NSMetadataQuery` per volume, off the main thread, streamed into the UI per volume.

No dedicated mount/unmount listener in v1 (no `DiskArbitration` event subscriptions): opening the popover always re-enumerates current volumes, which is equivalent in practice and matches Stats' own verified approach (timer + re-enumerate, not `DARegisterDiskAppearedCallback`).

## Alternatives considered

- **One uniform polling loop for all data:** rejected. Simpler, but a single interval forces the staleness-vs-load trade-off and runs expensive Spotlight/enumeration work on a timer even when nobody is looking; splitting by cost profile avoids that trade-off entirely.
- **Full event-driven `DiskArbitration` mount/unmount subscriptions:** rejected. More "real-time," but adds complexity Stats itself doesn't carry (verified against its source — the 40k-star reference app polls and re-enumerates), for a benefit (instant mount detection) the user didn't ask for and that popover-open re-enumeration already provides in practice.

## Consequences

- NFR1–NFR4 enforced by design: only one cheap `statfs` call runs continuously; all expensive work is on-demand and off the main thread.
- Icon stays live without any click; popover data is always freshly computed on open.
- Resolves the PRD open question: mount/unmount events do not trigger refresh in v1; volume list may be momentarily stale only while the popover is already open (mitigated by the manual Refresh button).
- Sets the data-collection pattern ("fast local + async extended") that future v2 modules (RAM/network) should follow.

## Implementation references

- `justStats/Modules/Disk` — `IconController` (icon tier), `VolumeEnumerator` and `CategoryScanner` (popover tier), per techspec §2–§3.
