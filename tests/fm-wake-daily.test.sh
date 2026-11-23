#!/usr/bin/env bash
# Exercise the public collector with fixture records, repeat runs, and absent inputs.
# Expected values follow docs/wake-daily.md and the story's acceptance criteria.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-daily)
CASE_HOME="$TMP_ROOT/home"
mkdir -p "$CASE_HOME/data" "$CASE_HOME/state"
mkdir -p "$TMP_ROOT/bin"
export MOCK_GLAB_FIXTURE="$ROOT/tests/fixtures/fm-wake-daily/pipelines.json"
export MOCK_GLAB_MODE_FILE="$TMP_ROOT/glab-mode"
export PATH="$TMP_ROOT/bin:$PATH"
cat > "$TMP_ROOT/bin/glab" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
from datetime import datetime
from urllib.parse import parse_qs, urlsplit

# GitLab list filters: updated_after/updated_before compare against each pipeline's updated_at.
def stamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))

args = sys.argv[1:]
if len(args) < 4 or args[0] != "api" or args[2:4] != ["--hostname", "lsg-git.lbl.gov"]:
    sys.exit(2)
mode_file = Path(os.environ["MOCK_GLAB_MODE_FILE"])
mode = mode_file.read_text().strip() if mode_file.exists() else None
if mode == "fail":
    sys.exit(1)
url = urlsplit(args[1])
path = url.path
project = "projects/lblnet%2Flblnet_hostupdate"
prefix = project + "/pipelines"
fixture = json.loads(Path(os.environ["MOCK_GLAB_FIXTURE"]).read_text())
records = fixture["pipelines"]
if mode == "bad-url":
    for record in records:
        if record["id"] == 900003:
            record["web_url"] = "https://example.invalid/pipelines/900003"
if path == prefix:
    query = parse_qs(url.query)
    if (args[4:] != ["--paginate", "--output", "ndjson"]
            or query.get("source") != ["merge_request_event"]
            or query.get("status") != ["success"]
            or query.get("per_page") != ["100"]
            or not query.get("updated_after")):
        sys.exit(2)
    after = stamp(query["updated_after"][0])
    before = stamp(query["updated_before"][0]) if "updated_before" in query else None
    for record in records:
        updated = stamp(record["updated_at"])
        if updated > after and (before is None or updated < before):
            print(json.dumps({"id": record["id"], "created_at": record["created_at"]}))
elif path.startswith(project + "/merge_requests/") and len(args) == 4:
    iid = path.removeprefix(project + "/merge_requests/")
    if iid not in fixture["merge_requests"]:
        sys.exit(2)
    print(json.dumps(fixture["merge_requests"][iid]))
elif path.startswith(prefix + "/") and path.endswith("/jobs"):
    pipeline_id = path.removeprefix(prefix + "/").removesuffix("/jobs")
    if (args[4:] != ["--paginate", "--output", "ndjson"]
            or parse_qs(url.query) != {"per_page": ["100"], "include_retried": ["false"]}
            or pipeline_id not in fixture["jobs"]):
        sys.exit(2)
    for name in fixture["jobs"][pipeline_id]:
        print(json.dumps({"name": name}))
elif path.startswith(prefix + "/") and len(args) == 4:
    selected = [record for record in records if str(record["id"]) == path.removeprefix(prefix + "/")]
    if len(selected) != 1 or selected[0].get("list_only"):
        sys.exit(2)
    print(json.dumps(selected[0]))
else:
    sys.exit(2)
PY
chmod +x "$TMP_ROOT/bin/glab"
PRE=2026-11-20
POST=2026-11-22
NOW=2026-11-30T12:00:00-08:00
TODAY=$(python3 -c 'from datetime import datetime; from zoneinfo import ZoneInfo; print(datetime.now(ZoneInfo("America/Los_Angeles")).date().isoformat())')
epoch() {
  python3 -c 'import sys; from datetime import datetime; from zoneinfo import ZoneInfo; print(int(datetime.fromisoformat(sys.argv[1]).replace(tzinfo=ZoneInfo("America/Los_Angeles")).timestamp()))' "$1"
}
POST_NOON=$(epoch "${POST}T12:00:00")
NEXT_NOON=$(epoch "2026-11-23T12:00:00")
PRE_NOON=$(epoch "${PRE}T12:00:00")
PRE_LATE=$(epoch "${PRE}T23:50:00")
POST_LATER=$((POST_NOON + 60))

# Run the real CLI entry point with its clock pinned to NOW so fixed days on both
# sides of the 2026-11-21 ledger cutoff count as completed.
PINNED="$TMP_ROOT/pinned-collector.py"
cat > "$PINNED" <<'PY'
import importlib.util
import sys
from datetime import datetime

