#!/usr/bin/env bash
# Record-driven worker resume ticks (bin/fm-watch.sh declared_wait_expiry_tick
# and delivery_handoff_tick), driven through the watcher's real tick and queue
# interfaces and through the actual watcher process.
#
# Both stalls were reproduced from a live 27-worker home: a worker that
# declared `paused: ... until <t>` sat idle for hours after <t>, and a
# no-mistakes worker that declared its implementation `done:` sat at the
# delivery handoff until a supervisor happened to notice. Neither needs pane
# evidence, so neither may depend on the pane-staleness scan being reached.
# Pinned here:
#   1. An expired declared wait rings the WORKER, once per declaration, and
#      wakes nobody; firstmate is told once only when the same line still holds
#      the lane a grace period later.
#   2. A worker that resumed, re-declared, or is busy is never escalated, and a
#      secondmate or remote endpoint is never rung.
#   3. A PR/MR-mode ship whose done names no PR/MR is steered to finish its
#      delivery path once per done line, only when the authoritative current
#      state is exactly that refusal, and firstmate is told once if it stalls.
#   4. The real watcher rings before any wake, and its pane-staleness path does
#      not raise the same expiry a second time.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-crew-resume)

# A fixed clock for the tick-level cases: the declared time, and offsets from it.
UNTIL=1800000000
REFUSED_NM='state: blocked · source: status-log · done declared without a PR/MR URL; complete the no-mistakes delivery path'
REFUSED_DIRECT='state: blocked · source: status-log · done declared without a PR/MR URL; complete the direct-PR delivery path'

# make_resume_case <name>: a hermetic home with the shared fake tmux and
# crew-state, plus a send stub that records `<task> TAB <text>` per steer and
# fails while <dir>/send-fail exists.
make_resume_case() {
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/config"
  cat > "$dir/fakebin/send" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FM_FAKE_SEND_DIR/send-fail" ] || exit 1
printf '%s\t%s\n' "$1" "$2" >> "$FM_FAKE_SEND_DIR/send.log"
SH
  chmod +x "$dir/fakebin/send"
  printf '%s\n' "$dir"
}

add_worker() {  # <dir> <task> [meta key=val...]
  local dir=$1 task=$2
  shift 2
  fm_write_meta "$dir/state/$task.meta" "window=test:fm-$task" 'backend=tmux' 'harness=claude' "$@"
}

# tick <dir> <function> <now> [env assignments...]: run one tick of the real
# watcher function in its own shell and print the reason it queued, if any.
tick() {
  local dir=$1 fn=$2 now=$3
  shift 3
  # shellcheck disable=SC2016 # the inner shell expands its own arguments
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_WATCH_SEND_BIN="$dir/fakebin/send" FM_FAKE_SEND_DIR="$dir" \
    FM_FAKE_CREW_STATE_LOG="$dir/crew-state.log" "$@" \
    bash -c '. "$1"; "$2" "$3" || exit 9; printf "%s" "${WAIT_EXPIRY_REMINDER:-}${HANDOFF_REMINDER:-}"' \
    _ "$WATCH" "$fn" "$now"
}

sends() {  # <dir> [task] -> number of recorded steers
  local dir=$1 task=${2:-}
  [ -f "$dir/send.log" ] || { printf 0; return; }
  if [ -n "$task" ]; then
    awk -F '\t' -v t="$task" '$1 == t { n++ } END { print n + 0 }' "$dir/send.log"
  else
    wc -l < "$dir/send.log" | tr -d ' '
  fi
}

wakes() {  # <dir> -> number of queued wakes
  if [ -f "$1/state/.wake-queue" ]; then wc -l < "$1/state/.wake-queue" | tr -d ' '; else printf 0; fi
}

busy_event() {  # <dir> <task> <busy|idle>
  local dir=$1 task=$2 state=$3 gen event=user-prompt-submit
  [ "$state" = busy ] || event=stop
  gen=$(cat "$dir/state/$task.busy-gen" 2>/dev/null) || gen=
  [ -n "$gen" ] || gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/state" "$task")
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" "$task" "$state" --gen "$gen" \
    --source claude-hook --event "$event"
}

