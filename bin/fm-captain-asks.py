#!/usr/bin/env python3
"""Record and check explicit delivery asks in the active Firstmate home.

The fm-captain-asks.v1 store is data/captain-asks.json. An absent store is empty.
Use --help for commands. sweep is the watcher entry point; it appends a durable
check wake through fm-wake-lib.sh before remembering an alert. Verification is
read-only. A passing predicate or captured captain acceptance closes an ask.
"""

import argparse
import csv
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = "fm-captain-asks.v1"
KINDS = ("deploy-prod", "deploy-dev", "merge", "project-priority")
OPEN = ("queued", "working", "awaiting-approval", "blocked", "verifying", "needs-evidence")
DELIVERY = KINDS[:3]
MAX_SWEEP = 12
SWEEP_BUSY = 75
SWEEP_INPUTS = ("state", "verifier", "target", "linked_task", "waiting_question", "due")


def utcnow():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def stamp(value):
    return value.isoformat().replace("+00:00", "Z")


def parse_time(value):
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp needs a timezone")
    return parsed.astimezone(dt.timezone.utc)


def text_file(path):
    source = Path(path)
    if source.is_symlink() or not source.is_file():
        raise ValueError(f"not a regular file: {path}")
    result = source.read_text(encoding="utf-8")
    if not result.strip():
        raise ValueError(f"empty text file: {path}")
    return result


def home_path(args):
    return Path(args.home or os.environ.get("FM_HOME") or ROOT).resolve()


def config(home):
    path = home / "config/captain-asks.json"
    if not path.exists():
        return {"scan_seconds": 600, "first_alert_seconds": 1800, "reminder_seconds": 3600}
    if path.is_symlink():
        raise ValueError("captain asks config is a symlink")
    settings = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(settings, dict) or set(settings) - {"scan_seconds", "first_alert_seconds", "reminder_seconds"}:
        raise ValueError("invalid captain asks config")
    defaults = {"scan_seconds": 600, "first_alert_seconds": 1800, "reminder_seconds": 3600}
    defaults.update(settings)
    if any(type(v) is not int or v < 1 or v > 86400 for v in defaults.values()):
        raise ValueError("captain asks intervals must be positive seconds up to one day")
    return defaults


def validate_verifier(spec, allow_unknown=False):
    if spec is None:
        return
    if not isinstance(spec, dict):
        raise ValueError("verifier must be an object")
    kind = spec.get("type")
    required = ({"type", "url", "path", "expected_prefix"} if kind == "http-json-field-equals"
                else {"type", "url", "sha"} if kind == "forge-mr-merged-at-sha"
                else {"type", "url", "sha", "hosts"} if kind == "host-rollout-receipt" else None)
    if required is None:
        if allow_unknown and isinstance(kind, str) and kind:
            return
        raise ValueError("unknown or invalid verifier")
    strings = required - {"hosts"}
    if set(spec) != required or any(not isinstance(spec[k], str) or not spec[k] for k in strings):
        raise ValueError("unknown or invalid verifier")
    if kind == "host-rollout-receipt" and (not isinstance(spec["hosts"], list) or not spec["hosts"]
            or any(not isinstance(host, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,252}", host)
                   for host in spec["hosts"]) or len(set(spec["hosts"])) != len(spec["hosts"])):
        raise ValueError("rollout verifier hosts are invalid")
    url = urllib.parse.urlsplit(spec["url"])
    if url.scheme != "https" and not (url.scheme == "http" and url.hostname in ("localhost", "127.0.0.1", "::1")):
        raise ValueError("verifier URL must be HTTPS (or loopback HTTP)")
    if url.username or url.password or not url.netloc or url.fragment:
        raise ValueError("invalid verifier URL")
    if kind in ("forge-mr-merged-at-sha", "host-rollout-receipt") and not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", spec["sha"]):
        raise ValueError("verifier SHA is invalid")
    if kind == "host-rollout-receipt" and not re.fullmatch(r"/.+/-/jobs/[1-9][0-9]*/?", url.path):
        raise ValueError("rollout verifier job URL is invalid")


def validate(doc):
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA or not isinstance(doc.get("asks"), list):
        raise ValueError("invalid captain asks store")
    seen_ids, seen_keys = set(), set()
    for row in doc["asks"]:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not re.fullmatch(r"a-[0-9]{8}-[0-9a-f]{8}", row["id"]):
            raise ValueError("invalid ask id")
        if row["id"] in seen_ids or row.get("key") in seen_keys:
            raise ValueError("duplicate ask id or key")
        seen_ids.add(row["id"])
        seen_keys.add(row.get("key"))
        if row.get("kind") not in KINDS or row.get("state") not in OPEN + ("verified", "archived"):
            raise ValueError("invalid ask kind or state")
        for field in ("key", "intent", "source", "project", "requested_target", "target"):
            if not isinstance(row.get(field), str) or not row[field].strip():
                raise ValueError(f"ask {field} is missing")
        if not isinstance(row.get("linked_task"), str) or not isinstance(row.get("no_task_reason"), str):
            raise ValueError("ask task link is invalid")
        if row.get("waiting_question") is not None and (not isinstance(row["waiting_question"], str)
                or not re.fullmatch(r"q-[0-9]{8}-[0-9a-f]{8}", row["waiting_question"])):
            raise ValueError("ask waiting question is invalid")
        if not row["linked_task"] and not row["no_task_reason"]:
            raise ValueError("ask needs a linked task or no-task reason")
        for field in ("created", "next_check"):
            parse_time(row[field])
        if row.get("due") is not None:
            parse_time(row["due"])
        if not isinstance(row.get("evidence"), list) or not isinstance(row.get("alert"), dict):
            raise ValueError("ask evidence or alert is invalid")
        if row.get("verification") is not None and not isinstance(row["verification"], dict):
            raise ValueError("ask verification is invalid")
        validate_verifier(row.get("verifier"), allow_unknown=True)
        if row["state"] == "verified" and not any(e.get("result") in ("pass", "captain-accept") for e in row["evidence"]):
            raise ValueError("verified ask lacks closing evidence")
        if row["state"] == "archived" and not row.get("archive_reason"):
            raise ValueError("archived ask lacks a reason")


