#!/usr/bin/env python3
"""GENERATED FILE - DO NOT EDIT. Backlog index guard (TASKRUN-145).

The file-per-task backlog store's own code, bundled into one self-contained
script so a plain checkout - a CI runner, which never has the gitignored
`.ai-task/` tree - can verify that BACKLOG.md still equals a fresh
regeneration from `backlog/tasks/`. Tracked on purpose: the store tool is
otherwise operator-local, and CI cannot run a tool it never checks out.

Usage:
    python3 scripts/backlog-index-guard.py check        # exit 1 when the index drifted (CI)
    python3 scripts/backlog-index-guard.py regenerate   # rebuild BACKLOG.md from backlog/tasks/
    python3 scripts/backlog-index-guard.py source-hash  # provenance of this generated copy

A repo that has not migrated to the file-per-task store (no
`backlog/index-skeleton.md`) passes `check` untouched - there is no generated
index to guard.

Refresh - never hand-edit - from the repo that owns the store tool:
    python3 .ai-task/scripts/backlog-store.py guard      # consuming repo
    python3 scripts/backlog-store.py guard               # using-ai profile
`guard --check` exits 1 when this file is stale or hand-edited, and
`ai-task init` rewrites it whenever the profile moves; being tracked, every
refresh shows up in `git status` instead of ageing silently.

Bundled verbatim (intra-package imports stripped) from: ai_task/_shared.py, ai_task/backlog.py, ai_task/backlog_store.py.
Source digest: sha256:10ade699962a8b33d1efb3618924c16e479fd71ec9dacbd4a93262e65916c782 (bundle format 1).
"""

from __future__ import annotations


# ===========================================================================
# ai_task/_shared.py (bundled verbatim, intra-package imports stripped)
# ===========================================================================
"""Cross-domain primitives shared by ai_task package modules.

Kept intentionally tiny (TASKRUN-118): the CLI error primitive, the
`.ai-task` app-dir location, and the process-liveness probe, needed across
domain modules. Later Phase 35 slices may add to this module, but anything
with domain logic belongs in its domain module, not here.
"""


import datetime as dt
import os
import sys
from pathlib import Path
from typing import Any, NoReturn

APP_DIR = ".ai-task"


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def die(message: str, code: int = 1) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(code)


def app_path(root: Path) -> Path:
    return root / APP_DIR


def pid_alive(pid: Any) -> bool | None:
    if not isinstance(pid, int):
        return None
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


# ===========================================================================
# ai_task/backlog.py (bundled verbatim, intra-package imports stripped)
# ===========================================================================
"""Backlog domain for the ai-task CLI (TASKRUN-119, Phase 35 slice 2).

Backlog machinery extracted verbatim from scripts/ai-task.py: `Task` parsing
(parse_backlog, TASK_RE and the checkbox regexes), DoR gap collection
(DorGap, collect_dor_gaps, dor_gaps_for_root, unparsed-checkbox gaps),
provenance validation (VALID_SOURCES, INCIDENT_SEVERITY_PRIORITY), the
SKILL-093 rebuild-invariant detector (SharedContractClass,
SHARED_CONTRACT_CLASSES, reminder functions), and the risk-gate keyword scan
(RISK_WORDS, BENIGN_RISK_COMPOUNDS, risk_gates).

Standalone by design: imports only the stdlib and ai_task._shared - no
subprocess, no state.json. Policy reaches risk_gates as a plain dict
argument, so there is no ai_task.policy import. A mover function that drags
in run-state or journal helpers belongs elsewhere: `enforce_risk_confirm`
wraps `risk_gates` but logs a `--risk-ack` to the decision journal, so it
lives in ai_task.decisions (TASKRUN-129), not here.
"""


import json
import re
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any


TASK_RE = re.compile(
    r"^- \[(?P<status>[ x~])\]\s+(?P<id>[A-Z][A-Z0-9-]*-\d+)\s+(?P<title>.+?)\s*$"
)
CHECKBOX_LINE_RE = re.compile(r"^- \[(?P<status>[ x~])\]\s+(?P<rest>.+?)\s*$")
TASK_ID_TOKEN_RE = re.compile(r"^[A-Z][A-Z0-9-]*-\d+$")
TASK_ID_PREFIX_RE = re.compile(r"^[A-Z][A-Z0-9-]*-")
RISK_WORDS = (
    "contract",
    "schema",
    "migration",
    "auth",
    "oauth",
    "security",
    "protocol",
    "public api",
    "runtime topology",
    "trust boundary",
    "data boundary",
)
# TASKRUN-113: phrases that contain a risk word but are benign (an error-mapping,
# not an API/schema contract). Scrubbed from the text before the word-boundary scan
# so they no longer trip a false-positive risk-keyword gate.
BENIGN_RISK_COMPOUNDS = (
    "error contract",
    "contract test",
)
# TASKRUN-113: anchor on the WORD START only (leading \b, no trailing \b). This
# rejects the false positive "subcontractor" (the risk word is not at a word start)
# while still catching legitimate derived/plural forms the prior substring scan
# flagged — "contracts", "schemas", "migrations", "authentication", "authorization".
# A trailing \b would silently drop all of those, turning a genuine trust-boundary
# task (e.g. "Add OAuth login" / "run database migrations") into a false negative
# that bypasses the gate. Over-matching here is the safe direction (a human just
# confirms); under-matching is not. "oauth" is listed explicitly in RISK_WORDS
# because a leading \b before "auth" cannot reach it inside "oauth".
RISK_WORD_PATTERNS = tuple(
    (word, re.compile(r"\b" + re.escape(word))) for word in RISK_WORDS
)


@dataclass(frozen=True)
class Task:
    id: str
    title: str
    status: str
    phase: str
    index: int
    block: str
    priority: str
    size: str
    depends_on: tuple[str, ...]
    agent: str
    # Provenance (SKILL-045): where this task came from, so post-release/ops work is
    # machine-distinguishable from planned delivery. `source` is an enum (planned by
    # default → existing backlogs stay valid); `incident` carries the ref + severity
    # for post-release incident tasks (`Source: incident`).
    source: str = "planned"
    incident: str = ""

    @property
    def is_open(self) -> bool:
        return self.status == " "


def task_metadata(block_lines: list[str], key: str, default: str = "") -> str:
    prefix = f"{key}:"
    for line in block_lines[1:]:
        if line.startswith(prefix):
            return line[len(prefix) :].strip()
    return default


