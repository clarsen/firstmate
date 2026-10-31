#!/usr/bin/env bash
# Behavior tests for fm_mkdir_exclusive (bin/fm-excl-mkdir-lib.sh) and the
# remote sequence allocator built on it. uutils coreutils mkdir (ubuntu-26.04)
# can report success to several concurrent callers for one directory, so a bare
# mkdir is not a lock. A non-atomic mkdir stand-in on PATH - one that, like
# `mkdir -p`, succeeds when the directory already exists - must not be able to
# grant one claim twice.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-excl-mkdir)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/mkdir" <<'SH'
#!/bin/sh
# Non-atomic stand-in: reports a uutils version and succeeds on an existing dir.
case "${1:-}" in --version) echo 'mkdir (uutils coreutils) 0.10.0'; exit 0 ;; esac
for last do :; done
exec /bin/mkdir -p -- "$last"
SH
chmod +x "$FAKEBIN/mkdir"
export PATH="$FAKEBIN:$PATH"

test_stand_in_is_not_exclusive() {
  mkdir "$TMP_ROOT/probe" 2>/dev/null
  mkdir "$TMP_ROOT/probe" || fail "stand-in must succeed on an existing directory"
  pass "stand-in mkdir is non-exclusive"
}

test_helper_grants_each_claim_once() {
  local out="$TMP_ROOT/claims" round i wins pids
  for round in 1 2 3; do
    rm -rf "$out"; /bin/mkdir -p "$out/lock-parent"
    pids=()
    for i in $(seq 1 20); do
      ( # shellcheck source=bin/fm-excl-mkdir-lib.sh
        . "$ROOT/bin/fm-excl-mkdir-lib.sh"
        if fm_mkdir_exclusive "$out/lock-parent/x"; then : > "$out/win-$i"; fi ) &
      pids+=("$!")
    done
    wait "${pids[@]}"
    wins=$(find "$out" -name 'win-*' | wc -l | tr -d ' ')
    assert_equals 1 "$wins" "round $round: exactly one caller must win the claim"
  done
  pass "helper grants each claim once"
}

test_helper_honors_umask() {
  ( . "$ROOT/bin/fm-excl-mkdir-lib.sh"; umask 077; fm_mkdir_exclusive "$TMP_ROOT/private" ) \
    || fail "helper failed to create a fresh directory"
  assert_equals 700 "$(stat -c %a "$TMP_ROOT/private" 2>/dev/null || /usr/bin/stat -f %Lp "$TMP_ROOT/private")" \
    "directory must honor the caller's umask"
  ( . "$ROOT/bin/fm-excl-mkdir-lib.sh"; fm_mkdir_exclusive "$TMP_ROOT/private" ) \
    && fail "helper must fail on an existing directory"
  pass "helper honors umask and refuses existing directories"
}

test_sequence_allocator_unique_under_stand_in() {
  local pids=() i pid results
  export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/state"
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$ROOT/bin/fm-remote-job-lib.sh"
  /bin/mkdir -p "$TMP_ROOT/account"
  fm_remote_job_prepare_state "$TMP_ROOT/account" || fail "$FM_REMOTE_JOB_ERROR"
  rm -f -- "$FM_REMOTE_JOB_STATE/seq"
  for i in $(seq 1 20); do
    fm_remote_job_next_seq > "$TMP_ROOT/seq-$i" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || fail "a concurrent sequence allocator failed"; done
  results=$(cat "$TMP_ROOT"/seq-* | sort -n | tr '\n' ' ')
  assert_equals "$(seq 1 20 | tr '\n' ' ')" "$results" "sequence claims must be unique and dense"
  pass "sequence allocator is unique under non-atomic mkdir"
}

fm_test_run test_stand_in_is_not_exclusive test_helper_grants_each_claim_once \
  test_helper_honors_umask test_sequence_allocator_unique_under_stand_in
