#!/usr/bin/env python3
"""Turn the weekly gitleaks and Semgrep reports of main into issues (SKILL-162).

Placed as scripts/security-findings.py, byte for byte, by the project bootstrap;
its tests live with the bootstrap templates, so do not edit or reformat a copy
in a consuming repository.

Routing by visibility:
  private  an issue per NEW finding in this repository (labels ai-inbox and
           security-scan); a finding that already has an open issue is skipped.
  public   no issue in this repository: an open issue about a vulnerability
           publishes it before the fix. The finding goes to an issue in the
           infra repository (label ai-improvement) and the public repository
           gets only the fix later.
  private with --infra-repo
           the same issue in the infra repository: for a repository outside
           the pipeline, where nobody triages ai-inbox, so the finding reaches
           the owner through the infra repository instead.
A new secret also writes one line for the owner to --telegram-out, because only
a human rotates a key. With --notify all every new finding writes that line: a
repository where nobody triages ai-inbox still reaches the owner.
The reports are read redacted (gitleaks --redact) and this script never prints
a finding's content, only counts and dedup keys.

GitHub is reached over its REST API with the standard library and the token in
GH_TOKEN (or GITHUB_TOKEN), so a self-hosted runner needs no gh CLI.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

MARKER = "<!-- security-key: {key} -->"
SCAN_LABEL = "security-scan"
PRIVATE_LABELS = ("ai-inbox", SCAN_LABEL)
INFRA_LABELS = ("ai-improvement", SCAN_LABEL)
# Five pages of 100: the cap the gh call had before (--limit 500).
MAX_PAGES = 5
TIMEOUT = 30


class GitHub:
    """The three calls the script needs, over REST. Tests pass their own opener."""

    def __init__(self, token: str, api: str = "https://api.github.com", opener=None):
        if not token:
            raise SystemExit("GH_TOKEN is empty: the run cannot read or file issues")
        self.token = token
        self.api = api.rstrip("/")
        self.opener = opener or urllib.request.urlopen

    def request(self, method: str, path: str, payload: dict | None = None):
        """Returns (JSON or None, status, Link header). HTTP errors end the run."""
        url = path if path.startswith("http") else f"{self.api}{path}"
        # The token goes only to the API host: a next-page URL from the Link header
        # must start with the same https base, never another scheme or host.
        if not url.startswith(self.api + "/"):
            where = url.split("?")[0]
            raise SystemExit(f"refusing to send the token outside {self.api}: {where}")
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        # S310: the scheme and host were checked against the https API base above.
        req = urllib.request.Request(url, data=data, method=method)  # noqa: S310
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with self.opener(req, timeout=TIMEOUT) as resp:
                raw = resp.read()
                link = resp.headers.get("Link", "") if resp.headers else ""
                return (json.loads(raw) if raw else None), resp.status, link
        except urllib.error.HTTPError as err:
            err.close()
            if err.code == 422 and method == "POST" and path.endswith("/labels"):
                return None, 422, ""
            # The status and the path only: a response body may quote the request.
            raise SystemExit(f"GitHub {method} {path}: HTTP {err.code}") from None
        except urllib.error.URLError as err:
            reason = type(err.reason).__name__
            raise SystemExit(f"GitHub {method} {path}: no answer ({reason})") from None

    def open_issue_bodies(self, repo: str, label: str) -> list[str]:
        query = urllib.parse.urlencode(
            {"state": "open", "labels": label, "per_page": 100}
        )
        path = f"/repos/{repo}/issues?{query}"
        bodies: list[str] = []
        for _ in range(MAX_PAGES):
            items, _status, link = self.request("GET", path)
            for item in items or []:
                if "pull_request" not in item:
                    bodies.append(item.get("body") or "")
            path = next_page(link)
            if not path:
                break
        return bodies

    def ensure_label(self, repo: str, label: str) -> None:
        # 422 means the label exists already; the request keeps its colour.
        self.request("POST", f"/repos/{repo}/labels", {"name": label})

    def create_issue(self, repo: str, title: str, body: str, labels) -> None:
        payload = {"title": title, "body": body, "labels": list(labels)}
        self.request("POST", f"/repos/{repo}/issues", payload)


def next_page(link: str) -> str:
    """The rel="next" URL of a Link header, or an empty string."""
    for part in link.split(","):
        section = part.split(";")
        if len(section) > 1 and section[1].strip() == 'rel="next"':
            return section[0].strip().strip("<>")
    return ""


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


def open_keys(api: GitHub, repo: str) -> set[str]:
    """Dedup keys of a repository's open scan issues, read from body markers."""
    prefix, suffix = MARKER.split("{key}")
    keys = set()
    for body in api.open_issue_bodies(repo, SCAN_LABEL):
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
    api: GitHub,
) -> tuple[list[dict], list[dict]]:
    """Create the issues; returns (created, skipped as duplicates)."""
    if visibility == "public" or infra_repo:
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
    existing = open_keys(api, target) if findings else set()
    created, skipped = [], []
    labelled = False
    for finding in findings:
        if finding["key"] in existing:
            skipped.append(finding)
            continue
        title, body = issue_text(finding, repo)
        if not labelled:
            for label in labels:
                api.ensure_label(target, label)
            labelled = True
        api.create_issue(target, title, body, labels)
        existing.add(finding["key"])
        created.append(finding)
    return created, skipped


def telegram_line(created: list[dict], repo: str, notify: str = "secrets") -> str:
    secrets = [f for f in created if f["kind"] == "secret"]
    if notify == "all" and created:
        return (
            f"Новые находки скана {repo}: секретов {len(secrets)}, "
            f"SAST {len(created) - len(secrets)}. Подробности в задачах "
            "security-scan; ключ ротирует только человек."
        )
    if not secrets:
        return ""
    return (
        f"Секрет в истории {repo}: новых находок {len(secrets)}. "
        "Ключ ротирует только человек, подробности в задаче."
    )


def default_api() -> GitHub:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
    api = os.environ.get("GITHUB_API_URL") or "https://api.github.com"
    return GitHub(token, api)


def main(argv: list[str] | None = None, api: GitHub | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True, help="OWNER/REPO that was scanned")
    parser.add_argument("--visibility", required=True, choices=("public", "private"))
    parser.add_argument(
        "--infra-repo",
        help="OWNER/REPO that receives the findings instead of this repository "
        "(required when public)",
    )
    parser.add_argument("--gitleaks", type=Path)
    parser.add_argument("--semgrep", type=Path)
    parser.add_argument(
        "--telegram-out",
        type=Path,
        help="file for the owner's line; empty when nothing to say",
    )
    parser.add_argument(
        "--notify",
        choices=("secrets", "all"),
        default="secrets",
        help="which new findings the owner's line covers",
    )
    args = parser.parse_args(argv)

    findings = load_findings(args.gitleaks, args.semgrep)
    if findings and api is None:
        api = default_api()
    created, skipped = route(
        findings, args.repo, args.visibility, args.infra_repo, api
    )
    line = telegram_line(created, args.repo, args.notify)
    if args.telegram_out:
        args.telegram_out.write_text(line + ("\n" if line else ""), encoding="utf-8")
    print(
        f"findings: {len(findings)}, new issues: {len(created)}, "
        f"already open: {len(skipped)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
