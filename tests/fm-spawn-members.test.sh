#!/usr/bin/env bash
# Regression tests for task members: `fm-spawn.sh --member
# <name>=<project-dir>:ref[@<ref>]` and `<name>=<project-dir>:edit`, and the
# teardown that returns them (bin/fm-task-members-lib.sh owns the contract).
# They drive the real spawn, relaunch, and teardown entry points and prove:
#   - a malformed, repeated, or disallowed member, including an edit member on a
#     scout or with a ref, refuses before any endpoint, record, or copy exists;
#   - a relaunch shows the replacement agent the recorded members again: the
#     launch brief section, the FM_MEMBER_<NAME> pane variables, and Claude's
#     --add-dir grants, leaving out a member whose copy is gone;
#   - with the real treehouse binary (skipped when absent), each member is
#     leased durably from its own project's pool under the task's lease holder,
#     claimed, pinned at the requested ref (fetching a ref the clone lacks, and
#     preferring origin's tip over a stale local branch), and
#     set up by its own project's setup hook, and the record, brief, and pane all
#     name it;
#   - a member that fails returns every member lease the spawn took and
#     publishes no record;
#   - cleanup refuses while another task record names a member's copy or names
#     the task's own copy as a member, returns only this task's member leases,
#     leaves another task's and a foreign lease untouched, and leaves alone a
#     slot this task no longer holds;
#   - a forced secondmate retirement returns its child tasks' members from the
#     secondmate's own pool, so that pool can be destroyed with the home;
#   - a relaunch shows the recorded edit members with their delivery rules and
#     refuses when an edit member's copy is gone;
#   - with the real treehouse binary, an edit member starts branch fm/<id> at
#     origin's tip and records its project's own registered delivery posture,
#     and the brief carries the edit section, a Definition of done for every
#     member mode the task's own does not cover, and the companion-note clause
#     ahead of the captain's words;
#   - an edit member that fails returns every member lease and drops the branch
#     the spawn started in another member;
#   - cleanup refuses while any edit member holds unlanded work, refuses a
#     --discard-member naming no edit member, and otherwise returns each landed
#     or named member, dropping its branch.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-members)
TEARDOWN="$ROOT/bin/fm-teardown.sh"
# Within a case every spawn and teardown runs as one user, sharing one HOME and
# so Treehouse's default root under it, exactly as a real main home does. Each
# case sets its own (use_user_home), because Treehouse keys a default pool by a
# clone's directory name and origin, and every case clones the same origins.
USER_HOME=
# A suite run from inside a herdr or cmux pane inherits that terminal's markers,
# which would steer a spawn here to the real backend (and leave a real herdr
# server behind); every entry point below clears them and pins the fake tmux.
CLEAR_TERMINAL_ENV=(-u HERDR_ENV -u HERDR_SOCKET_PATH -u HERDR_SESSION -u HERDR_PANE_ID
  -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID
  -u CMUX_TAB_ID -u CMUX_PANEL_ID -u CMUX_SOCKET_PATH -u ZELLIJ -u ZELLIJ_SESSION_NAME)
use_user_home() {  # <dir>
  USER_HOME="$1/user-home"
  mkdir -p "$USER_HOME"
}

# make_origin <bare-dir> <name>: a bare origin whose main has two commits, with
# tag v1 on the first and refs/review/side on a commit no branch holds.
make_origin() {
  local origin=$1 name=$2 seed="$1.seed"
  git init --quiet -b main "$seed"
  printf '%s v1\n' "$name" > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm v1
  git -C "$seed" tag v1
  printf '%s side\n' "$name" > "$seed/README.md"
  git -C "$seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam side
  git -C "$seed" update-ref refs/review/side HEAD
  git -C "$seed" reset -q --hard v1
  printf '%s v2\n' "$name" > "$seed/README.md"
  git -C "$seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam v2
  git clone --quiet --bare "$seed" "$origin"
  git -C "$seed" push --quiet "$origin" refs/review/side:refs/review/side
}

commit_of() {  # <origin> <ref>
  git -C "$1" rev-parse --verify --quiet "$2^{commit}"
}

# make_home <home>: a spawn-ready home cloning the task project (proj) and two
# member projects (contract, notes).
make_home() {
  local home=$1 name
  fm_test_spawn_home "$home" codex
  for name in proj contract notes; do
    git clone --quiet "file://$TMP_ROOT/$name.origin.git" "$home/projects/$name"
  done
}

# The value of one exact record key (last one wins, like the record's readers).
meta_value() {  # <meta> <key>
  awk -v k="$2=" 'index($0, k) == 1 { v = substr($0, length(k) + 1) } END { if (v != "") print v }' "$1"
}

# One field Treehouse itself reports for <copy> in <clone>'s default pool.
pool_field() {  # <clone> <copy> <field>
  (cd "$1" && env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME HOME="$USER_HOME" treehouse status --json) |
    jq -r --arg p "$2" --arg f "$3" '.[] | select(.path == $p) | .[$f] // ""'
}

# Every copy in <clone>'s default pool whose lease holder names task <id>.
pool_leases_for_task() {  # <clone> <id>
  (cd "$1" && env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME HOME="$USER_HOME" treehouse status --json) |
    jq -r --arg id "$2" '.[] | select((.lease_holder // "") | endswith(":" + $id)) | .path'
}

