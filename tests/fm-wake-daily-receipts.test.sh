#!/usr/bin/env bash
set -eu
export TMPDIR="$HOME/tmp/fm-scratch/wake-story16-receipts"
mkdir -p "$TMPDIR"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
task_tmp=$(fm_test_tmproot fm-wake-daily-receipts)
# API response shapes were recorded from hostupdate pipeline 868100 and job 2661548.
# IDs, URLs, commit, host, and event outcome below are stand-in values for public CI evidence.
home="$task_tmp/home"
mkdir -p "$home/data" "$home/state" "$home/projects" "$task_tmp/bin"
printf '## Done\n- [x] receipt-task - Fixture deployment https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42 (repo: lblnet_hostupdate) (kind: ship) (merged 2026-11-21)\n' > "$home/data/backlog.md"
printf '## Done\n' > "$home/data/done-archive.md"
printf '{"v":1,"ts":1795280400,"event":"task.merged","task":"receipt-task","pr":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42"}\n' > "$home/state/fleet-ledger.jsonl"
git -C "$home" init -q -b main
git -C "$home" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base
git -C "$home" checkout -q -b next
git -C "$home" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m 'Fixture change'
updated_commit=$(git -C "$home" rev-parse HEAD)
git -C "$home" checkout -q main
GIT_COMMITTER_DATE=2026-11-21T12:00:00Z git -C "$home" merge -q --ff-only next
cat > "$task_tmp/bin/glab" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *'pipelines?'*) printf '{"id":100,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","created_at":"2026-11-21T09:00:00Z"}\n' ;;
  *'pipelines/100/jobs?'*) printf '{"id":123456,"name":"ansible-deploy","finished_at":"2026-11-21T12:00:01Z","artifacts_file":{"filename":"artifacts.zip","size":500}}\n' ;;
  *'jobs/123456/artifacts/deploy-event.json'*) printf '{"schema_version":1,"coverage":"ci","events":[{"started_at":"2026-11-21T11:59:58Z","ended_at":"2026-11-21T12:00:01Z","host":"fixture.invalid","service_or_role":"ansible-deploy","outcome":"changed","commit_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","job_status":"success"}]}\n' ;;
  *'repository/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/merge_requests'*) printf '[{"iid":42,"web_url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42"}]\n' ;;
  *) printf '[]\n' ;;
esac
MOCK
cat > "$task_tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *'/pulls'*) printf '[{"html_url":"https://github.com/example/firstmate/pull/7","merged_at":"2026-11-21T11:00:00Z"}]\n' ;;
  *) printf '[]\n' ;;
esac
MOCK
chmod +x "$task_tmp/bin/glab" "$task_tmp/bin/gh"
export PATH="$task_tmp/bin:$PATH"
python3 "$ROOT/bin/fm-wake-daily.py" 2026-11-21 --home "$home" >/dev/null
record="$home/data/wake/daily/2026-11-21.json"
jq -e --arg commit "$updated_commit" '
  .hostupdate_deploy_receipts.events[0].deploy_job_id == 123456
  and .hostupdate_deploy_receipts.events[0].mrs == ["https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42"]
  and .hostupdate_deploy_receipts.events[0].tasks == ["receipt-task"]
  and .firstmate_updates.updates[0].after == $commit
  and .firstmate_updates.updates[0].merged_prs == ["https://github.com/example/firstmate/pull/7"]
  and .coverage.signals.hostupdate_deploy_receipts.status == "measured"
  and .coverage.signals.firstmate_updates.status == "measured"
' "$record" >/dev/null || fail 'receipt or update history missing'
cp "$record" "$task_tmp/first.json"
python3 "$ROOT/bin/fm-wake-daily.py" 2026-11-21 --home "$home" >/dev/null
cmp -s "$record" "$task_tmp/first.json" || fail 'rerun changed bytes'
cat > "$task_tmp/bin/glab" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *'pipelines?'*) printf '{"id":100,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","created_at":"2026-11-21T09:00:00Z"}\n' ;;
  *'pipelines/100/jobs?'*) printf '{"id":123456,"name":"ansible-deploy","finished_at":"2026-11-21T12:00:01Z","artifacts_file":null}\n' ;;
  *) printf '[]\n' ;;
esac
MOCK
chmod +x "$task_tmp/bin/glab"
python3 "$ROOT/bin/fm-wake-daily.py" 2026-11-21 --home "$home" >/dev/null
jq -e '.coverage.signals.hostupdate_deploy_receipts.status == "not_measurable" and .coverage.signals.hostupdate_deploy_receipts.count == null' "$record" >/dev/null || fail 'missing retained artifact reported as zero'
cat > "$task_tmp/bin/glab" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$task_tmp/bin/glab"
python3 "$ROOT/bin/fm-wake-daily.py" 2026-11-21 --home "$home" >/dev/null
jq -e '.coverage.signals.hostupdate_deploy_receipts.status == "not_measurable" and .coverage.signals.hostupdate_deploy_receipts.count == null' "$record" >/dev/null || fail 'unreachable source reported as zero'
pass 'retained receipt and local update evidence, outage coverage, byte-identical rerun'
