#!/usr/bin/env python3
"""Collect one completed Pacific day's fleet outcomes into private data/wake/daily.

Usage: fm-wake-daily.py YYYY-MM-DD [--home HOME]
       fm-wake-daily.py --catch-up [--home HOME]

The output contract is docs/wake-daily.md. This command reads its source files
without modifying them and atomically replaces only the daily JSON it writes.
It never interprets a merge as production value. Unimplemented signals have no
section in this version of the record.
"""

import argparse
import csv
import fcntl
import io
from datetime import date, datetime, timedelta, timezone
import json
import logging
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
import urllib.request
from urllib.parse import quote, urlencode, urlsplit
from zoneinfo import ZoneInfo


PACIFIC = ZoneInfo("America/Los_Angeles")
LEDGER_CUTOFF = "2026-11-21"
WAKE_START = date(2026, 11, 21)
ASSUMED_LOOKBACK_DAYS = 14
CATCH_UP_RETRY_DAYS = 3
ROW = re.compile(r"^- \[[ xX]\] ([A-Za-z0-9._-]+) - (.*)$")
META = re.compile(r"\s+\((?:repo|kind|priority|hold|hold-kind|hold-until): [^)]*\)$|\s+\((?:since|merged|reported|done) \d{4}-\d{2}-\d{2}\)$")
URL = re.compile(r"https?://[^\s)<>]+")
PR_URL = re.compile(r"https?://[^\s)<>]+/(?:pull|merge_requests)/\d+[^\s)<>]*")
REPORT = re.compile(r"(?:^|\s)(data/[^\s)]+/report\.md)(?:\s|$)")
DONE = re.compile(r"\((merged|reported|done) (\d{4}-\d{2}-\d{2})\)")
SINCE = re.compile(r"\(since (\d{4}-\d{2}-\d{2})\)")
HOLD_KIND = re.compile(r"\(hold-kind: ([^)]+)\)")
LOCAL_NOTE = re.compile(r"(?:^|\s)local main$")
KIND = re.compile(r"\(kind: ([^)]+)\)")
PROJECT = re.compile(r"\(repo: ([^)]+)\)")
BLOCKED_BY = re.compile(r"\bblocked-by:\s*([A-Za-z0-9._-]+)")
ORIGIN = re.compile(r"^\s*Captain hold origin:\s*([A-Za-z0-9._-]+)\s*$")
REFERENCE = re.compile(r"\b(story|epic)\s+([0-9]+(?:[.-][0-9A-Za-z]+)*)\b", re.I)
REPORT_PATH = re.compile(r"data/([A-Za-z0-9._-]+)/report\.md\b")
DELIVERY_URL = re.compile(r"^\s*(?:merge|pull) request\s+(https?://\S+)", re.I)
GITLAB_MR = re.compile(r"https://([^/\s)<>]+)/([^\s)<>]+?)/-/merge_requests/(\d+)(?!\d)")
GITHUB_PR = re.compile(r"https://github\.com/([^/\s)<>]+)/([^/\s)<>]+)/pull/(\d+)(?!\d)")
REVERT = re.compile(r"^Revert\s+", re.IGNORECASE)
HOSTUPDATE_PIPELINES = "gitlab:lsg-git.lbl.gov/lblnet/lblnet_hostupdate/pipelines"
HOSTUPDATE_PROJECT = "projects/lblnet%2Flblnet_hostupdate"
HOSTUPDATE_API = f"{HOSTUPDATE_PROJECT}/pipelines"
MR_REF = re.compile(r"refs/merge-requests/([1-9][0-9]*)/(?:head|merge|train)")
CHANGE_CLASSES = ("image_build", "full_unit", "other")
DEPLOY_METRICS = "influxdb:lsg_deploy_metrics/deploy_lead_time"
DEPLOY_QUERY_URL = "https://lsg-influxdb.lbl.gov:8086/api/v2/query?org=LSG"
DEPLOY_PATHS = {"datafeed_config", "arpwatch-ng", "iprequest_app_code",
                "iprequest_onestop_code", "iprequest_config", "vantage_code",
                "hostupdate_iprequest_app_pin", "hostupdate_iprequest_onestop_pin",
                "hostupdate_iprequest_both_pin", "hostupdate_iprequest_pin",
                "hostupdate_vantage_pin"}


def deploy_token(home):
    """Read the token only from the home's .env with its one-key parser."""
    result = subprocess.run(
        ["bash", "-c", '. "$1"; fmx_env_get INFLUXDB_DEPLOY_METRICS_TOKEN "$2"',
         "_", str(Path(__file__).with_name("fm-env-lib.sh")), str(home / ".env")],
        capture_output=True, text=True, check=False)
    return result.stdout if result.returncode == 0 else ""