def parse_backlog(root: Path) -> list[Task]:
    """Canonical backlog reader (TASKRUN-141 dual-read retired by TASKRUN-142).

    When ``backlog/tasks/*.md`` exists it is the ONLY source of task blocks:
    the root BACKLOG.md is a regenerated read-only index and is never parsed
    for tasks. An inline task block found next to a populated task-file store
    aborts loudly instead of merging - the dual-read transition window is
    closed, and silently preferring either source is the merge hazard the
    store exists to remove. A repo with no ``backlog/tasks/`` files keeps the
    original inline behavior unchanged (consuming repos migrate on their own
    schedule).
    """
    backlog_path = root / "BACKLOG.md"
    if not backlog_path.exists():
        die(f"BACKLOG.md not found in {root}")
    lines = backlog_path.read_text(encoding="utf-8").splitlines()
    file_tasks = parse_task_files(root)
    if file_tasks:
        inline = parse_backlog_blocks(lines)
        if inline:
            inline_ids = ", ".join(task.id for task in inline)
            die(
                f"inline task block(s) in {backlog_path} alongside a populated "
                f"backlog/tasks/ store: {inline_ids}. BACKLOG.md is a generated "
                "index; move each block into backlog/tasks/<TASK-ID>.md and "
                "regenerate it (python scripts/backlog-store.py regenerate)"
            )
        return file_tasks
    return parse_backlog_blocks(lines)


def store_task_files(root: Path) -> list[Path]:
    """Per-task store files, sorted by filename; [] when the store is absent.

    Only the literal ``backlog/tasks/`` directory counts - ``backlog/archive/``
    (including an archived ``tasks/`` subdirectory) stays invisible to every
    delivery reader.
    """
    tasks_dir = root / "backlog" / "tasks"
    if not tasks_dir.is_dir():
        return []
    return sorted(tasks_dir.glob("*.md"))


def archive_task_files(root: Path) -> list[Path]:
    """Rotated-out per-task files under backlog/archive/tasks/, sorted.

    AUDIT readers only (recurrence, dashboard, artifact check): delivery
    readers never see these. Rotation moves a closed task file here verbatim,
    so history-facing tooling merges this directory alongside the legacy
    ``backlog/archive/BACKLOG-*.md`` archives.
    """
    archive_dir = root / "backlog" / "archive" / "tasks"
    if not archive_dir.is_dir():
        return []
    return sorted(archive_dir.glob("*.md"))


def parse_task_files(root: Path) -> list[Task]:
    """Parse the per-task store: one standard task block per file.

    Each ``backlog/tasks/<TASK-ID>.md`` holds one block in the exact
    BACKLOG.md grammar, optionally preceded by its ``## <phase>`` heading (the
    phase-membership record the index generator reads), so the same block
    parser reads it. Files are read sorted by filename with ``index`` growing
    across files, so the (priority, file order) tie-break is deterministic. A
    task id that duplicates an already-parsed id aborts loudly naming both
    files - never silent shadowing.
    """
    sources: dict[str, str] = {}
    file_tasks: list[Task] = []
    index_offset = 0
    for task_file in store_task_files(root):
        file_lines = task_file.read_text(encoding="utf-8").splitlines()
        for task in parse_backlog_blocks(file_lines):
            previous = sources.get(task.id)
            if previous is not None:
                die(
                    f"duplicate task id {task.id}: {task_file} duplicates {previous}"
                )
            sources[task.id] = str(task_file)
            file_tasks.append(replace(task, index=task.index + index_offset))
        index_offset += len(file_lines)
    return file_tasks


def parse_backlog_blocks(lines: list[str]) -> list[Task]:
    tasks: list[Task] = []
    phase = ""
    current_start: int | None = None
    current_match: re.Match[str] | None = None

    def flush(end: int) -> None:
        nonlocal current_start, current_match
        if current_start is None or current_match is None:
            return
        block_lines = lines[current_start:end]
        depends = task_metadata(block_lines, "Depends on")
        depends_on = tuple(part.strip() for part in depends.split(",") if part.strip())
        tasks.append(
            Task(
                id=current_match.group("id"),
                title=current_match.group("title"),
                status=current_match.group("status"),
                phase=phase,
                index=current_start,
                block="\n".join(block_lines).strip() + "\n",
                priority=task_metadata(block_lines, "Priority", "P2") or "P2",
                size=task_metadata(block_lines, "Size", "M") or "M",
                depends_on=depends_on,
                agent=task_metadata(block_lines, "Agent", "auto") or "auto",
                source=task_metadata(block_lines, "Source", "planned") or "planned",
                incident=task_metadata(block_lines, "Incident", ""),
            )
        )
        current_start = None
        current_match = None

    for idx, line in enumerate(lines):
        match = TASK_RE.match(line)
        if match:
            flush(idx)
            current_start = idx
            current_match = match
            continue
        if line.startswith("## "):
            flush(idx)
            phase = line[3:].strip()
    flush(len(lines))
    return tasks


DOR_REQUIRED_KEYS = ("Priority", "Size", "Depends on", "Agent")
VALID_PRIORITIES = frozenset({"P0", "P1", "P2", "P3"})
VALID_SIZES = frozenset({"S", "M", "L"})
VALID_AGENTS = frozenset({"auto", "claude", "cursor", "codex", "human"})
# Task provenance (SKILL-045). Optional — a missing `Source:` line means `planned`,
# so existing backlogs stay valid. `incident` is reactive post-release work and must
# name its `Incident:` (ref + severity); `monitoring` is proactive from a signal/trend;
# `owner` is owner-requested ops; `retro` is raised by ai-task-retro.
VALID_SOURCES = frozenset({"planned", "incident", "monitoring", "owner", "retro"})
# Severity → Priority convention for `Source: incident` tasks (documented, not enforced
# by DoR — severity is a judgment): sev1→P0, sev2→P1, sev3→P2, sev4→P3.
INCIDENT_SEVERITY_PRIORITY = {"sev1": "P0", "sev2": "P1", "sev3": "P2", "sev4": "P3"}


