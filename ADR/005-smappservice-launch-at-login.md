# ADR-005: SMAppService for launch-at-login instead of a helper executable

Status: Accepted
Date: 2026-07-05
Sources: `docs/techspec.md` §5, §1; `docs/architecture-draft.md` §3 (decisions table); `docs/prd.md` (ADR-CANDIDATE — Kit/Modules pattern + launch-at-login)

## Context

justStats needs a "Launch at Login" toggle (FR11). The project mirrors exelban/stats' `Kit` + per-stat `Modules` architecture pattern, and the PRD's original plan was to reuse Stats' `LaunchAtLogin` module directly. Reading Stats' actual source showed that module implements a legacy embedded-helper-executable login-item pattern, which exists to support macOS versions older than our baseline. justStats targets macOS 15 (Sequoia+), where `SMAppService.mainApp` (macOS 13+) provides launch-at-login as a single API call with no separate login-item executable.

## Decision

Use `SMAppService.mainApp` directly for launch-at-login, not a helper-executable login item:

- Enable from the Settings toggle via `SMAppService.mainApp.register()`; disable via `.unregister()`.
- Read current state via `SMAppService.mainApp.status` to drive the toggle.
- No separate helper target, and no embedded login-item executable.

This adopts Stats' `Kit`/`Modules` structural pattern for the module boundary while explicitly **not** reusing its `LaunchAtLogin` helper-executable implementation.

## Alternatives considered

- **Reuse Stats' `LaunchAtLogin` helper-executable module (the PRD's original plan):** rejected after source inspection. It works, but its embedded-helper pattern exists only for pre-Sequoia macOS versions outside our baseline; copying it would add an unnecessary extra build target and login-item executable for zero benefit on macOS 15+.

## Consequences

- Launch-at-login is a one-call modern API with no extra build target, no embedded executable to sign/ship, and a directly readable status for the toggle — simpler to build and maintain.
- Hard dependency on the macOS 13+ `SMAppService` API, which is fully satisfied by the macOS 15 baseline.
- This corrects the PRD's original ADR-CANDIDATE (reuse Stats' module) after inspecting Stats' actual source; the `Kit`/`Modules` structural borrowing from Stats still stands — only the launch-at-login implementation choice diverges.

## Implementation references

- `justStats/SettingsViewModel` — launch-at-login toggle wiring to `SMAppService.mainApp.register()` / `.unregister()` / `.status`, per techspec §5.
