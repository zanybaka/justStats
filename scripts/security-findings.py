#!/usr/bin/env python3
"""Turn the weekly gitleaks and Semgrep reports of main into issues (SKILL-162).

Placed by bootstrap-project as scripts/security-findings.py, byte for byte; the
tests live in using-ai (tests/test_security_findings.py), so do not reformat a
copy in a consuming repository.

Routing by visibility:
  private  an issue per NEW finding in this repository (labels ai-inbox and
           security-scan); a finding that already has an open issue is skipped.
  public   no issue in this repository: an open issue about a vulnerability
           publishes it before the fix. The finding goes to an issue in the
           infra repository (label ai-improvement) and the public repository
           gets only the fix later.
A new secret also writes one line for the owner to --telegram-out, because only
a human rotates a key. The reports are read redacted (gitleaks --redact) and
this script never prints a finding's content, only counts and dedup keys.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

MARKER = "<!-- security-key: {key} -->"
SCAN_LABEL = "security-scan"
PRIVATE_LABELS = ("ai-inbox", SCAN_LABEL)
INFRA_LABELS = ("ai-improvement", SCAN_LABEL)

GhRunner = Callable[[list[str]], str]


def load_findings(gitleaks: Path | None, semgrep: Path | None) -> list[dict]:
    """Findings as dicts: key, kind, rule, path, line. The key is the dedup identity."""
    findings: list[dict] = []
    if gitleaks and gitleaks.is_file() and gitleaks.read_text(encoding="utf-8").strip():
        for item in json.loads(gitleaks.read_text(encoding="utf-8")) or []:
            fingerprint = item.get("Fingerprint") or ":".join(
                str(item.get(k, "")) for k in ("Commit", "File", "RuleID", "StartLine")
            )
            findings.append(
                {
                    "key": f"secret:{fingerprint}",
                    "kind": "secret",
                    "rule": item.get("RuleID", "unknown"),
                    "path": item.get("File", ""),
                    "line": item.get("StartLine", 0),
                }
            )
    if semgrep and semgrep.is_file() and semgrep.read_text(encoding="utf-8").strip():
        for item in json.loads(semgrep.read_text(encoding="utf-8")).get("results", []):
            rule, path = item.get("check_id", "unknown"), item.get("path", "")
            # One issue per rule and file: a line number moves with every edit
            # and would reopen the finding.
            findings.append(
                {
                    "key": f"sast:{rule}:{path}",
                    "kind": "sast",
                    "rule": rule,
                    "path": path,
                    "line": (item.get("start") or {}).get("line", 0),
                }
            )
    seen: set[str] = set()
    unique = []
    for finding in findings:
        if finding["key"] not in seen:
            seen.add(finding["key"])
            unique.append(finding)
    return unique


def open_keys(gh: GhRunner, repo: str) -> set[str]:
    """Dedup keys of a repository's open scan issues, read from body markers."""
    out = gh(
        [
            "issue",
            "list",
            "--repo",
            repo,
            "--state",
            "open",
            "--label",
            SCAN_LABEL,
            "--limit",
            "500",
            "--json",
            "body",
        ]
    )
    prefix, suffix = MARKER.split("{key}")
    keys = set()
    for issue in json.loads(out or "[]"):
        body = issue.get("body") or ""
        start = body.find(prefix)
        while start != -1:
            end = body.find(suffix, start + len(prefix))
            if end == -1:
                break
            keys.add(body[start + len(prefix) : end])
            start = body.find(prefix, end)
    return keys


def issue_text(finding: dict, source_repo: str) -> tuple[str, str]:
    where = (
        f"{finding['path']}:{finding['line']}" if finding["line"] else finding["path"]
    )
    kind = "секрет" if finding["kind"] == "secret" else "SAST"
    title = f"security: {kind} {finding['rule']} в {finding['path']} ({source_repo})"
    body = (
        f"Еженедельный скан main репозитория {source_repo} нашёл {kind}: "
        f"правило {finding['rule']}, "
        f"{where}.\n\n"
        + (
            "Значение в журнал и в этот текст не попадает. Ключ ротирует "
            "человек, и только после "
            "ротации отпечаток можно внести в .gitleaksignore.\n"
            if finding["kind"] == "secret"
            else "Если это ложное срабатывание, внесите причину в "
            ".semgrepignore или nosemgrep.\n"
        )
        + "\n"
        + MARKER.format(key=finding["key"])
        + "\n"
    )
    return title, body


def route(
    findings: list[dict],
    repo: str,
    visibility: str,
    infra_repo: str | None,
    gh: GhRunner,
) -> tuple[list[dict], list[dict]]:
    """Create the issues; returns (created, skipped as duplicates)."""
    if visibility == "public":
        if not infra_repo:
            raise SystemExit(
                "public repository needs --infra-repo: findings must not go "
                "to its own issues"
            )
        target, labels = infra_repo, INFRA_LABELS
        # A public finding is keyed with the repository, so one infra
        # repository can hold findings of many.
        findings = [{**f, "key": f"{repo}:{f['key']}"} for f in findings]
    else:
        target, labels = repo, PRIVATE_LABELS
    existing = open_keys(gh, target) if findings else set()
    created, skipped = [], []
    for finding in findings:
        if finding["key"] in existing:
            skipped.append(finding)
            continue
        title, body = issue_text(finding, repo)
        for label in labels:
            gh(["label", "create", label, "--repo", target, "--force"])
        gh(
            [
                "issue",
                "create",
                "--repo",
                target,
                "--title",
                title,
                "--body",
                body,
                *[a for label in labels for a in ("--label", label)],
            ]
        )
        existing.add(finding["key"])
        created.append(finding)
    return created, skipped


def telegram_line(created: list[dict], repo: str) -> str:
    secrets = [f for f in created if f["kind"] == "secret"]
    if not secrets:
        return ""
    return (
        f"Секрет в истории {repo}: новых находок {len(secrets)}. "
        "Ключ ротирует только человек, подробности в задаче."
    )


def _gh(args: list[str]) -> str:
    result = subprocess.run(["gh", *args], check=True, capture_output=True, text=True)
    return result.stdout


def main(argv: list[str] | None = None, gh: GhRunner = _gh) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True, help="OWNER/REPO that was scanned")
    parser.add_argument("--visibility", required=True, choices=("public", "private"))
    parser.add_argument(
        "--infra-repo", help="OWNER/REPO that receives findings of a public repository"
    )
    parser.add_argument("--gitleaks", type=Path)
    parser.add_argument("--semgrep", type=Path)
    parser.add_argument(
        "--telegram-out",
        type=Path,
        help="file for the owner's line; empty when nothing to say",
    )
    args = parser.parse_args(argv)

    findings = load_findings(args.gitleaks, args.semgrep)
    created, skipped = route(findings, args.repo, args.visibility, args.infra_repo, gh)
    line = telegram_line(created, args.repo)
    if args.telegram_out:
        args.telegram_out.write_text(line + ("\n" if line else ""), encoding="utf-8")
    print(
        f"findings: {len(findings)}, new issues: {len(created)}, "
        f"already open: {len(skipped)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
