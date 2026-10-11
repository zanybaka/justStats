# ADR-006: Rule-catalog cleanup actions instead of AI or heuristic suggestions

Status: Proposed
Date: 2026-10-11
Sources: `docs/prd.md` (FR14–FR16, ADR-CANDIDATE — rule-catalog cleanup); `docs/techspec.md` §12; manual disk-cleanup session on the author's Mac, 2026-10-10/11

## Context

justStats shows where space went (categories, largest files) and offers Reveal/Trash for individual files. A manual cleanup session showed that most reclaimable space was not user files but tool caches and update leftovers (Docker images, uv/npm caches, VS Code ShipIt residue, model caches). The app cannot see these as "largest files" and Trash is the wrong action for them (caches in Trash still occupy space; some are cleaned by the tool's own command). The app has no AI and must remain light, predictable and offline.

## Decision

Offer cleanup through a compiled-in, data-driven rule catalog:

- Each rule names one known item, how to detect it, a safety tier, and exactly one action.
- Actions are either deleting a declared directory or running one fixed command from an allowlist (no shell, fixed argv, timeout).
- Green tier: one-click Clean after an inline confirmation. Yellow tier: explain only, no action.
- Anything the catalog cannot cover is handed to an external AI by a copyable English prompt (FR16); the app makes no AI or network calls.

## Alternatives considered

- **Heuristic junk detection (size/age/location):** rejected. False positives delete user data; unacceptable for a disk tool.
- **Embedded LLM or cloud call:** rejected. Footprint, network dependency, trust, and it conflicts with NFR1–NFR4.
- **Trash-only cleanup:** rejected. Does not free space until emptied, and cannot run tool-native cleanup (`docker system prune`, `uv cache prune`).
- **Notifications only:** rejected. PRD Non-Goals exclude push alerts and a notification does not resolve the problem.

## Consequences

- Every destructive path is enumerable and unit-testable; a new item is a data change plus a test.
- The app now executes external programs. This is a new risk class beyond ACT-002 Move to Trash and needs the dedicated safety review task (CLEAN-006) before release.
- The catalog goes stale as tools change; entries need an owner and a "last verified" date in code comments.
- Direct delete is not undoable. Mitigated by the green-tier rule: only regenerable data, always confirmed.

## Implementation references

- `docs/techspec.md` §12 — rule model, execution safety, prompt contents.
- Tasks: `backlog/tasks/ADR-004.md`, `CLEAN-001` … `CLEAN-006`.