# --- declared-wait expiry ----------------------------------------------------

test_wait_before_its_time_is_quiet() {
  local dir out
  dir=$(make_resume_case wait-early)
  add_worker "$dir" early 'kind=ship'
  printf 'paused [at=%s]: rate limit until %s\n' "$((UNTIL - 600))" "$(iso_utc_at "$UNTIL")" \
    > "$dir/state/early.status"
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL - 1))") || fail "tick failed before the declared time"
  assert_equals '' "$out" 'no reason is queued before the declared time'
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 119))") || fail "tick failed inside the slack"
  assert_equals 0 "$(sends "$dir")" 'a worker is not rung inside the slack after its declared time'
  [ ! -e "$dir/state/early.wait-expiry" ] || fail "a marker was written before the wait expired"
  printf 'paused [at=%s]: waiting on the vendor, no time known\n' "$((UNTIL - 600))" > "$dir/state/early.status"
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 99999))") || fail "tick failed on an undated pause"
  assert_equals 0 "$(sends "$dir")" 'a pause that names no time is never rung'
  pass "a declared wait is left alone before its time, inside the slack, and when it names no time"
}

test_expired_wait_rings_worker_then_tells_firstmate_once() {
  local dir out
  dir=$(make_resume_case wait-expired)
  add_worker "$dir" late 'kind=ship'
  printf 'working [at=%s]: started\npaused [at=%s]: background test run until %s\n' \
    "$((UNTIL - 900))" "$((UNTIL - 600))" "$(iso_utc_at "$UNTIL")" > "$dir/state/late.status"
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 120))") || fail "expiry tick failed"
  assert_equals '' "$out" 'ringing the worker wakes nobody'
  assert_equals 1 "$(sends "$dir" late)" 'the worker is rung when its declared time has passed'
  assert_contains "$(cat "$dir/send.log")" 'until time in your paused: line passed 120s ago' \
    'the steer names the expired wait'
  assert_equals 0 "$(wakes "$dir")" 'no wake is queued while the worker has its grace'
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 419))") || fail "tick failed inside the grace"
  assert_equals 1 "$(sends "$dir")" 'the same declaration is not rung twice'
  assert_equals 0 "$(wakes "$dir")" 'firstmate is not woken inside the grace'
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 420))") || fail "tick failed at the grace"
  assert_equals 'check: declared wait expired: late until passed 420s ago; the worker was rung 300s ago and its status is unchanged - inspect it, then resume it or release the wait' \
    "$out" 'an unchanged wait reaches firstmate once the grace has passed'
  assert_equals 1 "$(wakes "$dir")" 'exactly one wake is queued'
  grep -F "$(printf '\tcheck\twait-expiry:late\t')" "$dir/state/.wake-queue" >/dev/null \
    || fail "the queued wake is not keyed to the task"
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 9000))") || fail "tick failed after escalation"
  assert_equals '' "$out" 'an escalated declaration is not raised again'
  assert_equals 1 "$(sends "$dir")" 'an escalated declaration is not rung again'
  assert_equals 1 "$(wakes "$dir")" 'an escalated declaration queues nothing more'
  pass "an expired declared wait rings the worker first and tells firstmate once if it stays unchanged"
}