# SKILL-093: shared-contract classes whose cross-cutting REBUILD invariant lives
# OUTSIDE the changing task's own DoD -- a shared onboarding label set, a rebuild
# runbook, an operator checklist. Verify only checks that one task's own DoD, so a
# task that adds a new label / n8n node / endpoint / env var / wire format but never
# names the matching rebuild doc leaves a from-scratch rebuild silently broken.
# Named here in ONE place so the DoR reminder (below) and the verify completeness
# check (skills/verification-and-dod, skills/ai-wave-verify) are not guesswork.
# Motivating gaps (vps_2026, 2026-07-21): the `bug` label from AI-021 was never
# added to the 17-label onboarding set, and the operator-checklist owner-steps
# snapshot went stale -- neither was in any task's DoD, both found only by a
# dedicated from-scratch rebuild audit. Widens the AI-031 doc-policy ("docs updated
# in the same PR") from "docs" toward "restorable from scratch".
@dataclass(frozen=True)
class SharedContractClass:
    name: str
    change_cue: re.Pattern[str]  # task INTRODUCES/CHANGES this shared contract
    already_named: re.Pattern[str]  # DoD already names the matching rebuild doc
    rebuild_invariant: str  # what the DoD must require
    rebuild_doc: str  # the cross-cutting doc that must be rebuilt in the same PR
    # Extra token that must ALSO be present (lowercased text) for the class to fire.
    # Used to scope an ambiguous noun (e.g. "node" only counts inside an n8n context).
    context: re.Pattern[str] | None = None
    # Optional cue matched against the ORIGINAL-case text, for signals that are
    # case-carrying (an UPPER_SNAKE env var name is lost after `.lower()`).
    raw_cue: re.Pattern[str] | None = None


# Change verbs, shared by every class. `change|changes` covers wire-format edits;
# `define/gain` cover common label phrasings ("define a bug label", "the pipeline
# gains a needs-refinement label") the first cut missed.
_CONTRACT_VERBS = (
    r"new|add|adds|added|adding|introduce|introduces|introducing|create|creates|"
    r"creating|register|registers|expose|exposes|rename|renames|change|changes|"
    r"define|defines|defining|gain|gains"
)
# Result verbs (noun-then-verb order), a subset that reads as a completed change.
_CONTRACT_RESULT_VERBS = r"added|introduced|created|registered|renamed|changed|exposed|defined"


def _contract_change_cue(*nouns: str) -> re.Pattern[str]:
    """Match a change verb next to a shared-contract noun on the SAME line.

    Same-line proximity (``[^\\n]``) stops two unrelated sentences from combining
    into a false positive, mirroring the word-boundary discipline of the
    risk-keyword scan (TASKRUN-113): over-matching only costs one advisory WARN
    line, so the cues stay readable rather than exhaustive.
    """
    alt = "|".join(re.escape(noun) for noun in nouns)
    return re.compile(
        rf"\bnew\s+(?:{alt})\b"
        rf"|\b(?:{_CONTRACT_VERBS})\b[^\n]{{0,60}}\b(?:{alt})\b"
        rf"|\b(?:{alt})\b[^\n]{{0,60}}\b(?:{_CONTRACT_RESULT_VERBS})\b"
    )


# Phrases scrubbed (lowercased) before per-class matching, so a UI/accessibility
# "label" does not trip the onboarding-label class. Same shape as the risk-keyword
# BENIGN_RISK_COMPOUNDS scrub.
CONTRACT_CUE_SCRUB = ("aria-label", "aria label", "label component", "<label")

# A DoD that already names any rebuild doc, or explicitly marks the invariant
# not-applicable NEXT TO a rebuild/contract word, has imprinted the invariant --
# suppress the reminder. The not-applicable / n/a marker is anchored to the concept
# (not a bare token) so an unrelated "Estimate: n/a" cannot silence every class.
# This is the "OR explicitly marked not-applicable" escape hatch from the DoD.
REBUILD_SATISFIED_GENERIC = re.compile(
    r"rebuild (?:runbook|doc|docs|checklist)"
    r"|(?:rebuild|invariant|onboarding|contract)[^\n]{0,30}(?:not[- ]applicable|\bn/a\b)"
    r"|(?:not[- ]applicable|\bn/a\b)[^\n]{0,30}(?:rebuild|invariant|onboarding|contract)"
)

SHARED_CONTRACT_CLASSES: tuple[SharedContractClass, ...] = (
    SharedContractClass(
        name="label",
        change_cue=re.compile(
            r"\bnew label\b"
            rf"|\b(?:{_CONTRACT_VERBS})\b[^\n]{{0,60}}\blabels?\b"
            r"|\blabels?\b[^\n]{0,60}\b(?:added|introduced|created|registered|defined)\b"
            # Russian: waves are Russian (AI-037). "добавить/ввести/создать метку".
            r"|\b(?:добав|введ|созда|регистр)\w*[^\n]{0,40}\bметк\w*"
            r"|\bметк\w*[^\n]{0,40}\b(?:добав|введ|созда|регистр)\w*"
            r"|\bновая метка\b|\bновую метку\b"
        ),
        already_named=re.compile(
            r"\bonboarding label\b|\blabel onboarding\b|\blabel set\b"
            r"|\bonboarding\b[^\n]{0,30}\blabels?\b|\bнабор меток\b"
            r"|\bонбординг\w*[^\n]{0,20}метк"
        ),
        rebuild_invariant="add the new label to the repo's onboarding label set",
        rebuild_doc="the onboarding label set (canonical label-bootstrap list)",
    ),
    SharedContractClass(
        name="n8n node",
        change_cue=re.compile(
            r"\bn8n node\b"
            rf"|\b(?:{_CONTRACT_VERBS})\b[^\n]{{0,60}}\bnode\b"
            r"|\bnode\b[^\n]{0,60}\b(?:added|introduced|created|registered)\b"
        ),
        # "node" is generic (tree node, DOM node, Node.js in a CI workflow), so
        # require an explicit n8n context. A real n8n task names n8n.
        context=re.compile(r"\bn8n\b"),
        already_named=re.compile(r"\bworkflow rebuild\b|\bn8n[^\n]{0,20}runbook\b"),
        rebuild_invariant="add the node to the n8n workflow rebuild runbook",
        rebuild_doc="the n8n workflow rebuild runbook",
    ),
    SharedContractClass(
        name="endpoint",
        # Server-side sense only: bare "route" fires on frontend routers (React/Vue),
        # so require "endpoint" or an explicit "api/http/rest route".
        change_cue=_contract_change_cue(
            "endpoint", "api route", "http route", "rest route"
        ),
        already_named=re.compile(
            r"\bapi surface\b|\boperator checklist\b|\bendpoint list\b"
        ),
        rebuild_invariant="add the endpoint to the API-surface list / operator checklist",
        rebuild_doc="the API-surface list or operator rebuild checklist",
    ),
    SharedContractClass(
        name="env var",
        change_cue=re.compile(
            r"\bnew env[- ]?var\b"
            rf"|\b(?:{_CONTRACT_VERBS})\b[^\n]{{0,60}}"
            r"\b(?:env[- ]?var|environment variable)\b"
            r"|\b(?:env[- ]?var|environment variable)\b[^\n]{0,60}"
            r"\b(?:added|introduced)\b"
        ),
        # Bare UPPER_SNAKE var names (DATABASE_URL, REDIS_URL) survive only in the
        # original-case text; require an env/deploy/secret context to avoid firing
        # on arbitrary snake_case identifiers.
        raw_cue=re.compile(
            r"(?i:\benv\b|\benvironment\b|\bdeploy\b|\bsecrets?\b)[^\n]{0,40}"
            r"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b"
            r"|\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b[^\n]{0,40}"
            r"(?i:\benv\b|\benvironment\b|\bdeploy\b|\bsecrets?\b)"
        ),
        already_named=re.compile(
            r"\benv template\b|\benv\.example\b|\bdeploy env\b|\bsecret template\b"
            r"|\benvironment doc\b"
        ),
        rebuild_invariant="add the variable to the env template / deploy env doc",
        rebuild_doc="the env template (.env.example) or deploy env doc",
    ),
    SharedContractClass(
        name="wire format",
        change_cue=re.compile(
            r"\bnew (?:wire[- ]format|wire protocol|message schema|message format"
            r"|payload schema|payload format)\b"
            rf"|\b(?:{_CONTRACT_VERBS})\b[^\n]{{0,60}}"
            r"\b(?:wire[- ]format|on-the-wire|wire protocol|protocol version"
            r"|message schema|message format|json payload|message payload"
            r"|payload schema|payload format|serialization format)\b"
            r"|\b(?:wire[- ]format|on-the-wire|protocol version|message schema"
            r"|json payload|message payload|payload schema|serialization format)\b"
            r"[^\n]{0,60}\b(?:changed|added|introduced)\b"
        ),
        already_named=re.compile(
            r"\bprotocol (?:doc|spec|schema|runbook)\b|\bschema doc\b"
            r"|\bwire[- ]format (?:doc|spec)\b"
        ),
        rebuild_invariant="update the protocol/schema rebuild doc",
        rebuild_doc="the protocol/schema rebuild doc",
    ),
)


