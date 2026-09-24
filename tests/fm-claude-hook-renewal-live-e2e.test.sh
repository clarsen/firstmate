#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for the Stop auto-arm's lifetime renewal
# (bin/fm-claude-stop-autoarm.sh, bin/fm-watch-arm.sh, bin/fm-watch.sh).
#
# Part 1 re-checks the harness fact the renewal exists for: when an asyncRewake
# hook reaches its configured timeout, Claude settles it as killed before it
# signals the hook, so the hook's TERM->exit-2 translation never wakes the
# session, while the same hook exiting 2 before its timeout does. If a future
# Claude starts delivering the timed-out exit 2, this fails naming the version
# so docs/verification/supervision.md can be refreshed.
#
# Part 2 runs the real tracked Stop registrations, real arm, and real watcher
# with the auto-arm's host timeout shortened in the lab copy: a quiet idle
# session must receive at least two renewal rewakes before that timeout, make
# no tool call for them, get no catch-up wake, and never see the host kill a
# cycle. Both parts use isolated throwaway projects and FM_HOME; Claude keeps
# its existing managed authentication and loads only project and local
# settings. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model and the hook shells, not this test shell, expand the quoted text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_RENEWAL_LIVE_E2E,FM_CLAUDE_LIVE_E2E claude jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - Claude %s: %s\n' "${CLAUDE_VERSION:-unknown}" "$1" >&2
  exit 1
}

LAB="$ROOT/.claude-hook-renewal-live-e2e.$$"
CLAUDE_VERSION=$(claude --version)
MONITOR_PID=

cleanup() {
  [ -z "$MONITOR_PID" ] || kill "$MONITOR_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB"

# Every session: cheapest model, low effort, project and local settings only.
claude_p() {  # <project> <prompt> <transcript> [VAR=value...]
  local project=$1 prompt=$2 transcript=$3
  shift 3
  (
    cd "$project" || exit 1
    env -u TMUX "$@" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
      claude -p "$prompt" --model haiku --effort low --setting-sources project,local \
      --dangerously-skip-permissions --output-format stream-json --verbose
  ) > "$transcript" 2>&1
}

# The user-turn texts Claude injected, one per line.
injected_texts() {  # <transcript>
  jq -r 'select(.type == "user") | .message.content
    | if type == "string" then . else (.[]? | select(.type == "text") | .text) end' "$1" 2>/dev/null
}

# --- part 1: a timed-out asyncRewake hook's exit 2 is never delivered ---------

probe_project() {  # <dir> <mode: timeout|before>
  local dir=$1 mode=$2
  mkdir -p "$dir/.claude"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/hook.sh","asyncRewake":true,"timeout":4}]}]}}' \
    > "$dir/.claude/settings.json"
  printf '%s\n' "$mode" > "$dir/mode"
  cat > "$dir/hook.sh" <<'SH'
#!/usr/bin/env bash
# First firing only; later firings exit 0 silently.
D="$(cd "$(dirname "$0")" && pwd)"
cat >/dev/null 2>&1 || true
N=$(cat "$D/fire-count" 2>/dev/null || echo 0); N=$((N + 1)); echo "$N" > "$D/fire-count"
[ "$N" -eq 1 ] || exit 0
on_term() {
  echo "term" >> "$D/hook.log"
  printf 'PROBE-REWAKE-AFTER-HOST-TIMEOUT\n' >&2
  exit 2
}
trap on_term TERM
if [ "$(cat "$D/mode")" = before ]; then
  sleep 1
  echo "self-exit-2" >> "$D/hook.log"
  printf 'PROBE-REWAKE-BEFORE-TIMEOUT\n' >&2
  exit 2
fi
sleep 60 &
wait "$!"
SH
  chmod +x "$dir/hook.sh"
}

PROBE_PROMPT='Reply with exactly READY and stop. If a Stop hook feedback message arrives later, reply with exactly WOKE and stop. Use no tools.'

probe_project "$LAB/probe-timeout" timeout
claude_p "$LAB/probe-timeout" "$PROBE_PROMPT" "$LAB/probe-timeout.jsonl" \
  || fail "timeout probe session failed: $(tail -20 "$LAB/probe-timeout.jsonl")"
grep -qx term "$LAB/probe-timeout/hook.log" 2>/dev/null \
  || fail "the 4s hook timeout never signalled the probe hook: $(cat "$LAB/probe-timeout/hook.log" 2>/dev/null)"
! injected_texts "$LAB/probe-timeout.jsonl" | grep -q 'PROBE-REWAKE-AFTER-HOST-TIMEOUT' \
  || fail "Claude now delivers a timed-out asyncRewake hook's exit 2; refresh docs/verification/supervision.md and re-evaluate the renewal margin"

probe_project "$LAB/probe-before" before
claude_p "$LAB/probe-before" "$PROBE_PROMPT" "$LAB/probe-before.jsonl" \
  || fail "counterfactual probe session failed: $(tail -20 "$LAB/probe-before.jsonl")"
injected_texts "$LAB/probe-before.jsonl" | grep -q 'PROBE-REWAKE-BEFORE-TIMEOUT' \
  || fail "the same hook exiting 2 before its timeout was not delivered, so the timeout probe proves nothing"

printf 'ok - Claude %s drops a timed-out asyncRewake exit 2 and delivers one made before the timeout\n' "$CLAUDE_VERSION"

# --- part 2: the tracked chain renews inside a shortened host timeout ---------

PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/claude.jsonl"
HOST_TIMEOUT=40
RENEW_AFTER=8

# git clone carries only committed state, so copy the working-tree surfaces
# under test (same pattern as the other Claude live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
# The real tracked Stop entries (turn-end guard and auto-arm) stay as tracked
# apart from the auto-arm's timeout; SessionStart is dropped because the Stop
# auto-arm reclaims the stale lock below on its own.
jq --argjson t "$HOST_TIMEOUT" '
  del(.hooks.SessionStart)
  | .hooks.Stop |= map(.hooks |= map(if (.command | contains("fm-claude-stop-autoarm.sh")) then .timeout = $t else . end))
' "$ROOT/.claude/settings.json" > "$PROJECT/.claude/settings.json" \
  || fail "could not derive the lab settings from the tracked registration"
[ "$(jq '[.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-stop-autoarm.sh")) | select(.asyncRewake == true and .timeout == '"$HOST_TIMEOUT"')] | length' "$PROJECT/.claude/settings.json")" = 1 ] \
  || fail "the lab settings lost the tracked asyncRewake auto-arm registration"
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": ".*", "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" } ] }
    ]
  }
}
JSON
cat > "$PROJECT/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -c '{tool: .tool_name, input: .tool_input}' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/tool-logger.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$LAB/fakebin"
: > "$HOME_DIR/state/task.meta"
# A numeric pid above the supported OS range is a demonstrably dead prior owner.
printf '9999999\n' > "$HOME_DIR/state/.lock"
printf 'acked:downtime:handled-seed\n' > "$HOME_DIR/state/.watcher-down"
printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/fakebin/tmux"
chmod +x "$LAB/fakebin/tmux"