test_resumed_or_redeclared_wait_is_not_escalated() {
  local dir out
  dir=$(make_resume_case wait-resumed)
  add_worker "$dir" back 'kind=ship'
  printf 'paused [at=%s]: rate limit until %s\n' "$((UNTIL - 600))" "$(iso_utc_at "$UNTIL")" \
    > "$dir/state/back.status"
  tick "$dir" declared_wait_expiry_tick "$((UNTIL + 120))" >/dev/null || fail "expiry tick failed"
  assert_equals 1 "$(sends "$dir")" 'the worker was rung'
  printf 'resolved [at=%s]: rate limit reset; restarting\nworking [at=%s]: validating\n' \
    "$((UNTIL + 130))" "$((UNTIL + 131))" >> "$dir/state/back.status"
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 9000))") || fail "tick failed after the worker resumed"
  assert_equals '' "$out" 'a worker that resumed is never reported'
  assert_equals 0 "$(wakes "$dir")" 'a resumed worker queues no wake'
  [ ! -e "$dir/state/back.wait-expiry" ] || fail "the marker outlived the wait it recorded"

  # A new declaration is a new episode: quiet until ITS time, then rung again.
  printf 'paused [at=%s]: second rate limit until %s\n' "$((UNTIL + 9100))" \
    "$(iso_utc_at "$((UNTIL + 10000))")" >> "$dir/state/back.status"
  tick "$dir" declared_wait_expiry_tick "$((UNTIL + 9500))" >/dev/null || fail "tick failed on the new declaration"
  assert_equals 1 "$(sends "$dir")" 'a new declaration is not rung before its own time'
  tick "$dir" declared_wait_expiry_tick "$((UNTIL + 10120))" >/dev/null || fail "tick failed at the new time"
  assert_equals 2 "$(sends "$dir")" 'a new declaration is rung at its own time'

  # An answer to an unrelated key does not end the wait, so it is one episode.
  printf 'resolved [key=other] [at=%s]: answered: unrelated\n' "$((UNTIL + 10130))" >> "$dir/state/back.status"
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 10200))") || fail "tick failed after an unrelated answer"
  assert_equals 2 "$(sends "$dir")" 'an unrelated answer does not ring the same declaration again'
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 10420))") || fail "tick failed at the second grace"
  assert_contains "$out" 'check: declared wait expired: back ' 'the standing declaration still reaches firstmate at its grace'
  pass "a resumed wait is dropped, a new declaration starts over, and an unrelated answer does neither"
}

test_busy_secondmate_and_remote_workers_are_not_rung() {
  local dir out
  dir=$(make_resume_case wait-exempt)
  add_worker "$dir" busy 'kind=ship'
  add_worker "$dir" mate 'kind=secondmate'
  add_worker "$dir" far 'kind=ship' 'remote_host=example.invalid'
  for task in busy mate far; do
    printf 'paused [at=%s]: waiting until %s\n' "$((UNTIL - 600))" "$(iso_utc_at "$UNTIL")" \
      > "$dir/state/$task.status"
  done
  busy_event "$dir" busy busy
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 500))") || fail "tick failed for exempt workers"
  assert_equals 0 "$(sends "$dir")" 'a busy worker, a secondmate and a remote endpoint are not rung'
  busy_event "$dir" busy idle
  tick "$dir" declared_wait_expiry_tick "$((UNTIL + 520))" >/dev/null || fail "tick failed once the worker was idle"
  assert_equals 1 "$(sends "$dir" busy)" 'the worker is rung once its endpoint stops reading busy'
  assert_equals 1 "$(sends "$dir")" 'only the idle local worker was rung'
  # A worker that went busy after the ring is acting on it, so it is not judged.
  busy_event "$dir" busy busy
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 9000))") || fail "tick failed for a busy rung worker"
  assert_equals '' "$out" 'a rung worker that is busy is not reported to firstmate'
  busy_event "$dir" busy idle
  out=$(tick "$dir" declared_wait_expiry_tick "$((UNTIL + 9001))") || fail "tick failed for an idle rung worker"
  assert_contains "$out" 'check: declared wait expired: busy ' 'the report follows once it is idle and unchanged'
  pass "busy endpoints, secondmates and remote endpoints are exempt from the ring"
}

