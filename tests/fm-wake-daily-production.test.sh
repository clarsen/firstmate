#!/usr/bin/env bash
set -eu
export TMPDIR="$HOME/tmp/fm-scratch/wake-story13-deploy-evidence"
mkdir -p "$TMPDIR"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

task_tmp=$(fm_test_tmproot fm-wake-daily-production)
case_home="$task_tmp/home"
mkdir -p "$case_home/data" "$case_home/state" "$case_home/projects" "$task_tmp/bin"
printf '## Done\n- [x] ship-a - Example deploy https://example.invalid/lab/datafeed/-/merge_requests/12 (repo: datafeed) (kind: ship) (merged 2026-11-21)\n- [x] ship-b - Unmeasured ship https://example.invalid/lab/other/-/merge_requests/15 (repo: other) (kind: ship) (merged 2026-11-21)\n' > "$case_home/data/backlog.md"
printf '## Done\n' > "$case_home/data/done-archive.md"
printf '{"v":1,"ts":1795280400,"event":"task.merged","task":"ship-a","pr":"https://example.invalid/lab/datafeed/-/merge_requests/12"}\n{"v":1,"ts":1795294800,"event":"task.merged","task":"ship-b","pr":"https://example.invalid/lab/other/-/merge_requests/15"}\n' > "$case_home/state/fleet-ledger.jsonl"
printf 'INFLUXDB_DEPLOY_METRICS_TOKEN=fixture-only\n' > "$case_home/.env"
cat > "$task_tmp/bin/glab" <<'SH'
#!/usr/bin/env bash
printf '[]\n'
SH
chmod +x "$task_tmp/bin/glab"
export PATH="$task_tmp/bin:$PATH"
cat > "$task_tmp/collect.py" <<'PY'
import importlib.util
import io
from pathlib import Path
import sys
from datetime import datetime
import urllib.request

source, home, fixture, mode = sys.argv[1:]
spec = importlib.util.spec_from_file_location("wake_daily", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Clock(datetime):
    @classmethod
    def now(cls, tz=None):
        return datetime.fromisoformat("2026-11-24T12:00:00+00:00").astimezone(tz)

class Response(io.BytesIO):
    def __enter__(self):
        return self
    def __exit__(self, *args):
        self.close()

def query(request, timeout):
    if mode == "unreachable":
        raise OSError("fixture outage")
    return Response(Path(fixture).read_bytes())

module.datetime = Clock
urllib.request.urlopen = query
sys.argv = [source, "2026-11-21", "--home", home]
module.main()
PY

collect() {
  python3 "$task_tmp/collect.py" "$ROOT/bin/fm-wake-daily.py" "$case_home" \
    "$ROOT/tests/fixtures/fm-wake-daily/deploy-points.csv" "$1" >/dev/null
}
record="$case_home/data/wake/daily/2026-11-21.json"
collect readable
jq -e '
  .coverage.signals.production_evidence == {"status":"measured","count":1}
  and .production_evidence.deployed[0].task == "ship-a"
  and .production_evidence.deployed[0].deploy_job_id == 123456
  and (.production_evidence.not_shown | length) == 3
  and .production_evidence.not_shown[0].path == "generate_nagios_cfg"
  and .production_evidence.not_shown[0].merged_at == "2026-11-21T19:00:00Z"
  and .production_evidence.not_shown[1].task == "ship-b"
  and .production_evidence.not_shown[1].path == null
  and .production_evidence.not_shown[1].merged_at == "2026-11-21T21:00:00Z"
  and .production_evidence.not_shown[1].reason == "no matching production measurement"
  and (.production_evidence.not_shown[2].mr | endswith("/merge_requests/14"))
  and .production_evidence.not_shown[2].path == "datafeed_config"
  and .production_evidence.not_shown[2].merged_at == "2026-11-22T06:00:00Z"
  and .production_evidence.not_shown[2].reason == "no successful production deploy recorded by day end"
  and (.production_evidence | tostring | contains("fixture-only") | not)
' "$record" >/dev/null || fail "production evidence did not match fixture"
cp "$record" "$task_tmp/first.json"
collect readable
cmp -s "$record" "$task_tmp/first.json" || fail "repeat record changed"

collect unreachable
jq -e '.coverage.signals.production_evidence.status == "not_measurable" and .coverage.signals.production_evidence.count == null' "$record" >/dev/null || fail "query outage reported zero"
rm "$case_home/.env"
collect readable
jq -e '.coverage.inputs["influxdb:lsg_deploy_metrics/deploy_lead_time"].reason == "read token absent" and .coverage.signals.production_evidence.count == null' "$record" >/dev/null || fail "missing token reported zero"
