#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board, and
# build and arm one-off captain question pages.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. A one-off captain question or
# checklist page is the shipped page template
# (.agents/skills/bearings/assets/page-template.html) plus one injected
# fm-decision-page.v1 JSON payload. Both templates render every question or
# decision as the exact same card, built by the one shared source
# (.agents/skills/bearings/assets/decision-card.{css,js}), so this script owns
# the mechanics for both and the invoking agent's per-run work stays "compose
# the JSON, run build/page" - the agent never authors board or page UI at
# invocation time.
#
# Usage:
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh path
#   fm-bearings-board.sh page <data.json> --label <label>
#   fm-bearings-board.sh page-path --label <label>
#
# build      Validate the payload, drop the Captain's Call cards whose subject
#            already landed, give every surviving decision card the standard
#            reconcile choice, and inject the result (plus the shared
#            decision-card CSS/JS) into a fresh copy of the shipped template at
#            the stable board path. Establish the Lavish session on that board
#            and PROVE it is live BEFORE binding and arming its answer source,
#            so a registered poll can never race a session that does not exist
#            or attach to one that has ended. Bind to the keyed-answer intake
#            (bin/fm-captain-hold.sh) ALWAYS precedes arm, so the board can
#            never produce an answer that has nowhere to go
#            (captain-hold-lifecycle's ordering rule, enforced here rather
#            than left to agent memory). Output starts with `board: <path>`,
#            then includes lavish-axi's session output and the remaining
#            status:
#              session: live | reopened
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#              listening: <owner>            (only when a replacement was needed)
#            Every dropped card is named on stderr as a `dropped-landed-card:`
#            line, so a rebuild states what it removed instead of quietly
#            shrinking Captain's Call.
# path       Print the stable board path for this home.
# page       Validate a small fm-decision-page.v1 payload (title, lead,
#            questions with options, an optional recommended option, and a
#            note policy), inject it (plus the shared decision-card CSS/JS)
#            into a fresh copy of the shipped page template at the
#            label-scoped page path - never the stable board path above, so a
#            one-off page can never replace the fleet board. PROVE under a
#            real headless DOM execution (bin/fm-bearings-page-render.mjs,
#            node) that every question rendered exactly one radio-button group
#            with at least one option before doing anything visible to the
#            captain, establish the Lavish session on that page and PROVE it
#            is live BEFORE binding and arming its answer source (the same
#            order and liveness proof `build` uses above), then bind and arm
#            it as a FIRSTMATE-OWNED process-event source - `register`, never
#            `register-task`. These pages exist for firstmate to act on, so an
#            answer must always reach firstmate as its own `check:` wake
#            (bin/fm-procevent-lavish.sh read/answers), never a steer
#            delivered into some task's worker inbox, where it can sit unread
#            for as long as that worker stays parked at a gate. <label> only
#            scopes the page's on-disk path and is never passed to the
#            process-event registration. Output:
#              page: <path>
#              (lavish-axi's own establish output, including its own `url:`
#               field)
#              session: live | reopened
#              link: <url>              the captain-facing page URL
#              served: <path>
#              bound: <source-id>
#              armed: <source-id> | already-armed: <source-id>
#              listening: live         (only when a replacement was needed)
#            A payload that fails validation, or a built page whose render
#            check fails, is refused with a clear message: no page is
#            published, no session is established, nothing is bound or armed,
#            and no link is printed.
# page-path  Print the stable page path for <label>.
#
# Payload schema fm-decision-page.v1, validated fail-closed with jq exactly as
# fm-bearings-board.v1 is below:
#   schema      "fm-decision-page.v1"
#   title       non-empty string: the page <title> and header
#   eyebrow     optional string: the small label above the title
#   lead        optional string: intro copy under the title
#   questions   non-empty array, each:
#     key           slug, 1-128 chars of [A-Za-z0-9._-]: the answer's question id.
#                   bin/fm-captain-hold.sh binds this source any-origin, so a
#                   key that happens to be a captain-held task id resolves
#                   that hold directly; any other key still delivers as an
#                   ordinary answer on the source's check wake.
#     title         non-empty string
#     body          optional string
#     image         optional string: an absolute local path to an image file
#                   shown above the question's options (a still frame is fine
#                   for a video candidate; inline video playback is not
#                   supported)
#     options       non-empty array of { value: slug, label: non-empty string,
#                   hint: optional string, recommended: optional boolean,
#                   image: optional string }; at most one option may carry
#                   recommended: true
#     note          optional, one of "none" (default), "optional", "required";
#                   anything but "none" adds a freeform note field, and
#                   "required" refuses to queue an answer with no note
#
# IMAGES ARE RESOLVED, NEVER LINKED. A question's or option's `image` is an
# absolute local filesystem path - typically under a home's data/ directory,
# possibly a secondmate home elsewhere on disk - never a path relative to this
# script or a URL. `page` resolves every such path before publishing: it
# refuses unless the path exists, is a regular file (never a symlink), is
# IMAGE_MAX_BYTES (5 MiB) or smaller, and `file --mime-type` reports one of
# image/png, image/jpeg, image/gif, or image/webp. A resolved image is
# embedded as a `data:` URI directly in the published page, so the page is
# fully self-contained and needs no separate file reachable from wherever
# Lavish serves it. This is presentation only: an image never changes an
# answer's key or value, and the render-proof harness
# (bin/fm-bearings-page-render.mjs) asserts only on rendered controls, never
# on image bytes.
#
# RENDER-PROVEN BEFORE A PAGE'S LINK EVER SHIPS. `page` stages the page at a
# temporary path and runs it through bin/fm-bearings-page-render.mjs, which
# executes the built page's own inline scripts under a minimal DOM shim (the
# same headless-parse pattern tests/assets/board-render-harness.mjs uses for
# the /bearings board) and reports what actually rendered. The build refuses
# unless that report names exactly one question per payload question, each
# with at least one radio option sharing one name, and no fail-closed render
# error. Only then does the staged page replace the published one. This
# exists because a hand-copied and hand-edited page once lost the element its
# choices render into to a stray line-index edit, and another shipped a
# JavaScript syntax error that stopped the script before any control drew -
# neither was checked before the link went to the captain, and no build here
# can recur that: it either proves its own page renders working controls, or
# it refuses with no link.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id, so exit status alone
# cannot tell a live board or page from a dead one. build/page require the
# server's fresh session listing to show the canonical artifact open and
# refuse rather than arming an ended session. After a reopen it retires the
# pre-reopen source generation through the guarded adapter path, arms a fresh
# registration, and accepts only the replacement listener as live. A
# registered board or page with no live owner also gets a replacement before
# the command returns, because `already-armed` is not the same fact as
# `listening`.
#
# CAPTAIN'S CALL HYGIENE. A decision card is dropped when its work item, PR, or
# structured artifact/version subject appears among the payload's own landed
# rows, or when `bin/fm-captain-hold.sh open` reports the task is no longer an
# open captain call. A newer published version also supersedes a version card.
# A task whose state cannot be established is kept, because a call wrongly
# hidden is worse than a card wrongly shown. Cleanup is therefore a normal
# rebuild effect rather than a committed migration or direct state mutation.
#
# THE RECONCILE CHOICE. Every decision card carries the standard `reconcile`
# option, injected here so the guarantee does not depend on the composer's
# memory, and the payload validator reserves that value across every card type.
# The validator's reservation scope must equal the adapter's reconcile
# classification scope, which is all card types because the captured payload
# carries no card type. Its meaning, and the reason it can never reach the
# keyed-answer intake as a blind close, are owned by
# docs/captain-hold-lifecycle.md.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# Every Underway row likewise carries a non-empty `name`: the durable task name
# when known, otherwise its durable identifier.
# A Charted Next row MAY carry `filed`, the durable filed date (YYYY-MM-DD, or
# that date with a UTC timestamp) the template orders the section by, newest
# first; a row with no comparable date keeps its payload order after every dated
# row. Anything else in that field refuses rather than sorting on garbage.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. A page path is
# stable per label - $FM_HOME/data/<label>/decision-page.html - for the same
# reason. Injection escapes every `<` in the compact JSON as the < string
# escape, so a payload string containing "</script>" can never terminate the
# data block early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped board template path (tests
# only). FM_BEARINGS_PAGE_TEMPLATE overrides the shipped page template path
# (tests only). FM_BEARINGS_PAGE_RENDER_HARNESS overrides the page render-check
# harness path (tests only). FM_BEARINGS_DECISION_CARD_CSS and
# FM_BEARINGS_DECISION_CARD_JS override the shared decision-card asset paths
# (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1

