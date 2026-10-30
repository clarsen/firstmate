#!/usr/bin/env bash
# Exercise the tracked Stop capture hook through a lock-owning fake Claude.
# shellcheck disable=SC2016 # Quoted scripts and sed programs expand in their own interpreters.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

tmp_root=$(fm_test_tmproot fm-portal-capture)
trap fm_test_cleanup EXIT
primary="$tmp_root/primary"
home="$tmp_root/home"
fakebin=$(fm_fakebin "$tmp_root/fakebin")
mkdir -p "$primary" "$home/state" "$home/config"
git init -q "$primary"
: > "$primary/AGENTS.md"
ln -s "$ROOT/bin" "$primary/bin"
ln -s /bin/bash "$fakebin/claude"
: > "$home/config/portal-capture"

payload() { jq -cn --arg text "$1" --arg prompt "$2" \
  '{hook_event_name:"Stop",session_id:"session-a",prompt_id:$prompt,
    cwd:"/some/firstmate",last_assistant_message:$text}'; }
capture() { # <payload> [root] [home]
  local body=$1 root=${2:-$primary} target=${3:-$home}
  FM_HOME="$target" FM_ROOT_OVERRIDE="$root" PAYLOAD="$body" \
    "$fakebin/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$PAYLOAD" | "$FM_ROOT_OVERRIDE/bin/fm-portal-capture.sh" hook'
}
count_sidecars() { find "$home/state/portal-sidecars" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' '; }
last_sidecar() { find "$home/state/portal-sidecars" -maxdepth 1 -name '*.json' -type f | LC_ALL=C sort | tail -1; }

out=$(capture "$(payload $'Report complete.\nPORTAL: page=abc123 task=task.1' p1)") || fail 'Stop hook failed'
assert_equals '' "$out" 'capture must print nothing'
assert_equals 1 "$(count_sidecars)" 'one non-empty Stop writes one sidecar'
jq -e '.schema == 1 and .session_id == "session-a" and .prompt_id == "p1" and
  .cwd == "/some/firstmate" and .hook_version == "1" and
  .trailer_status == "valid" and .trailer_kind == "page" and
  .page_ids == ["abc123"] and .task_ids == ["task.1"] and
  .enforcement == "off" and (.content_hash | startswith("sha256:")) and
  (.message_text | startswith("Report complete"))' "$(last_sidecar)" >/dev/null \
  || fail 'captured schema or trailer is wrong'
capture "$(payload $'Report complete.\nPORTAL: page=abc123 task=task.1' p1)" >/dev/null
assert_equals 1 "$(count_sidecars)" 'refired Stop must deduplicate'
capture "$(payload 'Captain, shipshape.' p2)" >/dev/null
capture "$(payload 'Captain, shipshape.' p3)" >/dev/null
assert_equals 3 "$(count_sidecars)" 'separate no-op turns must be distinct'
jq -e 'select(.message_text == "Captain, shipshape.") |
  .trailer_status == "valid" and .trailer_kind == "none" and
  .text_outside_trailer_chars == 0' "$home/state/portal-sidecars"/*.json \
  | jq -s -e 'length == 2 and all(.[]; . == true)' >/dev/null || fail 'implicit none is wrong'

