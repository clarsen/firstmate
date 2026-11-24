#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT/bin/fm-captain-asks.py" <<'PY'
from html.parser import HTMLParser
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time

cli = sys.argv[1]
sha = "0932fe0" + "a" * 33
old = "611f7e7" + "b" * 33
live = {"sha": old, "mr": sha, "job": "success", "receipt": [], "ancestor": True}
# /api/slow answers once the test releases it after its concurrent step, so the reply never races
# the CLI's 2s fetch timeout; the long wait only bounds a handler whose test already failed.
slow_release = threading.Event()

class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/health":
            value = {"git_sha": live["sha"]}
        elif self.path == "/api/slow":
            slow_release.wait(10)
            value = {"git_sha": live["sha"]}
        elif self.path == "/api/v4/projects/sample%2Fvantage/merge_requests/57":
            value = {"state": "merged", "merge_commit_sha": live["mr"]}
        elif self.path == "/api/v4/projects/sample%2Fvantage/merge_requests/58":
            # GitLab reports a fast-forward merge with a null merge_commit_sha; the head sha is what landed.
            value = {"state": "merged", "merge_commit_sha": None, "squash_commit_sha": None, "sha": sha}
        elif self.path == "/api/v4/projects/sample%2Fvantage/merge_requests/59":
            value = {"state": "opened", "merge_commit_sha": None, "squash_commit_sha": None, "sha": sha}
        elif self.path == "/api/v4/projects/sample%2Fvantage/jobs/71":
            value = {"id": 71, "status": live["job"]}
        elif self.path == "/api/v4/projects/sample%2Fvantage/jobs/71/artifacts/deploy-event.json":
            value = {"schema_version": 1, "events": live["receipt"]}
        elif self.path.startswith("/api/v4/projects/sample%2Fvantage/repository/merge_base?"):
            # GitLab answers 404 when a ref is not in the project; "c"*40 stands for such a foreign commit.
            if "c" * 40 in self.path:
                self.send_error(404)
                return
            if "e" * 40 in self.path:
                self.send_error(500)
                return
            value = {"id": sha if live["ancestor"] else "f" * 40}
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
COLUMNS = ["Project", "Ask", "Kind", "State", "Verifier", "Priority coverage", "Waiting on", "Age", "Decide"]

class PageShape(HTMLParser):
    """Collect a built ledger page's table column headings and its legend's term groups."""
    def __init__(self):
        super().__init__()
        self.columns, self.groups, self.capture = [], {}, None

    def handle_starttag(self, tag, attrs):
        if tag in ("th", "h3", "dt"):
            self.capture, self.text = tag, ""

    def handle_data(self, data):
        if self.capture:
            self.text += data

    def handle_endtag(self, tag):
        if tag != self.capture:
            return
        if tag == "th":
            self.columns.append(self.text.strip())
        elif tag == "h3":
            self.group = self.groups.setdefault(self.text.strip(), [])
        else:
            self.group.append(self.text.strip())
        self.capture = None

def page_shape(page):
    shape = PageShape()
    shape.feed(page.read_text())
    return shape.columns, shape.groups

node = shutil.which("node")
if node is None:
    print("skip: node not found; the ledger page's rendered rows and decisions are not checked")

