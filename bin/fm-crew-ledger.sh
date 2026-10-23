#!/usr/bin/env bash
# fm-crew-ledger.sh - one observational record for this home's direct reports.
#
# `tick` is called by the watcher on a bounded cadence. It reads each local
# task's canonical fm-crew-state verdict and the independent harness busy
# verdict, then atomically replaces state/crew-ledger.json. A changed wait
# declaration, run-step, or PR job completion resets the relevant age.
# An alert is retained by signature until its evidence changes, so a watcher restart cannot repeat an unchanged
# alarm. This record never decides task lifecycle or merge authority.
#
# Usage: fm-crew-ledger.sh tick
# Configuration: FM_CREW_LEDGER_IDLE_SECS (default 300),
# FM_CREW_LEDGER_WAIT_SECS (default 1800), FM_CREW_LEDGER_STATE_TIMEOUT
# (default 12), FM_CREW_LEDGER_CI_TIMEOUT (default 8), and
# FM_CREW_LEDGER_BUDGET_SECS (default 20). The watcher owns
# FM_CREW_LEDGER_CHECK_SECS.
# Once the tick budget is spent, remaining crew keep their previous rows; crew
# are visited least-recently-checked first so every report is eventually read.
# CI progress is the latest of the run-step or wait change, the newest finished
# job on the current head, and the retained progress for that same head.
# GitHub CI waits use completed checks on the PR's current head, selected by
# status because gh reports a 0001-01-01 completedAt on queued checks; GitLab waits
# use finished jobs on the MR's head pipeline and surface a skipped head immediately.
# An unreadable crew-state verdict or CI read keeps the previous observation for
# up to FM_CREW_LEDGER_WAIT_SECS after its last successful read, so a transient
# failure cannot start a new alert episode; older evidence is reported unverified,
# and current_state.observed_at keeps the last successful crew-state read.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER="$STATE/crew-ledger.json"
CREW_STATE="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
NOW="${FM_CREW_LEDGER_NOW:-$(date +%s)}"
IDLE_SECS=${FM_CREW_LEDGER_IDLE_SECS:-300}
WAIT_SECS=${FM_CREW_LEDGER_WAIT_SECS:-1800}
STATE_TIMEOUT=${FM_CREW_LEDGER_STATE_TIMEOUT:-12}
CI_TIMEOUT=${FM_CREW_LEDGER_CI_TIMEOUT:-8}
BUDGET_SECS=${FM_CREW_LEDGER_BUDGET_SECS:-20}
GH_BIN=${FM_CREW_LEDGER_GH_BIN:-gh}
GLAB_BIN=${FM_CREW_LEDGER_GLAB_BIN:-glab}
for value in "$NOW" "$IDLE_SECS" "$WAIT_SECS" "$STATE_TIMEOUT" "$CI_TIMEOUT" "$BUDGET_SECS"; do
  case "$value" in ''|*[!0-9]*|0) echo "fm-crew-ledger: positive integer required" >&2; exit 2 ;; esac
done

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=/dev/null # The wake owner is linted as a separate root.
. "$SCRIPT_DIR/fm-wake-lib.sh"

