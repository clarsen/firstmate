#!/usr/bin/env bash
# fm-captain-question-list.sh - print the open captain questions as JSON.
#
# Usage: fm-captain-question-list.sh
#
# Reads $FM_HOME/data/captain-questions.json (schema fm-captain-questions.v1,
# owned and mutated only by bin/fm-captain-question.py) with jq alone, so the
# Bearings snapshot and board never depend on python3. It applies the same
# record validation as that script and prints a JSON array of the open rows,
# each with a boolean `stale` that is true once 24 hours pass without a status
# update. A missing record prints []. A symlinked, unparsable, or invalid
# record prints nothing and exits non-zero.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RECORD="$FM_HOME/data/captain-questions.json"

[ "$#" -eq 0 ] || { echo "usage: fm-captain-question-list.sh" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-captain-question-list: jq is required" >&2; exit 1; }
if [ -L "$RECORD" ]; then
  echo "fm-captain-question-list: captain question record is a symlink" >&2
  exit 1
fi
if [ ! -e "$RECORD" ]; then
  printf '[]\n'
  exit 0
fi

jq -ce --argjson now "$(date -u +%s)" '
  def text: type == "string" and test("\\S");
  def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    and ((try (fromdateiso8601 | todateiso8601) catch null) == .);
  def url: type == "string"
    and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#]\\S*)?$")
    and (test("\\s") | not);
  def link: type == "object" and (.label | type == "string" and . != "") and (.url | url);
  def row:
    type == "object"
    and (.id | type == "string" and test("^q-[0-9]{8}-[0-9a-f]{8}$"))
    and (.state == "open" or .state == "closed")
    and (.question | text) and (.status | text)
    and (.opened | stamp) and (.last_updated | stamp)
    and (.links | type == "array" and all(.[]; link))
    and (if .state == "closed" then
           (.closed_by_captain | type == "object"
             and (.source == "captain-chat" or .source == "board")
             and (.at | stamp) and (.words | text))
         else .closed_by_captain == null end);
  if type == "object" and .schema == "fm-captain-questions.v1"
     and (.questions | type == "array") and all(.questions[]; row)
     and ([.questions[].id] | unique | length) == (.questions | length)
  then [.questions[] | select(.state == "open")
        | . + {stale: (($now - (.last_updated | fromdateiso8601)) >= 86400)}]
  else error("invalid captain question record") end
' "$RECORD"
