#!/usr/bin/env bash
# Live lab driver: runs inside a pane of the lab's private tmux server ($TMUX set).
set -u
ROOT=$1 LAB=$2 OUT=$3 HS=$4
exec > "$OUT/transcript.txt" 2>&1
export FM_HOME="$LAB"
S="$LAB/state"
step() { printf '\n===== %s =====\n' "$*"; }
# crew-state: only the two CI ids are stubbed (no real no-mistakes ci-step run exists
# for those PRs in a lab); every other id is the real bin/fm-crew-state.sh.
cat > "$LAB/crew-state-shim" <<SH
#!/usr/bin/env bash
case "\$1" in
  mr-skipped) printf 'state: working · source: run-step · validating (running)\nrun-step: running/running\nrun-pr: https://lsg-git.lbl.gov/lblnet/generate_nagios_cfg/-/merge_requests/12416\n' ;;
  gh-wait) printf 'state: working · source: run-step · validating (ci)\nrun-step: ci/running\nrun-pr: https://github.com/clarsen/firstmate/pull/37\n' ;;
  *) exec "$ROOT/bin/fm-crew-state.sh" "\$@" ;;
esac
SH
chmod +x "$LAB/crew-state-shim"
export FM_CREW_STATE_BIN="$LAB/crew-state-shim"
declare -A PANE
for id in mr-skipped gh-wait committed-idle; do
  PANE[$id]=$("$ROOT/bin/fm-herdr-lab.sh" run "$HS" workspace create --cwd "$LAB" --label "fm-$id" --no-focus | jq -r '.result.root_pane.pane_id')
  echo "herdr pane for $id: $HS:${PANE[$id]}"
done
printf 'herdr\n' > "$LAB/config/backend"
wt="$LAB/projects/committed-idle"; mkdir -p "$wt"; git -C "$wt" init -q
echo impl > "$wt/change.txt"; git -C "$wt" add .; git -C "$wt" -c user.name=t -c user.email=t@e.invalid commit -qm impl
NOW=$(date +%s)
for id in mr-skipped gh-wait committed-idle; do
  printf 'kind=ship\nharness=claude\nbackend=herdr\nwindow=%s\nworktree=%s\nspawn_gen=lab1\nbranch=lab-%s\n' \
    "$HS:${PANE[$id]}" "$( [ $id = committed-idle ] && echo "$wt" || echo "$LAB/projects/x")" "$id" > "$S/$id.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$S" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$S" "$id" idle --gen "$gen" --source claude-hook --event stop
done
printf 'paused [at=%s]: CI monitor still running; resume on gate or final CI result\n' $((NOW-60)) > "$S/gh-wait.status"
printf 'working [at=%s]: bounded CI wait elapsed; monitor reattached\n' $((NOW-60)) > "$S/mr-skipped.status"
printf 'working [at=%s]: implementation committed\n' $((NOW-60)) > "$S/committed-idle.status"
tick() { FM_CREW_LEDGER_NOW=$1 "$ROOT/bin/fm-crew-ledger.sh" tick; echo "[tick exit=$?]"; }
step "real provider state (read-only)"
gh pr view 37 --repo clarsen/firstmate --json headRefOid,statusCheckRollup | jq -c '{head:.headRefOid,total:(.statusCheckRollup|length),by_status:(.statusCheckRollup|group_by(.status)|map({(.[0].status):length})|add),queued_completedAt:[.statusCheckRollup[]|select(.status!="COMPLETED")|.completedAt]|unique}'
glab api --hostname lsg-git.lbl.gov 'projects/lblnet%2Fgenerate_nagios_cfg/merge_requests/12416' | jq -c '{sha,head_pipeline:(.head_pipeline|{id,status,sha})}'
step "real crew-state for committed-idle (no validation run)"
s0=$SECONDS; timeout 90 "$ROOT/bin/fm-crew-state.sh" committed-idle; echo "[crew-state exit=$? in $((SECONDS-s0))s]"
step "tick 1 at now=$NOW"
tick "$NOW"
jq -c '.crew[]|{id,harness:.harness.state,status:.last_status.state,state:.current_state,step:.run_step.state,ci:(.ci_progress|if .==null then null else {provider,head,pipeline_id,pipeline_status,completed_count,latest_completed_at,progress_at} end),alert:.alert.condition}' "$S/crew-ledger.json"
step "tick 2 at now+60 (unchanged evidence must not repeat)"
tick $((NOW+60))
step "tick 3 at now+4000 (past FM_CREW_LEDGER_WAIT_SECS=1800 / IDLE 300)"
tick $((NOW+4000))
jq -c '.crew[]|{id,alert:.alert.condition,checked:.checked_at,ci_count:.ci_progress.completed_count}' "$S/crew-ledger.json"
step "tick 4 at now+4060 (no repeat)"
tick $((NOW+4060))
step "fleet view (Crew Ledger table)"
"$ROOT/bin/fm-fleet-view.sh" | sed -n '/## Crew Ledger/,/## Queued/p'
step "bearings snapshot crew_alerts"
"$ROOT/bin/fm-bearings-snapshot.sh" --json | jq -c '{crew_alerts, has_full_ledger:(has("crew_ledger"))}'
"$ROOT/bin/fm-bearings-snapshot.sh" --fields crew-ledger >/dev/null 2>&1; echo "bearings --fields crew-ledger exit=$? (opt-in removed)"
step "adversarial: busy harness and terminal done suppress alerts"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$S" gh-wait)
"$ROOT/bin/fm-busy-event.sh" apply "$S" gh-wait busy --gen "$gen" --source claude-hook --event prompt 2>&1 || echo "(busy apply exit=$?)"
printf 'done [at=%s]: delivered\n' $((NOW+4100)) >> "$S/committed-idle.status"
tick $((NOW+6000))
jq -c '.crew[]|{id,harness:.harness.state,status:.last_status.state,state:.current_state.state,alert:.alert.condition}' "$S/crew-ledger.json"
step "watcher end-to-end: fresh ledger, real fm-watch.sh surfaces the stalled crew"
rm -f "$S/crew-ledger.json" "$S/.wake-queue"
FM_CREW_LEDGER_CHECK_SECS=1 FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  timeout 60 "$ROOT/bin/fm-watch.sh" > "$OUT/watch1.out" 2> "$OUT/watch1.err"; echo "watcher exit=$?"
echo "--- watcher stdout:"; cat "$OUT/watch1.out"
echo "--- wake queue:"; cat "$S/.wake-queue" 2>/dev/null
step "watcher restart: unchanged evidence must not re-wake"
FM_CREW_LEDGER_CHECK_SECS=1 FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  timeout 12 "$ROOT/bin/fm-watch.sh" > "$OUT/watch2.out" 2> "$OUT/watch2.err"; echo "watcher exit=$? (124 = still blocking, no wake)"
echo "--- watcher stdout:"; cat "$OUT/watch2.out"
jq -c '{checked_at,crew:[.crew[]|{id,checked_at,alert:.alert.condition}]}' "$S/crew-ledger.json"
echo DRIVER-DONE
