#!/usr/bin/env bash
# tests/fm-claude-usage-record.test.sh - bin/fm-claude-usage-record.sh, the
# Claude Code statusLine command bin/fm-spawn.sh injects only for a
# slot-injected Claude worker launch: it records the documented
# rate_limits.five_hour/.seven_day used_percentage/resets_at reading into the
# slot's usage file, auto-marks the slot limited once a window hits 100% used
# (with the real resets_at rather than a guessed five-hour default), never
# fails the worker, and never reads, prints, or stores a token or session
# content.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-claude-account-lib.sh
. "$ROOT/bin/fm-claude-account-lib.sh"

BIN="$ROOT/bin/fm-claude-usage-record.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-usage-record)

# new_case <name> builds a fresh home with config/ and state/. Echoes "<home>".
new_case() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' "$home"
}

run_recorder() {  # <home> <slot> <stdin-json>
  local home=$1 slot=$2 input=$3
  printf '%s' "$input" | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CLAUDE_ACCOUNT_SLOT="$slot" "$BIN"
}

usage_file() {  # <home> <slot>
  printf '%s/state/.claude-account-usage-%s' "$1" "$2"
}

test_records_both_windows_from_documented_fields() {
  local home out status file now future_5h future_7d
  home=$(new_case records)
  now=$(date +%s)
  future_5h=$((now + 10000))
  future_7d=$((now + 500000))
  out=$(run_recorder "$home" work-a \
    "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":42,\"resets_at\":$future_5h},\"seven_day\":{\"used_percentage\":7,\"resets_at\":$future_7d}}}") status=$?
  expect_code 0 "$status" "the recorder must always exit 0: $out"
  assert_contains "$out" "firstmate" "the recorder must still print a status line"
  file=$(usage_file "$home" work-a)
  [ -f "$file" ] || fail "the recorder should have written a usage file at $file"
  assert_contains "$(cat "$file")" '"used_percentage":42' "the five_hour used_percentage should be recorded"
  assert_contains "$(cat "$file")" '"used_percentage":7' "the seven_day used_percentage should be recorded"
  assert_contains "$(cat "$file")" "\"resets_at\":$future_5h" "the five_hour resets_at should be recorded verbatim"
  assert_contains "$(cat "$file")" "observed_at" "the record should carry an observed_at timestamp"
  pass "the recorder writes both windows' used_percentage and resets_at plus observed_at"
}

test_missing_rate_limits_writes_no_file() {
  local home out status file
  home=$(new_case missing-rate-limits)
  out=$(run_recorder "$home" work-a '{}') status=$?
  expect_code 0 "$status" "a status-line payload with no rate_limits must not fail the worker: $out"
  file=$(usage_file "$home" work-a)
  [ ! -f "$file" ] || fail "no usage file should be written when rate_limits is absent"
  assert_contains "$out" "firstmate" "a minimal status line should still print"
  pass "a status-line payload with no rate_limits writes no usage file and still exits 0"
}

test_no_slot_env_does_nothing_but_still_succeeds() {
  local home out status file
  home=$(new_case no-slot)
  out=$(env -u FM_CLAUDE_ACCOUNT_SLOT FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c "printf '%s' '{\"rate_limits\":{\"five_hour\":{\"used_percentage\":1,\"resets_at\":1}}}' | '$BIN'") status=$?
  expect_code 0 "$status" "a recorder run with no slot must still exit 0: $out"
  assert_equals "firstmate" "$out" "with no slot the status line should be the plain default"
  [ -z "$(find "$home/state" -maxdepth 1 -name '.claude-account-usage-*' 2>/dev/null)" ] \
    || fail "no usage file should be written when no slot is set"
  pass "a recorder run with FM_CLAUDE_ACCOUNT_SLOT unset writes nothing and still exits 0"
}

test_a_window_at_100_percent_refreshes_the_limited_mark_with_the_real_reset() {
  local home out status now resets_5h resets_7d markfile
  home=$(new_case automark)
  now=$(date +%s)
  resets_5h=$((now + 7200))
  resets_7d=$((now + 500000))
  out=$(run_recorder "$home" work-a \
    "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":100,\"resets_at\":$resets_5h},\"seven_day\":{\"used_percentage\":60,\"resets_at\":$resets_7d}}}") status=$?
  expect_code 0 "$status" "the recorder must exit 0 even while auto-marking: $out"
  markfile="$home/state/.claude-account-limited-work-a"
  [ -f "$markfile" ] || fail "a window at 100% used should refresh the slot's limited mark"
  assert_equals "$(jq -nr --argjson e "$resets_5h" '$e | todateiso8601')" "$(cat "$markfile")" \
    "the mark should use the saturated window's own resets_at, not a guessed default"
  pass "a window reported at 100% used refreshes the limited mark with that window's real reset time"
}