def load(path):
    if not path.exists():
        return {"schema": SCHEMA, "asks": []}
    if path.is_symlink():
        raise ValueError("captain asks store is a symlink")
    doc = json.loads(path.read_text(encoding="utf-8"))
    validate(doc)
    return doc


def save(path, doc):
    validate(doc)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, staged = tempfile.mkstemp(prefix=".captain-asks.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(doc, out, ensure_ascii=False, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(staged, path)
    finally:
        if os.path.exists(staged):
            os.unlink(staged)


@contextlib.contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = path.with_suffix(".lock")
    if lock.is_symlink():
        raise ValueError("captain asks lock is a symlink")
    with lock.open("a+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def find(doc, ask_id):
    return next((row for row in doc["asks"] if row["id"] == ask_id), None)


def fetch_json(url):
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "firstmate-captain-asks/1"})
    with urllib.request.urlopen(request, timeout=2) as response:
        if response.status != 200 or int(response.headers.get("Content-Length", "0")) > 262144:
            raise ValueError("verifier response unavailable or too large")
        body = response.read(262145)
    if len(body) > 262144:
        raise ValueError("verifier response too large")
    return json.loads(body)


def fetch_gitlab_mr(parsed, project, number):
    if parsed.scheme == "http":
        endpoint = f"{parsed.scheme}://{parsed.netloc}/api/v4/projects/{project}/merge_requests/{number}"
        return fetch_json(endpoint)
    result = subprocess.run(["glab", "api", "--hostname", parsed.hostname,
                             f"projects/{project}/merge_requests/{number}"],
                            capture_output=True, text=True, timeout=4)
    if result.returncode or len(result.stdout) > 262144:
        raise ValueError("forge MR is unavailable through authenticated read-only API")
    return json.loads(result.stdout)


class GitLabRefused(ValueError):
    """GitLab answered 400 or 404 for a well-formed request."""


def fetch_gitlab_project(parsed, endpoint):
    if parsed.scheme == "http":
        try:
            return fetch_json(f"{parsed.scheme}://{parsed.netloc}/api/v4/{endpoint}")
        except urllib.error.HTTPError as error:
            if error.code in (400, 404):
                raise GitLabRefused(f"GitLab answered HTTP {error.code}") from error
            raise
    result = subprocess.run(["glab", "api", "--hostname", parsed.hostname, endpoint],
                            capture_output=True, text=True, timeout=4)
    refused = re.search(r"\(HTTP (400|404)\)", result.stderr)
    if result.returncode and refused:
        raise GitLabRefused(f"GitLab answered HTTP {refused.group(1)}")
    if result.returncode or len(result.stdout) > 262144:
        raise ValueError("GitLab rollout evidence is unavailable through authenticated read-only API")
    return json.loads(result.stdout)


def verify_host_rollout(spec, parsed):
    match = re.fullmatch(r"/(.+)/-/jobs/([1-9][0-9]*)/?", parsed.path)
    if not match:
        raise ValueError("rollout verifier job URL is invalid")
    project = urllib.parse.quote(urllib.parse.unquote(match.group(1)), safe="")
    job_id = match.group(2)
    root = f"projects/{project}"
    job = fetch_gitlab_project(parsed, f"{root}/jobs/{job_id}")
    if not isinstance(job, dict) or job.get("id") != int(job_id):
        raise ValueError("GitLab rollout job response is invalid")
    if job.get("status") != "success":
        return "mismatch", f"job status={job.get('status')}", spec["url"]
    receipt = fetch_gitlab_project(parsed, f"{root}/jobs/{job_id}/artifacts/deploy-event.json")
    if not isinstance(receipt, dict) or receipt.get("schema_version") != 1 or not isinstance(receipt.get("events"), list):
        raise ValueError("GitLab rollout receipt is invalid")
    proven = set()
    for event in receipt["events"]:
        if not isinstance(event, dict):
            raise ValueError("GitLab rollout event is invalid")
        host = event.get("host")
        commit = event.get("commit_sha")
        if host not in spec["hosts"] or not isinstance(commit, str) or not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", commit):
            continue
        if (event.get("outcome") not in ("changed", "no_change") or event.get("ansible_exit_code") != 0
                or event.get("runner_exit_code") != 0 or event.get("job_status") != "success"):
            continue
        if commit.lower() != spec["sha"].lower():
            query = urllib.parse.urlencode([("refs[]", spec["sha"]), ("refs[]", commit)])
            try:
                base = fetch_gitlab_project(parsed, f"{root}/repository/merge_base?{query}")
            except GitLabRefused:
                continue
            if (not isinstance(base, dict) or not isinstance(base.get("id"), str)
                    or base["id"].lower() != spec["sha"].lower()):
                continue
        proven.add(host)
    missing = sorted(set(spec["hosts"]) - proven)
    return ("mismatch" if missing else "pass"), (f"unproven hosts: {', '.join(missing)}" if missing else
            f"successful rollout receipt for {', '.join(sorted(proven))}"), spec["url"]


