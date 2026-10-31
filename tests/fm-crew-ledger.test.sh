#!/usr/bin/env bash
# Regression for a paused, idle ship whose no-mistakes CI step never advances.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
home=$(fm_test_tmproot fm-crew-ledger)/home
mkdir -p "$home/state" "$home/projects/task" "$home/fakebin" "$home/data/ci-ship"
cat > "$home/data/ci-ship/brief.md" <<'MD'
# Task
## Captain's intent
Make the portal capture visible.

## Firstmate spec
More detail.
MD
cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-ci-ship\n' ;;
  capture-pane) printf 'Finished turn\n> \n' ;;
  display-message) printf '%%1\n' ;;
esac
SH
cat > "$home/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FM_HOME/crew-state-fail" ] || exit 124
[ "$1" != never-read ] || exit 124
if tail -1 "$FM_HOME/state/$1.status" 2>/dev/null | grep -q '^done '; then
  printf 'state: done · source: status-log · delivered\n'
  exit 0
fi
if [ "$1" != ci-ship ]; then
  if [ "$1" = ci-progress ]; then
    printf 'state: working · source: run-step · validating (running)\n'
    printf 'run-step: running/running\n'
    printf 'run-pr: https://github.com/clarsen/firstmate/pull/35\n'
    exit 0
  fi
  if [ "$1" = ci-undeclared ]; then
    printf 'state: working · source: run-step · validating (running)\n'
    printf 'run-step: running/running\n'
    printf 'run-pr: https://github.com/clarsen/firstmate/pull/35\n'
    exit 0
  fi
  if [ "${1#mr-}" != "$1" ]; then
    printf 'state: working · source: run-step · validating (running)\n'
    printf 'run-step: running/running\n'
    printf 'run-pr: https://gitlab.example.com/group/other-project/-/merge_requests/12416\n'
    exit 0
  fi
  printf 'state: unknown · source: none · no run\n'
  exit 0
fi
step=$(cat "$FM_HOME/run-step")
printf 'state: working · source: run-step · validating (%s)\n' "$step"
printf 'run-step: %s\n' "$step"
SH
cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/ci-snapshot"
SH
cat > "$home/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'/jobs?'*) cat "$FM_HOME/mr-jobs" ;;
  *) cat "$FM_HOME/mr-snapshot" ;;
esac
SH
cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "$1" = show ] && [ "$2" = ci-ship ] || exit 1
[ ! -e "$FM_HOME/backlog-fail" ] || exit 1
[ -f "$FM_HOME/backlog-title" ] || exit 1
printf '  title: %s\n' "$(cat "$FM_HOME/backlog-title")"
SH
chmod +x "$home/fakebin/tmux" "$home/fakebin/crew-state" "$home/fakebin/gh" "$home/fakebin/glab" "$home/fakebin/tasks-axi"
printf 'Track portal capture\n' > "$home/backlog-title"
fm_write_meta "$home/state/ci-ship.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-ci-ship' \
  "worktree=$home/projects/task" "project=$home/projects/therealfirstmate" 'spawn_gen=one'
printf 'running\n' > "$home/run-step"
printf 'paused [at=8000]: CI monitor running; resume on final CI result\n' > "$home/state/ci-ship.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ci-ship)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" ci-ship idle --gen "$gen" \
  --source claude-hook --event stop

tick() {
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/fakebin/crew-state" FM_CREW_LEDGER_NOW="$1" \
    FM_CREW_LEDGER_GH_BIN="$home/fakebin/gh" \
    FM_CREW_LEDGER_GLAB_BIN="$home/fakebin/glab" \
    FM_CREW_LEDGER_WAIT_SECS=900 FM_CREW_LEDGER_IDLE_SECS=300 \
    "$ROOT/bin/fm-crew-ledger.sh" tick
}

out=$(tick 10000) || fail 'first ledger tick failed'
assert_contains "$out" 'check: crew-ledger ci-ship declared-wait-no-run-progress' \
  'old paused run-step wakes for inspection'
