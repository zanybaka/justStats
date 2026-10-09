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
Source digest: sha256:e224d782a6f7a81f72626bb5691b6ee1d77cee17344a4793ec48b28340e8db5c (bundle format 2).
"""

# Inert to linters and formatters BY CONSTRUCTION (TASKRUN-146), so a repo that
# vendors this file needs no lint configuration of its own. Flattening leaves
# artifacts that are correct for a bundle and meaningless as project debt: each
# bundled module keeps its own stdlib imports, so the same import repeats and
# sits mid-file, and the code is formatted to the profile's width rather than
# this repo's. Suppress here rather than rewriting the code: the guard's whole
# value is being the store's own code byte-for-byte, and a bundler that also
# reformats would be a second thing to trust.
# ruff: noqa
# flake8: noqa
# pylint: skip-file
# fmt: off

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


# Checkbox states. ``c`` is the negative terminal added by TASKRUN-144: work
# that was dropped, not paused. It is ONE marker, not one per reason - duplicate
# and won't-fix are written on the required ``Canceled:`` line instead of each
# earning a checkbox, because every extra done-like state has to be taught to
# selection, rotation and analytics to buy information a reason string already
# carries.
TASK_STATUSES = " x~c"
CANCELED_STATUS = "c"
_STATUS_CLASS = f"[{TASK_STATUSES}]"

TASK_RE = re.compile(
    rf"^- \[(?P<status>{_STATUS_CLASS})\]\s+(?P<id>[A-Z][A-Z0-9-]*-\d+)\s+"
    r"(?P<title>.+?)\s*$"
)
CHECKBOX_LINE_RE = re.compile(
    rf"^- \[(?P<status>{_STATUS_CLASS})\]\s+(?P<rest>.+?)\s*$"
)
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

    @property
    def is_canceled(self) -> bool:
        """Dropped work (TASKRUN-144). Never selected, archived like done.

        Distinct from deferred on purpose: ``- [~]`` means paused with intent
        and stays in the active file, ``- [c]`` means it will not be done and
        the reason is on the block.
        """
        return self.status == CANCELED_STATUS


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


# The numbered archives rotation wrote before the file-per-task store existed.
LEGACY_ARCHIVE_GLOB = "backlog/archive/BACKLOG-*.md"


def archive_id_sources(root: Path) -> tuple[list[Path], list[Path]]:
    """(legacy numbered archives, archived per-task files).

    The rotated-out half of known_id_sources, named once so the id scan and
    the done-id scan below read the same files (TASKRUN-154). A legacy
    backlog/archive/BACKLOG-NNN.md holds many task blocks; an archived
    backlog/archive/tasks/<TASK-ID>.md holds one.
    """
    return sorted(root.glob(LEGACY_ARCHIVE_GLOB)), archive_task_files(root)


def known_id_sources(root: Path) -> tuple[list[Path], list[Path]]:
    """(text files holding task blocks, task files named by their id).

    The same sources scripts/backlog-id-registry.py derives its floors from:
    BACKLOG.md and the legacy archives are read as text, the active and archived
    task dirs by filename. The registry is a standalone vendored script and this
    module is bundled into the tracked CI guard, so neither can import the
    other; tests/test_backlog_store_add.py pins the two source lists together
    instead, so "known" cannot mean one thing to id allocation and another to
    the dependency check (TASKRUN-153).
    """
    legacy_archives, archived_tasks = archive_id_sources(root)
    text_sources: list[Path] = []
    active = root / "BACKLOG.md"
    if active.exists():
        text_sources.append(active)
    text_sources.extend(legacy_archives)
    return text_sources, [*store_task_files(root), *archived_tasks]


def archived_done_ids(root: Path) -> set[str]:
    """Ids of tasks rotation archived as done (`- [x]`).

    The done half of what known_task_ids knows: an archived id is out of the
    active store, so the scheduler cannot see it at all and an open task that
    depends on it waits forever (TASKRUN-154). Rotation archives both terminal
    states, so the blocks are read for their checkbox instead of taking the id
    alone: a canceled (`- [c]`) task was dropped, not delivered, and must keep
    blocking its dependent (TASKRUN-144). A block that does not parse
    contributes nothing, which keeps the dependent blocked rather than
    unblocking it on a file nobody can read.
    """
    legacy_archives, archived_tasks = archive_id_sources(root)
    done: set[str] = set()
    for path in (*legacy_archives, *archived_tasks):
        lines = path.read_text(encoding="utf-8").splitlines()
        done.update(
            task.id for task in parse_backlog_blocks(lines) if task.status == "x"
        )
    return done


def known_task_ids(root: Path) -> set[str]:
    """Every task id this repo has filed: active, archived, legacy-archived.

    What a `Depends on:` may name. Deliberately wider than what delivery reads:
    a dependency on closed work that rotation already moved out is still a real
    dependency, not a typo.
    """
    text_sources, id_files = known_id_sources(root)
    ids = {path.stem for path in id_files if TASK_ID_TOKEN_RE.match(path.stem)}
    for path in text_sources:
        lines = path.read_text(encoding="utf-8").splitlines()
        ids.update(task.id for task in parse_backlog_blocks(lines))
    return ids


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
                # The defaults below are read-time fallbacks for blocks written
                # before the metadata was required, and they are the reason
                # `backlog-order` once reported `"priority": "P2"` for a block
                # that never said P2. They stay for those older blocks, but the
                # store path can no longer reach them: `backlog-store.py check`
                # and `backlog-order` both refuse an open block that omits what
                # the scheduler acts on, so nothing is scheduled on a value
                # nobody wrote (TASKRUN-151).
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
VALID_AGENTS = frozenset({"auto", "claude", "cursor", "codex", "devin", "human"})
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
    return any(line.startswith(prefix) for line in task_block_lines(task)[1:])


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
    extra_known_ids: set[str] | None = None,
) -> list[DorGap]:
    gaps: list[DorGap] = []
    if backlog_lines is not None:
        gaps.extend(collect_unparsed_checkbox_gaps(backlog_lines, task_id=task_id))
    # `extra_known_ids` (TASKRUN-153): ids that exist outside `tasks`. The store
    # validates a single new block before writing it, and with only that block
    # as `tasks` every dependency it names looked unknown.
    known_ids = {task.id for task in tasks} | (extra_known_ids or set())
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
- ``add``         write ONE new ``backlog/tasks/<TASK-ID>.md`` from arguments,
                  then refresh the id registry, then regenerate the index - in
                  that order, because the registry helper rewrites the
                  skeleton's ``next ids:`` line and the index is a projection
                  of that skeleton (TASKRUN-148). Refuses an id that already
                  has a file, a phase heading the skeleton does not declare
                  (see ``--new-phase``), any metadata ``check`` rejects, and a
                  tree where no registry helper is reachable - neither in the
                  repo nor beside this tool (TASKRUN-160) - so a refused add
                  leaves no file, no moved floor, no new index.
- ``check``       fail (exit 1) on three things, not one (TASKRUN-151):
                  BACKLOG.md differing from a fresh regeneration (the hand-edit
                  guard used by tests and scripts/check-delivery-artifacts.py),
                  a task filed under a phase heading the skeleton never
                  declared, and an open block missing the metadata the
                  scheduler acts on. Drift alone was never enough - a mistyped
                  heading and a metadata-free block both reproduce byte for
                  byte through a regeneration, leaving the index
                  self-consistent and wrong at the same time.
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
import difflib
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

# Where this tool can live. The TASKRUN-140 lesson: a generated header must not
# name a path that only resolves inside the using-ai profile. Consuming repos
# that migrate get the wrapper under gitignored ``.ai-task/scripts/``; the
# using-ai profile runs ``scripts/backlog-store.py``.
#
# The profile path is probed FIRST (TASKRUN-161). It is tracked wherever it
# exists, so whether it is present is the same on every checkout. The vendored
# copy is not tracked: with it first, a profile machine that had run
# ``ai-task init`` and one that had not regenerated different headers, and the
# index check on each refused the other's BACKLOG.md. A consuming repo has no
# ``scripts/backlog-store.py`` and lands on the fallback, the vendored path,
# whether or not its copy is there.
GENERATOR_RELS = (
    "scripts/backlog-store.py",
    ".ai-task/scripts/backlog-store.py",
)
VENDORED_GENERATOR_REL = GENERATOR_RELS[1]

# A generated-index task entry. Deliberately NOT parseable by TASK_RE (the id
# sits inside a markdown link), so the index can never be read as task blocks.
INDEX_TASK_LINE_RE = re.compile(
    rf"^- \[(?P<status>[{TASK_STATUSES}])\] \[(?P<id>[A-Z][A-Z0-9-]*-\d+)\]"
    r"\((?P<path>[^)]+)\)(?:\s+(?P<title>.*))?$"
)
MARKER_PREFIX = "<!-- Generated index (backlog-store)."

_TASK_ID_SORT_RE = re.compile(r"^(?P<prefix>[A-Z][A-Z0-9-]*)-(?P<num>\d+)$")

# The store's own requirement on top of the DoR keys (TASKRUN-151). A block
# that never says how it is verified cannot be delivered honestly - `Verify:`
# is what makes a line like `Verify: python-quick` a claim rather than a label.
# Kept separate from DOR_REQUIRED_KEYS on purpose: changing what `ai-task dor`
# demands is a contract question for consuming repos, not this tool's to settle.
STORE_EXTRA_KEYS = ("Verify",)

# TASKRUN-144. A `- [c]` block must say why it was dropped. Checked on the
# canceled block itself, unlike the DoR keys, which are checked on open blocks
# only: those describe how work will be run, and a dropped task will not be.
# The reason IS the state here - a `[c]` with no reason is a quieter delete,
# and losing the reason is exactly what the marker exists to prevent.
CANCEL_REQUIRED_KEY = "Canceled"

# Metadata line order for blocks this tool writes, matching the shape the
# backlog already uses. `Source:` is optional and omitted when not given.
METADATA_ORDER = (
    "Source",
    "Incident",
    "Canceled",
    "Priority",
    "Size",
    "Depends on",
    "Agent",
    "Docs",
    "Verify",
)

# TASKRUN-158. "Update dependent docs in the same task" is a rule of the shared
# AGENTS.md (Workflow, step 5), and an executor reads the task block, not the
# rules. `add` therefore writes a `Docs:` line into every open or deferred block:
# the author's own value from `--docs` (which documents, or "none - <reason>"),
# or this reminder when the author gave none. It is a reminder, not a gate:
# `check` does not require the line, so no block written before it goes red,
# and a repo that guards docs mechanically keeps its own marker for that.
DOCS_REMINDER = (
    "update in this task the docs the change makes stale, or record why none "
    "(AGENTS.md, Workflow step 5)"
)


def generator_rel(repo: Path) -> str:
    """Tool path named in the generated marker; depends on tracked files only."""
    profile_rel = GENERATOR_RELS[0]
    if (repo / profile_rel).is_file():
        return profile_rel
    return VENDORED_GENERATOR_REL


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
        out = [marker, "", *out]
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


def task_file_rel(task_id: str) -> str:
    return f"{TASKS_REL}/{task_id}.md"


def skeleton_phases(repo: Path) -> list[str]:
    """Every `## ` heading the skeleton declares, in file order."""
    path = repo / SKELETON_REL
    if not path.exists():
        return []
    return [
        line[3:].strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.startswith("## ")
    ]


def _offending_line(repo: Path, task_id: str, key: str) -> tuple[int, str]:
    """1-based line and text for a metadata key; the checkbox line when absent."""
    path = repo / task_file_rel(task_id)
    if not path.is_file():
        return 0, ""
    lines = path.read_text(encoding="utf-8").splitlines()
    prefix = f"{key}:"
    for lineno, line in enumerate(lines, 1):
        if line.startswith(prefix):
            return lineno, line
    for lineno, line in enumerate(lines, 1):
        if TASK_RE.match(line):
            return lineno, line
    return (1, lines[0]) if lines else (0, "")


def phase_problems(repo: Path) -> list[str]:
    """Tasks filed under a heading the skeleton never declared (TASKRUN-151).

    An unknown heading becomes a new phase by construction (see ``build_index``),
    which is how a phase is created without editing the skeleton - so to the
    generator a typo and a real new phase look the same, and both regenerate
    into an index that ``check`` was happy with. The generator stays total on
    purpose, since no task may vanish from the index; this is where the two are
    told apart, by asking the skeleton which headings it actually declared.
    """
    known = skeleton_phases(repo)
    if not known:
        return []
    problems: list[str] = []
    for task in parse_task_files(repo):
        if not task.phase or task.phase in known:
            continue
        near = difflib.get_close_matches(task.phase, known, n=1, cutoff=0.6)
        hint = (
            f"; did you mean {near[0]!r}? A typo here forks the phase instead "
            "of failing"
            if near
            else "; a genuinely new phase is added with `add --new-phase`, "
            "which writes the heading into the skeleton so its preamble has "
            "somewhere to live"
        )
        problems.append(
            f"{task_file_rel(task.id)}: phase heading {task.phase!r} is not "
            f"declared in {SKELETON_REL}{hint}"
        )
    return problems


def _verify_fallback_exists(repo: Path) -> bool:
    """True when a policy can supply the verify profile a block leaves out.

    `Verify:` is a per-task OVERRIDE of the policy's `default_profile`, so in a
    repo with `.ai-task/policies/` a block without one is still verified, and
    demanding a redundant line there would be this tool deciding a contract
    question that is not its to settle. In a repo without policies there is no
    default to fall back on, so a block that never says how it is verified is
    simply unverified - the state TASKRUN-150 found sitting behind nineteen
    `Verify: python-quick` lines. This is the same distinction TASKRUN-151 drew
    between conditioning SELECTION on `.ai-task/`, where `backlog-order` is a
    real fallback, and conditioning a VALIDATION gate, which has none.
    """
    return (repo / APP_DIR / "policies").is_dir()


def block_problems(repo: Path) -> list[str]:
    """The block contract: what the scheduler needs before it schedules anything.

    Open blocks only. Closed and deferred blocks are history, and holding them
    to today's contract would red the gate over work nobody is going to run.

    These are the checks that used to live only behind ``ai-task dor``, which
    requires ``.ai-task/``. In a repo without it they were not merely skipped,
    they were unreachable - which is to say they never ran, in the very repo
    where these blocks get written (TASKRUN-151).
    """
    tasks = parse_task_files(repo)
    if not tasks:
        return []
    problems: list[str] = []
    # Archived ids count as known here too (TASKRUN-153): `add` accepts a
    # dependency on closed, rotated-out work, so `check` must not reject it.
    known = known_task_ids(repo)
    for gap in collect_dor_gaps(tasks, open_only=True, extra_known_ids=known):
        lineno, text = _offending_line(repo, gap.task_id, gap.field)
        detail = f" | {text.strip()!r}" if text.strip() else ""
        problems.append(
            f"{task_file_rel(gap.task_id)}:{lineno}: {gap.field} - "
            f"{gap.reason}{detail}"
        )
    if _verify_fallback_exists(repo):
        return problems
    for task in tasks:
        if not task.is_open:
            continue
        for key in STORE_EXTRA_KEYS:
            if task_has_metadata_line(task, key):
                continue
            lineno, text = _offending_line(repo, task.id, key)
            detail = f" | {text.strip()!r}" if text.strip() else ""
            problems.append(
                f"{task_file_rel(task.id)}:{lineno}: {key} - missing "
                f"`{key}:` line, and this repo has no `.ai-task/policies/` "
                f"whose `default_profile` could supply one{detail}"
            )
    return problems


def cancel_problems(repo: Path) -> list[str]:
    """A `- [c]` block must carry its reason (TASKRUN-144).

    Canceled is the only state whose entire content is the explanation: the
    task will not be delivered, and the line saying why is what separates the
    marker from deleting the file. So this is checked on the canceled block
    itself, not on open blocks like the DoR keys.
    """
    problems: list[str] = []
    for task in parse_task_files(repo):
        if not task.is_canceled:
            continue
        if task_has_metadata_line(task, CANCEL_REQUIRED_KEY):
            continue
        lineno, text = _offending_line(repo, task.id, CANCEL_REQUIRED_KEY)
        detail = f" | {text.strip()!r}" if text.strip() else ""
        problems.append(
            f"{task_file_rel(task.id)}:{lineno}: {CANCEL_REQUIRED_KEY} - a "
            f"`- [c]` block needs a `{CANCEL_REQUIRED_KEY}: <date> - <reason>` "
            f"line saying why the work was dropped; use `- [~]` if it is only "
            f"paused{detail}"
        )
    return problems


def check(repo: Path) -> list[str]:
    """The store gate: index drift, phase headings, and the block contract.

    Drift alone was never enough. A mistyped heading and a block with no
    metadata both reproduced byte for byte through a regeneration, so the index
    was self-consistent and wrong at the same time (TASKRUN-151).
    """
    if not (repo / SKELETON_REL).exists():
        return []  # not migrated - nothing to guard
    return [
        *index_drift_problems(repo),
        *phase_problems(repo),
        *block_problems(repo),
        *cancel_problems(repo),
    ]


def index_drift_problems(repo: Path) -> list[str]:
    """Hand-edit / staleness guard. Returns problems; [] means fresh."""
    index_path = repo / "BACKLOG.md"
    if not index_path.exists():
        return [f"BACKLOG.md missing in {repo}; run `regenerate`"]
    current = index_path.read_text(encoding="utf-8")
    expected = build_index(repo)
    if current == expected:
        return []
    current_lines = current.splitlines()
    expected_lines = expected.splitlines()
    detail = ""
    # strict=False: the two sides legitimately differ in length when the drift is
    # an added or removed block, and this loop only names the first differing line.
    for lineno, (have, want) in enumerate(
        zip(current_lines, expected_lines, strict=False), 1
    ):
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


def render_block(
    task_id: str,
    *,
    phase: str,
    title: str,
    context: str,
    dod: str = "",
    risk: str = "",
    status: str = " ",
    metadata: dict[str, str] | None = None,
) -> str:
    """The task-block shape, as bytes rather than as a paragraph in a skill file."""
    lines = [f"## {phase}", "", f"- [{status}] {task_id} {title}", "Task Context"]
    lines.extend(context.strip().splitlines() or [""])
    if risk.strip():
        lines.append(f"Risk: {risk.strip()}")
    if dod.strip():
        lines.append("Task DOD")
        lines.extend(dod.strip().splitlines())
    values = metadata or {}
    for key in METADATA_ORDER:
        value = values.get(key)
        if value is None:
            continue
        lines.append(f"{key}: {value}".rstrip())
    return "\n".join(lines) + "\n"


def add_phase_to_skeleton(repo: Path, phase: str) -> None:
    """Append a new `## <phase>` heading so its preamble has somewhere to live."""
    path = repo / SKELETON_REL
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    body = text.rstrip("\n")
    path.write_text(f"{body}\n\n## {phase}\n" if body else f"## {phase}\n", "utf-8")


def add(
    repo: Path,
    task_id: str,
    *,
    phase: str,
    title: str,
    context: str,
    dod: str = "",
    risk: str = "",
    status: str = " ",
    metadata: dict[str, str] | None = None,
    new_phase: bool = False,
) -> Path:
    """Write one task file, then refresh the registry, then regenerate the index.

    That order is the TASKRUN-148 lesson turned into mechanism: the registry
    helper rewrites the skeleton's `next ids:` line and the index is a
    projection of that skeleton, so regenerating first would publish an index
    advertising the id just taken.
    """
    if not (repo / SKELETON_REL).exists():
        die(f"{SKELETON_REL} not found in {repo} - run `split` first")
    path = repo / task_file_rel(task_id)
    if path.exists():
        die(f"{path.relative_to(repo)} already exists; `add` never overwrites a task")

    known = skeleton_phases(repo)
    if phase not in known and not new_phase:
        near = difflib.get_close_matches(phase, known, n=1, cutoff=0.6)
        hint = f" Did you mean {near[0]!r}?" if near else ""
        die(
            f"phase {phase!r} is not declared in {SKELETON_REL}.{hint} Pass "
            "--new-phase to open a new phase, which writes the heading into "
            "the skeleton so its preamble has somewhere to live."
        )

    block = render_block(
        task_id,
        phase=phase,
        title=title,
        context=context,
        dod=dod,
        risk=risk,
        status=status,
        metadata=metadata,
    )
    # Validate the block before touching the store, so a rejected add leaves no
    # file, no moved registry floor and no regenerated index. Only the new block
    # is checked, but its dependencies are resolved against every id the repo
    # knows (TASKRUN-153): against the block alone, every `Depends on` was
    # unknown and the gate refused them all.
    draft = parse_backlog_blocks(block.splitlines())
    if not draft:
        die(f"refusing to write {task_id}: the rendered block does not parse")
    gaps = collect_dor_gaps(
        draft, open_only=True, extra_known_ids=known_task_ids(repo)
    )
    missing = [
        key for key in STORE_EXTRA_KEYS if not task_has_metadata_line(draft[0], key)
    ]
    if gaps or missing:
        for gap in gaps:
            print(f"{task_id}: {gap.field} - {gap.reason}", file=sys.stderr)
        for key in missing:
            print(f"{task_id}: {key} - missing `{key}:` value", file=sys.stderr)
        die(f"refusing to write {task_id}: the block would not pass `check`")

    # A task written without moving the registry floor is the id collision the
    # registry exists to prevent: the next `add` hands out the same id. So no
    # reachable helper refuses the add before anything is written (TASKRUN-160).
    if _registry_helper(repo) is None:
        die(
            f"refusing to write {task_id}: backlog-id-registry.py not found in "
            f"{repo} nor beside this tool ({TOOL_SCRIPTS_DIR}); run `ai-task "
            "init` to vendor it, or run the tool from a checkout that has it"
        )

    if phase not in known:
        add_phase_to_skeleton(repo, phase)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(block, encoding="utf-8")
    refresh_registry(repo, f"new task {task_id} (backlog-store add)")
    regenerate(repo)
    return path


#: Where the running tool sits: ``scripts/`` in the using-ai profile,
#: ``.ai-task/scripts/`` in a consuming repo. The registry helper is shipped
#: beside it in both layouts (TASKRUN-160).
TOOL_SCRIPTS_DIR = Path(__file__).resolve().parent.parent


def _registry_helper(repo: Path) -> Path | None:
    for rel in (
        ".ai-task/scripts/backlog-id-registry.py",
        "scripts/backlog-id-registry.py",
    ):
        candidate = repo / rel
        if candidate.is_file():
            return candidate
    # A git worktree of a consuming repo has no `.ai-task/` (it is vendored and
    # gitignored), so `--repo .` finds no helper of its own. The helper beside
    # the running tool takes `--repo` like the tool does and serves that tree.
    beside_tool = TOOL_SCRIPTS_DIR / "backlog-id-registry.py"
    if beside_tool.is_file():
        return beside_tool
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


def index_volume(repo: Path, *, removing: int = 0) -> dict[str, int]:
    """Size of the generated index, and what it would be after a rotation.

    The trigger metric (TASKRUN-152). After the file-per-task migration the
    pile in ``backlog/tasks/`` is cheap - a parser reads it - while the index
    is what delivery skills and agents load, and it grows one line per task
    without bound. Reported by the tool rather than left as prose so the
    number can be looked at instead of estimated.
    """
    index_path = repo / "BACKLOG.md"
    if not index_path.exists():
        return {"index_lines": 0, "index_bytes": 0, "index_lines_after": 0}
    text = index_path.read_text(encoding="utf-8")
    lines = len(text.splitlines())
    return {
        "index_lines": lines,
        "index_bytes": len(text.encode("utf-8")),
        # Each rotated task drops exactly its own one-line index entry; an
        # emptied phase heading is a separate, optional cleanup step.
        "index_lines_after": max(lines - removing, 0),
    }


def rotate(repo: Path, *, dry_run: bool = False) -> dict[str, int]:
    """Move closed task files to the archive dir, regenerate, refresh registry."""
    tasks = parse_task_files(repo)
    if not tasks:
        die(f"no task files under {TASKS_REL}/ in {repo} - nothing to rotate")
    # Both terminals rotate (TASKRUN-144): `[x]` delivered and `[c]` dropped are
    # equally finished, and leaving canceled work in the active file would be the
    # eternal `- [~]` the marker was added to replace. They are counted apart so
    # the preview never reads a cancellation as delivery.
    done = [task for task in tasks if task.status == "x"]
    canceled = [task for task in tasks if task.is_canceled]
    closed = done + canceled
    open_count = sum(1 for task in tasks if task.status == " ")
    deferred_count = sum(1 for task in tasks if task.status == "~")
    counts = {
        "closed": len(closed),
        "done": len(done),
        "canceled": len(canceled),
        "open": open_count,
        "deferred": deferred_count,
    }
    # TASKRUN-152: the volume of the generated index, printed because it is the
    # thing rotation actually reduces now. The task files are read by a parser
    # and cost nothing; BACKLOG.md is read into a context window on every
    # delivery run, and it carries one line per task forever.
    counts.update(index_volume(repo, removing=len(closed)))
    print(
        f"rotation preview: {len(done)} done [x] and {len(canceled)} canceled [c] "
        f"-> {ARCHIVE_TASKS_REL}/, {open_count} open and {deferred_count} deferred "
        f"staying in {TASKS_REL}/"
    )
    print(
        f"index volume: BACKLOG.md {counts['index_lines']} lines "
        f"({counts['index_bytes']} bytes), {counts['index_lines_after']} lines "
        f"after this rotation"
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
    # Registry first, index second (TASKRUN-148): the registry helper now also
    # rewrites the `next ids:` line in the skeleton, and the index is a
    # projection of that skeleton - regenerating before it would leave
    # BACKLOG.md advertising the pre-rotation floors and `check` red.
    refresh_registry(
        repo,
        f"rotation: {len(done)} done + {len(canceled)} canceled task file(s) "
        f"-> {ARCHIVE_TASKS_REL}/",
    )
    regenerate(repo)
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
            "File-per-task backlog store: add a task, split BACKLOG.md, "
            "regenerate the read-only index, check the block contract, "
            "rotate closed task files (TASKRUN-142, TASKRUN-151)."
        )
    )
    parser.add_argument(
        "--repo", default=".", help="Repository root (default: current directory)"
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p_add = sub.add_parser(
        "add",
        help="Write one new task file, refresh the registry, regenerate the index",
        description=(
            "Write backlog/tasks/<ID>.md from arguments instead of hand-authoring "
            "it, then refresh the id registry and regenerate the index, in that "
            "order. Allocate the id from the registry floor first "
            "(backlog-id-registry.py). Refuses an id that already has a file, a "
            "phase the skeleton does not declare (see --new-phase), and any "
            "metadata `check` would reject."
        ),
    )
    p_add.add_argument("task_id", help="Task id, e.g. TASKRUN-152")
    p_add.add_argument("--phase", required=True, help="Phase heading, without `## `")
    p_add.add_argument("--title", required=True, help="Title on the checkbox line")
    p_add.add_argument("--context", required=True, help="Task Context body")
    p_add.add_argument("--dod", default="", help="Task DOD body")
    p_add.add_argument(
        "--risk", default="", help="Risk: acknowledgment (required for P0 and P1)"
    )
    p_add.add_argument("--priority", required=True, help="P0, P1, P2 or P3")
    p_add.add_argument("--size", required=True, help="S, M or L (XL must be split)")
    p_add.add_argument(
        "--verify", required=True, help="Verify profile, e.g. python-quick or none"
    )
    p_add.add_argument("--depends-on", default="", help="Comma-separated task ids")
    p_add.add_argument("--agent", default="auto", help="auto, claude, cursor, codex, human")
    p_add.add_argument("--source", default="", help="planned, incident, monitoring, owner, retro")
    p_add.add_argument("--incident", default="", help="Incident ref (Source: incident)")
    p_add.add_argument(
        "--docs",
        default="",
        help="Docs this task must update, or 'none - <reason>'. Without it an "
        "open or deferred block still gets a `Docs:` reminder line (TASKRUN-158)",
    )
    p_add.add_argument(
        "--status",
        default=" ",
        choices=list(TASK_STATUSES),
        help="Checkbox state (default: open); `c` also needs `--canceled`",
    )
    p_add.add_argument(
        "--canceled",
        default="",
        help="Why the work was dropped, e.g. '2026-09-12 - superseded by X'; "
        "required with --status c and rejected without it",
    )
    p_add.add_argument(
        "--new-phase",
        action="store_true",
        help="Open a new phase: write the heading into the skeleton too",
    )
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

    if args.command == "add":
        metadata = {
            "Priority": args.priority,
            "Size": args.size,
            "Depends on": args.depends_on,
            "Agent": args.agent,
            "Verify": args.verify,
        }
        if args.source:
            metadata["Source"] = args.source
        if args.incident:
            metadata["Incident"] = args.incident
        # The docs duty is visible where the executor reads the task. A closed or
        # canceled block gets the line only when the author wrote one: a reminder
        # to do work that is already done, or dropped, is noise.
        if args.docs.strip():
            metadata["Docs"] = args.docs.strip()
        elif args.status in (" ", "~"):
            metadata["Docs"] = DOCS_REMINDER
        # Keep the pair honest at the entry point rather than letting `check`
        # catch it after a file has been written (TASKRUN-144).
        if args.status == CANCELED_STATUS and not args.canceled.strip():
            print(
                "error: --status c needs --canceled '<date> - <reason>'; a "
                "canceled block without its reason is a quieter delete. Use "
                "--status ~ if the work is only paused.",
                file=sys.stderr,
            )
            return 2
        if args.canceled.strip() and args.status != CANCELED_STATUS:
            print(
                "error: --canceled only applies to --status c",
                file=sys.stderr,
            )
            return 2
        if args.canceled.strip():
            metadata["Canceled"] = args.canceled.strip()
        path = add(
            repo,
            args.task_id,
            phase=args.phase,
            title=args.title,
            context=args.context,
            dod=args.dod,
            risk=args.risk,
            status=args.status,
            metadata=metadata,
            new_phase=args.new_phase,
        )
        print(
            f"wrote {path.relative_to(repo)}, refreshed the id registry and "
            "regenerated BACKLOG.md"
        )
        return 0
    if args.command == "split":
        counts = split(repo)
        print(
            f"split {counts['tasks']} task block(s) into {TASKS_REL}/, wrote "
            f"{SKELETON_REL} and regenerated BACKLOG.md"
        )
        refresh_registry(repo, "file-per-task migration (backlog-store split)")
        # The refresh may have rewritten the skeleton's `next ids:` line
        # (TASKRUN-148), and `split` regenerated the index before that.
        regenerate(repo)
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
GUARD_SOURCE_SHA256 = "e224d782a6f7a81f72626bb5691b6ee1d77cee17344a4793ec48b28340e8db5c"
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
