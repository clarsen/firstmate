#!/usr/bin/env bash
# Behavior tests for `bin/fm-bearings-board.sh page`: fail-closed payload
# validation, the render-proof gate refusing a page with no working controls
# before any link is printed, and a good build binding and arming its answer
# source as a FIRSTMATE-OWNED process-event source (never a task-owned one,
# which would deliver the captain's answer into some task's worker inbox
# instead of to firstmate's own check wake).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
LABEL=sample-question
TMP_ROOT=$(fm_test_tmproot fm-bearings-page)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

# A lavish-axi stub reproducing the shapes verified against the real
# lavish-axi 0.1.61 (the same fixture bin/fm-bearings-board.sh's build suite
# uses): the plain-open shape on establish, and the session listing's `open`
# column that a page build must see before it may bind or arm anything.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
state=${LAVISH_FAKE_STATE:?}
emit() {  # <canonical-file> <status>
  printf 'session:\n'
  printf '  file: %s\n' "$1"
  printf '  url: "http://127.0.0.1:4387/session/0123456789abcdef"\n'
  printf '  status: %s\n' "$2"
}
case "${1-}" in
  --version) printf '0.1.61\n'; exit 0 ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    if [ -s "$state/open" ]; then
      while IFS= read -r listed; do
        [ -n "$listed" ] || continue
        printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$listed"
      done < "$state/open"
    fi
    exit 0
    ;;
esac
file=$1
shift
reopen=0
[ "${1-}" = --reopen ] && reopen=1
real=$(node -e 'process.stdout.write(require("node:fs").realpathSync.native(process.argv[1]))' "$file")
if [ -e "$state/ended" ] && [ "$reopen" = 0 ]; then
  : > "$state/open"
  emit "$real" ended
  exit 0
fi
rm -f "$state/ended"
printf '%s\n' "$real" > "$state/open"
jq -n --arg file "$real" \
  '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
  > "$state/state.json"
emit "$real" opened
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

run_page() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" page "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_lavish_source_id() {  # <home> <page>
  local home=$1 page=$2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$page"
}

write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-decision-page.v1",
  "title": "Pick an approach",
  "eyebrow": "Captain's call",
  "lead": "A payload string that tries to break out: </script><b>x</b>",
  "questions": [
    {
      "key": "approach",
      "title": "Which approach?",
      "body": "Option A is quick, option B is thorough.",
      "options": [
        { "value": "a", "label": "Quick patch" },
        { "value": "b", "label": "Thorough rebuild", "recommended": true, "hint": "takes longer" }
      ],
      "note": "optional"
    },
    {
      "key": "timing",
      "title": "When?",
      "options": [
        { "value": "now", "label": "Now" },
        { "value": "later", "label": "Later" }
      ]
    }
  ]
}
EOF
}

