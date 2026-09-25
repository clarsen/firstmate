#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against a freshly fetched
# PR head, not a stale local branch or a stale recorded pr_head= left behind
# after no-mistakes fix rounds push to the PR.
#
# Matrix:
#   (a) pr= + reachable pr_head=, no remote pull ref -> offline fallback to recorded SHA
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) pr= + STALE recorded pr_head= + newer remote pull head -> must use fetched head
#       (this is the class that bit reviewers holding merges over "missing" fixes)
#   (f) a task with an edit member: --member <name> reviews that member's copy
#       against its own PR, and without it the task's own copy is reviewed
#       against its own PR rather than the PR in delivery
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "$@"
}

stale_and_pr_commits() {
  local case_dir=$1
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b pr-head-tmp
  printf 'pr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on PR"
  PR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)

  git -C "$case_dir/wt" checkout -q fm/task-x1
}

run_review_diff() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$REVIEW_DIFF" "$@"
}

test_pr_meta_uses_pr_head_not_stale_local() {
  local case_dir out
  case_dir=$(make_case pr-head-sha)
  stale_and_pr_commits "$case_dir"
  # No remote pull ref: fetch fails, recorded pr_head is the offline fallback.
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when recorded pr_head is reachable offline"
  pass "fm-review-diff falls back to recorded pr_head when pull head cannot be fetched"
}

test_stale_recorded_pr_head_loses_to_fetched_pull_head() {
  local case_dir out stale_sha
  case_dir=$(make_case stale-recorded)
  stale_and_pr_commits "$case_dir"
  stale_sha=$(git -C "$case_dir/wt" rev-parse fm/task-x1)
  # Remote PR head is newer (pipeline fix); meta still points at the older local tip.
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$stale_sha"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' \
    "stale-recorded: diff must show the fetched PR head, not the recorded stale SHA"
  assert_not_contains "$out" 'stale-local' \
    "stale-recorded: diff must not use the stale local/recorded content"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "stale-recorded: fetch of refs/pull/<n>/head should succeed"
  # Pre-fix behavior preferred reachable recorded pr_head= and would show stale-local.
  [ "$stale_sha" != "$PR_SHA" ] || fail "stale-recorded: fixture did not diverge recorded vs PR head"
  pass "fm-review-diff prefers freshly fetched PR head over a stale recorded pr_head="
}

test_pr_meta_fetches_pull_head_without_recorded_sha() {
  local case_dir out
  case_dir=$(make_case pr-fetch)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-fetch: diff should use fetched PR head"
  assert_not_contains "$out" 'stale-local' "pr-fetch: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-fetch: should not warn when fetch succeeds"
  pass "fm-review-diff fetches refs/pull/<n>/head when pr_head= is absent"
}

test_no_pr_meta_uses_local_branch() {
  local case_dir out
  case_dir=$(make_case no-pr-meta)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+stale-local' "no-pr-meta: diff should still use the local branch"
  assert_not_contains "$out" '+pr-fixed' "no-pr-meta: diff must not jump to the unpushed PR commit"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "no-pr-meta: no warning without pr= in meta"
  pass "fm-review-diff without pr= keeps the worktree-branch diff"
}

test_unreachable_pr_head_falls_back_with_warning() {
  local case_dir out err
  case_dir=$(make_case fetch-fallback)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  set -e
  err=$(cat "$case_dir/stderr")

  assert_contains "$err" 'warning: PR head unavailable; diff may lag the open PR' \
    "fetch-fallback: must warn when PR head cannot be resolved"
  assert_contains "$out" '+stale-local' "fetch-fallback: should fall back to the local branch diff"
  assert_not_contains "$out" '+pr-fixed' "fetch-fallback: must not invent a PR head diff offline"
  pass "fm-review-diff falls back to local branch with a warning when PR head is unreachable"
}

# add_edit_member <case-dir>: edit member api of task-x1, a copy of its own
# project on branch fm/task-x1 whose PR 3 head changes api.txt.
add_edit_member() {
  local case_dir=$1
  git init -q --bare "$case_dir/api-origin.git"
  git -C "$case_dir/api-origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/api-origin.git" "$case_dir/_api-seed" 2>/dev/null
  printf 'api base\n' > "$case_dir/_api-seed/api.txt"
  git -C "$case_dir/_api-seed" add api.txt
  git -C "$case_dir/_api-seed" -c user.email=t@t -c user.name=t commit -qm "api baseline"
  git -C "$case_dir/_api-seed" push -q origin main
  rm -rf "$case_dir/_api-seed"
  git clone -q "$case_dir/api-origin.git" "$case_dir/api-project"
  git -C "$case_dir/api-project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/api-project" worktree add -q -b fm/task-x1 "$case_dir/api-wt" main
  printf 'api-change\n' > "$case_dir/api-wt/api.txt"
  git -C "$case_dir/api-wt" add api.txt
  git -C "$case_dir/api-wt" commit -qm "api change"
  git -C "$case_dir/api-wt" push -q origin "fm/task-x1:refs/pull/3/head"
}

test_edit_member_reviews_its_own_copy_and_pr() {
  local case_dir out err
  case_dir=$(make_case edit-member)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  add_edit_member "$case_dir"
  # The member's PR is the one in delivery; the task's own PR keeps anchor_pr=.
  write_task_meta "$case_dir" \
    "member.api.project=$case_dir/api-project" "member.api.worktree=$case_dir/api-wt" \
    "member.api.role=edit" "member.api.mode=no-mistakes" "member.api.yolo=off" \
    "anchor_pr=https://github.com/example/repo/pull/9" \
    "member.api.pr=https://github.com/example/api/pull/3" \
    "pr=https://github.com/example/api/pull/3"

  out=$(run_review_diff "$case_dir" task-x1 --member api 2> "$case_dir/stderr")
  assert_contains "$out" '+api-change' "edit-member: --member api did not review the member's PR"
  assert_not_contains "$out" 'feature.txt' "edit-member: --member api reviewed the task's own copy"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "edit-member: the member's own PR head should be fetched"

  out=$(run_review_diff "$case_dir" task-x1 --stat --member api 2> "$case_dir/stderr")
  assert_contains "$out" 'api.txt' "edit-member: --stat before --member did not review the member"
  assert_not_contains "$out" '+api-change' "edit-member: --stat still printed the full diff"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  assert_contains "$out" '+pr-fixed' "edit-member: the task's own copy was not reviewed against its own PR"
  assert_not_contains "$out" 'api.txt' "edit-member: the task's own review showed the member's change"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "edit-member: the task's own review used the PR in delivery instead of its own"

  set +e
  run_review_diff "$case_dir" task-x1 --member nope > /dev/null 2> "$case_dir/stderr"
  expect_code 1 "$?" "edit-member: an unknown member should refuse"
  set -e
  err=$(cat "$case_dir/stderr")
  assert_contains "$err" "has no edit member named nope" "edit-member: the refusal did not name the unknown member"
  pass "fm-review-diff reviews an edit member's copy against its own PR, and the task's own copy against its own"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_edit_member_reviews_its_own_copy_and_pr