def rendered(page, actions=()):
    """Run the built page's own script, driving the given row decisions; None without node."""
    if node is None:
        return None
    harness = Path(cli).parent.parent / "tests/assets/asks-page-harness.mjs"
    result = subprocess.run([node, str(harness), str(page), json.dumps(list(actions))], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)

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
    unknown_row = next(a for a in json.loads(run("dump").stdout)["asks"] if a["id"] == unknown)
    assert unknown_row["state"] == "queued" and unknown_row["verification"]["result"] == "unknown"
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
    assert 'id="decision-page-data"' in page.read_text()
    # The page is one table and a legend with one group of defined values per table column.
    columns, legend = page_shape(page)
    assert columns == COLUMNS, columns
    assert list(legend) == ["Kind", "State", "Verifier", "Priority coverage", "Decide"], legend
    assert legend["Verifier"] == ["Pass", "Mismatch", "Unknown", "Unchecked"] and legend["Decide"] == ["Accept", "Rework"]
    view = rendered(page)
    if view is not None:
        open_ids = [a["id"] for a in json.loads(run("list").stdout)["asks"]]
        assert sorted(r["key"] for r in view["rows"]) == sorted(f"captain-ask.{i}" for i in open_ids), view["rows"]
        assert view["count"] == str(len(open_ids)) and not view["captain"] and not view["empty"]
        for shown in view["rows"]:
            cells = shown["cells"]
            assert list(cells) == COLUMNS and not shown["panelOpen"], shown
            assert cells["Kind"] in legend["Kind"] and cells["State"] in legend["State"], shown
            assert cells["Verifier"] in ["", *legend["Verifier"]], shown
            assert cells["Priority coverage"] in ["", *legend["Priority coverage"]], shown
            assert shown["actions"] == [f"Accept: {cells['Ask']}", f"Rework: {cells['Ask']}"], shown
        by_key = {r["key"]: r for r in view["rows"]}
        assert by_key[f"captain-ask.{unknown}"]["cells"]["Verifier"] == "Unknown"
        roster = [r for r in view["rows"] if r["cells"]["Kind"] == "Priority project"]
        assert len(roster) == 12 and {r["cells"]["Verifier"] for r in roster} == {""}
        assert {(r["cells"]["Priority coverage"], r["tones"]["Priority coverage"]) for r in roster} == {("Idle", "attn")}
    embedded = page.read_text().split('<script id="decision-page-data" type="application/json">', 1)[1]
    page_rows = json.loads(embedded.split("</script>", 1)[0])["rows"]
    assert {r["verifier"] for r in page_rows if r["kind"] == "project-priority"} == {""}
    assert {r["verifier"] for r in page_rows if r["key"] == f"captain-ask.{unknown}"} == {"unknown"}

def fresh_home(temp):
    home = Path(temp)
    for name in ("data", "state", "config"):
        (home / name).mkdir()
    (home / "data/backlog.md").write_text("## Queued\n")
    (home / "intent.txt").write_text("Deploy the requested commit.\n")
    return home

def cli_runner(home):
    env = {**os.environ, "FM_HOME": str(home)}
    def run(*args, good=True):
        result = subprocess.run([sys.executable, cli, *args], env=env, text=True, capture_output=True)
        if good and result.returncode:
            raise AssertionError(f"{args}: {result.stderr}")
        return result
    return run

def add_ask(home, run, key, kind, project, target, spec=None, task="release", reason=""):
    args = ["add", "--key", key, "--kind", kind, "--intent-file", str(home / "intent.txt"),
            "--source", f"fixture:{key}", "--project", project, "--target", target]
    args += ["--task", task] if task else ["--no-task-reason", reason or "roster entry"]
    if spec is not None:
        (home / "verifier.json").write_text(json.dumps(spec))
        args += ["--verifier-file", str(home / "verifier.json")]
    return run(*args).stdout.strip()

def edit(home, ask_id, **fields):
    store = home / "data/captain-asks.json"
    record = json.loads(store.read_text())
    next(a for a in record["asks"] if a["id"] == ask_id).update(fields)
    store.write_text(json.dumps(record))

def row(run, ask_id):
    return next(a for a in json.loads(run("dump").stdout)["asks"] if a["id"] == ask_id)

health = {"type": "http-json-field-equals", "url": base + "/api/health", "path": "git_sha", "expected_prefix": sha}

def receipt(host, commit, outcome="changed"):
    return {"host": host, "commit_sha": commit, "outcome": outcome,
            "ansible_exit_code": 0, "runner_exit_code": 0, "job_status": "success"}

