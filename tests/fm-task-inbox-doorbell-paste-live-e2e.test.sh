#!/usr/bin/env bash
# tests/fm-task-inbox-doorbell-paste-live-e2e.test.sh - the live doorbell
# paste-submission guard (live-harness-optin family).
#
# Claude Code reads no input while its SessionStart hooks run, so a doorbell
# typed as raw text and followed by a separate Enter reaches it as one
# unbracketed chunk, and Claude drops that Enter. bin/fm-task-inbox-lib.sh
# therefore rings a verified paste harness with one ordered bracketed-paste
# submission (bin/fm-backend.sh fm_backend_paste_submit), and its recovery
# submits a held or partly erased doorbell of ours even on a busy agent. A
# stub can only confirm the model written into it, so this guard drives the
# REAL fm_task_inbox_ring against real Claude Code on every installed backend
# with that primitive:
#   herdr  an isolated named lab session, every Herdr call (adapter calls
#          included, through a PATH wrapper) routed through bin/fm-herdr-lab.sh
#   tmux   a private tmux server on its own -L socket
# For each backend it proves, with fixture data only:
#   1. startup  a doorbell rung while SessionStart hooks run is submitted and
#               acknowledged (the record moves into handled/);
#   2. busy     a whole doorbell left in the composer of a busy agent is
#               submitted by the ring and acknowledged after the turn;
#   3. erased   a partly erased doorbell (a prefix of the line) is submitted,
#               leaving the composer empty.
# It fails naming the harness, backend, and versions.
#
# Run explicitly with FM_DOORBELL_PASTE_LIVE=1; it spends a few short Claude
# turns per backend. Restrict backends with FM_DOORBELL_PASTE_LIVE_BACKENDS
# ("herdr tmux" by default); an absent backend tool is reported, and a run that
# checked nothing fails. FM_DOORBELL_PASTE_LIVE_MODEL picks the Claude model
# (default haiku). Record the dated result in
# docs/verification/runtime-backends.md ("Doorbell paste submission").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate opt-in FM_DOORBELL_PASTE_LIVE claude jq

BACKENDS=${FM_DOORBELL_PASTE_LIVE_BACKENDS:-herdr tmux}
MODEL=${FM_DOORBELL_PASTE_LIVE_MODEL:-haiku}
HOOK_SECS=${FM_DOORBELL_PASTE_LIVE_HOOK_SECS:-12}
ORIGINAL_PATH=$PATH
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1 || printf 'version-unknown')
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-doorbell-paste-live.XXXXXX")
CHECKED=0
HERDR_SESSION_NAME=
TMUX_SOCKET="fm-dbpaste-$$"
TMUX_STARTED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$HERDR_SESSION_NAME" ] \
    && ! env PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$HERDR_SESSION_NAME"; then
    rc=1
  fi
  [ "$TMUX_STARTED" = 0 ] || command tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

# The worker sees only fixture state: a scratch project, its own steering
# inbox, and a SessionStart hook that holds Claude off its input for
# HOOK_SECS, standing in for a real home's startup hooks.
SETTINGS="{\"feedbackDrafts\":\"off\",\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"sleep $HOOK_SECS\",\"timeout\":120}]}]}}"

# Per-backend primitives, set by the backend setup below.
B_NAME=
B_TARGET=
b_screen() { :; }
b_type() { :; }
b_keys() { :; }

ring() {  # <record>
  PATH="$B_PATH" FM_COMPOSER_HARNESS=claude bash -c '
    . "$1/bin/fm-task-inbox-lib.sh"
    fm_task_inbox_ring "$2" "$3" "$4"
  ' _ "$ROOT" "$B_NAME" "$B_TARGET" "$1"
}

composer_state() {
  PATH="$B_PATH" bash -c '
    . "$1/bin/fm-backend.sh"
    fm_backend_composer_state "$2" "$3"
  ' _ "$ROOT" "$B_NAME" "$B_TARGET"
}

doorbell_of() {  # <record>
  bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_doorbell_line "$2"' _ "$ROOT" "$1"
}

write_record() {  # <inbox-dir> <seq> <text>
  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:00Z\n--\n%s\n' "$3" > "$1/$2.msg"
  printf '%s' "$1/$2.msg"
}