jq -e --arg worktree "$home/projects/task" '.crew[0] | .harness.state == "idle" and .last_status.at == 8000 and
  .run_step.state == "running" and .run_step.changed_at == 8000 and .checked_at == 10000 and
  .alert.condition == "declared-wait-no-run-progress" and
  .title == "Track portal capture" and .request == "Make the portal capture visible." and
  .project == "therealfirstmate" and .worktree == $worktree and .current_state.since == 10000' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'ledger evidence is incomplete'
printf '"Track \\"portal\\", capture"\n' > "$home/backlog-title"
out=$(tick 10000) || fail 'quoted backlog title tick failed'
jq -e '.crew[0].title == "Track \"portal\", capture"' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'quoted backlog title was not decoded'
rm "$home/backlog-title"
out=$(tick 10001) || fail 'missing backlog title tick failed'
assert_equals '' "$out" 'missing backlog title does not change alert evidence'
jq -e '.crew[0] | .title == "Make the portal capture visible." and
  .request == "Make the portal capture visible."' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'missing backlog title did not fall back to request'
printf 'Track portal capture\n' > "$home/backlog-title"
: > "$home/backlog-fail"
out=$(tick 10002) || fail 'failed backlog read tick failed'
assert_equals '' "$out" 'failed backlog read does not change alert evidence'
jq -e '.crew[0] | .title == "Make the portal capture visible." and
  .request == "Make the portal capture visible."' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'failed backlog read did not fall back to request'
rm "$home/backlog-fail"
out=$(tick 10060) || fail 'repeat ledger tick failed'
assert_equals '' "$out" 'unchanged evidence does not repeat the wake'
jq -e '.crew[0].current_state.since == 10000' "$home/state/crew-ledger.json" >/dev/null \
  || fail 'unchanged current state reset its since epoch'
printf 'resolved [at=10060] [key=other]: unrelated decision closed\n' >> "$home/state/ci-ship.status"
out=$(tick 10060) || fail 'unrelated resolution tick failed'
assert_equals '' "$out" 'an unrelated resolution does not repeat or reset the declared wait'
jq -e '.crew[0] | .last_status.state == "resolved" and
  .declared_wait.class == "paused" and .run_step.changed_at == 8000' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'declared wait was lost behind a resolution'
printf 'paused [at=10061]: CI monitor reattached; resume on result\n' >> "$home/state/ci-ship.status"
out=$(tick 10061) || fail 'renewed declaration tick failed'
assert_equals '' "$out" 'a new declaration starts a new wait interval'
jq -e '.crew[0] | .run_step.changed_at == 8000 and .declared_wait.since == 10061' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'a new wait incorrectly changed the run-step timestamp'

printf 'fixing\n' > "$home/run-step"
out=$(tick 10062) || fail 'advanced run-step tick failed'
assert_equals '' "$out" 'run-step progress clears the stale condition'
jq -e '.crew[0] | .run_step.changed_at == 10062 and .alert == null' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'run-step change was not recorded'
out=$(tick 10963) || fail 'second stalled run-step tick failed'
assert_contains "$out" 'declared-wait-no-run-progress' 'a new stall gets one wake'

printf 'done [at=10964]: delivered\n' > "$home/state/ci-ship.status"
out=$(tick 10965) || fail 'terminal status tick failed'
assert_equals '' "$out" 'terminal status clears the alert'
jq -e '.crew[0].alert == null' "$home/state/crew-ledger.json" >/dev/null \
  || fail 'terminal status left an alert open'
jq -e '.crew[0].current_state | .state == "done" and .since == 10965' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'terminal state did not get its own since epoch'
fm_write_meta "$home/state/ci-progress.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-ci-progress' \
  "worktree=$home/projects/task" 'spawn_gen=one'
printf 'paused [at=15000]: CI monitor running; resume on final CI result\n' \
  > "$home/state/ci-progress.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ci-progress)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" ci-progress idle --gen "$gen" \
  --source claude-hook --event stop
cat > "$home/ci-snapshot" <<'JSON'
{"headRefOid":"0000000000000000000000000000000000000001","statusCheckRollup":[{"__typename":"CheckRun","name":"linux-a","status":"COMPLETED","completedAt":"1970-01-01T04:36:40Z"},{"__typename":"CheckRun","name":"linux-q1","status":"QUEUED","completedAt":"0001-01-01T00:00:00Z"}]}
JSON
out=$(tick 16800) || fail 'CI completion baseline failed'
assert_equals '' "$out" 'recent PR job completion prevents a stale wait alarm'
jq -e '.crew[] | select(.id == "ci-progress") | .title == null and .request == null and
  .project == null and .worktree != null and .current_state.since == 16800' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'ledger row without brief must have null title'