PAGE_TEMPLATE="${FM_BEARINGS_PAGE_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/page-template.html}"
PAGE_PLACEHOLDER='__FM_DECISION_PAGE_DATA__'
PAGE_SCHEMA=fm-decision-page.v1
RENDER_HARNESS="${FM_BEARINGS_PAGE_RENDER_HARNESS:-$SCRIPT_DIR/fm-bearings-page-render.mjs}"

# The one shared decision-card source both templates inject verbatim; see
# .agents/skills/bearings/assets/decision-card.{css,js}.
DECISION_CARD_CSS="${FM_BEARINGS_DECISION_CARD_CSS:-$SCRIPT_DIR/../.agents/skills/bearings/assets/decision-card.css}"
DECISION_CARD_JS="${FM_BEARINGS_DECISION_CARD_JS:-$SCRIPT_DIR/../.agents/skills/bearings/assets/decision-card.js}"
CSS_PLACEHOLDER='__FM_DECISION_CARD_CSS__'
JS_PLACEHOLDER='__FM_DECISION_CARD_JS__'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }
page_path() { printf '%s/data/%s/decision-page.html\n' "$FM_HOME" "$1"; }  # <label>

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def name_marker: has("name") and (.name | nonempty_string);
    def valid_filed:
      . as $filed
      | type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
      and (if test("T")
        then try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $filed) catch false
        else try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $filed) catch false
        end);
    def optional_filed:
      (has("filed") | not) or (.filed == null) or (.filed | valid_filed);
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
    def optional_subject:
      (has("subject") | not)
      or (.subject
        | type == "object"
          and (keys | sort) == ["artifact", "version"]
          and (.artifact | slug(128))
          and (.version | version));
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_https_url("pr_url"))
      and optional_subject
      and (if has("subject") then .type == "decision" else true end)
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend
            | ([.options[].value] | index($recommend) != null))))
      and ([.options[].value] | index("reconcile") == null)
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
    def underway_item:
      type == "object" and repo_marker and name_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string);
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and optional_subject;
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and optional_filed
      and (if .kind == "warning" then .dispatchable == false else true end);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null
}