test_no_window_at_100_percent_leaves_the_mark_untouched() {
  local home out status now resets markfile
  home=$(new_case no-automark)
  now=$(date +%s)
  resets=$((now + 7200))
  out=$(run_recorder "$home" work-a \
    "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":80,\"resets_at\":$resets}}}") status=$?
  expect_code 0 "$status" "the recorder must exit 0: $out"
  markfile="$home/state/.claude-account-limited-work-a"
  [ ! -f "$markfile" ] || fail "a reading below 100% used must not create a limited mark"
  pass "a reading with no window at 100% used leaves the slot's limited mark untouched"
}

test_a_lower_reading_in_the_same_window_generation_does_not_regress_the_record() {
  local home out status now resets_5h resets_7d new_resets_7d file
  home=$(new_case no-regress)
  now=$(date +%s)
  resets_5h=$((now + 7200))
  resets_7d=$((now + 500000))
  new_resets_7d=$((now + 600000))
  run_recorder "$home" work-a \
    "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":95,\"resets_at\":$resets_5h},\"seven_day\":{\"used_percentage\":60,\"resets_at\":$resets_7d}}}" >/dev/null
  out=$(run_recorder "$home" work-a \
    "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":30,\"resets_at\":$resets_5h},\"seven_day\":{\"used_percentage\":2,\"resets_at\":$new_resets_7d}}}") status=$?
  expect_code 0 "$status" "the recorder must exit 0: $out"
  file=$(usage_file "$home" work-a)
  assert_equals "95 $resets_5h" "$(jq -r '"\(.five_hour.used_percentage) \(.five_hour.resets_at)"' "$file")" \
    "a lower five_hour reading for the same resets_at must not replace the higher stored one"
  assert_equals "2 $new_resets_7d" "$(jq -r '"\(.seven_day.used_percentage) \(.seven_day.resets_at)"' "$file")" \
    "a seven_day reading for a new window generation should replace the stored one outright"
  [ "$(jq -r '.observed_at' "$file")" -ge "$now" ] || fail "observed_at should be refreshed on every write"
  pass "a stale lower reading never regresses its window's generation, while a new generation is accepted"
}

test_an_older_window_generation_does_not_replace_a_newer_stored_one() {
  local home out status now old_resets new_resets file
  home=$(new_case no-older-generation)
  now=$(date +%s)
  old_resets=$((now - 60))
  new_resets=$((now + 7200))
  run_recorder "$home" work-a \
    "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":80,\"resets_at\":$new_resets}}}" >/dev/null
  out=$(run_recorder "$home" work-a \
    "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":$old_resets}}}") status=$?
  expect_code 0 "$status" "the recorder must exit 0: $out"
  file=$(usage_file "$home" work-a)
  assert_equals "80 $new_resets" "$(jq -r '"\(.five_hour.used_percentage) \(.five_hour.resets_at)"' "$file")" \
    "a reading from an older, superseded window generation must not replace the newer stored one"
  pass "a stale reading from an older window generation never replaces a newer stored reading"
}

test_a_saturated_window_whose_reset_has_passed_does_not_mark() {
  local home out status now markfile
  home=$(new_case stale-saturated)
  now=$(date +%s)
  out=$(run_recorder "$home" work-a \
    "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":100,\"resets_at\":$((now - 60))}}}") status=$?
  expect_code 0 "$status" "the recorder must exit 0: $out"
  markfile="$home/state/.claude-account-limited-work-a"
  [ ! -f "$markfile" ] || fail "a saturated window whose reset has already passed must not write a limited mark"
  pass "a stale saturated reading whose reset has passed never writes a limited mark"
}

test_the_recorder_never_prints_the_slot_name_as_a_secret_but_also_never_sees_a_token() {
  local home out
  home=$(new_case no-token)
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CLAUDE_ACCOUNT_SLOT=work-a \
    CLAUDE_CODE_OAUTH_TOKEN=should-never-be-read "$BIN" </dev/null)
  assert_not_contains "$out" "should-never-be-read" "the recorder must never echo a token even if one happens to be in its environment"
  pass "the recorder's output never carries a token value"
}

test_malformed_stdin_does_not_fail_the_worker() {
  local home out status
  home=$(new_case malformed-stdin)
  out=$(printf 'not json' | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CLAUDE_ACCOUNT_SLOT=work-a "$BIN") status=$?
  expect_code 0 "$status" "malformed stdin must never fail the worker: $out"
  assert_contains "$out" "firstmate" "a status line should still print for malformed stdin"
  pass "malformed stdin never fails the worker and still prints a status line"
}

test_records_both_windows_from_documented_fields
test_missing_rate_limits_writes_no_file
test_no_slot_env_does_nothing_but_still_succeeds
test_a_window_at_100_percent_refreshes_the_limited_mark_with_the_real_reset
test_no_window_at_100_percent_leaves_the_mark_untouched
test_a_lower_reading_in_the_same_window_generation_does_not_regress_the_record
test_an_older_window_generation_does_not_replace_a_newer_stored_one
test_a_saturated_window_whose_reset_has_passed_does_not_mark
test_the_recorder_never_prints_the_slot_name_as_a_secret_but_also_never_sees_a_token
test_malformed_stdin_does_not_fail_the_worker