@dataclass(frozen=True)
class DorGap:
    task_id: str
    field: str
    reason: str
    action: str | None = None

    def as_dict(self) -> dict[str, str]:
        payload = {"task_id": self.task_id, "field": self.field, "reason": self.reason}
        if self.action is not None:
            payload["action"] = self.action
        return payload


def task_block_lines(task: Task) -> list[str]:
    return task.block.splitlines()


def task_has_metadata_line(task: Task, key: str) -> bool:
    prefix = f"{key}:"
    for line in task_block_lines(task)[1:]:
        if line.startswith(prefix):
            return True
    return False


def collect_unparsed_checkbox_gaps(
    backlog_lines: list[str],
    *,
    task_id: str | None = None,
) -> list[DorGap]:
    """Flag backlog checkbox lines that look like tasks but do not match TASK_RE."""
    gaps: list[DorGap] = []
    for lineno, line in enumerate(backlog_lines, 1):
        checkbox = CHECKBOX_LINE_RE.match(line)
        if not checkbox:
            continue
        if TASK_RE.match(line):
            continue
        rest = checkbox.group("rest").strip()
        if not rest:
            gaps.append(
                DorGap(
                    "(backlog)",
                    "Task id",
                    f"line {lineno}: checkbox line has no task id or title",
                    action="fix_task_id_format",
                )
            )
            continue
        token = rest.split(None, 1)[0]
        if not TASK_ID_PREFIX_RE.match(token):
            continue
        if task_id is not None and token != task_id:
            continue
        if TASK_ID_TOKEN_RE.match(token):
            reason = (
                f"line {lineno}: task id {token!r} must be followed by a short title "
                "(expected: - [ ] PREFIX-123 Title)"
            )
        else:
            reason = (
                f"line {lineno}: task id {token!r} must end with digits only "
                "(e.g. BUG-003, not BUG-B1); put batch labels in the title"
            )
        gaps.append(DorGap(token, "Task id", reason, action="fix_task_id_format"))
    return gaps


def collect_dor_gaps(
    tasks: list[Task],
    *,
    open_only: bool = True,
    task_id: str | None = None,
    backlog_lines: list[str] | None = None,
) -> list[DorGap]:
    gaps: list[DorGap] = []
    if backlog_lines is not None:
        gaps.extend(collect_unparsed_checkbox_gaps(backlog_lines, task_id=task_id))
    known_ids = {task.id for task in tasks}
    for task in tasks:
        if open_only and not task.is_open:
            continue
        if task_id is not None and task.id != task_id:
            continue
        for key in DOR_REQUIRED_KEYS:
            if not task_has_metadata_line(task, key):
                gaps.append(
                    DorGap(task.id, key, f"missing {key}: line in backlog block")
                )
        if (
            task_has_metadata_line(task, "Priority")
            and task.priority not in VALID_PRIORITIES
        ):
            gaps.append(
                DorGap(
                    task.id, "Priority", f"invalid value {task.priority!r} (use P0–P3)"
                )
            )
        if task_has_metadata_line(task, "Size") and task.size not in VALID_SIZES:
            gaps.append(
                DorGap(
                    task.id,
                    "Size",
                    (
                        f"invalid value {task.size!r} (use S, M, or L only; "
                        "XL+ requires product split into S/M child tasks before delivery)"
                    ),
                    action="split_required",
                )
            )
        if task_has_metadata_line(task, "Agent") and task.agent not in VALID_AGENTS:
            gaps.append(DorGap(task.id, "Agent", f"invalid value {task.agent!r}"))
        # Provenance validation (SKILL-045). `Source:` is optional but must be a known
        # value when present; a `Source: incident` task must name its `Incident:` so
        # post-release work is traceable to the signal that raised it.
        if task_has_metadata_line(task, "Source") and task.source not in VALID_SOURCES:
            gaps.append(
                DorGap(
                    task.id,
                    "Source",
                    (
                        f"invalid value {task.source!r} "
                        "(use planned, incident, monitoring, owner, or retro)"
                    ),
                )
            )
        if task.source == "incident" and not task.incident.strip():
            gaps.append(
                DorGap(
                    task.id,
                    "Incident",
                    "Source: incident requires an Incident: line (ref + severity, "
                    "e.g. 'Incident: INC-2026-07-13 sev1 (heartbeat flatline)')",
                    action="add_incident_ref",
                )
            )
        for dep in task.depends_on:
            if dep not in known_ids:
                gaps.append(
                    DorGap(task.id, "Depends on", f"unknown dependency {dep!r}")
                )
        if task.priority in {"P0", "P1"} and "risk:" not in task.block.lower():
            gaps.append(
                DorGap(
                    task.id,
                    "Task Context",
                    f"{task.priority} requires Risk: acknowledgment in the task block",
                )
            )
    return gaps