validate_page_payload() {  # <data.json>
  jq -e --arg schema "$PAGE_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def option:
      type == "object"
      and (.value | slug(128))
      and (.label | nonempty_string)
      and optional_string("hint")
      and optional_string("image")
      and ((has("recommended") | not) or (.recommended | type == "boolean"));
    def question:
      type == "object"
      and (.key | slug(128))
      and (.title | nonempty_string)
      and optional_string("body")
      and optional_string("image")
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

# --- Shared decision-card assets ---------------------------------------------
# Both templates carry the two slots below (__FM_DECISION_CARD_CSS__,
# __FM_DECISION_CARD_JS__) and inject the same shared source verbatim, so the
# decision card exists in exactly one place rather than two hand-maintained
# copies. Injection is fail-closed: a missing shared asset or a template that
# has lost either slot refuses rather than publishing a page or board with a
# broken card.
inject_shared_assets() {  # <in> <out>
  local in=$1 out=$2 mid css js
  [ -f "$DECISION_CARD_CSS" ] || { printf 'shared decision-card CSS is missing: %s\n' "$DECISION_CARD_CSS" >&2; return 1; }
  [ -f "$DECISION_CARD_JS" ] || { printf 'shared decision-card JS is missing: %s\n' "$DECISION_CARD_JS" >&2; return 1; }
  [ "$(grep -cxF "$CSS_PLACEHOLDER" "$in")" -eq 1 ] \
    || { printf 'template does not carry exactly one decision-card CSS slot: %s\n' "$in" >&2; return 1; }
  [ "$(grep -cxF "$JS_PLACEHOLDER" "$in")" -eq 1 ] \
    || { printf 'template does not carry exactly one decision-card JS slot: %s\n' "$in" >&2; return 1; }
  css=$(cat "$DECISION_CARD_CSS") || return 1
  js=$(cat "$DECISION_CARD_JS") || return 1
  mid=$(umask 077; mktemp "${out%/*}/.assets-mid.XXXXXX") || return 1
  if ! FM_SHARED_CSS="$css" perl -pe "s/^\\Q$CSS_PLACEHOLDER\\E\$/\$ENV{FM_SHARED_CSS}/" "$in" > "$mid"; then
    rm -f -- "$mid"
    return 1
  fi
  if ! FM_SHARED_JS="$js" perl -pe "s/^\\Q$JS_PLACEHOLDER\\E\$/\$ENV{FM_SHARED_JS}/" "$mid" > "$out"; then
    rm -f -- "$mid"
    return 1
  fi
  rm -f -- "$mid"
  if grep -qxF "$CSS_PLACEHOLDER" "$out" || grep -qxF "$JS_PLACEHOLDER" "$out"; then
    return 1
  fi
}

# --- Lavish session liveness -------------------------------------------------
# Verified against lavish-axi 0.1.61. `lavish-axi <file>` EXITS 0 even when it
# refuses to reopen a session the captain ended from the browser, reporting
# `status: user-ended` and the same session id, so an exit-code check alone
# cannot tell a live board or page from a dead one. The establish status is an
# initial signal only; the server's fresh session listing must also show the
# canonical artifact open before build/page may bind or arm its source.

artifact_realpath() {  # <file>
  "$SCRIPT_DIR/fm-procevent-lavish.sh" canonical-path "$1" 2>/dev/null
}

lavish_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

lavish_url_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The server's own listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>`, and only a live session is listed `open`.
lavish_session_listed_open() {  # <canonical-path>
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

# Establish <kind>'s (e.g. "board" or "page") Lavish session and PROVE it is
# live before anything arms a poll on it. A session the captain ended is
# reopened once - the captain asked for this artifact, which is exactly the
# attention `--reopen` exists for - and a session that is still not live after
# that refuses the build rather than arming a poll that can never attach. Sets
# LAVISH_SESSION_REOPENED and LAVISH_ESTABLISH_OUT for the caller.
establish_lavish_session() {  # <kind> <file>
  local kind=$1 file=$2 real out status version
  LAVISH_SESSION_REOPENED=0
  real=$(artifact_realpath "$file") || fail "cannot resolve the $kind path: $file"
  out=$(lavish-axi "$file") || fail "cannot establish the $kind Lavish session"
  printf '%s\n' "$out"
  if lavish_session_listed_open "$real"; then
    printf 'session: live\n'
    LAVISH_ESTABLISH_OUT=$out
    return 0
  fi
  out=$(lavish-axi "$file" --reopen) || fail "cannot reopen the ended $kind Lavish session"
  printf '%s\n' "$out"
  if lavish_session_listed_open "$real"; then
    LAVISH_SESSION_REOPENED=1
    printf 'session: reopened\n'
    LAVISH_ESTABLISH_OUT=$out
    return 0
  fi
  status=$(lavish_status_field "$out")
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the $kind Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# --- Captain's Call hygiene ---------------------------------------------------
# A held decision whose subject already shipped is not a live call, so it is
# dropped here instead of being carded again. All checks use exact structured
# identities; unknown subject state keeps the card.

decision_card_is_stale() {  # <task-id> <landed-0-or-1>
  local task=$1 landed=$2 rc=0
  if [ "$landed" = 1 ]; then
    printf 'structured subject already landed\n'
    return 0
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
  # 1 is a definite "no longer an open captain call". 2 is "cannot tell", 3 is
  # absent from this backlog, and a call wrongly hidden is worse than a card
  # wrongly shown, so both uncertain and absent cards stay.
  if [ "$rc" -eq 1 ]; then
    printf 'no longer an open captain call\n'
    return 0
  fi
  return 1
}

# Drop every stale decision card, then give every surviving decision card the
# standard reconcile choice. Injecting it here is what makes "every decision
# card offers reconcile" a property of the board rather than of the composer's
# memory; the validator prevents duplicate decision options.
effective_payload() {  # <data.json> <dest.json>
  local data=$1 dest=$2 landed_keys key reason drop='' tmp landed=0
  landed_keys=$(jq -c '
    def version_parts: split(".") | map(tonumber);
    . as $payload
    | [$payload.captains_call[]
      | select(.type == "decision")
      | . as $card
      | select(
          ($payload.landed | any(.id == $card.key))
          or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url)))
          or (($card.subject? != null) and ($payload.landed | any(
            (.subject? != null)
            and (.subject.artifact == $card.subject.artifact)
            and ((.subject.version | version_parts) >= ($card.subject.version | version_parts)))))
        )
      | .key]
  ' "$data") || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    landed=0
    if jq -e --arg key "$key" 'index($key) != null' <<< "$landed_keys" >/dev/null; then
      landed=1
    fi
    reason=$(decision_card_is_stale "$key" "$landed") || continue
    printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
    drop=$drop$key$'\n'
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" '
    .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | if .type == "decision"
        then .options += [{
          value: "reconcile",
          label: "Reconcile",
          hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
        }]
        else . end
    ]' "$data" > "$dest" || return 1
}

