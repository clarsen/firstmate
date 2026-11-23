#!/usr/bin/env bash
set -eu
export TMPDIR="$HOME/tmp/fm-scratch/wake-story16-receipts"
mkdir -p "$TMPDIR"
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
task_tmp=$(fm_test_tmproot fm-wake-daily-receipts)
# API response shapes were recorded from hostupdate pipeline 868100 and job 2661548.
# IDs, URLs, commit, host, and event outcome below are stand-in values for public CI evidence.
home="$task_tmp/home"
mkdir -p "$home/data" "$home/state" "$home/projects" "$task_tmp/bin"
# Field names and the successful-receipt rule follow reference_deploy_receipts.adoc (Receipt fields).
cat > "$home/data/backlog.md" <<'MD'
## Done
- [x] receipt-task - Fixture deployment https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42 (repo: lblnet_hostupdate) (kind: ship) (merged 2026-11-21)
- [x] receipt-failed - Failed deployment https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/43 (repo: lblnet_hostupdate) (kind: ship) (merged 2026-11-21)
- [x] receipt-earlier - Earlier undeployed change https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/41 (repo: lblnet_hostupdate) (kind: ship) (merged 2026-11-21)
- [x] receipt-pin - Earlier pin change https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/50 (repo: lblnet_hostupdate) (kind: ship) (merged 2026-11-21)
- [x] fm-task - Firstmate change https://github.com/clarsen/firstmate/pull/7 (repo: firstmate) (kind: ship) (merged 2026-11-21)
MD
printf '## Done\n' > "$home/data/done-archive.md"
cat > "$home/state/fleet-ledger.jsonl" <<'JSONL'
{"v":1,"ts":1795280400,"event":"task.merged","task":"receipt-task","pr":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42"}
{"v":1,"ts":1795280400,"event":"task.merged","task":"receipt-failed","pr":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/43"}
{"v":1,"ts":1795280400,"event":"task.merged","task":"receipt-earlier","pr":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/41"}
{"v":1,"ts":1795280400,"event":"task.merged","task":"receipt-pin","pr":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/50"}
{"v":1,"ts":1795280400,"event":"task.merged","task":"fm-task","pr":"https://github.com/clarsen/firstmate/pull/7"}
JSONL
printf 'INFLUXDB_DEPLOY_METRICS_TOKEN=fixture-only\n' > "$home/.env"
printf '%s\n' ',result,table,_start,_stop,_time,_measurement,path,project,iid,deployed,mr_url,merged_at_ms,deployed_at_ms,deploy_job_id' \
  ',,0,2026-07-24T00:00:00Z,2026-11-23T00:00:00Z,2026-11-21T17:00:00Z,deploy_lead_time,hostupdate_vantage_pin,lblnet/lblnet_hostupdate,50,0,https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/50,1795280400000,,' > "$task_tmp/points.csv"
cat > "$task_tmp/collect.py" <<'PY'
import importlib.util
import io
from pathlib import Path
import sys
import urllib.request

source, home, fixture = sys.argv[1:]
spec = importlib.util.spec_from_file_location("wake_daily", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Response(io.BytesIO):
    def __enter__(self):
        return self
    def __exit__(self, *args):
        self.close()

urllib.request.urlopen = lambda request, timeout: Response(Path(fixture).read_bytes())
sys.argv = [source, "2026-11-21", "--home", home]
module.main()
PY
collect() {
  python3 "$task_tmp/collect.py" "$ROOT/bin/fm-wake-daily.py" "$home" "$task_tmp/points.csv" >/dev/null
}
git -C "$home" init -q -b main
git -C "$home" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base
git -C "$home" checkout -q -b next
git -C "$home" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m 'Fixture change'
updated_commit=$(git -C "$home" rev-parse HEAD)
git -C "$home" checkout -q main
GIT_COMMITTER_DATE=2026-11-21T12:00:00Z git -C "$home" merge -q --ff-only next
export RECEIPT_ARTIFACT="$task_tmp/deploy-event.json"
cat > "$RECEIPT_ARTIFACT" <<'JSON'
{"schema_version":1,"coverage":"ci","events":[{"started_at":"2026-11-21T11:59:58Z","ended_at":"2026-11-21T12:00:01Z","host":"fixture.invalid","service_or_role":"ansible-deploy","outcome":"changed","ansible_exit_code":0,"runner_exit_code":0,"commit_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","deployed_ref":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","job_status":"success"},{"started_at":"2026-11-21T12:04:00Z","ended_at":"2026-11-21T12:05:00Z","host":"other.invalid","service_or_role":"ansible-deploy","outcome":"failed","ansible_exit_code":2,"runner_exit_code":2,"commit_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","deployed_ref":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","requested_version":"v9","job_status":"failed"}]}
JSON
cat > "$task_tmp/bin/glab" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *'pipelines?'*) printf '{"id":100,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","created_at":"2026-11-21T09:00:00Z"}\n' ;;
  # Job 2661538 shape: the checks-stage job has no artifacts and never publishes a receipt.
  *'pipelines/100/jobs?'*) printf '{"id":123455,"name":"ansible-check-denyboot-shim","stage":"checks","finished_at":"2026-11-21T11:00:00Z","artifacts_file":null}\n{"id":123456,"name":"ansible-deploy","stage":"deploy","finished_at":"2026-11-21T12:00:01Z","artifacts_file":{"filename":"artifacts.zip","size":500}}\n' ;;
  *'jobs/123456/artifacts/deploy-event.json'*) cat "$RECEIPT_ARTIFACT" ;;
  *'repository/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/merge_requests'*) printf '[{"iid":42,"web_url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42"}]\n' ;;
  *'repository/commits/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/merge_requests'*) printf '[{"iid":43,"web_url":"https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/43"}]\n' ;;
  *'hostupdate/merge_requests/41 '*) printf '{"iid":41,"merge_commit_sha":"dddddddddddddddddddddddddddddddddddddddd"}\n' ;;
  *'hostupdate/merge_requests/43 '*) printf '{"iid":43,"merge_commit_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n' ;;
  *'hostupdate/merge_requests/50 '*) printf '{"iid":50,"merge_commit_sha":"ffffffffffffffffffffffffffffffffffffffff"}\n' ;;
  *'merge_base'*'ffffffffffffffffffffffffffffffffffffffff'*'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'*) printf '{"id":"ffffffffffffffffffffffffffffffffffffffff"}\n' ;;
  *'merge_base'*'dddddddddddddddddddddddddddddddddddddddd'*'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'*) printf '{"id":"dddddddddddddddddddddddddddddddddddddddd"}\n' ;;
  *'merge_base'*'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'*'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'*) printf '{"id":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}\n' ;;
  *) printf '[]\n' ;;
