#!/usr/bin/env bash
# Exercise the public collector with fixture records, repeat runs, and absent inputs.
# Expected values follow docs/wake-daily.md and the story's acceptance criteria.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-daily)
CASE_HOME="$TMP_ROOT/home"
mkdir -p "$CASE_HOME/data" "$CASE_HOME/state"
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
collect() {
  python3 - "$ROOT/bin/fm-wake-daily.py" "$NOW" "$1" --home "${2:-$CASE_HOME}" <<'PY'
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
  and .coverage.signals.scouts == {"status": "measured", "count": 2}
  and .coverage.signals.decisions == {"status": "measured", "count": 2}
  and .coverage.uncounted_decisions == {"count": 1, "reason": "answer time unknown (task still open)"}
  and ([.contributions.projects[].project] == ["alpha", "beta", "none recorded"])
  and .contributions.projects[0].ships == [
    {"task": "ship-a", "title": "Ship title with exact words", "evidence": "https://example.org/a/pull/1", "merged_at": "2026-11-22T20:00:00Z", "time_precision": "second"},
    {"task": "ship-c", "title": "Reordered merge ship", "evidence": "https://example.org/a/pull/3", "merged_at": "2026-11-22T20:00:00Z", "time_precision": "second"}]
  and ([.contributions.projects[0].scouts[].task] == ["scout-a", "scout-b"])
  and .contributions.projects[0].scouts[0].evidence == "data/scout-a/report.md"
  and .contributions.projects[0].scouts[1] == {"task": "scout-b", "title": "Scout without path", "evidence": "data/scout-b/report.md", "reported_on": $day}
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

pre_record="$CASE_HOME/data/wake/daily/$PRE.json"
collect "$PRE" >/dev/null || fail "pre-cutoff run failed"
jq -e --arg day "$PRE" '
  .coverage.merge_time_source == "done-archive"
  and .coverage.ledger_duplicates_dropped == 0
  and .coverage.signals.ships == {"status": "measured", "count": 1}
  and .contributions.projects[0].ships == [{"task": "old-ship", "title": "Old ship", "evidence": "data/done-archive.md#old-ship", "merged_at": $day, "time_precision": "day"}]
' "$pre_record" >/dev/null || fail "pre-cutoff ships did not come from done-archive dates"

cmp -s "$TMP_ROOT/backlog-saved.md" "$CASE_HOME/data/backlog.md" || fail "backlog changed"
cmp -s "$TMP_ROOT/archive-saved.md" "$CASE_HOME/data/done-archive.md" || fail "archive changed"
cmp -s "$TMP_ROOT/ledger-saved.jsonl" "$CASE_HOME/state/fleet-ledger.jsonl" || fail "ledger changed"
cmp -s "$TMP_ROOT/questions-saved.json" "$CASE_HOME/data/captain-questions.json" || fail "questions changed"

mv "$CASE_HOME/state/fleet-ledger.jsonl" "$TMP_ROOT/ledger-removed.jsonl"
collect "$POST" >/dev/null || fail "missing-ledger run failed"
jq -e '.coverage.signals.ships.status == "not_measurable" and .coverage.signals.ships.count == null and .coverage.signals.links.status == "not_measurable" and .coverage.signals.links.count == null and .coverage.inputs["'"$CASE_HOME"'/state/fleet-ledger.jsonl"].reason == "absent"' "$record" >/dev/null || fail "missing ledger reported as zero"
collect "$PRE" >/dev/null || fail "pre-cutoff missing-ledger run failed"
jq -e '.coverage.signals.ships == {"status": "measured", "count": 1} and .coverage.signals.links.status == "measured"' "$pre_record" >/dev/null || fail "pre-cutoff records required the ledger"

{ cat "$TMP_ROOT/ledger-saved.jsonl"; printf '{not json\n'; } > "$CASE_HOME/state/fleet-ledger.jsonl"
collect "$POST" >/dev/null || fail "invalid-ledger run failed"
jq -e '.coverage.signals.ships.status == "not_measurable" and .coverage.signals.ships.count == null and .coverage.inputs["'"$CASE_HOME"'/state/fleet-ledger.jsonl"].reason == "invalid JSON line 13"' "$record" >/dev/null || fail "invalid ledger reported as measured"

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