# A fake pane whose shell runs the `treehouse ... get` line spawn types, from
# the directory the window opened in, as a durable lease (a fake pane has no
# interactive subshell to hold Treehouse's process lease), and then reports the
# copy it landed in. Every other text line lands in <state>.keys and every
# launch in <state>.literal, so a case can read what the pane was told.
make_real_pool_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_PANE_STATE:-/dev/null}
case "$*" in
  *"#{pane_current_path}"*) cat "$state" 2>/dev/null; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  new-window)
    prev=
    for a in "$@"; do
      [ "$prev" != -c ] || printf '%s\n' "$a" > "$state"
      prev=$a
    done
    ;;
  send-keys)
    [ "$state" != /dev/null ] || exit 0
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
      printf '%s\n' "$payload" >> "$state.literal"
      exit 0
    fi
    printf '%s\n' "$payload" >> "$state.keys"
    case "$payload" in
      'treehouse '*)
        if copy=$(cd "$(cat "$state")" && eval "$payload --lease --lease-holder fake-pane" 2>>"$state.log"); then
          printf '%s\n' "$copy" > "$state"
        fi
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# run_spawn <home> <fakebin> <pane-state> <id> [--member ...]: a scout spawn of
# <home>'s proj under the shared USER_HOME.
run_spawn() {
  local home=$1 fakebin=$2 pane=$3 id=$4
  shift 4
  fm_test_spawn_brief "$home" "$id"
  env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME "${CLEAR_TERMINAL_ENV[@]}" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_STATE="$pane" TMUX="fake,1,0" \
    MEMBER_HOOK_LOG="$home/member-hook.log" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home/projects/proj" --scout "$@" 2>&1
}

run_teardown() {  # <home> <fakebin> <id>
  env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME "${CLEAR_TERMINAL_ENV[@]}" TMUX="fake,1,0" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" HOME="$USER_HOME" \
    FM_STATE_OVERRIDE="$1/state" PATH="$2:$PATH" \
    "$TEARDOWN" "$3" --force 2>&1
}

make_origin "$TMP_ROOT/proj.origin.git" proj
make_origin "$TMP_ROOT/contract.origin.git" contract
make_origin "$TMP_ROOT/notes.origin.git" notes

# --- refusals ---------------------------------------------------------------

test_member_refusals_leave_nothing_behind() {
  local dir="$TMP_ROOT/refuse" home fakebin out status label spec want n=0
  home="$dir/home"
  make_home "$home"
  git clone --quiet "file://$TMP_ROOT/contract.origin.git" "$home/projects/contract-again"
  git clone --quiet --bare "file://$TMP_ROOT/contract.origin.git" "$home/projects/contract-bare.git"
  fakebin=$(make_spawn_fakebin "$dir/fake")
  while IFS='|' read -r label want spec; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    : > "$dir/pane.$n"
    fm_test_spawn_brief "$home" "refuse-$n"
    # shellcheck disable=SC2086 # Each case's spec list is deliberately split.
    out=$(FM_FAKE_PANE_LOG="$dir/pane.$n" FM_FAKE_LAUNCH_LOG="$dir/pane.$n" \
      fm_test_run_spawn "$home" "$dir/none" "$fakebin" "refuse-$n" "$home/projects/proj" --scout $spec)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: the spawn did not refuse"$'\n'"$out"
    assert_contains "$out" "$want" "$label: the refusal did not say why"
    [ ! -s "$dir/pane.$n" ] || fail "$label: the refusal still drove the terminal"$'\n'"$(cat "$dir/pane.$n")"
    [ ! -e "$home/state/refuse-$n.meta" ] || fail "$label: the refusal published a task record"
  done <<EOF
bad name|must be 1-32 characters|--member Api=projects/contract:ref
other role|a member is ref or edit|--member api=projects/contract:review
no role|names no role|--member api=projects/contract
edit on scout|only a ship spawn delivers|--member api=projects/contract:edit
edit with ref|gives an edit member a ref|--member api=projects/contract:edit@v1
empty ref|empty ref|--member api=projects/contract:ref@
option ref|ref starting with -|--member api=projects/contract:ref@--upload-pack=x
repeated name|given twice|--member api=projects/contract:ref --member api=projects/notes:ref
own project|is the task's own project|--member api=projects/proj:ref
shared project|same project as member api|--member api=projects/contract:ref --member spec=projects/contract-again:ref
missing project|does not exist|--member api=projects/nowhere:ref
git dir|is not the top of a git clone|--member api=projects/contract/.git:ref
own git dir|is not the top of a git clone|--member api=projects/proj/.git:ref
bare repository|is not the top of a git clone|--member api=projects/contract-bare.git:ref
EOF
  for spec in "--member=api=projects/contract:ref" "--member api=projects/contract:ref"; do
    fm_test_spawn_brief "$home" refuse-batch
    # shellcheck disable=SC2086 # The flag form under test is split on purpose.
    if out=$(fm_test_run_spawn "$home" "$dir/none" "$fakebin" "refuse-batch=$home/projects/proj" --scout $spec); then
      fail "batch dispatch accepted $spec"$'\n'"$out"
    fi
    assert_contains "$out" "batch dispatch does not support --member" "batch dispatch did not refuse $spec"
  done
  if out=$(fm_test_run_spawn "$home" "$dir/none" "$fakebin" mate-x "$home" --secondmate --member api=projects/contract:ref); then
    fail "a secondmate spawn accepted --member"$'\n'"$out"
  fi
  assert_contains "$out" "applies only to ship and scout spawns" "the secondmate refusal did not say why"
  if out=$(fm_test_run_spawn "$home" "$dir/none" "$fakebin" refuse-relaunch --relaunch --member api=projects/contract:ref); then
    fail "a relaunch accepted --member"$'\n'"$out"
  fi
  assert_contains "$out" "reuses the task's recorded members" "the relaunch refusal did not say why"
  pass "malformed, repeated, same-project, batch, secondmate, and relaunch members refuse before any endpoint or record"
}

# --- relaunch ---------------------------------------------------------------

# A pane whose shell sits in the task worktree with no agent running, so a
# relaunch adopts it; text lines land in keys and launches in literal.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
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
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) printf 'zsh\n'; exit 0 ;;
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
  fm_test_fake_sleep_noop "$fb"
}