@dataclass(frozen=True)
class RebuildInvariantReminder:
    task_id: str
    contract_class: str
    rebuild_invariant: str
    rebuild_doc: str

    def as_dict(self) -> dict[str, str]:
        return {
            "task_id": self.task_id,
            "contract_class": self.contract_class,
            "rebuild_invariant": self.rebuild_invariant,
            "rebuild_doc": self.rebuild_doc,
        }


def rebuild_invariant_reminders_for_task(task: Task) -> list[RebuildInvariantReminder]:
    """SKILL-093: shared-contract changes whose rebuild invariant is not yet in the DoD.

    A heuristic reminder, never a blocking DoR gap: the task text signals a change to a
    shared contract, but neither the Task Context nor the DoD names the matching
    cross-cutting rebuild doc. Keyword-driven, so it WARNs like the privacy/dependency
    scans rather than blocking -- a keyword false positive must not gate delivery (the
    lesson of TASKRUN-113). Mark the invariant not-applicable in the block to silence it.
    """
    raw = f"{task.title}\n{task.block}"
    text = raw.lower()
    for phrase in CONTRACT_CUE_SCRUB:
        text = text.replace(phrase, " ")
    reminders: list[RebuildInvariantReminder] = []
    for contract in SHARED_CONTRACT_CLASSES:
        hit = bool(contract.change_cue.search(text))
        if not hit and contract.raw_cue is not None:
            hit = bool(contract.raw_cue.search(raw))
        if not hit:
            continue
        if contract.context is not None and not contract.context.search(text):
            continue
        if contract.already_named.search(text) or REBUILD_SATISFIED_GENERIC.search(text):
            continue
        reminders.append(
            RebuildInvariantReminder(
                task.id,
                contract.name,
                contract.rebuild_invariant,
                contract.rebuild_doc,
            )
        )
    return reminders


def collect_rebuild_invariant_reminders(
    tasks: list[Task],
    *,
    open_only: bool = True,
    task_id: str | None = None,
) -> list[RebuildInvariantReminder]:
    reminders: list[RebuildInvariantReminder] = []
    for task in tasks:
        if open_only and not task.is_open:
            continue
        if task_id is not None and task.id != task_id:
            continue
        reminders.extend(rebuild_invariant_reminders_for_task(task))
    return reminders


def format_rebuild_invariant_reminders(
    reminders: list[RebuildInvariantReminder],
) -> str | None:
    """One 'rebuild invariant missing' soft note for `dor` (not a DoR gap), or None."""
    if not reminders:
        return None
    lines = [
        (
            "shared-contract rebuild invariants missing from DoD (SKILL-093; advisory, "
            "not a DoR gap -- imprint into the DoD or mark not-applicable):"
        )
    ]
    for rem in reminders:
        lines.append(
            f"- {rem.task_id}: {rem.contract_class} change -- {rem.rebuild_invariant} "
            f"(rebuild doc: {rem.rebuild_doc})"
        )
    return "\n".join(lines)


def dor_gaps_for_root(
    root: Path,
    *,
    open_only: bool = True,
    task_id: str | None = None,
) -> list[DorGap]:
    tasks = parse_backlog(root)
    task_files = store_task_files(root)
    if task_files:
        # File-per-task store (TASKRUN-142): malformed checkbox lines live in
        # the task files now; the generated index is never scanned for tasks.
        gaps: list[DorGap] = []
        for task_file in task_files:
            gaps.extend(
                collect_unparsed_checkbox_gaps(
                    task_file.read_text(encoding="utf-8").splitlines(),
                    task_id=task_id,
                )
            )
        gaps.extend(collect_dor_gaps(tasks, open_only=open_only, task_id=task_id))
        return gaps
    backlog_path = root / "BACKLOG.md"
    lines = backlog_path.read_text(encoding="utf-8").splitlines()
    return collect_dor_gaps(
        tasks,
        open_only=open_only,
        task_id=task_id,
        backlog_lines=lines,
    )


def print_dor_gaps(gaps: list[DorGap], *, as_json: bool = False) -> None:
    if as_json:
        print(json.dumps([gap.as_dict() for gap in gaps], indent=2))
        return
    if not gaps:
        print("DoR: all checked tasks passed.")
        return
    print("DoR failures:")
    for gap in gaps:
        print(f"- {gap.task_id} | {gap.field} | {gap.reason}")


def enforce_dor_gaps(gaps: list[DorGap]) -> None:
    if not gaps:
        return
    print_dor_gaps(gaps)
    die("DoR check failed", 1)


def risk_gates(task: Task, policy: dict[str, Any]) -> list[str]:
    gates: list[str] = []
    high_priority = set(policy.get("review", {}).get("high_priority", ["P0", "P1"]))
    if task.priority in high_priority:
        gates.append(f"high-priority:{task.priority}")
    lowered = f"{task.title}\n{task.block}".lower()
    if policy.get("review", {}).get("require_for_risk_keywords", True):
        # TASKRUN-113: scrub benign compounds first (so "error contract" cannot
        # expose a bare "contract"), then match risk words on word boundaries.
        scrubbed = lowered
        for compound in BENIGN_RISK_COMPOUNDS:
            scrubbed = scrubbed.replace(compound, " ")
        for word, pattern in RISK_WORD_PATTERNS:
            if pattern.search(scrubbed):
                gates.append(f"risk-keyword:{word}")
                break
    return gates


