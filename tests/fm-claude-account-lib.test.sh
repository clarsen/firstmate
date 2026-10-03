#!/usr/bin/env bash
# tests/fm-claude-account-lib.test.sh - bin/fm-claude-account-lib.sh slot
# selection: disabled when unconfigured, skips slots carrying an unexpired
# `fm-claude-account.sh mark-limited` mark, prefers more measured quota-axi
# allowance only as a tiebreaker, still selects when no slot is measurable
# (the real setup-token case), picks the soonest-expiring slot when all are
# limited, and refuses a malformed config/claude-accounts file.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/fm-claude-account-fakes.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-claude-account-fakes.sh"
# shellcheck source=bin/fm-claude-account-lib.sh
. "$ROOT/bin/fm-claude-account-lib.sh"

BIN="$ROOT/bin/fm-claude-account.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-account-lib)

# new_case <name> builds a fresh config dir, state dir, fakebin (with fake
# security + quota-axi), and the quota map file. Echoes
# "<config-dir>|<state-dir>|<fakebin>|<map-file>".
new_case() {
  local name=$1 dir fakebin store map config state
  dir="$TMP_ROOT/$name"
  config="$dir/config"
  state="$dir/state"
  mkdir -p "$config" "$state"
  fakebin=$(fm_fakebin "$dir")
  store="$dir/keychain"
  map="$dir/quota-map"
  : > "$map"
  fm_claude_account_fake_security "$fakebin" "$store"
  fm_claude_account_fake_quota_axi "$fakebin" "$map"
  printf '%s|%s|%s|%s\n' "$config" "$state" "$fakebin" "$map"
}

add_slot() {  # <fakebin> <slot> <token>
  local fakebin=$1 slot=$2 token=$3
  printf '%s\n' "$token" | PATH="$fakebin:$PATH" "$BIN" add "$slot" >/dev/null
}

select_slot() {  # <config> <state> <fakebin>
  local config=$1 state=$2 fakebin=$3
  PATH="$fakebin:$PATH" fm_claude_account_select "$config" "$(dirname "$state")" "$state" "$BIN"
}

test_disabled_when_unconfigured() {
  local rec config state fakebin map out status
  rec=$(new_case disabled)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  out=$(select_slot "$config" "$state" "$fakebin") status=$?
  expect_code 0 "$status" "selection with no config/claude-accounts should succeed"
  assert_equals "" "$out" "an absent config/claude-accounts should select nothing"
  pass "selection is a no-op when config/claude-accounts is absent"
}

mark() {  # <state> <fakebin> <slot> [--until <iso8601>]
  local state=$1 fakebin=$2
  shift 2
  FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" "$BIN" mark-limited "$@" >/dev/null
}

test_unmeasurable_setup_tokens_select_the_first_configured_slot() {
  local rec config state fakebin map out status
  rec=$(new_case unmeasurable)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'account-first\naccount-second\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-first tok-first
  add_slot "$fakebin" account-second tok-second
  out=$(select_slot "$config" "$state" "$fakebin") status=$?
  expect_code 0 "$status" "selection should succeed when quota-axi cannot read any setup token"
  assert_equals account-first "$out" "with no reading and no limited mark, the first configured slot should be used"
  pass "unmeasurable setup tokens still select the first configured slot"
}

test_measured_allowance_breaks_the_tie_among_eligible_slots() {
  local rec config state fakebin map out
  rec=$(new_case higher)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'low-slot\nhigh-slot\n' > "$config/claude-accounts"
  add_slot "$fakebin" low-slot tok-low
  add_slot "$fakebin" high-slot tok-high
  printf 'tok-low 10\ntok-high 90\n' >> "$map"
  out=$(select_slot "$config" "$state" "$fakebin")
  assert_equals high-slot "$out" "the slot with more remaining allowance should win when readings exist"
  pass "measured allowance, when available, prefers the eligible slot with more room"
}

test_limited_slot_is_skipped() {
  local rec config state fakebin map out
  rec=$(new_case limited)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'account-a\naccount-b\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-a tok-a
  add_slot "$fakebin" account-b tok-b
  printf 'tok-a 90\n' >> "$map"
  mark "$state" "$fakebin" account-a
  out=$(select_slot "$config" "$state" "$fakebin")
  assert_equals account-b "$out" "a limited slot should be skipped even when it measures more room"
  pass "a slot marked limited is skipped in favor of the other slot"
}

test_expired_mark_no_longer_excludes() {
  local rec config state fakebin map out
  rec=$(new_case expired)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'account-a\naccount-b\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-a tok-a
  add_slot "$fakebin" account-b tok-b
  mark "$state" "$fakebin" account-a --until 2000-01-01T00:00:00Z
  out=$(select_slot "$config" "$state" "$fakebin")
  assert_equals account-a "$out" "an expired limited mark should not exclude its slot"
  pass "an expired limited mark no longer excludes its slot"
}

