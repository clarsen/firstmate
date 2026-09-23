#!/usr/bin/env bash
# Regression tests for fm-spawn's per-project setup hook,
# config/project-setup/<project>.sh.
#
# These tests drive the real spawn path with a fake terminal and prove the hook
# runs inside the fresh task worktree before the agent launch is sent, that a
# failing, hung, invalid, or git-visible hook refuses the launch, and that an
# absent hook changes nothing.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-project-setup)

# make_case <name> <id>
# An origin-less project with a clean detached pool worktree, so the spawn's
# base refresh has nothing to fetch and the hook is the only moving part.
make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/taskbase"
  POOL_DIR="$CASE_DIR/pool"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  LAUNCH_LOG="$CASE_DIR/launch.log"

  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  touch "$HOME_DIR/state/.last-watcher-beat"

  git init --quiet -b main "$PROJECT_DIR"
  printf 'base\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" add README.md
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" HEAD
}

# install_hook <body>
# Writes an executable config/project-setup/taskbase.sh with <body>.
install_hook() {
  mkdir -p "$HOME_DIR/config/project-setup"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$1"
  } > "$HOME_DIR/config/project-setup/taskbase.sh"
  chmod 0755 "$HOME_DIR/config/project-setup/taskbase.sh"
}

run_spawn() {
  local id=$1
  shift
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

launched() {
  grep -q "$HOME_DIR/data/$1/launch-brief.md\|$HOME_DIR/data/$1/brief.md" "$LAUNCH_LOG" 2>/dev/null
}

test_absent_hook_changes_nothing() {
  local id=setup-absent-r1 out status
  make_case absent "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn with no project setup script should launch"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the spawn without a setup script did not report success"
  assert_not_contains "$out" "project setup" "a spawn without a setup script mentioned project setup"
  launched "$id" || fail "the spawn without a setup script never sent the agent launch"
  [ -z "$(git -C "$POOL_DIR" status --porcelain)" ] || fail "the spawn without a setup script changed the worktree"
  pass "an absent project setup script leaves the spawn unchanged"
}

test_hook_runs_in_worktree_before_launch() {
  local id kind first expected_wt setup_line
  for kind in ship scout; do
    id="setup-runs-$kind-r1"
    make_case "runs-$kind" "$id"
    # The hook records its view into the same log the fake terminal appends
    # launch lines to, so line order proves it ran before the launch was sent.
    install_hook '
exclude=$(git rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$exclude")"
echo "/bmad-submodule/" >> "$exclude"
mkdir -p bmad-submodule && echo installed > bmad-submodule/marker
echo "SETUP cwd=$(pwd -P) task=$FM_TASK_ID kind=$FM_TASK_KIND project=$FM_PROJECT dir=$FM_PROJECT_DIR wt=$FM_WORKTREE" >> "$FM_TEST_SETUP_LOG"
echo "setup says hello"'
    if [ "$kind" = ship ]; then
      out=$(FM_TEST_SETUP_LOG="$LAUNCH_LOG" run_spawn "$id" --mode no-mistakes --yolo off)
    else
      out=$(FM_TEST_SETUP_LOG="$LAUNCH_LOG" run_spawn "$id" --scout)
    fi
    status=$?
    expect_code 0 "$status" "a $kind spawn with a passing setup script should launch"$'\n'"$out"
    assert_contains "$out" "setup says hello" "the setup script's output was not surfaced"
    [ "$(printf '%s\n' "$out" | tail -n 1 | cut -c1-8)" = "spawned " ] \
      || fail "the setup script's output displaced the spawn's final success line"$'\n'"$out"
    launched "$id" || fail "the $kind spawn never sent the agent launch"
    first=$(grep -n . "$LAUNCH_LOG" | grep -v ':SETUP ' | grep "$HOME_DIR/data/$id/" | head -n 1 | cut -d: -f1)
    setup_line=$(grep -n '^SETUP ' "$LAUNCH_LOG" | cut -d: -f1)
    [ -n "$setup_line" ] || fail "the $kind setup script never ran"
    [ "$setup_line" -lt "$first" ] || fail "the $kind setup script ran after the agent launch"$'\n'"$(cat "$LAUNCH_LOG")"
    expected_wt=$(cd "$POOL_DIR" && pwd -P)
    assert_grep "SETUP cwd=$expected_wt task=$id kind=$kind project=taskbase dir=$PROJECT_DIR wt=$POOL_DIR" "$LAUNCH_LOG" \
      "the $kind setup script did not run in the task worktree with its task environment"
    [ -f "$POOL_DIR/bmad-submodule/marker" ] || fail "the $kind setup script's output did not stay in the worktree"
    assert_grep "kind=$kind" "$HOME_DIR/state/$id.meta" "the $kind spawn did not publish its task record"
    pass "a $kind spawn runs the project setup script in the task worktree before launching the agent"
  done
}

test_failing_hook_refuses_launch() {
  local id=setup-fails-r1 out status
  make_case fails "$id"
  install_hook 'echo partial > partial-setup; echo "clone failed" >&2; exit 7'
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose setup script failed still succeeded"
  assert_contains "$out" "project setup script $HOME_DIR/config/project-setup/taskbase.sh exited with status 7" \
    "the refusal did not name the setup script and its exit status"$'\n'"$out"
  assert_contains "$out" "clone failed" "the failing setup script's stderr was not surfaced"
  ! launched "$id" || fail "a failing setup script still let the agent launch"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a failing setup script still published task metadata"
  [ -f "$POOL_DIR/partial-setup" ] || fail "the refused spawn did not leave the worktree for inspection"
  pass "a failing project setup script refuses the launch and leaves the worktree for inspection"
}

test_hung_hook_times_out() {
  local id=setup-hangs-r1 out status
  make_case hangs "$id"
  install_hook 'exec /bin/sleep 30'
  out=$(FM_PROJECT_SETUP_TIMEOUT=1 run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose setup script hung still succeeded"
  assert_contains "$out" "timed out after 1s" "the refusal did not report the setup timeout"$'\n'"$out"
  ! launched "$id" || fail "a hung setup script still let the agent launch"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a hung setup script still published task metadata"
  pass "a project setup script that outlives FM_PROJECT_SETUP_TIMEOUT refuses the launch"
}

test_git_visible_setup_output_refuses_launch() {
  local id=setup-dirty-r1 out status
  make_case dirty "$id"
  install_hook 'echo stray > stray-output'
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a setup script that left git-visible output still launched"
  assert_contains "$out" "left changes git can see" "the refusal did not explain the git-visible output"$'\n'"$out"
  assert_contains "$out" "stray-output" "the refusal did not name the git-visible path"
  ! launched "$id" || fail "git-visible setup output still let the agent launch"
  pass "a project setup script whose output git can see refuses the launch"
}

test_invalid_hook_refuses_before_allocation() {
  local id=setup-invalid-r1 out status
  make_case invalid "$id"
  mkdir -p "$HOME_DIR/config/project-setup"
  printf '#!/bin/sh\ntouch "$FM_WORKTREE/ran"\n' > "$HOME_DIR/config/project-setup/taskbase.sh"
  chmod 0644 "$HOME_DIR/config/project-setup/taskbase.sh"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a non-executable setup script still let the spawn launch"
  assert_contains "$out" "must be an executable regular file" "the refusal did not explain the invalid setup script"$'\n'"$out"
  [ ! -e "$POOL_DIR/ran" ] || fail "the non-executable setup script ran anyway"
  [ ! -s "$LAUNCH_LOG" ] || fail "the invalid setup script refusal still drove the terminal"$'\n'"$(cat "$LAUNCH_LOG")"

  chmod 0755 "$HOME_DIR/config/project-setup/taskbase.sh"
  out=$(FM_PROJECT_SETUP_TIMEOUT=0 run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a zero FM_PROJECT_SETUP_TIMEOUT still let the spawn launch"
  assert_contains "$out" "FM_PROJECT_SETUP_TIMEOUT must be a positive whole number" \
    "the refusal did not explain the invalid timeout"$'\n'"$out"
  [ ! -s "$LAUNCH_LOG" ] || fail "the invalid timeout refusal still drove the terminal"
  pass "an invalid project setup script or timeout refuses before any terminal or worktree work"
}

test_absent_hook_changes_nothing
test_hook_runs_in_worktree_before_launch
test_failing_hook_refuses_launch
test_hung_hook_times_out
test_git_visible_setup_output_refuses_launch
test_invalid_hook_refuses_before_allocation

echo "# all fm-spawn-project-setup tests passed"