# ===========================================================================
# ai_task/backlog_store.py (bundled verbatim, intra-package imports stripped)
# ===========================================================================
"""Backlog store tool (TASKRUN-142): file-per-task migration and index.

One tool owns the whole storage layout so the pieces cannot drift apart:

- ``split``       one-time migration: move every inline BACKLOG.md task block
                  into ``backlog/tasks/<TASK-ID>.md`` (phase recorded as a
                  leading ``## <phase>`` heading, block bytes preserved),
                  extract the non-task lines into ``backlog/index-skeleton.md``
                  and regenerate the index.
- ``regenerate``  rebuild BACKLOG.md as a read-only index: the skeleton's
                  header lines and phase headings/preambles, plus one-liner
                  entries per task (checkbox, linked id, title). The one-liner
                  format ``- [x] [ID](backlog/tasks/ID.md) Title`` is chosen so
                  the canonical block parser cannot mistake an index entry for
                  a task block (TASK_RE requires the bare id right after the
                  checkbox).
- ``check``       fail (exit 1) when BACKLOG.md differs from a fresh
                  regeneration - the hand-edit guard used by tests and
                  scripts/check-delivery-artifacts.py.
- ``rotate``      backlog hygiene on the new layout: move every closed
                  (``- [x]``) task file to ``backlog/archive/tasks/`` verbatim,
                  regenerate the index and refresh the id registry. Open and
                  deferred files stay put; nothing is renumbered.
- ``guard``       write/refresh the TRACKED CI index guard
                  ``scripts/backlog-index-guard.py`` (TASKRUN-145), so the
                  hand-edit guard also runs in a consuming repo's CI, where
                  this tool - vendored under gitignored ``.ai-task/`` - does
                  not exist. ``--check`` exits 1 when that tracked copy is
                  missing, stale against these modules, or hand-edited.
                  ``split`` writes it as part of the migration.

The generated index carries a STATIC marker line naming the regeneration
command. Deliberately no content hash in the marker: a hash line changes on
every regeneration, which would make every pair of concurrent index updates a
guaranteed merge conflict - the exact failure this store removes. Drift is
detected by ``check`` byte-comparing the file against a fresh regeneration
instead. Any conflict that still lands in the index resolves mechanically:
merge the task files (distinct paths merge clean by construction), take either
side of BACKLOG.md, then run ``regenerate`` - never hand-edit the index.

Contract: docs/ai-task-backlog-contract.md. Layout decision: ADR/007.
"""


import argparse
import hashlib
import re
import shutil
import subprocess
import sys
from pathlib import Path


try:  # TASKRUN-145: optional by construction.
    # The tracked CI guard (scripts/backlog-index-guard.py) is generated by
    # bundling THIS module, and the bundle carries no ai_task package - so
    # inside the guard this import fails and guard generation degrades to
    # "unavailable" instead of exploding. Every other layout (profile
    # checkout, vendored .ai-task/scripts/) resolves it normally.
    from ai_task.index_guard import guard_status, write_guard
except ImportError:  # pragma: no cover - only inside the generated guard
    guard_status = None
    write_guard = None

SKELETON_REL = "backlog/index-skeleton.md"
TASKS_REL = "backlog/tasks"
ARCHIVE_TASKS_REL = "backlog/archive/tasks"

# Where this tool can live, most-likely-vendored first (the TASKRUN-140
# lesson: a generated header must not name a path that only resolves inside
# the using-ai profile). Consuming repos that migrate get the wrapper under
# ``.ai-task/scripts/``; the using-ai profile runs ``scripts/backlog-store.py``.
GENERATOR_RELS = (
    ".ai-task/scripts/backlog-store.py",
    "scripts/backlog-store.py",
)

# A generated-index task entry. Deliberately NOT parseable by TASK_RE (the id
# sits inside a markdown link), so the index can never be read as task blocks.
INDEX_TASK_LINE_RE = re.compile(
    r"^- \[(?P<status>[ x~])\] \[(?P<id>[A-Z][A-Z0-9-]*-\d+)\]"
    r"\((?P<path>[^)]+)\)(?:\s+(?P<title>.*))?$"
)
MARKER_PREFIX = "<!-- Generated index (backlog-store)."

_TASK_ID_SORT_RE = re.compile(r"^(?P<prefix>[A-Z][A-Z0-9-]*)-(?P<num>\d+)$")


def generator_rel(repo: Path) -> str:
    for rel in GENERATOR_RELS:
        if (repo / rel).is_file():
            return rel
    return GENERATOR_RELS[0]


def index_line(task: Task) -> str:
    return f"- [{task.status}] [{task.id}]({TASKS_REL}/{task.id}.md) {task.title}"


def is_marker_line(line: str) -> bool:
    return line.startswith(MARKER_PREFIX)


def _task_sort_key(task: Task) -> tuple[str, int, int]:
    match = _TASK_ID_SORT_RE.match(task.id)
    if match is None:  # pragma: no cover - TASK_RE already enforces the shape
        return (task.id, 0, task.index)
    return (match.group("prefix"), int(match.group("num")), task.index)


