#!/usr/bin/env bash
# Exercise the public collector with fixture records, repeat runs, and absent inputs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-daily)
CASE_HOME="$TMP_ROOT/home"
mkdir -p "$CASE_HOME/data" "$CASE_HOME/state"
DAY=$(python3 -c 'from datetime import datetime,timedelta; from zoneinfo import ZoneInfo; print((datetime.now(ZoneInfo("America/Los_Angeles")).date()-timedelta(days=1)).isoformat())')
TODAY=$(python3 -c 'from datetime import datetime; from zoneinfo import ZoneInfo; print(datetime.now(ZoneInfo("America/Los_Angeles")).date().isoformat())')
EPOCH=$(python3 - "$DAY" <<'PY'
from datetime import datetime
from zoneinfo import ZoneInfo
import sys
print(int(datetime.fromisoformat(sys.argv[1] + "T12:00:00").replace(tzinfo=ZoneInfo("America/Los_Angeles")).timestamp()))
PY
)

cat > "$CASE_HOME/data/backlog.md" <<EOF
## In flight
- [ ] live-ship - Current title (repo: alpha) (kind: ship) (since $DAY)

## Done
- [x] ship-a - Ship title with exact words https://example.org/a/pull/1 (repo: alpha) (kind: ship) (merged $DAY)
  Resolution mode: answered

  Captain decision:
  Which route? -> Use the route, exactly.
EOF
cat > "$CASE_HOME/data/done-archive.md" <<EOF
## Archived $DAY
- [x] ship-a - Ship title with exact words https://example.org/a/pull/1 (repo: alpha) (kind: ship) (merged $DAY)
- [x] scout-a - Scout title data/scout-a/report.md (repo: alpha) (kind: scout) (reported $DAY)
- [x] unknown-a - Unknown kind title (done $DAY)
EOF
cat > "$CASE_HOME/state/fleet-ledger.jsonl" <<EOF
{"v":1,"ts":$EPOCH,"event":"task.dispatched","task":"ship-a","kind":"ship","project":"alpha"}
{"v":1,"ts":$EPOCH,"event":"task.dispatched","task":"ship-a","kind":"ship","project":"alpha"}
{"v":1,"ts":$EPOCH,"event":"task.merged","task":"ship-a","via":"pr","pr":"https://example.org/a/pull/1"}
{"v":1,"ts":$EPOCH,"event":"task.merged","task":"ship-a","via":"pr","pr":"https://example.org/a/pull/1"}
EOF
cat > "$CASE_HOME/data/captain-questions.json" <<EOF
{"schema":"fm-captain-questions.v1","questions":[]}
EOF

cp "$CASE_HOME/data/backlog.md" "$TMP_ROOT/backlog-saved.md"
cp "$CASE_HOME/data/done-archive.md" "$TMP_ROOT/archive-saved.md"
cp "$CASE_HOME/state/fleet-ledger.jsonl" "$TMP_ROOT/ledger-saved.jsonl"
cp "$CASE_HOME/data/captain-questions.json" "$TMP_ROOT/questions-saved.json"
out=$(python3 "$ROOT/bin/fm-wake-daily.py" "$DAY" --home "$CASE_HOME") || fail "collector failed"
[ "$out" = "$CASE_HOME/data/wake/daily/$DAY.json" ] || fail "unexpected output path: $out"
record="$CASE_HOME/data/wake/daily/$DAY.json"
jq -e --arg day "$DAY" '
  .schema == "fm-wake-daily.v1"
  and .day == $day
  and .coverage.ledger_duplicates_dropped == 2
  and .coverage.signals.ships.count == 1
  and .coverage.signals.scouts.count == 1
  and .coverage.signals.decisions.count == 1
  and .contributions.projects[0].project == "alpha"
  and .contributions.projects[0].ships[0].title == "Ship title with exact words"
  and .contributions.projects[0].ships[0].time_precision == "second"
  and .contributions.projects[0].ships[0].evidence == "https://example.org/a/pull/1"
  and .contributions.projects[0].scouts[0].evidence == "data/scout-a/report.md"
  and .contributions.projects[0].decisions[0].question == "Which route?"
  and .contributions.projects[0].decisions[0].answer == "Use the route, exactly."
  and .contributions.projects[1].project == "none recorded"
  and .contributions.projects[1].unclassified[0].title == "Unknown kind title"
' "$record" >/dev/null || fail "outcomes lost evidence, titles, or decision words"

cp "$record" "$TMP_ROOT/first.json"
python3 "$ROOT/bin/fm-wake-daily.py" "$DAY" --home "$CASE_HOME" >/dev/null || fail "repeat run failed"
cmp -s "$TMP_ROOT/first.json" "$record" || fail "repeat run changed bytes"
cmp -s "$TMP_ROOT/backlog-saved.md" "$CASE_HOME/data/backlog.md" || fail "backlog changed"
cmp -s "$TMP_ROOT/archive-saved.md" "$CASE_HOME/data/done-archive.md" || fail "archive changed"
cmp -s "$TMP_ROOT/ledger-saved.jsonl" "$CASE_HOME/state/fleet-ledger.jsonl" || fail "ledger changed"
cmp -s "$TMP_ROOT/questions-saved.json" "$CASE_HOME/data/captain-questions.json" || fail "questions changed"

mv "$CASE_HOME/state/fleet-ledger.jsonl" "$TMP_ROOT/ledger-removed.jsonl"
python3 "$ROOT/bin/fm-wake-daily.py" "$DAY" --home "$CASE_HOME" >/dev/null || fail "missing-ledger run failed"
jq -e '.coverage.signals.ships.status == "not_measurable" and .coverage.signals.ships.count == null and .coverage.inputs["'"$CASE_HOME"'/state/fleet-ledger.jsonl"].reason == "absent"' "$record" >/dev/null || fail "missing ledger reported as zero"

if python3 "$ROOT/bin/fm-wake-daily.py" "$TODAY" --home "$CASE_HOME" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail "incomplete day was accepted"
fi
grep -q 'not complete' "$TMP_ROOT/err" || fail "incomplete day reason missing"
[ ! -e "$CASE_HOME/data/wake/daily/$TODAY.json" ] || fail "incomplete day wrote a record"

printf 'ok: Wake daily collector\n'