# A successful job is insufficient until every named host has a successful receipt at or after the requested SHA.
with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    run = cli_runner(home)
    spec = {"type": "host-rollout-receipt", "url": base + "/sample/vantage/-/jobs/71",
            "sha": sha, "hosts": ["one.invalid", "two.invalid"]}
    ask = add_ask(home, run, "rollout", "deploy-prod", "vantage", sha, spec)
    live["receipt"] = [receipt("one.invalid", sha)]
    assert json.loads(run("verify", ask).stdout)["result"] == "mismatch"
    live["receipt"].append(receipt("two.invalid", old, "failed"))
    assert json.loads(run("verify", ask).stdout)["result"] == "mismatch"
    live["job"] = "failed"
    assert json.loads(run("verify", ask).stdout)["result"] == "mismatch"
    live["job"] = "success"
    live["receipt"][-1] = receipt("two.invalid", old)
    live["ancestor"] = False
    assert json.loads(run("verify", ask).stdout)["result"] == "mismatch"
    live["ancestor"] = True
    assert json.loads(run("verify", ask).stdout)["result"] == "pass"
    assert row(run, ask)["state"] == "verified"
    mixed = add_ask(home, run, "rollout-mixed", "deploy-prod", "vantage", sha, spec)
    live["receipt"] = [receipt("one.invalid", "c" * 40), receipt("one.invalid", sha), receipt("two.invalid", sha)]
    assert json.loads(run("verify", mixed).stdout)["result"] == "pass"
    foreign = add_ask(home, run, "rollout-foreign", "deploy-prod", "vantage", sha, spec)
    live["receipt"] = [receipt("one.invalid", sha), receipt("two.invalid", "c" * 40)]
    checked = json.loads(run("verify", foreign).stdout)
    assert checked["result"] == "mismatch" and checked["detail"] == "unproven hosts: two.invalid", checked
    live["receipt"] = [receipt("one.invalid", sha), receipt("two.invalid", "e" * 40)]
    assert json.loads(run("verify", foreign).stdout)["result"] == "unknown"
    bad = {**spec, "hosts": []}
    (home / "verifier.json").write_text(json.dumps(bad))
    assert run("add", "--key", "bad", "--kind", "deploy-prod", "--intent-file", str(home / "intent.txt"),
               "--source", "fixture:bad", "--project", "vantage", "--task", "release", "--target", sha,
               "--verifier-file", str(home / "verifier.json"), good=False).returncode != 0
    pending = add_ask(home, run, "pending", "deploy-prod", "vantage", sha)
    assert run("update", pending, "--state", "working", "--evidence", "check later",
               "--verifier-file", str(home / "verifier.json"), good=False).returncode != 0
    assert row(run, pending)["verifier"] is None
    decision = "captain-ask." + pending
    capture = home / "answer.result"
    answer = {"schema": "fm-decision-page-answer.v1", "question": decision,
              "selection": "rework", "note": "Fix deployment ordering"}
    # The row's Rework and Accept actions queue exactly the answer the capture path reads.
    page = home / "decide.html"
    run("page", "--output", str(page))
    view = rendered(page, [{"key": decision, "choose": "rework"}])
    if view is not None:
        blank = next(r for r in view["rows"] if r["key"] == decision)
        assert not view["queued"] and blank["panelOpen"] and blank["noteLabel"] == "Rework note", blank
        assert blank["error"] == "Add a rework note." and len(blank["actions"]) == 2, blank
        view = rendered(page, [{"key": decision, "choose": "accept", "cancel": True},
                               {"key": decision, "choose": "rework", "note": " Fix deployment ordering "}])
        sent = next(r for r in view["rows"] if r["key"] == decision)
        assert [(q["tag"], q["question"], q["data"]) for q in view["queued"]] == [("choice", decision, answer)], view["queued"]
        assert sent["cells"]["Decide"] == "Rework queued" and not sent["actions"] and not sent["panelOpen"], sent
        view = rendered(page, [{"key": decision, "choose": "accept"}])
        assert [q["data"] for q in view["queued"]] == [{**answer, "selection": "accept", "note": ""}], view["queued"]
        assert next(r for r in view["rows"] if r["key"] == decision)["send"] == "Send accept"
    capture.write_text('session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  ' +
        ','.join(json.dumps(value) for value in ["2", "Answer - fixture: rework\n\nContext data:\n" +
        json.dumps(answer), "form", "choice", "fixture -> rework"]) + '\n')
    extracted = subprocess.run(["bash", str(Path(cli).parent / "fm-procevent-lavish.sh"),
                                "ask-answers", str(capture)], text=True, capture_output=True,
                               env={**os.environ, "FM_HOME": str(home)})
    assert extracted.returncode == 0, extracted.stderr
    assert extracted.stdout == f"{decision}\trework\tFix deployment ordering\n"
    refused = subprocess.run([sys.executable, cli, "captured-answers", "--source", "fixture empty"],
                             input=f"{decision}\trework\t\n", text=True, capture_output=True,
                             env={**os.environ, "FM_HOME": str(home)})
    assert refused.returncode == 0 and row(run, pending)["state"] == "queued"
    input_row = f"{decision}\trework\tFix deployment ordering\n"
    result = subprocess.run([sys.executable, cli, "captured-answers", "--source", "fixture capture 1"],
                            input=input_row, text=True, capture_output=True, env={**os.environ, "FM_HOME": str(home)})
    assert result.returncode == 0, result.stderr
    assert row(run, pending)["state"] == "working"
    assert row(run, pending)["evidence"][-1]["detail"] == "Fix deployment ordering"
    evidence_count = len(row(run, pending)["evidence"])
    subprocess.run([sys.executable, cli, "captured-answers", "--source", "fixture capture 1"],
                   input=input_row, text=True, capture_output=True,
                   env={**os.environ, "FM_HOME": str(home)}, check=True)
    assert len(row(run, pending)["evidence"]) == evidence_count
    assert pending in (home / "state/.wake-queue").read_text()
    result = subprocess.run([sys.executable, cli, "captured-answers", "--source", "fixture capture 2"],
                            input=f"{decision}\taccept\t\n", text=True, capture_output=True,
                            env={**os.environ, "FM_HOME": str(home)})
    assert result.returncode == 0, result.stderr
    assert row(run, pending)["state"] == "verified"
    assert row(run, pending)["evidence"][-1]["result"] == "captain-accept"
    assert row(run, pending)["verification"] is None