path, now = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("fm_wake_daily", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PinnedClock(datetime):
    @classmethod
    def now(cls, tz=None):
        return datetime.fromisoformat(now).astimezone(tz)


module.datetime = PinnedClock
sys.argv = [path] + sys.argv[3:]
module.main()
PY
collect() {
  python3 "$PINNED" "$ROOT/bin/fm-wake-daily.py" "$NOW" "$1" --home "${2:-$CASE_HOME}"
}

cat > "$CASE_HOME/data/backlog.md" <<EOF
## In flight
- [ ] live-ship - Current title (repo: alpha) (kind: ship) (since $POST)
  Resolution mode: answered

  Captain decision:
  Still open? -> Answered while open.

## Done
- [x] ship-a - Ship title with exact words https://example.org/a/pull/1 (repo: alpha) (kind: ship) (merged $POST)
  Resolution mode: answered

  Captain decision:
  Which route? -> Use the route, exactly.
- [x] ship-b - Backlog only ship (repo: beta) (kind: ship) (merged $POST)
EOF
cat > "$CASE_HOME/data/done-archive.md" <<EOF
## Archived $POST
- [x] ship-a - Ship title with exact words https://example.org/a/pull/1 (repo: alpha) (kind: ship) (merged $POST)
- [x] scout-a - Scout title data/scout-a/report.md (repo: alpha) (kind: scout) (reported $POST)
- [x] scout-b - Scout without path (repo: alpha) (kind: scout) (reported $POST)
- [x] receiver-list-scout - Add test receiver data/receiver-list-scout/report.md (repo: alpha) (kind: ship) (reported $POST)
- [x] unknown-a - Unknown kind title (done $POST)
- [x] unknown-b - Unknown merged title (done $POST)
- [x] ship-c - Reordered merge ship https://example.org/a/pull/3 (repo: alpha) (kind: ship) (merged $POST)
- [x] late-ship - Merged before midnight, booked after (repo: beta) (kind: ship) (merged $POST)
- [x] done-pr-nondelivery - Closed without merge https://example.org/a/pull/5 (repo: alpha) (kind: ship) (done $POST)
- [x] reported-ship - Reported not merged (repo: alpha) (kind: ship) (reported $POST)
- [x] held-ship - Captain kept this https://example.org/a/pull/6 (repo: alpha) (kind: ship) (merged $POST) (hold-kind: captain)
- [x] local-ship - Landed locally - local main (repo: beta) (kind: ship) (done $POST)
- [x] issue-ship - Fix linked issue https://example.org/a/issues/9 (repo: beta) (kind: ship) (done $POST)
- [x] local-body-ship - Landed locally by teardown (repo: beta) (kind: ship) (done $POST)
  local main
- [x] local-held-ship - Captain resolution note https://example.org/a/pull/7 (repo: beta) (kind: ship) (done $POST)
  Resolution recorded by fm-captain-hold.
  local main
- [x] scout-none - Scout with no report anywhere (repo: alpha) (kind: scout) (reported $POST)

## Archived $PRE
- [x] old-ship - Old ship (repo: alpha) (kind: ship) (merged $PRE)
EOF
cat > "$CASE_HOME/state/fleet-ledger.jsonl" <<EOF
{"v":1,"ts":$PRE_NOON,"event":"task.merged","task":"old-ship","via":"pr","pr":"https://example.org/a/pull/0"}
{"v":1,"ts":$PRE_NOON,"event":"task.merged","task":"old-ship","via":"pr","pr":"https://example.org/a/pull/0"}
{"v":1,"ts":$POST_NOON,"event":"task.dispatched","task":"ship-a","kind":"ship","project":"alpha"}
{"v":1,"ts":$POST_NOON,"event":"task.dispatched","task":"ship-a","kind":"ship","project":"alpha"}
{"v":1,"ts":$POST_NOON,"event":"task.merged","task":"ship-a","via":"pr","pr":"https://example.org/a/pull/1"}
{"v":1,"ts":$POST_NOON,"event":"task.merged","task":"ship-a","via":"pr","pr":"https://example.org/a/pull/1"}
{"v":1,"ts":$NEXT_NOON,"event":"task.dispatched","task":"later","kind":"ship","project":"alpha"}
{"v":1,"ts":$NEXT_NOON,"event":"task.dispatched","task":"later","kind":"ship","project":"alpha"}
{"v":1,"ts":$POST_LATER,"event":"task.merged","task":"ship-c","via":"pr","pr":"https://example.org/a/pull/3"}
{"v":1,"ts":$POST_NOON,"event":"task.merged","task":"ship-c","via":"pr","pr":"https://example.org/a/pull/3"}
{"v":1,"ts":$POST_NOON,"event":"task.merged","task":"unknown-b","via":"direct"}
{"v":1,"ts":$PRE_LATE,"event":"task.merged","task":"late-ship","via":"direct"}
EOF
cat > "$CASE_HOME/data/captain-questions.json" <<EOF
{"schema":"fm-captain-questions.v1","questions":[
{"id":"q-20261122-0000abcd","question":"Ship the route today?","opened":"2026-11-22T16:00:00Z","status":"Investigation pending.","last_updated":"2026-11-22T16:00:00Z","links":[],"state":"closed","closed_by_captain":{"at":"2026-11-22T18:30:00Z","source":"captain-chat","words":"Yes, ship it today.","evidence":"tmp/words.txt"}},
{"id":"q-20261122-0000ef01","question":"Still pending?","opened":"2026-11-22T16:00:00Z","status":"Investigation pending.","last_updated":"2026-11-22T16:00:00Z","links":[],"state":"open","closed_by_captain":null}
]}
EOF

mkdir -p "$CASE_HOME/data/scout-b"
printf '# Scout B report\n' > "$CASE_HOME/data/scout-b/report.md"
mkdir -p "$CASE_HOME/data/receiver-list-scout"
printf '# Receiver investigation\n' > "$CASE_HOME/data/receiver-list-scout/report.md"

cp "$CASE_HOME/data/backlog.md" "$TMP_ROOT/backlog-saved.md"
cp "$CASE_HOME/data/done-archive.md" "$TMP_ROOT/archive-saved.md"
cp "$CASE_HOME/state/fleet-ledger.jsonl" "$TMP_ROOT/ledger-saved.jsonl"
cp "$CASE_HOME/data/captain-questions.json" "$TMP_ROOT/questions-saved.json"
out=$(collect "$POST") || fail "collector failed"
[ "$out" = "$CASE_HOME/data/wake/daily/$POST.json" ] || fail "unexpected output path: $out"
record="$CASE_HOME/data/wake/daily/$POST.json"
jq -e --arg day "$POST" '
  .schema == "fm-wake-daily.v1"
  and .day == $day
  and .coverage.ledger_duplicates_dropped == 3
  and .coverage.merge_time_source == "fleet-ledger"
  and .coverage.signals.ships == {"status": "measured", "count": 8}
  and .coverage.signals.scouts == {"status": "measured", "count": 3}
  and .coverage.signals.unclassified == {"status": "measured", "count": 1}
  and .coverage.signals.decisions == {"status": "measured", "count": 2}
  and .coverage.signals.hostupdate_mr_pipeline_wall_time == {"status": "measured", "count": 11}
  and .hostupdate_mr_pipeline_wall_time.summary == {"count": 11, "median_seconds": 50, "p90_seconds": 90, "share_under_60s": 0.5455}
  and .hostupdate_mr_pipeline_wall_time.initial_summary == {"count": 10, "median_seconds": 47.5, "p90_seconds": 80, "share_under_60s": 0.6}
  and .hostupdate_mr_pipeline_wall_time.initial_by_change_class == {
    "image_build": {"count": 2, "median_seconds": 37.5, "p90_seconds": 45, "share_under_60s": 1},
    "full_unit": {"count": 1, "median_seconds": 10, "p90_seconds": 10, "share_under_60s": 1},
    "other": {"count": 7, "median_seconds": 60, "p90_seconds": 90, "share_under_60s": 0.4286}
  }
  and ([.hostupdate_mr_pipeline_wall_time.pipelines[].id] == [900001,900002,900003,900004,900005,900006,900007,900008,900009,900010,900013])
  and .hostupdate_mr_pipeline_wall_time.pipelines[0].merge_request_iid == 101
  and .hostupdate_mr_pipeline_wall_time.pipelines[0].source_branch == "fm/change-101"
  and .hostupdate_mr_pipeline_wall_time.pipelines[0].change_class == "full_unit"
  and .hostupdate_mr_pipeline_wall_time.pipelines[2].change_class == "image_build"
  and .hostupdate_mr_pipeline_wall_time.pipelines[10].change_class == "image_build"
  and .hostupdate_mr_pipeline_wall_time.pipelines[10].wall_seconds == 45
  and .hostupdate_mr_pipeline_wall_time.pipelines[0].wall_seconds == 10
  and .hostupdate_mr_pipeline_wall_time.pipelines[0].created_at == "2026-11-22T07:59:50Z"
  and .hostupdate_mr_pipeline_wall_time.pipelines[0].finished_at == "2026-11-22T08:00:00Z"
  and .hostupdate_mr_pipeline_wall_time.pipelines[0].kind == "initial"
  and .hostupdate_mr_pipeline_wall_time.pipelines[0].job_signals == ["test-unit-checkout"]
  and .hostupdate_mr_pipeline_wall_time.pipelines[2].job_signals == ["build-lblnet_hostupdate"]
  and .hostupdate_mr_pipeline_wall_time.pipelines[9].kind == "generated_followup"
  and .coverage.uncounted_decisions == {"count": 1, "reason": "answer time unknown (task still open)"}
  and ([.contributions.projects[].project] == ["alpha", "beta", "none recorded"])
  and .contributions.projects[0].ships == [
    {"task": "ship-a", "title": "Ship title with exact words", "evidence": "https://example.org/a/pull/1", "merged_at": "2026-11-22T20:00:00Z", "time_precision": "second"},
    {"task": "ship-c", "title": "Reordered merge ship", "evidence": "https://example.org/a/pull/3", "merged_at": "2026-11-22T20:00:00Z", "time_precision": "second"}]
  and ([.contributions.projects[0].scouts[].task] == ["receiver-list-scout", "scout-a", "scout-b"])
  and .contributions.projects[0].scouts[0].evidence == "data/receiver-list-scout/report.md"
  and .contributions.projects[0].scouts[1].evidence == "data/scout-a/report.md"
  and .contributions.projects[0].scouts[2] == {"task": "scout-b", "title": "Scout without path", "evidence": "data/scout-b/report.md", "reported_on": $day}
  and .contributions.projects[0].decisions == [{"task": "ship-a", "title": "Ship title with exact words", "question": "Which route?", "answer": "Use the route, exactly.", "evidence": "data/backlog.md#ship-a:decision:1", "closed_on": $day, "time_precision": "day", "date_source": "task close date, not answer time"}]
  and .contributions.projects[1].ships == [
    {"task": "issue-ship", "title": "Fix linked issue", "evidence": "data/done-archive.md#issue-ship", "merged_at": $day, "time_precision": "day"},
    {"task": "late-ship", "title": "Merged before midnight, booked after", "evidence": "data/done-archive.md#late-ship", "merged_at": $day, "time_precision": "day"},
    {"task": "local-body-ship", "title": "Landed locally by teardown", "evidence": "data/done-archive.md#local-body-ship", "merged_at": $day, "time_precision": "day"},
    {"task": "local-ship", "title": "Landed locally - local main", "evidence": "data/done-archive.md#local-ship", "merged_at": $day, "time_precision": "day"},
    {"task": "ship-b", "title": "Backlog only ship", "evidence": "data/backlog.md#ship-b", "merged_at": $day, "time_precision": "day"}]
  and .contributions.projects[2].ships == [{"task": "unknown-b", "title": "Unknown merged title", "evidence": "state/fleet-ledger.jsonl#task.merged:unknown-b", "merged_at": "2026-11-22T20:00:00Z", "time_precision": "second"}]
  and .contributions.projects[2].decisions == [{"task": "q-20261122-0000abcd", "title": "Ship the route today?", "question": "Ship the route today?", "answer": "Yes, ship it today.", "evidence": "data/captain-questions.json#q-20261122-0000abcd", "closed_at": "2026-11-22T18:30:00Z", "time_precision": "second", "date_source": "captain close time"}]
  and ([.contributions.projects[2].unclassified[].task] == ["unknown-a"])
' "$record" >/dev/null || fail "outcomes lost evidence, titles, decision words, or per-day coverage"

cp "$record" "$TMP_ROOT/first.json"
collect "$POST" >/dev/null || fail "repeat run failed"
cmp -s "$TMP_ROOT/first.json" "$record" || fail "repeat run changed bytes"
# A reported task archived late with no kind and an existing report is a scout,
# and a selected-day rerun picks it up without also counting it as unclassified.
printf '%s\n' '- [x] late-scout - Late investigation (reported 2026-11-22)' >> "$CASE_HOME/data/backlog.md"
mkdir -p "$CASE_HOME/data/late-scout"
printf '# Late report\n' > "$CASE_HOME/data/late-scout/report.md"
collect "$POST" >/dev/null || fail "rerun after late source edit failed"
jq -e '
  .coverage.signals.scouts == {"status": "measured", "count": 4}
  and .coverage.signals.unclassified == {"status": "measured", "count": 1}
  and ([.contributions.projects[2].scouts[].task] == ["late-scout"])
  and ([.contributions.projects[2].unclassified[].task] == ["unknown-a"])
' "$record" >/dev/null || fail "selected-day rerun missed late data or double-listed an unkinded scout"
cp "$TMP_ROOT/backlog-saved.md" "$CASE_HOME/data/backlog.md"
rm -r "$CASE_HOME/data/late-scout"
collect "$POST" >/dev/null || fail "rerun after restoring sources failed"
cmp -s "$TMP_ROOT/first.json" "$record" || fail "rebuild with unchanged inputs changed bytes"

# Catch-up lags one day, retries records with unmeasured inputs while the day is
# at most three days old, keeps other records final, and continues past a
# failing day with one log line for it.
CATCH_HOME="$TMP_ROOT/catch-home"
CATCH_EARLY=2026-11-24T12:00:00-08:00
catch_day() { printf '%s/data/wake/daily/%s.json' "$CATCH_HOME" "$1"; }
late_report() {
  printf -- '- [x] %s - %s (reported %s)\n' "$1" "$2" "$3" >> "$CATCH_HOME/data/backlog.md"
  mkdir -p "$CATCH_HOME/data/$1"
  printf '# %s\n' "$2" > "$CATCH_HOME/data/$1/report.md"
}
mkdir -p "$CATCH_HOME/data" "$CATCH_HOME/state" "$CATCH_HOME/projects"
printf '## Done\n' > "$CATCH_HOME/data/backlog.md"
: > "$CATCH_HOME/data/done-archive.md"
: > "$CATCH_HOME/state/fleet-ledger.jsonl"
printf 'fail\n' > "$MOCK_GLAB_MODE_FILE"
NOW=$CATCH_EARLY collect --catch-up "$CATCH_HOME" >/dev/null || fail "catch-up failed"
[ -f "$(catch_day 2026-11-21)" ] || fail "catch-up missed the first Wake day"
[ -f "$(catch_day 2026-11-22)" ] || fail "catch-up missed a day whose next day completed"
[ ! -e "$(catch_day 2026-11-23)" ] || fail "catch-up finalized a day before its next day completed"
jq -e '.coverage.signals.hostupdate_mr_pipeline_wall_time.status == "not_measurable"' "$(catch_day 2026-11-22)" >/dev/null \
  || fail "unreachable GitLab was counted as zero during catch-up"
rm "$MOCK_GLAB_MODE_FILE"
late_report late-catch "Late catch-up scout" 2026-11-22
NOW=$CATCH_EARLY collect --catch-up "$CATCH_HOME" >/dev/null || fail "recovery catch-up failed"
jq -e '
  .coverage.signals.hostupdate_mr_pipeline_wall_time.status == "measured"
  and ([.coverage.inputs[].status] | unique) == ["readable"]
  and ([.contributions.projects[].scouts[].task] == ["late-catch"])
' "$(catch_day 2026-11-22)" >/dev/null || fail "catch-up did not rebuild a recent unmeasured record with late data"
collect --catch-up "$CATCH_HOME" >/dev/null || fail "full catch-up failed"
[ -f "$(catch_day 2026-11-28)" ] || fail "catch-up missed a day whose next day completed"
[ ! -e "$(catch_day 2026-11-29)" ] || fail "catch-up finalized a day before its next day completed"
jq -e '.coverage.inputs["gitlab:lsg-git.lbl.gov/lblnet/lblnet_hostupdate/pipelines"].status == "not_measurable"' \
  "$(catch_day 2026-11-23)" >/dev/null || fail "fixture day 2026-11-23 was unexpectedly measured"
jq -e '([.coverage.inputs[].status] | unique) == ["readable"]' "$(catch_day 2026-11-26)" >/dev/null || fail "fixture day 2026-11-26 was not fully measured"
cp "$(catch_day 2026-11-23)" "$TMP_ROOT/catch-23.json"
cp "$(catch_day 2026-11-26)" "$TMP_ROOT/catch-26.json"
late_report after-window "Edited after the retry window" 2026-11-23
late_report after-final "Edited after measurement" 2026-11-26
rm "$(catch_day 2026-11-21)"
rm "$(catch_day 2026-11-28)"
rm "$(catch_day 2026-11-27)"
mkdir "$(catch_day 2026-11-27)"
if collect --catch-up "$CATCH_HOME" >/dev/null 2>"$TMP_ROOT/catch.err"; then
  fail "catch-up hid a failing day"
fi
[ "$(grep -c '' "$TMP_ROOT/catch.err")" = 1 ] || fail "catch-up failure was not one line"
grep -q 'fm-wake-daily.py:[0-9].*2026-11-27.*IsADirectoryError' "$TMP_ROOT/catch.err" || fail "catch-up failure lacked its day, error, and source line"
[ -f "$(catch_day 2026-11-21)" ] || fail "catch-up did not recover a missed day"
[ -f "$(catch_day 2026-11-28)" ] || fail "catch-up stopped at a failing day"
cmp -s "$TMP_ROOT/catch-23.json" "$(catch_day 2026-11-23)" || fail "catch-up rebuilt an unmeasured record past its retry window"
NOW=2026-11-28T12:00:00-08:00 collect --catch-up "$CATCH_HOME" >/dev/null || fail "in-window catch-up failed"
cmp -s "$TMP_ROOT/catch-26.json" "$(catch_day 2026-11-26)" || fail "catch-up rewrote a measured record inside its retry window"
collect 2026-11-26 "$CATCH_HOME" >/dev/null || fail "selected-day rebuild failed"
jq -e '[.contributions.projects[].scouts[].task] == ["after-final"]' "$(catch_day 2026-11-26)" >/dev/null \
  || fail "selected-day run did not rebuild a measured record"

pre_record="$CASE_HOME/data/wake/daily/$PRE.json"
collect "$PRE" >/dev/null || fail "pre-cutoff run failed"
jq -e --arg day "$PRE" '
  .coverage.merge_time_source == "done-archive"
  and .coverage.ledger_duplicates_dropped == 0
  and .coverage.signals.ships == {"status": "measured", "count": 1}
  and .coverage.signals.hostupdate_mr_pipeline_wall_time == {"status": "measured", "count": 0}
  and .contributions.projects[0].ships == [{"task": "old-ship", "title": "Old ship", "evidence": "data/done-archive.md#old-ship", "merged_at": $day, "time_precision": "day"}]
' "$pre_record" >/dev/null || fail "pre-cutoff ships did not come from done-archive dates"

printf 'fail\n' > "$MOCK_GLAB_MODE_FILE"
collect "$POST" >/dev/null || fail "unreachable GitLab run failed"
jq -e '
  .hostupdate_mr_pipeline_wall_time.summary == {"count": null, "median_seconds": null, "p90_seconds": null, "share_under_60s": null}
  and .hostupdate_mr_pipeline_wall_time.initial_summary == {"count": null, "median_seconds": null, "p90_seconds": null, "share_under_60s": null}
  and ([.hostupdate_mr_pipeline_wall_time.initial_by_change_class[].count] == [null, null, null])
  and .coverage.signals.hostupdate_mr_pipeline_wall_time.status == "not_measurable"
  and .coverage.signals.hostupdate_mr_pipeline_wall_time.count == null
  and .coverage.signals.hostupdate_mr_pipeline_wall_time.error == "GitLab API request failed (glab exit 1)"
  and .coverage.signals.hostupdate_mr_pipeline_wall_time.pipeline_id == null
  and .coverage.inputs["gitlab:lsg-git.lbl.gov/lblnet/lblnet_hostupdate/pipelines"].status == "not_measurable"
' "$record" >/dev/null || fail "unreachable GitLab was counted as zero"
printf 'bad-url\n' > "$MOCK_GLAB_MODE_FILE"
collect "$POST" >/dev/null || fail "invalid GitLab detail run failed"
jq -e '
  .coverage.signals.hostupdate_mr_pipeline_wall_time.status == "not_measurable"
  and .coverage.signals.hostupdate_mr_pipeline_wall_time.count == null
  and .coverage.inputs["gitlab:lsg-git.lbl.gov/lblnet/lblnet_hostupdate/pipelines"].error == "invalid pipeline URL"
  and .coverage.inputs["gitlab:lsg-git.lbl.gov/lblnet/lblnet_hostupdate/pipelines"].pipeline_id == 900003
  and .hostupdate_mr_pipeline_wall_time.pipelines == []
' "$record" >/dev/null || fail "invalid GitLab detail lost its diagnostic"
rm "$MOCK_GLAB_MODE_FILE"

cmp -s "$TMP_ROOT/backlog-saved.md" "$CASE_HOME/data/backlog.md" || fail "backlog changed"
cmp -s "$TMP_ROOT/archive-saved.md" "$CASE_HOME/data/done-archive.md" || fail "archive changed"
cmp -s "$TMP_ROOT/ledger-saved.jsonl" "$CASE_HOME/state/fleet-ledger.jsonl" || fail "ledger changed"
cmp -s "$TMP_ROOT/questions-saved.json" "$CASE_HOME/data/captain-questions.json" || fail "questions changed"

# The live watcher starts the finite catch-up job on its existing check cadence.
# Keep all endpoint and forge reads inside this synthetic home.
SCHEDULE_HOME="$TMP_ROOT/scheduled-home"
mkdir -p "$SCHEDULE_HOME/data" "$SCHEDULE_HOME/state" "$TMP_ROOT/watch-bin"
printf '## Done\n' > "$SCHEDULE_HOME/data/backlog.md"
printf '## Done\n' > "$SCHEDULE_HOME/data/done-archive.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/watch-bin/tmux"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/watch-bin/glab"
mkdir -p "$SCHEDULE_HOME/data/wake/daily/2026-11-21.json"
for n in $(seq 1 2000); do printf 'prefill-%04d %0600d\n' "$n" 0; done > "$SCHEDULE_HOME/state/wake-daily.log"
REAL_PYTHON=$(command -v python3)
cat > "$TMP_ROOT/watch-bin/python3" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == */fm-wake-daily.py ]]; then
  exec "$REAL_PYTHON" "$PINNED" "\$1" 2026-11-24T12:00:00-08:00 "\${@:2}"