def query_deploy_metrics(day, home, coverage):
    token = deploy_token(home)
    if not token:
        coverage[DEPLOY_METRICS] = {"status": "not_measurable", "reason": "read token absent"}
        return None
    start = (date.fromisoformat(day) - timedelta(days=120)).isoformat() + "T00:00:00Z"
    stop = (date.fromisoformat(day) + timedelta(days=2)).isoformat() + "T00:00:00Z"
    flux = (f'from(bucket: "lsg_deploy_metrics") |> range(start: time(v: "{start}"), '
            f'stop: time(v: "{stop}")) |> filter(fn: (r) => '
            'r._measurement == "deploy_lead_time") |> pivot(rowKey: ["_time"], '
            'columnKey: ["_field"], valueColumn: "_value")')
    request = urllib.request.Request(
        DEPLOY_QUERY_URL, data=flux.encode(), method="POST",
        headers={"Authorization": "Token " + token, "Accept": "application/csv",
                 "Content-Type": "application/vnd.flux"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read().decode("utf-8")
        columns = None
        points = []
        for row in csv.reader(io.StringIO(body)):
            if not row or row[0].startswith("#"):
                continue
            if "_measurement" in row and "result" in row:
                columns = row
                continue
            if columns is None or len(row) != len(columns):
                raise ValueError("invalid InfluxDB CSV")
            point = dict(zip(columns, row))
            if point.get("_measurement") == "deploy_lead_time":
                points.append(point)
        if columns is None:
            raise ValueError("missing InfluxDB CSV header")
    except (OSError, UnicodeError, ValueError):
        coverage[DEPLOY_METRICS] = {"status": "not_measurable", "reason": "query unavailable or invalid"}
        return None
    coverage[DEPLOY_METRICS] = {"status": "readable"}
    return points


def production_evidence(day, ships, points, coverage):
    if points is None:
        return {"deployed": [], "not_shown": []}, {"status": "not_measurable", "count": None,
                                                    "inputs": [DEPLOY_METRICS]}
    start = datetime.combine(date.fromisoformat(day), datetime.min.time(), PACIFIC).astimezone(timezone.utc)
    end = datetime.combine(date.fromisoformat(day) + timedelta(days=1),
                           datetime.min.time(), PACIFIC).astimezone(timezone.utc)
    def on_day(value):
        try:
            stamp = datetime.fromtimestamp(int(value) / 1000, timezone.utc)
        except (TypeError, ValueError, OverflowError):
            return None
        return stamp if start <= stamp < end else None
    tasks = {pr_key(item["evidence"]): item["task"] for project in ships
             for item in project["ships"] if pr_key(item["evidence"])}
    deployed, not_shown = [], []
    measured_mrs = set()
    for point in points:
        mr = point.get("mr_url")
        if not mr:
            continue
        key = pr_key(mr)
        if key is None:
            continue
        merged = on_day(point.get("merged_at_ms"))
        deployed_at = on_day(point.get("deployed_at_ms"))
        if merged:
            measured_mrs.add(key)
        if (point.get("path") in DEPLOY_PATHS and deployed_at and
                point.get("deployed") == "1" and point.get("deploy_job_id", "").isdigit()):
            deployed.append({"mr": key, "task": tasks.get(key), "path": point["path"],
                             "deployed_at": deployed_at.isoformat().replace("+00:00", "Z"),
                             "deploy_job_id": int(point["deploy_job_id"]),
                             "evidence": DEPLOY_METRICS})
        elif merged:
            not_shown.append({"mr": key, "task": tasks.get(key), "path": point["path"],
                              "merged_at": merged.isoformat().replace("+00:00", "Z"),
                              "reason": ("no GitLab-visible production signal for this path"
                                         if point["path"] not in DEPLOY_PATHS else
                                         "no successful production deploy recorded by day end")})
    shown = {item["mr"] for item in deployed}
    not_shown = [item for item in not_shown if item["mr"] not in shown]
    for project in ships:
        for item in project["ships"]:
            key = pr_key(item["evidence"])
            if key and key not in measured_mrs and key not in shown:
                not_shown.append({"mr": key, "task": item["task"], "path": None,
                                  "merged_at": item["merged_at"],
                                  "reason": "no matching production measurement"})
    deployed.sort(key=lambda item: (item["deployed_at"], item["mr"], item["path"]))
    not_shown.sort(key=lambda item: (item["merged_at"], item["mr"], item["path"] or ""))
    return {"deployed": deployed, "not_shown": not_shown}, {"status": "measured", "count": len(deployed)}


def read_text(path, coverage):
    name = str(path)
    try:
        data = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        coverage[name] = {"status": "not_measurable", "reason": "unreadable" if path.exists() else "absent"}
        return None
    coverage[name] = {"status": "readable"}
    return data


def parse_rows(text, source):
    if text is None:
        return []
    rows = []
    section = None
    current = None
    for line in text.splitlines():
        if line.startswith("## "):
            section = line[3:]
            current = None
        match = ROW.match(line)
        if match:
            task, raw = match.groups()
            kind_match = KIND.search(raw)
            project_match = PROJECT.search(raw)
            day_match = DONE.search(raw)
            since_match = SINCE.search(raw)
            hold_kind_match = HOLD_KIND.search(raw)
            kind = kind_match.group(1) if kind_match else None
            if kind is None:
                if re.match(r"^SHIP\b", raw):
                    kind = "ship"
                elif re.match(r"^SCOUT\b", raw):
                    kind = "scout"
            title = raw
            while True:
                shorter = META.sub("", title)
                if shorter == title:
                    break
                title = shorter
            local_note = bool(LOCAL_NOTE.search(title))
            title = URL.sub("", title).strip()
            report = REPORT.search(title)
            if report:
                title = title.replace(report.group(1), "").strip().rstrip(" -")
            current = {
                "task": task,
                "raw": raw,
                "title": title or task,
                "project": project_match.group(1) if project_match else "none recorded",
                "kind": kind,
                "verb": day_match.group(1) if day_match else None,
                "day": day_match.group(2) if day_match else None,
                "since": since_match.group(1) if since_match else None,
                "hold_kind": hold_kind_match.group(1) if hold_kind_match else None,
                "local_note": local_note,
                "url": (URL.search(raw).group(0) if URL.search(raw) else None),
                "pr_url": (PR_URL.search(raw).group(0) if PR_URL.search(raw) else None),
                "report": report.group(1) if report else None,
                "source": source,
                "completed": source == "done-archive" or section == "Done",
                "lines": [],
            }
            rows.append(current)
        elif current and (line.startswith("  ") or not line):
            current["lines"].append(line)
        else:
            current = None
    return rows


def has_local_note(row):
    body = [line.strip() for line in row["lines"] if line.strip()]
    if row["local_note"]:
        return True
    if any(re.match(r"^Resolution recorded by fm-(captain|decision)-hold\.$", line) for line in body):
        return False
    return bool(body) and body[-1] == "local main"


def ship_delivered(row):
    """Mirror landed_record in bin/fm-landed-lib.sh for a ship row's merge."""
    if row["hold_kind"] == "captain" or row["verb"] not in ("merged", "done"):
        return False
    local = has_local_note(row)
    artifact = row["pr_url"] if row["verb"] == "merged" else local
    return bool(artifact) or (row["pr_url"] is None and row["report"] is None and not local)


def decision_pairs(row):
    lines = row["lines"]
    result = []
    active = False
    answered = False
    for line in lines:
        stripped = line.strip()
        if stripped == "Resolution mode: answered" or stripped == "Resolution mode: released":
            answered = True
        if stripped == "Captain decision:":
            active = answered
            continue
        if active and not stripped:
            active = False
            continue
        if not active:
            continue
        if stripped.startswith("Answer as shown to the captain: "):
            stripped = stripped.removeprefix("Answer as shown to the captain: ")
        if " -> " in stripped:
            question, answer = stripped.split(" -> ", 1)
            result.append((question, answer))
    return result


def ledger_events(text, coverage, path, day):
    if text is None:
        return [], 0
    events = []
    seen = set()
    dropped = 0
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("not an object")
        except (ValueError, TypeError):
            coverage[str(path)] = {"status": "not_measurable", "reason": f"invalid JSON line {number}"}
            return [], 0
        identity = json.dumps(record, sort_keys=True, separators=(",", ":"))
        if identity in seen:
            if local_day(record.get("ts")) == day:
                dropped += 1
            continue
        seen.add(identity)
        events.append(record)
    return events, dropped


def local_day(epoch):
    try:
        return datetime.fromtimestamp(epoch, timezone.utc).astimezone(PACIFIC).date().isoformat()
    except (OverflowError, OSError, TypeError, ValueError):
        return None


def task_family(task, tasks):
    parts = task.split("-")
    for length in range(2, len(parts) + 1):
        prefix = "-".join(parts[:length])
        members = [other for other in tasks if other == prefix or other.startswith(prefix + "-")]
        if len(members) > 1 and (length >= 3 or prefix in tasks):
            return prefix, sorted(members)
    return None, []


def link_fields(task, row, day_tasks, by_task, day):
    title = row["title"] if row else task
    lines = row["lines"] if row else []
    body = "\n".join([row["raw"] if row else title, *lines])
    family, members = task_family(task, day_tasks)
    blocked = sorted(set(BLOCKED_BY.findall(body)))
    origins = sorted({match.group(1) for line in lines if (match := ORIGIN.match(line))})
    reports = sorted({
        match.group(0) for match in REPORT_PATH.finditer(body)
        if match.group(1) != task
        and (scout := by_task.get(match.group(1))) is not None
        and scout["kind"] == "scout" and scout["day"] is not None and scout["day"] <= day
    })
    without_reports = REPORT_PATH.sub("", body)
    scouts = sorted({
        name for name, scout in by_task.items()
        if name != task and scout["kind"] == "scout"
        and scout["day"] is not None and scout["day"] <= day
        and re.search(r"(?<![A-Za-z0-9_-])" + re.escape(name) + r"(?![A-Za-z0-9_-])", without_reports)
    })
    references = {kind: [] for kind in ("story", "epic")}
    for match in REFERENCE.finditer(title):
        values = references[match.group(1).lower()]
        if match.group(2) not in values:
            values.append(match.group(2))
    return {
        "blocked_by": blocked,
        "id_family": family,
        "family_tasks": [name for name in members if name != task],
        "story_refs": references["story"],
        "epic_refs": references["epic"],
        "origin_tasks": origins,
        "scout_reports": reports,
        "scout_tasks": scouts,
    }


def timestamp_day(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(PACIFIC).date().isoformat()
    except (AttributeError, ValueError):
        return None


def utc_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def read_json_command(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=30, check=False)
        if result.returncode:
            return None
        return json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, UnicodeError, ValueError):
        return None


def pr_key(text):
    """Reduce a PR or MR reference to its canonical URL; keep other forge URLs whole."""
    for pattern in (GITLAB_MR, GITHUB_PR):
        match = pattern.search(text)
        if match:
            return match.group(0)
    match = PR_URL.search(text)
    return match.group(0).rstrip("/") if match else None


def task_spans(rows, ledger):
    """Map each task to (start, end, assumed): first known start day, last known done day, None when open or unknown.

    A done task with no recorded start is assumed to start ASSUMED_LOOKBACK_DAYS before its done day.
    """
    starts, ends, open_tasks = {}, {}, set()

    def note(table, task, day, pick):
        if day:
            table[task] = pick(table[task], day) if task in table else day

    for row in rows:
        note(starts, row["task"], row["since"], min)
        if not row["completed"]:
            open_tasks.add(row["task"])
        elif row["day"]:
            note(ends, row["task"], row["day"], max)
    for event in ledger:
        task = event.get("task")
        if not isinstance(task, str):
            continue
        if event.get("event") == "task.dispatched":
            note(starts, task, local_day(event.get("ts")), min)
        elif event.get("event") in ("task.merged", "task.cleaned_up"):
            note(ends, task, local_day(event.get("ts")), max)
    spans = {}
    for task in set(starts) | set(ends) | open_tasks:
        end = None if task in open_tasks else ends.get(task)
        start = starts.get(task)
        assumed = start is None and end is not None
        if assumed:
            start = (date.fromisoformat(end) - timedelta(days=ASSUMED_LOOKBACK_DAYS)).isoformat()
        spans[task] = (start, end, assumed)
    return spans


def merged_prs(rows, ledger):
    found = {pr_key(row["pr_url"]) for row in rows if row["verb"] == "merged" and row["pr_url"]}
    found |= {pr_key(event["pr"]) for event in ledger
              if event.get("event") == "task.merged" and isinstance(event.get("pr"), str)}
    found.discard(None)
    return found


def task_prs(home, rows, ledger, coverage):
    """Find task delivery URLs, without treating references in notes as task PRs."""
    found = {}
    for row in rows:
        if row["kind"] == "ship" and row["pr_url"]:
            found.setdefault(pr_key(row["pr_url"]), row["task"])
    for event in ledger:
        url, task = event.get("pr"), event.get("task")
        key = pr_key(url) if isinstance(url, str) else None
        if key and isinstance(task, str):
            found.setdefault(key, task)
    state = home / "state"
    try:
        metas = sorted(state.glob("*.meta"))
    except OSError:
        metas = []
    for path in metas:
        content = read_text(path, coverage)
        if content is None:
            continue
        task = path.stem
        for line in content.splitlines():
            if not re.match(r"^(?:pr|anchor_pr|member\.[^.]+\.pr)=", line):
                continue
            key = pr_key(line.split("=", 1)[1])
            if key:
                found.setdefault(key, task)
    return found


def clone_reverts(day, home, coverage):
    root = home / "projects"
    try:
        clones = sorted(path for path in root.iterdir() if path.is_dir() and (path / ".git").exists())
    except OSError:
        coverage[str(root)] = {"status": "not_measurable", "reason": "unreadable or absent"}
        return []
    coverage[str(root)] = {"status": "readable", "clones": len(clones)}
    found = []
    for clone in clones:
        source = str(clone)
        start = datetime.fromisoformat(f"{day}T00:00:00").replace(tzinfo=PACIFIC)
        end = datetime.fromordinal(start.date().toordinal() + 1).replace(tzinfo=PACIFIC)
        try:
            result = subprocess.run(["git", "-C", source, "log", "--all", "--format=%H%x09%cI%x09%s", "--grep=^Revert ",
                                     f"--since={start.isoformat()}", f"--until={end.isoformat()}"],
                                    capture_output=True, text=True, timeout=30, check=False)
        except (OSError, subprocess.TimeoutExpired):
            result = None
        if result is None or result.returncode:
            coverage[source] = {"status": "not_measurable", "reason": "git read failed"}
            continue
        coverage[source] = {"status": "readable"}
        try:
            remote = subprocess.run(["git", "-C", source, "remote", "get-url", "origin"],
                                    capture_output=True, text=True, timeout=10, check=False)
        except (OSError, subprocess.TimeoutExpired):
            remote = None
        base = remote.stdout.strip().removesuffix(".git") if remote is not None and not remote.returncode else ""
        if base.startswith("git@") and ":" in base:
            host, path = base[4:].split(":", 1)
            base = f"https://{host}/{path}"
        parsed = urlsplit(base)
        base = f"https://{parsed.hostname}{':' + str(parsed.port) if parsed.port else ''}{parsed.path}" if parsed.scheme == "https" and parsed.hostname else None
        seen = set()
        for line in result.stdout.splitlines():
            parts = line.split("\t", 2)
            if len(parts) != 3:
                continue
            sha, when, subject = parts
            if sha in seen or timestamp_day(when) != day or not REVERT.match(subject):
                continue
            seen.add(sha)
            url = f"{base}/-/commit/{sha}" if base and "lsg-git.lbl.gov" in base else f"{base}/commit/{sha}" if base else None
            found.append({"project": clone.name, "commit": sha, "subject": subject,
                          "at": utc_time(when), "evidence": url or f"projects/{clone.name}@{sha}"})
    return sorted(found, key=lambda item: (item["at"], item["project"], item["commit"]))


def forge_rework(day, home, rows, ledger, coverage):
    closed, failed = [], []
    candidates, assumed_starts = 0, 0
    spans = task_spans(rows, ledger)
    merged = merged_prs(rows, ledger)
    for url, task in sorted(task_prs(home, rows, ledger, coverage).items()):
        start, end, assumed = spans.get(task, (None, None, False))
        if (start is not None and day < start) or (end is not None and day > end):
            continue
        candidates += 1
        assumed_starts += assumed
        known_merged = url in merged
        source = f"forge:{url}"
        gitlab = GITLAB_MR.fullmatch(url)
        github = GITHUB_PR.fullmatch(url)
        if gitlab:
            host, project, number = gitlab.groups()
            api = f"projects/{quote(project, safe='')}/merge_requests/{number}"
            detail = None if known_merged else read_json_command(["glab", "api", "--hostname", host, api])
            pipelines = read_json_command(["glab", "api", "--hostname", host, f"{api}/pipelines?per_page=100"])
            if (not known_merged and not isinstance(detail, dict)) or not isinstance(pipelines, list):
                coverage[source] = {"status": "not_measurable", "reason": "forge unreachable or invalid response"}
                continue
            if len(pipelines) == 100:
                coverage[source] = {"status": "not_measurable", "reason": "pipeline page limit reached"}
                continue
            coverage[source] = {"status": "readable"}
            if detail and detail.get("state") == "closed" and not detail.get("merged_at") and timestamp_day(detail.get("closed_at")) == day:
                closed.append({"task": task, "url": url, "at": utc_time(detail["closed_at"])})
            for pipeline in pipelines:
                when = pipeline.get("finished_at") or pipeline.get("updated_at")
                if pipeline.get("status") != "failed" or timestamp_day(when) != day:
                    continue
                pipeline_url = pipeline.get("web_url")
                if not pipeline_url:
                    coverage[source] = {"status": "not_measurable", "reason": "pipeline URL absent"}
                    continue
                failed.append({"task": task, "url": pipeline_url, "pr_url": url, "at": utc_time(when),
                               "time_source": "finished_at" if pipeline.get("finished_at") else "updated_at"})
        elif github:
            owner, repo, number = github.groups()
            api = f"/repos/{owner}/{repo}"
            detail = None if known_merged else read_json_command(["gh", "api", f"{api}/pulls/{number}"])
            commits = read_json_command(["gh", "api", f"{api}/pulls/{number}/commits?per_page=100"])
            if (not known_merged and not isinstance(detail, dict)) or not isinstance(commits, list) or len(commits) == 100:
                coverage[source] = {"status": "not_measurable", "reason": "forge unreachable or commit page limit reached"}
                continue
            runs = []
            for commit in commits:
                sha = commit.get("sha")
                response = read_json_command(["gh", "api", f"{api}/actions/runs?head_sha={sha}&per_page=100"]) if sha else None
                if not isinstance(response, dict) or not isinstance(response.get("workflow_runs"), list) or response.get("total_count", 0) > 100:
                    runs = None
                    break
                runs.extend(response["workflow_runs"])
            if runs is None:
                coverage[source] = {"status": "not_measurable", "reason": "forge unreachable or run page limit reached"}
                continue
            coverage[source] = {"status": "readable"}
            if detail and detail.get("state") == "closed" and not detail.get("merged_at") and timestamp_day(detail.get("closed_at")) == day:
                closed.append({"task": task, "url": url, "at": utc_time(detail["closed_at"])})
            for run in runs:
                when = run.get("updated_at")
                if run.get("conclusion") == "failure" and run.get("event") in ("pull_request", "pull_request_target") and timestamp_day(when) == day and run.get("html_url"):
                    failed.append({"task": task, "url": run["html_url"], "pr_url": url, "at": utc_time(when),
                                   "time_source": "updated_at"})
        else:
            coverage[source] = {"status": "not_measurable", "reason": "unsupported forge URL"}
    closed = sorted({item["url"]: item for item in closed}.values(), key=lambda item: (item["at"], item["url"]))
    failed = sorted({item["url"]: item for item in failed}.values(), key=lambda item: (item["at"], item["url"]))
    window = {"count": candidates, "assumed_start": assumed_starts,
              "assumed_start_rule": f"done day minus {ASSUMED_LOOKBACK_DAYS} days when no start is recorded"}
    return closed, failed, window
def gitlab_json(endpoint, *, ndjson=False):
    command = ["glab", "api", endpoint, "--hostname", "lsg-git.lbl.gov"]
    if ndjson:
        command += ["--paginate", "--output", "ndjson"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=120, check=False)
    except OSError as error:
        raise ValueError("glab unavailable") from error
    except subprocess.TimeoutExpired as error:
        raise ValueError("GitLab API request timed out") from error
    if result.returncode:
        raise ValueError(f"GitLab API request failed (glab exit {result.returncode})")
    try:
        if ndjson:
            return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        return json.loads(result.stdout)
    except ValueError as error:
        raise ValueError("GitLab API returned invalid JSON") from error


def gitlab_time(value):
    if not isinstance(value, str):
        raise ValueError("missing pipeline timestamp")
    try:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("invalid pipeline timestamp") from error
    if timestamp.tzinfo is None:
        raise ValueError("pipeline timestamp lacks timezone")
    return timestamp.astimezone(timezone.utc)


def change_class(names):
    if "build-lblnet_hostupdate" in names:
        return "image_build"
    if "test-unit-checkout" in names:
        return "full_unit"
    return "other"


def pipeline_summary(pipelines):
    durations = sorted(item["wall_seconds"] for item in pipelines)
    summary = {"count": len(durations), "median_seconds": None, "p90_seconds": None, "share_under_60s": None}
    if durations:
        summary["median_seconds"] = round(statistics.median(durations), 3)
        summary["p90_seconds"] = durations[math.ceil(0.9 * len(durations)) - 1]
        summary["share_under_60s"] = round(sum(1 for seconds in durations if seconds < 60) / len(durations), 4)
    return summary


def pipeline_section(pipelines, summarize):
    initial = [item for item in pipelines if item["kind"] == "initial"]
    return {
        "pipelines": pipelines,
        "summary": summarize(pipelines),
        "initial_summary": summarize(initial),
        "initial_by_change_class": {
            name: summarize([item for item in initial if item["change_class"] == name]) for name in CHANGE_CLASSES
        },
    }


def hostupdate_pipeline_wall_time(day, coverage):
    start = datetime.combine(date.fromisoformat(day), datetime.min.time(), PACIFIC)
    end = start + timedelta(days=1)
    query = urlencode({
        "source": "merge_request_event", "status": "success", "per_page": 100,
        "updated_after": (start - timedelta(microseconds=1)).isoformat(),
    })
    pipelines = []
    pipeline_id = None
    try:
        listed = gitlab_json(f"{HOSTUPDATE_API}?{query}", ndjson=True)
        seen = set()
        for entry in listed:
            pipeline_id = None
            if not isinstance(entry, dict) or type(entry.get("id")) is not int:
                raise ValueError("invalid pipeline list entry")
            pipeline_id = entry["id"]
            if pipeline_id in seen or gitlab_time(entry.get("created_at")) >= end:
                continue
            seen.add(pipeline_id)
            detail = gitlab_json(f"{HOSTUPDATE_API}/{pipeline_id}")
            if (not isinstance(detail, dict) or detail.get("id") != pipeline_id
                    or detail.get("source") != "merge_request_event" or detail.get("status") != "success"):
                raise ValueError("invalid pipeline detail")
            created = gitlab_time(detail.get("created_at"))
            finished = gitlab_time(detail.get("finished_at"))
            if finished.astimezone(PACIFIC).date().isoformat() != day:
                continue
            seconds = (finished - created).total_seconds()
            if seconds < 0:
                raise ValueError("pipeline finished before creation")
            url = detail.get("web_url")
            if url != f"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/pipelines/{pipeline_id}":
                raise ValueError("invalid pipeline URL")
            ref = MR_REF.fullmatch(detail.get("ref") or "")
            if not ref:
                raise ValueError("invalid merge request pipeline ref")
            mr_iid = int(ref.group(1))
            merge_request = gitlab_json(f"{HOSTUPDATE_PROJECT}/merge_requests/{mr_iid}")
            if (not isinstance(merge_request, dict) or merge_request.get("iid") != mr_iid
                    or not isinstance(merge_request.get("source_branch"), str) or not merge_request["source_branch"]):
                raise ValueError("invalid merge request detail")
            jobs = gitlab_json(f"{HOSTUPDATE_API}/{pipeline_id}/jobs?per_page=100&include_retried=false", ndjson=True)
            if not all(isinstance(job, dict) and isinstance(job.get("name"), str) for job in jobs):
                raise ValueError("invalid pipeline jobs")
            names = {job["name"] for job in jobs}
            kind = "generated_followup" if "generated-followup-verify" in names else "initial"
            pipelines.append({
                "id": pipeline_id, "url": url,
                "merge_request_iid": mr_iid, "source_branch": merge_request["source_branch"],
                "created_at": created.isoformat().replace("+00:00", "Z"),
                "finished_at": finished.isoformat().replace("+00:00", "Z"),
                "wall_seconds": round(seconds, 3),
                "kind": kind,
                "job_signals": sorted(names & {"build-lblnet_hostupdate", "test-unit-checkout"}),
                "change_class": change_class(names),
            })
    except ValueError as error:
        failure = {"status": "not_measurable", "reason": "GitLab API unavailable or invalid",
                   "error": str(error), "pipeline_id": pipeline_id}
        coverage[HOSTUPDATE_PIPELINES] = failure
        unknown = {"count": None, "median_seconds": None, "p90_seconds": None, "share_under_60s": None}
        return pipeline_section([], lambda _: dict(unknown)), {
            **failure, "count": None, "inputs": [HOSTUPDATE_PIPELINES],
        }
    pipelines.sort(key=lambda item: item["id"])
    coverage[HOSTUPDATE_PIPELINES] = {"status": "readable"}
    return pipeline_section(pipelines, pipeline_summary), {"status": "measured", "count": len(pipelines)}


def build(day, home):
    coverage = {}
    hostupdate_pipelines, hostupdate_coverage = hostupdate_pipeline_wall_time(day, coverage)
    ledger_path = home / "state/fleet-ledger.jsonl"
    backlog_path = home / "data/backlog.md"
    archive_path = home / "data/done-archive.md"
    questions_path = home / "data/captain-questions.json"
    uses_ledger = day >= LEDGER_CUTOFF
    ledger, dropped = [], 0
    if uses_ledger:
        ledger, dropped = ledger_events(read_text(ledger_path, coverage), coverage, ledger_path, day)
    rows = parse_rows(read_text(backlog_path, coverage), "backlog")
    rows += parse_rows(read_text(archive_path, coverage), "done-archive")
    reverts = clone_reverts(day, home, coverage)
    closed_unmerged, failed_pipelines, forge_candidates = forge_rework(day, home, rows, ledger, coverage)
    questions_text = read_text(questions_path, coverage)
    if questions_text is None and coverage[str(questions_path)]["reason"] == "absent":
        # The captain-question store defines an absent file as an empty store.
        coverage[str(questions_path)] = {"status": "readable", "note": "absent means zero questions"}
    questions = []
    if questions_text is not None:
        try:
            document = json.loads(questions_text)
            if document.get("schema") != "fm-captain-questions.v1" or not isinstance(document.get("questions"), list):
                raise ValueError("invalid schema")
            questions = document["questions"]
        except (ValueError, AttributeError, TypeError):
            coverage[str(questions_path)] = {"status": "not_measurable", "reason": "invalid JSON or schema"}

    by_task = {}
    day_rows = {}
    for row in rows:
        old = by_task.get(row["task"])
        if old is None or row["source"] == "backlog" or old["source"] == "done-archive":
            by_task[row["task"]] = row
        if row["day"] == day and row["completed"]:
            old = day_rows.get(row["task"])
            if old is None or row["source"] == "backlog" or old["source"] == "done-archive":
                day_rows[row["task"]] = row
    projects = {}

    def section(project, signal):
        return projects.setdefault(project, {"ships": [], "scouts": [], "decisions": [], "unclassified": []})[signal]

    merges = {}
    ledger_merged_tasks = set()
    for event in ledger:
        if event.get("event") != "task.merged" or not isinstance(event.get("task"), str):
            continue
        event_day = local_day(event.get("ts"))
        if event_day is None or event_day < LEDGER_CUTOFF:
            continue
        ledger_merged_tasks.add(event["task"])
        if event_day != day:
            continue
        task = event["task"]
        old = merges.get(task)
        if old is not None:
            dropped += 1
        if old is None or event["ts"] < old["ts"]:
            merges[task] = event

    for task, event in sorted(merges.items()):
        row = day_rows.get(task) or by_task.get(task)
        project = row["project"] if row else "none recorded"
        url = event.get("pr") or (row["pr_url"] if row else None)
        item = {
            "task": task,
            "title": row["title"] if row else task,
            "evidence": url or f"state/fleet-ledger.jsonl#task.merged:{task}",
            "merged_at": datetime.fromtimestamp(event["ts"], timezone.utc).isoformat().replace("+00:00", "Z"),
            "time_precision": "second",
        }
        section(project, "ships").append(item)

    for row in sorted(day_rows.values(), key=lambda item: item["task"]):
        report = row["report"] or f"data/{row['task']}/report.md"
        reported_artifact = row["verb"] == "reported" and (home / report).is_file()
        if row["kind"] is None and row["task"] not in ledger_merged_tasks and not reported_artifact:
            section(row["project"], "unclassified").append({
                "task": row["task"], "title": row["title"],
                "evidence": row["url"] or row["report"] or f"data/{row['source']}.md#{row['task']}",
                "recorded_on": day,
            })
        if row["kind"] == "ship" and row["task"] not in ledger_merged_tasks and ship_delivered(row):
            section(row["project"], "ships").append({
                "task": row["task"], "title": row["title"],
                "evidence": row["pr_url"] or f"data/{row['source']}.md#{row['task']}",
                "merged_at": day, "time_precision": "day",
            })
        scout_report = row["kind"] == "scout" and bool(row["report"])
        if scout_report or reported_artifact or (row["kind"] == "scout" and (home / report).is_file()):
            section(row["project"], "scouts").append({
                "task": row["task"], "title": row["title"], "evidence": report,
                "reported_on": day,
            })
        for number, (question, answer) in enumerate(decision_pairs(row), 1):
            section(row["project"], "decisions").append({
                "task": row["task"], "title": row["title"],
                "question": question, "answer": answer,
                "evidence": f"data/{row['source']}.md#{row['task']}:decision:{number}",
                "closed_on": day, "time_precision": "day",
                "date_source": "task close date, not answer time",
            })

    for question in questions:
        if not isinstance(question, dict) or question.get("state") != "closed":
            continue
        close = question.get("closed_by_captain")
        if not isinstance(close, dict):
            continue
        try:
            closed_at = datetime.fromisoformat(close["at"].replace("Z", "+00:00"))
        except (KeyError, ValueError, AttributeError):
            continue
        if closed_at.astimezone(PACIFIC).date().isoformat() != day:
            continue
        section("none recorded", "decisions").append({
            "task": question["id"], "title": question["question"],
            "question": question["question"], "answer": close.get("words", ""),
            "evidence": f"data/captain-questions.json#{question['id']}",
            "closed_at": closed_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "time_precision": "second",
            "date_source": "captain close time",
        })

    link_tasks = sorted(set(day_rows) | set(merges))
    link_items = []
    for task in link_tasks:
        row = day_rows.get(task) or by_task.get(task)
        fields = link_fields(task, row, link_tasks, by_task, day)
        mr_urls = set()
        if row:
            if row["pr_url"]:
                mr_urls.add(row["pr_url"])
            mr_urls.update(match.group(1).rstrip(".,)") for line in row["lines"]
                           if (match := DELIVERY_URL.match(line)))
        if task in merges and merges[task].get("pr"):
            mr_urls.add(merges[task]["pr"])
        mrs = sorted(mr_urls)
        project = row["project"] if row else "none recorded"
        link_items.append({"kind": "task", "id": task, "project": project,
                           "mrs": mrs, "recorded_on": day, **fields})
        for mr in mrs:
            link_items.append({"kind": "mr", "id": mr, "task": task,
                               "project": project, "recorded_on": day, **fields})
    link_items.sort(key=lambda item: (item["kind"], item["id"], item.get("task", "")))

    ordered_projects = []
    for project in sorted(projects):
        signals = projects[project]
        for items in signals.values():
            items.sort(key=lambda item: (item["task"], item["evidence"]))
        ordered_projects.append({"project": project, **signals})

    deploy_points = query_deploy_metrics(day, home, coverage)
    production, production_coverage = production_evidence(day, ordered_projects, deploy_points, coverage)

    source_ok = lambda path: coverage[str(path)]["status"] == "readable"
    open_task_decisions = sum(len(decision_pairs(row)) for row in by_task.values() if not row["completed"])
    counts = {}
    for signal in ("ships", "scouts", "decisions", "unclassified", "links"):
        needed = [backlog_path, archive_path]
        if signal in ("ships", "unclassified", "links") and uses_ledger:
            needed.append(ledger_path)
        if signal == "decisions":
            needed.append(questions_path)
        missing = [str(path) for path in needed if not source_ok(path)]
        count = len(link_items) if signal == "links" else sum(len(project[signal]) for project in ordered_projects)
        if missing:
            counts[signal] = {"status": "not_measurable", "count": None, "observed": count,
                              "reason": "missing or unreadable input", "inputs": missing}
        else:
            counts[signal] = {"status": "measured", "count": count}
    rework = {"reverts": reverts, "closed_unmerged": closed_unmerged,
              "failed_pipelines": failed_pipelines}
    clone_missing = sorted(name for name, info in coverage.items()
                           if (name == str(home / "projects") or name.startswith(str(home / "projects") + os.sep))
                           and info["status"] != "readable")
    forge_missing = sorted(name for name, info in coverage.items()
                           if (name.startswith("forge:") or name.startswith(str(home / "state") + os.sep)
                               or name in (str(backlog_path), str(archive_path)))
                           and info["status"] != "readable")
    if uses_ledger and not source_ok(ledger_path) and str(ledger_path) not in forge_missing:
        forge_missing.append(str(ledger_path))
        forge_missing.sort()
    for signal, missing in (("reverts", clone_missing), ("closed_unmerged", forge_missing),
                            ("failed_pipelines", forge_missing)):
        observed = len(rework[signal])
        if signal == "closed_unmerged":
            reason = "candidate coverage limited to recorded task PR and MR URLs"
            counts[signal] = {"status": "not_measurable", "count": None, "observed": observed,
                              "reason": reason + ("; missing or unreadable input" if missing else ""),
                              "inputs": missing}
        else:
            counts[signal] = ({"status": "not_measurable", "count": None, "observed": observed,
                               "reason": "missing or unreadable input", "inputs": missing}
                              if missing else {"status": "measured", "count": observed})
    counts["hostupdate_mr_pipeline_wall_time"] = hostupdate_coverage
    counts["production_evidence"] = production_coverage
    return {
        "schema": "fm-wake-daily.v1",
        "day": day,
        "timezone": "America/Los_Angeles",
        "contributions": {"projects": ordered_projects},
        "links": {"items": link_items},
        "rework": rework,
        "hostupdate_mr_pipeline_wall_time": hostupdate_pipelines,
        "production_evidence": production,
        "coverage": {
            "inputs": {name: coverage[name] for name in sorted(coverage)},
            "signals": counts,
            "ledger_duplicates_dropped": dropped,
            "merge_time_source": "fleet-ledger" if uses_ledger else "done-archive",
            "forge_candidates": forge_candidates,
            "uncounted_decisions": {"count": open_task_decisions, "reason": "answer time unknown (task still open)"},
            "limits": [
                "Sessions outside firstmate are invisible.",
                "Backlog-only dates are day-level; backlog decisions are dated by their task's close date.",
                "A merge is a contribution, not proof of production value.",
            ],
        },
    }


def write_day(day, home):
    output = home / "data/wake/daily" / f"{day}.json"
    if not (home / "data").is_dir():
        raise ValueError(f"home data directory is absent: {home / 'data'}")
    for directory in (home / "data", home / "data/wake", output.parent):
        if directory.is_symlink():
            raise ValueError(f"output directory is a symlink: {directory}")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.is_symlink():
        raise ValueError(f"output file is a symlink: {output}")
    result = build(day, home)
    payload = (json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    if output.exists() and output.read_bytes() == payload:
        return output
    fd, temporary = tempfile.mkstemp(prefix=f".{day}.", dir=output.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return output


def needs_catch_up(output, retry):
    if not output.exists():
        return True
    if not retry:
        return False
    inputs = json.loads(output.read_text(encoding="utf-8"))["coverage"]["inputs"]
    return any(info["status"] != "readable" for info in inputs.values())


def catch_up(home, today):
    failed = 0
    day = WAKE_START
    while day <= today - timedelta(days=2):
        try:
            output = home / "data/wake/daily" / f"{day.isoformat()}.json"
            if needs_catch_up(output, day >= today - timedelta(days=CATCH_UP_RETRY_DAYS)):
                print(write_day(day.isoformat(), home))
        except Exception as error:
            failed += 1
            logging.error("wake daily catch-up failed for %s in %s: %s: %s",
                          day.isoformat(), home, type(error).__name__, error)
        day += timedelta(days=1)
    return failed


def main():
    logging.basicConfig(format="%(asctime)s %(filename)s:%(lineno)d %(levelname)s %(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("day", nargs="?", help="completed Pacific day, YYYY-MM-DD")
    parser.add_argument("--catch-up", action="store_true",
                        help="write missing Wake days once the next day has completed and retry unmeasured recent days")
    parser.add_argument("--home", type=Path, default=Path(os.environ.get("FM_HOME", Path(__file__).resolve().parent.parent)))
    args = parser.parse_args()
    if args.catch_up == bool(args.day):
        parser.error("provide either a day or --catch-up")
    today = datetime.now(PACIFIC).date()
    home = args.home.resolve()
    if args.catch_up:
        lock = home / "state/.wake-daily.lock"
        if not lock.parent.is_dir() or lock.is_symlink():
            parser.error("home state directory is absent or lock is a symlink")
        with lock.open("a+b") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            if catch_up(home, today):
                sys.exit(1)
        return
    try:
        requested = date.fromisoformat(args.day)
        if requested.isoformat() != args.day:
            raise ValueError("noncanonical date")
    except ValueError:
        parser.error("day must be a real YYYY-MM-DD date")
    if requested >= today:
        parser.error(f"day {args.day} is not complete in America/Los_Angeles")
    try:
        output = write_day(args.day, home)
    except ValueError as error:
        parser.error(str(error))
    print(output)


if __name__ == "__main__":
    main()