jq -e '.crew[] | select(.id == "ci-progress") |
  .ci_progress.completed_count == 1 and .ci_progress.progress_at == 16600 and .alert == null' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'PR completion was not recorded'
cat > "$home/ci-snapshot" <<'JSON'
{"headRefOid":"0000000000000000000000000000000000000001","statusCheckRollup":[{"__typename":"CheckRun","name":"linux-a","status":"COMPLETED","completedAt":"1970-01-01T04:36:40Z"},{"__typename":"CheckRun","name":"linux-q1","status":"QUEUED","completedAt":"0001-01-01T00:00:00Z"},{"__typename":"CheckRun","name":"linux-q2","status":"QUEUED","completedAt":"0001-01-01T00:00:00Z"}]}
JSON
out=$(tick 17501) || fail 'CI job stall tick failed'
assert_contains "$out" 'ci-progress declared-wait-no-ci-progress' \
  'no new PR completion past the bound wakes firstmate'
assert_contains "$out" 'completed-checks=1; last-completion=16600' \
  'CI wake names the actual progress evidence'
out=$(tick 17502) || fail 'repeat CI job stall tick failed'
assert_equals '' "$out" 'same queued CI condition does not repeat'
cp "$home/ci-snapshot" "$home/ci-snapshot.good"
: > "$home/ci-snapshot"
out=$(tick 17502 2>/dev/null) || fail 'failed CI read tick failed'
assert_equals '' "$out" 'a failed CI read does not start a new alert episode'
mv "$home/ci-snapshot.good" "$home/ci-snapshot"
out=$(tick 17502) || fail 'recovered CI read tick failed'
assert_equals '' "$out" 'a recovered CI read does not repeat the alert'
: > "$home/crew-state-fail"
out=$(tick 17502 2>/dev/null) || fail 'failed crew-state tick failed'
assert_equals '' "$out" 'an unreadable crew-state verdict does not start a new alert episode'
rm -f "$home/crew-state-fail"
out=$(tick 17502) || fail 'recovered crew-state tick failed'
assert_equals '' "$out" 'a recovered crew-state verdict does not repeat the alert'
cat > "$home/ci-snapshot" <<'JSON'
{"headRefOid":"0000000000000000000000000000000000000001","statusCheckRollup":[{"__typename":"CheckRun","name":"linux-a","status":"COMPLETED","completedAt":"1970-01-01T04:36:40Z"},{"__typename":"CheckRun","name":"linux-b","status":"COMPLETED","completedAt":"1970-01-01T04:51:40Z"},{"__typename":"CheckRun","name":"linux-q2","status":"QUEUED","completedAt":"0001-01-01T00:00:00Z"}]}
JSON
out=$(tick 17503) || fail 'new PR completion tick failed'
assert_equals '' "$out" 'a completed PR job clears the stale condition'
out=$(tick 18401) || fail 'second CI job stall tick failed'
assert_contains "$out" 'ci-progress declared-wait-no-ci-progress' \
  'a later unchanged PR check set may trigger one new alarm'
cp "$home/ci-snapshot" "$home/ci-snapshot.good"
: > "$home/ci-snapshot"
out=$(tick 18500 2>/dev/null) || fail 'repeated CI read failure tick failed'
assert_equals '' "$out" 'recent CI evidence carries over a failed read'
out=$(tick 19302 2>/dev/null) || fail 'stale CI evidence tick failed'
assert_contains "$out" 'ci-progress declared-wait-ci-unverified' \
  'CI evidence older than the bound is reported unverified'
assert_contains "$out" 'CI evidence unavailable' 'unverified CI wake does not cite stale checks'
out=$(tick 19362 2>/dev/null) || fail 'repeated stale CI evidence tick failed'
assert_equals '' "$out" 'an unchanged CI read failure wakes only once'
mv "$home/ci-snapshot.good" "$home/ci-snapshot"
out=$(tick 19400) || fail 'CI read recovery tick failed'
assert_contains "$out" 'ci-progress declared-wait-no-ci-progress' \
  'recovered CI evidence reports the real stall once'