fi
exec "$REAL_PYTHON" "\$@"
EOF
chmod +x "$TMP_ROOT/watch-bin/"*
PATH="$TMP_ROOT/watch-bin:$PATH" FM_HOME="$SCHEDULE_HOME" FM_STATE_OVERRIDE="$SCHEDULE_HOME/state" \
  FM_WAKE_DAILY_DISABLE=0 FM_POLL=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
  bash "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
WATCH_PID=$!
for _ in {1..30}; do
  [ -f "$SCHEDULE_HOME/data/wake/daily/2026-11-22.json" ] && grep -q '2026-11-21' "$SCHEDULE_HOME/state/wake-daily.log" 2>/dev/null && break
  sleep 0.2
done
kill -TERM "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
[ -f "$SCHEDULE_HOME/data/wake/daily/2026-11-22.json" ] || fail "watcher did not schedule daily catch-up"
[ ! -e "$SCHEDULE_HOME/data/wake/daily/2026-11-23.json" ] || fail "watcher catch-up did not lag one day"
grep -q 'fm-wake-daily.py:[0-9].*2026-11-21' "$SCHEDULE_HOME/state/wake-daily.log" || fail "watcher discarded a collector failure"
! grep -q 'prefill-0001 ' "$SCHEDULE_HOME/state/wake-daily.log" || fail "watcher did not trim an oversized collector log"
grep -q 'prefill-2000 ' "$SCHEDULE_HOME/state/wake-daily.log" || fail "watcher trimmed recent collector log lines"
[ "$(wc -c < "$SCHEDULE_HOME/state/wake-daily.log")" -lt 1048576 ] || fail "collector log stayed oversized"

