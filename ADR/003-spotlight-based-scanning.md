# ADR-003: Spotlight-based category and largest-files scanning

Status: Accepted
Date: 2026-07-05
Sources: `docs/techspec.md` §4, §7, §11; `docs/architecture-draft.md` §3; `docs/prd.md` (ADR-CANDIDATE decisions)

## Context

The popover must show a per-volume category breakdown (System/Apps/Media/Other/Free) and a "largest files" list (FR6–FR8). Producing this data requires classifying and ranking files by size across a volume. A full recursive walk of an internal SSD — let alone an external or network volume — is slow and CPU/IO-heavy, directly conflicting with the "don't load the system" constraint (NFR1–NFR4) and the "internal disks must render instantly" requirement (FR3). macOS already maintains a pre-built file index (Spotlight) that can answer both category-by-kind and largest-file queries near-instantly with negligible extra load. Category and largest-files data granularity depends on read access to the user's home folder, which under recent macOS privacy protections requires Full Disk Access.

## Decision

Compute the category breakdown and largest-files list via Spotlight (`NSMetadataQuery`), scoped per volume, not via a raw recursive filesystem walk. Queries run only on demand (popover open plus the manual "Refresh" button), off the main thread on `DispatchQueue.global(qos: .utility)`, streamed into the UI per volume as results arrive; they are cancellable and released, with no query running while the popover is closed (per ADR-002 and NFR4).

Default taxonomy (techspec §4), computed against the volume's index:

- **Apps:** `kMDItemContentType == 'com.apple.application-bundle'`, summed logical size.
- **Media:** `kMDItemContentTypeTree` intersects `public.image`, `public.movie`, `public.audio`.
- **Other:** user-owned files not matching Apps or Media (documents, archives, code), via one additional predicate scoped to `/Users/*`.
- **Free:** `statfs` free bytes (not a Spotlight query).
- **System:** residual `Total − Free − Apps − Media − Other`, clamped to ≥ 0 — matching the "large residual bucket" approach Finder's own "About This Mac → Storage" uses, avoiding the need to positively classify every OS/cache/hidden file.

When a volume's index is unusable (external/network drives are frequently unindexed, or paths are excluded via `mdutil -i off` / `.metadata_never_index`), show an explicit "Not indexed — category breakdown unavailable" state for that volume rather than a zero/misleading bar. No automatic fallback to a raw recursive scan.

## Alternatives considered

- **Raw recursive filesystem walk:** rejected. Accurate and always available, but slow and high-IO; it violates the non-blocking and low-load constraints (NFR1–NFR4) and the "internal disks render instantly" requirement, and is especially bad on network volumes. An opt-in manual "scan anyway" action remains a candidate for a later backlog item, not v1.
- **Custom background indexer built into the app:** rejected. Accurate and independent of Spotlight, but a large engineering investment disproportionate to v1 scope.

## Consequences

- Category and largest-files data is available at near-zero extra load on indexed volumes; NFR1–NFR4 preserved because no continuous or expensive scan runs.
- **Degraded state on unindexed volumes:** volumes without a usable Spotlight index show an explicit "not indexed" notice instead of wrong or empty numbers; accuracy of this data is bounded by Spotlight's indexing state, not by the app.
- **Full Disk Access dependency:** complete category/largest-files data requires read access across the user's home folder (Mail, Photos, Messages, etc.), which needs Full Disk Access. It is requested lazily — only when results come back empty/incomplete in a way consistent with a permissions block — surfacing an inline notice with a direct link to the relevant System Settings pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`), not a prompt at first launch. This grant is broader than disk-space math alone requires; no data leaves the machine (no telemetry; network calls limited to Sparkle update checks and GitHub asset downloads).
- Whether the degraded state is sufficient indefinitely, or an opt-in on-demand raw scan is later needed for unindexed volumes, is left open — default is the degraded state only for v1.

## Implementation references

- `justStats/Modules/Disk` — `CategoryScanner` (Spotlight category + largest-files queries) and `FileActions` (Reveal/Trash), per techspec §2–§4, §7.