def verify_predicate(spec):
    if spec is None:
        return "unknown", "no verifier", None
    try:
        validate_verifier(spec)
        if spec["type"] == "http-json-field-equals":
            doc = fetch_json(spec["url"])
            value = doc
            for part in spec["path"].split("."):
                if not part or not isinstance(value, dict):
                    raise ValueError("JSON path unavailable")
                value = value[part]
            if not isinstance(value, str):
                raise ValueError("JSON field is not a string")
            expected = spec["expected_prefix"]
            passed = value == expected if re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", expected) else value.startswith(expected)
            return ("pass" if passed else "mismatch"), f"observed {value}", spec["url"]
        if spec["type"] == "host-rollout-receipt":
            return verify_host_rollout(spec, urllib.parse.urlsplit(spec["url"]))
        parsed = urllib.parse.urlsplit(spec["url"])
        match = re.fullmatch(r"/(.+)/-/merge_requests/([1-9][0-9]*)/?", parsed.path)
        if not match:
            raise ValueError("forge MR URL is invalid")
        project = urllib.parse.quote(urllib.parse.unquote(match.group(1)), safe="")
        doc = fetch_gitlab_mr(parsed, project, match.group(2))
        if not isinstance(doc, dict):
            raise ValueError("forge MR response is invalid")
        landed = {doc.get(field) for field in ("merge_commit_sha", "squash_commit_sha", "sha")}
        passed = doc.get("state") == "merged" and spec["sha"] in landed
        detail = (f"state={doc.get('state')} merge_sha={doc.get('merge_commit_sha')} "
                  f"squash_sha={doc.get('squash_commit_sha')} head_sha={doc.get('sha')}")
        return ("pass" if passed else "mismatch"), detail, spec["url"]
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired,
            urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        return "unknown", str(error)[:240], spec.get("url")


def check_verifier(spec, now):
    result, detail, url = verify_predicate(spec)
    return {"at": stamp(now), "result": result, "detail": detail, "url": url}


def record_verification(row, entry):
    row["verification"] = entry
    if not row["evidence"] or row["evidence"][-1]["result"] != entry["result"] or row["evidence"][-1]["detail"] != entry["detail"]:
        row["evidence"].append(entry)
    if entry["result"] == "pass":
        row["state"] = "verified"


def captured_answers(home, path, source):
    """Apply choices already extracted from a bound Lavish result."""
    for line in sys.stdin:
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 3 or not fields[0].startswith("captain-ask."):
            continue
        ask_id = fields[0].removeprefix("captain-ask.")
        selection, note = fields[1:]
        if selection not in ("accept", "rework") or (selection == "rework" and not note.strip()):
            continue
        with locked(path):
            doc = load(path)
            row = find(doc, ask_id)
            if row is None or row["state"] not in OPEN:
                continue
            if any(item.get("source") == source for item in row["evidence"]):
                continue
            at = stamp(utcnow())
            entry = {"at": at, "result": "captain-accept" if selection == "accept" else "rework",
                     "detail": note if note else "Accept", "url": None, "source": source}
            row["evidence"].append(entry)
            if selection == "accept":
                row["state"] = "verified"
            else:
                row["state"] = "working"
                row["waiting_question"] = None
                row["next_check"] = at
            append_wake(home, f"captain-ask:{ask_id}",
                        f"check: captain ask {ask_id} ({row['project']}): captain {selection}"
                        + (f" - {note[:160]}" if selection == "rework" else ""))
            save(path, doc)


def worker_live(home, task_id):
    meta = home / "state" / f"{task_id}.meta"
    if not task_id or not re.fullmatch(r"[A-Za-z0-9._-]+", task_id) or meta.is_symlink() or not meta.is_file():
        return False
    result = subprocess.run([str(ROOT / "bin/fm-crew-state.sh"), task_id],
                            env={**os.environ, "FM_HOME": str(home), "FM_CREW_STATE_NO_FORGE": "1"},
                            capture_output=True, text=True, timeout=10)
    match = re.match(r"state: ([a-z]+) · source: ", result.stdout)
    if match is None:
        raise ValueError(f"crew state unavailable for {task_id}")
    return match.group(1) == "working"


def project_live(home, project):
    for meta in sorted((home / "state").glob("*.meta"))[:500]:
        if meta.is_symlink() or not meta.is_file():
            continue
        fields = dict(line.split("=", 1) for line in meta.read_text(encoding="utf-8", errors="replace").splitlines() if "=" in line)
        if fields.get("project", fields.get("repo")) != project or fields.get("kind") == "secondmate":
            continue
        if worker_live(home, meta.stem):
            return True
    return False


