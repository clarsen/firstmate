#!/usr/bin/env bash
# tests/fm-claude-account-spawn.test.sh - config/claude-accounts end to end
# through bin/fm-spawn.sh: with the realistic unmeasurable setup-token
# readings, a claude launch skips a slot marked limited, the launched process actually receives that slot's
# token as CLAUDE_CODE_OAUTH_TOKEN, the task record carries the slot NAME, and
# the token value itself never appears in the recorded launch command or task
# metadata. A non-claude harness spawn is untouched even when
# config/claude-accounts is configured.
#
# As with tests/fm-spawn-compact-adviser-disable.test.sh, assertions execute
# the real emitted launch command against a fake pane rather than reading
# bin/fm-spawn.sh's source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/fm-claude-account-fakes.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-claude-account-fakes.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-account-spawn)
ACCOUNT_BIN="$ROOT/bin/fm-claude-account.sh"

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>|<map-file>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog map id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  map="$case_dir/quota-map"
  mkdir -p "$case_dir"
  : > "$map"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_claude_account_fake_security "$fakebin" "$case_dir/keychain"
  fm_claude_account_fake_quota_axi "$fakebin" "$map"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$panelog|$map"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG MAP_FILE <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

add_slot() {  # <slot> <token>
  printf '%s\n' "$2" | PATH="$FAKEBIN_DIR:$PATH" "$ACCOUNT_BIN" add "$1" >/dev/null
}

# A probe harness binary that prints the env var the launch is supposed to
# have resolved, so executing the emitted command answers "what would the
# agent have received" rather than "what does the command text look like".
install_token_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s\n' "${CLAUDE_CODE_OAUTH_TOKEN-unset}"
SH
  chmod +x "$1/$2"
}

emitted_token() {  # <fakebin> <launch-log> <pane-log>
  local fakebin=$1 launchlog=$2 panelog=$3 launch preamble
  launch=$(cat "$launchlog")
  preamble=$(grep '^export ' "$panelog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane \
    /bin/sh -c "$preamble
$launch"
}

test_claude_launch_skips_the_limited_slot() {
  local rec out status launch token meta
  rec=$(make_case claude-select claude claude-select-a1)
  read_case "$rec"
  printf 'account-a\naccount-b\n' > "$HOME_DIR/config/claude-accounts"
  add_slot account-a tok-aaa
  add_slot account-b tok-bbb
  FM_HOME="$HOME_DIR" "$ACCOUNT_BIN" mark-limited account-a >/dev/null

  out=$(run_case_spawn claude-select-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "claude spawn with config/claude-accounts should succeed: $out"

  install_token_probe "$FAKEBIN_DIR" claude
  token=$(emitted_token "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "the emitted claude launch failed to run"
  assert_equals tok-bbb "$token" "the launched claude process should receive account-b's token (account-a is marked limited)"

  meta=$(cat "$HOME_DIR/state/claude-select-a1.meta")
  assert_contains "$meta" "claude_account=account-b" "the task record should name the selected slot"

  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" tok-bbb "the recorded launch command must never contain the raw token"
  assert_not_contains "$launch" tok-aaa "the recorded launch command must never contain the raw token"
  assert_not_contains "$meta" tok-bbb "the task record must never contain the raw token"
  pass "a claude launch skips the limited slot and uses the other, recording only its name"
}

# bin/fm-control.sh relaunch stops the agent and rebuilds the launch through
# bin/fm-spawn.sh --relaunch, so this drives that operator-facing verb rather
# than the rebuild alone. The custom tmux stub below (adapted from
# tests/fm-spawn-compact-adviser-disable.test.sh) models just enough pane
# lifecycle for that transaction.
make_relaunch_stub() {  # <fakebin-dir> <fake-state-dir>
  local fb=$1 d=$2
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
D=$d
SH
  cat >> "$fb/tmux" <<'SH'
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'claude' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" sleep
}

test_claude_relaunch_falls_over_after_exhaustion() {
  local dir home proj wt fakebin fakestate map id out status token launch preamble
  dir="$TMP_ROOT/claude-fallover"
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  fakestate="$dir/fake"
  map="$dir/quota-map"
  id="claude-fallover-a1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$fakestate"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(fm_fakebin "$dir")
  fm_claude_account_fake_security "$fakebin" "$dir/keychain"
  fm_claude_account_fake_quota_axi "$fakebin" "$map"
  make_relaunch_stub "$fakebin" "$fakestate"
  fm_git_worktree "$proj" "$wt" "wt-claude-fallover"
  fm_test_spawn_brief "$home" "$id"

  printf 'account-a\naccount-b\n' > "$home/config/claude-accounts"
  printf '%s\n' tok-aaa | PATH="$fakebin:$PATH" "$ACCOUNT_BIN" add account-a >/dev/null
  printf '%s\n' tok-bbb | PATH="$fakebin:$PATH" "$ACCOUNT_BIN" add account-b >/dev/null

  : > "$fakestate/literal"
  : > "$fakestate/keys"
  printf 'claude' > "$fakestate/command"
  printf '%s\n' "fm-$id" > "$fakestate/windows"
  printf '%s' "$wt" > "$fakestate/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
    echo "claude_account=account-a"
  } > "$home/state/$id.meta"
  mkdir -p "$dir/user-home"

  # account-a's session limit is hit and firstmate marks it; quota-axi still
  # cannot read either setup token, so the relaunch should pick account-b.
  FM_HOME="$home" "$ACCOUNT_BIN" mark-limited account-a >/dev/null

  out=$(env PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$fakestate" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$ROOT/bin/fm-control.sh" "$id" relaunch --note 'account exhausted, falling over' 2>&1)
  status=$?
  expect_code 0 "$status" "relaunch after exhaustion should succeed: $out"

  launch=$(grep 'encode launch-brief' "$fakestate/literal" | tail -1)
  [ -n "$launch" ] || fail "relaunch sent no replacement launch command"
  install_token_probe "$fakebin" claude
  preamble=$(grep '^export ' "$fakestate/keys")
  token=$(env -i HOME="$dir/user-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane /bin/sh -c "$preamble
$launch") || fail "relaunch's emitted launch failed to run"
  assert_equals tok-bbb "$token" "the relaunch should fall over to account-b once account-a is marked limited"
  assert_contains "$(cat "$home/state/$id.meta")" "claude_account=account-b" "the relaunched task record should name the new slot"
  pass "a relaunch re-selects and falls over to the other account once the chosen one is marked limited"
}

test_non_claude_harness_is_unaffected() {
  local rec out status meta launch
  rec=$(make_case codex-untouched codex codex-untouched-a1)
  read_case "$rec"
  printf 'account-a\n' > "$HOME_DIR/config/claude-accounts"
  add_slot account-a tok-aaa
  printf 'tok-aaa 50\n' > "$MAP_FILE"

  out=$(run_case_spawn codex-untouched-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "codex spawn with config/claude-accounts present should succeed: $out"
  meta=$(cat "$HOME_DIR/state/codex-untouched-a1.meta")
  assert_not_contains "$meta" "claude_account=" "a non-claude spawn should never record a claude_account slot"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "fm-claude-account.sh" "a non-claude launch should never reference the account helper"
  pass "config/claude-accounts has no effect on a non-claude harness spawn"
}

test_claude_launch_skips_the_limited_slot
test_claude_relaunch_falls_over_after_exhaustion
test_non_claude_harness_is_unaffected
