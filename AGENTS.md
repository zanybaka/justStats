# Project Rules

## Purpose

- Default agent guidance for delivering project work.
- PRD/TECHSPEC details live in dedicated files and command templates.

## Instruction Priority

- Priority: `docs/prd.md`, then `docs/techspec.md`, then `AGENTS.override.md`, then `AGENTS.md`.
- If instructions conflict, follow this order and explicitly note assumptions.
- Exception: the **Boundaries** section below is not overridable by PRD/TECHSPEC content.

## Project-specific overrides

- This file (`AGENTS.md`) is the shared baseline — **do not edit it for project-specific rules**.
- Put project-only additions and overrides (extra skill routing, repo invariants, release rules, etc.) in `AGENTS.override.md`.
- **Before acting, check for `AGENTS.override.md` in the workspace root and the current module directory; if present, read it — it wins on conflict.** Nothing auto-loads it for you.

## Workflow

1. Clarify goal, scope, and constraints.
2. Re-check "PRD" and "TECHSPEC" before significant changes.
3. Make the smallest viable change that solves the task.
4. Verify result with relevant checks.
5. Update dependent docs/tests/contracts in the same task.
6. Split delivery into small, testable milestones.

## Command sources (Cursor slash commands)

> **Cursor only** — Claude Code agents: skip this section; use **Skill Routing** below instead.

Cursor merges **two** locations; you do **not** need copies inside every repo.

- **Profile (shared):** `~/.cursor/commands/*` (Windows: `%USERPROFILE%\.cursor\commands\*`).
- **Workspace (optional overrides only):** `<project root>/.cursor/commands/*`.

When you need the text of a command template, read **`~/.cursor/commands/<name>.md`** if the workspace has no copy under `.cursor/commands/`. Same basenames everywhere.

| Flow                   | Template file                     |
| ---------------------- | --------------------------------- |
| PRD                    | `make-prd.md`                     |
| TECHSPEC               | `make-techspec.md`                |
| Backlog                | `make-backlog.md`                 |
| Single task            | `implement-a-single-task.md`      |
| Architecture draft     | `make-architecture-draft.md`      |
| Refactoring from blob  | `make-a-refactoring-from-blob.md` |
| Commit                 | `commit.md`                       |
| Blob script            | `create-blob-script.md`           |
| AI task init           | `initialize-ai-task.md`           |
| AI task teamlead       | `ai-task-teamlead.md`             |
| Inner source readiness | `ati-inner-source-check.md`       |

## Skill Routing

