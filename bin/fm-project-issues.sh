#!/usr/bin/env bash
# fm-project-issues.sh - the single reader of each registered project's open
# GitHub issues that carry a Bearings label.
#
# Every outstanding next step for a project is recorded as an open GitHub issue
# in that project, labelled `captain` (needs the captain to act or decide) or
# `next-step` (queued work for the project). This script reads them so Bearings
# surfaces them deterministically instead of relying on prose in a merged PR or
# a private file. It is read-only: it never creates, edits, labels, or closes an
# issue.
#
# Projects come from bin/fm-project-mode.sh --list (the registry owner). A
# project's repository is the GitHub owner/repo of its local clone's `origin`
# under $FM_PROJECTS_OVERRIDE or $FM_HOME/projects/<name>. A clone whose origin
# is not GitHub (or that has no origin) is skipped: it has no GitHub issues to
# read. A registered project with no readable local clone, a missing gh, or a
# gh call that fails or times out yields a visible `unavailable` row naming the
# reason, never a silent empty result.
#
# Reads run concurrently, at most FM_PROJECT_ISSUES_JOBS repositories at a time
# (default 8). Each gh call is bounded by FM_PROJECT_ISSUES_TIMEOUT seconds
# (default 15) through bin/fm-timeout-lib.sh. Each label returns at most
# FM_PROJECT_ISSUES_LIMIT issues per repository (default 50); a repository that
# has more is counted in `capped`. An issue carrying both labels appears once,
# as `captain`.
#
# Output (JSON, schema fm-project-issues.v1):
#   schema   "fm-project-issues.v1"
#   status   one line: "checked (<n> repos, <c> captain, <s> next-step)" with
#            "; <u> unavailable" and "; capped in <k> repo(s)" when nonzero,
#            or "no GitHub projects registered"
#   repos    number of GitHub repositories attempted
#   capped   number of repositories whose result hit the per-label limit
#   rows     array, ordered by registry order, then captain before next-step,
#            then oldest created first, then number; every row has the keys
#            project, repo, state ("open" | "unavailable"), label ("captain" |
#            "next-step" | null), number, title, url, created (YYYY-MM-DD),
#            reason (null on an open row; why the project could not be read on
#            an unavailable row, whose other issue fields are null)
#
# Usage: fm-project-issues.sh [--json]   (JSON is the only format; --json is accepted for symmetry)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_PROJECT_ISSUES_JOBS=${FM_PROJECT_ISSUES_JOBS:-8}
FM_PROJECT_ISSUES_TIMEOUT=${FM_PROJECT_ISSUES_TIMEOUT:-15}
FM_PROJECT_ISSUES_LIMIT=${FM_PROJECT_ISSUES_LIMIT:-50}
for bound in FM_PROJECT_ISSUES_JOBS FM_PROJECT_ISSUES_TIMEOUT FM_PROJECT_ISSUES_LIMIT; do
  case "${!bound}" in
    ''|*[!0-9]*|0) echo "fm-project-issues: $bound must be a positive integer" >&2; exit 2 ;;
  esac
done

case "${1:-}" in
  ''|--json) : ;;
  -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: fm-project-issues.sh [--json]" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-project-issues: jq not found" >&2; exit 1; }

# owner/repo from an https or ssh GitHub remote URL; empty when not GitHub.
repo_slug() {  # <url>
  local re='^(https://([^@/]+@)?|ssh://git@|git@)(www\.)?github\.com[:/]([^/]+/[^/]+)$' slug
  [[ "$1" =~ $re ]] || return 0
  slug=${BASH_REMATCH[4]%/}
  printf '%s\n' "${slug%.git}"
}

NAMES=$("$SCRIPT_DIR/fm-project-mode.sh" --list) \
  || { echo "fm-project-issues: cannot list registered projects" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-project-issues.XXXXXX") \
  || { echo "fm-project-issues: cannot create a work directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

unavailable_row() {  # <order> <project> <repo-or-empty> <reason>
  jq -n --argjson order "$1" --arg project "$2" --arg repo "$3" --arg reason "$4" \
    '[{_order:$order, project:$project, repo:(if $repo == "" then null else $repo end),
       state:"unavailable", label:null, number:null, title:null, url:null, created:null,
       reason:$reason}]'
}