test_relaunch_shows_the_recorded_members_again() {
  local dir="$TMP_ROOT/relaunch" home proj wt api id=relaunch-a1 out status brief launch
  home="$dir/home"; proj="$dir/proj"; wt="$dir/wt"; api="$dir/api-copy"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake"
  touch "$home/state/.last-watcher-beat"
  make_relaunch_stub "$dir"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  git -C "$proj" worktree add --quiet --detach "$api" HEAD
  fm_test_spawn_brief "$home" "$id"
  : > "$dir/fake/literal"; : > "$dir/fake/keys"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  fm_write_meta "$home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "tasktmp=$dir/tasktmp" "model=default" "effort=default" \
    "member.api.project=$dir/contract" "member.api.worktree=$api" "member.api.role=ref" \
    "member.api.ref=v1" "member.api.commit=$(git -C "$api" rev-parse HEAD)" \
    "member.api.lease_id=lease-api" "member.api.pool_root=" \
    "member.old-notes.project=$dir/notes" "member.old-notes.worktree=$dir/gone-copy" \
    "member.old-notes.role=ref" "member.old-notes.ref=" "member.old-notes.commit=abc" \
    "member.old-notes.lease_id=lease-notes" "member.old-notes.pool_root="
  mkdir -p "$dir/user-home"
  out=$(env "${CLEAR_TERMINAL_ENV[@]}" PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1)
  status=$?
  expect_code 0 "$status" "the relaunch should succeed"$'\n'"$out"
  assert_contains "$out" "reference member old-notes copy '$dir/gone-copy' is missing; relaunching without it" \
    "the relaunch did not warn about the member whose copy is gone"
  brief=$(cat "$home/data/$id/launch-brief.md")
  assert_contains "$brief" "# Reference worktrees" "the relaunch brief has no member section"
  assert_contains "$brief" "- \`api\`: $api (\`\$FM_MEMBER_API\`), a copy of $dir/contract, v1 at " \
    "the relaunch brief does not list the recorded member"
  assert_not_contains "$brief" "old-notes" "the relaunch brief lists a member whose copy is gone"
  grep -Fxq "export FM_MEMBER_API='$api'" "$dir/fake/keys" \
    || fail "the relaunch did not export the member path into the pane"$'\n'"$(cat "$dir/fake/keys")"
  ! grep -Fq FM_MEMBER_OLD_NOTES "$dir/fake/keys" || fail "the relaunch exported a member whose copy is gone"
  launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
  assert_contains "$launch" "claude --dangerously-skip-permissions --add-dir '$api' --settings" \
    "the relaunched Claude agent was not granted the member directory"
  assert_not_contains "$launch" "gone-copy" "the relaunched Claude agent was granted a member whose copy is gone"
  [ "$(meta_value "$home/state/$id.meta" member.api.worktree)" = "$api" ] \
    && [ "$(meta_value "$home/state/$id.meta" member.old-notes.lease_id)" = lease-notes ] \
    || fail "the relaunch did not carry every member line forward"$'\n'"$(cat "$home/state/$id.meta")"
  # An empty allowlist clears the launch environment down to its floor, which
  # must still carry the member path.
  : > "$home/config/launch-env-allowlist"
  : > "$dir/fake/literal"
  out=$(env "${CLEAR_TERMINAL_ENV[@]}" PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1)
  expect_code 0 "$?" "the relaunch under an allowlist should succeed"$'\n'"$out"
  launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
  # shellcheck disable=SC2016 # The literal floor entry the launch carries.
  assert_contains "$launch" '${FM_MEMBER_API+"FM_MEMBER_API=$FM_MEMBER_API"}' \
    "a launch environment allowlist dropped the member path from the relaunched agent"
  pass "a relaunch lists, exports, grants, and keeps through an allowlist the recorded members again, leaving out one whose copy is gone"
}

# --- real treehouse ---------------------------------------------------------

real_treehouse_available() {
  command -v treehouse >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

test_real_members_are_leased_pinned_set_up_and_shown() {
  local dir="$TMP_ROOT/real" home fakebin id=real-a1 out status meta api notes brief holder
  real_treehouse_available || { printf '# real-treehouse member spawn case not run: treehouse or jq is not installed\n'; return 0; }
  use_user_home "$dir"
  home="$dir/home"
  make_home "$home"
  mkdir -p "$home/config/project-setup"
  cat > "$home/config/project-setup/contract.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s\n' "$FM_MEMBER" "$(pwd -P)" "$(git rev-parse HEAD)" "$FM_PROJECT" "$FM_WORKTREE" >> "$MEMBER_HOOK_LOG"
SH
  chmod +x "$home/config/project-setup/contract.sh"
  fakebin=$(make_real_pool_fakebin "$dir/fake")
  out=$(run_spawn "$home" "$fakebin" "$dir/pane" "$id" \
    --member api=projects/contract:ref@v1 --member notes=projects/notes:ref@refs/review/side)
  status=$?
  expect_code 0 "$status" "a spawn with two members should launch"$'\n'"$out"$'\n'"$(cat "$dir/pane.log" 2>/dev/null)"
  meta="$home/state/$id.meta"
  api=$(meta_value "$meta" member.api.worktree)
  notes=$(meta_value "$meta" member.notes.worktree)
  [ -n "$api" ] && [ -d "$api" ] && [ -n "$notes" ] && [ -d "$notes" ] \
    || fail "the task record does not name both member copies"$'\n'"$(cat "$meta")"
  assert_equals "$(commit_of "$TMP_ROOT/contract.origin.git" v1)" "$(git -C "$api" rev-parse HEAD)" \
    "the api member is not pinned at v1"
  assert_equals "$(commit_of "$TMP_ROOT/notes.origin.git" refs/review/side)" "$(git -C "$notes" rev-parse HEAD)" \
    "the notes member is not pinned at the ref fetched from its origin"
  assert_equals "$(git -C "$api" rev-parse HEAD)" "$(meta_value "$meta" member.api.commit)" "the record names another api commit"
  assert_equals v1 "$(meta_value "$meta" member.api.ref)" "the record lost the requested api ref"
  assert_equals ref "$(meta_value "$meta" member.api.role)" "the record names another api role"
  assert_equals leased "$(pool_field "$home/projects/contract" "$api" status)" "the api copy is not durably leased"
  holder=$(pool_field "$home/projects/contract" "$api" lease_holder)
  case "$holder" in
    fm-member:*:"$id") ;;
    *) fail "the api copy is leased under '$holder', not this task's member holder" ;;
  esac
  assert_equals "$(meta_value "$meta" member.api.lease_id)" "$(pool_field "$home/projects/contract" "$api" lease_id)" \
    "the record does not carry Treehouse's lease id"
  grep -Fxq "task=$id" "$(dirname "$api")/.fm-slot-owner" || fail "the api slot does not carry this task's claim"
  grep -Fxq "api|$(cd "$api" && pwd -P)|$(commit_of "$TMP_ROOT/contract.origin.git" v1)|contract|$api" "$home/member-hook.log" \
    || fail "the contract setup hook did not run in the pinned api copy"$'\n'"$(cat "$home/member-hook.log" 2>/dev/null)"
  [ "$(grep -c . "$home/member-hook.log")" = 1 ] || fail "a setup hook ran for a member of another project"
  brief=$(cat "$home/data/$id/launch-brief.md")
  assert_contains "$brief" "# Reference worktrees" "the launch brief has no member section"
  assert_contains "$brief" "never edit, commit in, push from" "the member section does not say members are read-only"
  assert_contains "$brief" "keep changes to anything another repository relies on additive" \
    "the member section lacks the additive-contract rule"
  assert_contains "$brief" "- \`api\`: $api (\`\$FM_MEMBER_API\`), a copy of $home/projects/contract, v1 at $(git -C "$api" rev-parse HEAD)" \
    "the launch brief does not list the api member"
  assert_contains "$brief" "- \`notes\`: $notes (\`\$FM_MEMBER_NOTES\`)" "the launch brief does not list the notes member"
  if ! grep -Fxq "export FM_MEMBER_API='$api'" "$dir/pane.keys" ||
    ! grep -Fxq "export FM_MEMBER_NOTES='$notes'" "$dir/pane.keys"; then
    fail "the pane did not receive both member paths"$'\n'"$(cat "$dir/pane.keys")"
  fi
  out=$(run_teardown "$home" "$fakebin" "$id")
  expect_code 0 "$?" "the task's teardown should return its copies"$'\n'"$out"
  pass "each member is durably leased from its own pool, claimed, pinned (fetching a missing ref), set up by its own hook, recorded, briefed, and exported"
}