# Fast-forward and squash merges leave merge_commit_sha null; an open MR at the SHA is not merged.
with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    run = cli_runner(home)
    ff = add_ask(home, run, "ff", "merge", "vantage", sha,
                 {"type": "forge-mr-merged-at-sha", "url": base + "/sample/vantage/-/merge_requests/58", "sha": sha})
    assert json.loads(run("verify", ff).stdout)["result"] == "pass"
    opened = add_ask(home, run, "open-mr", "merge", "vantage", sha,
                     {"type": "forge-mr-merged-at-sha", "url": base + "/sample/vantage/-/merge_requests/59", "sha": sha})
    assert json.loads(run("verify", opened).stdout)["result"] == "mismatch"

# A non-passing check keeps the recorded workflow state, and a recorded wait suppresses reminders.
with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    run = cli_runner(home)
    live["sha"] = old
    wait = add_ask(home, run, "await", "deploy-prod", "vantage", sha, health)
    run("update", wait, "--state", "awaiting-approval", "--evidence", "release job needs approval")
    assert json.loads(run("verify", wait).stdout)["result"] == "mismatch"
    assert row(run, wait)["state"] == "awaiting-approval"
    assert row(run, wait)["verification"]["result"] == "mismatch"
    edit(home, wait, created="2020-01-01T00:00:00Z", next_check="2020-01-01T00:00:00Z")
    assert wait in run("sweep").stdout
    edit(home, wait, next_check="2020-01-01T00:00:00Z", alert={**row(run, wait)["alert"], "at": "2020-01-01T00:00:00Z"})
    assert wait not in run("sweep").stdout
    assert row(run, wait)["state"] == "awaiting-approval"
    run("update", wait, "--state", "working", "--evidence", "approval granted", "--next-check", "2020-01-01T00:00:00Z")
    edit(home, wait, alert={**row(run, wait)["alert"], "at": "2020-01-01T00:00:00Z"})
    assert wait in run("sweep").stdout

# An unrelated worker on the same project does not cover a delivery ask's own linked task.
with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    run = cli_runner(home)
    (home / "state/unrelated.meta").write_text("project=vantage\nrepo=vantage\nwindow=fm:unrelated\nkind=ship\n")
    undriven = add_ask(home, run, "undriven", "deploy-prod", "vantage", sha, health, task="release-0932")
    edit(home, undriven, created="2020-01-01T00:00:00Z")
    out = run("sweep").stdout
    assert undriven in out and "linked worker=absent" in out