esac
MOCK
cat > "$task_tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *'/pulls'*) printf '[{"html_url":"https://github.com/clarsen/firstmate/pull/7","merged_at":"2026-11-21T11:00:00Z"}]\n' ;;
  *) printf '[]\n' ;;
esac
MOCK
chmod +x "$task_tmp/bin/glab" "$task_tmp/bin/gh"
export PATH="$task_tmp/bin:$PATH"
collect
record="$home/data/wake/daily/2026-11-21.json"
jq -e --arg commit "$updated_commit" '
  (.hostupdate_deploy_receipts.events | length) == 2
  and .hostupdate_deploy_receipts.events[0] == {
    "deploy_job_id": 123456, "job_url": "https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/jobs/123456",
    "started_at": "2026-11-21T11:59:58Z", "ended_at": "2026-11-21T12:00:01Z",
    "host": "fixture.invalid", "service_or_role": "ansible-deploy",
    "commit_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "deployed_ref": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "requested_pins": null, "requested_version": null, "outcome": "changed",
    "ansible_exit_code": 0, "runner_exit_code": 0, "job_status": "success", "reaches_production": true,
    "mrs": ["https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/42"], "tasks": ["receipt-task"],
    "earlier_mrs": ["https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/41", "https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/50"]}
  and .hostupdate_deploy_receipts.events[1].reaches_production == false
  and .hostupdate_deploy_receipts.events[1].job_status == "failed"
  and .hostupdate_deploy_receipts.events[1].ansible_exit_code == 2
  and .hostupdate_deploy_receipts.events[1].requested_version == "v9"
  and .hostupdate_deploy_receipts.events[1].tasks == ["receipt-failed"]
  and .hostupdate_deploy_receipts.events[1].earlier_mrs == []
  and .firstmate_updates.updates[0].after == $commit
  and .firstmate_updates.updates[0].merged_prs == ["https://github.com/clarsen/firstmate/pull/7"]
  and .firstmate_updates.updates[0].tasks == ["fm-task"]
  and .coverage.signals.production_evidence.status == "measured"
  and .coverage.signals.hostupdate_deploy_receipts.status == "measured"
  and .coverage.signals.firstmate_updates.status == "measured"