# The OWNER column bin/fm-procevent.sh already publishes: live, none,
# orphaned, or uncertain. Empty means the source is not registered at all.
source_owner() {  # <source-id>
  "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3 }'
}

# A replacement listener is started detached, so it claims the source shortly
# after reconcile returns. Wait for that claim rather than reporting the race.
await_source_owner() {  # <source-id>
  local owner i=0
  while [ "$i" -lt 50 ]; do
    owner=$(source_owner "$1")
    [ "$owner" != live ] || { printf '%s\n' "$owner"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "${owner:-none}"
}

# Retire a stale pre-reopen source generation, print the captain-facing link
# when the caller has one, confirm the session is listed open immediately
# before arming, bind and arm the source FIRSTMATE-OWNED
# (bin/fm-captain-hold.sh bind, then `fm-procevent-lavish.sh arm` - never
# `register-task`, so an answer always reaches firstmate as its own check wake
# rather than a worker's steer inbox), and wait for a live listener before
# returning. <link_url>, when non-empty, is printed as `link: <url>` right
# after the reopen retire: a one-off question page prints its captain-facing
# URL there, while the board omits it because captains reach the stable board
# path directly.
finish_arming_source() {  # <kind> <file> <sid> <pre_reopen_owner> <link_url>
  local kind=$1 file=$2 sid=$3 pre_reopen_owner=$4 link_url=$5 owner version
  if [ "$LAVISH_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$file" >/dev/null \
      || fail "cannot retire the pre-reopen source generation (observed owner: ${pre_reopen_owner:-none})"
  fi
  if [ -n "$link_url" ]; then
    printf 'link: %s\n' "$link_url"
  fi
  if ! lavish_session_listed_open "$(artifact_realpath "$file")"; then
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the $kind Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$file"

  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the $kind source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  owner=$(source_owner "$sid")
  if [ "$LAVISH_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$file" >/dev/null \
      || fail "cannot arm a fresh $kind source after reopening"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  elif [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$file" >/dev/null \
      || fail "cannot arm the $kind as a process-event source"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  fi
  # Registered is not listening. An artifact whose source has no live owner
  # gets a replacement started now rather than at the next supervision cycle,
  # which is what keeps a rebuilt board or page from sitting silent behind
  # `already-armed`.
  if [ "$owner" != live ]; then
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(await_source_owner "$sid")
    if [ "$owner" != live ]; then
      fail "source $sid is not listening after reconcile (observed owner: ${owner:-none})"
    fi
    printf 'listening: live\n'
  fi
}

# --- Question-page image resolution -------------------------------------
# A question's or option's `image` field is an absolute local filesystem
# path, never a URL or a path relative to this script. Resolve every such
# path into a `data:` URI BEFORE the payload is injected, so the published
# page is fully self-contained and needs no file reachable alongside it
# wherever Lavish serves it from. Fails closed on a missing path, a symlink,
# an oversized file, or a file whose detected type is not a supported image
# format - never silently drops or skips an image.
IMAGE_MAX_BYTES=$((5 * 1024 * 1024))

image_data_uri() {  # <path>
  local path=$1 size mime b64
  case "$path" in
    /*) ;;
    *) printf 'image path must be absolute: %s\n' "$path" >&2; return 1 ;;
  esac
  [ -e "$path" ] || { printf 'image file does not exist: %s\n' "$path" >&2; return 1; }
  [ ! -L "$path" ] || { printf 'image file must not be a symlink: %s\n' "$path" >&2; return 1; }
  [ -f "$path" ] || { printf 'image path is not a regular file: %s\n' "$path" >&2; return 1; }
  command -v file >/dev/null 2>&1 \
    || { printf 'the file command is required to validate image types\n' >&2; return 1; }
  size=$(wc -c < "$path" | tr -d '[:space:]') || return 1
  [ "$size" -le "$IMAGE_MAX_BYTES" ] \
    || { printf 'image file exceeds the %d-byte cap: %s (%d bytes)\n' "$IMAGE_MAX_BYTES" "$path" "$size" >&2; return 1; }
  mime=$(file --brief --mime-type "$path" 2>/dev/null) \
    || { printf 'cannot determine the image type: %s\n' "$path" >&2; return 1; }
  case "$mime" in
    image/png|image/jpeg|image/gif|image/webp) ;;
    *) printf 'unsupported image type %s for %s (png, jpeg, gif, and webp only)\n' "$mime" "$path" >&2; return 1 ;;
  esac
  b64=$(base64 < "$path" | tr -d '\n') || return 1
  printf 'data:%s;base64,%s' "$mime" "$b64"
}

# Replace every question/option `image` path in <data.json> with its
# resolved `data:` URI, writing the result to <dest.json>. The input's
# schema is already validated by this point, so every `image` present is a
# non-empty string; resolution only has to prove it is a safe, in-cap image
# file.
resolve_page_images() {  # <data.json> <dest.json>
  local data=$1 dest=$2 json path uri qidx oidx
  json=$(jq -c . "$data") || return 1
  while IFS=$'\t' read -r qidx path; do
    [ -n "$path" ] || continue
    uri=$(image_data_uri "$path") || return 1
    json=$(jq -c --argjson qi "$qidx" --arg uri "$uri" '.questions[$qi].image = $uri' <<< "$json") || return 1
  done < <(jq -r '.questions | to_entries[] | select(.value.image != null) | "\(.key)\t\(.value.image)"' "$data")
  while IFS=$'\t' read -r qidx oidx path; do
    [ -n "$path" ] || continue
    uri=$(image_data_uri "$path") || return 1
    json=$(jq -c --argjson qi "$qidx" --argjson oi "$oidx" --arg uri "$uri" \
      '.questions[$qi].options[$oi].image = $uri' <<< "$json") || return 1
  done < <(jq -r '
    .questions | to_entries[] | .key as $qi
    | .value.options | to_entries[] | select(.value.image != null)
    | "\($qi)\t\(.key)\t\(.value.image)"
  ' "$data")
  printf '%s\n' "$json" > "$dest"
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
  # Order already proved equal above, so a positional zip ties each payload
  # question to its render report: every declared question/option image must
  # actually render, and no extra image must appear where none was declared.
  bad=$(jq -rn --slurpfile data "$data" --argjson report "$report" '
    ($data[0].questions) as $qs
    | [range(0; $qs | length)
      | $qs[.] as $q
      | $report.questions[.] as $r
      | select(
          (($q.image != null) != ($r.questionImage == true))
          or (([$q.options[] | select(.image != null)] | length) != $r.optionImageCount))
      | $q.key] | join(",")
  ') || fail "cannot compare declared and rendered images"
  [ -z "$bad" ] \
    || fail "the built page did not render the declared image(s) for: $bad"
}

command_build() {
  local data=${1-} board json effective stage1 tmp sid extracted owner version pre_reopen_owner
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || fail "cannot stage the board payload"
  if ! effective_payload "$data" "$effective"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work"
  fi
  json=$(jq -c . "$effective") || { rm -f -- "$effective"; fail "cannot compact the board data"; }
  rm -f -- "$effective"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  stage1=$(umask 077; mktemp "${board%/*}/.board-stage.XXXXXX") || fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$stage1"; then
    rm -f -- "$stage1"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$stage1"; then
    rm -f -- "$stage1"
    fail "the board data slot survived injection"
  fi
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || { rm -f -- "$stage1"; fail "cannot stage the board"; }
  if ! inject_shared_assets "$stage1" "$tmp"; then
    rm -f -- "$stage1" "$tmp"
    fail "cannot inject the shared decision-card CSS/JS into the board template"
  fi
  rm -f -- "$stage1"
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the board"
  fi
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  pre_reopen_owner=$(source_owner "$sid")
  establish_lavish_session board "$board"
  finish_arming_source board "$board" "$sid" "$pre_reopen_owner" ""
}

command_page() {
  local data=${1-} label='' page json tmp tmp2='' resolved='' sid extracted pre_reopen_owner link_url
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label)
        [ "$#" -ge 2 ] || { usage >&2; exit 2; }
        label=$2
        shift 2
        ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [ -n "$label" ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "page data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "page data is not valid JSON: $data"
  validate_page_payload "$data" || fail "page data does not satisfy $PAGE_SCHEMA: $data"
  [ -f "$PAGE_TEMPLATE" ] && [ ! -L "$PAGE_TEMPLATE" ] || fail "page template is missing: $PAGE_TEMPLATE"
  [ "$(grep -cxF "$PAGE_PLACEHOLDER" "$PAGE_TEMPLATE")" -eq 1 ] \
    || fail "page template does not carry exactly one data slot: $PAGE_TEMPLATE"

  resolved=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-decision-page-resolved.XXXXXX") \
    || fail "cannot stage the resolved page data"
  # A staged page or resolved-data file that never reaches `mv` - any refusal
  # below - is cleaned up by this trap rather than by a rm at every call
  # site. The trap outlives this function's own locals, so it reads
  # `${var:-}` rather than tripping `set -u` once the function has returned
  # and they are gone.
  trap 'rm -f -- "${tmp:-}" "${tmp2:-}" "${resolved:-}"' EXIT
  if ! resolve_page_images "$data" "$resolved"; then
    fail "cannot resolve an image referenced by the page data: $data"
  fi
  data=$resolved

  json=$(jq -c . "$data") || fail "cannot compact the page data"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  page=$(page_path "$label")
  (umask 077; mkdir -p "${page%/*}") || fail "cannot create ${page%/*}"
  tmp=$(umask 077; mktemp "${page%/*}/.page.XXXXXX") || fail "cannot stage the page"
  if ! FM_DECISION_PAGE_JSON="$json" perl -pe "s/^\\Q$PAGE_PLACEHOLDER\\E\$/\$ENV{FM_DECISION_PAGE_JSON}/" "$PAGE_TEMPLATE" > "$tmp"; then
    fail "cannot inject the page data"
  fi
  if grep -qxF "$PAGE_PLACEHOLDER" "$tmp"; then
    fail "the page data slot survived injection"
  fi
  tmp2=$(umask 077; mktemp "${page%/*}/.page-assets.XXXXXX") || fail "cannot stage the page"
  if ! inject_shared_assets "$tmp" "$tmp2"; then
    fail "cannot inject the shared decision-card CSS/JS into the page template"
  fi
  mv -f -- "$tmp2" "$tmp" || fail "cannot stage the page"
  tmp2=''
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
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$page") \
    || fail "cannot derive the page source id"
  pre_reopen_owner=$(source_owner "$sid")
  establish_lavish_session page "$page"
  link_url=$(lavish_url_field "$LAVISH_ESTABLISH_OUT")
  finish_arming_source page "$page" "$sid" "$pre_reopen_owner" "$link_url"
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) board_path ;;
  page) shift; command_page "$@" ;;
  page-path)
    shift
    label=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --label) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; label=$2; shift 2 ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    [ -n "$label" ] || { usage >&2; exit 2; }
    page_path "$label"
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
