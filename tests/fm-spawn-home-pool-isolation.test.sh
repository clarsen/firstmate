#!/usr/bin/env bash
# Regression tests for per-home Treehouse pools.
#
# Treehouse keys a pool only by a clone's directory name and origin, so a main
# home and a secondmate home that each clone one origin into projects/<name>
# used to share one pool, and the secondmate's spawn was handed a worktree of
# the main home's clone. These tests drive the real spawn and teardown paths and
# prove each home draws copies only of its own clone:
#   - a main home types plain `treehouse get`, a secondmate home types
#     `treehouse --root <its own pool root> get`, and an unusable home marker
#     refuses before any endpoint exists;
#   - a copy of another clone of the same origin is never adopted;
#   - with the real treehouse binary (skipped when absent), two homes, one
#     origin get distinct pools of their own clones, and teardown returns each
#     copy to the pool it came from;
#   - with the real treehouse binary, retiring a secondmate removes its own
#     pool (refusing, unforced, while a copy there is still leased), so a
#     re-seed with the same id and home path spawns a working copy.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-home-pool-isolation)
TEARDOWN="$ROOT/bin/fm-teardown.sh"
# Both homes run as one user, so they share one HOME and Treehouse's default
# root under it, exactly as a real main home and its secondmates do.
USER_HOME="$TMP_ROOT/user-home"
mkdir -p "$USER_HOME"

# make_origin <dir>: a bare origin with one commit on main.
make_origin() {
  local origin=$1 seed="$1.seed"
  git init --quiet -b main "$seed"
  printf 'base\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$seed" "$origin"
}

# make_home <home> [secondmate-id]: a spawn-ready home whose clone of $ORIGIN
# lives at projects/proj, marked as a secondmate home when an id is given.
make_home() {
  local home=$1 mate=${2-}
  fm_test_spawn_home "$home" codex
  [ -z "$mate" ] || printf '%s\n' "$mate" > "$home/.fm-secondmate-home"
  git clone --quiet "file://$ORIGIN" "$home/projects/proj"
}

# run_spawn <home> <pane-path> <fakebin> <id>: a scout spawn from <home>'s
# clone, as fm_test_run_spawn does it but under the shared USER_HOME.
run_spawn() {
  local home=$1 pane=$2 fakebin=$3 id=$4
  fm_test_spawn_brief "$home" "$id"
  env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home/projects/proj" --scout 2>&1
}

run_teardown() {
  local home=$1 fakebin=$2 id=$3
  env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" HOME="$USER_HOME" \
    FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1
}

common_dir() {
  local dir
  dir=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return 1
  (cd "$dir" && pwd -P)
}

# own_copy <home> <path>: a detached worktree of <home>'s clone, printed, for a
# fake pane to report as the copy Treehouse handed out.
own_copy() {
  git -C "$1/projects/proj" worktree add --quiet --detach "$2" HEAD
  printf '%s\n' "$2"
}

# The --root argument a pane log's `treehouse ... get` line carries, or empty.
typed_root() {
  sed -n "s/^treehouse --root '\\(.*\\)' get\$/\\1/p" "$1"
}

ORIGIN="$TMP_ROOT/proj.origin.git"
make_origin "$ORIGIN"