test_failed_steer_is_retried_and_bad_settings_refuse() {
  local dir out rc=0
  dir=$(make_resume_case wait-retry)
  add_worker "$dir" flaky 'kind=ship'
  printf 'paused [at=%s]: waiting until %s\n' "$((UNTIL - 600))" "$(iso_utc_at "$UNTIL")" \
    > "$dir/state/flaky.status"
  : > "$dir/send-fail"
  tick "$dir" declared_wait_expiry_tick "$((UNTIL + 200))" >/dev/null || fail "a failed steer failed the tick"
  tick "$dir" declared_wait_expiry_tick "$((UNTIL + 9000))" >/dev/null || fail "a second failed steer failed the tick"
  assert_equals 0 "$(wakes "$dir")" 'a steer that was never recorded is not reported as an unanswered ring'
  assert_equals 1 "$(grep -c 'steer to flaky was not recorded' "$dir/state/.watch-triage.log")" \
    'a steer that keeps failing is logged once, not on every retry'
  rm -f "$dir/send-fail"
  tick "$dir" declared_wait_expiry_tick "$((UNTIL + 9059))" >/dev/null || fail "tick failed inside the retry interval"
  assert_equals 0 "$(sends "$dir" flaky)" 'a failed steer is not retried inside the retry interval'
  tick "$dir" declared_wait_expiry_tick "$((UNTIL + 9060))" >/dev/null || fail "retry tick failed"
  assert_equals 1 "$(sends "$dir" flaky)" 'a steer that failed is retried once the retry interval has passed'
  tick "$dir" declared_wait_expiry_tick "$((UNTIL + 300))" FM_WAIT_EXPIRY_GRACE_SECS=soon >/dev/null 2>&1 || rc=$?
  assert_equals 9 "$rc" 'a malformed grace setting refuses instead of guessing'
  pass "an unrecorded steer is retried, and malformed settings fail the tick"
}

# --- delivery handoff ----------------------------------------------------------

test_handoff_done_is_steered_once() {
  local dir out
  dir=$(make_resume_case handoff-steer)
  add_worker "$dir" ship 'kind=ship' 'mode=no-mistakes'
  printf 'working [at=1000]: implementing\ndone [at=2000]: committed abc1234; 12 tests pass\n' \
    > "$dir/state/ship.status"
  out=$(tick "$dir" delivery_handoff_tick 2119 FM_FAKE_CREW_STATE="$REFUSED_NM") || fail "handoff tick failed inside the settle"
  assert_equals 0 "$(sends "$dir")" 'a fresh done is left for its supervisor inside the settle'
  [ ! -s "$dir/crew-state.log" ] || fail "the current state was read inside the settle"
  out=$(tick "$dir" delivery_handoff_tick 2120 FM_FAKE_CREW_STATE="$REFUSED_NM") || fail "handoff tick failed"
  assert_equals '' "$out" 'steering the worker wakes nobody'
  assert_equals 1 "$(sends "$dir" ship)" 'a done naming no PR/MR is steered to finish delivery'
  assert_contains "$(cat "$dir/send.log")" 'Invoke your no-mistakes skill now' 'a no-mistakes ship is told to validate'
  assert_contains "$(cat "$dir/send.log")" 'never --yes' 'the steer keeps the fleet-wide gate rule'
  out=$(tick "$dir" delivery_handoff_tick 2500 FM_FAKE_CREW_STATE="$REFUSED_NM") || fail "handoff tick failed inside the grace"
  assert_equals 1 "$(sends "$dir")" 'the same done line is steered once'
  assert_equals 0 "$(wakes "$dir")" 'firstmate is not woken inside the grace'
  pass "a no-mistakes ship idle at its delivery handoff is steered to validate, once"
}

test_handoff_direct_pr_names_its_own_path() {
  local dir
  dir=$(make_resume_case handoff-direct)
  add_worker "$dir" direct 'kind=ship' 'mode=direct-PR'
  printf 'done [at=2000]: committed the fix\n' > "$dir/state/direct.status"
  tick "$dir" delivery_handoff_tick 3000 FM_FAKE_CREW_STATE="$REFUSED_DIRECT" >/dev/null || fail "handoff tick failed"
  assert_contains "$(cat "$dir/send.log")" 'the direct-PR delivery is not finished' 'a direct-PR ship is told to open its PR'
  assert_not_contains "$(cat "$dir/send.log")" 'no-mistakes' 'a direct-PR ship is not sent to a pipeline it does not use'
  pass "a direct-PR ship is steered to push and open its PR"
}

