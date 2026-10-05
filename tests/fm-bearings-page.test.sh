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
  poll)
    # A real blocking listener: without this the fake treated `poll` as an
    # artifact path and returned at once, so the armed listener exited and a
    # "live" owner was only a timing artifact. Bounded so an escaped listener
    # cannot outlive its test.
    limit=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
    while [ "$SECONDS" -lt "$limit" ]; do sleep 0.05; done
    exit 75
    ;;
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

# A minimal valid 1x1 transparent PNG, decoded to real image bytes so `file
# --mime-type` reports image/png exactly as it would for a real screenshot.
write_test_png() {  # <path>
  base64 -D <<< "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mL8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" \
    > "$1" 2>/dev/null \
    || base64 -d <<< "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mL8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" \
    > "$1"
}

# A minimal ISO-BMFF `ftyp` box - just enough for `file --mime-type` to read
# it as video/mp4, exactly as it would a real recording's container header.
write_test_mp4() {  # <path>
  printf '\x00\x00\x00\x14ftypisom\x00\x00\x00\x00isom' > "$1"
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

test_page_embeds_a_valid_option_and_question_image_as_a_data_uri() {
  local home data page out report png
  home=$(make_home images-ok)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  png="$home/candidate.png"
  write_test_png "$png"
  write_valid_payload "$data"
  jq --arg img "$png" '
    .questions[0].image = $img
    | .questions[0].options[0].image = $img
  ' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_page "$home" "$data" --label "$LABEL") || fail "a payload with valid images did not build: $out"
  assert_present "$page" "a valid-image build reported success without a page"

  extract_payload "$page" \
    | jq -e '
        (.questions[0].image | startswith("data:image/png;base64,"))
          and (.questions[0].options[0].image | startswith("data:image/png;base64,"))
          and (.questions[0].options[1].image == null)
      ' >/dev/null \
    || fail "the published page does not carry the resolved image(s) as data URIs"
  grep -qF "$png" "$page" \
    && fail "the published page still references the source image path instead of embedding it"

  report=$(node "$ROOT/bin/fm-bearings-page-render.mjs" "$page") \
    || fail "the built page could not be rendered: $report"
  jq -e '
    .questions[0].questionImage == true and .questions[0].optionImageCount == 1
  ' <<< "$report" >/dev/null \
    || fail "the rendered page did not draw the declared images: $report"
  pass "a valid local image on a question and an option is embedded as a data URI and renders"
}

test_page_refuses_a_missing_image_file_before_touching_the_page() {
  local home data page rc out
  home=$(make_home images-missing)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  write_valid_payload "$data"
  jq --arg img "$home/does-not-exist.png" '.questions[0].options[0].image = $img' "$data" \
    > "$data.tmp" && mv "$data.tmp" "$data"

  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload with a missing image file was accepted"
  assert_contains "$out" "does not exist" "the missing-image refusal did not say why: $out"
  assert_absent "$page" "a missing-image refusal still produced a page"
  pass "page refuses a missing image file before touching the page"
}

test_page_refuses_a_non_image_file_and_a_relative_image_path() {
  local home data page rc out nonimg
  home=$(make_home images-wrong-type)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  nonimg="$home/candidate.txt"
  printf 'not an image\n' > "$nonimg"

  write_valid_payload "$data"
  jq --arg img "$nonimg" '.questions[0].options[0].image = $img' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload with a non-image file was accepted"
  assert_contains "$out" "unsupported image type" "the wrong-type refusal did not say why: $out"
  assert_absent "$page" "a wrong-type-image refusal still produced a page"

  write_valid_payload "$data"
  jq '.questions[0].options[0].image = "relative/candidate.png"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload with a relative image path was accepted"
  assert_contains "$out" "must be absolute" "the relative-path refusal did not say why: $out"
  assert_absent "$page" "a relative-path-image refusal still produced a page"
  pass "page refuses a non-image file and a non-absolute image path"
}

test_page_refuses_an_oversized_image_file() {
  local home data page rc out big
  home=$(make_home images-oversized)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  big="$home/big.png"
  write_test_png "$big"
  # Pad well past the 5 MiB cap with trailing junk bytes; the cap is enforced
  # on file size, not on whether the bytes still parse as a real image.
  head -c 6000000 /dev/zero >> "$big"

  write_valid_payload "$data"
  jq --arg img "$big" '.questions[0].options[0].image = $img' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload with an oversized image file was accepted"
  assert_contains "$out" "exceeds the" "the oversized-image refusal did not say why: $out"
  assert_absent "$page" "an oversized-image refusal still produced a page"
  pass "page refuses an image file over the size cap"
}

test_page_embeds_a_valid_video_as_a_page_relative_asset_and_renders_it_playable() {
  local home data page out report mp4 png
  home=$(make_home videos-ok)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  mp4="$home/candidate.mp4"
  png="$home/poster.png"
  write_test_mp4 "$mp4"
  write_test_png "$png"
  write_valid_payload "$data"
  jq --arg vid "$mp4" --arg img "$png" '
    .questions[0].video = $vid
    | .questions[0].image = $img
    | .questions[0].options[0].video = $vid
  ' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_page "$home" "$data" --label "$LABEL") || fail "a payload with a valid video did not build: $out"
  assert_present "$page" "a valid-video build reported success without a page"
  assert_present "$home/data/$LABEL/assets/q0.mp4" "the question video asset was not copied beside the page"
  assert_present "$home/data/$LABEL/assets/q0-o0.mp4" "the option video asset was not copied beside the page"

  extract_payload "$page" \
    | jq -e '
        (.questions[0].video == "assets/q0.mp4")
          and (.questions[0].options[0].video == "assets/q0-o0.mp4")
          and (.questions[0].image | startswith("data:image/png;base64,"))
      ' >/dev/null \
    || fail "the published page does not carry page-relative video references"
  grep -qF "$mp4" "$page" \
    && fail "the published page still references the source video path instead of a relative asset"

  report=$(node "$ROOT/bin/fm-bearings-page-render.mjs" "$page") \
    || fail "the built page could not be rendered: $report"
  jq -e '
    .questions[0].questionVideo == true and .questions[0].questionVideoPlayable == true
      and .questions[0].optionVideoCount == 1 and .questions[0].optionVideoAllPlayable == true
  ' <<< "$report" >/dev/null \
    || fail "the rendered page did not draw the declared video(s) as playable: $report"
  pass "a valid local video on a question and an option is copied as a page-relative asset and renders playable"
}

test_page_rebuild_clears_stale_video_assets_from_a_prior_build() {
  local home data page out
  home=$(make_home videos-stale)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  write_test_mp4 "$home/candidate.mp4"
  write_valid_payload "$data"
  jq --arg vid "$home/candidate.mp4" '.questions[0].video = $vid' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_page "$home" "$data" --label "$LABEL") || fail "first video build failed: $out"
  assert_present "$home/data/$LABEL/assets/q0.mp4" "the first build did not copy its video asset"

  write_valid_payload "$data"
  out=$(run_page "$home" "$data" --label "$LABEL") || fail "the image-only rebuild failed: $out"
  assert_absent "$home/data/$LABEL/assets/q0.mp4" "a rebuild with no video left the prior build's asset behind"
  pass "a rebuild clears stale video assets a prior build left behind"
}

