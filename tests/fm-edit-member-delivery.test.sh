#!/usr/bin/env bash
# Regression tests for PR delivery of a task that changes several repositories
# through edit members (bin/fm-task-members-lib.sh). They drive the real
# fm-pr-check.sh and fm-pr-merge.sh entry points against a fake forge and prove:
#   - a PR is resolved to its repository by origin, recorded under that
#     repository's own key ahead of pr=, and gated on that repository's own
#     copy and delivery mode;
#   - a PR of no repository of the task is refused;
#   - pr= moves to another repository only once the PR in delivery has a
#     recorded merge or the forge reports it closed without merging, and a
#     merged PR whose merge is not recorded yet still holds it;
#   - the merge helper merges only the PR in delivery, refusing another
#     repository's PR while that one is open and another PR of the same
#     repository.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-edit-member-delivery)
fm_git_identity fmtest fmtest@example.invalid
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_JQ=$(command -v jq) || fail "these tests read the forge's JSON with the real jq, which was not found"

API_URL=https://github.com/o/api/pull/5
APP_URL=https://github.com/o/app/pull/7

# make_repo <dir> <origin-url>: a repository whose origin is <origin-url> and
# whose one commit origin/main already holds.
make_repo() {
  git init -q -b main "$1"
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" remote add origin "$2"
  git -C "$1" update-ref refs/remotes/origin/main "$(git -C "$1" rev-parse HEAD)"
}

# make_case <name>: task task-a whose own repository is github.com/o/app
# (no-mistakes, yolo off) and whose edit member api is github.com/o/api
# (direct-PR, yolo on), each with a clone and a copy on branch fm/task-a. The
# fake forge reports each PR's state from FM_TEST_PR_<number>_STATE and
# _MERGED (OPEN and false by default), reports a PR it merged as merged, and
# logs every call.
make_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/root/bin" "$dir/fakebin"
  make_repo "$dir/proj" https://github.com/o/app.git
  make_repo "$dir/wt" https://github.com/o/app.git
  make_repo "$dir/api-project" git@github.com:o/api.git
  make_repo "$dir/api-wt" git@github.com:o/api.git
  git -C "$dir/wt" checkout -q -b fm/task-a
  git -C "$dir/api-wt" checkout -q -b fm/task-a
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
head=${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}
case "${1:-} ${2:-}" in
  "api graphql")
    number=
    for arg in "$@"; do
      case "$arg" in
        number=*) number=${arg#number=} ;;
      esac
    done
    eval "state=\${FM_TEST_PR_${number}_STATE:-OPEN}"
    eval "merged=\${FM_TEST_PR_${number}_MERGED:-false}"
    if [ -e "$FM_TEST_GH_LOG.merged-$number" ]; then
      state=MERGED
      merged=true
    fi
    printf 'state=%s\nmerged=%s\n' "$state" "$merged"
    case " $* " in
      *isInMergeQueue*) printf 'queued=false\nbase=main\n' ;;
    esac
    exit 0
    ;;
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        printf '%s\n' "{\"state\":\"OPEN\",\"isDraft\":false,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"$head\",\"baseRefName\":\"main\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"name\":\"ci\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]}"
        exit 0
        ;;
      *" --json isDraft "*)
        printf '%s\n' '{"isDraft":false}'
        exit 0
        ;;
      *headRefOid,reviewDecision*)
        printf '%s\n' "{\"headRefOid\":\"$head\",\"reviewDecision\":\"APPROVED\"}"
        exit 0
        ;;
      *" headRefOid "*)
        [ "$head" != unavailable ] || exit 1
        printf '%s\n' "$head"
        exit 0
        ;;
    esac
    ;;
  "pr merge")
    : > "$FM_TEST_GH_LOG.merged-${3:-}"
    exit 0
    ;;
esac
case " $* " in
  *" api repos/"*"/issues/"*"/comments?per_page=100 "*|*" api repos/"*"/pulls/"*"/reviews?per_page=100 "*|*" api repos/"*"/pulls/"*"/comments?per_page=100 "*)
    printf '%s\n' '[[]]'
    ;;
  *" api repos/"*"/commits/"*"/check-runs?filter=all&per_page=100 "*)
    printf '%s\n' '[{"check_runs":[]}]'
    ;;
  *" api repos/"*"/commits/"*"/statuses?per_page=100 "*)
    printf '%s\n' '[[]]'
    ;;
  *" api repos/"*"/pulls/"*)
    printf '%s\n' "{\"state\":\"open\",\"user\":{\"login\":\"author\"},\"head\":{\"sha\":\"$head\"},\"draft\":false,\"mergeable\":true,\"merged_at\":null}"
    ;;
  *" api repos/"*)
    printf '%s\n' '{"permissions":{"push":false}}'
    ;;