test_handoff_is_not_steered_without_the_refusal() {
  local dir task
  dir=$(make_resume_case handoff-skip)
  add_worker "$dir" finished 'kind=ship' 'mode=no-mistakes'
  add_worker "$dir" running 'kind=ship' 'mode=no-mistakes'
  add_worker "$dir" unread 'kind=ship' 'mode=no-mistakes'
  add_worker "$dir" busy 'kind=ship' 'mode=no-mistakes'
  add_worker "$dir" local 'kind=ship' 'mode=local-only'
  add_worker "$dir" scout 'kind=scout'
  add_worker "$dir" quoted 'kind=ship' 'mode=no-mistakes'
  for task in finished running unread busy local scout quoted; do
    printf 'done [at=2000]: committed the fix\n' > "$dir/state/$task.status"
  done
  mkdir -p "$dir/state/unread.inbox"
  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:00Z\n--\nrun validation\n' > "$dir/state/unread.inbox/001.msg"
  busy_event "$dir" busy busy
  tick "$dir" delivery_handoff_tick 9000 \
    FM_FAKE_CREW_STATE="$REFUSED_NM" \
    FM_FAKE_CREW_STATE_finished='state: done · source: status-log · PR https://example.test/o/r/pull/7 checks green' \
    FM_FAKE_CREW_STATE_running='state: working · source: run-step · validating (running) · run: 01RUN' \
    FM_FAKE_CREW_STATE_quoted='state: blocked · source: status-log · worker said: done declared without a PR/MR URL; complete the no-mistakes delivery path' \
    >/dev/null || fail "handoff tick failed"
  assert_equals 0 "$(sends "$dir")" \
    "only the exact refusal on an idle lane with no unread instruction is steered; steered: $(cut -f1 "$dir/send.log" 2>/dev/null | tr '\n' ' ')"
  # The cheap file evidence is read first: lanes it rules out cost no state read.
  assert_no_regex '^(unread|busy|local|scout)$' "$dir/crew-state.log" \
    'a lane the inbox, busy record, kind or delivery mode rules out spent a current-state read'
  # A lane that could not be judged yet is retried: once the busy worker is
  # idle it is steered, while a lane a state read ruled out stays closed.
  busy_event "$dir" busy idle
  tick "$dir" delivery_handoff_tick 9060 FM_FAKE_CREW_STATE="$REFUSED_NM" >/dev/null || fail "handoff tick failed on the retry"
  assert_equals 1 "$(sends "$dir" busy)" 'a worker that was busy at the handoff is steered once it is idle'
  assert_equals 1 "$(sends "$dir")" 'a lane whose state read was not the refusal was steered on a later tick'
  pass "a finished, validating, already-instructed, busy, local-only or scout lane is never steered"
}

test_handoff_captain_held_task_is_not_steered() {
  local dir
  command -v tasks-axi >/dev/null 2>&1 \
    || fail "tasks-axi is required (captain-held delivery handoff)"
  dir=$(make_resume_case handoff-held)
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml" || fail "could not write the backlog config"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  (cd "$dir" && tasks-axi add held 'delivered work' --file data/backlog.md) >/dev/null 2>&1 \
    || fail "could not file the held task"
  run_hold "$dir" hold held --reason 'awaiting the captain on the approach' \
    || fail "could not record the captain hold"
  add_worker "$dir" held 'kind=ship' 'mode=no-mistakes'
  printf 'done [at=2000]: committed the fix\n' > "$dir/state/held.status"
  tick "$dir" delivery_handoff_tick 3000 FM_FAKE_CREW_STATE="$REFUSED_NM" >/dev/null || fail "handoff tick failed"
  tick "$dir" delivery_handoff_tick 9000 FM_FAKE_CREW_STATE="$REFUSED_NM" >/dev/null || fail "handoff tick failed later"
  assert_equals 0 "$(sends "$dir")" 'a task the captain holds is not steered past its hold'
  assert_equals 0 "$(wakes "$dir")" 'a held task queues no handoff wake'
  assert_equals 1 "$(wc -l < "$dir/crew-state.log" | tr -d ' ')" 'a held done line is closed after one state read'
  pass "a task held for the captain is left at its handoff"
}

