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
                     "verifier": (row.get("verification") or {}).get("result", "unchecked"),
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
:root{font-family:system-ui,sans-serif;color:#172a36;background:#f5f7f6;color-scheme:light}
*{box-sizing:border-box}body{margin:0}main{max-width:1060px;margin:auto;padding:42px 24px 80px}
h1{font-size:clamp(1.8rem,4vw,2.8rem);letter-spacing:-.025em;margin:0 0 8px}h2{font-size:1.35rem;margin:36px 0 12px}
h3{font-size:1rem;margin:20px 0 8px}p{line-height:1.5}.sub{color:#52636d;margin:0}.count{font-variant-numeric:tabular-nums}
.project{border-top:1px solid #b9c8cb;margin-top:32px}.group{display:grid;grid-template-columns:150px minmax(0,1fr);gap:20px;margin-top:16px}
.group-label{color:#52636d;font-weight:650;padding-top:12px}.ask-list{display:grid;gap:12px}.ask{background:#fff;border:1px solid #ccd6d7;border-radius:12px;padding:18px 20px}
.ask-title{font-size:1.08rem;font-weight:650;overflow-wrap:anywhere;margin:0 0 9px}.meta{color:#52636d;font-size:.89rem;display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px}
.detail{font-size:.88rem;color:#40565f;margin:0 0 14px;overflow-wrap:anywhere}
.meta span+span:before{content:'·';margin-right:8px}.choices{display:flex;gap:18px;flex-wrap:wrap}.choices label{display:inline-flex;align-items:center;gap:7px;min-height:38px;cursor:pointer}
.choices input{accent-color:#275a55}.note{display:block;width:100%;max-width:580px;padding:10px;border:1px solid #9bafb3;border-radius:6px;font:inherit;margin:8px 0}
button{background:#275a55;color:#fff;border:0;border-radius:6px;padding:10px 17px;font:inherit;font-weight:650;cursor:pointer;min-height:42px}
button:hover{background:#17423e}button:focus-visible,input:focus-visible{outline:3px solid #b17631;outline-offset:3px}
.error{color:#a12020;font-size:.9rem;min-height:1.4em}.queued{color:#275a55;font-weight:650;display:none}.is-queued .queued{display:inline}.is-queued button{display:none}
.glossary{border-collapse:collapse;width:100%;font-size:.91rem;background:#fff}.glossary th,.glossary td{text-align:left;padding:10px 12px;border-bottom:1px solid #dbe2e3;vertical-align:top}
.glossary th{background:#e9efee}.glossary td:first-child{font-weight:650;white-space:nowrap}.empty{padding:25px;background:#fff;border:1px solid #ccd6d7;border-radius:12px}
@media(max-width:700px){main{padding:24px 16px 48px}.group{display:block}.group-label{margin:18px 0 8px}.glossary td:first-child{white-space:normal}}
</style></head><body><main><h1>Outstanding asks</h1><p class="sub"><span class="count" id="count"></span> open · Updated <span id="updated"></span></p>
<div id="projects"></div><section aria-labelledby="glossary-title"><h2 id="glossary-title">Terms on this page</h2>
<table class="glossary"><thead><tr><th>Term</th><th>Meaning</th></tr></thead><tbody>
<tr><td>Production deploy</td><td>Roll out a change to production.</td></tr><tr><td>Development deploy</td><td>Roll out a change to a development environment.</td></tr>
<tr><td>Merge</td><td>Land a proposed change.</td></tr><tr><td>Priority project</td><td>Keep work moving on a named project.</td></tr>
<tr><td>Queued</td><td>The ask is recorded and work has not started.</td></tr><tr><td>Working</td><td>Firstmate is driving the ask.</td></tr>
<tr><td>Waiting</td><td>The captain’s decision or approval is needed.</td></tr><tr><td>Blocked</td><td>Progress needs a dependency or intervention.</td></tr>
<tr><td>Verifying</td><td>Delivery evidence is being checked.</td></tr><tr><td>Verified</td><td>Evidence passed or the captain accepted the ask.</td></tr>
<tr><td>Needs evidence</td><td>Delivery still needs proof.</td></tr><tr><td>Archived</td><td>The ask was removed with a recorded reason.</td></tr><tr><td>Pass</td><td>The configured check proved delivery.</td></tr>
<tr><td>Mismatch</td><td>The check ran but did not prove delivery.</td></tr><tr><td>Unknown</td><td>No usable check or evidence is available yet.</td></tr>
<tr><td>Unchecked</td><td>The verifier has not run yet.</td></tr>
<tr><td>Covered</td><td>A priority project has work or a captain hold.</td></tr><tr><td>Idle</td><td>A priority project has no qualifying work or hold.</td></tr>
</tbody></table></section></main><script id="decision-page-data" type="application/json">\n''' + data + '''\n</script><script>
(function(){"use strict";const data=JSON.parse(document.getElementById("decision-page-data").textContent);
document.getElementById("count").textContent=data.rows.length;document.getElementById("updated").textContent=data.generated;
const root=document.getElementById("projects");if(!data.rows.length){root.innerHTML='<p class="empty">No open asks.</p>';return}
let project='',owner='',section,items;for(const row of data.rows){if(row.project!==project){project=row.project;owner='';section=document.createElement('section');section.className='project';
const heading=document.createElement('h2');heading.textContent=project;section.appendChild(heading);root.appendChild(section)}
if(row.owner!==owner){owner=row.owner;const group=document.createElement('div');group.className='group';const label=document.createElement('div');label.className='group-label';label.textContent='Waiting on '+owner.toLowerCase();
items=document.createElement('div');items.className='ask-list';group.append(label,items);section.appendChild(group)}
const card=document.createElement('article');card.className='ask';const title=document.createElement('h3');title.className='ask-title';title.textContent=row.title;card.appendChild(title);
const kind={"deploy-prod":"production deploy","deploy-dev":"development deploy","merge":"merge","project-priority":"priority project"}[row.kind]||row.kind;
const state={"awaiting-approval":"waiting","needs-evidence":"needs evidence"}[row.state]||row.state;
const meta=document.createElement('div');meta.className='meta';for(const value of [kind,state,'verifier: '+row.verifier,row.priority?'priority: '+row.priority:null,row.age+'m old']){
if(value){const span=document.createElement('span');span.textContent=value;meta.appendChild(span)}}card.appendChild(meta);
if(row.verifier_detail){const detail=document.createElement('p');detail.className='detail';detail.textContent='Verifier detail: '+row.verifier_detail;card.appendChild(detail)}
const form=document.createElement('form');form.setAttribute('data-lavish-question',row.key);form.innerHTML='<div class="choices"><label><input type="radio" name="answer" value="accept">Accept</label><label><input type="radio" name="answer" value="rework">Rework</label></div><input class="note" name="note" aria-label="Note for this ask" placeholder="Note (required for rework)"><button type="submit">Send decision</button> <span class="queued">Queued</span><div class="error" role="alert"></div>';
form.addEventListener('submit',function(event){event.preventDefault();const selection=new FormData(form).get('answer');const note=form.elements.note.value.trim();const error=form.querySelector('.error');
if(!selection){error.textContent='Choose Accept or Rework.';return}if(selection==='rework'&&!note){error.textContent='Add a rework note.';return}
if(new TextEncoder().encode(selection+(note?' - '+note:'')).length>512){error.textContent='Decision is too long (512 bytes maximum).';return}
if(!window.lavish||!window.lavish.queuePrompt){error.textContent='Decision capture is unavailable. Open the published Lavish page.';return}
window.lavish.queuePrompt('Answer - '+row.title+': '+selection+(note?' - '+note:''),{tag:'choice',text:row.title+' -> '+selection+(note?' - '+note:''),element:form,
data:{schema:'fm-decision-page-answer.v1',question:row.key,selection:selection,note:note}});error.textContent='';card.classList.add('is-queued')});
card.appendChild(form);items.appendChild(card)}
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