esac
SH
  ln -s "$REAL_JQ" "$dir/fakebin/jq"
  chmod +x "$dir/root/bin/fm-guard.sh" "$dir/fakebin/gh"
  : > "$dir/gh.log"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" "endpoint_task_id=task-a" "worktree=$dir/wt" "project=$dir/proj" \
    "kind=ship" "mode=no-mistakes" "yolo=off" \
    "member.api.project=$dir/api-project" "member.api.worktree=$dir/api-wt" "member.api.role=edit" \
    "member.api.ref=" "member.api.commit=$(git -C "$dir/api-wt" rev-parse HEAD)" \
    "member.api.lease_id=lease-api" "member.api.pool_root=" "member.api.mode=direct-PR" "member.api.yolo=on"
  printf '%s\n' "$dir"
}

run_entry() {  # <case-dir> <script> <args...>
  local dir=$1 script=$2
  shift 2
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_TEST_GH_LOG="$dir/gh.log" \
    PATH="$dir/fakebin:$BASE_PATH" "$script" "$@"
}

# assert_line <line> <file> <msg>: <file> holds exactly the line <line>.
assert_line() {
  grep -qxF -- "$1" "$2" || fail "$3"
}

meta_keys() {  # <meta>: the record's keys, in order
  cut -d= -f1 "$1"
}

test_member_pr_records_under_its_repository() {
  local dir head keys
  dir=$(make_case member-record)
  head=$(git -C "$dir/api-wt" rev-parse HEAD)
  FM_TEST_GH_HEAD=$head run_entry "$dir" "$PR_CHECK" task-a "$API_URL" > "$dir/out" 2> "$dir/err" \
    || fail "registering the api member's PR failed: $(cat "$dir/err")"
  assert_line "member.api.pr=$API_URL" "$dir/home/state/task-a.meta" "the member's PR is not recorded under its repository"
  assert_line "member.api.pr_head=$head" "$dir/home/state/task-a.meta" "the member's PR head is not recorded under its repository"
  assert_line "pr=$API_URL" "$dir/home/state/task-a.meta" "the member's PR is not the PR in delivery"
  keys=$(meta_keys "$dir/home/state/task-a.meta" | tr '\n' ' ')
  assert_contains "$keys" "member.api.pr member.api.pr_head pr pr_head" "the repository's own record does not precede pr="
  [ -f "$dir/home/state/task-a.check.sh" ] || fail "registering the member's PR armed no merge poll"
  assert_no_grep 'anchor_pr=' "$dir/home/state/task-a.meta" "a member PR was recorded as the task's own"
  pass "a member's PR is recorded under its repository, ahead of pr=, and armed"
}

test_member_named_head_gate_reads_the_member_copy() {
  local dir sha
  dir=$(make_case member-gate)
  printf 'fix\n' > "$dir/api-wt/fix.txt"
  git -C "$dir/api-wt" add fix.txt
  git -C "$dir/api-wt" commit -q -m 'only in the member copy'
  sha=$(git -C "$dir/api-wt" rev-parse HEAD)
  cp "$dir/home/state/task-a.meta" "$dir/meta.before"
  if FM_TEST_GH_HEAD=unavailable run_entry "$dir" "$PR_CHECK" task-a "$API_URL" > "$dir/out" 2> "$dir/err"; then
    fail "a member PR whose named head is only in the member copy was registered"
  fi
  assert_grep "named head $sha is unreachable outside the worker copy" "$dir/err" \
    "the refusal did not name the member copy's head"
  cmp -s "$dir/meta.before" "$dir/home/state/task-a.meta" || fail "a refused registration changed the task record"
  git -C "$dir/api-wt" update-ref refs/remotes/origin/fm/task-a "$sha"
  FM_TEST_GH_HEAD=unavailable run_entry "$dir" "$PR_CHECK" task-a "$API_URL" > "$dir/out" 2> "$dir/err" \
    || fail "a member PR whose head is on the member's remote was refused: $(cat "$dir/err")"
  pass "a member PR's named head is read from the member's own copy"
}

test_pr_of_no_repository_of_the_task_is_refused() {
  local dir
  dir=$(make_case unknown-repo)
  cp "$dir/home/state/task-a.meta" "$dir/meta.before"
  if run_entry "$dir" "$PR_CHECK" task-a https://github.com/o/other/pull/1 > "$dir/out" 2> "$dir/err"; then
    fail "a PR of no repository of the task was registered"
  fi
  assert_grep "is not the origin of this task's own repository or of any of its edit members" "$dir/err" \
    "the refusal did not say the PR belongs to no repository of the task"
  cmp -s "$dir/meta.before" "$dir/home/state/task-a.meta" || fail "a refused registration changed the task record"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "a refused registration armed a poll"
  pass "a PR of no repository of the task is refused before anything is recorded"
}