test_handoff_stalled_reaches_firstmate_once() {
  local dir out
  dir=$(make_resume_case handoff-stalled)
  add_worker "$dir" stuck 'kind=ship' 'mode=no-mistakes'
  printf 'done [at=2000]: committed the fix\n' > "$dir/state/stuck.status"
  tick "$dir" delivery_handoff_tick 3000 FM_FAKE_CREW_STATE="$REFUSED_NM" >/dev/null || fail "handoff tick failed"
  assert_equals 1 "$(sends "$dir")" 'the worker was steered'
  out=$(tick "$dir" delivery_handoff_tick 3600 FM_FAKE_CREW_STATE="$REFUSED_NM") || fail "handoff tick failed at the grace"
  assert_equals 'check: delivery handoff stalled: stuck declared done with no PR/MR, was steered to finish its no-mistakes delivery, and still reads refused after the 600s grace - inspect the worker' \
    "$out" 'a steered lane that still holds the refusal reaches firstmate'
  out=$(tick "$dir" delivery_handoff_tick 99999 FM_FAKE_CREW_STATE="$REFUSED_NM") || fail "handoff tick failed after escalation"
  assert_equals '' "$out" 'a stalled handoff is reported once'
  assert_equals 1 "$(sends "$dir")" 'a stalled handoff is never steered a second time'
  assert_equals 1 "$(wakes "$dir")" 'exactly one wake is queued'
  pass "a handoff that stays refused after its steer reaches firstmate once"
}

test_handoff_that_moved_on_is_closed() {
  local dir out reads
  dir=$(make_resume_case handoff-moved)
  add_worker "$dir" moved 'kind=ship' 'mode=no-mistakes'
  printf 'done [at=2000]: committed the fix\n' > "$dir/state/moved.status"
  tick "$dir" delivery_handoff_tick 3000 FM_FAKE_CREW_STATE="$REFUSED_NM" >/dev/null || fail "handoff tick failed"
  out=$(tick "$dir" delivery_handoff_tick 3600 \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running) · run: 01RUN') \
    || fail "handoff tick failed once the run started"
  assert_equals '' "$out" 'a lane whose run started is not reported'
  reads=$(wc -l < "$dir/crew-state.log" | tr -d ' ')
  # The same done line is closed: neither steered again nor read again.
  out=$(tick "$dir" delivery_handoff_tick 99999 FM_FAKE_CREW_STATE="$REFUSED_NM") || fail "handoff tick failed later"
  assert_equals 1 "$(sends "$dir")" 'a done line is steered at most once, whatever the lane does next'
  assert_equals 0 "$(wakes "$dir")" 'a lane that moved on queues no wake'
  assert_equals "$reads" "$(wc -l < "$dir/crew-state.log" | tr -d ' ')" 'a closed done line costs no further state reads'
  # A new done line is a new handoff.
  printf 'working [at=100000]: reworking\ndone [at=100100]: committed the rework\n' >> "$dir/state/moved.status"
  tick "$dir" delivery_handoff_tick 100300 FM_FAKE_CREW_STATE="$REFUSED_NM" >/dev/null || fail "handoff tick failed on the new done"
  assert_equals 2 "$(sends "$dir")" 'a later done line that is refused again is its own handoff'
  pass "a done line is one episode: steered once, closed when the lane moves on"
}

