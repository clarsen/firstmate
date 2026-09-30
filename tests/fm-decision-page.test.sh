#!/usr/bin/env bash
# Behavior tests for bin/fm-decision-page.sh: fail-closed payload validation,
# the render-proof gate refusing a page with no working controls before any
# link is printed, and a good build arming its answer source bound to the
# owning task.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PAGE="$ROOT/bin/fm-decision-page.sh"
TASK=sample-task
TMP_ROOT=$(fm_test_tmproot fm-decision-page)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

# A lavish-axi stub reproducing the shapes verified against the real
# lavish-axi 0.1.61 (the same fixture bin/fm-bearings-board.sh's suite uses):
# the plain-open shape on establish, and the session listing's `open` column
# that a build must see before it may arm anything.
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
real=$(node -e 'process.stdout.write(require("node:fs").realpathSync.native(process.argv[1]))' "$file")
printf '%s\n' "$real" > "$state/open"
jq -n --arg file "$real" \
  '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
  > "$state/state.json"
emit "$real" opened
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  # A minimal tmux-shaped task endpoint record, valid enough for
  # fm_backend_validate_task_endpoint's shape check (bin/fm-backend.sh); no
  # real tmux session is needed because register-task only validates the
  # metadata record, never sends anything to it.
  fm_write_meta "$home/state/$TASK.meta" \
    "window=fm-decision-page-tests:fm-$TASK" \
    "worktree=$home/projects/sample" \
    "project=$home/projects/sample"
  printf '%s\n' "$home"
}

run_page() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$PAGE" "$@"
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

test_path_is_task_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_page "$home" path --for "$TASK")" = "$home/data/$TASK/decision-page.html" ] \
    || fail "the page path is not the stable task-scoped location"
  pass "path prints the stable task-scoped page location"
}

test_build_refuses_malformed_payloads_before_touching_the_page() {
  local home data page rc out
  home=$(make_home refusal)
  page="$home/data/$TASK/decision-page.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_page "$home" build "$data" --for "$TASK" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-decision-page.v2"}\n' > "$data"
  set +e; out=$(run_page "$home" build "$data" --for "$TASK" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-decision-page.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq 'del(.questions[0].options)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" build "$data" --for "$TASK" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a question without options was accepted"

  write_valid_payload "$data"
  jq '.questions[0].options = []' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" build "$data" --for "$TASK" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a question with zero options was accepted"

  write_valid_payload "$data"
  jq 'del(.questions[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" build "$data" --for "$TASK" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.questions[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" build "$data" --for "$TASK" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an option with an empty label was accepted"

  write_valid_payload "$data"
  jq '.questions[0].note = "sometimes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" build "$data" --for "$TASK" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown note mode was accepted"

  write_valid_payload "$data"
  jq '.questions[0].options[0].recommended = true
      | .questions[0].options[1].recommended = true' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" build "$data" --for "$TASK" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "two recommended options on one question were accepted"

  write_valid_payload "$data"
  jq '.questions[1].key = .questions[0].key' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" build "$data" --for "$TASK" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "two questions sharing one key were accepted"

  write_valid_payload "$data"
  jq '.title = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" build "$data" --for "$TASK" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an empty page title was accepted"

  set +e; out=$(run_page "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a build with no --for task id was accepted"

  assert_absent "$page" "a refused payload still produced a page"
  pass "build refuses malformed payloads before touching the page"
}

test_build_refuses_a_page_that_does_not_render_its_controls() {
  local home data page broken_template rc out
  home=$(make_home render-refusal)
  data="$home/payload.json"
  page="$home/data/$TASK/decision-page.html"
  write_valid_payload "$data"

  # Reproduce the shipped defect class exactly: a stray edit that deletes the
  # element the choices render into. A real browser would throw dereferencing
  # the resulting null, and the render harness must catch the same failure.
  broken_template="$home/broken-template.html"
  sed 's/id="dp-questions"//' "$ROOT/bin/fm-decision-page-template.html" > "$broken_template"

  set +e
  out=$(FM_DECISION_PAGE_TEMPLATE="$broken_template" run_page "$home" build "$data" --for "$TASK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a page that cannot render its controls was accepted"
  assert_contains "$out" "fail-closed error" "the render refusal did not explain why: $out"
  assert_absent "$page" "a render-check refusal still published a page"
  [ ! -s "$home/lavish-state/open" ] \
    || fail "a render-check refusal still established a Lavish session"
  pass "build refuses a page that fails to render its controls, before any session or link"
}

test_build_renders_the_right_radio_groups_and_answer_keys() {
  local home data page out report sid
  home=$(make_home build)
  data="$home/payload.json"
  page="$home/data/$TASK/decision-page.html"
  write_valid_payload "$data"

  out=$(run_page "$home" build "$data" --for "$TASK") || fail "a valid payload did not build: $out"
  assert_contains "$out" "page: $page" "build did not report the page path: $out"
  assert_contains "$out" "link: http://127.0.0.1:4387/session/0123456789abcdef" \
    "build did not print the captain-facing link: $out"
  assert_contains "$out" "served: $page" "build did not establish the Lavish session: $out"
  assert_contains "$out" "armed: " "build did not arm the page source: $out"
  assert_present "$page" "build reported success without a page"

  extract_payload "$page" | jq -e '.schema == "fm-decision-page.v1"' >/dev/null \
    || fail "the built page does not carry a readable fm-decision-page.v1 payload"
  grep -qF '</script><b>' "$page" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_DECISION_PAGE_DATA__' "$page" \
    && fail "the data slot survived injection"

  report=$(node "$ROOT/bin/fm-decision-page-render.mjs" "$page") \
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

  # fm-procevent-lavish.sh, not fm-procevent.sh, derives a Lavish source id.
  sid=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$page")
  assert_contains "$out" "armed: $sid" "the arm confirmation does not name the page source: $out"
  run_procevent "$home" list | awk -v sid="$sid" 'NR > 1 && $1 == sid { found=1; print }
    END { exit found ? 0 : 1 }' | grep -q "task:$TASK" \
    || fail "the page source is not registered as owned by its task"
  pass "build renders one radio group per question and arms the source bound to its task"
}

test_path_is_task_scoped
test_build_refuses_malformed_payloads_before_touching_the_page
test_build_refuses_a_page_that_does_not_render_its_controls
test_build_renders_the_right_radio_groups_and_answer_keys