test_real_member_failure_returns_every_lease() {
  local dir="$TMP_ROOT/rollback" home fakebin id=rollback-a1 out status
  real_treehouse_available || { printf '# real-treehouse member rollback case not run: treehouse or jq is not installed\n'; return 0; }
  use_user_home "$dir"
  home="$dir/home"
  make_home "$home"
  fakebin=$(make_real_pool_fakebin "$dir/fake")
  out=$(run_spawn "$home" "$fakebin" "$dir/pane" "$id" \
    --member api=projects/contract:ref@v1 --member notes=projects/notes:ref@no-such-ref)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose member ref does not exist still launched"$'\n'"$out"
  assert_contains "$out" "member notes: ref 'no-such-ref' does not name a commit" "the refusal did not name the failing member"
  assert_contains "$out" "returned member copy" "the refusal did not report returning the leases it took"
  [ ! -e "$home/state/$id.meta" ] || fail "a failed member spawn published a task record"
  [ -z "$(pool_leases_for_task "$home/projects/contract" "$id")" ] \
    || fail "the api member lease survived the failed spawn"
  [ -z "$(pool_leases_for_task "$home/projects/notes" "$id")" ] \
    || fail "the notes member lease survived the failed spawn"
  ! grep -rqx "task=$id" "$USER_HOME/.treehouse" --include=.fm-slot-owner 2>/dev/null \
    || fail "a member slot still carries the failed task's claim"
  grep -Fq 'encode launch-brief' "$dir/pane.literal" 2>/dev/null && fail "the failed member spawn still launched an agent"
  pass "a member that fails returns every member lease the spawn took and publishes no record"
}

test_real_member_branch_pins_origin_tip_over_a_stale_local_branch() {
  local dir="$TMP_ROOT/stale" home fakebin id=stale-a1 out meta api
  real_treehouse_available || { printf '# real-treehouse stale-branch member case not run: treehouse or jq is not installed\n'; return 0; }
  use_user_home "$dir"
  home="$dir/home"
  make_home "$home"
  git -C "$home/projects/contract" reset -q --hard v1
  fakebin=$(make_real_pool_fakebin "$dir/fake")
  out=$(run_spawn "$home" "$fakebin" "$dir/pane" "$id" --member api=projects/contract:ref@main)
  expect_code 0 "$?" "a spawn with a branch member should launch"$'\n'"$out"
  meta="$home/state/$id.meta"
  api=$(meta_value "$meta" member.api.worktree)
  [ -n "$api" ] && [ -d "$api" ] || fail "the task record does not name the member copy"$'\n'"$(cat "$meta")"
  assert_equals "$(commit_of "$TMP_ROOT/contract.origin.git" main)" "$(git -C "$api" rev-parse HEAD)" \
    "a member branch ref is pinned at the clone's stale local branch, not origin's tip"
  assert_equals "$(git -C "$api" rev-parse HEAD)" "$(meta_value "$meta" member.api.commit)" "the record names another api commit"
  out=$(run_teardown "$home" "$fakebin" "$id")
  expect_code 0 "$?" "the task's teardown should return its copies"$'\n'"$out"
  pass "a member branch ref pins origin's tip even when the clone's local branch lags it"
}