jq -e '.crew[] | select(.id == "ci-progress") | .ci_progress.observed_at == 19400' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'recovered CI read was not recorded as observed'
out=$(tick 19460) || fail 'recovered CI repeat tick failed'
assert_equals '' "$out" 'recovered CI stall does not repeat'
printf 'done [at=18402]: delivered\n' > "$home/state/ci-progress.status"
fm_write_meta "$home/state/mr-skipped.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-mr-skipped' \
  "worktree=$home/projects/task" 'spawn_gen=one'
printf 'paused [at=20000]: CI monitor running; resume on final CI result\n' \
  > "$home/state/mr-skipped.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" mr-skipped)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" mr-skipped idle --gen "$gen" \
  --source claude-hook --event stop
cat > "$home/mr-snapshot" <<'JSON'
{"sha":"0000000000000000000000000000000000000002","head_pipeline":{"id":837362,"sha":"0000000000000000000000000000000000000002","status":"skipped"}}
JSON
printf '[]\n' > "$home/mr-jobs"
out=$(tick 20010) || fail 'skipped MR head tick failed'
assert_contains "$out" 'mr-skipped ci-head-skipped' \
  'a skipped current-head pipeline wakes immediately for inspection'
assert_contains "$out" 'pipeline=skipped' 'skipped-head wake identifies the pipeline state'
out=$(tick 20070) || fail 'skipped MR head repeat failed'
assert_equals '' "$out" 'unchanged skipped head does not repeat'
printf 'done [at=20071]: delivered\n' > "$home/state/mr-skipped.status"
fm_write_meta "$home/state/mr-running.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-mr-running' \
  "worktree=$home/projects/task" 'spawn_gen=one'
printf 'paused [at=20000]: CI monitor running; resume on final CI result\n' \
  > "$home/state/mr-running.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" mr-running)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" mr-running idle --gen "$gen" \
  --source claude-hook --event stop
cat > "$home/mr-snapshot" <<'JSON'
{"sha":"0000000000000000000000000000000000000003","head_pipeline":{"id":837363,"sha":"0000000000000000000000000000000000000003","status":"running"}}
JSON
printf '[{"id":1,"finished_at":"1970-01-01T05:46:40.000Z"}]\n' > "$home/mr-jobs"
out=$(tick 21000) || fail 'running MR completion baseline failed'
assert_equals '' "$out" 'a completed MR pipeline job counts as progress'
out=$(tick 21901) || fail 'running MR stall tick failed'
assert_contains "$out" 'mr-running declared-wait-no-ci-progress' \
  'a running MR pipeline without another job completion wakes after the bound'
printf '[{"id":1,"finished_at":"1970-01-01T05:46:40.000Z"},{"id":2,"finished_at":"1970-01-01T06:05:00.000Z"}]\n' > "$home/mr-jobs"
out=$(tick 21902) || fail 'running MR completion tick failed'
assert_equals '' "$out" 'a new MR pipeline job completion clears the alert'
printf 'done [at=21903]: delivered\n' > "$home/state/mr-running.status"
# A worker that re-arms its bounded CI monitor takes a busy turn between idle
# observations; that turn must not restart the MR's job-completion clock.
fm_write_meta "$home/state/mr-rearm.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-mr-rearm' \
  "worktree=$home/projects/task" 'spawn_gen=one'
printf 'paused [at=22100]: CI monitor running; resume on final CI result\n' \
  > "$home/state/mr-rearm.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" mr-rearm)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" mr-rearm idle --gen "$gen" \
  --source claude-hook --event stop
cat > "$home/mr-snapshot" <<'JSON'
{"sha":"0000000000000000000000000000000000000004","head_pipeline":{"id":837364,"sha":"0000000000000000000000000000000000000004","status":"running"}}
JSON
printf '[{"id":1,"finished_at":"1970-01-01T06:10:00.000Z"}]\n' > "$home/mr-jobs"
out=$(tick 22300) || fail 'MR re-arm baseline failed'
assert_equals '' "$out" 'a recent MR job completion holds the re-armed wait'
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" mr-rearm busy --gen "$gen" \
  --source claude-hook --event user-prompt-submit