test_page_embeds_a_multi_megabyte_photo_without_hitting_argument_limits() {
  local home data page out report png
  home=$(make_home images-large)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  png="$home/photo.png"
  write_test_png "$png"
  # A real website photo is routinely well past ARG_MAX (about 1 MiB on
  # macOS, 128 KiB per argument on Linux) once base64-encoded; the cap is on
  # file size, so trailing bytes stand in for a photo's real pixel data.
  head -c 2000000 /dev/urandom >> "$png"
  write_valid_payload "$data"
  jq --arg img "$png" '
    .questions[0].options[0].image = $img
    | .questions[0].options[1].image = $img
  ' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_page "$home" "$data" --label "$LABEL" 2>&1) || fail "a payload with a 2 MB photo did not build: $out"
  assert_present "$page" "a large-photo build reported success without a page"
  extract_payload "$page" | jq -r '.questions[0].options[0].image' \
    | sed 's/^data:image\/png;base64,//' > "$home/embedded.b64"
  { base64 -D < "$home/embedded.b64" 2>/dev/null || base64 -d < "$home/embedded.b64"; } > "$home/embedded.png"
  cmp -s "$png" "$home/embedded.png" || fail "the embedded data URI does not decode to the source photo's bytes"

  report=$(node "$ROOT/bin/fm-bearings-page-render.mjs" "$page") \
    || fail "the built page could not be rendered: $report"
  jq -e '.questions[0].optionImageCount == 2' <<< "$report" >/dev/null \
    || fail "the rendered page did not draw the large photos: $report"
  pass "a multi-megabyte photo is embedded byte-for-byte and renders"
}

test_page_refused_rebuild_leaves_the_published_page_and_assets_intact() {
  local home data page out rc
  home=$(make_home videos-refused-rebuild)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  write_test_mp4 "$home/candidate.mp4"
  write_valid_payload "$data"
  jq --arg vid "$home/candidate.mp4" '.questions[0].video = $vid' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_page "$home" "$data" --label "$LABEL") || fail "first video build failed: $out"
  cp "$page" "$home/published.html"

  jq --arg img "$home/does-not-exist.png" '.questions[0].options[0].image = $img' "$data" \
    > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a rebuild with a missing image file was accepted"
  cmp -s "$page" "$home/published.html" || fail "a refused rebuild changed the published page"
  assert_present "$home/data/$LABEL/assets/q0.mp4" "a refused rebuild deleted the published page's video asset"
  [ -z "$(find "$home/data/$LABEL" -maxdepth 1 -name '.*')" ] \
    || fail "a refused rebuild left staging files behind: $(ls -A "$home/data/$LABEL")"
  pass "a refused rebuild leaves the published page and its video assets intact"
}