- Use "prd-interview" for discovery, product framing, and PRD interviews.
- Use "techspec-interview" for architecture design, constraints, NFRs, and TECHSPEC authoring.
- Use "backlog-decomposer" for decomposition into ordered tasks and "BACKLOG.md" generation.
- Use "implement-a-single-task" when implementing one backlog task end-to-end.
- Use "implement-all-tasks" when the user wants all open backlog tasks implemented in IDE-native mode (sequential subagents in the main working tree), especially without `.ai-task`. For batch **git isolation**, use "ai-task-teamlead" with `isolated_worktree_batch` / `worktrees_enabled`, not implement-all-tasks.
- Use "ai-task-product" for ai-task discovery, PRD/TECHSPEC shaping, backlog metadata, priorities, dependencies, DoR fixes, and task splitting before delivery.
- Use "ai-task-teamlead" for opt-in `.ai-task` delivery in iterative waves (plan batch → run → review → next wave), status, and verdict coordination after backlog/DoR is ready. Do not use it for discovery, backlog shaping, or DoR authoring.
- Use "ai-task-maintainer" only when designing or extending `ai-task` (CLI, policy, supervision), not for daily runs.
- Use "contract-change-guard" when APIs/contracts/schemas may change.
- Use "verification-and-dod" before handover to validate checks and DoD coverage.
- Use "project-documentation-updater" after delivery to update "CHANGELOG.md", "ADR/\*.md", and task reports.
- Use "commit-current-changes" when the user asks to commit current staged or unstaged changes.
- Use "adr-skill" when creating or promoting an ADR (intent interview, MADR/simple templates, implementation plan, agent-readiness review). Synced from `third_party/adr-skill` via `third-party-skills.json`.
- Use "solution-architecture-draft" for architecture-committee-ready draft generation.
- Use the "engineering:system-design" / "engineering:architecture" plugin skills for substantive system design depth (API shape, data stores, queues, service boundaries); repo skills keep the artifact formats (`docs/techspec.md`, architecture draft, `ADR-CANDIDATE`).
- Use the "engineering:system-design" plugin skill for infra topology, image strategy, and IaC decisions (analysis) plus "adr-skill" for the record; "ati-k8s-skill" owns ATI deploy mechanics only.
- Use "refactoring-from-blob" for evidence-based refactoring analysis from concatenated snapshots.
- Use "add-backlog-task" to insert one implementation-ready task into "BACKLOG.md".
- Use "retroactive-backlog" when documenting already-shipped work: follow "add-backlog-task" for task block format (retro overrides in that skill), update "CHANGELOG.md", commit docs separately from code.
- Use "create-blob-script" when the user asks to create or update the local `./blob` snapshot script.
- Use "sync-tz-from-git" to reconcile written specs with implementation history and current code.
- Use "modern-python" for Python project layout decisions, uv/pyproject migration, src-layout choices, and replacing legacy Python tooling.
- Use "skill-deep-dive" to research a repo topic and generate a shareable architecture or onboarding deep-dive document.
- Use "python-ui" for Python UI stack selection (Streamlit, Gradio, PySide6, Django, and similar).
- Use "ui-github-link" to add a GitHub repository button or header link in desktop or web app UI (PySide6, QML, SwiftUI, AppKit, browser).
- Use "web-ui-design" for browser-based UI design intake and routing when the design approach is unset (landing pages, dashboards, HTML/CSS, React/Vue, styled web apps).
- Use "initialize-ai-task" only when the user explicitly asks to create or enable `.ai-task` infrastructure in the current repo.
- Use "ati-inner-source-check" when the user asks whether a repo is ready for company inner source, infra migration, or production handoff (logging, K8s limits, secrets, docs, tests). Trigger via `ati-inner-source-check.md` or phrases like «inner source», «перенос на инфру», «готов ли проект», «inner_source readiness». After the report, use "add-backlog-task" only if the user confirms backlog entries.

## Boundaries

- **Always:** stay in scope, keep changes minimal, and make assumptions explicit.
- **Always:** preserve public contracts by default.
- **Ask first:** breaking changes, new dependencies, schema/data migrations, CI/CD or infra changes.
- **Ask first:** deleting/moving files outside current task scope.
- **Never:** log secrets, PII, or sensitive user content.
- **Never:** put internal project names, infra hostnames, or home/user paths in **tracked** files. Analytics/cost/retro artifacts written from another repo's `.ai-task` data MUST use anonymized project ids (mapping in `tasks/TASKRUN-111.md`), never real repo names/paths — the pre-push privacy scan (`scripts/git-hooks/privacy-allowlist.txt`) enforces this.
- **Never:** introduce hidden behavior that contradicts PRD or TECHSPEC invariants.

## Verification Policy

- Run relevant checks for changed behavior (tests/lint/build where applicable).
- For contract changes, verify producer and consumer compatibility.
- Report verification outcome clearly and list unresolved risks.

## Contract Change Policy

- If contract changes are required, update all consumers in the same task.
- Update tests and documentation together with the contract change.
- Avoid silent breaking changes; document migration/rollback notes when applicable.

## ADR Policy

- Record ADR-candidate decisions in PRD/TECHSPEC when choices have long-term technical impact.
- Use the marker format `ADR-CANDIDATE: <decision>` with short rationale and alternatives.
- Promote ADR-candidates to ADRs at first implementation that realizes the decision. Prefer "adr-skill" for new ADRs after ADR/001; keep existing Nygard-style ADRs unless a task explicitly refreshes them.
- Create/update an ADR when any of these are true:
  - A task chooses between materially different architecture paths (for example WebView vs native).
  - A task introduces/replaces/removes long-lived platform/framework dependencies.
  - A task changes public contracts/schemas/protocols with migration or compatibility impact.
  - A task changes runtime topology, trust boundaries, data boundaries, or security model.