out=$(tick 22600) || fail 'MR re-arm busy tick failed'
assert_equals '' "$out" 'a busy re-arm turn does not alert'
jq -e '.crew[] | select(.id == "mr-rearm") | .harness.state == "running" and .ci_progress == null' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'busy re-arm turn was not observed'
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" mr-rearm idle --gen "$gen" \
  --source claude-hook --event stop
out=$(tick 23101) || fail 'MR re-arm stall tick failed'
assert_contains "$out" 'mr-rearm declared-wait-no-ci-progress' \
  'a re-armed MR wait without a new job completion wakes after the bound'
jq -e '.crew[] | select(.id == "mr-rearm") | .ci_progress.progress_at == 22200' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'MR progress was anchored to the re-arm'
printf 'done [at=23102]: delivered\n' > "$home/state/mr-rearm.status"
# An undeclared GitLab CI wait whose head pipeline has not finished any job.
fm_write_meta "$home/state/mr-pending.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-mr-pending' \
  "worktree=$home/projects/task" 'spawn_gen=one'
printf 'working [at=23200]: CI monitor running\n' > "$home/state/mr-pending.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" mr-pending)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" mr-pending idle --gen "$gen" \
  --source claude-hook --event stop
cat > "$home/mr-snapshot" <<'JSON'
{"sha":"0000000000000000000000000000000000000005","head_pipeline":{"id":837365,"sha":"0000000000000000000000000000000000000005","status":"pending"}}
JSON
printf '[]\n' > "$home/mr-jobs"
out=$(tick 23300) || fail 'MR without finished jobs baseline failed'
assert_equals '' "$out" 'a new MR pipeline without finished jobs gets the progress bound'
jq -e '.crew[] | select(.id == "mr-pending") |
  .ci_progress.completed_count == 0 and .ci_progress.progress_at == 23300' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'MR without finished jobs dropped out of the ledger'
out=$(tick 24201) || fail 'MR without finished jobs stall failed'
assert_contains "$out" 'mr-pending run-step-no-ci-progress' \
  'an MR pipeline that never finishes a job wakes after the bound'
printf 'done [at=24202]: delivered\n' > "$home/state/mr-pending.status"
fm_write_meta "$home/state/ci-undeclared.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-ci-undeclared' \
  "worktree=$home/projects/task" 'spawn_gen=one'
printf 'working [at=22000]: CI monitor running\n' > "$home/state/ci-undeclared.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ci-undeclared)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" ci-undeclared idle --gen "$gen" \
  --source claude-hook --event stop
out=$(tick 23000) || fail 'undeclared CI wait baseline failed'
assert_equals '' "$out" 'first observation of an undeclared CI wait gets the progress bound'
out=$(tick 23901) || fail 'undeclared CI wait stall failed'
assert_contains "$out" 'ci-undeclared run-step-no-ci-progress' \
  'an undeclared CI wait also measures PR check completions'
fm_write_meta "$home/state/plain.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-plain' \
  "worktree=$home/projects/task" 'spawn_gen=one'
printf 'working [at=11000]: building\n' > "$home/state/plain.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" plain)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" plain idle --gen "$gen" \
  --source claude-hook --event stop
out=$(tick 11000) || fail 'plain idle baseline failed'
assert_equals '' "$out" 'a new idle observation gets its configured grace'
out=$(tick 11301) || fail 'plain idle threshold failed'
assert_contains "$out" 'plain idle-without-terminal-status' \
  'idle crew without a terminal status wakes after the bound'
out=$(tick 11361) || fail 'plain idle repeat failed'
assert_equals '' "$out" 'idle alert stays one-shot across ledger reads'
printf 'paused [at=8000]: CI monitor running; resume on final CI result\n' \
  > "$home/state/ci-ship.status"
printf 'running\n' > "$home/run-step"
rm -f "$home/state/crew-ledger.json" "$home/state/plain.meta" "$home/state/plain.status" \
  "$home/state/ci-progress.meta" "$home/state/ci-progress.status"