test_page_refuses_a_media_source_inside_the_builder_owned_assets_directory() {
  local home data page out rc src
  home=$(make_home images-in-assets)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  mkdir -p "$home/data/$LABEL/assets"
  src="$home/data/$LABEL/assets/hero.png"
  write_test_png "$src"
  write_valid_payload "$data"
  jq --arg img "$src" '.questions[0].options[0].image = $img' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a media source inside the builder-owned assets directory was accepted"
  assert_contains "$out" "builder-owned assets directory" "the assets-dir refusal did not say why: $out"
  assert_present "$src" "the refusal deleted the mate's source photo"
  assert_absent "$page" "an assets-dir-source refusal still produced a page"
  pass "page refuses a media source inside its own assets directory and leaves it in place"
}

test_page_refuses_a_missing_video_file_before_touching_the_page() {
  local home data page rc out
  home=$(make_home videos-missing)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  write_valid_payload "$data"
  jq --arg vid "$home/does-not-exist.mp4" '.questions[0].options[0].video = $vid' "$data" \
    > "$data.tmp" && mv "$data.tmp" "$data"

  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload with a missing video file was accepted"
  assert_contains "$out" "does not exist" "the missing-video refusal did not say why: $out"
  assert_absent "$page" "a missing-video refusal still produced a page"
  pass "page refuses a missing video file before touching the page"
}

test_page_refuses_a_non_video_file_and_a_relative_video_path() {
  local home data page rc out nonvid
  home=$(make_home videos-wrong-type)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  nonvid="$home/candidate.txt"
  printf 'not a video\n' > "$nonvid"

  write_valid_payload "$data"
  jq --arg vid "$nonvid" '.questions[0].options[0].video = $vid' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload with a non-video file was accepted"
  assert_contains "$out" "unsupported video type" "the wrong-type refusal did not say why: $out"
  assert_absent "$page" "a wrong-type-video refusal still produced a page"

  write_valid_payload "$data"
  jq '.questions[0].options[0].video = "relative/candidate.mp4"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload with a relative video path was accepted"
  assert_contains "$out" "must be absolute" "the relative-path refusal did not say why: $out"
  assert_absent "$page" "a relative-path-video refusal still produced a page"
  pass "page refuses a non-video file and a non-absolute video path"
}

test_page_refuses_an_oversized_video_file() {
  local home data page rc out big
  home=$(make_home videos-oversized)
  data="$home/payload.json"
  page="$home/data/$LABEL/decision-page.html"
  big="$home/big.mp4"
  write_test_mp4 "$big"
  # Pad well past the 25 MiB (26,214,400-byte) cap; the cap is enforced on
  # file size alone.
  head -c 27000000 /dev/zero >> "$big"

  write_valid_payload "$data"
  jq --arg vid "$big" '.questions[0].options[0].video = $vid' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_page "$home" "$data" --label "$LABEL" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload with an oversized video file was accepted"
  assert_contains "$out" "exceeds the" "the oversized-video refusal did not say why: $out"
  assert_absent "$page" "an oversized-video refusal still produced a page"
  pass "page refuses a video file over the size cap"
}

test_page_path_is_label_scoped
test_page_refuses_malformed_payloads_before_touching_the_page
test_page_refuses_a_page_that_does_not_render_its_controls
test_page_renders_the_right_radio_groups_and_answer_keys
test_page_arms_a_firstmate_owned_source_never_a_task_owned_one
test_page_rebuild_after_the_session_ended_arms_a_fresh_source
test_page_embeds_a_valid_option_and_question_image_as_a_data_uri
test_page_refuses_a_missing_image_file_before_touching_the_page
test_page_refuses_a_non_image_file_and_a_relative_image_path
test_page_refuses_an_oversized_image_file
test_page_embeds_a_valid_video_as_a_page_relative_asset_and_renders_it_playable
test_page_rebuild_clears_stale_video_assets_from_a_prior_build
test_page_embeds_a_multi_megabyte_photo_without_hitting_argument_limits
test_page_refused_rebuild_leaves_the_published_page_and_assets_intact
test_page_refuses_a_media_source_inside_the_builder_owned_assets_directory
test_page_refuses_a_missing_video_file_before_touching_the_page
test_page_refuses_a_non_video_file_and_a_relative_video_path
test_page_refuses_an_oversized_video_file