mv "$CASE_HOME/state/fleet-ledger.jsonl" "$TMP_ROOT/ledger-removed.jsonl"
collect "$POST" >/dev/null || fail "missing-ledger run failed"
jq -e '.coverage.signals.ships.status == "not_measurable" and .coverage.signals.ships.count == null and .coverage.signals.links.status == "not_measurable" and .coverage.signals.links.count == null and .coverage.inputs["'"$CASE_HOME"'/state/fleet-ledger.jsonl"].reason == "absent"' "$record" >/dev/null || fail "missing ledger reported as zero"
collect "$PRE" >/dev/null || fail "pre-cutoff missing-ledger run failed"
jq -e '.coverage.signals.ships == {"status": "measured", "count": 1} and .coverage.signals.links.status == "measured"' "$pre_record" >/dev/null || fail "pre-cutoff records required the ledger"

{ cat "$TMP_ROOT/ledger-saved.jsonl"; printf '{not json\n'; } > "$CASE_HOME/state/fleet-ledger.jsonl"
collect "$POST" >/dev/null || fail "invalid-ledger run failed"
jq -e '.coverage.signals.ships.status == "not_measurable" and .coverage.signals.ships.count == null and .coverage.inputs["'"$CASE_HOME"'/state/fleet-ledger.jsonl"].reason == "invalid JSON line 13"' "$record" >/dev/null || fail "invalid ledger reported as measured"

