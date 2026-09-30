#!/usr/bin/env bash
# fm-decision-page.sh - build and arm a one-off captain question page.
#
# The shipped template (bin/fm-decision-page-template.html) plus one injected
# fm-decision-page.v1 JSON payload is THE way a one-off captain question or
# checklist page is built. This script owns the mechanics so the invoking
# agent's per-run work stays "compose the JSON, run build" - the agent never
# authors page markup at invocation time, the same contract
# bin/fm-bearings-board.sh already holds for the /bearings fleet board.
#
# Hand-copying an earlier page's HTML and editing it by hand is the exact
# defect this script exists to remove: one shipped page lost the element its
# choices render into to a stray line-index edit, and another shipped a
# duplicated `const OPTS` declaration that was a JavaScript syntax error and
# stopped the script before any control drew. Neither was checked before the
# link went to the captain. This script never lets that recur: a build either
# proves its own page renders working controls, or it refuses with no link.
#
# Usage:
#   fm-decision-page.sh build <data.json> --for <task-id>
#   fm-decision-page.sh path --for <task-id>
#
# build      Validate the payload, inject it into a fresh copy of the shipped
#            template at the task-scoped page path, PROVE under a real
#            headless DOM execution (bin/fm-decision-page-render.mjs, node)
#            that every question rendered exactly one radio-button group with
#            at least one option before doing anything visible to the
#            captain, establish the Lavish session on that page and PROVE it
#            is live BEFORE arming its answer source (the same order
#            bin/fm-bearings-board.sh enforces, for the same reason: a
#            registered poll must never race a session that does not exist or
#            attach to one that has ended), then arm the source bound to
#            <task-id> through bin/fm-procevent-lavish.sh's register-task
#            path so an answered page wakes that task directly. Output:
#              page: <path>
#              (lavish-axi's own establish output, including its own `url:`
#               field)
#              session: live | reopened
#              link: <url>              the captain-facing page URL
#              served: <path>
#              armed: <source-id>
#            A payload that fails validation, or a built page whose render
#            check fails, is refused with a clear message: no page is
#            published, no session is established, nothing is armed, and no
#            link is printed.
#   path       Print the stable page path for <task-id>.
#
# Payload schema fm-decision-page.v1 (validated fail-closed with jq, exactly
# as bin/fm-bearings-board.sh's fm-bearings-board.v1 payload is):
#   schema      "fm-decision-page.v1"
#   title       non-empty string: the page <title> and header
#   eyebrow     optional string: the small label above the title
#   lead        optional string: intro copy under the title
#   questions   non-empty array, each:
#     key           slug, 1-128 chars of [A-Za-z0-9._-]: the answer's question id
#     title         non-empty string
#     body          optional string
#     options       non-empty array of { value: slug, label: non-empty string,
#                   hint: optional string, recommended: optional boolean };
#                   at most one option may carry recommended: true
#     note          optional, one of "none" (default), "optional", "required";
#                   anything but "none" adds a freeform note field, and
#                   "required" refuses to queue an answer with no note
#
# RENDER-PROVEN BEFORE THE LINK EVER SHIPS. The build stages the page at a
# temporary path and runs it through bin/fm-decision-page-render.mjs, which
# executes the built page's own inline script under a minimal DOM shim (the
# same headless-parse pattern tests/assets/board-render-harness.mjs uses for
# the /bearings board) and reports what actually rendered. The build refuses
# unless that report names exactly one question per payload question, each
# with at least one radio option sharing one name, and no fail-closed render
# error. Only then does the staged page replace the published one.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED - see bin/fm-bearings-board.sh's
# comment of the same name; the mechanics here are the same. `lavish-axi
# <file>` exits 0 even when it refuses to reopen a session the captain ended
# from the browser, reporting `status: user-ended` with the same session id,
# so the server's fresh session listing must show the page open before this
# build may arm anything.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TEMPLATE="${FM_DECISION_PAGE_TEMPLATE:-$SCRIPT_DIR/fm-decision-page-template.html}"
RENDER_HARNESS="${FM_DECISION_PAGE_RENDER_HARNESS:-$SCRIPT_DIR/fm-decision-page-render.mjs}"
PLACEHOLDER='__FM_DECISION_PAGE_DATA__'
PAGE_SCHEMA=fm-decision-page.v1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-page: %s\n' "$*" >&2
  exit 1
}

page_path() {  # <task-id>
  printf '%s/data/%s/decision-page.html\n' "$FM_HOME" "$1"
}

validate_payload() {  # <data.json>
  jq -e --arg schema "$PAGE_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def option:
      type == "object"
      and (.value | slug(128))
      and (.label | nonempty_string)
      and optional_string("hint")
      and ((has("recommended") | not) or (.recommended | type == "boolean"));
    def question:
      type == "object"
      and (.key | slug(128))
      and (.title | nonempty_string)
      and optional_string("body")
      and (.options | type == "array" and length > 0)
      and ([.options[] | option] | all)
      and (([.options[] | select(.recommended == true)] | length) <= 1)
      and ((has("note") | not) or (.note == "none" or .note == "optional" or .note == "required"));
    type == "object"
    and (.schema == $schema)
    and (.title | nonempty_string)
    and (optional_string("eyebrow"))
    and (optional_string("lead"))
    and (.questions | type == "array" and length > 0)
    and ([.questions[] | question] | all)
    and (([.questions[].key] | unique | length) == (.questions | length))
  ' "$1" >/dev/null
}