# End the fleet need once two renewal generations have committed, so the
# session can finish: the next Stop then finds nothing to supervise. Waiting for
# the committed ledger outcome, not the arm's close record, keeps the second
# renewal from reading the need as already gone.
(
  seen=' '
  count=0
  while :; do
    line=$(sed -n '1p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null || true)
    case "$line" in
      epoch=*' outcome=renew '*)
        epoch=${line%% *}
        case "$seen" in
          *" $epoch "*) ;;
          *) seen="$seen$epoch "; count=$((count + 1)) ;;
        esac
        ;;
    esac
    if [ "$count" -ge 2 ]; then
      rm -f "$HOME_DIR/state/task.meta"
      exit 0
    fi
    sleep 0.2
  done
) &
MONITOR_PID=$!

STARTED=$(date +%s)
claude_p "$PROJECT" 'Reply with exactly READY and stop. Follow any later Stop hook feedback message exactly as it instructs.' "$TRANSCRIPT" \
  PATH="$LAB/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_POLL=2 FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_GUARD_GRACE=10 \
  FM_CLAUDE_AUTOARM_RENEW_AFTER="$RENEW_AFTER" \
  || fail "renewal session failed: $(tail -20 "$TRANSCRIPT")"
ELAPSED=$(( $(date +%s) - STARTED ))

RENEWALS=$(injected_texts "$TRANSCRIPT" | grep -c 'firstmate watcher renewal' || true)
[ "${RENEWALS:-0}" -ge 2 ] \
  || fail "expected at least two delivered renewal rewakes, got ${RENEWALS:-0}: $(injected_texts "$TRANSCRIPT" | head -20)"
! injected_texts "$TRANSCRIPT" | grep -Eq 'firstmate watcher wake|rearm-resurface|auto-arm (INTERRUPTED|FAILED)' \
  || fail "the quiet session received a wake or failure notice instead of silent renewals: $(injected_texts "$TRANSCRIPT" | head -20)"
[ ! -s "$HOME_DIR/state/tool-calls.log" ] \
  || fail "the renewal turns made tool calls: $(cat "$HOME_DIR/state/tool-calls.log")"
[ "$(grep -c "$(printf '\treason=renewal\t')" "$HOME_DIR/state/.watch-cycle-exits.log")" -ge 2 ] \
  || fail "the arm recorded fewer than two renewal closes: $(cat "$HOME_DIR/state/.watch-cycle-exits.log")"
! grep -Eq "$(printf '\tsignal=(TERM|HUP|INT|KILL)\t')|reason=arm-interrupted" "$HOME_DIR/state/.watch-cycle-exits.log" \
  || fail "the host interrupted a cycle, so a renewal missed its timeout: $(cat "$HOME_DIR/state/.watch-cycle-exits.log")"
[ "$(cat "$HOME_DIR/state/.watcher-down")" = acked:downtime:handled-seed ] \
  || fail "renewals changed the handled recovery episode: $(cat "$HOME_DIR/state/.watcher-down")"
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "the cooperative turn-end guard forced a continuation across a renewal"

printf 'ok - Claude %s renewed a quiet idle cycle %s times inside a %ss hook timeout in %ss, silently and with no catch-up wake\n' \
  "$CLAUDE_VERSION" "$RENEWALS" "$HOST_TIMEOUT" "$ELAPSED"
