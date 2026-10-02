#!/usr/bin/env bash
# tests/fm-claude-account-lib.test.sh - bin/fm-claude-account-lib.sh slot
# selection: disabled when unconfigured, picks the slot with more measured
# quota-axi allowance, falls back to the last-good slot or the first
# configured slot when nothing is measurable, and refuses a malformed
# config/claude-accounts file.
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
  PATH="$fakebin:$PATH" fm_claude_account_select "$config" "$state" "$BIN"
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

test_single_slot_is_selected() {
  local rec config state fakebin map out status
  rec=$(new_case single)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'only-slot\n' > "$config/claude-accounts"
  add_slot "$fakebin" only-slot tok-only
  printf 'tok-only 50\n' >> "$map"
  out=$(select_slot "$config" "$state" "$fakebin") status=$?
  expect_code 0 "$status" "selection with one measurable slot should succeed"
  assert_equals only-slot "$out" "the one configured slot should be selected"
  assert_equals only-slot "$(cat "$state/.claude-account-last-good")" "a measured selection should record last-good"
  pass "a single configured, measurable slot is selected and recorded as last-good"
}

test_picks_the_slot_with_more_remaining_allowance() {
  local rec config state fakebin map out status
  rec=$(new_case higher)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'low-slot\nhigh-slot\n' > "$config/claude-accounts"
  add_slot "$fakebin" low-slot tok-low
  add_slot "$fakebin" high-slot tok-high
  printf 'tok-low 10\ntok-high 90\n' >> "$map"
  out=$(select_slot "$config" "$state" "$fakebin") status=$?
  expect_code 0 "$status" "selection between two measurable slots should succeed"
  assert_equals high-slot "$out" "the slot with more remaining allowance should win"
  pass "selection picks the configured slot with the most remaining allowance"
}

test_falls_over_once_the_chosen_slot_is_exhausted() {
  local rec config state fakebin map out status
  rec=$(new_case fallover)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'account-a\naccount-b\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-a tok-a
  add_slot "$fakebin" account-b tok-b
  printf 'tok-a 80\ntok-b 20\n' > "$map"
  out=$(select_slot "$config" "$state" "$fakebin")
  assert_equals account-a "$out" "account-a starts with more room and should be chosen first"

  # account-a's session limit is hit: its next reading is exhausted (0%).
  printf 'tok-a 0\ntok-b 20\n' > "$map"
  out=$(select_slot "$config" "$state" "$fakebin")
  assert_equals account-b "$out" "a relaunch after account-a is exhausted should fall over to account-b"
  pass "re-selection at the next launch falls over once the chosen account hits its limit"
}

test_unmeasurable_falls_back_to_last_good() {
  local rec config state fakebin map out status
  rec=$(new_case last-good)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'account-a\naccount-b\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-a tok-a
  add_slot "$fakebin" account-b tok-b
  printf 'tok-a 30\ntok-b 70\n' > "$map"
  select_slot "$config" "$state" "$fakebin" >/dev/null
  assert_equals account-b "$(cat "$state/.claude-account-last-good")" "account-b should be recorded as last-good"

  # Both readings become unmeasurable (e.g. quota-axi itself is unavailable).
  : > "$map"
  out=$(select_slot "$config" "$state" "$fakebin") status=$?
  expect_code 0 "$status" "selection should still succeed when nothing is measurable"
  assert_equals account-b "$out" "with nothing measurable, the recorded last-good slot should be reused"
  pass "selection falls back to the last successfully measured slot when quota-axi cannot measure any slot"
}

test_unmeasurable_with_no_last_good_picks_the_first_configured_slot() {
  local rec config state fakebin map out status
  rec=$(new_case no-last-good)
  IFS='|' read -r config state fakebin map <<EOF
$rec
EOF
  printf 'account-first\naccount-second\n' > "$config/claude-accounts"
  add_slot "$fakebin" account-first tok-first
  add_slot "$fakebin" account-second tok-second
  out=$(select_slot "$config" "$state" "$fakebin") status=$?
  expect_code 0 "$status" "selection should still succeed with no measurable slot and no last-good"
  assert_equals account-first "$out" "with nothing measurable and no last-good, the first configured slot should be used"
  pass "selection falls back to the first configured slot when nothing is measurable and no last-good is recorded"
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
test_single_slot_is_selected
test_picks_the_slot_with_more_remaining_allowance
test_falls_over_once_the_chosen_slot_is_exhausted
test_unmeasurable_falls_back_to_last_good
test_unmeasurable_with_no_last_good_picks_the_first_configured_slot
test_malformed_slot_name_refuses