def backlog_rows(home, project, state_name):
    result = subprocess.run([str(ROOT / "bin/fm-tasks-axi.sh"), "list", "--state", state_name, "--repo", project,
                             "--limit", "500", "--fields", "blocked,held,hold_kind"],
                            env={**os.environ, "FM_HOME": str(home)}, capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise ValueError(f"backlog reader unavailable: {result.stderr.strip()[:160]}")
    count = re.search(r"^count: ([0-9]+)$", result.stdout, re.M)
    if count is None:
        raise ValueError(f"{state_name} backlog response is invalid")
    header = next((line for line in result.stdout.splitlines() if line.startswith("tasks[") and "{" in line), "")
    if not header:
        if int(count.group(1)):
            raise ValueError(f"{state_name} backlog rows are unavailable")
        return []
    columns = header.split("{", 1)[1].split("}", 1)[0].split(",")
    if not {"id", "blocked", "held", "hold_kind"}.issubset(columns):
        raise ValueError(f"{state_name} backlog fields are unavailable")
    rows = []
    for line in result.stdout.splitlines():
        if not line.startswith("  ") or line.startswith("  -"):
            continue
        values = next(csv.reader([line.strip()]))
        if len(values) == len(columns):
            rows.append(dict(zip(columns, values)))
    return rows


def open_question_ids(home):
    questions = home / "data/captain-questions.json"
    if questions.is_symlink():
        raise ValueError("captain questions record is a symlink")
    if not questions.is_file():
        return set()
    try:
        document = json.loads(questions.read_text(encoding="utf-8"))
        if document.get("schema") != "fm-captain-questions.v1" or not isinstance(document.get("questions"), list):
            raise ValueError("invalid captain questions record")
        return {q.get("id") for q in document["questions"] if q.get("state") == "open"}
    except (ValueError, TypeError, AttributeError) as error:
        raise ValueError("captain questions unavailable") from error


def priority_state(home, row):
    live = project_live(home, row["project"])
    queued = any(r["blocked"] == "no" and r["held"] == "no" for r in backlog_rows(home, row["project"], "queued"))
    held = (any(r["hold_kind"] == "captain" for r in backlog_rows(home, row["project"], "held"))
            or row.get("waiting_question") in open_question_ids(home))
    return live, queued, held


def append_wake(home, key, reason):
    script = '. "$1"; fm_wake_append check "$2" "$3"'
    result = subprocess.run(["bash", "-c", script, "_", str(ROOT / "bin/fm-wake-lib.sh"), key, reason],
                            env={**os.environ, "FM_HOME": str(home)}, capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise ValueError(f"wake append failed: {result.stderr.strip()[:200]}")


def sweep(home, path, now):
    if not path.exists() and not path.is_symlink():
        return []
    settings = config(home)
    doc = load(path)
    emitted = []
    due = [r for r in sorted((r for r in doc["asks"] if r["state"] in OPEN), key=lambda r: r["next_check"])[:MAX_SWEEP]
           if parse_time(r["next_check"]) <= now]
    for snapshot in due:
        waiting = False
        verification = None
        try:
            if snapshot["kind"] in DELIVERY:
                verification = check_verifier(snapshot["verifier"], now)
            if verification is not None and verification["result"] == "pass":
                actionable, detail, fingerprint = False, "", ""
            elif snapshot["kind"] == "project-priority":
                live, queued, held = priority_state(home, snapshot)
                actionable = not (live or queued or held)
                detail = "idle priority project: no live worker, startable queued task, or open captain hold/question"
                fingerprint = f"priority:{live}:{queued}:{held}"
            else:
                live = worker_live(home, snapshot["linked_task"])
                waiting = snapshot["state"] == "awaiting-approval" or snapshot.get("waiting_question") in open_question_ids(home)
                age = int((now - parse_time(snapshot["created"])).total_seconds())
                actionable = bool(snapshot["due"] and parse_time(snapshot["due"]) <= now) or (not live and age >= settings["first_alert_seconds"])
                detail = (f"{snapshot['kind']} target {snapshot['target']} remains {snapshot['state']} "
                          f"({age // 60}m old; linked worker={'live' if live else 'absent'})")
                fingerprint = f"{snapshot['target']}:{live}:{verification['result']}"
        except (ValueError, OSError, subprocess.TimeoutExpired) as error:
            actionable = True
            detail = f"check failed: {str(error)[:200]}"
            fingerprint = f"error:{detail}"
        with locked(path):
            doc = load(path)
            row = find(doc, snapshot["id"])
            if (row is None or row["state"] not in OPEN or parse_time(row["next_check"]) > now
                    or any(row.get(field) != snapshot.get(field) for field in SWEEP_INPUTS)):
                continue
            if verification is not None:
                record_verification(row, verification)
            if row["state"] != "verified":
                alert = row["alert"]
                last = parse_time(alert["at"]) if alert.get("at") else None
                reminder = not waiting and last is not None and (now - last).total_seconds() >= settings["reminder_seconds"]
                row["next_check"] = stamp(now + dt.timedelta(seconds=settings["scan_seconds"]))
                if actionable and (alert.get("fingerprint") != fingerprint or reminder):
                    reason = f"check: captain ask {row['id']} ({row['project']}): {detail}"
                    append_wake(home, f"captain-ask:{row['id']}", reason)
                    row["alert"] = {"at": stamp(now), "fingerprint": fingerprint}
                    emitted.append(reason)
                elif not actionable and alert:
                    row["alert"] = {}
            save(path, doc)
    return emitted


def render_page(doc, home, output):
    now = utcnow()
    rows = []
    for row in doc["asks"]:
        if row["state"] not in OPEN:
            continue
        idle = ""
        if row["kind"] == "project-priority":
            try:
                live, queued, held = priority_state(home, row)
                idle = "idle" if not (live or queued or held) else "covered"
            except (ValueError, OSError, subprocess.TimeoutExpired) as error:
                idle = f"unavailable: {str(error)[:160]}"
        rows.append({"key": f"captain-ask.{row['id']}", "project": row["project"],
                     "title": row["target"], "kind": row["kind"], "state": row["state"],
                     "verifier": "" if row["kind"] == "project-priority"
                     else (row.get("verification") or {}).get("result", "unchecked"),
                     "verifier_detail": (row.get("verification") or {}).get("detail", ""),
                     "priority": idle, "owner": "Captain" if row["state"] == "awaiting-approval"
                     or row.get("waiting_question") else "Firstmate",
                     "age": max(0, int((now - parse_time(row["created"])).total_seconds() // 60))})
    rows.sort(key=lambda item: (item["project"].casefold(), item["owner"], item["title"].casefold()))
    payload = {"schema": "fm-decision-page.v1", "questions": [{"key": row["key"]} for row in rows],
               "rows": rows, "generated": stamp(now)}
    data = json.dumps(payload, ensure_ascii=False).replace("<", "\\u003c")
    content = '''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Outstanding asks</title>
<style>
:root{font-family:system-ui,sans-serif;color:#172a36;background:#f5f7f6;color-scheme:light;
--muted:#52636d;--soft:#40565f;--line:#d5dedf;--edge:#ccd6d7;--accent:#275a55;--attn:#9a4a14}
*{box-sizing:border-box}[hidden]{display:none!important}::selection{background:#cfe3df;color:#172a36}
body{margin:0}main{max-width:1320px;margin:auto;padding:36px 24px 72px}
h1{font-size:clamp(1.6rem,3vw,2.1rem);letter-spacing:-.025em;margin:0 0 6px}h2{font-size:1.1rem;margin:40px 0 14px}
h3{font-size:.8rem;font-weight:650;color:var(--muted);margin:0 0 6px}
.sub{color:var(--muted);margin:0 0 20px}.count{font-variant-numeric:tabular-nums}
.table-wrap{background:#fff;border:1px solid var(--edge);border-radius:12px;overflow:hidden}
.asks{border-collapse:collapse;width:100%;table-layout:fixed;font-size:.875rem;line-height:1.35}
.asks th,.asks td{text-align:left;padding:9px 10px;vertical-align:top;border-bottom:1px solid var(--line);overflow-wrap:break-word}
.asks thead th{background:#e9efee;font-size:.78rem;font-weight:650;color:var(--soft);vertical-align:bottom}
.asks tbody tr:last-child td{border-bottom:0}.asks tr.ask:hover{background:#f6f9f8}
.asks .age{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.project{font-weight:600}.project.repeat,.owner{color:var(--muted);font-weight:400}.owner.captain{color:inherit;font-weight:650}
.ask-title{font-weight:600;overflow-wrap:anywhere}
.detail{display:block;width:100%;margin:2px 0 0;padding:0;border:0;background:none;font:inherit;font-size:.78rem;color:var(--muted);text-align:left;
white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
button.detail{cursor:pointer}button.detail:hover{color:#172a36}button.detail[aria-expanded=true]{white-space:normal;overflow-wrap:anywhere}
.st{display:inline-flex;align-items:baseline;gap:7px}
.st:before{content:'';flex:none;width:8px;height:8px;border-radius:50%;border:1.5px solid #8a9aa1}
.st.ok:before{background:var(--accent);border-color:var(--accent)}
.st.attn{color:var(--attn);font-weight:600}.st.attn:before{background:var(--attn);border-color:var(--attn)}
.asks td.decide{padding-top:5px;padding-bottom:5px;white-space:nowrap}
.act{display:inline-grid;place-items:center;width:28px;height:28px;padding:0;border:1px solid #b9c8cb;border-radius:6px;
background:#fff;color:var(--soft);cursor:pointer;vertical-align:top}.act+.act{margin-left:6px}
.act:hover{border-color:var(--accent);color:var(--accent);background:#eef4f3}
.act[aria-expanded=true]{background:var(--accent);border-color:var(--accent);color:#fff}
.queued{display:inline-block;padding:4px 0;color:var(--accent);font-weight:650;font-size:.8rem;white-space:normal}
.asks tr.decide-row td{background:#f1f6f5;padding:9px 10px}
.decide-row form{display:flex;align-items:center;justify-content:flex-end;gap:10px;flex-wrap:wrap}
.note-label{font-weight:650;font-size:.82rem;white-space:nowrap}
.note{flex:1 1 260px;min-width:0;max-width:560px;padding:6px 10px;border:1px solid #9bafb3;border-radius:6px;
font:inherit;color:inherit;background:#fff;caret-color:var(--accent)}.note::placeholder{color:#5d6e77;opacity:1}
.send{background:var(--accent);color:#fff;border:0;border-radius:6px;padding:7px 14px;font:inherit;font-weight:650;cursor:pointer}
.send:hover{background:#17423e}
.cancel{background:none;border:0;padding:7px 4px;font:inherit;color:var(--soft);cursor:pointer;text-decoration:underline;text-underline-offset:3px}
button:focus-visible,input:focus-visible{outline:3px solid #b17631;outline-offset:2px}
.error{flex-basis:100%;color:#a12020;font-size:.82rem}.error:empty{display:none}
.empty{margin:0;padding:22px;background:#fff;border:1px solid var(--edge);border-radius:12px}
.legend{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:22px 36px;align-items:start;font-size:.84rem;line-height:1.4}
.legend .tall{grid-row:span 2}.legend dl{margin:0;display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 14px}
.legend dt{font-weight:600}.legend dd{margin:0;color:var(--soft)}.legend dt svg{vertical-align:-3px;margin-right:6px}
@media(max-width:860px){main{padding:22px 14px 48px}.table-wrap{background:none;border:0;border-radius:0;overflow:visible}
.asks colgroup,.asks thead{display:none}.asks,.asks tbody,.asks td{display:block}
.asks tr.ask{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px 14px;background:#fff;border:1px solid var(--edge);border-radius:12px;padding:12px 14px;margin-top:10px}
.asks tr.ask td{border:0;padding:0}.asks td:empty{display:none}.asks td[data-label]:before{content:attr(data-label);display:block;font-size:.72rem;font-weight:400;color:var(--muted)}
.asks td.project,.asks td.title{grid-column:1/-1}.asks td.project:before,.asks td.title:before{display:none}.project.repeat{color:inherit;font-weight:600}
.asks .age{text-align:left}.act{width:40px;height:40px}.act+.act{margin-left:10px}
.asks tr.decide-row{display:block;margin-top:6px}.asks tr.decide-row td{border:1px solid var(--edge);border-radius:12px;padding:12px 14px}}
</style></head><body><main><h1>Outstanding asks</h1>
<p class="sub"><span class="count" id="count"></span> open<span class="count" id="captain"></span> · Updated <span id="updated"></span></p>
<div class="table-wrap" id="ledger"><table class="asks" aria-label="Open asks"><colgroup><col style="width:132px"><col><col style="width:128px">
<col style="width:146px"><col style="width:116px"><col style="width:96px"><col style="width:94px"><col style="width:52px"><col style="width:84px"></colgroup>
<thead><tr><th scope="col">Project</th><th scope="col">Ask</th><th scope="col">Kind</th><th scope="col">State</th><th scope="col">Verifier</th>
<th scope="col">Priority coverage</th><th scope="col">Waiting on</th><th scope="col" class="age">Age</th><th scope="col">Decide</th></tr></thead>
<tbody id="rows"></tbody></table></div>
<section aria-labelledby="legend-title"><h2 id="legend-title">Legend</h2><div class="legend">
<section><h3>Kind</h3><dl><dt>Prod deploy</dt><dd>Roll out a change to production.</dd>
<dt>Dev deploy</dt><dd>Roll out a change to a development environment.</dd>
<dt>Merge</dt><dd>Land a proposed change.</dd><dt>Priority project</dt><dd>Keep work moving on a named project.</dd></dl></section>
<section class="tall"><h3>State</h3><dl><dt><span class="st">Queued</span></dt><dd>The ask is recorded and work has not started.</dd>
<dt><span class="st">Working</span></dt><dd>Firstmate is driving the ask.</dd>
<dt><span class="st attn">Waiting</span></dt><dd>The captain’s decision or approval is needed.</dd>
<dt><span class="st attn">Blocked</span></dt><dd>Progress needs a dependency or intervention.</dd>
<dt><span class="st">Verifying</span></dt><dd>Delivery evidence is being checked.</dd>
<dt><span class="st attn">Needs evidence</span></dt><dd>Delivery still needs proof.</dd>
<dt><span class="st ok">Verified</span></dt><dd>Evidence passed or the captain accepted the ask.</dd>
<dt><span class="st">Archived</span></dt><dd>The ask was removed with a recorded reason.</dd></dl></section>
<section><h3>Verifier</h3><dl><dt><span class="st ok">Pass</span></dt><dd>The configured check proved delivery.</dd>
<dt><span class="st">Mismatch</span></dt><dd>The check ran but did not prove delivery.</dd>
<dt><span class="st">Unknown</span></dt><dd>No usable check or evidence is available yet.</dd>
<dt><span class="st">Unchecked</span></dt><dd>The verifier has not run yet.</dd></dl></section>
<section><h3>Priority coverage</h3><dl><dt><span class="st ok">Covered</span></dt><dd>A priority project has work or a captain hold.</dd>
<dt><span class="st attn">Idle</span></dt><dd>A priority project has no qualifying work or hold.</dd>
<dt><span class="st attn">Unavailable</span></dt><dd>Coverage could not be read; the reason is under the ask.</dd></dl></section>
<section><h3>Decide</h3><dl><dt id="legend-accept">Accept</dt><dd>Close the ask as delivered. A note is optional.</dd>
<dt id="legend-rework">Rework</dt><dd>Send the ask back to firstmate with a note.</dd></dl></section>
</div></section></main><script id="decision-page-data" type="application/json">\n''' + data + '''\n</script><script>
(function(){"use strict";const data=JSON.parse(document.getElementById("decision-page-data").textContent);
const el=function(tag,cls,text){const node=document.createElement(tag);if(cls)node.className=cls;if(text!=null)node.textContent=text;return node};
const cap=function(text){return text?text.charAt(0).toUpperCase()+text.slice(1):''};
const svg=function(path){return '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="'+path+'"/></svg>'};
const ICON={accept:svg('M3 8.5l3.2 3.2L13 4.8'),rework:svg('M6 3L3 6l3 3M3 6h6.5a3.5 3.5 0 010 7H7')};
for(const mode of ['accept','rework'])document.getElementById('legend-'+mode).insertAdjacentHTML('afterbegin',ICON[mode]);
const KIND={"deploy-prod":"Prod deploy","deploy-dev":"Dev deploy","merge":"Merge","project-priority":"Priority project"};
const STATE={"awaiting-approval":"Waiting","needs-evidence":"Needs evidence"};
const ATTN=['Waiting','Blocked','Needs evidence','Idle','Unavailable'],OK=['Pass','Covered'];
const cell=function(label,cls,text){const td=el('td',cls,text);td.dataset.label=label;return td};
const status=function(label,value){const td=cell(label);
if(value)td.appendChild(el('span','st'+(ATTN.includes(value)?' attn':OK.includes(value)?' ok':''),value));return td};
const age=function(minutes){return minutes<60?minutes+'m':minutes<2880?Math.floor(minutes/60)+'h':Math.floor(minutes/1440)+'d'};
const waiting=data.rows.filter(function(row){return row.owner==='Captain'}).length;
document.getElementById("count").textContent=data.rows.length;document.getElementById("updated").textContent=data.generated;
if(waiting)document.getElementById("captain").textContent=' · '+waiting+' waiting on captain';
const ledger=document.getElementById("ledger");
if(!data.rows.length){ledger.replaceWith(el('p','empty','No open asks.'));return}
const body=document.getElementById("rows");let project=null;data.rows.forEach(function(row,index){
const tr=el('tr','ask');tr.appendChild(cell('Project','project'+(row.project===project?' repeat':''),row.project));project=row.project;
const title=cell('Ask','title');title.appendChild(el('div','ask-title',row.title));
let coverage=cap(row.priority);const details=[];if(row.verifier_detail)details.push('Verifier detail: '+row.verifier_detail);
if(coverage.startsWith('Unavailable')){details.push('Priority coverage u'+coverage.slice(1));coverage='Unavailable'}
for(const text of details)title.appendChild(el('div','detail',text));
tr.append(title,cell('Kind','',KIND[row.kind]||row.kind),status('State',STATE[row.state]||cap(row.state)),status('Verifier',cap(row.verifier)),
status('Priority coverage',coverage),cell('Waiting on','owner'+(row.owner==='Captain'?' captain':''),row.owner),cell('Age','age',age(row.age)));
tr.lastChild.title=row.age+' minutes';
const decide=cell('Decide','decide'),panel=el('tr','decide-row'),holder=el('td'),form=el('form');panel.hidden=true;holder.colSpan=9;
form.noValidate=true;form.id='decide-'+index;form.setAttribute('data-lavish-question',row.key);
const label=el('label','note-label'),note=el('input','note'),send=el('button','send'),cancel=el('button','cancel','Cancel'),error=el('div','error');
note.id=label.htmlFor='note-'+index;note.name='note';note.autocomplete='off';send.type='submit';cancel.type='button';error.setAttribute('role','alert');
form.append(label,note,send,cancel,error);const buttons={};let selection='';
const show=function(mode){selection=mode;panel.hidden=!mode;error.textContent='';
for(const name in buttons)buttons[name].setAttribute('aria-expanded',String(name===mode));if(!mode)return;
label.textContent=mode==='accept'?'Accept note (optional)':'Rework note';
note.placeholder=mode==='accept'?'Anything to record with the acceptance':'What needs to change';
send.textContent=mode==='accept'?'Send accept':'Send rework';note.focus()};
for(const mode of ['accept','rework']){const button=el('button','act');button.type='button';button.innerHTML=ICON[mode];button.title=cap(mode);
button.setAttribute('aria-label',cap(mode)+': '+row.title);button.setAttribute('aria-expanded','false');button.setAttribute('aria-controls',form.id);
button.addEventListener('click',function(){show(selection===mode?'':mode)});buttons[mode]=button;decide.appendChild(button)}
const close=function(){const opener=buttons[selection];show('');if(opener)opener.focus()};
cancel.addEventListener('click',close);
form.addEventListener('keydown',function(event){if(event.key==='Escape'){event.preventDefault();close()}});
form.addEventListener('submit',function(event){event.preventDefault();const text=note.value.trim();
if(selection==='rework'&&!text){error.textContent='Add a rework note.';note.focus();return}
if(new TextEncoder().encode(selection+(text?' - '+text:'')).length>512){error.textContent='Decision is too long (512 bytes maximum).';return}
if(!window.lavish||!window.lavish.queuePrompt){error.textContent='Decision capture is unavailable. Open the published Lavish page.';return}
window.lavish.queuePrompt('Answer - '+row.title+': '+selection+(text?' - '+text:''),{tag:'choice',text:row.title+' -> '+selection+(text?' - '+text:''),element:form,
data:{schema:'fm-decision-page-answer.v1',question:row.key,selection:selection,note:text}});
const queued=el('span','queued',cap(selection)+' queued');queued.tabIndex=-1;queued.setAttribute('role','status');
panel.hidden=true;decide.replaceChildren(queued);queued.focus()});
tr.appendChild(decide);holder.appendChild(form);panel.appendChild(holder);body.append(tr,panel)});
const fit=function(){for(const node of body.querySelectorAll('.detail')){const open=node.getAttribute('aria-expanded')==='true';
const tag=open||node.scrollWidth>node.clientWidth?'button':'div';if(node.localName===tag)continue;const next=el(tag,'detail',node.textContent);
if(tag==='button'){next.type='button';next.title='Show or hide the full detail';next.setAttribute('aria-expanded','false');
next.addEventListener('click',function(){next.setAttribute('aria-expanded',String(next.getAttribute('aria-expanded')!=='true'))})}
node.replaceWith(next)}};fit();window.addEventListener('resize',fit)
})();
</script></body></html>'''
    if output.is_symlink():
        raise ValueError("captain asks page is a symlink")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8")


def publish_page(home, output):
    real = str(output.resolve())
    command = ["lavish-axi", str(output)]
    for attempt in range(2):
        result = subprocess.run(command + (["--reopen"] if attempt else []), capture_output=True, text=True)
        if result.returncode:
            raise ValueError(f"Lavish publish failed: {result.stderr.strip()[:200]}")
        listing = subprocess.run(["lavish-axi"], capture_output=True, text=True)
        if listing.returncode == 0 and any(line.strip().startswith(real + ",open,") for line in listing.stdout.splitlines()):
            env = {**os.environ, "FM_HOME": str(home)}
            adapter = str(ROOT / "bin/fm-procevent-lavish.sh")
            source = subprocess.run([adapter, "source-id", str(output)], env=env,
                                    capture_output=True, text=True)
            if source.returncode:
                raise ValueError("captain asks page source is unavailable")
            source = source.stdout.strip()
            if attempt:
                retired = subprocess.run([adapter, "retire", str(output), "--keep-session"], env=env,
                                         capture_output=True, text=True)
                if retired.returncode:
                    raise ValueError("captain asks page could not retire its prior listener")
            bound = subprocess.run([str(ROOT / "bin/fm-captain-hold.sh"), "bind", source], env=env,
                                   capture_output=True, text=True)
            if bound.returncode:
                raise ValueError("captain asks page could not bind its answer source")
            armed = subprocess.run([adapter, "arm", str(output)], env=env,
                                   capture_output=True, text=True)
            if armed.returncode:
                raise ValueError("captain asks page could not arm its answer source")
            print(result.stdout.strip())
            return
    raise ValueError("Lavish session is not open")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--home", help="Firstmate home (defaults to FM_HOME)")
    sub = parser.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add", help="capture an exact captain ask")
    add.add_argument("--key", required=True, help="stable source-and-target idempotency key")
    add.add_argument("--kind", choices=KINDS, required=True)
    add.add_argument("--intent-file", required=True)
    add.add_argument("--source", required=True)
    add.add_argument("--project", required=True)
    add.add_argument("--task", default="")
    add.add_argument("--waiting-question")
    add.add_argument("--no-task-reason", default="")
    add.add_argument("--target", required=True)
    add.add_argument("--due")
    add.add_argument("--verifier-file")
    sub.add_parser("list", help="print open items as JSON")
    sub.add_parser("dump", help="print the complete ledger as JSON")
    update = sub.add_parser("update", help="update delivery status and evidence")
    update.add_argument("id")
    update.add_argument("--state", choices=OPEN, required=True)
    update.add_argument("--evidence", required=True)
    update.add_argument("--task")
    update.add_argument("--waiting-question")
    update.add_argument("--target")
    update.add_argument("--verifier-file")
    update.add_argument("--due")
    update.add_argument("--next-check")
    verify = sub.add_parser("verify", help="run an allowlisted verifier")
    verify.add_argument("id")
    captured = sub.add_parser("captured-answers", help="apply extracted answers from a bound Lavish source")
    captured.add_argument("--source", required=True)
    archive = sub.add_parser("archive", aliases=["remove"], help="tombstone an ask with a reason")
    archive.add_argument("id")
    archive.add_argument("--reason", required=True)
    sub.add_parser("sweep", help="bounded watcher scan and durable check wake")
    page = sub.add_parser("page", help="render the Lavish ledger page with Accept/Rework decisions")
    page.add_argument("--output")
    page.add_argument("--publish", action="store_true", help="establish and verify an open Lavish session")
    args = parser.parse_args()
    home = home_path(args)
    path = home / "data/captain-asks.json"
    if args.command in ("list", "dump", "page"):
        doc = load(path)
        if args.command == "page":
            if args.publish and args.output:
                raise ValueError("published captain asks page uses the home-local page path")
            output = Path(args.output) if args.output else home / ".lavish/captain-asks.html"
            render_page(doc, home, output)
            print(output)
            if args.publish:
                publish_page(home, output)
        elif args.command == "dump":
            print(json.dumps(doc, ensure_ascii=False))
        else:
            try:
                config(home)
                config_error = None
            except (ValueError, OSError) as error:
                config_error = str(error)
            print(json.dumps({**doc, "asks": [r for r in doc["asks"] if r["state"] in OPEN],
                              "config_error": config_error}, ensure_ascii=False))
        return
    if args.command == "sweep":
        sweep_lock = home / "state/.captain-asks-sweep.lock"
        sweep_lock.parent.mkdir(parents=True, exist_ok=True)
        if sweep_lock.is_symlink():
            raise ValueError("captain asks sweep lock is a symlink")
        with sweep_lock.open("a+") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit(SWEEP_BUSY)
            for reason in sweep(home, path, utcnow()):
                print(reason)
        return
    if args.command == "captured-answers":
        captured_answers(home, path, args.source)
        return
    with locked(path):
        doc = load(path)
        now = utcnow()
        if args.command == "add":
            intent = text_file(args.intent_file)
            due = stamp(parse_time(args.due)) if args.due else None
            verifier = json.loads(text_file(args.verifier_file)) if args.verifier_file else None
            validate_verifier(verifier, allow_unknown=True)
            existing = next((r for r in doc["asks"] if r["key"] == args.key), None)
            if existing:
                if any((existing["kind"] != args.kind, existing["project"] != args.project,
                        existing["requested_target"] != args.target, existing["intent"] != intent,
                        existing["source"] != args.source)):
                    raise ValueError("idempotency key already belongs to a different ask")
                print(existing["id"])
                return
            if not args.task and not args.no_task_reason:
                raise ValueError("provide --task or --no-task-reason")
            row = {"id": f"a-{now:%Y%m%d}-{uuid.uuid4().hex[:8]}", "key": args.key, "kind": args.kind,
                   "intent": intent, "source": args.source, "project": args.project,
                   "linked_task": args.task, "no_task_reason": args.no_task_reason,
                   "waiting_question": args.waiting_question,
                   "requested_target": args.target, "target": args.target,
                   "created": stamp(now), "due": due, "next_check": stamp(now), "state": "queued",
                   "evidence": [], "verifier": verifier, "verification": None, "alert": {}, "archive_reason": None}
            doc["asks"].append(row)
            save(path, doc)
            print(row["id"])
        else:
            row = find(doc, args.id)
            if row is None:
                raise ValueError("ask does not exist")
            if row["state"] not in OPEN:
                raise ValueError("ask is already closed")
            if args.command == "update":
                row["state"] = args.state
                row["evidence"].append({"at": stamp(now), "result": "progress", "detail": args.evidence, "url": None})
                if args.task is not None:
                    row["linked_task"] = args.task
                if args.waiting_question is not None:
                    row["waiting_question"] = args.waiting_question
                if args.target is not None:
                    if not args.target.strip():
                        raise ValueError("target cannot be empty")
                    row["target"] = args.target
                if args.verifier_file:
                    replacement = json.loads(text_file(args.verifier_file))
                    validate_verifier(replacement, allow_unknown=True)
                    row["verifier"] = replacement
                if args.due:
                    row["due"] = stamp(parse_time(args.due))
                if args.next_check:
                    row["next_check"] = stamp(parse_time(args.next_check))
            elif args.command == "verify":
                if row["kind"] not in DELIVERY:
                    raise ValueError("priority items use the idle detector")
                record_verification(row, check_verifier(row["verifier"], now))
                row["next_check"] = stamp(now + dt.timedelta(seconds=config(home)["scan_seconds"]))
                print(json.dumps(row["verification"], ensure_ascii=False))
            else:
                row["state"] = "archived"
                row["archive_reason"] = args.reason
                row["evidence"].append({"at": stamp(now), "result": "archive", "detail": args.reason, "url": None})
            save(path, doc)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        print(f"fm-captain-asks: {error}", file=sys.stderr)
        sys.exit(1)