# Only a captain hold explains an idle priority project; a check failure on one row alerts and the rest still run.
with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    run = cli_runner(home)
    (home / "data/backlog.md").write_text(
        "## Queued\n"
        "- [ ] ci-wait - Wait for CI (repo: other-hold) (kind: ship) (hold: waiting on CI)\n"
        "- [ ] cap-wait - Ask first (repo: captain-hold) (kind: ship) (hold-kind: captain) (hold: may this proceed)\n")
    other = add_ask(home, run, "p-other", "project-priority", "other-hold", "next task", task="")
    captain = add_ask(home, run, "p-captain", "project-priority", "captain-hold", "next task", task="")
    out = run("sweep").stdout
    assert other in out and captain not in out
    backlog = home / "data/backlog.md"
    backlog.rename(home / "data/backlog-real.md")
    backlog.symlink_to(home / "data/backlog-real.md")
    late = add_ask(home, run, "late", "deploy-prod", "vantage", sha, health)
    edit(home, late, due="2020-01-01T00:00:00Z", next_check="2099-01-01T00:00:00Z")
    edit(home, other, next_check="2020-01-01T00:00:00Z")
    edit(home, captain, next_check="2020-01-01T00:00:00Z")
    edit(home, late, next_check="2020-01-02T00:00:00Z")
    out = run("sweep").stdout
    assert f"captain ask {captain}" in out and "check failed" in out
    assert late in out
    queue = (home / "state/.wake-queue").read_text()
    assert captain in queue and late in queue
    page = home / "page.html"
    run("page", "--output", str(page))
    text = page.read_text()
    assert "captain-hold" in text and "unavailable" in text
    view = rendered(page)
    if view is not None:
        roster = [r for r in view["rows"] if r["cells"]["Kind"] == "Priority project"]
        assert roster and all(r["cells"]["Priority coverage"] == "Unavailable" for r in roster), roster
        assert all(r["tones"]["Priority coverage"] == "attn" for r in roster), roster
        # The reason sits under the ask as an expandable line, since it does not fit the row.
        assert all([d["text"].startswith("Priority coverage unavailable: ") and d["clipped"]
                    for d in r["details"]] == [True] for r in roster), roster

# A home with no open asks says so instead of drawing an empty table, and an ask waiting on the captain stands out.
with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    run = cli_runner(home)
    page = home / "page.html"
    run("page", "--output", str(page))
    view = rendered(page)
    assert view is None or (view["empty"] == "No open asks." and not view["rows"] and view["count"] == "0"), view
    approval = add_ask(home, run, "approval", "merge", "vantage", "Merge the fixture change")
    add_ask(home, run, "driven", "deploy-dev", "vantage", sha)
    run("update", approval, "--state", "awaiting-approval", "--evidence", "ready for the captain")
    run("page", "--output", str(page))
    view = rendered(page)
    if view is not None:
        assert view["count"] == "2" and view["captain"] == " · 1 waiting on captain" and not view["empty"], view
        first, second = view["rows"]
        assert first["key"] == f"captain-ask.{approval}" and first["cells"]["Waiting on"] == "Captain", first
        assert first["cells"]["State"] == "Waiting" and first["tones"]["State"] == "attn", first
        assert second["cells"]["Waiting on"] == "Firstmate" and second["tones"]["State"] == "", second
        assert second["cells"]["Verifier"] == "Unchecked" and not second["details"], second

