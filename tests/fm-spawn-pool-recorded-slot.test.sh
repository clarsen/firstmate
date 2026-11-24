#!/usr/bin/env bash
# A pool slot recorded by another task stays unavailable even when its owner
# record predates slot-owner claims. Drive the public spawn command with a
# fixture pool and terminal; no real fleet records or pool are touched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-recorded-slot)

test_recorded_slot_is_refused() {
  local case_name=$1 marker=$2 field=${3:-worktree} dir home project slot fakebin old new out status before
  dir="$TMP_ROOT/$case_name"
  home="$dir/home"
  project="$dir/project"
  slot="$dir/pool/1/project"
  old=recorded-owner-r1
  new=recorded-new-r1
  fakebin=$(make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$new"
  fm_git_worktree "$project" "$slot" "slot-$case_name"
  printf '{}\n' > "$dir/pool/treehouse-state.json"
  printf '%s=%s\nproject=%s\nkind=scout\n' "$field" "$slot" "$project" \
    > "$home/state/$old.meta"
  printf 'paused [at=1]: fixture worker still owns its copy\n' > "$home/state/$old.status"
  if [ "$marker" = present ]; then
    printf 'task=%s\nhome=%s\n' "$old" "$home" > "$dir/pool/1/.fm-slot-owner"
  fi
  before=$(git -C "$slot" rev-parse HEAD)

  out=$(FM_FAKE_LAUNCH_LOG="$dir/launch" \
    fm_test_run_spawn "$home" "$slot" "$fakebin" "$new" "$project" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn reused another task's recorded slot ($marker claim)"$'\n'"$out"
  assert_contains "$out" "$old" "refusal did not identify the recorded owner"$'\n'"$out"
  [ ! -s "$dir/launch" ] || fail "spawn launched a worker in another task's slot"
  [ ! -e "$home/state/$new.meta" ] || fail "spawn published a second owner for one slot"
  [ "$(git -C "$slot" rev-parse HEAD)" = "$before" ] || fail "spawn changed the recorded owner's HEAD"
  if [ "$marker" = present ]; then
    grep -Fxq "task=$old" "$dir/pool/1/.fm-slot-owner" \
      || fail "spawn replaced the recorded owner's slot claim"
  else
    [ ! -e "$dir/pool/1/.fm-slot-owner" ] \
      || fail "spawn wrote a claim into a legacy recorded slot"
  fi
  pass "spawn refuses a slot recorded by another task ($field, $marker claim)"
}

test_recorded_slot_is_refused legacy absent
test_recorded_slot_is_refused claimed present
test_recorded_slot_is_refused member absent member.notes.worktree

echo '# all fm-spawn-pool-recorded-slot tests passed'