extract_payload() {  # <page-path>
  sed -n '/<script id="decision-page-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

test_page_path_is_label_scoped() {
  local home
  home=$(make_home path)
  [ "$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BOARD" page-path --label "$LABEL")" \
      = "$home/data/$LABEL/decision-page.html" ] \
    || fail "the page path is not the stable label-scoped location"
  pass "page-path prints the stable label-scoped page location"
}

test_page_refuses_malformed_payloads_before_touching_the_page() {
  local home data page rc out
  home=$(make_home refusal)
  page="$home/data/$LABEL/decision-page.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-decision-page.v2"}\n' > "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-decision-page.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq 'del(.questions[0].options)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a question without options was accepted"

  write_valid_payload "$data"
  jq '.questions[0].options = []' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a question with zero options was accepted"

  write_valid_payload "$data"
  jq 'del(.questions[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.questions[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an option with an empty label was accepted"

  write_valid_payload "$data"
  jq '.questions[0].note = "sometimes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown note mode was accepted"

  write_valid_payload "$data"
  jq '.questions[0].options[0].recommended = true
      | .questions[0].options[1].recommended = true' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "two recommended options on one question were accepted"

  write_valid_payload "$data"
  jq '.questions[1].key = .questions[0].key' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "two questions sharing one key were accepted"

  write_valid_payload "$data"
  jq '.title = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an empty page title was accepted"

  set +e; out=$(run_page "$home" "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a build with no --label was accepted"

  assert_absent "$page" "a refused payload still produced a page"
  pass "page refuses malformed payloads before touching the page"
}

test_page_refuses_a_page_that_does_not_render_its_controls() {
  local home data page broken_template rc out
  home=$(make_home render-refusal)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  write_valid_payload "$data"

  # Reproduce the shipped defect class exactly: a stray edit that deletes the
  # element the choices render into. A real browser would throw dereferencing
  # the resulting null, and the render harness must catch the same failure.
  broken_template="$home/broken-template.html"
  sed 's/id="dp-questions"//' "$ROOT/.agents/skills/bearings/assets/page-template.html" > "$broken_template"

  set +e
  out=$(FM_BEARINGS_PAGE_TEMPLATE="$broken_template" run_page "$home" "$data" --label "$LABEL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a page that cannot render its controls was accepted"
  assert_contains "$out" "fail-closed error" "the render refusal did not explain why: $out"
  assert_absent "$page" "a render-check refusal still published a page"
  [ ! -s "$home/lavish-state/open" ] \
    || fail "a render-check refusal still established a Lavish session"
  pass "page refuses a page that fails to render its controls, before any session or link"
}

test_page_renders_the_right_radio_groups_and_answer_keys() {
  local home data page out report sid
  home=$(make_home build)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  write_valid_payload "$data"

  out=$(run_page "$home" "$data" --label "$LABEL") || fail "a valid payload did not build: $out"
  assert_contains "$out" "page: $page" "build did not report the page path: $out"
  assert_contains "$out" "link: http://127.0.0.1:4387/session/0123456789abcdef" \
    "build did not print the captain-facing link: $out"
  assert_contains "$out" "served: $page" "build did not establish the Lavish session: $out"
  assert_contains "$out" "bound: " "build did not bind the page source: $out"
  assert_contains "$out" "armed: " "build did not arm the page source: $out"
  assert_present "$page" "build reported success without a page"

  extract_payload "$page" | jq -e '.schema == "fm-decision-page.v1"' >/dev/null \
    || fail "the built page does not carry a readable fm-decision-page.v1 payload"
  grep -qF '</script><b>' "$page" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_DECISION_PAGE_DATA__' "$page" \
    && fail "the data slot survived injection"
  grep -qxF '__FM_DECISION_CARD_CSS__' "$page" \
    && fail "the decision-card CSS slot survived injection"
  grep -qxF '__FM_DECISION_CARD_JS__' "$page" \
    && fail "the decision-card JS slot survived injection"

  report=$(node "$ROOT/bin/fm-bearings-page-render.mjs" "$page") \
    || fail "the built page could not be rendered: $report"
  [ "$(jq -r '.error' <<< "$report")" = "" ] \
    || fail "the built page rendered its fail-closed error: $report"
  jq -e '
    (.questions | length) == 2
      and (.questions[0] | .key == "approach" and .optionCount == 2
        and .radioName == "answer" and .hasNote == true)
      and (.questions[1] | .key == "timing" and .optionCount == 2
        and .radioName == "answer" and .hasNote == false)
  ' <<< "$report" >/dev/null \
    || fail "the built page did not render one radio group per question with the right keys: $report"

  sid=$(run_lavish_source_id "$home" "$page")
  assert_contains "$out" "bound: $sid" "the binding does not name the page source: $out"
  assert_contains "$out" "armed: $sid" "the arm confirmation does not name the page source: $out"
  pass "page renders one radio group per question and arms its answer source"
}

test_page_arms_a_firstmate_owned_source_never_a_task_owned_one() {
  local home data page out sid row
  home=$(make_home ownership)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  write_valid_payload "$data"

  out=$(run_page "$home" "$data" --label "$LABEL") || fail "a valid payload did not build: $out"
  sid=$(run_lavish_source_id "$home" "$page")
  row=$(run_procevent "$home" list | awk -v sid="$sid" 'NR > 1 && $1 == sid')
  [ -n "$row" ] || fail "the page source is not registered at all: $(run_procevent "$home" list)"
  case "$row" in
    *"task:"*) fail "the page source is task-owned, so its answer would be delivered to a worker's inbox instead of firstmate's own check wake: $row" ;;
  esac
  printf '%s\n' "$row" | awk '{ print $3 }' | grep -qx live \
    || fail "the page source is not listed as a live, firstmate-owned listener: $row"
  pass "the page source is a firstmate-owned listener, never task-owned"
}

test_page_rebuild_after_the_session_ended_arms_a_fresh_source() {
  local home data page out sid row
  home=$(make_home reopen)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  write_valid_payload "$data"

  out=$(run_page "$home" "$data" --label "$LABEL") || fail "first build failed: $out"
  touch "$home/lavish-state/ended"
  out=$(run_page "$home" "$data" --label "$LABEL") || fail "rebuild after the session ended failed: $out"
  assert_contains "$out" "session: reopened" "the rebuild did not reopen the ended session: $out"
  assert_contains "$out" "armed: " "the rebuild did not arm a fresh source: $out"
  case "$out" in
    *already-armed*) fail "the rebuild kept the pre-reopen source generation: $out" ;;
  esac
  sid=$(run_lavish_source_id "$home" "$page")
  row=$(run_procevent "$home" list | awk -v sid="$sid" 'NR > 1 && $1 == sid')
  printf '%s\n' "$row" | awk '{ print $3 }' | grep -qx live \
    || fail "the rebuilt page source is not live: $row"
  pass "a rebuild after the session ended retires and re-arms the source"
}

test_page_path_is_label_scoped
test_page_refuses_malformed_payloads_before_touching_the_page
test_page_refuses_a_page_that_does_not_render_its_controls
test_page_renders_the_right_radio_groups_and_answer_keys
test_page_arms_a_firstmate_owned_source_never_a_task_owned_one
test_page_rebuild_after_the_session_ended_arms_a_fresh_source
