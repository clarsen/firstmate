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
LOCAL="$CASE_HOME/projects/localonly"
mkdir -p "$LOCAL"
git -C "$LOCAL" init -q || fail "local-only clone init failed"
git -C "$LOCAL" config user.name Fixture
git -C "$LOCAL" config user.email fixture@example.org
printf 'fixture\n' > "$LOCAL/fixture.txt"
git -C "$LOCAL" add fixture.txt
GIT_AUTHOR_DATE=2026-11-19T10:00:00-08:00 GIT_COMMITTER_DATE=2026-11-19T10:00:00-08:00 \
  git -C "$LOCAL" commit -qm 'Revert "local change"' || fail "local-only revert commit failed"
LOCAL_SHA=$(git -C "$LOCAL" rev-parse HEAD)

cat > "$CASE_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] task-open - Open GitHub task https://github.com/clarsen/firstmate/pull/9 (repo: firstmate) (kind: ship) (since 2026-11-15)

## Done
- [x] task-mr - GitLab task https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42#note_1 (repo: lblnet_hostupdate) (kind: ship) (done 2026-11-19)
- [x] task-gh - GitHub task https://github.com/clarsen/firstmate/pull/7, follow-up (repo: firstmate) (kind: ship) (done 2026-11-19)
- [x] task-merged - Merged GitHub task https://github.com/clarsen/firstmate/pull/8/files (repo: firstmate) (kind: ship) (merged 2026-11-19)
- [x] task-red - GitLab task fixed after a red pipeline https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/43 (repo: lblnet_hostupdate) (kind: ship) (merged 2026-11-19)
- [x] task-old - Historical GitHub task https://github.com/clarsen/firstmate/pull/3 (repo: firstmate) (kind: ship) (done 2026-10-20)
EOF
cat > "$CASE_HOME/data/done-archive.md" <<'EOF'
## Done
- [x] task-closed - GitLab task abandoned before archiving https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/44 (repo: lblnet_hostupdate) (kind: ship) (done 2026-11-19)
EOF
cat > "$CASE_HOME/data/captain-questions.json" <<'EOF'
{"schema":"fm-captain-questions.v1","questions":[]}
EOF

cat > "$BIN/glab" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  */merge_requests/42/pipelines\?per_page=100)
    printf '%s\n' '[{"id":9,"status":"failed","updated_at":"2026-11-19T21:00:00Z","web_url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/pipelines/9"},{"id":8,"status":"success","updated_at":"2026-11-19T20:00:00Z","web_url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/pipelines/8"}]'
    ;;
  */merge_requests/42)
    printf '%s\n' '{"state":"closed","closed_at":"2026-11-19T22:00:00Z","merged_at":null}'
    ;;
  */merge_requests/43/pipelines\?per_page=100)
    printf '%s\n' '[{"id":20,"status":"failed","finished_at":"2026-11-18T20:00:00Z","updated_at":"2026-11-18T20:00:00Z","web_url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/pipelines/20"}]'
    ;;
  */merge_requests/44/pipelines\?per_page=100)
    printf '%s\n' '[]'
    ;;
  */merge_requests/44)
    printf '%s\n' '{"state":"closed","closed_at":"2026-11-17T20:00:00Z","merged_at":null}'
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
  */pulls/8/commits\?per_page=100)
    printf '%s\n' '[{"sha":"aaa888"}]'
    ;;
  */actions/runs\?head_sha=aaa888\&per_page=100)
    printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":12,"conclusion":"success","event":"pull_request","updated_at":"2026-11-19T19:00:00Z","html_url":"https://github.com/clarsen/firstmate/actions/runs/12"}]}'
    ;;
  */pulls/9)
    printf '%s\n' '{"state":"open","closed_at":null,"merged_at":null}'
    ;;
  */pulls/9/commits\?per_page=100)
    printf '%s\n' '[{"sha":"def999"}]'
    ;;
  */actions/runs\?head_sha=def999\&per_page=100)
    printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":11,"conclusion":"failure","event":"pull_request","updated_at":"2026-11-19T18:30:00Z","html_url":"https://github.com/clarsen/firstmate/actions/runs/11"}]}'
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN/glab" "$BIN/gh"