def content_hash(repo: Path) -> str:
    """sha256 over the index inputs (skeleton + task-file set).

    Reported by ``check`` diagnostics and available to external tooling; NOT
    embedded in the generated file (see the module docstring: a per-content
    hash line would turn every concurrent regeneration into a merge conflict).
    """
    digest = hashlib.sha256()
    skeleton = repo / SKELETON_REL
    digest.update(skeleton.read_bytes() if skeleton.exists() else b"")
    for task_file in store_task_files(repo):
        digest.update(b"\0")
        digest.update(task_file.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(task_file.read_bytes())
    return digest.hexdigest()


def _normalize_lines(lines: list[str]) -> list[str]:
    """Strip trailing whitespace, collapse blank runs, trim the edges."""
    out: list[str] = []
    for raw in lines:
        line = raw.rstrip()
        if not line and out and not out[-1]:
            continue
        out.append(line)
    while out and not out[0]:
        out.pop(0)
    while out and not out[-1]:
        out.pop()
    return out


def build_index(repo: Path) -> str:
    """Render BACKLOG.md from the skeleton plus the per-task store."""
    skeleton_path = repo / SKELETON_REL
    if not skeleton_path.exists():
        die(f"{SKELETON_REL} not found in {repo} - run `split` first")
    tasks = parse_task_files(repo)
    if not tasks:
        die(f"no task files under {TASKS_REL}/ in {repo} - nothing to index")

    by_phase: dict[str, list[Task]] = {}
    phase_order: list[str] = []
    for task in tasks:
        if task.phase not in by_phase:
            by_phase[task.phase] = []
            phase_order.append(task.phase)
        by_phase[task.phase].append(task)
    for rows in by_phase.values():
        rows.sort(key=_task_sort_key)

    marker = (
        f"{MARKER_PREFIX} Do not edit by hand: task blocks live in "
        f"{TASKS_REL}/<TASK-ID>.md; edit those, then run "
        f"`python {generator_rel(repo)} regenerate`. Drift fails "
        f"`{Path(generator_rel(repo)).name} check` and the test suite. -->"
    )

    out: list[str] = []
    emitted: set[str] = set()
    current_phase: str | None = None

    def flush(phase: str | None) -> None:
        if phase is None or phase in emitted:
            return
        rows = by_phase.get(phase)
        if not rows:
            return
        emitted.add(phase)
        out.append("")
        for task in rows:
            out.append(index_line(task))
        out.append("")

    skeleton_lines = skeleton_path.read_text(encoding="utf-8").splitlines()
    for lineno, line in enumerate(skeleton_lines):
        if line.startswith("## "):
            flush(current_phase)
            current_phase = line[3:].strip()
        out.append(line)
        if lineno == 0 and line.startswith("# "):
            out.extend(["", marker])
    if not skeleton_lines or not skeleton_lines[0].startswith("# "):
        out = [marker, ""] + out
    flush(current_phase)

    # Phases the skeleton does not know yet (a task file created with a new
    # `## <phase>` heading): append them so no task can vanish from the index.
    for phase in phase_order:
        if phase in emitted or not by_phase.get(phase):
            continue
        out.append("")
        out.append(f"## {phase}" if phase else "## Unphased")
        flush(phase)

    return "\n".join(_normalize_lines(out)) + "\n"


def regenerate(repo: Path) -> Path:
    index_path = repo / "BACKLOG.md"
    index_path.write_text(build_index(repo), encoding="utf-8")
    return index_path


def check(repo: Path) -> list[str]:
    """Hand-edit / staleness guard. Returns problems; [] means fresh."""
    index_path = repo / "BACKLOG.md"
    if not (repo / SKELETON_REL).exists():
        return []  # not migrated - nothing to guard
    if not index_path.exists():
        return [f"BACKLOG.md missing in {repo}; run `regenerate`"]
    current = index_path.read_text(encoding="utf-8")
    expected = build_index(repo)
    if current == expected:
        return []
    current_lines = current.splitlines()
    expected_lines = expected.splitlines()
    detail = ""
    for lineno, (have, want) in enumerate(zip(current_lines, expected_lines), 1):
        if have != want:
            detail = f" (first difference at line {lineno}: {have!r} != {want!r})"
            break
    else:
        detail = (
            f" (line count {len(current_lines)} != {len(expected_lines)})"
        )
    problem = (
        "BACKLOG.md drifted from regeneration - it is a generated index, "
        "edit backlog/tasks/<TASK-ID>.md (or the skeleton) and run "
        f"`python {generator_rel(repo)} regenerate`{detail}"
    )
    return [problem]


def _block_ranges(lines: list[str]) -> list[tuple[int, int, str, str]]:
    """(start, end, task_id, phase) for every inline task block."""
    ranges: list[tuple[int, int, str, str]] = []
    phase = ""
    start: int | None = None
    task_id = ""
    block_phase = ""

    def flush(end: int) -> None:
        nonlocal start
        if start is not None:
            ranges.append((start, end, task_id, block_phase))
        start = None

    for idx, line in enumerate(lines):
        match = TASK_RE.match(line)
        if match:
            flush(idx)
            start = idx
            task_id = match.group("id")
            block_phase = phase
            continue
        if line.startswith("## "):
            flush(idx)
            phase = line[3:].strip()
    flush(len(lines))
    return ranges


def split(repo: Path) -> dict[str, int]:
    """One-time migration: inline BACKLOG.md -> per-task files + skeleton."""
    backlog_path = repo / "BACKLOG.md"
    if not backlog_path.exists():
        die(f"BACKLOG.md not found in {repo}")
    if store_task_files(repo):
        die(
            f"{TASKS_REL}/ already holds task files in {repo}; split runs "
            "once, on an inline BACKLOG.md"
        )
    lines = backlog_path.read_text(encoding="utf-8").splitlines()
    ranges = _block_ranges(lines)
    if not ranges:
        die(f"no inline task blocks found in {backlog_path} - nothing to split")
    seen: dict[str, int] = {}
    for start, _end, task_id, _phase in ranges:
        if task_id in seen:
            die(
                f"duplicate task id {task_id} in {backlog_path} "
                f"(lines {seen[task_id] + 1} and {start + 1}); fix before split"
            )
        seen[task_id] = start

    tasks_dir = repo / TASKS_REL
    tasks_dir.mkdir(parents=True, exist_ok=True)
    covered: set[int] = set()
    for start, end, task_id, phase in ranges:
        covered.update(range(start, end))
        block_lines = list(lines[start:end])
        while block_lines and not block_lines[-1].strip():
            block_lines.pop()
        heading = f"## {phase}\n\n" if phase else ""
        (tasks_dir / f"{task_id}.md").write_text(
            heading + "\n".join(block_lines) + "\n", encoding="utf-8"
        )

    skeleton_lines = [
        line for idx, line in enumerate(lines) if idx not in covered
    ]
    (repo / SKELETON_REL).write_text(
        "\n".join(_normalize_lines(skeleton_lines)) + "\n", encoding="utf-8"
    )
    regenerate(repo)
    return {"tasks": len(ranges)}


def _registry_helper(repo: Path) -> Path | None:
    for rel in (
        ".ai-task/scripts/backlog-id-registry.py",
        "scripts/backlog-id-registry.py",
    ):
        candidate = repo / rel
        if candidate.is_file():
            return candidate
    return None


def refresh_registry(repo: Path, reason: str) -> bool:
    helper = _registry_helper(repo)
    if helper is None:
        print(
            "warning: backlog-id-registry.py not found (run `ai-task init` "
            "to vendor it); id registry NOT refreshed",
            file=sys.stderr,
        )
        return False
    subprocess.run(
        [
            sys.executable,
            str(helper),
            "--repo",
            str(repo),
            "update",
            "--reason",
            reason,
        ],
        check=False,
    )
    return True


def rotate(repo: Path, *, dry_run: bool = False) -> dict[str, int]:
    """Move closed task files to the archive dir, regenerate, refresh registry."""
    tasks = parse_task_files(repo)
    if not tasks:
        die(f"no task files under {TASKS_REL}/ in {repo} - nothing to rotate")
    closed = [task for task in tasks if task.status == "x"]
    open_count = sum(1 for task in tasks if task.status == " ")
    deferred_count = sum(1 for task in tasks if task.status == "~")
    counts = {
        "closed": len(closed),
        "open": open_count,
        "deferred": deferred_count,
    }
    print(
        f"rotation preview: {len(closed)} closed [x] -> {ARCHIVE_TASKS_REL}/, "
        f"{open_count} open and {deferred_count} deferred staying in {TASKS_REL}/"
    )
    if dry_run or not closed:
        return counts
    archive_dir = repo / ARCHIVE_TASKS_REL
    archive_dir.mkdir(parents=True, exist_ok=True)
    moves: list[tuple[Path, Path]] = []
    for task in closed:
        src = repo / TASKS_REL / f"{task.id}.md"
        dest = archive_dir / f"{task.id}.md"
        if dest.exists():
            die(f"refusing rotation: {dest} already exists (id reuse?)")
        moves.append((src, dest))
    for src, dest in moves:
        shutil.move(str(src), str(dest))
        print(f"archived {src.relative_to(repo)} -> {dest.relative_to(repo)}")
    regenerate(repo)
    refresh_registry(
        repo,
        f"rotation: {len(closed)} closed task file(s) -> {ARCHIVE_TASKS_REL}/",
    )
    return counts


def refresh_tracked_guard(repo: Path) -> tuple[Path, str] | None:
    """Write/refresh the tracked CI index guard; None when unavailable.

    The guard (TASKRUN-145) is the one tracked piece of store tooling: the
    vendored tool lives under gitignored ``.ai-task/``, so without it a
    consumer's CI has nothing to run. Unavailable only inside the generated
    guard itself, which cannot regenerate itself.
    """
    if write_guard is None:  # pragma: no cover - only inside the generated guard
        return None
    return write_guard(repo)


def archive_store_files(repo: Path) -> list[Path]:
    """Alias for audit callers that only import the store tool."""
    return archive_task_files(repo)


def store_has_index(repo: Path) -> bool:
    return (repo / SKELETON_REL).exists()


def _parse_file_blocks(path: Path) -> list[Task]:
    return parse_backlog_blocks(path.read_text(encoding="utf-8").splitlines())


def _report_guard(repo: Path, change: tuple[Path, str] | None) -> None:
    if change is None:
        return
    dest, action = change
    rel = dest.relative_to(repo)
    if action == "unchanged":
        print(f"tracked index guard already current: {rel}")
        return
    print(
        f"{action} {rel} - TRACKED on purpose: commit it, then run "
        f"`python3 {rel} check` in this repo's CI (TASKRUN-145)"
    )


def _guard_cmd(repo: Path, *, check_only: bool) -> int:
    if write_guard is None or guard_status is None:  # pragma: no cover
        print(
            "error: this copy of the store cannot generate the guard (it IS "
            "the generated guard); run the vendored .ai-task/scripts/"
            "backlog-store.py instead",
            file=sys.stderr,
        )
        return 2
    if check_only:
        state, message = guard_status(repo)
        print(message, file=sys.stdout if state == "fresh" else sys.stderr)
        return 0 if state == "fresh" else 1
    _report_guard(repo, write_guard(repo))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "File-per-task backlog store: split BACKLOG.md, regenerate the "
            "read-only index, rotate closed task files (TASKRUN-142)."
        )
    )
    parser.add_argument(
        "--repo", default=".", help="Repository root (default: current directory)"
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("split", help="One-time migration of inline BACKLOG.md")
    sub.add_parser("regenerate", help="Rebuild the BACKLOG.md index from the store")
    sub.add_parser("check", help="Exit 1 when BACKLOG.md drifted from regeneration")
    p_rotate = sub.add_parser(
        "rotate", help="Move closed task files to backlog/archive/tasks/"
    )
    p_rotate.add_argument(
        "--dry-run", action="store_true", help="Preview counts, write nothing"
    )
    p_guard = sub.add_parser(
        "guard", help="Write/refresh the TRACKED CI index guard (TASKRUN-145)"
    )
    p_guard.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 when the tracked guard is missing, stale, or hand-edited",
    )
    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve()
    if not repo.exists():
        print(f"error: repo path does not exist: {repo}", file=sys.stderr)
        return 2

    if args.command == "split":
        counts = split(repo)
        print(
            f"split {counts['tasks']} task block(s) into {TASKS_REL}/, wrote "
            f"{SKELETON_REL} and regenerated BACKLOG.md"
        )
        refresh_registry(repo, "file-per-task migration (backlog-store split)")
        _report_guard(repo, refresh_tracked_guard(repo))
        return 0
    if args.command == "guard":
        return _guard_cmd(repo, check_only=args.check)
    if args.command == "regenerate":
        path = regenerate(repo)
        print(f"regenerated {path}")
        return 0
    if args.command == "check":
        problems = check(repo)
        if problems:
            for problem in problems:
                print(problem, file=sys.stderr)
            return 1
        print("BACKLOG.md matches regeneration.")
        return 0
    # rotate
    rotate(repo, dry_run=args.dry_run)
    return 0