# TODAY can equal a fixed fixture day collected above; clear it so the check sees only this run.
rm -f "$CASE_HOME/data/wake/daily/$TODAY.json"
if python3 "$ROOT/bin/fm-wake-daily.py" "$TODAY" --home "$CASE_HOME" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail "incomplete day was accepted"
fi
grep -q 'not complete' "$TMP_ROOT/err" || fail "incomplete day reason missing"
[ ! -e "$CASE_HOME/data/wake/daily/$TODAY.json" ] || fail "incomplete day wrote a record"

LINK_HOME="$TMP_ROOT/links-home"
mkdir -p "$LINK_HOME/data"
cat > "$LINK_HOME/data/backlog.md" <<'EOF'
## Done
- [x] batch-ci-speed - Scout pipeline speed data/batch-ci-speed/report.md (repo: example) (kind: scout) (reported 2026-10-02)
- [x] batch-ci-speed-impl - Ship P0 from data/batch-ci-speed/report.md (repo: example) (kind: ship) (reported 2026-10-02)
  merge request https://example.org/example/-/merge_requests/10
- [x] batch-ci-speed-stages - Ship P1+P2 for story 2.1 in epic 4 blocked-by: batch-ci-speed-impl (repo: example) (kind: ship) (done 2026-10-02)
  merge request https://example.org/example/-/merge_requests/11