PATH="$BIN:$PATH" python3 "$ROOT/bin/fm-wake-daily.py" "$DAY" --home "$CASE_HOME" >/dev/null || fail "fixture collection failed"
record="$CASE_HOME/data/wake/daily/$DAY.json"
jq -e --arg sha "$SHA" --arg local "$LOCAL_SHA" '
  .rework.reverts == [
    {"project":"localonly","commit":$local,"subject":"Revert \"local change\"","at":"2026-11-19T18:00:00Z","evidence":("projects/localonly@" + $local)},
    {"project":"lblnet_hostupdate","commit":$sha,"subject":"Revert \"fixture change\"","at":"2026-11-19T20:00:00Z","evidence":("https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/commit/" + $sha)}]
  and ([.rework.closed_unmerged[].url] == ["https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42","https://github.com/clarsen/firstmate/pull/7"])
  and ([.rework.closed_unmerged[].at] == ["2026-11-19T22:00:00Z","2026-11-19T23:00:00Z"])
  and ([.rework.failed_pipelines[].url] == ["https://github.com/clarsen/firstmate/actions/runs/11","https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/pipelines/9","https://github.com/clarsen/firstmate/actions/runs/10"])
  and ([.rework.failed_pipelines[].at] == ["2026-11-19T18:30:00Z","2026-11-19T21:00:00Z","2026-11-19T23:30:00Z"])
  and .coverage.signals.reverts == {"status":"measured","count":2}
  and .coverage.signals.closed_unmerged == {"status":"measured","count":2}
  and .coverage.signals.failed_pipelines == {"status":"measured","count":3}
  and .coverage.inputs["forge:https://github.com/clarsen/firstmate/pull/8"].status == "readable"
  and (.coverage.inputs | has("forge:https://github.com/clarsen/firstmate/pull/3") | not)
  and .coverage.forge_candidates.count == 6
  and .coverage.forge_candidates.assumed_start == 5
  and (.rework | has("relaunch") | not)
' "$record" >/dev/null || fail "rework signals missing events, times, or URLs"

RED_DAY=2026-11-18
PATH="$BIN:$PATH" python3 "$ROOT/bin/fm-wake-daily.py" "$RED_DAY" --home "$CASE_HOME" >/dev/null || fail "red pipeline day collection failed"
jq -e '
  .rework.failed_pipelines == [{"task":"task-red","url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/pipelines/20","pr_url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/43","at":"2026-11-18T20:00:00Z","time_source":"finished_at"}]
  and .coverage.signals.failed_pipelines == {"status":"measured","count":1}
' "$CASE_HOME/data/wake/daily/$RED_DAY.json" >/dev/null || fail "red pipeline before the merge day was dropped"

CLOSED_DAY=2026-11-17
PATH="$BIN:$PATH" python3 "$ROOT/bin/fm-wake-daily.py" "$CLOSED_DAY" --home "$CASE_HOME" >/dev/null || fail "closed MR day collection failed"
jq -e '
  .rework.closed_unmerged == [{"task":"task-closed","url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/44","at":"2026-11-17T20:00:00Z"}]
  and .coverage.signals.closed_unmerged == {"status":"measured","count":1}
' "$CASE_HOME/data/wake/daily/$CLOSED_DAY.json" >/dev/null || fail "MR closed before its archive day was dropped"

OLD_DAY=2026-10-20
PATH="$BIN:$PATH" python3 "$ROOT/bin/fm-wake-daily.py" "$OLD_DAY" --home "$CASE_HOME" >/dev/null || fail "historical day collection failed"
jq -e '
  .coverage.signals.closed_unmerged.status == "not_measurable"
  and .coverage.signals.closed_unmerged.inputs == ["forge:https://github.com/clarsen/firstmate/pull/3"]
  and .coverage.signals.failed_pipelines.status == "not_measurable"
  and ([.coverage.inputs | keys[] | select(startswith("forge:"))] == ["forge:https://github.com/clarsen/firstmate/pull/3"])
' "$CASE_HOME/data/wake/daily/$OLD_DAY.json" >/dev/null || fail "historical unreadable PR not confined to its own days"

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
  and .coverage.signals.reverts == {"status":"measured","count":2}
' "$record" >/dev/null || fail "unreachable forge was counted as zero"

printf 'ok: Wake daily rework collector\n'