test_all_limited_selects_the_soonest_to_expire() {
  local rec config state fakebin map out status err
  rec=$(new_case all-limited)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'account-a\naccount-b\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-a tok-a
  add_slot "$fakebin" account-b tok-b
  mark "$state" "$fakebin" account-a --until 2999-06-01T00:00:00Z
  mark "$state" "$fakebin" account-b --until 2999-01-01T00:00:00Z
  err="$TMP_ROOT/all-limited/select.stderr"
  out=$(select_slot "$config" "$state" "$fakebin" 2>"$err") status=$?
  expect_code 0 "$status" "selection should still succeed when every slot is limited"
  assert_equals account-b "$out" "the slot whose mark expires soonest should be chosen"
  assert_contains "$(cat "$err")" "every configured Claude account slot is marked limited" "stderr should explain the all-limited choice"
  assert_contains "$(cat "$err")" "account-b" "stderr should name the chosen slot"
  pass "with every slot limited, selection picks the soonest-to-expire slot and explains why"
}

test_clear_limited_makes_a_slot_selectable_again() {
  local rec config state fakebin map out
  rec=$(new_case cleared)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'account-a\naccount-b\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-a tok-a
  add_slot "$fakebin" account-b tok-b
  mark "$state" "$fakebin" account-a
  assert_equals account-b "$(select_slot "$config" "$state" "$fakebin")" "account-a should be skipped while marked"
  FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" "$BIN" clear-limited account-a >/dev/null
  out=$(select_slot "$config" "$state" "$fakebin")
  assert_equals account-a "$out" "clear-limited should make account-a selectable again"
  pass "clear-limited makes a slot selectable again"
}

test_mark_limited_rejects_a_malformed_until() {
  local rec config state fakebin map out status
  rec=$(new_case bad-until)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  out=$(FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" "$BIN" mark-limited account-a --until tomorrow 2>&1) status=$?
  [ "$status" -ne 0 ] || fail "mark-limited should reject a non-ISO-8601 --until: $out"
  [ ! -e "$state/.claude-account-limited-account-a" ] || fail "a rejected mark-limited must not write a mark"
  pass "mark-limited rejects a malformed --until without writing a mark"
}

test_measured_exhausted_slot_loses_to_an_unmeasured_eligible_slot() {
  local rec config state fakebin map out
  rec=$(new_case exhausted-vs-unmeasured)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'account-a\naccount-b\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-a tok-a
  add_slot "$fakebin" account-b tok-b
  printf 'tok-b 0\n' >> "$map"
  out=$(select_slot "$config" "$state" "$fakebin")
  assert_equals account-a "$out" "a slot measured at 0% must not beat an unmeasured eligible slot"
  pass "a measured-exhausted slot loses to an eligible slot with no reading"
}

test_measured_exhausted_slot_listed_first_still_loses() {
  local rec config state fakebin map out
  rec=$(new_case exhausted-first)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'account-a\naccount-b\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-a tok-a
  add_slot "$fakebin" account-b tok-b
  printf 'tok-a 0\n' >> "$map"
  out=$(select_slot "$config" "$state" "$fakebin")
  assert_equals account-b "$out" "a slot measured at 0% listed first must not win over a later unmeasured slot"
  printf 'tok-b 0\n' >> "$map"
  out=$(select_slot "$config" "$state" "$fakebin")
  assert_equals account-a "$out" "when every unmarked slot measures 0%, the first of them is still selected"
  pass "a measured-exhausted slot loses regardless of file order and is only a last resort"
}

test_unreadable_slot_listed_first_loses_to_a_readable_slot() {
  local rec config state fakebin map out
  rec=$(new_case unreadable-first)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'missing-slot\naccount-b\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-b tok-b
  out=$(select_slot "$config" "$state" "$fakebin")
  assert_equals account-b "$out" "a slot with no readable token must not beat a later readable slot"
  pass "a slot whose token cannot be read loses to a readable unmarked slot"
}

test_unconfigured_selection_never_resolves_the_parent_chain() {
  local rec config state fakebin map out err
  rec=$(new_case unconfigured-broken-parent)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$(dirname "$state")/.fm-secondmate-parent"
  err="$TMP_ROOT/unconfigured-broken-parent/select.stderr"
  out=$(select_slot "$config" "$state" "$fakebin" 2>"$err")
  assert_equals "" "$out" "an absent config/claude-accounts should select nothing"
  assert_equals "" "$(cat "$err")" "an unconfigured home must not print a parent-resolution note"
  pass "selection with the feature off never walks the parent chain or prints its note"
}

test_malformed_slot_name_refuses() {
  local rec config state fakebin map out status
  rec=$(new_case malformed)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'ok-slot\nbad slot name\n' > "$config/claude-accounts"
  out=$(select_slot "$config" "$state" "$fakebin" 2>&1) status=$?
  [ "$status" -ne 0 ] || fail "a malformed slot name in config/claude-accounts should refuse: $out"
  assert_contains "$out" "bad slot name" "the refusal should name the offending entry"
  pass "a malformed config/claude-accounts entry refuses selection instead of guessing"
}

test_disabled_when_unconfigured
test_unmeasurable_setup_tokens_select_the_first_configured_slot
test_measured_allowance_breaks_the_tie_among_eligible_slots
test_limited_slot_is_skipped
test_expired_mark_no_longer_excludes
test_all_limited_selects_the_soonest_to_expire
test_clear_limited_makes_a_slot_selectable_again
test_mark_limited_rejects_a_malformed_until
test_measured_exhausted_slot_loses_to_an_unmeasured_eligible_slot
test_measured_exhausted_slot_listed_first_still_loses
test_unreadable_slot_listed_first_loses_to_a_readable_slot
test_unconfigured_selection_never_resolves_the_parent_chain
test_malformed_slot_name_refuses