test_handoff_unreadable_state_is_retried_on_the_recheck_interval() {
  local dir now out
  dir=$(make_resume_case handoff-unreadable)
  add_worker "$dir" slow 'kind=ship' 'mode=no-mistakes'
  printf 'done [at=2000]: committed the fix\n' > "$dir/state/slow.status"
  for now in 3000 3015 3030 3059; do
    tick "$dir" delivery_handoff_tick "$now" FM_FAKE_CREW_STATE='no verdict' >/dev/null || fail "handoff tick failed"
  done
  assert_equals 0 "$(sends "$dir")" 'a lane whose state cannot be read is not steered'
  assert_equals 1 "$(wc -l < "$dir/crew-state.log" | tr -d ' ')" 'an unreadable state costs one read per recheck interval'
  tick "$dir" delivery_handoff_tick 3060 FM_FAKE_CREW_STATE="$REFUSED_NM" >/dev/null || fail "handoff tick failed"
  assert_equals 1 "$(sends "$dir")" 'the lane is steered at the next recheck once the refusal is read'
  # The same bound holds at the grace: no verdict is not evidence of a stall.
  for now in 3660 3675 3719; do
    out=$(tick "$dir" delivery_handoff_tick "$now" FM_FAKE_CREW_STATE='no verdict') || fail "handoff tick failed at the grace"
    assert_equals '' "$out" 'an unreadable state at the grace reports nothing'
  done
  assert_equals 3 "$(wc -l < "$dir/crew-state.log" | tr -d ' ')" 'an unreadable state at the grace is retried on the recheck interval'
  out=$(tick "$dir" delivery_handoff_tick 3720 FM_FAKE_CREW_STATE="$REFUSED_NM") || fail "handoff tick failed"
  assert_contains "$out" 'check: delivery handoff stalled: slow ' 'the stall is reported once the refusal is read again'
  pass "a lane whose state cannot be read is retried on the recheck interval, before the steer and at the grace"
}

# --- the actual watcher ----------------------------------------------------------