test_real_teardown_returns_only_this_tasks_members() {
  local dir="$TMP_ROOT/cleanup" home fakebin out status a_api b_api probe contract holder
  real_treehouse_available || { printf '# real-treehouse member cleanup case not run: treehouse or jq is not installed\n'; return 0; }
  use_user_home "$dir"
  home="$dir/home"
  make_home "$home"
  contract="$home/projects/contract"
  fakebin=$(make_real_pool_fakebin "$dir/fake")
  out=$(run_spawn "$home" "$fakebin" "$dir/pane-a" clean-a1 --member api=projects/contract:ref)
  expect_code 0 "$?" "task A should launch"$'\n'"$out"
  out=$(run_spawn "$home" "$fakebin" "$dir/pane-b" clean-b1 --member api=projects/contract:ref)
  expect_code 0 "$?" "task B should launch"$'\n'"$out"
  a_api=$(meta_value "$home/state/clean-a1.meta" member.api.worktree)
  b_api=$(meta_value "$home/state/clean-b1.meta" member.api.worktree)
  [ -n "$a_api" ] && [ -n "$b_api" ] && [ "$a_api" != "$b_api" ] \
    || fail "two tasks' members did not get distinct copies: '$a_api' and '$b_api'"
  assert_equals "$(commit_of "$TMP_ROOT/contract.origin.git" main)" "$(git -C "$a_api" rev-parse HEAD)" \
    "a member with no ref is not pinned at origin's default-branch tip"
  probe=$(cd "$contract" && env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME HOME="$USER_HOME" \
    treehouse get --lease --lease-holder probe 2>/dev/null) || fail "could not lease a foreign probe copy"
  printf 'scratch\n' > "$a_api/left-behind.txt"

  # One live path named by two task records is the reuse collision itself, so
  # cleanup refuses before touching anything, whichever record is stale.
  printf 'worktree=%s\n' "$a_api" > "$home/state/ghost.meta"
  if out=$(run_teardown "$home" "$fakebin" clean-a1); then
    fail "teardown returned a member copy another task record names as its worktree"$'\n'"$out"
  fi
  assert_contains "$out" "is also task ghost's recorded worktree" "the member collision refusal did not name the other record"
  mv "$home/state/ghost.meta" "$home/state/ghost.meta.off"
  printf 'member.x.worktree=%s\n' "$(meta_value "$home/state/clean-a1.meta" worktree)" > "$home/state/ghost.meta"
  if out=$(run_teardown "$home" "$fakebin" clean-a1); then
    fail "teardown returned a copy another task record names as a reference member"$'\n'"$out"
  fi
  assert_contains "$out" "is also task ghost's recorded reference member worktree" \
    "the collision refusal did not name the other record's member"
  mv "$home/state/ghost.meta" "$home/state/ghost-2.meta.off"
  assert_equals leased "$(pool_field "$contract" "$a_api" status)" "a refused teardown still returned task A's member"
  [ -f "$home/state/clean-a1.meta" ] || fail "a refused teardown removed task A's record"

  out=$(run_teardown "$home" "$fakebin" clean-a1)
  status=$?
  expect_code 0 "$status" "task A's teardown should succeed"$'\n'"$out"
  assert_contains "$out" "discarding what was left in task clean-a1's reference member api copy" \
    "teardown did not say it discarded what was left in the member"
  assert_equals available "$(pool_field "$contract" "$a_api" status)" "task A's member copy was not returned"
  [ ! -e "$(dirname "$a_api")/.fm-slot-owner" ] || fail "task A's member claim outlived its return"
  assert_equals leased "$(pool_field "$contract" "$b_api" status)" "task A's teardown returned task B's member"
  grep -Fxq "task=clean-b1" "$(dirname "$b_api")/.fm-slot-owner" || fail "task A's teardown disturbed task B's claim"
  assert_equals probe "$(pool_field "$contract" "$probe" lease_holder)" "task A's teardown returned a foreign lease"

  # A slot this task no longer holds is left to its pool rather than reset.
  (cd "$contract" && HOME="$USER_HOME" treehouse return --force \
    --if-lease-id "$(meta_value "$home/state/clean-b1.meta" member.api.lease_id)" "$b_api" >/dev/null 2>&1) \
    || fail "could not return task B's member out of band"
  # Two leases take both available copies, so one of them re-leases B's.
  for holder in probe-2 probe-3; do
    (cd "$contract" && env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME HOME="$USER_HOME" \
      treehouse get --lease --lease-holder "$holder" >/dev/null 2>&1) || fail "could not re-lease a returned copy as $holder"
  done
  holder=$(pool_field "$contract" "$b_api" lease_holder)
  case "$holder" in
    probe-2|probe-3) ;;
    *) fail "fixture precondition: task B's returned copy was not re-leased ('$holder')" ;;
  esac
  out=$(run_teardown "$home" "$fakebin" clean-b1)
  expect_code 0 "$?" "task B's teardown should succeed with its member slot already gone"$'\n'"$out"
  assert_contains "$out" "no longer carries this task's lease" "teardown did not say task B no longer held its member"
  assert_equals "$holder" "$(pool_field "$contract" "$b_api" lease_holder)" \
    "task B's teardown returned a slot it no longer held"
  pass "cleanup refuses a path two records name, and otherwise returns only this task's member leases, discarding what was left, and leaves another task's, a foreign, and a no-longer-held slot alone"
}

