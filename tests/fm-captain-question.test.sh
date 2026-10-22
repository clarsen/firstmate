#!/usr/bin/env bash
# Exercise captain-question record mutations through the public CLI.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUESTION="$ROOT/bin/fm-captain-question.py"
TMP_ROOT=$(fm_test_tmproot fm-captain-question)
home="$TMP_ROOT/home"
mkdir -p "$home/data"
printf 'What is the rollout status?\n' > "$home/question.txt"
printf 'Deployment evidence has not been checked.\n' > "$home/status.txt"
id=$(FM_HOME="$home" "$QUESTION" open --question-file "$home/question.txt" --status-file "$home/status.txt") \
  || fail "the captain question was not opened"
repeat_id=$(FM_HOME="$home" "$QUESTION" open --question-file "$home/question.txt")
[ "$repeat_id" = "$id" ] || fail "a repeated open question created a duplicate"
FM_HOME="$home" "$QUESTION" list | jq -e --arg id "$id" '
  length == 1 and .[0].id == $id and .[0].state == "open"
  and .[0].question == "What is the rollout status?\n"
  and .[0].closed_by_captain == null
' >/dev/null || fail "the exact captain question was not preserved"

printf 'The rollout reached two of three hosts.\n' > "$home/status.txt"
FM_HOME="$home" "$QUESTION" status "$id" --status-file "$home/status.txt" \
  --link 'Report=https://example.com/report' || fail "status did not update"
FM_HOME="$home" "$QUESTION" list | jq -e '
  .[0].status == "The rollout reached two of three hosts.\n"
  and .[0].links == [{"label":"Report","url":"https://example.com/report"}]
' >/dev/null || fail "the current status or evidence link was lost"
FM_HOME="$home" "$QUESTION" status "$id" --status-file "$home/status.txt" \
  || fail "status refresh without new links failed"
FM_HOME="$home" "$QUESTION" list | jq -e \
  '.[0].links == [{"label":"Report","url":"https://example.com/report"}]' >/dev/null \
  || fail "a status refresh discarded existing evidence links"
jq '.questions[0].last_updated = "2020-01-01T00:00:00Z"' \
  "$home/data/captain-questions.json" > "$home/aged.json"
mv "$home/aged.json" "$home/data/captain-questions.json"
FM_HOME="$home" "$QUESTION" list | jq -e '.[0].stale == true' >/dev/null \
  || fail "an old question status was not flagged stale"

if FM_HOME="$home" "$QUESTION" close "$id" >/dev/null 2>&1; then
  fail "a question closed without captain provenance"
fi
printf 'This is an unrelated captured answer.\n' > "$home/unrelated.result"
if FM_HOME="$home" "$QUESTION" close "$id" --board-result "$home/unrelated.result" >/dev/null 2>&1; then
  fail "an unrelated board result closed a question"
fi
FM_HOME="$home" "$QUESTION" list | jq -e 'length == 1 and .[0].state == "open"' >/dev/null \
  || fail "a refused close altered the record"

printf 'Close this question; the rollout is complete.\n' > "$home/captain-words.txt"
FM_HOME="$home" "$QUESTION" close "$id" --captain-words-file "$home/captain-words.txt" \
  || fail "the captain's explicit close was refused"
FM_HOME="$home" "$QUESTION" list | jq -e 'length == 0' >/dev/null \
  || fail "the closed question stayed in the open projection"
FM_HOME="$home" "$QUESTION" list --all | jq -e '
  length == 1 and .[0].state == "closed"
  and .[0].closed_by_captain.source == "captain-chat"
  and .[0].closed_by_captain.words == "Close this question; the rollout is complete.\n"
' >/dev/null || fail "close history lacks captain provenance"
if FM_HOME="$home" "$QUESTION" status "$id" --status-file "$home/status.txt" >/dev/null 2>&1; then
  fail "a closed question accepted a status update"
fi

board_id=$(FM_HOME="$home" "$QUESTION" open --question-file "$home/question.txt")
cat > "$home/close.result" <<EOF
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Captain question close: close\\n\\nContext data:\\n{\\n  \\"schema\\": \\"fm-bearings-answer.v1\\",\\n  \\"question\\": \\"captain-question.$board_id\\",\\n  \\"selection\\": \\"close\\",\\n  \\"note\\": \\"\\"\\n}","form",choice,"Close"
EOF
FM_HOME="$home" "$QUESTION" close "$board_id" --board-result "$home/close.result" \
  || fail "the captured board Close answer was refused"
FM_HOME="$home" "$QUESTION" list --all | jq -e --arg id "$board_id" '
  any(.[]; .id == $id and .state == "closed"
    and .closed_by_captain.source == "board" and .closed_by_captain.words == "close")
' >/dev/null || fail "the board close lacks provenance"
pass "captain questions keep exact words, status, links, and guarded close history"

fake_root="$TMP_ROOT/root"
work="$TMP_ROOT/work"
mkdir -p "$fake_root/bin" "$work"
cp "$QUESTION" "$fake_root/bin/fm-captain-question.py"
(cd "$work" && FM_HOME='' "$fake_root/bin/fm-captain-question.py" open --question-file "$home/question.txt" >/dev/null) \
  || fail "an empty FM_HOME refused to open a question"
[ ! -e "$work/data/captain-questions.json" ] || fail "an empty FM_HOME wrote the record under the current directory"
(cd "$work" && FM_HOME='' "$fake_root/bin/fm-captain-question.py" list) | jq -e 'length == 1' >/dev/null \
  || fail "an empty FM_HOME did not resolve to the repository root record"
jq -e '.questions | length == 1' "$fake_root/data/captain-questions.json" >/dev/null 2>&1 \
  || fail "an empty FM_HOME did not store the record under the repository root"
pass "an empty FM_HOME resolves to the repository root like the shell owners"