test_delivery_moves_between_repositories_only_after_merge() {
  local dir
  dir=$(make_case switch)
  run_entry "$dir" "$PR_CHECK" task-a "$API_URL" > "$dir/out" 2> "$dir/err" \
    || fail "registering the api PR failed: $(cat "$dir/err")"
  cp "$dir/home/state/task-a.meta" "$dir/meta.before"

  if run_entry "$dir" "$PR_CHECK" task-a "$APP_URL" > "$dir/out" 2> "$dir/err"; then
    fail "delivery moved to another repository while the PR in delivery was open"
  fi
  assert_grep "is still open; repositories deliver one at a time" "$dir/err" "the open refusal did not say why"
  cmp -s "$dir/meta.before" "$dir/home/state/task-a.meta" || fail "a refused move changed the task record"

  if FM_TEST_PR_5_STATE=MERGED FM_TEST_PR_5_MERGED=true \
    run_entry "$dir" "$PR_CHECK" task-a "$APP_URL" > "$dir/out" 2> "$dir/err"; then
    fail "delivery moved on before the merge of the PR in delivery was recorded"
  fi
  assert_grep "has merged, but its merge outcome is not recorded yet" "$dir/err" \
    "the unrecorded-merge refusal did not say why"
  cmp -s "$dir/meta.before" "$dir/home/state/task-a.meta" || fail "a refused move changed the task record"

  FM_TEST_PR_5_STATE=CLOSED run_entry "$dir" "$PR_CHECK" task-a "$APP_URL" > "$dir/out" 2> "$dir/err" \
    || fail "delivery did not move on from a PR closed without merging: $(cat "$dir/err")"
  assert_line "anchor_pr=$APP_URL" "$dir/home/state/task-a.meta" "the task's own PR is not recorded under its own key"
  assert_line "pr=$APP_URL" "$dir/home/state/task-a.meta" "the task's own PR is not the PR in delivery"
  assert_line "member.api.pr=$API_URL" "$dir/home/state/task-a.meta" "moving delivery lost the member's own PR record"

  # A recorded merge releases the PR in delivery without another forge read.
  if run_entry "$dir" "$PR_CHECK" task-a https://github.com/o/api/pull/9 > "$dir/out" 2> "$dir/err"; then
    fail "delivery moved back while the task's own PR was open"
  fi
  fm_pr_poll_merge_mark_notified "$dir/home/state" task-a github github.com o/app 7 \
    || fail "could not record the merge of the task's own PR"
  : > "$dir/gh.log"
  run_entry "$dir" "$PR_CHECK" task-a https://github.com/o/api/pull/9 > "$dir/out" 2> "$dir/err" \
    || fail "delivery did not move on from a PR whose merge is recorded: $(cat "$dir/err")"
  assert_no_grep 'api graphql' "$dir/gh.log" "a recorded merge still read the forge"
  assert_line "member.api.pr=https://github.com/o/api/pull/9" "$dir/home/state/task-a.meta" \
    "the member's replacement PR is not recorded"
  [ "$(grep -c '^member.api.pr=' "$dir/home/state/task-a.meta")" = 1 ] || fail "the member's earlier PR record was kept beside its replacement"
  assert_line "anchor_pr=$APP_URL" "$dir/home/state/task-a.meta" "moving delivery lost the task's own PR record"
  pass "delivery moves to another repository only once the PR in delivery is closed or its merge is recorded"
}

test_merge_binds_to_the_pr_in_delivery() {
  local dir
  dir=$(make_case merge)
  run_entry "$dir" "$PR_CHECK" task-a "$API_URL" > "$dir/out" 2> "$dir/err" \
    || fail "registering the api PR failed: $(cat "$dir/err")"
  : > "$dir/gh.log"
  if run_entry "$dir" "$PR_MERGE" task-a "$APP_URL" > "$dir/out" 2> "$dir/err"; then
    fail "the merge helper merged another repository's PR while the PR in delivery was open"
  fi
  assert_grep "is still open; repositories deliver one at a time" "$dir/err" "the merge refusal did not say why"
  assert_no_grep 'pr merge' "$dir/gh.log" "a refused merge still reached the forge"
  if run_entry "$dir" "$PR_MERGE" task-a https://github.com/o/api/pull/6 > "$dir/out" 2> "$dir/err"; then
    fail "the merge helper merged another PR of the repository in delivery"
  fi
  assert_grep "is bound to $API_URL" "$dir/err" "the same-repository refusal did not name the PR in delivery"
  assert_no_grep 'pr merge' "$dir/gh.log" "a refused merge still reached the forge"
  run_entry "$dir" "$PR_MERGE" task-a "$API_URL" > "$dir/out" 2> "$dir/err" \
    || fail "the merge helper refused the PR in delivery: $(cat "$dir/err")"
  assert_grep 'pr merge 5 --repo o/api ' "$dir/gh.log" "the merge did not reach the member's repository"
  pass "the merge helper merges only the PR in delivery"
}

test_member_pr_records_under_its_repository
test_member_named_head_gate_reads_the_member_copy
test_pr_of_no_repository_of_the_task_is_refused
test_delivery_moves_between_repositories_only_after_merge
test_merge_binds_to_the_pr_in_delivery

echo "# all fm-edit-member-delivery tests passed"