wait_file() {  # <path> <secs>
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ -e "$1" ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

wait_pending() {  # <tries, half a second apart>
  local i=0
  while [ "$i" -lt "$1" ]; do
    [ "$(composer_state 2>/dev/null)" = pending ] && return 0
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

fail_screen() {  # <message>
  printf '# last screen:\n' >&2
  b_screen | sed 's/^/#   /' >&2
  fail "$1"
}

wait_acked() {  # <record> <secs> -> 0 when the worker moved it into handled/
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ -e "${1%/*}/handled/${1##*/}" ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# Idle, read structurally rather than from a vendor string: Claude's spinner
# and turn timer redraw every second while a turn runs, so a screen unchanged
# across three reads a second apart, above an empty composer, is an idle agent.
wait_settled() {  # <secs>
  local i=0 last='' cur same=0
  while [ "$i" -lt "$1" ]; do
    cur=$(b_screen)
    if [ "$cur" = "$last" ] && [ "$(composer_state 2>/dev/null)" = empty ]; then
      same=$((same + 1))
      [ "$same" -ge 2 ] && return 0
    else
      same=0
    fi
    last=$cur
    i=$((i + 1))
    sleep 1
  done
  return 1
}

launch_claude() {  # <workdir> <inbox>
  local trusted=0 i=0 launch="$1/launch.sh"
  cat > "$launch" <<L
#!/bin/sh
exec env -i HOME="$HOME" USER="${USER:-}" PATH="$ORIGINAL_PATH" TERM=xterm-256color LANG=en_US.UTF-8 \
  FM_TASK_INBOX='$2' DISABLE_AUTOUPDATER=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
  claude --dangerously-skip-permissions --model '$MODEL' --settings '$SETTINGS' 'Reply with exactly READY and nothing else.'
L
  chmod +x "$launch"
  b_type "$launch"
  b_keys Enter
  while [ "$i" -lt 240 ]; do
    case "$(b_screen)" in
      *'Yes, I trust this folder'*)
        if [ "$trusted" = 0 ]; then
          trusted=1
          b_keys Down
          b_keys Enter
        fi
        ;;
      *'running SessionStart'*) return 0 ;;
    esac
    i=$((i + 1))
    sleep 0.25
  done
  return 1
}

run_scenarios() {
  local tag="$CLAUDE_VERSION on $B_NAME ($B_VERSION)" work inbox rec line held
  work="$TMP_ROOT/$B_NAME"
  inbox="$work/scenario.inbox"
  mkdir -p "$work/proj" "$inbox/handled"
  rec=$(write_record "$inbox" 001 "Reply with exactly STARTUPOK and nothing else.")
  launch_claude "$work" "$inbox" || fail "$tag: Claude never reached its SessionStart hooks"

  # 1. Startup freeze.
  ring "$rec" || fail "$tag: the ring during SessionStart hooks returned $?"
  wait_acked "$rec" 180 || fail_screen "$tag: a doorbell rung during SessionStart hooks was never acknowledged"
  pass "doorbell paste: $tag submits a doorbell rung during SessionStart hooks"

  # 2. A whole doorbell held in the composer while the agent is busy.
  wait_settled 120 || fail_screen "$tag: Claude never settled at an empty idle composer"
  rec=$(write_record "$inbox" 002 "Reply with exactly BUSYOK and nothing else.")
  line=$(doorbell_of "$rec")
  # The busy turn's command creates a marker file before it waits, so the
  # running tool call is read from the filesystem, not from rendered output.
  b_type "Use the Bash tool to run exactly: touch busy.marker && perl -e 'select(undef,undef,undef,20)' then reply DONE."
  b_keys Enter
  wait_file "$work/proj/busy.marker" 90 || fail_screen "$tag: Claude never started the busy tool call"
  b_type "$line"
  wait_pending 20 || fail_screen "$tag: the staged doorbell never read pending in the composer"
  ring "$rec" || fail "$tag: the ring of a held doorbell on a busy agent returned $?"
  wait_acked "$rec" 180 || fail_screen "$tag: a held doorbell on a busy agent was never acknowledged"
  pass "doorbell paste: $tag submits our held doorbell on a busy agent"

  # 3. A partly erased doorbell: its first 120 characters.
  wait_settled 120 || fail_screen "$tag: Claude never settled at an empty idle composer"
  rec=$(write_record "$inbox" 003 "Reply with exactly ERASEDOK and nothing else.")
  line=$(doorbell_of "$rec")
  held=${line:0:120}
  b_type "$held"
  wait_pending 20 || fail_screen "$tag: the staged doorbell prefix never read pending in the composer"
  ring "$rec" || fail "$tag: the ring of a partly erased doorbell returned $?"
  wait_settled 180 || fail_screen "$tag: a partly erased doorbell was left in the composer"
  if wait_acked "$rec" 5; then
    note "$tag: the worker also acted on the partly erased doorbell and acknowledged it"
  fi
  pass "doorbell paste: $tag submits a partly erased doorbell of ours"
  CHECKED=$((CHECKED + 1))
}

setup_herdr() {
  command -v herdr >/dev/null 2>&1 || { note "herdr absent, not verified here"; return 1; }
  [ -x "$LAB_HELPER" ] || fail "the Herdr lab helper is not executable at $LAB_HELPER"
  # shellcheck source=tests/herdr-test-safety.sh
  . "$ROOT/tests/herdr-test-safety.sh"
  herdr_forget_inherited_pane
  HERDR_SESSION_NAME=$("$LAB_HELPER" name doorbell-paste-live) || fail "could not name a Herdr lab session"
  local fakebin="$TMP_ROOT/herdr-fakebin" ws
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$HERDR_SESSION_NAME" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $HERDR_SESSION_NAME" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$HERDR_SESSION_NAME" "\${args[@]}"
EOF
  chmod +x "$fakebin/herdr"
  "$LAB_HELPER" provision "$HERDR_SESSION_NAME" || fail "could not provision the isolated Herdr lab"
  mkdir -p "$TMP_ROOT/herdr/proj"
  ws=$(herdr_lab workspace create --cwd "$TMP_ROOT/herdr/proj" --label fm-dbpaste --no-focus) \
    || fail "could not create the lab workspace"
  HERDR_PANE=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') || fail "workspace create returned no pane"
  B_NAME=herdr
  B_TARGET="$HERDR_SESSION_NAME:$HERDR_PANE"
  B_PATH="$fakebin:$ORIGINAL_PATH"
  B_VERSION=$(herdr --version 2>/dev/null | head -1)
  b_screen() { herdr_lab pane read "$HERDR_PANE" --source visible 2>/dev/null || true; }
  b_type() { herdr_lab pane send-text "$HERDR_PANE" "$1" >/dev/null; }
  b_keys() {
    case "$1" in
      Enter) herdr_lab pane send-keys "$HERDR_PANE" enter >/dev/null ;;
      Down) herdr_lab pane send-keys "$HERDR_PANE" down >/dev/null ;;
    esac
  }
}

