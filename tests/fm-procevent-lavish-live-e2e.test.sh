#!/usr/bin/env bash
# tests/fm-procevent-lavish-live-e2e.test.sh - live guard proving a Lavish
# board answer reaches its home after that home's supervision lapsed, against
# the real lavish-axi.
#
# Why this file exists: a board answer submitted hours after the board was
# armed never reached firstmate. The home's agent session was alive, but its
# supervision cycle had ended, so nothing refreshed the process-event owner
# lease and every board listener in the home was stopped as though the home
# were gone. The captain's Send & End then sat on the ended session with nothing
# polling it. tests/fm-procevent.test.sh pins the owner-presence logic in CI
# against a stand-in poll; this guard proves the two lavish-axi facts that
# delivery relies on still hold for the installed tool:
#
#   - a blocking poll that survived the lapse returns the Send & End answer as
#     it lands, with no supervision running at all; and
#   - a poll started after Send & End - a listener relaunched once supervision
#     returns - still collects the ended session's queued final answer, exactly
#     once.
#
# It runs a private Lavish server with its own state directory and port and no
# browser, so it never touches a server anyone is using, and stops it before
# returning. The captain's Send & End reaches that server through the same
# route the browser's Send & End button calls, so nothing here needs a human.
# Standard CI has no lavish-axi, so this reports a capability skip there. Run it
# after a lavish-axi upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_PROCEVENT_LAVISH_LIVE lavish-axi jq curl perl

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=''
SESSION_PID=''
cleanup() {
  fm_test_reap_procevent_homes
  [ -z "$SESSION_PID" ] || kill "$SESSION_PID" 2>/dev/null || true
  [ -z "$LAB" ] || {
    lavish-axi stop >/dev/null 2>&1 || true
    rm -rf "$LAB"
  }
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-lavish-live.XXXXXX") || fail "cannot create the guard lab"
# Lavish records a board under its on-disk spelling, including letter case on a
# case-insensitive volume, so the lab path is taken in that same spelling.
LAB=$(realpath -- "$LAB" 2>/dev/null || { cd -P -- "$LAB" && pwd -P; })
PORT=$(perl -MIO::Socket::INET -e '
  my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1", LocalPort => 0) or exit 1;
  print $s->sockport, "\n";
') || fail "cannot choose a free port for the private Lavish server"
export LAVISH_AXI_STATE_DIR="$LAB/lavish" LAVISH_AXI_PORT="$PORT" LAVISH_AXI_NO_OPEN=1
export FM_PROCEVENT_CLAIM_ROOT="$LAB/claims"
# A short lease and check, so the lapse under test takes seconds, not minutes.
LEASE=2
CHECK=1
LAPSE_BOUND=$((LEASE + 1 + CHECK + 4 + 2))

LIVE_HOME="$LAB/live-session-home"
NONE_HOME="$LAB/no-session-home"
mkdir -p "$LAVISH_AXI_STATE_DIR" "$LIVE_HOME/state" "$NONE_HOME/state" "$LAB/bin"
fm_test_track_procevent_home "$LIVE_HOME" "$FM_PROCEVENT_CLAIM_ROOT"
fm_test_track_procevent_home "$NONE_HOME" "$FM_PROCEVENT_CLAIM_ROOT"

# A live agent session holding the first home, as bin/fm-lock.sh records one: a
# harness-named process whose pid is line 1 of state/.lock.
ln -s "$(command -v bash)" "$LAB/bin/claude"
# shellcheck disable=SC2016 # The session's own shell expands $SECONDS.
"$LAB/bin/claude" -c 'while [ "$SECONDS" -lt 300 ]; do sleep 0.1; done' &
SESSION_PID=$!
printf '%s\n' "$SESSION_PID" > "$LIVE_HOME/state/.lock"
case "$(FM_HOME="$LIVE_HOME" "$ROOT/bin/fm-lock.sh" status)" in
  *"held by live harness pid $SESSION_PID"*) ;;
  *) fail "the fixture session does not read as a live agent session holding its home" ;;
esac

pe() {  # <home> <command...>
  local home=$1
  shift
  FM_PROCEVENT_OWNER_LEASE_SECONDS=$LEASE FM_PROCEVENT_OWNER_CHECK_SECONDS=$CHECK \
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" "$@"
}

open_board() {  # <home>: create and open a board, print "<artifact> <session-key> <base-url>"
  local board url
  board="$1/acceptance.html"
  printf '<!doctype html><title>acceptance</title><h1>Acceptance</h1><p id="q">Accept?</p>\n' > "$board"
  url=$(lavish-axi "$board" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
  case "$url" in
    http://*/session/*) ;;
    *) return 1 ;;
  esac
  printf '%s %s %s\n' "$board" "${url##*/}" "${url%/session/*}"
}

read -r LIVE_BOARD LIVE_KEY LIVE_BASE < <(open_board "$LIVE_HOME") \
  || fail "the private Lavish server did not open the live-session board"
read -r NONE_BOARD NONE_KEY NONE_BASE < <(open_board "$NONE_HOME") \
  || fail "the private Lavish server did not open the control board"

FM_HOME="$LIVE_HOME" "$ROOT/bin/fm-procevent-lavish.sh" arm "$LIVE_BOARD" >/dev/null \
  || fail "cannot arm the live-session board"
FM_HOME="$NONE_HOME" "$ROOT/bin/fm-procevent-lavish.sh" arm "$NONE_BOARD" >/dev/null \
  || fail "cannot arm the control board"
