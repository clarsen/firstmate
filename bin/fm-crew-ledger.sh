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
# FM_CREW_LEDGER_WAIT_SECS (default 1800), FM_CREW_LEDGER_GATE_SECS (default
# 600), FM_CREW_LEDGER_PIPELINE_STALE_SECS (default 300),
# FM_CREW_LEDGER_STATE_TIMEOUT (default 12), FM_CREW_LEDGER_CI_TIMEOUT (default
# 8), and FM_CREW_LEDGER_BUDGET_SECS (default 20). The watcher owns
# FM_CREW_LEDGER_CHECK_SECS.
# Two conditions rest on evidence outside the pane, so they are raised for any
# worker whose harness does not read running - an unreadable harness included,
# where every other condition stays silent:
#   gate-awaiting-decision  the attributed run is parked at a gate whose answer
#     a human owes (crew_gate_awaits_human_decision in fm-classify-lib.sh) and
#     nothing has moved for FM_CREW_LEDGER_GATE_SECS. While the worker's own
#     `nm-<run>-<step>` report of that gate is open the clock is the newest
#     status event, so a reported gate is aged from its report; otherwise it is
#     the later of the newest status event and the first tick that read this
#     gate parked, so a worker still writing its report is not raced. One alert
#     is raised per quiet episode, and a captain-held lane is exempt.
#   ci-pipeline-stale  a GitLab pipeline the worker waits on is still created,
#     waiting_for_resource, preparing, pending or running, every job and
#     trigger (bridge) job in it reports a status, none is one a runner or
#     downstream pipeline can still advance (pending, running, preparing,
#     waiting_for_resource, scheduled, canceling), and that
#     has held for FM_CREW_LEDGER_PIPELINE_STALE_SECS since the later of its
#     newest job finish and the pipeline's own last update. That is a pipeline
#     the forge stopped processing, not one still running. The pipeline is the
#     run's merge request head pipeline while the run's CI step is active;
#     otherwise it is the first merge request or pipeline URL the declared wait
#     names, read only when that URL is on the GitLab host of the task's own
#     recorded or run PR, because a status line is worker-written text and must
#     not choose where a forge credential is sent. Each row keeps the evidence
#     as gate and pipeline. Nothing is cancelled or retried here.
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
# Each row also has title (backlog title, then first Captain's intent line, or
# null), request (first Captain's intent line or null), project (the recorded
# project directory's name, or null), worktree from metadata, and
# current_state.since (the epoch the reconciled state changed).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER="$STATE/crew-ledger.json"
CREW_STATE="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
NOW="${FM_CREW_LEDGER_NOW:-$(date +%s)}"
IDLE_SECS=${FM_CREW_LEDGER_IDLE_SECS:-300}
WAIT_SECS=${FM_CREW_LEDGER_WAIT_SECS:-1800}
GATE_SECS=${FM_CREW_LEDGER_GATE_SECS:-600}
PIPELINE_STALE_SECS=${FM_CREW_LEDGER_PIPELINE_STALE_SECS:-300}
STATE_TIMEOUT=${FM_CREW_LEDGER_STATE_TIMEOUT:-12}
CI_TIMEOUT=${FM_CREW_LEDGER_CI_TIMEOUT:-8}
BUDGET_SECS=${FM_CREW_LEDGER_BUDGET_SECS:-20}
GH_BIN=${FM_CREW_LEDGER_GH_BIN:-gh}
GLAB_BIN=${FM_CREW_LEDGER_GLAB_BIN:-glab}
for value in "$NOW" "$IDLE_SECS" "$WAIT_SECS" "$GATE_SECS" "$PIPELINE_STALE_SECS" "$STATE_TIMEOUT" "$CI_TIMEOUT" "$BUDGET_SECS"; do
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
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
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