# One repository: both labels, bounded; writes a JSON row array and, when a
# label hit the limit, a .capped marker.
read_repo() {  # <order> <project> <slug> <out>
  local order=$1 project=$2 slug=$3 out=$4 label raw all='[]' rc
  for label in captain next-step; do
    rc=0
    raw=$(fm_run_timed "$FM_PROJECT_ISSUES_TIMEOUT" \
      env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
      gh issue list --repo "$slug" --state open --label "$label" \
        --limit "$((FM_PROJECT_ISSUES_LIMIT + 1))" --json number,title,url,createdAt 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 124 ]; then
        unavailable_row "$order" "$project" "$slug" "gh issue list timed out after ${FM_PROJECT_ISSUES_TIMEOUT}s" > "$out"
      else
        unavailable_row "$order" "$project" "$slug" "gh issue list failed (exit $rc)" > "$out"
      fi
      return 0
    fi
    all=$(printf '%s' "${raw:-[]}" | jq -c --argjson all "$all" --arg label "$label" \
      --argjson limit "$FM_PROJECT_ISSUES_LIMIT" '
        if type != "array" then error("not an array") else . end
        | (if length > $limit then [{_capped:true}] else [] end) as $flag
        | $all + $flag + [ .[:$limit][] | {label:$label, number, title, url,
                                           created:((.createdAt // "") | .[0:10])} ]') \
      || { unavailable_row "$order" "$project" "$slug" "gh issue list returned unreadable output" > "$out"; return 0; }
  done
  printf '%s' "$all" | jq -c --argjson order "$order" --arg project "$project" --arg repo "$slug" '
    (map(select(._capped)) | length > 0) as $capped
    | [ .[] | select(._capped | not) ] | group_by(.url)
    | map(sort_by(if .label == "captain" then 0 else 1 end) | .[0]
          | {_order:$order, project:$project, repo:$repo, state:"open", label, number, title, url,
             created:(if .created == "" then null else .created end), reason:null})
    | if $capped then . + [{_capped:true}] else . end' > "$out" \
    || unavailable_row "$order" "$project" "$slug" "gh issue list returned unreadable output" > "$out"
}

HAVE_GH=1
command -v gh >/dev/null 2>&1 || HAVE_GH=0
order=0
repos=0
active=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  order=$((order + 1))
  out="$WORK/$(printf '%06d' "$order").json"
  clone="$PROJECTS_DIR/$name"
  if [ ! -d "$clone" ]; then
    unavailable_row "$order" "$name" "" "no local clone to read the GitHub origin from" > "$out"
    continue
  fi
  url=$(git -C "$clone" remote get-url origin 2>/dev/null) || url=""
  [ -n "$url" ] || continue
  slug=$(repo_slug "$url")
  [ -n "$slug" ] || continue
  repos=$((repos + 1))
  if [ "$HAVE_GH" = 0 ]; then
    unavailable_row "$order" "$name" "$slug" "gh not found" > "$out"
    continue
  fi
  read_repo "$order" "$name" "$slug" "$out" &
  active=$((active + 1))
  if [ "$active" -ge "$FM_PROJECT_ISSUES_JOBS" ]; then
    if wait -n 2>/dev/null; then active=$((active - 1)); else wait; active=0; fi
  fi
done <<EOF
$NAMES
EOF
wait

shopt -s nullglob
files=("$WORK"/*.json)
if [ "${#files[@]}" -eq 0 ]; then
  rows_raw='[]'
else
  rows_raw=$(jq -s 'add' "${files[@]}") || { echo "fm-project-issues: cannot merge results" >&2; exit 1; }
fi
printf '%s' "$rows_raw" | jq --argjson repos "$repos" '
  ([.[] | select(._capped)] | length) as $capped
  | [ .[] | select(._capped | not) ]
  | sort_by([._order, (if .label == "captain" then 0 elif .label == "next-step" then 1 else -1 end),
             (.created // "9999"), (.number // 0)])
  | map(del(._order)) as $rows
  | ([$rows[] | select(.label == "captain")] | length) as $c
  | ([$rows[] | select(.label == "next-step")] | length) as $s
  | ([$rows[] | select(.state == "unavailable")] | length) as $u
  | {schema:"fm-project-issues.v1",
     status:(if $repos == 0 and $u == 0 then "no GitHub projects registered"
             else "checked (\($repos) repos, \($c) captain, \($s) next-step"
                  + (if $u > 0 then "; \($u) unavailable" else "" end)
                  + (if $capped > 0 then "; capped in \($capped) repo(s)" else "" end) + ")" end),
     repos:$repos, capped:$capped, rows:$rows}'