# --- Lavish session liveness -------------------------------------------------
# Identical contract to bin/fm-bearings-board.sh's "A LIVE SESSION IS PROVED,
# NEVER ASSUMED" section; see that script's comment for the full rationale.

page_realpath() {  # <page>
  "$SCRIPT_DIR/fm-procevent-lavish.sh" canonical-path "$1" 2>/dev/null
}

lavish_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

lavish_url_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"'
}

lavish_session_listed_open() {  # <canonical-page-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

lavish_page_live() {  # <establish output> <canonical-page-path>
  lavish_session_listed_open "$2"
}

establish_page_session() {  # <page>
  local page=$1 real out status version
  real=$(page_realpath "$page") || fail "cannot resolve the page path: $page"
  out=$(lavish-axi "$page") || fail "cannot establish the page Lavish session"
  printf '%s\n' "$out"
  if lavish_page_live "$out" "$real"; then
    printf 'session: live\n'
    ESTABLISH_OUT=$out
    return 0
  fi
  out=$(lavish-axi "$page" --reopen) || fail "cannot reopen the ended page Lavish session"
  printf '%s\n' "$out"
  if lavish_page_live "$out" "$real"; then
    printf 'session: reopened\n'
    ESTABLISH_OUT=$out
    return 0
  fi
  status=$(lavish_status_field "$out")
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the page Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# Run the built page through a real headless DOM execution and refuse unless
# every payload question rendered exactly one radio group with options and no
# fail-closed render error fired.
verify_render() {  # <data.json> <built-page>
  local data=$1 built=$2 report expected_keys got_keys bad
  command -v node >/dev/null 2>&1 || fail "node is required to prove the page renders its controls"
  [ -f "$RENDER_HARNESS" ] || fail "the render-check harness is missing: $RENDER_HARNESS"
  report=$(node "$RENDER_HARNESS" "$built" 2>&1) \
    || fail "the render check could not execute the built page: $report"
  jq -e . >/dev/null 2>&1 <<< "$report" \
    || fail "the render check produced unreadable output: $report"
  if [ -n "$(jq -r '.error' <<< "$report")" ]; then
    fail "the built page renders its fail-closed error instead of controls: $(jq -r '.error' <<< "$report")"
  fi
  expected_keys=$(jq -c '[.questions[].key]' "$data")
  got_keys=$(jq -c '[.questions[].key]' <<< "$report")
  [ "$expected_keys" = "$got_keys" ] \
    || fail "the built page did not render one question per payload question in order (expected $expected_keys, got $got_keys)"
  bad=$(jq -r '
    [.questions[] | select(.optionCount < 1 or .radioName == null or .radioName == "(mixed)")
      | .key] | join(",")
  ' <<< "$report")
  [ -z "$bad" ] \
    || fail "the built page did not render a working radio-button group for: $bad"
}

command_build() {
  local data=${1-} task='' page json tmp sid extracted
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for)
        [ "$#" -ge 2 ] || { usage >&2; exit 2; }
        task=$2
        shift 2
        ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [ -n "$task" ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "page data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "page data is not valid JSON: $data"
  validate_payload "$data" || fail "page data does not satisfy $PAGE_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "page template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "page template does not carry exactly one data slot: $TEMPLATE"

  json=$(jq -c . "$data") || fail "cannot compact the page data"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  page=$(page_path "$task")
  (umask 077; mkdir -p "${page%/*}") || fail "cannot create ${page%/*}"
  tmp=$(umask 077; mktemp "${page%/*}/.page.XXXXXX") || fail "cannot stage the page"
  # A staged page that never reaches `mv` - any refusal below - is cleaned up
  # by this trap rather than by a rm at every call site. The trap outlives
  # this function's own `local tmp`, so it reads `${tmp:-}` rather than
  # tripping `set -u` once the function has returned and `tmp` is gone.
  trap 'rm -f -- "${tmp:-}"' EXIT
  if ! FM_DECISION_PAGE_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{FM_DECISION_PAGE_JSON}/" "$TEMPLATE" > "$tmp"; then
    fail "cannot inject the page data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    fail "the page data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a page
  # that would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="decision-page-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$PAGE_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    fail "the built page does not carry a readable $PAGE_SCHEMA payload"
  fi
  # verify_render fails closed (via `fail`, which exits) rather than
  # returning, so a render-check failure never falls through to publish.
  verify_render "$data" "$tmp"
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$page"; }; then
    fail "cannot publish the page"
  fi
  printf 'page: %s\n' "$page"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  establish_page_session "$page"
  printf 'link: %s\n' "$(lavish_url_field "$ESTABLISH_OUT")"
  if ! lavish_session_listed_open "$(page_realpath "$page")"; then
    local version
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the page Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$page"

  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$page") \
    || fail "cannot derive the page source id"
  "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$page" --for "$task" >/dev/null \
    || fail "cannot arm the page as a process-event source for $task"
  printf 'armed: %s\n' "$sid"
}

case "${1-}" in
  build)
    shift
    command_build "$@"
    ;;
  path)
    shift
    task=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --for) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; task=$2; shift 2 ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    [ -n "$task" ] || { usage >&2; exit 2; }
    page_path "$task"
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