LIVE_ID=$(FM_HOME="$LIVE_HOME" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$LIVE_BOARD")
NONE_ID=$(FM_HOME="$NONE_HOME" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$NONE_BOARD")

# The last supervision cycle either home gets: it launches both listeners.
pe "$LIVE_HOME" reconcile >/dev/null || fail "the live-session home could not launch its listener"
pe "$NONE_HOME" reconcile >/dev/null || fail "the control home could not launch its listener"
runner_pid() {  # <home> <source-id>: wait for the runner's own record of its pid
  local record="$1/state/procevent/$2.runner" _
  for _ in $(seq 1 100); do
    [ -s "$record" ] && { cat "$record"; return 0; }
    sleep 0.1
  done
  return 1
}
LIVE_RUNNER=$(runner_pid "$LIVE_HOME" "$LIVE_ID") || fail "the live-session board listener never launched"
NONE_RUNNER=$(runner_pid "$NONE_HOME" "$NONE_ID") || fail "the control board listener never launched"

store_field() {  # <session-key> <field>
  jq -r --arg k "$1" --arg f "$2" '.sessions[$k][$f] | tostring' "$LAVISH_AXI_STATE_DIR/state.json"
}
result_count() {  # <home> <source-id>
  find "$1/state/procevent-inbox" -maxdepth 1 -name "$2.*.result" 2>/dev/null | grep -c . || true
}
send_and_end() {  # <base-url> <session-key>
  curl -fsS -X POST -H 'content-type: application/json' -H "Origin: $1" \
    --data '{"prompts":[{"uid":"1","prompt":"accept: go to Deploy","selector":"#q","tag":"message","text":"accept: go to Deploy"}],"endSession":true}' \
    "$1/api/$2/prompts" >/dev/null
}

# Supervision lapses in both homes. The control listener is stopped within the
# lease bound, which is the evidence the lapse really happened; the live home
# then gets that bound again before its listener must still be polling.
deadline=$((SECONDS + LAPSE_BOUND))
while kill -0 -"$NONE_RUNNER" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "the control listener outlived its expired lease, so the lapse under test never happened"
  sleep 0.2
done
sleep "$((LEASE + 1 + CHECK + 1))"
kill -0 -"$LIVE_RUNNER" 2>/dev/null \
  || fail "a board listener was stopped while a live agent session still held its home"
pass "a live agent session keeps its board listener polling real lavish-axi through lapsed supervision"

send_and_end "$LIVE_BASE" "$LIVE_KEY" || fail "the captain's Send & End did not reach the live-session board"
send_and_end "$NONE_BASE" "$NONE_KEY" || fail "the captain's Send & End did not reach the control board"

deadline=$((SECONDS + 15))
until [ "$(result_count "$LIVE_HOME" "$LIVE_ID")" -ge 1 ]; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "lavish-axi ${VERSION:-version-unknown}: the surviving poll never returned the Send & End answer"
  sleep 0.2
done
LIVE_RESULT=$(find "$LIVE_HOME/state/procevent-inbox" -maxdepth 1 -name "$LIVE_ID.*.result" | head -1)
if ! grep -q 'accept: go to Deploy' "$LIVE_RESULT" || ! grep -q 'session_ended: true' "$LIVE_RESULT"; then
  fail "lavish-axi ${VERSION:-version-unknown}: the surviving poll returned something other than the session-ending answer: $(head -8 "$LIVE_RESULT")"
fi
[ "$(store_field "$LIVE_KEY" pending_prompts)" = 0 ] \
  || fail "lavish-axi still holds the answer the surviving poll captured"
pass "a Send & End answer after lapsed supervision is captured as it lands, with no reconcile"

# The incident's evidence, reproduced in the control home: the ended session
# holds the answer and nothing captured it.
sleep 1
if [ "$(store_field "$NONE_KEY" status)" != ended ] || [ "$(store_field "$NONE_KEY" pending_prompts)" != 1 ]; then
  fail "lavish-axi ${VERSION:-version-unknown}: an unpolled Send & End did not stay queued on the ended session ($(store_field "$NONE_KEY" status), pending $(store_field "$NONE_KEY" pending_prompts))"
fi
[ "$(result_count "$NONE_HOME" "$NONE_ID")" = 0 ] \
  || fail "the control home captured an answer with no listener running"

# Supervision returns and relaunches the missing listener against the ended session.
pe "$NONE_HOME" reconcile >/dev/null || fail "returning supervision could not relaunch the listener"
deadline=$((SECONDS + 15))
until [ "$(result_count "$NONE_HOME" "$NONE_ID")" -ge 1 ]; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "lavish-axi ${VERSION:-version-unknown}: a poll against the ended session never collected its queued final answer"
  sleep 0.2
done
NONE_RESULT=$(find "$NONE_HOME/state/procevent-inbox" -maxdepth 1 -name "$NONE_ID.*.result" | head -1)
if ! grep -q 'accept: go to Deploy' "$NONE_RESULT" || ! grep -q 'session_ended: true' "$NONE_RESULT"; then
  fail "lavish-axi ${VERSION:-version-unknown}: the relaunched poll returned something other than the queued final answer: $(head -8 "$NONE_RESULT")"
fi
for _ in 1 2 3; do pe "$NONE_HOME" reconcile >/dev/null 2>&1 || true; sleep 0.5; done
[ "$(result_count "$NONE_HOME" "$NONE_ID")" = 1 ] \
  || fail "the ended session's final answer was captured $(result_count "$NONE_HOME" "$NONE_ID") times"
[ "$(store_field "$NONE_KEY" pending_prompts)" = 0 ] \
  || fail "lavish-axi still holds the final answer after the relaunched poll collected it"
pass "a listener relaunched after Send & End collects the ended session's final answer exactly once"