# run_mate <main-home> <fakebin> <cmd> <args...>: a secondmate lifecycle command
# run from the main home under the case's USER_HOME.
run_mate() {
  local main=$1 fakebin=$2 cmd=$3 dir
  dir=${main%/*}
  shift 3
  env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME "${CLEAR_TERMINAL_ENV[@]}" TMUX="fake,1,0" \
    FM_ROOT_OVERRIDE='' FM_HOME="$main" HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_TMUX_LOG="$dir/mate-tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/mate-pane.txt" \
    PATH="$fakebin:$PATH" "$ROOT/bin/$cmd" "$@" 2>&1
}

test_real_forced_retirement_returns_child_members() {
  local dir="$TMP_ROOT/retire" fakebin matebin main sm out status api root
  real_treehouse_available || { printf '# real-treehouse secondmate retirement case not run: treehouse or jq is not installed\n'; return 0; }
  use_user_home "$dir"
  fakebin=$(make_real_pool_fakebin "$dir/fake")
  # Secondmate lifecycle commands drive the ordinary fake tmux but the real
  # treehouse, so the retirement's pool destroy is the real one.
  matebin=$(make_fake_tmux "$dir/mate-fake")
  rm -f "$matebin/treehouse"
  printf '❯\n' > "$dir/mate-pane.txt"
  main="$dir/main-home"; sm="$dir/evo-home"
  make_home "$main"
  printf -- '- proj [direct-PR] - evolution project (added 2026-09-23)\n- contract [direct-PR] - contract project (added 2026-09-23)\n' \
    > "$main/data/projects.md"
  FM_HOME="$main" FM_SECONDMATE_CHARTER='evolution charter' "$ROOT/bin/fm-brief.sh" evo --secondmate proj >/dev/null \
    || fail "could not scaffold the secondmate charter"
  out=$(run_mate "$main" "$matebin" fm-home-seed.sh evo "$sm" proj contract) || fail "seeding secondmate evo failed"$'\n'"$out"
  out=$(run_mate "$main" "$matebin" fm-spawn.sh evo "$sm" codex --secondmate) || fail "launching secondmate evo failed"$'\n'"$out"
  fm_test_spawn_home "$sm" codex

  out=$(run_spawn "$sm" "$fakebin" "$dir/pane" retire-c1 --member api=projects/contract:ref)
  status=$?
  expect_code 0 "$status" "the secondmate's child spawn with a member should launch"$'\n'"$out"$'\n'"$(cat "$dir/pane.log" 2>/dev/null)"
  api=$(meta_value "$sm/state/retire-c1.meta" member.api.worktree)
  root=$(meta_value "$sm/state/retire-c1.meta" member.api.pool_root)
  [ -n "$root" ] && [ -d "$root" ] || fail "the secondmate's child member was not drawn from its own pool root ('$root')"
  case "$api" in
    "$root"/*) ;;
    *) fail "the child member copy $api is not in the secondmate's pool root $root" ;;
  esac

  out=$(run_mate "$main" "$matebin" fm-teardown.sh evo --force)
  status=$?
  expect_code 0 "$status" "the forced retirement should return the child's member and remove the home"$'\n'"$out"
  assert_contains "$out" "returned task retire-c1's reference member api copy" \
    "the forced retirement did not return the child's member"
  [ ! -e "$root" ] || fail "the forced retirement left the secondmate's pool root: $(find "$root" -maxdepth 3 2>/dev/null)"
  [ ! -e "$sm" ] || fail "the forced retirement left the secondmate home"
  pass "a forced secondmate retirement returns its child tasks' members, so its own pool is destroyed with it"
}

# --- edit members -----------------------------------------------------------

test_relaunch_shows_edit_members_and_refuses_a_missing_one() {
  local dir="$TMP_ROOT/relaunch-edit" home proj wt api id=relaunch-e1 out status brief commit
  home="$dir/home"; proj="$dir/proj"; wt="$dir/wt"; api="$dir/api-copy"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake"
  touch "$home/state/.last-watcher-beat"
  make_relaunch_stub "$dir"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet --detach "$api" HEAD
  commit=$(git -C "$api" rev-parse HEAD)
  fm_test_spawn_brief "$home" "$id" "change the contract and its client together"
  : > "$dir/fake/literal"; : > "$dir/fake/keys"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  fm_write_meta "$home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off" "tasktmp=$dir/tasktmp" "model=default" "effort=default" \
    "member.api.project=$dir/contract" "member.api.worktree=$api" "member.api.role=edit" \
    "member.api.ref=" "member.api.commit=$commit" "member.api.lease_id=lease-api" "member.api.pool_root=" \
    "member.api.mode=no-mistakes" "member.api.yolo=off"
  mkdir -p "$dir/user-home"
  out=$(env "${CLEAR_TERMINAL_ENV[@]}" PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1)
  status=$?
  expect_code 0 "$status" "the relaunch with an edit member should succeed"$'\n'"$out"
  brief=$(cat "$home/data/$id/launch-brief.md")
  assert_contains "$brief" "# Edit worktrees" "the relaunch brief has no edit member section"
  assert_contains "$brief" "- \`api\`: $api (\`\$FM_MEMBER_API\`), a copy of $dir/contract, on branch \`fm/$id\` from $commit, delivery mode=no-mistakes" \
    "the relaunch brief does not list the recorded edit member"
  assert_contains "$brief" "## Definition of done for no-mistakes repositories" \
    "the relaunch brief lacks the Definition of done for the edit member's mode"
  assert_contains "$brief" "Companion note:" "the relaunch brief lacks the companion-note clause"
  assert_equals "change the contract and its client together" "$(tail -n 1 "$home/data/$id/launch-brief.md")" \
    "the captain's words do not close the relaunch brief"
  grep -Fxq "export FM_MEMBER_API='$api'" "$dir/fake/keys" \
    || fail "the relaunch did not export the edit member path into the pane"$'\n'"$(cat "$dir/fake/keys")"

  git -C "$proj" worktree remove --force "$api"
  : > "$dir/fake/literal"
  if out=$(env "${CLEAR_TERMINAL_ENV[@]}" PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1); then
    fail "a relaunch whose edit member copy is gone still launched"$'\n'"$out"
  fi
  assert_contains "$out" "edit member api copy '$api' is missing" "the relaunch refusal did not name the missing edit member"
  ! grep -Fq 'encode launch-brief' "$dir/fake/literal" || fail "the refused relaunch still launched an agent"
  pass "a relaunch lists an edit member with its delivery rules, and refuses when its copy is gone"
}

# make_edit_home <home>: make_home plus a registry giving each project its own
# delivery posture.
make_edit_home() {
  make_home "$1"
  cat > "$1/data/projects.md" <<'EOF'
- proj [direct-PR] - task project (added 2026-09-24)
- contract [no-mistakes] - contract project (added 2026-09-24)
- notes [local-only +yolo] - notes project (added 2026-09-24)
EOF
}

# The real pool fakebin plus a no-mistakes that, like the real one, reports an
# uninitialized repository, so cleanup's run checks read no run anywhere.
make_edit_fakebin() {  # <dir>
  local fakebin
  fakebin=$(make_real_pool_fakebin "$1")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
echo "error: repo not initialized (run 'no-mistakes init' first)"
exit 1
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# run_ship_spawn <home> <fakebin> <pane-state> <id> [--member ...]: a direct-PR
# ship spawn of <home>'s proj under the shared USER_HOME.
run_ship_spawn() {
  local home=$1 fakebin=$2 pane=$3 id=$4
  shift 4
  fm_test_spawn_brief "$home" "$id" "change the contract and its client together"
  env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME "${CLEAR_TERMINAL_ENV[@]}" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_STATE="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home/projects/proj" --mode direct-PR --yolo off "$@" 2>&1
}

# run_plain_teardown <home> <fakebin> <id> [args...]: teardown with no --force.
run_plain_teardown() {
  local home=$1 fakebin=$2 id=$3
  shift 3
  env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME "${CLEAR_TERMINAL_ENV[@]}" TMUX="fake,1,0" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" HOME="$USER_HOME" \
    FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@" 2>&1
}

# A commit that changes a file: cleanup reads a branch whose tree matches its
# default branch as landed, so an empty commit would not be unlanded work.
member_commit() {  # <worktree> <message>
  printf '%s\n' "$2" >> "$1/CHANGES.md"
  git -C "$1" add CHANGES.md
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -m "$2"
}

test_real_edit_members_are_branched_recorded_and_briefed() {
  local dir="$TMP_ROOT/edit" home fakebin id=edit-a1 out status meta api notes brief tip n_edit n_intent n_words
  real_treehouse_available || { printf '# real-treehouse edit member cases not run: treehouse or jq is not installed\n'; return 0; }
  use_user_home "$dir"
  home="$dir/home"
  make_edit_home "$home"
  fakebin=$(make_edit_fakebin "$dir/fake")
  out=$(run_ship_spawn "$home" "$fakebin" "$dir/pane" "$id" \
    --member api=projects/contract:edit --member notes=projects/notes:edit)
  status=$?
  expect_code 0 "$status" "a ship spawn with two edit members should launch"$'\n'"$out"$'\n'"$(cat "$dir/pane.log" 2>/dev/null)"
  meta="$home/state/$id.meta"
  api=$(meta_value "$meta" member.api.worktree)
  notes=$(meta_value "$meta" member.notes.worktree)
  [ -n "$api" ] && [ -d "$api" ] && [ -n "$notes" ] && [ -d "$notes" ] \
    || fail "the task record does not name both edit member copies"$'\n'"$(cat "$meta")"
  tip=$(commit_of "$TMP_ROOT/contract.origin.git" main)
  assert_equals "fm/$id" "$(git -C "$api" symbolic-ref --quiet --short HEAD)" "the api edit member is not on branch fm/$id"
  assert_equals "$tip" "$(git -C "$api" rev-parse HEAD)" "the api edit member does not start at origin's default-branch tip"
  assert_equals "$tip" "$(meta_value "$meta" member.api.commit)" "the record names another api base"
  assert_equals "fm/$id" "$(git -C "$notes" symbolic-ref --quiet --short HEAD)" "the notes edit member is not on branch fm/$id"
  assert_equals edit "$(meta_value "$meta" member.api.role)" "the record names another api role"
  assert_equals no-mistakes "$(meta_value "$meta" member.api.mode)" "the api member does not carry its project's registered mode"
  assert_equals off "$(meta_value "$meta" member.api.yolo)" "the api member does not carry its project's registered merge posture"
  assert_equals local-only "$(meta_value "$meta" member.notes.mode)" "the notes member does not carry its project's registered mode"
  assert_equals on "$(meta_value "$meta" member.notes.yolo)" "the notes member does not carry its project's registered merge posture"
  assert_equals leased "$(pool_field "$home/projects/contract" "$api" status)" "the api copy is not durably leased"
  brief=$(cat "$home/data/$id/launch-brief.md")
  assert_contains "$brief" "# Edit worktrees" "the launch brief has no edit member section"
  assert_contains "$brief" "- \`api\`: $api (\`\$FM_MEMBER_API\`), a copy of $home/projects/contract, on branch \`fm/$id\` from $tip, delivery mode=no-mistakes" \
    "the launch brief does not list the api edit member"
  assert_contains "$brief" "delivery mode=local-only" "the launch brief does not give the notes member its mode"
  assert_contains "$brief" "never run more than one no-mistakes validation for this task at once" \
    "the edit section does not keep validation to one repository at a time"
  assert_contains "$brief" "## Definition of done for no-mistakes repositories" "the brief lacks the no-mistakes member Definition of done"
  assert_contains "$brief" "## Definition of done for local-only repositories" "the brief lacks the local-only member Definition of done"
  assert_not_contains "$brief" "## Definition of done for direct-PR repositories" \
    "the brief repeats the task's own Definition of done as a member one"
  assert_contains "$brief" "Companion note:" "the brief lacks the companion-note clause"
  n_edit=$(grep -n '^# Edit worktrees$' "$home/data/$id/launch-brief.md" | cut -d: -f1)
  n_intent=$(grep -n '^# Current no-mistakes intent contract$' "$home/data/$id/launch-brief.md" | cut -d: -f1)
  n_words=$(grep -n '^## Captain intent authorized for --intent$' "$home/data/$id/launch-brief.md" | cut -d: -f1)
  [ -n "$n_edit" ] && [ -n "$n_intent" ] && [ -n "$n_words" ] && [ "$n_edit" -lt "$n_intent" ] && [ "$n_intent" -lt "$n_words" ] \
    || fail "the edit section, intent contract, and captain's words are not in that order ($n_edit, $n_intent, $n_words)"
  assert_equals "change the contract and its client together" "$(tail -n 1 "$home/data/$id/launch-brief.md")" \
    "the captain's words do not close the launch brief"
  if ! grep -Fxq "export FM_MEMBER_API='$api'" "$dir/pane.keys" ||
    ! grep -Fxq "export FM_MEMBER_NOTES='$notes'" "$dir/pane.keys"; then
    fail "the pane did not receive both edit member paths"$'\n'"$(cat "$dir/pane.keys")"
  fi

  # An unpushed commit in an edit member is unlanded work: cleanup refuses and
  # keeps every copy.
  member_commit "$api" "api change"
  if out=$(run_plain_teardown "$home" "$fakebin" "$id"); then
    fail "cleanup returned a task whose edit member holds unlanded work"$'\n'"$out"
  fi
  assert_contains "$out" "edit member api ($api) holds work that has not landed" "the refusal did not name the unlanded edit member"
  [ -f "$meta" ] || fail "a refused cleanup removed the task record"
  assert_equals leased "$(pool_field "$home/projects/contract" "$api" status)" "a refused cleanup returned the api copy"
  if out=$(run_plain_teardown "$home" "$fakebin" "$id" --discard-member nothing-here); then
    fail "cleanup accepted --discard-member naming no edit member"$'\n'"$out"
  fi
  assert_contains "$out" "names no edit member" "the refusal did not say the discard named no edit member"

  # Pushed, the api work is on a remote; the notes member's local-only commit
  # lands through the member merge into its own clone.
  git -C "$api" push --quiet origin "fm/$id" || fail "could not push the api branch"
  member_commit "$notes" "notes change"
  if out=$(run_plain_teardown "$home" "$fakebin" "$id"); then
    fail "cleanup returned a task whose local-only edit member is not merged"$'\n'"$out"
  fi
  assert_contains "$out" "edit member notes ($notes) holds work that has not landed" "the refusal did not name the unmerged notes member"
  out=$(env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" HOME="$USER_HOME" \
    FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" "$ROOT/bin/fm-merge-local.sh" "$id" --member notes 2>&1)
  expect_code 0 "$?" "the notes member's local merge should land it"$'\n'"$out"
  assert_contains "$out" "in $home/projects/notes" "the member merge did not land in the notes clone"
  assert_equals "$(git -C "$notes" rev-parse HEAD)" "$(git -C "$home/projects/notes" rev-parse main)" \
    "the notes clone's default branch did not take the member's work"
  if out=$(env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" HOME="$USER_HOME" \
    FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" "$ROOT/bin/fm-merge-local.sh" "$id" --member api 2>&1); then
    fail "a local merge landed a no-mistakes edit member"$'\n'"$out"
  fi
  assert_contains "$out" "is mode=no-mistakes, not local-only" "the member merge refusal did not name the member's mode"

  out=$(run_plain_teardown "$home" "$fakebin" "$id")
  expect_code 0 "$?" "cleanup should return a task whose edit members all landed"$'\n'"$out"
  assert_contains "$out" "returned task $id's edit member api copy" "cleanup did not return the api member"
  assert_contains "$out" "returned task $id's edit member notes copy" "cleanup did not return the notes member"
  assert_equals available "$(pool_field "$home/projects/contract" "$api" status)" "the api copy was not returned"
  assert_equals available "$(pool_field "$home/projects/notes" "$notes" status)" "the notes copy was not returned"
  ! git -C "$home/projects/contract" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null \
    || fail "cleanup left the api member's branch behind"
  ! git -C "$home/projects/notes" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null \
    || fail "cleanup left the notes member's branch behind"
  [ ! -e "$meta" ] || fail "cleanup kept the task record"
  pass "edit members start fm/<id> at origin's tip with their own posture, are briefed and exported, block cleanup until landed, and land and return per repository"
}

test_real_edit_member_discard_names_one_repository() {
  local dir="$TMP_ROOT/edit-discard" home fakebin id=edit-d1 out meta api
  real_treehouse_available || { printf '# real-treehouse edit member discard case not run: treehouse or jq is not installed\n'; return 0; }
  use_user_home "$dir"
  home="$dir/home"
  make_edit_home "$home"
  fakebin=$(make_edit_fakebin "$dir/fake")
  out=$(run_ship_spawn "$home" "$fakebin" "$dir/pane" "$id" --member api=projects/contract:edit)
  expect_code 0 "$?" "a ship spawn with an edit member should launch"$'\n'"$out"
  meta="$home/state/$id.meta"
  api=$(meta_value "$meta" member.api.worktree)
  member_commit "$api" "abandoned change"
  out=$(run_plain_teardown "$home" "$fakebin" "$id" --discard-member api)
  expect_code 0 "$?" "cleanup should discard the named edit member's work"$'\n'"$out"
  assert_contains "$out" "discarding any unlanded work in task $id's edit member api copy" \
    "cleanup did not say it discarded the named member's work"
  assert_equals available "$(pool_field "$home/projects/contract" "$api" status)" "the discarded api copy was not returned"
  ! git -C "$home/projects/contract" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null \
    || fail "cleanup left the discarded member's branch behind"
  pass "--discard-member discards exactly the named edit member's unlanded work and returns it"
}

test_real_edit_member_failure_returns_every_lease_and_branch() {
  local dir="$TMP_ROOT/edit-rollback" home fakebin id=edit-r1 out status
  real_treehouse_available || { printf '# real-treehouse edit member rollback case not run: treehouse or jq is not installed\n'; return 0; }
  use_user_home "$dir"
  home="$dir/home"
  make_edit_home "$home"
  git -C "$home/projects/notes" branch "fm/$id"
  fakebin=$(make_edit_fakebin "$dir/fake")
  out=$(run_ship_spawn "$home" "$fakebin" "$dir/pane" "$id" \
    --member api=projects/contract:edit --member notes=projects/notes:edit)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose edit member branch already exists still launched"$'\n'"$out"
  assert_contains "$out" "member notes: branch fm/$id already exists" "the refusal did not name the failing edit member"
  assert_contains "$out" "returned member copy" "the refusal did not report returning the leases it took"
  [ ! -e "$home/state/$id.meta" ] || fail "a failed edit member spawn published a task record"
  [ -z "$(pool_leases_for_task "$home/projects/contract" "$id")" ] || fail "the api member lease survived the failed spawn"
  [ -z "$(pool_leases_for_task "$home/projects/notes" "$id")" ] || fail "the notes member lease survived the failed spawn"
  ! git -C "$home/projects/contract" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null \
    || fail "the failed spawn left the branch it started in the api member"
  git -C "$home/projects/notes" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null \
    || fail "the failed spawn removed a branch it did not start"
  pass "an edit member that fails returns every member lease, drops the branch the spawn started, and keeps one it did not"
}

test_member_refusals_leave_nothing_behind
test_relaunch_shows_the_recorded_members_again
test_real_members_are_leased_pinned_set_up_and_shown
test_real_member_failure_returns_every_lease
test_real_member_branch_pins_origin_tip_over_a_stale_local_branch
test_real_teardown_returns_only_this_tasks_members
test_real_forced_retirement_returns_child_members
test_relaunch_shows_edit_members_and_refuses_a_missing_one
test_real_edit_members_are_branched_recorded_and_briefed
test_real_edit_member_discard_names_one_repository
test_real_edit_member_failure_returns_every_lease_and_branch

echo "# all fm-spawn-members tests passed"