rm -f "$home/state/mr-skipped.meta" "$home/state/mr-skipped.status"
rm -f "$home/state/mr-running.meta" "$home/state/mr-running.status"
rm -f "$home/state/mr-rearm.meta" "$home/state/mr-rearm.status" \
  "$home/state/mr-pending.meta" "$home/state/mr-pending.status"
rm -f "$home/state/ci-undeclared.meta" "$home/state/ci-undeclared.status"
PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_CREW_STATE_BIN="$home/fakebin/crew-state" FM_CREW_LEDGER_NOW=10000 \
  FM_CREW_LEDGER_WAIT_SECS=900 FM_CREW_LEDGER_CHECK_SECS=1 \
  FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 \
  "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
watcher_pid=$!
for ((i=0; i<100; i++)); do
  kill -0 "$watcher_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$watcher_pid" 2>/dev/null; then
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  fail 'watcher did not surface the crew-ledger check'
fi
wait "$watcher_pid" || fail "watcher exited unsuccessfully: $(cat "$home/watch.err")"
assert_contains "$(cat "$home/watch.out")" 'check: crew-ledger ci-ship declared-wait-no-run-progress' \
  'watcher did not print the actionable reason'
assert_contains "$(cat "$home/state/.wake-queue")" 'crew-ledger ci-ship declared-wait-no-run-progress' \
  'watcher did not queue the durable wake'

# A committed ship can leave the pane idle before it starts no-mistakes.
# The working event is nonterminal and there is no attributed run-step.
rm -f "$home/state/crew-ledger.json" "$home/state/ci-ship.meta" "$home/state/ci-ship.status"
committed_worktree="$home/projects/committed-task"
mkdir -p "$committed_worktree"
git -C "$committed_worktree" init -q || fail 'could not initialize committed fixture'
printf 'implementation\n' > "$committed_worktree/change.txt"
git -C "$committed_worktree" add change.txt || fail 'could not stage committed fixture'
git -C "$committed_worktree" -c user.name=Test -c user.email=test@example.invalid \
  commit -qm 'Finish implementation' || fail 'could not commit fixture'
[ -n "$(git -C "$committed_worktree" rev-parse HEAD)" ] || fail 'fixture has no commit'
[ ! -e "$committed_worktree/.no-mistakes" ] || fail 'fixture unexpectedly has a validation run'
fm_write_meta "$home/state/committed-idle.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-committed-idle' \
  "worktree=$committed_worktree" 'spawn_gen=one'
printf 'working [at=30000]: implementation committed\n' > "$home/state/committed-idle.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" committed-idle)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" committed-idle idle --gen "$gen" \
  --source claude-hook --event stop
out=$(tick 30000) || fail 'committed idle baseline failed'
assert_equals '' "$out" 'a newly idle committed ship gets the configured grace'
out=$(tick 30301) || fail 'committed idle threshold failed'
assert_contains "$out" 'committed-idle idle-without-terminal-status' \
  'a committed idle ship without validation or terminal status wakes firstmate'
assert_contains "$out" 'no attributed validation run; inspect commit and worker status' \
  'the wake identifies the missing validation run'
jq -e '.crew[] | select(.id == "committed-idle") |
  .harness.state == "idle" and .last_status.state == "working" and
  .run_step.state == null and .alert.condition == "idle-without-terminal-status" and
  .checked_at == 30301' "$home/state/crew-ledger.json" >/dev/null \
  || fail 'committed idle ledger evidence is incomplete'
out=$(tick 30361) || fail 'committed idle repeat failed'
assert_equals '' "$out" 'unchanged committed idle evidence wakes only once'

# A slow tick stops at its budget, keeps unread rows, and reads them first next time.
cat > "$home/fakebin/slow-crew-state" <<SH
#!/usr/bin/env bash
sleep 3
exec "$home/fakebin/crew-state" "\$@"
SH
chmod +x "$home/fakebin/slow-crew-state"
fm_write_meta "$home/state/budget-new.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-budget-new' \
  "worktree=$home/projects/task" 'spawn_gen=one'