test_each_home_types_its_own_pool_root() {
  local dir="$TMP_ROOT/typed" fakebin main sm other out status root other_root
  fakebin=$(make_spawn_fakebin "$dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  main="$dir/main-home"; sm="$dir/mate-home"; other="$dir/other-mate-home"
  make_home "$main"
  make_home "$sm" evo
  make_home "$other" evo

  out=$(FM_FAKE_PANE_LOG="$dir/main.pane" run_spawn "$main" "$(own_copy "$main" "$dir/main-wt")" "$fakebin" typed-main-r1)
  status=$?
  expect_code 0 "$status" "a main home's spawn should launch"$'\n'"$out"
  grep -Fxq 'treehouse get' "$dir/main.pane" \
    || fail "a main home did not type plain treehouse get"$'\n'"$(cat "$dir/main.pane" 2>/dev/null)"$'\n'"$out"

  out=$(FM_FAKE_PANE_LOG="$dir/sm.pane" run_spawn "$sm" "$(own_copy "$sm" "$dir/sm-wt")" "$fakebin" typed-sm-r1)
  status=$?
  expect_code 0 "$status" "a secondmate home's spawn should launch"$'\n'"$out"
  root=$(typed_root "$dir/sm.pane")
  [ -n "$root" ] || fail "a secondmate home did not type treehouse get with its own root"$'\n'"$(cat "$dir/sm.pane" 2>/dev/null)"$'\n'"$out"
  case "$root" in
    "$USER_HOME/.treehouse/home-pools/evo-"*) ;;
    *) fail "a secondmate home's pool root is not under \$HOME/.treehouse/home-pools/<mate-id>-: $root" ;;
  esac
  case "$root/" in
    "$sm"/*|"$main"/*) fail "a secondmate home's pool root lies inside a firstmate home: $root" ;;
  esac

  out=$(FM_FAKE_PANE_LOG="$dir/other.pane" run_spawn "$other" "$(own_copy "$other" "$dir/other-wt")" "$fakebin" typed-other-r1)
  other_root=$(typed_root "$dir/other.pane")
  [ -n "$other_root" ] || fail "a second secondmate home did not type its own root"$'\n'"$out"
  [ "$other_root" != "$root" ] \
    || fail "two secondmate homes with one mate id share a pool root: $root"
  pass "a main home keeps Treehouse's root, and each secondmate home types a pool root of its own outside every home"
}

test_unusable_home_marker_refuses_before_any_endpoint() {
  local dir="$TMP_ROOT/bad-marker" fakebin home out status
  fakebin=$(make_spawn_fakebin "$dir/fake")
  home="$dir/mate-home"
  make_home "$home"
  printf 'not a valid id!\n' > "$home/.fm-secondmate-home"
  out=$(FM_FAKE_PANE_LOG="$dir/pane" FM_FAKE_LAUNCH_LOG="$dir/launch" \
    run_spawn "$home" "$dir/none" "$fakebin" bad-marker-r1)
  status=$?
  [ "$status" -ne 0 ] || fail "a home with an unusable secondmate marker still spawned"$'\n'"$out"
  assert_contains "$out" "could not resolve this home's own Treehouse pool root" \
    "the refusal did not name the unresolved pool root"$'\n'"$out"
  [ ! -s "$dir/pane" ] && [ ! -s "$dir/launch" ] \
    || fail "the unresolved pool root refusal still drove the terminal"
  [ ! -e "$home/state/bad-marker-r1.meta" ] || fail "the unresolved pool root refusal published a task record"
  pass "an unusable secondmate marker refuses before any endpoint rather than fall back to the shared pool"
}

test_copy_of_another_clone_is_never_adopted() {
  local dir="$TMP_ROOT/foreign" fakebin main sm foreign out status
  fakebin=$(make_spawn_fakebin "$dir/fake")
  # The settle wait polls an unchanging fake pane; its duration is not under test.
  fm_test_fake_sleep_noop "$fakebin"
  main="$dir/main-home"; sm="$dir/mate-home"
  make_home "$main"
  make_home "$sm" evo
  foreign="$dir/pool/1/proj"
  mkdir -p "$dir/pool/1"
  git -C "$main/projects/proj" worktree add --quiet --detach "$foreign" HEAD
  out=$(FM_FAKE_LAUNCH_LOG="$dir/launch" run_spawn "$sm" "$foreign" "$fakebin" foreign-r1)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn adopted a worktree of the main home's clone"$'\n'"$out"
  assert_contains "$out" "worktree of another clone" \
    "the refusal did not say the copy belongs to another clone"$'\n'"$out"
  [ ! -s "$dir/launch" ] || fail "a copy of another clone still received the agent launch"
  [ ! -e "$sm/state/foreign-r1.meta" ] || fail "a copy of another clone was published as the task's worktree"
  pass "a copy of another clone of the same origin is refused, never adopted"
}

# --- real treehouse ---------------------------------------------------------

# A fake pane whose shell runs the `treehouse ... get` line spawn types, from the
# directory the window opened in, and then reports the copy it landed in. A fake
# pane has no interactive subshell to hold Treehouse's process lease, so the
# line runs as a durable lease instead; teardown's `treehouse return --force`
# releases either kind.
make_real_pool_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# Teardown drives the same stub with no pane state; it then answers like the
# ordinary spawn stub: every command succeeds and the pane reports no path.
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
    shift
    if [ "${1:-}" = -t ]; then shift 2; fi
    case "${1:-}" in
      'treehouse '*)
        if copy=$(cd "$(cat "$state")" && eval "$1 --lease --lease-holder fake-pane" 2>>"$state.log"); then
          printf '%s\n' "$copy" > "$state"
        fi
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# The status Treehouse itself reports for <copy> in the pool under <root>
# (empty for Treehouse's default root).
pool_slot_status() {  # <clone> <root> <copy>
  local clone=$1 root=$2 copy=$3
  (
    cd "$clone" || exit 1
    if [ -n "$root" ]; then
      env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME HOME="$USER_HOME" treehouse --root "$root" status --json
    else
      env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME HOME="$USER_HOME" treehouse status --json
    fi
  ) | jq -r --arg p "$copy" '.[] | select(.path == $p) | .status'
}

meta_worktree() {
  sed -n 's/^worktree=//p' "$1"
}

test_real_pools_are_per_home_and_teardown_returns_home() {
  local dir="$TMP_ROOT/real" fakebin main sm main_clone sm_clone out status
  local probe_a probe_b main_wt sm_wt sm_wt2 sm_root
  if ! command -v treehouse >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf '# real-treehouse cases not run: treehouse or jq is not installed\n'
    return 0
  fi
  fakebin=$(make_real_pool_fakebin "$dir/fake")
  main="$dir/main-home"; sm="$dir/mate-home"
  make_home "$main"
  make_home "$sm" evo
  main_clone="$main/projects/proj"; sm_clone="$sm/projects/proj"

  # The collision this guards against is real in this fixture: with no root of
  # its own, the secondmate's clone is handed the copy of the main home's clone.
  probe_a=$(cd "$main_clone" && env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME HOME="$USER_HOME" \
    treehouse get --lease 2>/dev/null) || fail "could not lease a probe copy from the main home's clone"
  (cd "$main_clone" && HOME="$USER_HOME" treehouse return --force "$probe_a" >/dev/null 2>&1) \
    || fail "could not return the probe copy"
  probe_b=$(cd "$sm_clone" && env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME HOME="$USER_HOME" \
    treehouse get --lease 2>/dev/null) || fail "could not lease a probe copy from the secondmate's clone"
  [ "$probe_b" = "$probe_a" ] && [ "$(common_dir "$probe_b")" = "$(common_dir "$main_clone")" ] \
    || fail "fixture precondition: a shared default pool did not hand the secondmate the main home's copy ($probe_a vs $probe_b)"
  (cd "$sm_clone" && HOME="$USER_HOME" treehouse return --force "$probe_b" >/dev/null 2>&1) \
    || fail "could not return the second probe copy"

  out=$(FM_FAKE_PANE_STATE="$dir/main.pane" run_spawn "$main" "$dir/none" "$fakebin" real-main-r1)
  status=$?
  expect_code 0 "$status" "the main home's spawn should launch from the real pool"$'\n'"$out"$'\n'"$(cat "$dir/main.pane.log" 2>/dev/null)"
  main_wt=$(meta_worktree "$main/state/real-main-r1.meta")
  [ "$(common_dir "$main_wt")" = "$(common_dir "$main_clone")" ] \
    || fail "the main home's copy $main_wt is not a worktree of its own clone"
  [ "$main_wt" = "$probe_a" ] \
    || fail "the main home no longer draws from its existing default pool: $main_wt (existing copy $probe_a)"

  out=$(FM_FAKE_PANE_STATE="$dir/sm.pane" run_spawn "$sm" "$dir/none" "$fakebin" real-sm-r1)
  status=$?
  expect_code 0 "$status" "the secondmate's spawn should launch from its own pool"$'\n'"$out"$'\n'"$(cat "$dir/sm.pane.log" 2>/dev/null)"
  sm_wt=$(meta_worktree "$sm/state/real-sm-r1.meta")
  [ "$(common_dir "$sm_wt")" = "$(common_dir "$sm_clone")" ] \
    || fail "the secondmate's copy $sm_wt is not a worktree of its own clone"
  [ "$(dirname "$(dirname "$sm_wt")")" != "$(dirname "$(dirname "$main_wt")")" ] \
    || fail "two homes' clones of one origin still share a pool: $sm_wt and $main_wt"
  sm_root=${sm_wt%%/.treehouse/proj-*}
  [ "$sm_root" != "$sm_wt" ] || fail "cannot locate the secondmate's pool root from $sm_wt"

  out=$(run_teardown "$sm" "$fakebin" real-sm-r1)
  status=$?
  expect_code 0 "$status" "the secondmate task's teardown should return its copy"$'\n'"$out"
  [ "$(pool_slot_status "$sm_clone" "$sm_root" "$sm_wt")" = available ] \
    || fail "teardown did not return the secondmate's copy to its own pool"$'\n'"$out"
  [ "$(pool_slot_status "$main_clone" '' "$main_wt")" = leased ] \
    || fail "the secondmate's teardown disturbed the main home's copy"

  out=$(FM_FAKE_PANE_STATE="$dir/sm2.pane" run_spawn "$sm" "$dir/none" "$fakebin" real-sm-r2)
  status=$?
  expect_code 0 "$status" "the secondmate's next spawn should launch"$'\n'"$out"
  sm_wt2=$(meta_worktree "$sm/state/real-sm-r2.meta")
  [ "$sm_wt2" = "$sm_wt" ] \
    || fail "the secondmate's next spawn did not reuse its own returned copy: $sm_wt2 (returned $sm_wt)"

  out=$(run_teardown "$main" "$fakebin" real-main-r1)
  status=$?
  expect_code 0 "$status" "the main task's teardown should return its copy"$'\n'"$out"
  [ "$(pool_slot_status "$main_clone" '' "$main_wt")" = available ] \
    || fail "teardown did not return the main home's copy to the default pool"
  [ "$(pool_slot_status "$sm_clone" "$sm_root" "$sm_wt2")" = leased ] \
    || fail "the main home's teardown disturbed the secondmate's copy"
  out=$(run_teardown "$sm" "$fakebin" real-sm-r2)
  status=$?
  expect_code 0 "$status" "the secondmate's second teardown should return its copy"$'\n'"$out"
  pass "with real Treehouse, two homes' clones of one origin draw distinct pools and teardown returns each copy to its own pool"
}

# run_mate <main-home> <fakebin> <cmd> <args...>: a secondmate lifecycle command
# run from the main home under the shared USER_HOME.
run_mate() {
  local main=$1 fakebin=$2 cmd=$3 dir
  dir=${main%/*}
  shift 3
  env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME \
    FM_ROOT_OVERRIDE='' FM_HOME="$main" HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_TMUX_LOG="$dir/mate-tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/mate-pane.txt" \
    PATH="$fakebin:$PATH" "$ROOT/bin/$cmd" "$@" 2>&1
}

# seed_and_launch_mate <main> <home> <fakebin>: seed secondmate evo at <home>
# from <main>'s clone and launch it, leaving <home> spawn-ready.
seed_and_launch_mate() {
  local main=$1 home=$2 fakebin=$3 out
  [ -f "$main/data/evo/brief.md" ] \
    || FM_HOME="$main" FM_SECONDMATE_CHARTER='evolution charter' "$ROOT/bin/fm-brief.sh" evo --secondmate proj >/dev/null \
    || fail "could not scaffold the secondmate charter"
  out=$(run_mate "$main" "$fakebin" fm-home-seed.sh evo "$home" proj) \
    || fail "seeding secondmate evo failed"$'\n'"$out"
  out=$(run_mate "$main" "$fakebin" fm-spawn.sh evo "$home" codex --secondmate) \
    || fail "launching secondmate evo failed"$'\n'"$out"
  fm_test_spawn_home "$home" codex
}

test_real_retired_mate_pool_is_removed_and_reseed_spawns() {
  local dir="$TMP_ROOT/reseed" fakebin matebin main sm clone root out status wt probe
  if ! command -v treehouse >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf '# real-treehouse retire/re-seed case not run: treehouse or jq is not installed\n'
    return 0
  fi
  fakebin=$(make_real_pool_fakebin "$dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  # Secondmate lifecycle commands drive the ordinary fake tmux, but the real
  # treehouse, so retirement's pool destroy is the real one.
  matebin=$(make_fake_tmux "$dir/mate-fake")
  rm -f "$matebin/treehouse"
  printf '❯\n' > "$dir/mate-pane.txt"
  main="$dir/main-home"; sm="$dir/evo-home"
  make_home "$main"
  printf -- '- proj [direct-PR] - evolution project (added 2026-09-23)\n' > "$main/data/projects.md"

  seed_and_launch_mate "$main" "$sm" "$matebin"
  clone="$sm/projects/proj"
  out=$(FM_FAKE_PANE_STATE="$dir/sm1.pane" run_spawn "$sm" "$dir/none" "$fakebin" reseed-r1)
  status=$?
  expect_code 0 "$status" "the first secondmate's spawn should launch"$'\n'"$out"$'\n'"$(cat "$dir/sm1.pane.log" 2>/dev/null)"
  wt=$(meta_worktree "$sm/state/reseed-r1.meta")
  root=${wt%%/.treehouse/proj-*}
  [ "$root" != "$wt" ] && [ -d "$root" ] || fail "cannot locate the secondmate's pool root from $wt"
  out=$(run_teardown "$sm" "$fakebin" reseed-r1)
  expect_code 0 "$?" "the first secondmate's task teardown should return its copy"$'\n'"$out"

  # A copy still leased in the home's pool stops the retirement, unforced.
  probe=$(cd "$clone" && env -u TREEHOUSE_ROOT -u XDG_CONFIG_HOME HOME="$USER_HOME" \
    treehouse --root "$root" get --lease --lease-holder probe 2>/dev/null) \
    || fail "could not lease a probe copy from the secondmate's pool"
  out=$(run_mate "$main" "$matebin" fm-teardown.sh evo)
  status=$?
  [ "$status" -ne 0 ] || fail "retirement removed a home whose pool still held a leased copy"$'\n'"$out"
  assert_contains "$out" "retirement stopped" "the refusal did not stop the retirement"$'\n'"$out"
  assert_contains "$out" "leased" "the refusal did not carry Treehouse's skip output"$'\n'"$out"
  [ -d "$probe" ] && [ -d "$clone" ] && [ -f "$main/state/evo.meta" ] \
    || fail "a refused retirement still removed the leased copy, the home's clone, or its record"
  (cd "$clone" && HOME="$USER_HOME" treehouse return --force "$probe" >/dev/null 2>&1) \
    || fail "could not return the probe copy"

  out=$(run_mate "$main" "$matebin" fm-teardown.sh evo)
  expect_code 0 "$?" "retiring secondmate evo should succeed once its pool holds no live copy"$'\n'"$out"
  [ ! -e "$sm" ] || fail "retirement left the secondmate home"
  [ ! -e "$root" ] || fail "retirement left the secondmate's own pool root: $(find "$root" -maxdepth 3 2>/dev/null)"

  seed_and_launch_mate "$main" "$sm" "$matebin"
  out=$(FM_FAKE_PANE_STATE="$dir/sm2.pane" run_spawn "$sm" "$dir/none" "$fakebin" reseed-r2)
  status=$?
  expect_code 0 "$status" "the re-seeded secondmate's spawn should get a working copy"$'\n'"$out"$'\n'"$(cat "$dir/sm2.pane.log" 2>/dev/null)"
  wt=$(meta_worktree "$sm/state/reseed-r2.meta")
  [ "$(common_dir "$wt")" = "$(common_dir "$clone")" ] \
    || fail "the re-seeded secondmate's copy $wt is not a worktree of its new clone"
  out=$(run_teardown "$sm" "$fakebin" reseed-r2)
  expect_code 0 "$?" "the re-seeded secondmate's task teardown should return its copy"$'\n'"$out"
  pass "retiring a secondmate removes its own pool, refusing unforced while a copy is leased, and a re-seed at the same id and path spawns a working copy"
}

test_each_home_types_its_own_pool_root
test_unusable_home_marker_refuses_before_any_endpoint
test_copy_of_another_clone_is_never_adopted
test_real_pools_are_per_home_and_teardown_returns_home
test_real_retired_mate_pool_is_removed_and_reseed_spawns

echo "# all fm-spawn-home-pool-isolation tests passed"