# One live, idle grok ship whose pane is stable and whose only status line is a
# declared wait naming <until-epoch>.
resume_watch_case() {  # <name> <task> <until-epoch> -> dir
  local dir state window key
  dir=$(make_case "$1"); state="$dir/state"; window="test:fm-$2"
  mkdir -p "$dir/config"
  touch "$state/home-summary.json"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/$2.meta"
  printf 'paused: rate limit until %s\n' "$(iso_utc_at "$3")" > "$state/$2.status"
  printf '%s' "$(seen_sig "$state/$2.status")" > "$state/.seen-${2}_status"
  key=$(watch_window_key "$window")
  printf 'parked at the prompt' > "$dir/pane.txt"
  printf '%s' "$(hash_text 'parked at the prompt')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

# Launch the actual watcher against that home. The pid lands in
# RESUME_WATCH_PID: a command substitution would background the watcher inside
# a subshell, leaving the caller unable to wait on or reap its own watcher.
RESUME_WATCH_PID=
resume_watch() {  # <dir> <task> [env assignments...]
  local dir=$1 window="test:fm-$2"
  shift 2
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · parked' \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$@" "$WATCH" >> "$dir/watch.out" 2>> "$dir/watch.err" &
  RESUME_WATCH_PID=$!
}

# A declared time that passed five minutes ago: the watcher rings the worker
# through the real fm-send before any wake, does not raise the same expiry from
# the pane-staleness path, and reports it to firstmate once the grace has passed.
test_watcher_rings_then_reports_without_a_stale_alarm() {
  local dir state out pid i=0
  dir=$(resume_watch_case watcher-wait-expired waiter "$(( $(date +%s) - 300 ))")
  state="$dir/state"; out="$dir/watch.out"
  resume_watch "$dir" waiter FM_WAIT_EXPIRY_GRACE_SECS=4
  pid=$RESUME_WATCH_PID
  while [ "$i" -lt 100 ] && [ ! -e "$state/waiter.wait-expiry" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1; i=$((i + 1))
  done
  [ -e "$state/waiter.wait-expiry" ] || { reap "$pid"; fail "the watcher did not ring a worker whose declared time had passed: $(cat "$out" "$dir/watch.err")"; }
  grep -l 'until time in your paused: line passed' "$state/waiter.inbox"/*.msg >/dev/null 2>&1 \
    || { reap "$pid"; fail "the ring left no durable instruction in the worker's inbox"; }
  wait_for_exit "$pid" 200 || { reap "$pid"; fail "the watcher never reported the unchanged wait: $(cat "$out" "$dir/watch.err")"; }
  grep -F 'check: declared wait expired: waiter ' "$out" >/dev/null \
    || fail "the watcher did not print the expiry report: $(cat "$out")"
  assert_no_regex '^stale: ' "$out" 'the pane-staleness path raised the same expiry the tick already owned'
  assert_equals 1 "$(find "$state/waiter.inbox" -name '*.msg' | wc -l | tr -d ' ')" 'the worker was rung exactly once'
  assert_equals 1 "$(awk -F '\t' '$3 == "check" { n++ } END { print n + 0 }' "$state/.wake-queue")" \
    'exactly one report is queued for firstmate'
  pass "the actual watcher rings the worker first, then reports once, with no duplicate stale alarm"
}

# The slack between the declared time and the ring belongs to the same owner:
# the pane-staleness path must not raise the expiry to firstmate before the
# worker has had its chance, and must take it back when no ring can be recorded.
test_watcher_holds_the_stale_recheck_through_the_slack() {
  local dir state out pid cycles=0
  dir=$(resume_watch_case watcher-wait-slack slack "$(( $(date +%s) - 20 ))")
  state="$dir/state"; out="$dir/watch.out"
  resume_watch "$dir" slack
  pid=$RESUME_WATCH_PID
  while [ "$cycles" -lt 4 ]; do
    wait_poll_cycle "$state" "$pid" 300 \
      || { reap "$pid"; fail "the watcher woke inside the slack after a declared time: $(cat "$out" "$dir/watch.err")"; }
    cycles=$((cycles + 1))
  done
  reap "$pid"
  [ ! -s "$state/.wake-queue" ] || fail "a wake was queued inside the slack: $(cat "$state/.wake-queue")"
  [ ! -e "$state/slack.inbox" ] || fail "the worker was rung inside the slack"
  grep -F 'declared time reached, owned by the expiry tick' "$state/.watch-triage.log" >/dev/null \
    || fail "the pane-staleness path never reached the passed declared time, so the hold was not exercised"

  # With the slack over and no ring recordable, the pane-staleness recheck is
  # the fallback, exactly as before the tick existed.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/fakebin/send-fails"
  chmod +x "$dir/fakebin/send-fails"
  resume_watch "$dir" slack FM_WAIT_EXPIRY_SLACK_SECS=0 FM_WATCH_SEND_BIN="$dir/fakebin/send-fails"
  pid=$RESUME_WATCH_PID
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "an expiry whose ring could not be recorded never reached firstmate"; }
  grep -F 'declared clearing time has passed' "$out" >/dev/null \
    || fail "the fallback was not the pane-staleness recheck of the passed time: $(cat "$out")"
  pass "the pane-staleness recheck waits out the slack, and is the fallback when the ring cannot be recorded"
}

fm_test_run test_wait_before_its_time_is_quiet \
  test_expired_wait_rings_worker_then_tells_firstmate_once \
  test_resumed_or_redeclared_wait_is_not_escalated \
  test_busy_secondmate_and_remote_workers_are_not_rung \
  test_failed_steer_is_retried_and_bad_settings_refuse \
  test_handoff_done_is_steered_once test_handoff_direct_pr_names_its_own_path \
  test_handoff_is_not_steered_without_the_refusal \
  test_handoff_captain_held_task_is_not_steered \
  test_handoff_stalled_reaches_firstmate_once test_handoff_that_moved_on_is_closed \
  test_handoff_unreadable_state_is_retried_on_the_recheck_interval \
  test_watcher_rings_then_reports_without_a_stale_alarm \
  test_watcher_holds_the_stale_recheck_through_the_slack
