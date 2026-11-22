#!/usr/bin/env bash
# Exercise the public rework record with a clone and fixture forge responses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-daily-rework)
CASE_HOME="$TMP_ROOT/home"
BIN="$TMP_ROOT/bin"
mkdir -p "$CASE_HOME/data" "$CASE_HOME/state" "$CASE_HOME/projects/lblnet_hostupdate" "$BIN"
DAY=2026-11-19
CLONE="$CASE_HOME/projects/lblnet_hostupdate"
git -C "$CLONE" init -q || fail "fixture clone init failed"
git -C "$CLONE" config user.name Fixture
git -C "$CLONE" config user.email fixture@example.org
git -C "$CLONE" remote add origin https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate.git
printf 'fixture\n' > "$CLONE/fixture.txt"
git -C "$CLONE" add fixture.txt
GIT_AUTHOR_DATE=2026-11-19T12:00:00-08:00 GIT_COMMITTER_DATE=2026-11-19T12:00:00-08:00 \
  git -C "$CLONE" commit -qm 'Revert "fixture change"' || fail "fixture revert commit failed"
SHA=$(git -C "$CLONE" rev-parse HEAD)

cat > "$CASE_HOME/data/backlog.md" <<'EOF'
## Done
- [x] task-mr - GitLab task https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42 (repo: lblnet_hostupdate) (kind: ship) (done 2026-11-19)
- [x] task-gh - GitHub task https://github.com/clarsen/firstmate/pull/7 (repo: firstmate) (kind: ship) (done 2026-11-19)
EOF
printf '## Done\n' > "$CASE_HOME/data/done-archive.md"
cat > "$CASE_HOME/data/captain-questions.json" <<'EOF'
{"schema":"fm-captain-questions.v1","questions":[]}
EOF

cat > "$BIN/glab" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  */pipelines\?per_page=100)
    printf '%s\n' '[{"id":9,"status":"failed","updated_at":"2026-11-19T21:00:00Z","web_url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/pipelines/9"},{"id":8,"status":"success","updated_at":"2026-11-19T20:00:00Z","web_url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/pipelines/8"}]'
    ;;
  */merge_requests/42)
    printf '%s\n' '{"state":"closed","closed_at":"2026-11-19T22:00:00Z","merged_at":null}'
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  */pulls/7)
    printf '%s\n' '{"state":"closed","closed_at":"2026-11-19T23:00:00Z","merged_at":null}'
    ;;
  */pulls/7/commits\?per_page=100)
    printf '%s\n' '[{"sha":"abc123"}]'
    ;;
  */actions/runs\?head_sha=abc123\&per_page=100)
    printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":10,"conclusion":"failure","event":"pull_request","updated_at":"2026-11-19T23:30:00Z","html_url":"https://github.com/clarsen/firstmate/actions/runs/10"}]}'
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN/glab" "$BIN/gh"

PATH="$BIN:$PATH" python3 "$ROOT/bin/fm-wake-daily.py" "$DAY" --home "$CASE_HOME" >/dev/null || fail "fixture collection failed"
record="$CASE_HOME/data/wake/daily/$DAY.json"
jq -e --arg sha "$SHA" '
  .rework.reverts == [{"project":"lblnet_hostupdate","commit":$sha,"subject":"Revert \"fixture change\"","at":"2026-11-19T20:00:00Z","evidence":("https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/commit/" + $sha)}]
  and ([.rework.closed_unmerged[].url] == ["https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42","https://github.com/clarsen/firstmate/pull/7"])
  and ([.rework.closed_unmerged[].at] == ["2026-11-19T22:00:00Z","2026-11-19T23:00:00Z"])
  and ([.rework.failed_pipelines[].url] == ["https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/pipelines/9","https://github.com/clarsen/firstmate/actions/runs/10"])
  and ([.rework.failed_pipelines[].at] == ["2026-11-19T21:00:00Z","2026-11-19T23:30:00Z"])
  and .coverage.signals.reverts == {"status":"measured","count":1}
  and .coverage.signals.closed_unmerged == {"status":"measured","count":2}
  and .coverage.signals.failed_pipelines == {"status":"measured","count":2}
  and (.rework | has("relaunch") | not)
' "$record" >/dev/null || fail "rework signals missing events, times, or URLs"

cp "$record" "$TMP_ROOT/first.json"
PATH="$BIN:$PATH" python3 "$ROOT/bin/fm-wake-daily.py" "$DAY" --home "$CASE_HOME" >/dev/null || fail "fixture repeat failed"
cmp -s "$record" "$TMP_ROOT/first.json" || fail "repeat changed record bytes"

cat > "$BIN/glab" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN/glab"
PATH="$BIN:$PATH" python3 "$ROOT/bin/fm-wake-daily.py" "$DAY" --home "$CASE_HOME" >/dev/null || fail "unreachable forge collection failed"
jq -e '
  .coverage.signals.closed_unmerged.status == "not_measurable"
  and .coverage.signals.closed_unmerged.count == null
  and .coverage.signals.failed_pipelines.status == "not_measurable"
  and .coverage.inputs["forge:https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42"].status == "not_measurable"
  and .coverage.signals.reverts == {"status":"measured","count":1}
' "$record" >/dev/null || fail "unreachable forge was counted as zero"

printf 'ok: Wake daily rework collector\n'
