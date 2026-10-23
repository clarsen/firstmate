#!/usr/bin/env bash
# Live drive: crew ledger + watcher against a disposable lab home with real tmux
# panes, real fm-crew-state, real gh (PR 35) and real glab (MR 12416), read-only.
set -u
WT=/home/ctlarsen/.no-mistakes/worktrees/6442e268076a/01M5M02BJCPYBRJ10F0A80A771
EV=/home/ctlarsen/.no-mistakes/evidence/01M5M02BJCPYBRJ10F0A80A771
unset TMUX FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
out=$("$EV/lab-setup.sh") || exit 1
eval "$out"
export TMUX_TMPDIR=$TMUXD
REAL_TMUX=$(command -v tmux)
export FM_LAB_NM=$LAB/nm FM_HOME=$LAB PATH="$LAB/fakebin:$PATH"
export FM_CREW_LEDGER_IDLE_SECS=20
cleanup() { "$REAL_TMUX" kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$LAB"; rm -rf "$LAB"; }
trap cleanup EXIT
cd "$WT"
sec() { printf '\n===== %s =====\n' "$*"; }
rows() { jq -c '.crew[] | {id,harness:.harness.state,status:.last_status.state,state:.current_state.state,source:.current_state.source,run_step:.run_step.state,ci:(.ci_progress|if .==null then null else {provider,head,completed_count,latest_completed_at,pipeline_status,progress_at} end),alert:.alert.condition}' "$LAB/state/crew-ledger.json"; }

sec "S0 real fm-crew-state verdicts (the reported blind spot)"
for id in bearings-card-nav-fixed lagmon-uv-cache-guard committed-idle busy-worker done-worker; do
  printf '%s: ' "$id"; bin/fm-crew-state.sh "$id"
done
for id in bearings-card-nav-fixed committed-idle busy-worker; do
  printf '%s pane: %s\n' "$id" "$(tmux capture-pane -p -t "firstmate:fm-$id" | grep -v '^$' | tr '\n' '|')"
done

sec "S1 tick #1 at $(date +%s) (real gh PR 35, real glab MR 12416)"
bin/fm-crew-ledger.sh tick; echo "exit=$?"
rows
sec "S2 tick #2 immediately - unchanged evidence must not re-alert"
o=$(bin/fm-crew-ledger.sh tick 2>&1); echo "output=[${o}] exit=$?"
sec "wake queue after ticks"
cat "$LAB/state/.wake-queue" 2>/dev/null

sec "S3 real fm-watch.sh in lab: committed-idle crew past FM_CREW_LEDGER_IDLE_SECS=20"
sleep 22
FM_CREW_LEDGER_CHECK_SECS=1 FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 timeout 60 bin/fm-watch.sh > "$LAB/watch.out" 2> "$LAB/watch.err"
echo "watcher exit=$?"
echo "--- watcher stdout"; cat "$LAB/watch.out"
echo "--- watcher stderr (tail)"; tail -5 "$LAB/watch.err"
echo "--- wake queue"; cat "$LAB/state/.wake-queue"
rows

sec "S4 fleet view Crew Ledger table + Bearings crew_alerts"
bin/fm-fleet-view.sh | sed -n '/## Crew Ledger/,/^$/p'
bin/fm-bearings-snapshot.sh --json 2>/dev/null | jq -c '.crew_alerts'

sec "S5 adversarial: busy-worker suppressed only while busy; now its turn ends"
bin/fm-busy-event.sh apply "$LAB/state" busy-worker idle --current-gen --source claude-hook --event stop
bin/fm-crew-ledger.sh tick; rows | grep -E 'busy-worker|done-worker'

sec "S6 bearings-card-nav-fixed reports done -> alert clears, no new wake"
printf 'done [at=%s]: PR https://github.com/clarsen/firstmate/pull/35 checks green\n' "$(date +%s)" >> "$LAB/state/bearings-card-nav-fixed.status"
o=$(bin/fm-crew-ledger.sh tick 2>&1); echo "output=[${o}]"
rows | grep bearings-card-nav-fixed
cp "$LAB/state/crew-ledger.json" "$EV/crew-ledger-final.json"
sec "teardown"