slow_tick() {
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/fakebin/slow-crew-state" FM_CREW_LEDGER_NOW="$1" \
    FM_CREW_LEDGER_BUDGET_SECS=2 FM_CREW_LEDGER_WAIT_SECS=900 FM_CREW_LEDGER_IDLE_SECS=300 \
    "$ROOT/bin/fm-crew-ledger.sh" tick
}
jq '(.crew[] | select(.id == "committed-idle")) |= del(.project)' \
  "$home/state/crew-ledger.json" > "$home/legacy-ledger.json"
mv "$home/legacy-ledger.json" "$home/state/crew-ledger.json"
slow_tick 30400 >/dev/null || fail 'first budgeted tick failed'
jq -e 'all(.crew[]; has("project"))' "$home/state/crew-ledger.json" >/dev/null \
  || fail 'budgeted tick kept a row without a project field'
jq -e '[.crew[] | {id,checked_at}] ==
  [{id:"budget-new",checked_at:30400},{id:"committed-idle",checked_at:30361}]' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'budgeted tick did not keep the unread row'
slow_tick 30460 >/dev/null || fail 'second budgeted tick failed'
jq -e '[.crew[] | {id,checked_at}] ==
  [{id:"budget-new",checked_at:30400},{id:"committed-idle",checked_at:30460}]' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'budgeted tick did not read the oldest row first'
# A crew-state verdict is carried over a failed read only within the bound.
: > "$home/crew-state-fail"
tick 30500 >/dev/null 2>&1 || fail 'failed crew-state tick failed'
jq -e '.crew[] | select(.id == "committed-idle") | .current_state.observed_at == 30460' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'recent crew-state verdict was not carried'
out=$(tick 31400 2>/dev/null) || fail 'stale crew-state tick failed'
assert_contains "$out" 'committed-idle crew-state-unverified' \
  'a crew-state verdict unreadable past the bound wakes as unverified'
assert_contains "$out" 'crew-state unreadable since 30460' \
  'the unverified wake names the last successful crew-state read'
jq -e '.crew[] | select(.id == "committed-idle") |
  .current_state.state == "unknown" and .current_state.observed_at == 30460 and .checked_at == 31400' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'stale crew-state verdict was reported as fresh'
out=$(tick 31460 2>/dev/null) || fail 'repeated stale crew-state tick failed'
assert_equals '' "$out" 'an unchanged crew-state failure wakes only once'
rm -f "$home/crew-state-fail"
out=$(tick 31500) || fail 'crew-state recovery tick failed'
assert_contains "$out" 'committed-idle idle-without-terminal-status' \
  'a recovered crew-state verdict reports the real condition once'
jq -e '.crew[] | select(.id == "committed-idle") | .current_state.observed_at == 31500' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'recovered crew-state read was not recorded'
out=$(tick 31560) || fail 'recovered crew-state repeat tick failed'
assert_equals '' "$out" 'a recovered crew-state condition does not repeat'
# A crew whose crew-state was never read keeps the ordinary idle bound.
fm_write_meta "$home/state/never-read.meta" \
  'kind=ship' 'harness=claude' 'backend=tmux' 'window=firstmate:fm-never-read' \
  "worktree=$home/projects/task" 'spawn_gen=one'
printf 'working [at=32000]: implementation committed\n' > "$home/state/never-read.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" never-read)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" never-read idle --gen "$gen" \
  --source claude-hook --event stop
out=$(tick 32000 2>/dev/null) || fail 'never-read baseline failed'
assert_not_contains "$out" 'never-read' 'a never-read crew gets the idle grace'
out=$(tick 32301 2>/dev/null) || fail 'never-read idle threshold failed'
assert_contains "$out" 'never-read idle-without-terminal-status' \
  'a crew with no successful crew-state read wakes after the idle bound'
jq -e '.crew[] | select(.id == "never-read") | .current_state.observed_at == null' \
  "$home/state/crew-ledger.json" >/dev/null || fail 'never-read crew recorded an observation'
out=$(tick 32361 2>/dev/null) || fail 'never-read repeat failed'
assert_not_contains "$out" 'never-read' 'an unchanged never-read crew wakes only once'
pass 'crew ledger flags the observed paused and idle CI stall once per unchanged episode'