[ "${1:-}" = tick ] && [ "$#" -eq 1 ] || {
  echo "usage: fm-crew-ledger.sh tick" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || { echo "fm-crew-ledger: jq not found" >&2; exit 1; }
mkdir -p "$STATE"
tmp=$(umask 077; mktemp -d "$STATE/.crew-ledger.XXXXXX") || exit 1
trap 'rm -rf -- "$tmp"' EXIT
if [ -f "$LEDGER" ] && jq -e '.schema == "fm-crew-ledger.v1" and (.crew | type == "array")' "$LEDGER" >/dev/null 2>&1; then
  cp -- "$LEDGER" "$tmp/previous.json" || exit 1
else
  printf '{"schema":"fm-crew-ledger.v1","crew":[]}\n' > "$tmp/previous.json"
fi
: > "$tmp/rows"
: > "$tmp/alerts"

while IFS= read -r meta <&3; do
  id=${meta##*/}; id=${id%.meta}
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  generation=$(fm_meta_get "$meta" spawn_gen)
  [ -n "$generation" ] || generation="$(fm_backend_target_of_meta "$meta")|$(fm_meta_get "$meta" worktree)|$(fm_meta_get "$meta" branch)"
  previous=$(jq -c --arg id "$id" --arg generation "$generation" \
    '.crew[]? | select(.id == $id and .generation == $generation)' "$tmp/previous.json" | head -1)
  [ -n "$previous" ] || previous='{}'
  if [ "$SECONDS" -ge "$BUDGET_SECS" ]; then
    [ "$previous" = '{}' ] || printf '%s\n' "$previous" >> "$tmp/rows"
    continue
  fi

  status_file="$STATE/$id.status"
  status_raw=$(grep -v '^[[:space:]]*$' "$status_file" 2>/dev/null | tail -1 || true)
  status_verb=$(status_line_verb "$status_raw")
  status_at=$(status_line_at_epoch "$status_raw" 2>/dev/null || true)
  case "$status_at" in ''|*[!0-9]*) status_at=null ;; esac
  wait_raw=$(status_declared_wait_line "$status_file")
  wait_at=$(status_line_at_epoch "$wait_raw" 2>/dev/null || true)
  case "$wait_at" in ''|*[!0-9]*) wait_at=null ;; esac
  wait_class=none
  if status_is_paused "$wait_raw"; then
    wait_class=paused
  elif status_is_captain_held "$wait_raw"; then
    wait_class=captain-held
  fi

  state_output=$(fm_run_timed "$STATE_TIMEOUT" env FM_CREW_STATE_LEDGER=1 "$CREW_STATE" "$id" 2>/dev/null || true)
  state_line=$(printf '%s\n' "$state_output" | head -1)
  step_label=$(printf '%s\n' "$state_output" | sed -n 's/^run-step: //p' | head -1)
  run_pr=$(printf '%s\n' "$state_output" | sed -n 's/^run-pr: //p' | head -1)
  state=unknown source=none detail="" state_observed_at=$NOW
  case "$state_line" in
    state:\ *' · source: '*)
      rest=${state_line#state: }
      state=${rest%%' · source: '*}
      rest=${rest#*' · source: '}
      source=${rest%%' · '*}
      [ "$source" != "$rest" ] && detail=${rest#*' · '} || detail=
      ;;
    *)
      state_observed_at=$(jq -c '.current_state.observed_at // null' <<< "$previous")
      if jq -e --argjson now "$NOW" --argjson wait "$WAIT_SECS" \
        '$now - (.current_state.observed_at // 0) < $wait' <<< "$previous" >/dev/null 2>&1; then
        echo "fm-crew-ledger.sh:$LINENO: crew-state unreadable for $id; keeping previous observation" >&2
        state=$(jq -r '.current_state.state // "unknown"' <<< "$previous")
        source=$(jq -r '.current_state.source // "none"' <<< "$previous")
        detail=$(jq -r '.current_state.detail // ""' <<< "$previous")
        step_label=$(jq -r 'if .current_state.source == "run-step" then .run_step.state // "" else "" end' <<< "$previous")
        run_pr=$(jq -r '.run_step.pr_url // ""' <<< "$previous")
      else
        echo "fm-crew-ledger.sh:$LINENO: crew-state unreadable for $id; no recent observation" >&2
      fi
      ;;
  esac

  harness=unknown harness_source=unavailable
  if [ -z "$(fm_meta_get "$meta" remote_host)" ]; then
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$target" ]; then
      tail40=$(fm_backend_capture "$backend" "$target" 40 "fm-$id" 2>/dev/null) || tail40=
      verdict=$(fm_busy_classify_meta "$meta" "$id" "$STATE" "$tail40")
      harness=${verdict%% *}
      harness_source=${verdict#* }
      case "$harness" in
        busy) harness=running ;;
        idle|unknown) ;;
        *) harness=unknown ;;
      esac
    fi
  fi

  ci_snapshot=null ci_candidate=false
  if [ "$harness" = idle ] && [ "$state" = working ] && [ "$wait_class" != captain-held ] \
    && [ -n "$run_pr" ] && [ "$source" = run-step ] \
    && fm_pr_url_parse "$run_pr"; then
    case "$step_label" in
      ci|ci/*|*/running|*/running/*)
        ci_candidate=true
        if [ "$FM_PR_PROVIDER" = github ]; then
          ci_raw=$(fm_run_timed "$CI_TIMEOUT" "$GH_BIN" pr view "$run_pr" \
            --json headRefOid,statusCheckRollup 2>/dev/null) || ci_raw=
          if [ -n "$ci_raw" ]; then
            ci_snapshot=$(printf '%s\n' "$ci_raw" | jq -ce '
            if (.headRefOid | type) != "string" or
               (.headRefOid | test("^[0-9a-f]{40}$") | not) or
               (.statusCheckRollup | type) != "array"
            then error("invalid PR checks")
            else [.statusCheckRollup[] | select(.status == "COMPLETED" and (.completedAt // "") != "")] as $done
            | {
              provider:"github",
              head:.headRefOid,
              completed_count:($done | length),
              latest_completed_at:([$done[].completedAt | fromdateiso8601] | max // null)
            } end' 2>/dev/null) || ci_snapshot=null
          fi
        elif [ "$FM_PR_PROVIDER" = gitlab ]; then
          encoded_path=$(jq -rn --arg path "$FM_PR_PATH" '$path | @uri')
          mr_api="projects/$encoded_path/merge_requests/$FM_PR_NUMBER"
          ci_raw=$(fm_run_timed "$CI_TIMEOUT" "$GLAB_BIN" api --hostname "$FM_PR_HOST" \
            "$mr_api" 2>/dev/null) || ci_raw=
          if [ -n "$ci_raw" ]; then
            ci_snapshot=$(printf '%s\n' "$ci_raw" | jq -ce '
              (.sha // .diff_refs.head_sha) as $head
              | if ($head | type) != "string" or ($head | test("^[0-9a-f]{40}$") | not) or
                   (.head_pipeline | type) != "object" or .head_pipeline.sha != $head or
                   (.head_pipeline.status | type) != "string" or
                   (.head_pipeline.id | type) != "number"
                then error("current head pipeline unavailable")
                else {provider:"gitlab",head:$head,pipeline_id:.head_pipeline.id,
                  pipeline_status:.head_pipeline.status,completed_count:0,latest_completed_at:null}
                end' 2>/dev/null) || ci_snapshot=null
            if [ "$ci_snapshot" != null ]; then
              pipeline_id=$(jq -r '.pipeline_id' <<< "$ci_snapshot")
              jobs_raw=$(fm_run_timed "$CI_TIMEOUT" "$GLAB_BIN" api --hostname "$FM_PR_HOST" \
                --paginate "projects/$encoded_path/pipelines/$pipeline_id/jobs?per_page=100" 2>/dev/null) || jobs_raw=
              if [ -n "$jobs_raw" ]; then
                jobs_progress=$(printf '%s\n' "$jobs_raw" | jq -sc '
                  if all(.[]; type == "array") then
                    [ .[][] | select((.finished_at // "") != "") ] as $finished
                    | {completed_count:($finished | length),
                       latest_completed_at:([$finished[].finished_at | sub("\\.[0-9]+"; "") |
                         fromdateiso8601] | max // null)}
                  else error("invalid pipeline jobs") end' 2>/dev/null) || jobs_progress=
                if [ -n "$jobs_progress" ]; then
                  ci_snapshot=$(jq -cn --argjson ci "$ci_snapshot" --argjson jobs "$jobs_progress" '$ci + $jobs')
                elif [ "$(jq -r '.pipeline_status' <<< "$ci_snapshot")" != skipped ]; then
                  ci_snapshot=null
                fi
              elif [ "$(jq -r '.pipeline_status' <<< "$ci_snapshot")" != skipped ]; then
                ci_snapshot=null
              fi
            fi
          fi
        fi
        [ "$ci_snapshot" != null ] ||
          echo "fm-crew-ledger.sh:$LINENO: CI evidence unavailable for $id" >&2
        ;;
    esac
  fi

  row=$(jq -cn \
    --argjson previous "$previous" --arg id "$id" --arg kind "$kind" \
    --arg generation "$generation" --arg status_raw "$status_raw" \
    --arg status_verb "$status_verb" --argjson status_at "$status_at" \
    --arg wait_raw "$wait_raw" --arg wait_class "$wait_class" --argjson wait_at "$wait_at" \
    --arg state "$state" --argjson state_observed_at "$state_observed_at" --arg source "$source" --arg detail "$detail" --arg step_label "$step_label" \
    --arg run_pr "$run_pr" --argjson ci "$ci_snapshot" --argjson ci_candidate "$ci_candidate" \
    --arg harness "$harness" --arg harness_source "$harness_source" \
    --argjson now "$NOW" --argjson idle_seconds "$IDLE_SECS" \
    --argjson wait_seconds "$WAIT_SECS" '
    ($previous // {}) as $old
    | (if $ci != null then $ci + {observed_at:$now}
       elif $ci_candidate and $old.ci_progress != null and $old.ci_progress.pr_url == $run_pr and
            $now - ($old.ci_progress.observed_at // 0) < $wait_seconds
       then $old.ci_progress | del(.pr_url, .progress_at)
       else null end) as $ci
    | (if $harness == $old.harness.state then ($old.harness.since // $now) else $now end) as $harness_since
    | (if $source == "run-step" then
         (if $step_label != "" then $step_label else ($state + " / " + $detail) end)
       else null end) as $step
    | (if $step == null then null
       elif $step == $old.run_step.state
       then ($old.run_step.changed_at // $now)
       elif $step != null and $old.run_step.state != null and $step != $old.run_step.state
       then $now
       elif $step != null and $wait_class == "paused" and $wait_at != null and $wait_at <= $now
       then $wait_at
       else $now end) as $step_changed
    | (if $wait_class == "none" then null
       elif $wait_raw == $old.declared_wait.raw then ($old.declared_wait.since // $now)
       elif $wait_at != null and $wait_at <= $now then $wait_at
       else $now end) as $wait_since
    | ([$step_changed, $wait_since] | map(select(. != null)) | max) as $wait_progress_at
    | (if $ci == null then null
       elif ($ci.head != $old.ci_progress.head and $old.ci_progress.head != null) or
            ($ci.pipeline_id != $old.ci_progress.pipeline_id and $old.ci_progress.pipeline_id != null)
       then $now
       elif $ci.completed_count < ($old.ci_progress.completed_count // 0) and $old.ci_progress.head != null
       then $now
       elif $ci.completed_count > ($old.ci_progress.completed_count // 0) and
            $ci.latest_completed_at == $old.ci_progress.latest_completed_at and
            $old.ci_progress.head != null
       then $now
       else ([$wait_progress_at, $ci.latest_completed_at, $old.ci_progress.progress_at]
             | map(select(. != null)) | max) end) as $ci_progress_at
    | (if $kind == "secondmate" or $harness != "idle" or $wait_class == "captain-held" or
          ([$state] | any(. == "done" or . == "blocked" or . == "failed" or . == "parked"))
       then null
       elif $state_observed_at != null and $now - $state_observed_at >= $wait_seconds
       then "crew-state-unverified"
       elif $ci.provider == "gitlab" and $ci.pipeline_status == "skipped"
       then "ci-head-skipped"
       elif $ci != null and $now - $ci_progress_at >= $wait_seconds
       then (if $wait_class == "paused" then "declared-wait-no-ci-progress" else "run-step-no-ci-progress" end)
       elif $ci_candidate and $ci == null and $step != null and $now - $wait_progress_at >= $wait_seconds
       then (if $wait_class == "paused" then "declared-wait-ci-unverified" else "run-step-ci-unverified" end)
       elif $wait_class == "paused" and $ci == null and $step != null and $now - $wait_progress_at >= $wait_seconds
       then "declared-wait-no-run-progress"
       elif $wait_class == "paused" and $step == null and $now - ([$harness_since,$wait_since] | max) >= $wait_seconds
       then "declared-wait-no-progress"
       elif $step != null and $wait_class != "paused" and ($ci_candidate | not) and $now - $step_changed >= $wait_seconds
       then "run-step-no-progress"
       elif $step != null then null
       elif $wait_class != "paused" and $now - $harness_since >= $idle_seconds
       then "idle-without-terminal-status"
       else null end) as $condition
    | (if $condition == null then null
       else [$condition,(if $wait_class == "paused" then $wait_raw else $status_raw end),($step // ""),
             (if $condition == "crew-state-unverified" then $state_observed_at
              elif $condition == "idle-without-terminal-status" then $harness_since
              elif $ci != null then $ci_progress_at
              elif $wait_class == "paused" then $wait_progress_at else $step_changed end),
             ($ci.head // ""),($ci.pipeline_id // 0),($ci.pipeline_status // ""),
             ($ci.completed_count // 0),($ci.latest_completed_at // 0)] | @json end) as $signature
    | {
        id:$id,kind:$kind,generation:$generation,checked_at:$now,
        harness:{state:$harness,source:$harness_source,since:$harness_since},
        last_status:{state:$status_verb,raw:$status_raw,at:$status_at},
        declared_wait:{class:$wait_class,raw:$wait_raw,at:$wait_at,since:$wait_since},
        current_state:{state:$state,source:$source,detail:$detail,observed_at:$state_observed_at},
        run_step:{state:$step,changed_at:(if $step == null then null else $step_changed end),
          pr_url:(if $run_pr == "" then null else $run_pr end)},
        ci_progress:(if $ci == null then null else ($ci + {pr_url:$run_pr,progress_at:$ci_progress_at}) end),
        alert:(if $signature == null then null
               elif $signature == $old.alert.signature then $old.alert
               else {condition:$condition,signature:$signature,reported_at:$now} end)
      }
    ') || {
    echo "fm-crew-ledger.sh:$LINENO: row evaluation failed for $id" >&2
    exit 1
  }
  printf '%s\n' "$row" >> "$tmp/rows"
  if jq -e --argjson old "$previous" '.alert != null and .alert.signature != $old.alert.signature' <<< "$row" >/dev/null; then
    condition=$(jq -r '.alert.condition' <<< "$row")
    step=$(jq -r '.run_step.state // "none"' <<< "$row")
    ci_detail=$(jq -r 'if .alert.condition == "crew-state-unverified" then
      "crew-state unreadable since " + (.current_state.observed_at | tostring) +
      "; inspect worker and fm-crew-state"
      elif .run_step.state == null then
      "no attributed validation run; inspect commit and worker status"
      elif .ci_progress == null then
      "PR=" + (.run_step.pr_url // "unknown") + "; CI evidence unavailable" else
      "PR=" + .ci_progress.pr_url + "; pipeline=" + (.ci_progress.pipeline_status // "unknown") +
      "; completed-checks=" + (.ci_progress.completed_count | tostring) +
      "; last-completion=" + ((.ci_progress.latest_completed_at // "none") | tostring) end' <<< "$row")
    printf 'check: crew-ledger %s %s; pane=%s; status=%s; run-step=%s; %s; last-checked=%s; inspect worker and validation\n' \
      "$id" "$condition" "$harness" "${status_verb:-none}" "${step:-none}" "$ci_detail" "$NOW" >> "$tmp/alerts"
  fi
done 3< <(
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    checked=$(jq -r --arg id "$id" 'first(.crew[]? | select(.id == $id) | .checked_at // 0) // 0' "$tmp/previous.json")
    printf '%s\t%s\n' "$checked" "$meta"
  done | sort -s -n -k1,1 | cut -f2-
)

jq -s --argjson checked_at "$NOW" \
  '{schema:"fm-crew-ledger.v1",checked_at:$checked_at,crew:sort_by(.id)}' "$tmp/rows" > "$tmp/next.json" || exit 1
if [ -s "$tmp/alerts" ]; then
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
  while IFS= read -r reason; do
    [ -n "$reason" ] || continue
    if ! fm_wake_append_locked check crew-ledger "$reason"; then
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      exit 1
    fi
  done < "$tmp/alerts"
  if ! mv -- "$tmp/next.json" "$LEDGER"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    exit 1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
else
  mv -- "$tmp/next.json" "$LEDGER" || exit 1
fi
cat "$tmp/alerts"