# A slow row check holds neither the ledger lock nor a second sweep slot, and an invalid config is visible.
with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    run = cli_runner(home)
    slow = add_ask(home, run, "slow", "deploy-prod", "vantage", sha,
                   {"type": "http-json-field-equals", "url": base + "/api/slow", "path": "git_sha", "expected_prefix": sha})
    slow_release.clear()
    sweeper = subprocess.Popen([sys.executable, cli, "sweep"], env={**os.environ, "FM_HOME": str(home)},
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    threading.Event().wait(0.7)
    busy = run("sweep", good=False)
    assert busy.returncode == 75 and not busy.stdout.strip(), busy
    started = time.monotonic()
    intake = add_ask(home, run, "intake-during-sweep", "deploy-dev", "vantage", sha, task="dev-release")
    assert time.monotonic() - started < 1.0, "add waited for a slow sweep check"
    assert sweeper.poll() is None, "setup error: sweep finished before the concurrent add"
    slow_release.set()
    sweeper.communicate(timeout=30)
    assert sweeper.returncode == 0
    assert row(run, slow)["verification"]["result"] == "mismatch"
    assert row(run, intake)["state"] == "queued"

    (home / "config/captain-asks.json").write_text(json.dumps({"scan_seconds": 0}))
    failed = run("sweep", good=False)
    assert failed.returncode == 1 and "intervals" in failed.stderr
    assert "intervals" in json.loads(run("list").stdout)["config_error"]
    bearings = str(Path(cli).parent / "fm-bearings-snapshot.sh")
    model = json.loads(subprocess.run([bearings, "--json"], text=True, capture_output=True, check=True,
                                      env={**os.environ, "FM_HOME": str(home)}).stdout)
    assert {a["id"] for a in model["captain_asks"]} == {slow, intake}
    assert any(o["surface"].startswith("captain asks config invalid") for o in model["omitted"])

# A recorded wait that lands while a row's check is in flight is not overwritten by a stale reminder.
with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    run = cli_runner(home)
    racing = add_ask(home, run, "racing", "deploy-prod", "vantage", sha,
                     {"type": "http-json-field-equals", "url": base + "/api/slow", "path": "git_sha", "expected_prefix": sha})
    edit(home, racing, created="2020-01-01T00:00:00Z", state="working",
         alert={"at": "2020-01-01T00:00:00Z", "fingerprint": f"{sha}:False:mismatch"})
    slow_release.clear()
    sweeper = subprocess.Popen([sys.executable, cli, "sweep"], env={**os.environ, "FM_HOME": str(home)},
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    threading.Event().wait(0.7)
    run("update", racing, "--state", "awaiting-approval", "--evidence", "release job awaits approval")
    assert sweeper.poll() is None, "setup error: sweep finished before the concurrent update"
    slow_release.set()
    out, err = sweeper.communicate(timeout=30)
    assert sweeper.returncode == 0, err
    assert racing not in out, out
    assert not (home / "state/.wake-queue").exists() or racing not in (home / "state/.wake-queue").read_text()
    assert row(run, racing)["state"] == "awaiting-approval"

def daily(home, day):
    result = subprocess.run([sys.executable, str(Path(cli).parent / "fm-wake-daily.py"), day, "--home", str(home)],
                            env={**os.environ, "PATH": f"{home / 'bin'}:{os.environ['PATH']}"}, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    return json.loads((home / f"data/wake/daily/{day}.json").read_text())["captain_asks"]

def ask_record(ask_id, created, evidence=(), state="queued", **extra):
    return {"id": ask_id, "key": ask_id, "kind": "deploy-prod", "intent": "Deploy.", "source": "fixture",
            "project": "vantage", "linked_task": "release", "no_task_reason": "", "waiting_question": None,
            "requested_target": sha, "target": sha, "created": created, "due": None,
            "next_check": created, "state": state, "evidence": list(evidence), "verifier": None,
            "verification": None, "alert": {}, "archive_reason": extra.get("archive_reason")}

# Wake reconstructs asks open at the end of the Pacific day (2026-11-21 ends 2026-11-22T08:00Z under PST).
with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    (home / "bin").mkdir()
    (home / "bin/glab").write_text("#!/bin/sh\nexit 1\n")
    (home / "bin/glab").chmod(0o755)
    store = home / "data/captain-asks.json"
    asks = [ask_record("a-20261120-00000001", "2026-11-20T18:00:00Z"),
            ask_record("a-20261120-00000002", "2026-11-20T18:00:00Z", state="verified",
                       evidence=[{"at": "2026-11-21T20:00:00Z", "result": "pass", "detail": "live", "url": None}]),
            ask_record("a-20261122-00000003", "2026-11-22T12:00:00Z"),
            ask_record("a-20261120-00000004", "2026-11-20T18:00:00Z", state="archived", archive_reason="superseded",
                       evidence=[{"at": "2026-11-22T10:00:00Z", "result": "archive", "detail": "superseded", "url": None}])]
    store.write_text(json.dumps({"schema": "fm-captain-asks.v1", "asks": asks}))
    section = daily(home, "2026-11-21")
    assert section["status"] == "measured" and section["open_count"] == 2
    assert {i["id"]: i["lag_minutes"] for i in section["items"]} == {"a-20261120-00000001": 2280, "a-20261120-00000004": 2280}
    many = [ask_record(f"a-20261120-{n:08x}", "2026-11-20T18:00:00Z") for n in range(21)]
    store.write_text(json.dumps({"schema": "fm-captain-asks.v1", "asks": many}))
    section = daily(home, "2026-11-21")
    assert section["open_count"] == 21 and section["items"] == [] and section["follow_up"]
    store.write_text(json.dumps({"schema": "other", "asks": []}))
    section = daily(home, "2026-11-21")
    assert section["status"] == "not_measurable" and section["open_count"] is None

    # Bearings projects open asks with their latest verifier result, and discloses an unreadable ledger.
    bearings = str(Path(cli).parent / "fm-bearings-snapshot.sh")
    open_row = ask_record("a-20261120-00000001", "2026-11-20T18:00:00Z")
    open_row["verification"] = {"at": "2026-11-21T00:00:00Z", "result": "mismatch", "detail": "observed old", "url": None}
    store.write_text(json.dumps({"schema": "fm-captain-asks.v1", "asks": [open_row, asks[1]]}))
    benv = {**os.environ, "FM_HOME": str(home), "FM_BEARINGS_NOW": "2026-11-22T18:00:00Z"}
    model = json.loads(subprocess.run([bearings, "--json"], env=benv, text=True, capture_output=True, check=True).stdout)
    assert [(a["id"], a["verifier_status"]) for a in model["captain_asks"]] == [("a-20261120-00000001", "mismatch")]
    store.write_text("{not json")
    model = json.loads(subprocess.run([bearings, "--json"], env=benv, text=True, capture_output=True, check=True).stdout)
    assert model["captain_asks"] is None
    assert any(o["surface"] == "captain asks unavailable" for o in model["omitted"])

    # The wake drain lists alerted asks and recorded waits, not quiet queued asks.
    alerted = ask_record("a-20261120-0000000a", "2026-11-20T18:00:00Z")
    alerted["alert"] = {"at": "2026-11-22T00:00:00Z", "fingerprint": "x"}
    waiting = ask_record("a-20261120-0000000b", "2026-11-20T18:00:00Z", state="awaiting-approval")
    quiet = ask_record("a-20261120-0000000c", "2026-11-20T18:00:00Z")
    store.write_text(json.dumps({"schema": "fm-captain-asks.v1", "asks": [alerted, waiting, quiet]}))
    (home / "config/supervision-host-off").write_text("")
    drain = subprocess.run([str(Path(cli).parent / "fm-wake-drain.sh")], text=True, capture_output=True,
                           env={**os.environ, "FM_HOME": str(home), "FM_STATE_OVERRIDE": str(home / "state"),
                                "FM_CONFIG_OVERRIDE": str(home / "config")})
    assert drain.returncode == 0, drain.stderr
    assert "DUE CAPTAIN ASKS" in drain.stdout
    assert alerted["id"] in drain.stdout and waiting["id"] in drain.stdout and quiet["id"] not in drain.stdout

# The watcher rings a sweep wake only after the rest of its check block ran, and dedupes a repeated scan failure.
def watch_once(home, seconds):
    bin_dir = home / "watch-bin"
    bin_dir.mkdir(exist_ok=True)
    (bin_dir / "tmux").write_text("#!/usr/bin/env bash\nexit 0\n")
    (bin_dir / "python3").write_text(
        "#!/usr/bin/env bash\n"
        f"if [[ \"$1\" == */fm-wake-daily.py ]]; then echo collector >> '{home}/collector.log'; exit 0; fi\n"
        f"exec '{sys.executable}' \"$@\"\n")
    for item in bin_dir.iterdir():
        item.chmod(0o755)
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FM_HOME": str(home),
           "FM_STATE_OVERRIDE": str(home / "state"), "FM_WAKE_DAILY_DISABLE": "0", "FM_POLL": "1",
           "FM_CHECK_INTERVAL": "0", "FM_HEARTBEAT": "999999"}
    watcher = subprocess.Popen(["bash", str(Path(cli).parent / "fm-watch.sh")], env=env, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        out, _ = watcher.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        watcher.terminate()
        out, _ = watcher.communicate()
    return out

with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    run = cli_runner(home)
    idle = add_ask(home, run, "watch-idle", "project-priority", "watched", "next task", task="")
    out = watch_once(home, 60)
    assert f"check: captain ask {idle}" in out, out
    for _ in range(50):
        if (home / "collector.log").exists():
            break
        threading.Event().wait(0.1)
    assert (home / "collector.log").exists(), "watcher skipped later checks after a captain ask sweep wake"

with tempfile.TemporaryDirectory() as temp:
    home = fresh_home(temp)
    (home / "config/supervision-host-off").write_text("")
    (home / "data/captain-asks.json").write_text("{not json")
    failed = watch_once(home, 60)
    assert "captain asks scan failed" in failed, failed
    subprocess.run([str(Path(cli).parent / "fm-wake-drain.sh")], text=True, capture_output=True, check=True,
                   env={**os.environ, "FM_HOME": str(home), "FM_STATE_OVERRIDE": str(home / "state"),
                        "FM_CONFIG_OVERRIDE": str(home / "config")})
    repeated = watch_once(home, 4)
    assert not repeated.strip(), repeated
server.shutdown()
print("ok - captain asks ledger, verification, sweep, consumers, watcher, idempotency, and concurrent writes")
PY
