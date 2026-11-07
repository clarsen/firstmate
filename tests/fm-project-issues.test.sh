#!/usr/bin/env bash
# Behavior tests for bin/fm-project-issues.sh: the labelled GitHub issue reader
# Bearings uses. Exercised through the script with a fake gh serving fixtures
# shaped like real `gh issue list` output (tests/assets/fake-gh-issues.sh).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ISSUES="$ROOT/bin/fm-project-issues.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-issues)
export FAKE_GH_ISSUES_DIR="$ROOT/tests/assets/gh-issues"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home"
  fakebin=$(fm_fakebin "$home")
  fm_seed_issue_projects "$home" "$fakebin"
  printf '%s\n' "$home"
}

run_issues() {  # <home> [env...]
  local home=$1; shift
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" NET_LOG="$home/net.log" "$@" "$ISSUES" --json
}

test_reads_labelled_issues_per_github_project() {
  local home out
  home=$(make_home basic)
  out=$(run_issues "$home") || fail "the reader failed: $out"
  printf '%s' "$out" | jq -e '
    .schema == "fm-project-issues.v1"
    and .repos == 3 and .capped == 0
    and .status == "checked (3 repos, 2 captain, 2 next-step; 2 unavailable)"
    and ([.rows[] | [.project, .state, .label, .number]] == [
      ["alpha","open","captain",7], ["alpha","open","captain",12],
      ["alpha","open","next-step",9], ["beta","open","next-step",3],
      ["gamma","unavailable",null,null], ["omega","unavailable",null,null]])
    and (.rows[0] == {project:"alpha", repo:"acme/alpha", state:"open", label:"captain",
          number:7, title:"Pick the alpha release name",
          url:"https://github.com/acme/alpha/issues/7", created:"2026-11-05", reason:null})
    and (.rows[3].repo == "acme/beta")' >/dev/null \
    || fail "unexpected rows: $out"
  pass "every GitHub project's captain and next-step issues are read, oldest first, captain winning a double label"
}

test_unreadable_projects_are_visible_rows() {
  local home out
  home=$(make_home unreadable)
  out=$(run_issues "$home") || fail "the reader failed: $out"
  printf '%s' "$out" | jq -e '
    ([.rows[] | select(.state == "unavailable") | {project, repo, reason}] == [
      {project:"gamma", repo:null, reason:"no local clone to read the GitHub origin from"},
      {project:"omega", repo:"acme/omega", reason:"gh issue list failed (exit 1)"}])
    and ([.rows[] | select(.project == "delta")] == [])' >/dev/null \
    || fail "unreadable projects were not reported as unavailable rows: $out"
  grep -q 'acme/delta\|gitlab' "$home/net.log" && fail "a non-GitHub origin was queried: $(cat "$home/net.log")"
  pass "a project that cannot be read is an unavailable row with its reason, and a non-GitHub origin is skipped"
}

test_missing_gh_marks_every_github_project_unavailable() {
  local home out toolbin cmd
  home=$(make_home nogh)
  rm -f "$home/fakebin/gh"
  toolbin="$home/toolbin"
  mkdir -p "$toolbin"
  for cmd in bash dirname basename jq sed git awk mktemp rm cat sort env perl sleep mkdir; do
    ln -s "$(command -v "$cmd")" "$toolbin/$cmd"
  done
  out=$(PATH="$home/fakebin:$toolbin" FM_HOME="$home" "$ISSUES" --json) || fail "the reader failed: $out"
  printf '%s' "$out" | jq -e '
    [.rows[] | select(.reason == "gh not found") | .project] == ["alpha","beta","omega"]
    and ([.rows[] | select(.state == "open")] == [])' >/dev/null \
    || fail "a missing gh did not mark every GitHub project unavailable: $out"
  pass "a missing gh is reported per project, never as an empty result"
}

test_a_stalled_gh_call_is_bounded() {
  local home out started elapsed
  home=$(make_home stalled)
  started=$(date +%s)
  out=$(run_issues "$home" FAKE_GH_SLEEP=5 FM_PROJECT_ISSUES_TIMEOUT=1) || fail "the reader failed: $out"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 5 ] || fail "stalled gh calls were not bounded (${elapsed}s)"
  printf '%s' "$out" | jq -e '
    [.rows[] | select(.reason == "gh issue list timed out after 1s") | .project] == ["alpha","beta","omega"]' >/dev/null \
    || fail "a timed-out repository was not reported unavailable: $out"
  pass "each gh call is time-bounded, repositories run concurrently, and a timeout is an unavailable row"
}

test_a_capped_repository_is_disclosed() {
  local home out
  home=$(make_home capped)
  out=$(run_issues "$home" FM_PROJECT_ISSUES_LIMIT=1) || fail "the reader failed: $out"
  printf '%s' "$out" | jq -e '.capped == 1 and (.status | endswith("; capped in 1 repo(s))"))' >/dev/null \
    || fail "a repository over the per-label limit was not disclosed: $out"
  pass "a repository with more labelled issues than the limit is counted in capped"
}

test_no_registry_means_no_calls() {
  local home out
  home="$TMP_ROOT/empty"
  mkdir -p "$home"
  out=$(env FM_HOME="$home" NET_LOG="$home/net.log" PATH="$PATH" "$ISSUES" --json) || fail "the reader failed: $out"
  printf '%s' "$out" | jq -e '. == {schema:"fm-project-issues.v1", status:"no GitHub projects registered", repos:0, capped:0, rows:[]}' >/dev/null \
    || fail "an empty home did not report an explicit empty result: $out"
  [ ! -e "$home/net.log" ] || fail "an empty home made a gh call"
  pass "a home with no registered projects reports an explicit empty result without calling gh"
}

fm_test_run \
  test_reads_labelled_issues_per_github_project \
  test_unreadable_projects_are_visible_rows \
  test_missing_gh_marks_every_github_project_unavailable \
  test_a_stalled_gh_call_is_bounded \
  test_a_capped_repository_is_disclosed \
  test_no_registry_means_no_calls
