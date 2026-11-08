#!/usr/bin/env bash
# Fake `gh` for `gh issue list` tests of bin/fm-project-issues.sh.
#
# Serves $FAKE_GH_ISSUES_DIR/<owner>__<repo>__<label>.json for
#   gh issue list --repo <owner>/<repo> --state open --label <label> --limit N --json ...
# and exits 1 when that fixture is absent, the way a real gh call against an
# unreadable repository fails. The fixtures in tests/assets/gh-issues/ copy
# the shape of real `gh issue list --json number,title,url,createdAt` output
# (captured 2026-11-07 from a labelled issue): an array of
# {createdAt, number, title, url}. --limit is honored like gh does.
# Every call is appended to $NET_LOG when set; FAKE_GH_SLEEP stalls the call.
set -u
[ -z "${NET_LOG:-}" ] || echo "gh $*" >> "$NET_LOG"
[ -z "${FAKE_GH_SLEEP:-}" ] || sleep "$FAKE_GH_SLEEP"
[ "${1:-}" = issue ] && [ "${2:-}" = list ] || exit 1
shift 2
repo='' label='' limit=30
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift ;;
    --label) label=$2; shift ;;
    --limit) limit=$2; shift ;;
  esac
  shift
done
f="${FAKE_GH_ISSUES_DIR:?}/${repo%%/*}__${repo#*/}__${label}.json"
[ -f "$f" ] || { echo "GraphQL: Could not resolve to a Repository with the name '$repo'." >&2; exit 1; }
jq --argjson limit "$limit" '.[:$limit]' "$f"