herdr_lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$HERDR_SESSION_NAME" "$@"; }

setup_tmux() {
  command -v tmux >/dev/null 2>&1 || { note "tmux absent, not verified here"; return 1; }
  local shim="$TMP_ROOT/tmux-shim" real
  real=$(command -v tmux)
  mkdir -p "$shim" "$TMP_ROOT/tmux/proj"
  printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$real" "$TMUX_SOCKET" > "$shim/tmux"
  chmod +x "$shim/tmux"
  # A named window: tmux liveness resolves <session>:<window-name> targets.
  command tmux -L "$TMUX_SOCKET" -f /dev/null new-session -d -s dbpaste -n fm-dbpaste -x 120 -y 45 \
    -c "$TMP_ROOT/tmux/proj" || fail "could not start the private tmux server"
  TMUX_STARTED=1
  B_NAME=tmux
  B_TARGET="dbpaste:fm-dbpaste"
  B_PATH="$shim:$ORIGINAL_PATH"
  B_VERSION=$(tmux -V)
  b_screen() { command tmux -L "$TMUX_SOCKET" capture-pane -p -t "$B_TARGET" 2>/dev/null || true; }
  b_type() { command tmux -L "$TMUX_SOCKET" send-keys -t "$B_TARGET" -l "$1"; }
  b_keys() { command tmux -L "$TMUX_SOCKET" send-keys -t "$B_TARGET" "$1"; }
}

for backend in $BACKENDS; do
  case "$backend" in
    herdr) setup_herdr && run_scenarios ;;
    tmux) setup_tmux && run_scenarios ;;
    *) fail "unknown backend in FM_DOORBELL_PASTE_LIVE_BACKENDS: $backend" ;;
  esac
done

[ "$CHECKED" -gt 0 ] || fail "no backend was verified; refusing a run that checked nothing"
