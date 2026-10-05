#!/usr/bin/env bash
# tests/fm-claude-account.test.sh - bin/fm-claude-account.sh Keychain slot
# management: add/get/list/remove against a fake `security`, slot-name
# validation, and that no token value ever reaches stdout/stderr except
# `get`'s single-line success output.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/fm-claude-account-fakes.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-claude-account-fakes.sh"

BIN="$ROOT/bin/fm-claude-account.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-account)
SECRET='sk-ant-oat01-this-is-a-fake-secret-value'

new_case() {
  local name=$1 dir fakebin store
  dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$dir")
  store="$dir/keychain"
  fm_claude_account_fake_security "$fakebin" "$store"
  printf '%s|%s\n' "$fakebin" "$store"
}

run_bin() {  # <fakebin> <args...>
  local fakebin=$1
  shift
  PATH="$fakebin:$PATH" "$BIN" "$@"
}

test_add_then_get_roundtrips() {
  local rec fakebin store out status
  rec=$(new_case add-get)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  out=$(printf '%s\n' "$SECRET" | run_bin "$fakebin" add work-a) status=$?
  expect_code 0 "$status" "add should succeed: $out"
  assert_contains "$out" "stored slot 'work-a'" "add should confirm the slot name, never the token"
  assert_not_contains "$out" "$SECRET" "add's own output must never contain the token"

  out=$(run_bin "$fakebin" get work-a) status=$?
  expect_code 0 "$status" "get should succeed for a stored slot: $out"
  assert_equals "$SECRET" "$out" "get must return exactly the stored token and nothing else"
  pass "add then get round-trips the stored token exactly"
}

test_add_rejects_empty_or_whitespace_token() {
  local rec fakebin store out status
  rec=$(new_case add-empty)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  out=$(printf '\n' | run_bin "$fakebin" add work-a 2>&1) status=$?
  [ "$status" -ne 0 ] || fail "add with an empty token should fail: $out"
  out=$(run_bin "$fakebin" get work-a 2>&1) status=$?
  [ "$status" -ne 0 ] || fail "get should fail for a slot that was never stored"

  out=$(printf 'has space here\n' | run_bin "$fakebin" add work-b 2>&1) status=$?
  [ "$status" -ne 0 ] || fail "add with a whitespace-containing token should fail: $out"
  pass "add refuses an empty or whitespace-containing token"
}

test_get_missing_slot_names_the_slot_only() {
  local rec fakebin store out status
  rec=$(new_case get-missing)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  out=$(run_bin "$fakebin" get never-added 2>&1) status=$?
  [ "$status" -ne 0 ] || fail "get on a never-stored slot should fail"
  assert_contains "$out" "never-added" "the failure should name the slot"
  pass "get on a missing slot fails naming only the slot"
}

test_invalid_slot_names_are_rejected() {
  local rec fakebin store out status slot
  rec=$(new_case invalid-slot)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  for slot in '' 'has space' 'slash/es' '-leading-dash'; do
    out=$(printf '%s\n' "$SECRET" | run_bin "$fakebin" add "$slot" 2>&1) status=$?
    [ "$status" -ne 0 ] || fail "add should reject invalid slot name '$slot': $out"
  done
  pass "add rejects slot names outside the bare letters/digits/-/_ charset"
}

test_remove_then_get_fails() {
  local rec fakebin store out status
  rec=$(new_case remove)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  printf '%s\n' "$SECRET" | run_bin "$fakebin" add work-a >/dev/null
  out=$(run_bin "$fakebin" remove work-a) status=$?
  expect_code 0 "$status" "remove should succeed: $out"
  out=$(run_bin "$fakebin" get work-a 2>&1) status=$?
  [ "$status" -ne 0 ] || fail "get after remove should fail"
  pass "remove deletes the slot so a later get fails"
}

test_remove_missing_slot_is_not_an_error() {
  local rec fakebin store out status
  rec=$(new_case remove-missing)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  out=$(run_bin "$fakebin" remove never-stored) status=$?
  expect_code 0 "$status" "removing a slot that was never stored should still succeed: $out"
  pass "remove is idempotent for a slot that was never stored"
}