# ===========================================================================
# generated guard CLI (TASKRUN-145)
# ===========================================================================

# sha256 over the bundled module sources plus the generator templates. The
# store's `guard --check` recomputes it from the local modules, so a copy that
# fell behind the profile - or was hand-edited - is detected, not trusted.
GUARD_SOURCE_SHA256 = "10ade699962a8b33d1efb3618924c16e479fd71ec9dacbd4a93262e65916c782"
GUARD_REL = "scripts/backlog-index-guard.py"


def guard_main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog=Path(GUARD_REL).name,
        description=(
            "Backlog index guard: verify the generated BACKLOG.md against a "
            "fresh regeneration from backlog/tasks/ (TASKRUN-145). Generated "
            "file - refresh it with the backlog store's `guard` command."
        ),
    )
    parser.add_argument(
        "--repo", default=".", help="Repository root (default: current directory)"
    )
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("check", help="Exit 1 when BACKLOG.md drifted (default; CI gate)")
    sub.add_parser("regenerate", help="Rebuild BACKLOG.md from backlog/tasks/")
    sub.add_parser("source-hash", help="Print the digest of the bundled sources")
    args = parser.parse_args(argv)

    if (args.command or "check") == "source-hash":
        print(GUARD_SOURCE_SHA256)
        return 0

    repo = Path(args.repo).resolve()
    if not repo.exists():
        print(f"error: repo path does not exist: {repo}", file=sys.stderr)
        return 2
    if (args.command or "check") == "regenerate":
        print(f"regenerated {regenerate(repo)}")
        return 0

    if not (repo / SKELETON_REL).exists():
        print(
            f"{SKELETON_REL} absent: {repo} is not on the file-per-task store, "
            "so BACKLOG.md is not a generated index - nothing to guard."
        )
        return 0
    problems = check(repo)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        # The problem text names the store tool, which lives in the gitignored
        # `.ai-task/` tree - right for the operator who will fix this locally,
        # absent for whoever is reading a CI log. Name the fix that works from
        # a plain checkout too.
        print(
            f"fix: edit backlog/tasks/<TASK-ID>.md, then run `python3 "
            f"{GUARD_REL} regenerate` (works from any checkout) and commit "
            "the regenerated index.",
            file=sys.stderr,
        )
        return 1
    print("BACKLOG.md matches regeneration.")
    return 0


if __name__ == "__main__":
    sys.exit(guard_main())