# jq: a forge timestamp as epoch seconds, or null when it is not one.
# GitLab renders times in the instance's configured zone
# (`2026-01-02T10:15:30.123-08:00`), which jq's fromdateiso8601 refuses, and no
# jq or date primitive reads an offset on both GNU and BSD userlands. The date
# is therefore still parsed by fromdateiso8601 and only the numeric offset is
# applied here.
# shellcheck disable=SC2016 # jq variables, not shell expansions
JQ_FORGE_EPOCH='def forge_epoch:
  if type != "string" then null
  else (capture("^(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$") // null) as $m
  | if $m == null then null
    else (try (($m.t + "Z") | fromdateiso8601) catch null) as $utc
    | if $utc == null or $m.z == "Z" then $utc
      else $utc - (if $m.z[0:1] == "-" then -1 else 1 end) *
           (($m.z[1:3] | tonumber) * 3600 + ($m.z[4:6] | tonumber) * 60) end
    end
  end;'

# 0 when a run-step label reports the run's CI step as the active one.
ledger_step_is_ci() {  # <run-step label>
  case "$1" in ci|ci/*|*/running|*/running/*) return 0 ;; esac
  return 1
}

# The first GitLab pipeline or merge request URL a declared wait names.
ledger_wait_forge_url() {  # <wait-line>
  local re='(https://[^[:space:]]+/-/(pipelines|merge_requests)/[1-9][0-9]*)'
  [[ $1 =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# Parse <url> as a GitLab pipeline URL under the shared forge host and project
# path rules. Sets PIPELINE_HOST, PIPELINE_PATH and PIPELINE_ID.
ledger_pipeline_url_parse() {  # <url>
  local re='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/pipelines/([1-9][0-9]*)$'
  PIPELINE_HOST='' PIPELINE_PATH='' PIPELINE_ID=''
  [[ $1 =~ $re ]] || return 1
  fm_pr_forge_host_valid "${BASH_REMATCH[1]}" || return 1
  fm_pr_gitlab_path_valid "${BASH_REMATCH[2]}" || return 1
  PIPELINE_HOST=${BASH_REMATCH[1]} PIPELINE_PATH=${BASH_REMATCH[2]} PIPELINE_ID=${BASH_REMATCH[3]}
}

# One pipeline's census of its jobs and trigger (bridge) jobs, for the stale
# classification the header owns. A job with no status string is left
# unclassified, so a response that cannot say what its jobs are doing never
# reads as a pipeline with nothing running.
ledger_pipeline_evidence() {  # <subject-url> <pipeline-object-json> <jobs-pages-json> <bridges-pages-json>
  local jobs bridges
  jobs=$(printf '%s\n' "$3" | jq -sc '.' 2>/dev/null) || return 1
  bridges=$(printf '%s\n' "$4" | jq -sc '.' 2>/dev/null) || return 1
  jq -nc --arg subject "$1" --argjson pipeline "$2" --argjson jobs "$jobs" \
    --argjson bridges "$bridges" "$JQ_FORGE_EPOCH"'
    def pages_valid: length > 0 and all(.[]; type == "array");
    if ($pipeline | type) != "object" or ($pipeline.id | type) != "number" or
       ($pipeline.status | type) != "string" or ($jobs | pages_valid | not) or
       ($bridges | pages_valid | not)
    then error("invalid pipeline evidence")
    else [ $jobs[][], $bridges[][] ] as $jobs
    | [ $jobs[] | select((.finished_at // "") != "") ] as $finished
    | {subject:$subject, pipeline_id:$pipeline.id, pipeline_status:$pipeline.status,
       pipeline_updated_at:(($pipeline.updated_at // $pipeline.created_at) | forge_epoch),
       job_count:($jobs | length),
       classified_count:([$jobs[] | select((.status | type) == "string")] | length),
       active_count:([$jobs[] | select(.status == "pending" or .status == "running" or
         .status == "preparing" or .status == "waiting_for_resource" or
         .status == "scheduled" or .status == "canceling")] | length),
       finished_count:($finished | length),
       latest_finished_at:([$finished[].finished_at | forge_epoch |
         if . == null then error("invalid job time") else . end] | max // null)}
    end' 2>/dev/null
}

# Read a pipeline's trigger (bridge) jobs and build its census from the
# already-read pipeline object and jobs pages.
ledger_pipeline_census() {  # <subject-url> <host> <project-path> <pipeline-object-json> <jobs-pages-json>
  local encoded pipeline_id bridges
  encoded=$(jq -rn --arg path "$3" '$path | @uri') || return 1
  pipeline_id=$(printf '%s\n' "$4" | jq -re '.id | numbers' 2>/dev/null) || return 1
  bridges=$(fm_run_timed "$CI_TIMEOUT" "$GLAB_BIN" api --hostname "$2" \
    --paginate "projects/$encoded/pipelines/$pipeline_id/bridges?per_page=100" 2>/dev/null) || return 1
  ledger_pipeline_evidence "$1" "$4" "$5" "$bridges"
}

# Read one GitLab pipeline, its jobs and its trigger jobs. <reference> is
# `merge_requests/<n>`, whose head pipeline is read, or `pipelines/<id>`.
ledger_pipeline_read() {  # <subject-url> <host> <project-path> <reference>
  local subject=$1 host=$2 encoded reference=$4 raw pipeline pipeline_id jobs
  encoded=$(jq -rn --arg path "$3" '$path | @uri') || return 1
  raw=$(fm_run_timed "$CI_TIMEOUT" "$GLAB_BIN" api --hostname "$host" \
    "projects/$encoded/$reference" 2>/dev/null) || return 1
  case "$reference" in
    merge_requests/*) pipeline=$(printf '%s\n' "$raw" | jq -ce '.head_pipeline | objects' 2>/dev/null) || return 1 ;;
    *) pipeline=$(printf '%s\n' "$raw" | jq -ce 'objects' 2>/dev/null) || return 1 ;;
  esac
  pipeline_id=$(printf '%s\n' "$pipeline" | jq -re '.id | numbers' 2>/dev/null) || return 1
  jobs=$(fm_run_timed "$CI_TIMEOUT" "$GLAB_BIN" api --hostname "$host" \
    --paginate "projects/$encoded/pipelines/$pipeline_id/jobs?per_page=100" 2>/dev/null) || return 1
  ledger_pipeline_census "$subject" "$host" "$3" "$pipeline" "$jobs"
}

while IFS= read -r meta <&3; do
  id=${meta##*/}; id=${id%.meta}
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  worktree=$(fm_meta_get "$meta" worktree)
  project_path=$(fm_meta_get "$meta" project)
  project=
  [ -z "$project_path" ] || project=$(basename -- "$project_path")
  brief="$FM_HOME/data/$id/brief.md"
  request=
  if [ -f "$brief" ]; then
    request=$(fm_brief_task_heading_body "$brief" "## Captain's intent" | awk 'NF { print; exit }')
  fi
  generation=$(fm_meta_get "$meta" spawn_gen)
  [ -n "$generation" ] || generation="$(fm_backend_target_of_meta "$meta")|$(fm_meta_get "$meta" worktree)|$(fm_meta_get "$meta" branch)"
  previous=$(jq -c --arg id "$id" --arg generation "$generation" \
    '.crew[]? | select(.id == $id and .generation == $generation)' "$tmp/previous.json" | head -1)
  [ -n "$previous" ] || previous='{}'
  if [ "$SECONDS" -ge "$BUDGET_SECS" ]; then
    if [ "$previous" != '{}' ]; then
      jq -c --arg project "$project" \
        '. + {project:(if $project == "" then null else $project end)}' \
        <<< "$previous" >> "$tmp/rows"
    fi
    continue
  fi
  title=$request
  remaining=$((BUDGET_SECS - SECONDS))
  if [ "$remaining" -gt 2 ]; then remaining=2; fi
  if [ "$remaining" -gt 0 ]; then
    backlog_row=$(fm_run_timed "$remaining" env FM_HOME="$FM_HOME" \
      "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" 2>/dev/null) || backlog_row=
    backlog_title=$(printf '%s\n' "$backlog_row" | sed -n 's/^  title: //p' | head -1)
    case "$backlog_title" in
      \"*) backlog_title=$(printf '%s\n' "$backlog_title" | jq -r 'select(type == "string")' 2>/dev/null) || backlog_title= ;;
    esac
    [ -z "$backlog_title" ] || title=$backlog_title
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

  ci_snapshot=null ci_candidate=false ci_raw='' jobs_raw='' ci_step=false
  ! ledger_step_is_ci "$step_label" || ci_step=true
  if [ "$harness" = idle ] && [ "$state" = working ] && [ "$wait_class" != captain-held ] \
    && [ -n "$run_pr" ] && [ "$source" = run-step ] \
    && fm_pr_url_parse "$run_pr"; then
    case "$ci_step" in
      true)
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
                jobs_progress=$(printf '%s\n' "$jobs_raw" | jq -sc "$JQ_FORGE_EPOCH"'
                  if all(.[]; type == "array") then
                    [ .[][] | select((.finished_at // "") != "") ] as $finished
                    | {completed_count:($finished | length),
                       latest_completed_at:([$finished[].finished_at | forge_epoch |
                         if . == null then error("invalid job time") else . end] | max // null)}
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

  # Evidence for gate-awaiting-decision and ci-pipeline-stale (header contract).
  gate=null
  if [ "$state" = parked ] && [ -n "$state_line" ] \
    && gate_run=$(crew_gate_awaits_human_decision "$id" "$state_line"); then
    gate_reported=false
    ! status_has_open_needs_decision "$status_file" "$gate_run" || gate_reported=true
    gate=$(jq -cn --arg run "$gate_run" --argjson reported "$gate_reported" '{run:$run,reported:$reported}')
  fi
  pipeline=null
  if [ "$kind" != secondmate ] && [ "$harness" != running ] && [ "$wait_class" != captain-held ]; then
    pipeline_hosts=' ' pipeline_host='' pipeline_path='' pipeline_ref='' pipeline_url=''
    for pipeline_url in "$run_pr" "$(fm_meta_get "$meta" pr)"; do
      ! { fm_pr_url_parse "$pipeline_url" && [ "$FM_PR_PROVIDER" = gitlab ]; } ||
        pipeline_hosts="$pipeline_hosts$FM_PR_HOST "
    done
    pipeline_url=
    if [ "$state" = working ] && [ "$source" = run-step ] && [ "$ci_step" = true ]; then
      pipeline_url=$run_pr
    elif [ "$wait_class" = paused ]; then
      pipeline_url=$(ledger_wait_forge_url "$wait_raw") || pipeline_url=
    fi
    if fm_pr_url_parse "$pipeline_url" && [ "$FM_PR_PROVIDER" = gitlab ]; then
      pipeline_host=$FM_PR_HOST pipeline_path=$FM_PR_PATH pipeline_ref="merge_requests/$FM_PR_NUMBER"
    elif ledger_pipeline_url_parse "$pipeline_url"; then
      pipeline_host=$PIPELINE_HOST pipeline_path=$PIPELINE_PATH pipeline_ref="pipelines/$PIPELINE_ID"
    fi
    case "$pipeline_hosts" in *" ${pipeline_host:-?} "*) ;; *) pipeline_ref= ;; esac
    if [ -n "$pipeline_ref" ] && [ "$ci_candidate" = true ] && [ "$pipeline_url" = "$run_pr" ]; then
      # The CI read above already fetched this merge request and its jobs.
      [ -z "$ci_raw" ] || [ -z "$jobs_raw" ] ||
        pipeline=$(ledger_pipeline_census "$pipeline_url" "$pipeline_host" "$pipeline_path" \
          "$(jq -c '.head_pipeline' <<< "$ci_raw" 2>/dev/null)" "$jobs_raw") || pipeline=null
    elif [ -n "$pipeline_ref" ]; then
      pipeline=$(ledger_pipeline_read "$pipeline_url" "$pipeline_host" "$pipeline_path" "$pipeline_ref") || {
        echo "fm-crew-ledger.sh:$LINENO: pipeline evidence unavailable for $id" >&2
        pipeline=null
      }
    fi
    [ -n "$pipeline" ] || pipeline=null
  fi

  row=$(jq -cn \
    --argjson previous "$previous" --arg id "$id" --arg kind "$kind" \
    --arg title "$title" --arg request "$request" --arg project "$project" --arg worktree "$worktree" \
    --arg generation "$generation" --arg status_raw "$status_raw" \
    --arg status_verb "$status_verb" --argjson status_at "$status_at" \
    --arg wait_raw "$wait_raw" --arg wait_class "$wait_class" --argjson wait_at "$wait_at" \
    --arg state "$state" --argjson state_observed_at "$state_observed_at" --arg source "$source" --arg detail "$detail" --arg step_label "$step_label" \
    --arg run_pr "$run_pr" --argjson ci "$ci_snapshot" --argjson ci_candidate "$ci_candidate" \
    --argjson gate "$gate" --argjson pipeline "$pipeline" \
    --arg harness "$harness" --arg harness_source "$harness_source" \
    --argjson now "$NOW" --argjson idle_seconds "$IDLE_SECS" \
    --argjson wait_seconds "$WAIT_SECS" --argjson gate_seconds "$GATE_SECS" \
    --argjson pipeline_stale_seconds "$PIPELINE_STALE_SECS" '
    ($previous // {}) as $old
    | (if $ci != null then $ci + {observed_at:$now}
       elif $ci_candidate and $old.ci_progress != null and $old.ci_progress.pr_url == $run_pr and
            $now - ($old.ci_progress.observed_at // 0) < $wait_seconds
       then $old.ci_progress | del(.pr_url, .progress_at)
       else null end) as $ci
    | (if $harness == $old.harness.state then ($old.harness.since // $now) else $now end) as $harness_since
    | (if $state == $old.current_state.state then ($old.current_state.since // $now) else $now end) as $state_since
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
    | (if $gate == null then null
       elif $gate.run == $old.gate.run and $detail == $old.gate.detail then ($old.gate.since // $now)
       else $now end) as $gate_since
    | (if $gate == null then null
       elif $gate.reported and $status_at != null and $status_at <= $now then $status_at
       else ([$status_at, $gate_since] | map(select(. != null and . <= $now)) | max) end) as $gate_clock
    | (if $pipeline == null or $pipeline.classified_count != $pipeline.job_count or
          $pipeline.active_count > 0 or
          ([$pipeline.pipeline_status] | any(. == "created" or . == "waiting_for_resource" or
            . == "preparing" or . == "pending" or . == "running") | not)
       then null
       else ([$pipeline.latest_finished_at, $pipeline.pipeline_updated_at]
             | map(select(. != null)) | max) end) as $pipeline_stale_since
    | (if $kind == "secondmate" or $wait_class == "captain-held" then null
       elif $gate_clock != null and $harness != "running" and $now - $gate_clock >= $gate_seconds
       then "gate-awaiting-decision"
       elif $pipeline_stale_since != null and $now - $pipeline_stale_since >= $pipeline_stale_seconds
       then "ci-pipeline-stale"
       elif $harness != "idle" or
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
       elif $condition == "gate-awaiting-decision"
       then [$condition,$status_raw,($step // ""),$gate_clock,$gate.run] | @json
       elif $condition == "ci-pipeline-stale"
       then [$condition,$pipeline.subject,$pipeline.pipeline_id,$pipeline.pipeline_status,
             $pipeline_stale_since] | @json
       else [$condition,(if $wait_class == "paused" then $wait_raw else $status_raw end),($step // ""),
             (if $condition == "crew-state-unverified" then $state_observed_at
              elif $condition == "idle-without-terminal-status" then $harness_since
              elif $ci != null then $ci_progress_at
              elif $wait_class == "paused" then $wait_progress_at else $step_changed end),
             ($ci.head // ""),($ci.pipeline_id // 0),($ci.pipeline_status // ""),
             ($ci.completed_count // 0),($ci.latest_completed_at // 0)] | @json end) as $signature
    | {
        id:$id,kind:$kind,generation:$generation,checked_at:$now,
        title:(if $title == "" then null else $title end),
        request:(if $request == "" then null else $request end),
        project:(if $project == "" then null else $project end),
        worktree:(if $worktree == "" then null else $worktree end),
        harness:{state:$harness,source:$harness_source,since:$harness_since},
        last_status:{state:$status_verb,raw:$status_raw,at:$status_at},
        declared_wait:{class:$wait_class,raw:$wait_raw,at:$wait_at,since:$wait_since},
        current_state:{state:$state,source:$source,detail:$detail,observed_at:$state_observed_at,since:$state_since},
        run_step:{state:$step,changed_at:(if $step == null then null else $step_changed end),
          pr_url:(if $run_pr == "" then null else $run_pr end)},
        ci_progress:(if $ci == null then null else ($ci + {pr_url:$run_pr,progress_at:$ci_progress_at}) end),
        gate:(if $gate == null then null
              else $gate + {detail:$detail,since:$gate_since,quiet_since:$gate_clock} end),
        pipeline:(if $pipeline == null then null else $pipeline + {stale_since:$pipeline_stale_since} end),
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
    action='inspect worker and validation'
    case "$condition" in
      gate-awaiting-decision) action='decide the gate, or have the worker report it' ;;
      ci-pipeline-stale) action='inspect the pipeline on the forge; nothing was cancelled or retried' ;;
    esac
    ci_detail=$(jq -r 'if .alert.condition == "crew-state-unverified" then
      "crew-state unreadable since " + (.current_state.observed_at | tostring) +
      "; inspect worker and fm-crew-state"
      elif .alert.condition == "gate-awaiting-decision" then
      "gate=" + .gate.detail + "; reported=" + (if .gate.reported then "yes" else "no" end) +
      "; quiet-since=" + (.gate.quiet_since | tostring)
      elif .alert.condition == "ci-pipeline-stale" then
      "stale pipeline " + (.pipeline.pipeline_id | tostring) + " at " + .pipeline.subject +
      ": status=" + .pipeline.pipeline_status + " with no job a runner can advance; jobs-finished=" +
      (.pipeline.finished_count | tostring) + "/" + (.pipeline.job_count | tostring) +
      "; stale-since=" + (.pipeline.stale_since | tostring)
      elif .run_step.state == null then
      "no attributed validation run; inspect commit and worker status"
      elif .ci_progress == null then
      "PR=" + (.run_step.pr_url // "unknown") + "; CI evidence unavailable" else
      "PR=" + .ci_progress.pr_url + "; pipeline=" + (.ci_progress.pipeline_status // "unknown") +
      "; completed-checks=" + (.ci_progress.completed_count | tostring) +
      "; last-completion=" + ((.ci_progress.latest_completed_at // "none") | tostring) end' <<< "$row")
    printf 'check: crew-ledger %s %s; pane=%s; status=%s; run-step=%s; %s; last-checked=%s; %s\n' \
      "$id" "$condition" "$harness" "${status_verb:-none}" "${step:-none}" "$ci_detail" "$NOW" "$action" >> "$tmp/alerts"
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