test_list_reports_present_and_missing_without_values() {
  local rec fakebin store home out status
  rec=$(new_case list)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  home="$TMP_ROOT/list/home"
  mkdir -p "$home/config"
  printf 'work-a\n# a comment\n\nwork-b\n' > "$home/config/claude-accounts"
  printf '%s\n' "$SECRET" | run_bin "$fakebin" add work-a >/dev/null

  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$BIN" list)
  assert_contains "$out" "work-a: present" "a stored slot should list as present"
  assert_contains "$out" "work-b: missing" "an unstored but configured slot should list as missing"
  assert_not_contains "$out" "$SECRET" "list must never print a token value"
  pass "list reports present/missing for every configured slot without any token value"
}

test_add_get_never_leak_the_secret_on_any_stream() {
  local rec fakebin store add_out get_out stderr_file
  rec=$(new_case no-leak)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  add_out=$(printf '%s\n' "$SECRET" | run_bin "$fakebin" add leak-check 2>&1)
  assert_not_contains "$add_out" "$SECRET" "add's combined stdout+stderr must never contain the token"
  stderr_file="$TMP_ROOT/no-leak/get.stderr"
  get_out=$(run_bin "$fakebin" get leak-check 2>"$stderr_file")
  assert_equals "$SECRET" "$get_out" "get's stdout is exactly the token (the one sanctioned exposure)"
  assert_not_contains "$(cat "$stderr_file" 2>/dev/null)" "$SECRET" "get's stderr must never contain the token"
  assert_not_contains "$(cat "$store/argv.log")" "$SECRET" "no security invocation may carry the token in its argv"
  pass "the token appears only on get's stdout, never on stderr, add's output, or any process argv"
}

test_status_reports_mark_and_reading_without_values() {
  local rec fakebin store home out status
  rec=$(new_case status)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  home="$TMP_ROOT/status/home"
  mkdir -p "$home/config" "$home/state"
  printf 'account-a\naccount-b\n' > "$home/config/claude-accounts"
  printf '{"five_hour":{"used_percentage":42,"resets_at":9999999999},"seven_day":{"used_percentage":5,"resets_at":9999999999},"observed_at":1}\n' \
    > "$home/state/.claude-account-usage-account-a"
  FM_HOME="$home" PATH="$fakebin:$PATH" "$BIN" mark-limited account-b >/dev/null

  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$BIN" status) status=$?
  expect_code 0 "$status" "status should succeed: $out"
  assert_contains "$out" "account-a: no limited mark" "an unmarked slot should report no mark"
  assert_contains "$out" "5h=42%" "a recorded reading should show its five_hour used percentage"
  assert_contains "$out" "7d=5%" "a recorded reading should show its seven_day used percentage"
  assert_contains "$out" "account-b: limited until" "a marked slot should report its limited-until time"
  assert_contains "$out" "account-b" "the limited slot's own name should appear"
  assert_not_contains "$out" "$SECRET" "status must never print a token value"
  pass "status reports each slot's mark and recorded reading without any token value"
}

test_status_reports_no_reading_for_a_never_recorded_slot() {
  local rec fakebin store home out
  rec=$(new_case status-empty)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  home="$TMP_ROOT/status-empty/home"
  mkdir -p "$home/config" "$home/state"
  printf 'account-a\n' > "$home/config/claude-accounts"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$BIN" status)
  assert_contains "$out" "no recorded reading" "a slot with no usage file should report no recorded reading"
  pass "status reports no recorded reading for a slot the recorder has never written"
}

test_status_with_no_configured_slots() {
  local rec fakebin store home out
  rec=$(new_case status-unconfigured)
  IFS='|' read -r fakebin store <<EOF
$rec
EOF
  home="$TMP_ROOT/status-unconfigured/home"
  mkdir -p "$home/config" "$home/state"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$BIN" status)
  assert_contains "$out" "no slots configured" "status with no config/claude-accounts should say so"
  pass "status reports no configured slots when config/claude-accounts is absent or empty"
}

test_add_then_get_roundtrips
test_add_rejects_empty_or_whitespace_token
test_get_missing_slot_names_the_slot_only
test_invalid_slot_names_are_rejected
test_remove_then_get_fails
test_remove_missing_slot_is_not_an_error
test_list_reports_present_and_missing_without_values
test_add_get_never_leak_the_secret_on_any_stream
test_status_reports_mark_and_reading_without_values
test_status_reports_no_reading_for_a_never_recorded_slot
test_status_with_no_configured_slots
