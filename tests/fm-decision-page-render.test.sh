#!/usr/bin/env bash
# Behavior tests for the shipped decision-page renderer
# (bin/fm-decision-page-template.html) and its render-check harness
# (bin/fm-decision-page-render.mjs), exercised by injecting a payload into the
# real template exactly as bin/fm-decision-page.sh build does, then executing
# the built page's own inline script under the minimal DOM shim. Assertions
# are on what the page renders - radio groups, option counts, note fields,
# the fail-closed error - never on the template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEMPLATE="$ROOT/bin/fm-decision-page-template.html"
HARNESS="$ROOT/bin/fm-decision-page-render.mjs"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

# Inject <payload-json> into a copy of the real template (same slot-injection
# fm-decision-page.sh build uses) and print what the render-check harness
# reports for it.
render() {  # <home> <payload-json> [template]
  local home=$1 payload=$2 template=${3:-$TEMPLATE} page="$1/page.html" json
  json=$(jq -c . <<< "$payload")
  json=${json//</\\u003c}
  FM_DECISION_PAGE_JSON="$json" perl -pe 's/^\Q__FM_DECISION_PAGE_DATA__\E$/$ENV{FM_DECISION_PAGE_JSON}/' \
    "$template" > "$page"
  node "$HARNESS" "$page" || fail "the built page could not be rendered"
}

test_two_questions_each_render_their_own_radio_group() {
  local home out
  home=$(fm_test_tmproot render-two-questions)
  out=$(render "$home" '{
    "schema": "fm-decision-page.v1",
    "title": "Pick a fix",
    "questions": [
      { "key": "q1", "title": "First", "options": [
        {"value":"a","label":"A"}, {"value":"b","label":"B"} ] },
      { "key": "q2", "title": "Second", "options": [
        {"value":"x","label":"X"} ], "note": "required" }
    ]
  }')
  jq -e '
    .error == ""
      and (.questions | length) == 2
      and (.questions[0] | .key == "q1" and .optionCount == 2
        and (.radioName | type) == "string" and .hasNote == false)
      and (.questions[1] | .key == "q2" and .optionCount == 1 and .hasNote == true)
  ' <<< "$out" >/dev/null || fail "two questions did not each render their own radio group: $out"
  pass "two questions each render exactly one radio group with their own answer key"
}

test_a_question_with_no_options_never_reaches_the_page() {
  local home out
  home=$(fm_test_tmproot render-empty-options)
  # The template's own fail-closed guard, not payload validation, is under
  # test here: a payload bin/fm-decision-page.sh would itself refuse (an empty
  # options array) must also make the shipped renderer refuse rather than
  # silently draw a control-less card, in case anything ever reaches it with
  # validation bypassed.
  out=$(render "$home" '{
    "schema": "fm-decision-page.v1",
    "title": "Broken",
    "questions": [ { "key": "q1", "title": "First", "options": [] } ]
  }')
  jq -e '.error != "" and (.questions | length) == 0' <<< "$out" >/dev/null \
    || fail "a question with no options rendered as if it had controls: $out"
  pass "a question with no options renders the fail-closed error, not an empty control"
}

test_a_wrong_schema_payload_renders_the_fail_closed_error() {
  local home out
  home=$(fm_test_tmproot render-wrong-schema)
  out=$(render "$home" '{"schema":"fm-decision-page.v2","title":"x","questions":[]}')
  jq -e '.error | contains("Unsupported")' <<< "$out" >/dev/null \
    || fail "a wrong-schema payload did not render the fail-closed error: $out"
  pass "a wrong-schema payload renders the fail-closed error"
}

test_a_recommended_option_and_a_hint_survive_render() {
  local home out
  home=$(fm_test_tmproot render-recommend)
  out=$(render "$home" '{
    "schema": "fm-decision-page.v1",
    "title": "Pick one",
    "questions": [
      { "key": "q1", "title": "First", "options": [
        {"value":"a","label":"A","hint":"careful"},
        {"value":"b","label":"B","recommended":true} ] }
    ]
  }')
  jq -e '.questions[0].optionCount == 2 and .error == ""' <<< "$out" >/dev/null \
    || fail "a hinted and recommended option pair did not render: $out"
  pass "a hinted option and a recommended option both still render"
}

test_deleting_the_questions_container_is_caught_as_a_render_failure() {
  local home out broken_template
  home=$(fm_test_tmproot render-deleted-container)
  # Reproduces the exact shipped defect: a stray edit deletes the element the
  # choices render into. A real browser dereferences the resulting null and
  # throws; the harness must surface the same failure rather than silently
  # minting a substitute container that was never actually on the page.
  broken_template="$home/broken-template.html"
  sed 's/id="dp-questions"//' "$TEMPLATE" > "$broken_template"
  out=$(render "$home" '{
    "schema": "fm-decision-page.v1",
    "title": "Pick one",
    "questions": [ { "key": "q1", "title": "First", "options": [{"value":"a","label":"A"}] } ]
  }' "$broken_template")
  jq -e '.error != "" and (.questions | length) == 0' <<< "$out" >/dev/null \
    || fail "deleting the questions container did not surface as a render failure: $out"
  pass "deleting the questions container is caught, not silently tolerated"
}

test_two_questions_each_render_their_own_radio_group
test_a_question_with_no_options_never_reaches_the_page
test_a_wrong_schema_payload_renders_the_fail_closed_error
test_a_recommended_option_and_a_hint_survive_render
test_deleting_the_questions_container_is_caught_as_a_render_failure
