#!/usr/bin/env python3
"""Collect one completed Pacific day's fleet outcomes into private data/wake/daily.

Usage: fm-wake-daily.py YYYY-MM-DD [--home HOME]

The output contract is docs/wake-daily.md. This command reads its source files
without modifying them and atomically replaces only the requested daily JSON.
It never interprets a merge as production value. Unimplemented signals have no
section in this version of the record.
"""

import argparse
from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import re
import tempfile
from zoneinfo import ZoneInfo


PACIFIC = ZoneInfo("America/Los_Angeles")
LEDGER_CUTOFF = "2026-11-21"
ROW = re.compile(r"^- \[[ xX]\] ([A-Za-z0-9._-]+) - (.*)$")
META = re.compile(r"\s+\((?:repo|kind|priority|hold|hold-kind|hold-until): [^)]*\)$|\s+\((?:since|merged|reported|done) \d{4}-\d{2}-\d{2}\)$")
URL = re.compile(r"https?://[^\s)<>]+")
PR_URL = re.compile(r"https?://[^\s)<>]+/(?:pull|merge_requests)/\d+[^\s)<>]*")
REPORT = re.compile(r"(?:^|\s)(data/[^\s)]+/report\.md)(?:\s|$)")
DONE = re.compile(r"\((merged|reported|done) (\d{4}-\d{2}-\d{2})\)")
HOLD_KIND = re.compile(r"\(hold-kind: ([^)]+)\)")
LOCAL_NOTE = re.compile(r"(?:^|\s)local main$")
KIND = re.compile(r"\(kind: ([^)]+)\)")
PROJECT = re.compile(r"\(repo: ([^)]+)\)")


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
                "title": title or task,
                "project": project_match.group(1) if project_match else "none recorded",
                "kind": kind,
                "verb": day_match.group(1) if day_match else None,
                "day": day_match.group(2) if day_match else None,
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


def build(day, home):
    coverage = {}
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
        if row["kind"] is None and row["task"] not in ledger_merged_tasks:
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
        report = row["report"] or f"data/{row['task']}/report.md"
        if row["kind"] == "scout" and (row["report"] or (home / report).is_file()):
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

    ordered_projects = []
    for project in sorted(projects):
        signals = projects[project]
        for items in signals.values():
            items.sort(key=lambda item: (item["task"], item["evidence"]))
        ordered_projects.append({"project": project, **signals})

    source_ok = lambda path: coverage[str(path)]["status"] == "readable"
    open_task_decisions = sum(len(decision_pairs(row)) for row in by_task.values() if not row["completed"])
    counts = {}
    for signal in ("ships", "scouts", "decisions"):
        needed = [backlog_path, archive_path]
        if signal == "ships" and uses_ledger:
            needed.append(ledger_path)
        if signal == "decisions":
            needed.append(questions_path)
        missing = [str(path) for path in needed if not source_ok(path)]
        count = sum(len(project[signal]) for project in ordered_projects)
        if missing:
            counts[signal] = {"status": "not_measurable", "count": None, "observed": count,
                              "reason": "missing or unreadable input", "inputs": missing}
        else:
            counts[signal] = {"status": "measured", "count": count}
    return {
        "schema": "fm-wake-daily.v1",
        "day": day,
        "timezone": "America/Los_Angeles",
        "contributions": {"projects": ordered_projects},
        "coverage": {
            "inputs": {name: coverage[name] for name in sorted(coverage)},
            "signals": counts,
            "ledger_duplicates_dropped": dropped,
            "merge_time_source": "fleet-ledger" if uses_ledger else "done-archive",
            "uncounted_decisions": {"count": open_task_decisions, "reason": "answer time unknown (task still open)"},
            "limits": [
                "Sessions outside firstmate are invisible.",
                "Backlog-only dates are day-level; backlog decisions are dated by their task's close date.",
                "A merge is a contribution, not proof of production value.",
            ],
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("day", help="completed Pacific day, YYYY-MM-DD")
    parser.add_argument("--home", type=Path, default=Path(os.environ.get("FM_HOME", Path(__file__).resolve().parent.parent)))
    args = parser.parse_args()
    try:
        requested = date.fromisoformat(args.day)
        if requested.isoformat() != args.day:
            raise ValueError("noncanonical date")
    except ValueError:
        parser.error("day must be a real YYYY-MM-DD date")
    if requested >= datetime.now(PACIFIC).date():
        parser.error(f"day {args.day} is not complete in America/Los_Angeles")
    home = args.home.resolve()
    result = build(args.day, home)
    output = home / "data/wake/daily" / f"{args.day}.json"
    if not (home / "data").is_dir():
        parser.error(f"home data directory is absent: {home / 'data'}")
    payload = (json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    for directory in (home / "data", home / "data/wake", output.parent):
        if directory.is_symlink():
            parser.error(f"output directory is a symlink: {directory}")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.is_symlink():
        parser.error(f"output file is a symlink: {output}")
    if output.exists() and output.read_bytes() == payload:
        print(output)
        return
    fd, temporary = tempfile.mkstemp(prefix=f".{args.day}.", dir=output.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(output)


if __name__ == "__main__":
    main()