- [x] batch-ci-speed-p3p4 - Ship P3+P4 (repo: example) (kind: ship) (done 2026-10-02)
- [x] batch-ci-speed-p5 - Ship P5 (repo: example) (kind: ship) (done 2026-10-02)
  Follow-up to scout task older-scout.
- [x] batch-ci-speed-p6 - Ship P6 (repo: example) (kind: ship) (done 2026-10-02)
- [x] batch-unit-test-scout - Scout unit tests data/batch-unit-test-scout/report.md (repo: example) (kind: scout) (reported 2026-10-02)
- [x] batch-ci-chain-trim - Ship xdist and chain trim (repo: example) (kind: ship) (done 2026-10-02)
  From scout report data/batch-unit-test-scout/report.md.
- [x] older-scout - Earlier investigation data/older-scout/report.md (repo: example) (kind: scout) (reported 2026-10-01)
- [x] flow-scout - Scout deployment data/flow-scout/report.md (repo: example) (kind: scout) (reported 2026-10-12)
- [x] flow-decision - Choose deployment flow (repo: example) (kind: captain) (done 2026-10-13)
  Captain hold origin: flow-scout
- [x] nest-ci-speed-impl - Ship nested impl (repo: example) (kind: ship) (done 2026-10-03)
- [x] nest-ci-speed-impl-fix - Fix nested impl (repo: example) (kind: ship) (done 2026-10-03)
- [x] nest-ci-speed-p5 - Ship nested P5 (repo: example) (kind: ship) (done 2026-10-03)
EOF
: > "$LINK_HOME/data/done-archive.md"
cp "$LINK_HOME/data/backlog.md" "$TMP_ROOT/links-backlog-saved.md"
collect 2026-10-02 "$LINK_HOME" >/dev/null || fail "links fixture collection failed"
link_record="$LINK_HOME/data/wake/daily/2026-10-02.json"
jq -e '
  .coverage.signals.links == {"status":"measured","count":10}
  and ([.links.items[] | select(.kind == "task" and (.id | startswith("batch-ci-speed-"))) | .id] | length) == 5
  and ([.links.items[] | select(.kind == "task" and (.id | startswith("batch-ci-speed-"))) | .id_family] | unique) == ["batch-ci-speed"]
  and ([.links.items[] | select(.kind == "task" and (.id | startswith("batch-ci-speed-"))) | .family_tasks | length] | min) == 5
  and (.links.items[] | select(.id == "batch-ci-speed-stages") | .blocked_by) == ["batch-ci-speed-impl"]
  and (.links.items[] | select(.id == "batch-ci-speed-stages") | .story_refs) == ["2.1"]
  and (.links.items[] | select(.id == "batch-ci-speed-stages") | .epic_refs) == ["4"]
  and (.links.items[] | select(.id == "batch-ci-speed-impl") | .scout_reports) == ["data/batch-ci-speed/report.md"]
  and (.links.items[] | select(.id == "batch-ci-speed-p5") | .scout_tasks) == ["older-scout"]
  and (.links.items[] | select(.id == "batch-ci-chain-trim") | .scout_reports) == ["data/batch-unit-test-scout/report.md"]
  and (.links.items[] | select(.id == "batch-ci-chain-trim") | .id_family) == null
  and (.links.items[] | select(.id == "batch-ci-chain-trim") | .family_tasks) == []
  and (.links.items[] | select(.id == "batch-ci-chain-trim") | .blocked_by) == []
  and (.links.items[] | select(.id == "https://example.org/example/-/merge_requests/11") | .task) == "batch-ci-speed-stages"
  and (.links.items[] | select(.id == "https://example.org/example/-/merge_requests/11") | .blocked_by) == ["batch-ci-speed-impl"]