' "$record" >/dev/null || fail 'receipt or update history missing'
jq -e '
  [.production_evidence.not_shown[] | {mr, task, reason}] == [
    {"mr": "https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/41", "task": "receipt-earlier",
     "reason": "merged before successful receipt 123456 on a later commit; role deployment not proven"},
    {"mr": "https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/43", "task": "receipt-failed",
     "reason": "no matching production measurement"},
    {"mr": "https://lsg-git.lbl.gov/lblnet/lblnet_hostupdate/-/merge_requests/50", "task": "receipt-pin",
     "reason": "merged before successful receipt 123456 on a later commit; role deployment not proven"}]
' "$record" >/dev/null || fail 'not_shown ignored a successful receipt or home update, or counted a failed receipt'
cp "$record" "$task_tmp/first.json"
collect
cmp -s "$record" "$task_tmp/first.json" || fail 'rerun changed bytes'
for artifact in \
  '[{"ended_at":"2026-11-21T12:00:01Z","commit_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' \
  '{"schema_version":2,"events":[]}' \
  '{"schema_version":1,"events":[{"ended_at":"2026-11-21T12:00:01Z","outcome":"changed","job_status":"success"}]}'; do
  printf '%s\n' "$artifact" > "$RECEIPT_ARTIFACT"
  collect
  jq -e '.coverage.signals.hostupdate_deploy_receipts.status == "not_measurable" and .hostupdate_deploy_receipts.events == []' \
    "$record" >/dev/null || fail "invalid receipt accepted: $artifact"
done
cat > "$task_tmp/bin/glab" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *'pipelines?'*) printf '{"id":100,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","created_at":"2026-11-21T09:00:00Z"}\n' ;;
  *'pipelines/100/jobs?'*) printf '{"id":123456,"name":"ansible-deploy","stage":"deploy","finished_at":"2026-11-21T12:00:01Z","artifacts_file":null}\n' ;;
  *) printf '[]\n' ;;
esac
MOCK
chmod +x "$task_tmp/bin/glab"
collect
jq -e '.coverage.signals.hostupdate_deploy_receipts.status == "not_measurable" and .coverage.signals.hostupdate_deploy_receipts.count == null' "$record" >/dev/null || fail 'missing retained artifact reported as zero'
cat > "$task_tmp/bin/glab" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$task_tmp/bin/glab"
collect
jq -e '.coverage.signals.hostupdate_deploy_receipts.status == "not_measurable" and .coverage.signals.hostupdate_deploy_receipts.count == null' "$record" >/dev/null || fail 'unreachable source reported as zero'
jq -e '
  .coverage.signals.production_evidence.inputs == ["gitlab:lsg-git.lbl.gov/lblnet/lblnet_hostupdate/deploy-event.json"]
  and ([.production_evidence.not_shown[] | select(.mr | contains("lblnet_hostupdate")) | .reason] | unique)
    == ["evidence source gitlab:lsg-git.lbl.gov/lblnet/lblnet_hostupdate/deploy-event.json unavailable"]
  and ([.production_evidence.not_shown[].mr] | index("https://github.com/clarsen/firstmate/pull/7")) == null
' "$record" >/dev/null || fail 'unreadable receipts reported as missing production evidence'
cat > "$task_tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
collect
jq -e '
  .coverage.signals.firstmate_updates.status == "not_measurable"
  and .coverage.signals.production_evidence.inputs == ["git:home/firstmate/reflog", "gitlab:lsg-git.lbl.gov/lblnet/lblnet_hostupdate/deploy-event.json"]
  and ([.production_evidence.not_shown[] | select(.mr == "https://github.com/clarsen/firstmate/pull/7") | .reason]
    == ["evidence source git:home/firstmate/reflog unavailable"])
' "$record" >/dev/null || fail 'unreadable home updates reported as missing production evidence'
pass 'receipt and home update evidence reconcile not_shown; failed, earlier, and invalid receipts are not evidence'
