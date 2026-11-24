#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT/bin/fm-captain-asks.py" <<'PY'
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

cli = sys.argv[1]
sha = "0932fe0" + "a" * 33
old = "611f7e7" + "b" * 33
live = {"sha": old, "mr": sha}

class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/health":
            value = {"git_sha": live["sha"]}
        elif self.path == "/api/v4/projects/sample%2Fvantage/merge_requests/57":
            value = {"state": "merged", "merge_commit_sha": live["mr"]}
        else:
            self.send_error(404)
            return
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_port}"

with tempfile.TemporaryDirectory() as temp:
    home = Path(temp)
    (home / "data").mkdir()
    (home / "state").mkdir()
    (home / "config").mkdir()
    intent = home / "intent.txt"
    intent.write_text("Deploy the requested commit to production.\n")
    verifier = home / "verifier.json"
    env = {**os.environ, "FM_HOME": str(home)}

    def run(*args, good=True):
        result = subprocess.run([sys.executable, cli, *args], env=env, text=True, capture_output=True)
        if good and result.returncode:
            raise AssertionError(f"{args}: {result.stderr}")
        return result

    def add(key, kind, project, target, spec, task="release"):
        verifier.write_text(json.dumps(spec))
        return run("add", "--key", key, "--kind", kind, "--intent-file", str(intent),
                   "--source", "fixture:chat/1", "--project", project, "--task", task,
                   "--target", target, "--verifier-file", str(verifier),
                   "--due", "2020-01-01T00:00:00Z").stdout.strip()

    prod = add("chat-1-prod", "deploy-prod", "vantage", sha,
               {"type": "http-json-field-equals", "url": base + "/api/health",
                "path": "git_sha", "expected_prefix": sha})
    assert prod == add("chat-1-prod", "deploy-prod", "vantage", sha,
                       {"type": "http-json-field-equals", "url": base + "/api/health",
                        "path": "git_sha", "expected_prefix": sha})
    assert len(json.loads(run("dump").stdout)["asks"]) == 1
    assert run("add", "--key", "chat-1-prod", "--kind", "merge", "--intent-file", str(intent),
               "--source", "fixture:chat/1", "--project", "vantage", "--task", "release",
               "--target", sha, good=False).returncode != 0
    merge = add("chat-1-merge", "merge", "vantage", sha,
                {"type": "forge-mr-merged-at-sha", "url": base + "/sample/vantage/-/merge_requests/57", "sha": sha})
    assert json.loads(run("verify", merge).stdout)["result"] == "pass"
    run("update", prod, "--state", "working", "--evidence", "eight green no-change deploy jobs")
    assert json.loads(run("verify", prod).stdout)["result"] == "mismatch"
    assert json.loads(run("dump").stdout)["asks"][0]["state"] != "verified"
    run("update", prod, "--state", "working", "--evidence", "request remains undelivered",
        "--next-check", "2020-01-01T00:00:00Z")
    assert "captain ask" in run("sweep").stdout
    queue = (home / "state/.wake-queue").read_text()
    assert prod in queue
    assert not run("sweep").stdout.strip()
    assert (home / "state/.wake-queue").read_text() == queue
    store = home / "data/captain-asks.json"
    record = json.loads(store.read_text())
    record["asks"][0]["next_check"] = "2020-01-01T00:00:00Z"
    store.write_text(json.dumps(record))
    assert not run("sweep").stdout.strip()
    assert (home / "state/.wake-queue").read_text() == queue
    record = json.loads(store.read_text())
    record["asks"][0]["next_check"] = "2020-01-01T00:00:00Z"
    record["asks"][0]["alert"]["at"] = "2020-01-01T00:00:00Z"
    store.write_text(json.dumps(record))
    assert prod in run("sweep").stdout
    live["sha"] = sha
    assert json.loads(run("verify", prod).stdout)["result"] == "pass"
    assert json.loads(run("dump").stdout)["asks"][0]["state"] == "verified"

    broad = run("add", "--key", "chat-broad", "--kind", "deploy-dev", "--intent-file", str(intent),
                "--source", "fixture:chat/broad", "--project", "sample", "--no-task-reason", "target pending",
                "--target", "requested dev release").stdout.strip()
    verifier.write_text(json.dumps({"type": "http-json-field-equals", "url": base + "/api/health",
                                    "path": "git_sha", "expected_prefix": sha}))
    run("update", broad, "--state", "verifying", "--evidence", "resolved requested release SHA",
        "--target", sha, "--verifier-file", str(verifier), "--task", "dev-release")
    assert broad == run("add", "--key", "chat-broad", "--kind", "deploy-dev", "--intent-file", str(intent),
                        "--source", "fixture:chat/broad", "--project", "sample", "--no-task-reason", "target pending",
                        "--target", "requested dev release").stdout.strip()
    assert json.loads(run("verify", broad).stdout)["result"] == "pass"

    unknown = add("chat-2", "deploy-dev", "sample", "target",
                  {"type": "future-verifier"})
    assert json.loads(run("verify", unknown).stdout)["result"] == "unknown"
    assert next(a for a in json.loads(run("dump").stdout)["asks"] if a["id"] == unknown)["state"] == "needs-evidence"
    missing = add("chat-2-missing", "deploy-dev", "sample", "target",
                  {"type": "http-json-field-equals", "url": base + "/api/missing",
                   "path": "git_sha", "expected_prefix": sha})
    assert json.loads(run("verify", missing).stdout)["result"] == "unknown"
    priority = run("add", "--key", "priority-1", "--kind", "project-priority", "--intent-file", str(intent),
                   "--source", "fixture:chat/3", "--project", "sample", "--no-task-reason", "roster entry",
                   "--target", "next valuable task").stdout.strip()
    assert priority in run("sweep").stdout
    assert priority in (home / "state/.wake-queue").read_text()
    assert not run("sweep").stdout.strip()
    (home / "data/backlog.md").write_text("## Queued\n- [ ] next - Work ready (repo: sample) (kind: ship)\n")
    record = json.loads(store.read_text())
    next(a for a in record["asks"] if a["id"] == priority)["next_check"] = "2020-01-01T00:00:00Z"
    store.write_text(json.dumps(record))
    assert priority not in run("sweep").stdout
    (home / "data/backlog.md").write_text("## Queued\n")
    question_id = "q-20200101-abcdef01"
    (home / "data/captain-questions.json").write_text(json.dumps({"schema": "fm-captain-questions.v1",
        "questions": [{"id": question_id, "state": "open", "question": "May this proceed?",
                       "status": "Awaiting answer", "opened": "2020-01-01T00:00:00Z",
                       "last_updated": "2020-01-01T00:00:00Z", "links": [], "closed_by_captain": None}]}))
    run("update", priority, "--state", "queued", "--evidence", "waiting for explicit answer",
        "--waiting-question", question_id, "--next-check", "2020-01-01T00:00:00Z")
    assert priority not in run("sweep").stdout
    (home / "data/captain-questions.json").write_text(json.dumps({"schema": "fm-captain-questions.v1", "questions": []}))
    record = json.loads(store.read_text())
    next(a for a in record["asks"] if a["id"] == priority)["next_check"] = "2020-01-01T00:00:00Z"
    store.write_text(json.dumps(record))
    assert priority in run("sweep").stdout
    run("remove", priority, "--reason", "captain removed priority")
    row = next(a for a in json.loads(run("dump").stdout)["asks"] if a["id"] == priority)
    assert row["state"] == "archived" and row["archive_reason"]

    results = []
    def concurrent(index):
        results.append(run("add", "--key", f"bulk-{index}", "--kind", "project-priority",
                           "--intent-file", str(intent), "--source", f"fixture:chat/{index}",
                           "--project", "parallel", "--no-task-reason", "roster entry",
                           "--target", f"outcome-{index}").stdout.strip())
    workers = [threading.Thread(target=concurrent, args=(i,)) for i in range(12)]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join()
    assert len(results) == 12 and len(set(results)) == 12
    assert len(json.loads(run("dump").stdout)["asks"]) == 18
    page = home / "view.html"
    run("page", "--output", str(page))
    assert "Outstanding asks" in page.read_text() and "parallel" in page.read_text()
server.shutdown()
print("ok - captain asks ledger, verification, sweep, idempotency, and concurrent writes")
PY