' "$link_record" >/dev/null || fail "links missed family, dependency, references, scout, or MR relation"
cp "$link_record" "$TMP_ROOT/links-first.json"
collect 2026-10-02 "$LINK_HOME" >/dev/null || fail "links rerun failed"
cmp -s "$TMP_ROOT/links-first.json" "$link_record" || fail "links rerun changed bytes"
cmp -s "$TMP_ROOT/links-backlog-saved.md" "$LINK_HOME/data/backlog.md" || fail "links source changed"
collect 2026-10-13 "$LINK_HOME" >/dev/null || fail "origin fixture collection failed"
jq -e '(.links.items[] | select(.id == "flow-decision") | .origin_tasks) == ["flow-scout"]' \
  "$LINK_HOME/data/wake/daily/2026-10-13.json" >/dev/null || fail "closed decision lost origin"
collect 2026-10-03 "$LINK_HOME" >/dev/null || fail "nested family fixture collection failed"
jq -e '
  ([.links.items[] | select(.kind == "task") | .id_family] | unique) == ["nest-ci-speed"]
  and (.links.items[] | select(.id == "nest-ci-speed-impl") | .family_tasks) == ["nest-ci-speed-impl-fix", "nest-ci-speed-p5"]
  and (.links.items[] | select(.id == "nest-ci-speed-impl-fix") | .family_tasks) == ["nest-ci-speed-impl", "nest-ci-speed-p5"]
  and (.links.items[] | select(.id == "nest-ci-speed-p5") | .family_tasks) == ["nest-ci-speed-impl", "nest-ci-speed-impl-fix"]
' "$LINK_HOME/data/wake/daily/2026-10-03.json" >/dev/null || fail "nested family links were not symmetric"

printf 'ok: Wake daily collector\n'