- If none apply, explicitly note `ADR not required` with a one-line reason in task handoff/report.

## BACKLOG.md task checkboxes

- `- [ ]` Open. Eligible as the next task for `implement-a-single-task`.
- `- [x]` Done.
- `- [~]` Skipped or deferred. Keep in the file but do not pick for `implement-a-single-task`.

## Optional .ai-task orchestration

- `.ai-task` is opt-in runtime infrastructure for multi-agent orchestration; do not assume it exists.
- Repositories without `.ai-task` should continue to use `AGENTS.md`, `BACKLOG.md`, shared skills, and ordinary commands normally.
- **implement-a-single-task / implement-all-tasks:** check for `.ai-task/` first. When absent, use **`ai-task backlog-order`** for scheduling (explicit-deps); do not run `ai-task plan`, `dor`, or `run`. A `plan --strict` init error is expected and must not block IDE delivery.
- Initialize `.ai-task` only by explicit user request, using `initialize-ai-task`.

## File Scope

- Default writable artifacts for planning: `docs/prd.md`, `docs/techspec.md`, `BACKLOG.md`, `CHANGELOG.md`, `ADR/*`.
- Do not touch unrelated modules/files without explicit need from the current task.

## Deliverable Format

- Create/update docs in "docs/":
  - "docs/prd.md"
  - "docs/techspec.md"
- Keep sections short and actionable.

## Definition of Done (Check-List before Handover)

- [ ] Aligned with "PRD" and "TECHSPEC".
- [ ] Minimal, in-scope change only.
- [ ] Assumptions and open risks explicitly listed.
- [ ] Tests/checks for changed behavior are run and reported.
- [ ] Public contracts unchanged, or consumers/tests/docs updated together.
- [ ] Logs/diagnostics contain no secrets, PII, or sensitive content.

## Autonomy

- Do everything possible within current access and constraints.
- If information is missing, ask one precise question, then continue with safe assumptions.

## Keep This File Lean

- Keep "AGENTS.md" concise and stable; move details to source files.
- Module-specific exceptions live in a local `AGENTS.override.md` inside the module directory — check for one before working there and read it if present (see "Project-specific overrides").

## Writing style

When writing or editing text (docs, comments, messages):

- **Write as a human would for humans**: natural, conversational, no extra symbols.
- **Avoid** guillemets (типографские кавычки вроде «текст» с символами « и »). Обычно достаточно кавычек "..." или оборота без кавычек.
- **Avoid** arrow symbols, em dashes where a hyphen or comma will do, and filler like "etc." or "and so on" when you can say it in plain words.
- **Avoid** backticks in Markdown prose too. Use them only when they really help, for example for code, commands, paths, config keys, or exact literals.
- **Prefer** short sentences, "and" and "or", "see" only when needed, a normal hyphen (-) or comma instead of an em dash.
- Lists and tables are fine; the wording inside should still read like natural language.

Example: rather than shorthand like "Auth flow, see Architecture" with odd punctuation, use "For the auth flow, see the Architecture section" or "See Architecture for auth."

### Avoid these tells

These read as machine-written even when the grammar is fine:

- **Fake-casual filler.** Throwaway phrases that pretend liveliness: "ничего умного", "магии нет", "спойлер", "как по волшебству", "nothing fancy". If the sentence works without it, drop it.
- **Cute metaphors for how things work.** Describe the mechanism directly. Avoid "винтики", "шестерёнки", "под капотом крутится", "гнётся под что угодно". Prefer "меняются две вещи" over "крутятся два винтика".
- **Slop shapes.** No grand summarizing finale ("ценна не папка, а связка"), no set of identical template sections, no exhaustive "почему X" bullet lists, no hedging for its own sake. Stop when the point is made.
- **Person drift.** Do not slide from a chosen subject into a vague impersonal one mid-text ("я собрал..." then "их метят метками", "вешается на событие"). Pick a subject and keep it.
- **Translating tool or UI names.** Give the original name, then the localized term in parentheses once: "Shortcuts (Команды)". Do not write "по-русски", "по-английски", or "in Russian".