for row in \
  'PORTAL: none|valid|none' \
  'PORTAL: page=one,two task=t-1,t_2|valid|page' \
  'plain text|missing|null' \
  'PORTAL: page=bad!|malformed|null' \
  $'PORTAL: none\nmore text|missing|null'; do
  text=${row%%|*}; rest=${row#*|}; status=${rest%%|*}; kind=${rest##*|}
  result=$(capture "$(payload "$text" "fixture-${status}-${kind}-${RANDOM}")") || fail 'fixture Stop failed'
  assert_equals '' "$result" 'fixture Stop printed output'
  jq -e --arg t "$text" --arg s "$status" --arg k "$kind" '
    select(.message_text == $t) | .trailer_status == $s and
    .trailer_kind == (if $k == "null" then null else $k end)' \
    "$home/state/portal-sidecars"/*.json | tail -1 | jq -e '. == true' >/dev/null \
    || fail "fixture ending parsed incorrectly: $text"
done
jq -e 'select(.message_text == "PORTAL: page=one,two task=t-1,t_2") |
  .page_ids == ["one","two"] and .task_ids == ["t-1","t_2"] and
  .text_outside_trailer_chars == 0' "$home/state/portal-sidecars"/*.json \
  | jq -s -e 'length == 1 and .[0] == true' >/dev/null || fail 'multiple page and task ids parsed incorrectly'

capture "$(payload $'Body with trailing newline\nPORTAL: none\n' trailing)" >/dev/null
jq -e 'select(.prompt_id == "trailing") |
  .message_text == "Body with trailing newline\nPORTAL: none\n" and
  .text_outside_trailer_chars > 0' "$home/state/portal-sidecars"/*.json \
  | jq -s -e 'length == 1 and .[0] == true' >/dev/null || fail 'full message text was not preserved'

before=$(count_sidecars)
capture "$(payload '' empty)" >/dev/null
assert_equals "$before" "$(count_sidecars)" 'empty message should be skipped'
capture '{broken' >/dev/null || fail 'bad JSON blocked Stop'
assert_equals "$before" "$(count_sidecars)" 'bad JSON wrote a sidecar'
capture '{"hook_event_name":"Stop","session_id":"missing-text"}' >/dev/null \
  || fail 'missing message field blocked Stop'
assert_equals "$before" "$(count_sidecars)" 'missing message field wrote a sidecar'
assert_contains "$(cat "$home/state/portal-capture.log")" 'fm-portal-capture.sh:' 'error log must name script and line'

rm -f "$home/config/portal-capture"
capture "$(payload 'off' off)" >/dev/null
assert_equals "$before" "$(count_sidecars)" 'flag absence must disable capture'
: > "$home/config/portal-capture"
: > "$home/.fm-secondmate-home"
capture "$(payload 'secondmate' secondmate)" >/dev/null
assert_equals "$before" "$(count_sidecars)" 'secondmate marker must disable capture'
rm "$home/.fm-secondmate-home"
foreign=$(payload 'foreign' foreign | jq -c '. + {cursor_version:"test"}')
capture "$foreign" >/dev/null
assert_equals "$before" "$(count_sidecars)" 'foreign host must be skipped'
rm -f "$home/state/.lock"
out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$primary" PAYLOAD="$(payload 'no lock' no-lock)" \
  "$fakebin/claude" -c 'printf "%s" "$PAYLOAD" | "$FM_ROOT_OVERRIDE/bin/fm-portal-capture.sh" hook') \
  || fail 'missing lock blocked Stop'
assert_equals '' "$out" 'missing lock printed output'
assert_equals "$before" "$(count_sidecars)" 'missing lock must disable capture'
printf '1\n' > "$home/state/.lock"
out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$primary" PAYLOAD="$(payload 'foreign lock' other-lock)" \
  "$fakebin/claude" -c 'printf "%s" "$PAYLOAD" | "$FM_ROOT_OVERRIDE/bin/fm-portal-capture.sh" hook') \
  || fail 'foreign lock blocked Stop'
assert_equals '' "$out" 'foreign lock printed output'
assert_equals "$before" "$(count_sidecars)" 'foreign lock must disable capture'

linked="$tmp_root/linked"
mkdir -p "$linked"
: > "$linked/AGENTS.md"
ln -s "$ROOT/bin" "$linked/bin"
printf 'gitdir: %s\n' "$primary/.git/worktrees/linked" > "$linked/.git"
capture "$(payload 'linked worktree' linked)" "$linked" >/dev/null
assert_equals "$before" "$(count_sidecars)" 'linked worktree must be out of scope'

documented=0
while IFS= read -r example; do
  [ -n "$example" ] || continue
  documented=$((documented + 1))
  capture "$(payload "$example" "doc-$RANDOM")" >/dev/null
  jq -e --arg t "$example" 'select(.message_text == $t) | .trailer_status == "valid"' \
    "$home/state/portal-sidecars"/*.json | jq -s -e 'length >= 1 and all(.[]; . == true)' >/dev/null \
    || fail "documented trailer did not parse: $example"
done < <(grep -oE 'PORTAL: (page=[A-Za-z0-9_-]+|none)' "$ROOT/AGENTS.md" | LC_ALL=C sort -u)
[ "$documented" -ge 2 ] || fail "expected documented page and none trailers, checked $documented"
before=$(count_sidecars)

old=$(last_sidecar)
touch -t 202001010000 "$old"
rm -f "$home/config/portal-capture"
FM_HOME="$home" FM_ROOT_OVERRIDE="$primary" FM_PORTAL_SIDECAR_KEEP_DAYS=30 \
  "$ROOT/bin/fm-portal-capture.sh" prune
[ ! -e "$old" ] || fail 'expired sidecar was not pruned'
assert_equals "$((before - 1))" "$(count_sidecars)" 'prune removed a fresh sidecar'
if find "$home/state/portal-sidecars" -name '.capture.*' | grep -q .; then
  fail 'temporary sidecar was left behind'
fi
: > "$home/config/portal-capture"
rm -rf "$home/state/portal-sidecars"
: > "$home/state/portal-sidecars"
capture "$(payload 'cannot write' unwritable)" >/dev/null || fail 'unwritable sidecar path blocked Stop'
assert_contains "$(cat "$home/state/portal-capture.log")" 'cannot create sidecar directory' \
  'unwritable sidecar path must be logged'
pass 'portal capture: schema, trailer, dedup, scope, failure, and retention'
