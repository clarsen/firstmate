#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# Refuses when bin/fm-dod-lib.sh will not accept the named head as reachable
# outside the worker's disposable copy; in no-mistakes mode a forge-reported
# head is that named head and is already stored on the forge.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# A GitHub pull request the forge reports as a draft is refused, naming the draft
# state and recording and arming nothing: a draft cannot be merged, so a poll armed on it
# would wait for an event that cannot occur while nobody is asked to act.
# Mark the pull request ready for review, then arm again; a lane that keeps a
# draft on purpose declares a wait instead of reporting done. An unreadable
# draft state does not refuse, matching how the head read below is optional.
# bin/fm-pr-merge.sh records through this script with FM_PR_CHECK_MERGE=1 and
# skips this refusal, because its own merge-time draft refusal is authoritative.
# A task with edit members (bin/fm-task-members-lib.sh owns that delivery
# model) ships one PR per repository. Here the PR's repository is resolved by
# remote - the task's own or one edit member's; a PR matching no repository of
# the task, or several, refuses - and its copy, clone, and delivery mode stand in for the
# task's own in the head read, the named-head gate, and the ready line. The PR
# is also recorded for its repository (member.<name>.pr= and .pr_head=, or
# anchor_pr= and anchor_pr_head= for the task's own), while pr= and pr_head=
# name the PR currently in delivery, which the merge poll watches. Moving pr=
# to another repository's PR refuses until the PR it names has merged -
# recorded by its merge outcome - or the forge reports it closed unmerged, so
# delivery stays one repository at a time and no open PR loses its poll. A PR
# the forge reports merged whose merge outcome has not been recorded yet also
# refuses: register again once that merge notification arrives.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-task-members-lib.sh
. "$SCRIPT_DIR/fm-task-members-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# A task with edit members: resolve the PR's repository (header above) and
# refuse to move pr= off a PR that is still in delivery.
REPO_PR_KEY=
REPO_NAME=
if fm_member_has_edit "$META"; then
  if ! fm_member_resolve_pr_repo "$META" "$HOST" "$PROJECT_PATH"; then
    echo "error: $URL: $FM_MEMBER_ERROR" >&2
    exit 1
  fi
  REPO_NAME=$FM_MEMBER_MATCH_NAME
  if [ -n "$REPO_NAME" ]; then
    REPO_PR_KEY="member.$REPO_NAME.pr"
  else
    REPO_PR_KEY=anchor_pr
  fi
  MATCH_WORKTREE=$FM_MEMBER_MATCH_WORKTREE
  MATCH_PROJECT=$FM_MEMBER_MATCH_PROJECT
  MATCH_MODE=$FM_MEMBER_MATCH_MODE
  MATCH_YOLO=$FM_MEMBER_MATCH_YOLO
  CURRENT_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -n "$CURRENT_URL" ] && [ "$CURRENT_URL" != "$URL" ] && fm_pr_url_parse "$CURRENT_URL"; then
    CURRENT_PROVIDER=$FM_PR_PROVIDER
    CURRENT_HOST=$FM_PR_HOST
    CURRENT_PATH=$FM_PR_PATH
    CURRENT_OWNER=$FM_PR_OWNER
    CURRENT_REPO=$FM_PR_REPO
    CURRENT_NUMBER=$FM_PR_NUMBER
    CURRENT_NAME='<none>'
    if fm_member_resolve_pr_repo "$META" "$CURRENT_HOST" "$CURRENT_PATH"; then
      CURRENT_NAME=$FM_MEMBER_MATCH_NAME
    fi
    if [ "$CURRENT_NAME" != "$REPO_NAME" ] \
      && ! fm_pr_poll_merge_already_notified "$STATE" "$ID" \
        "$CURRENT_PROVIDER" "$CURRENT_HOST" "$CURRENT_PATH" "$CURRENT_NUMBER"; then
      CURRENT_READ=0
      case "$CURRENT_PROVIDER" in
        github) fm_pr_github_read_record "$CURRENT_OWNER" "$CURRENT_REPO" "$CURRENT_NUMBER" && CURRENT_READ=1 ;;
        gitlab) fm_pr_gitlab_read_record "$CURRENT_HOST" "$CURRENT_PATH" "$CURRENT_NUMBER" && CURRENT_READ=1 ;;
      esac
      if [ "$CURRENT_READ" = 1 ] && [ "$FM_PR_RECORD_MERGED" = false ]; then
        case "$FM_PR_RECORD_STATE" in
          CLOSED | closed) CURRENT_READ=closed ;;
        esac
      fi
      case "$CURRENT_READ" in
        closed) ;;
        1)
          if [ "$FM_PR_RECORD_MERGED" = true ]; then
            echo "error: task $ID's current PR $CURRENT_URL has merged, but its merge outcome is not recorded yet; register $URL again once that merge notification arrives" >&2
          else
            echo "error: task $ID's current PR $CURRENT_URL (another repository of the task) is still open; repositories deliver one at a time, so register $URL once that PR has merged or closed" >&2
          fi
          exit 1
          ;;
        *)
          echo "error: could not read whether task $ID's current PR $CURRENT_URL (another repository of the task) has merged or closed; refusing to move delivery to $URL" >&2
          exit 1
          ;;
      esac
    fi
  fi
fi

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# The draft state is read before anything is recorded or armed. Only a positive
# draft reading refuses, because an unreadable one must not block arming.
if [ "$PROVIDER" = github ] && [ "${FM_PR_CHECK_MERGE:-}" != 1 ] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  DRAFT_JSON=$(gh pr view "$URL" --json isDraft 2>/dev/null || true)
  if [ "$(fm_pr_json_draft_state "$DRAFT_JSON")" = true ]; then
    echo "error: $URL is a draft pull request; a draft cannot be merged, so merge monitoring would wait for an event that cannot occur - mark it ready for review and arm again, or declare a wait instead of done if the draft is deliberate" >&2
    exit 1
  fi
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$REPO_PR_KEY" ] || WT=$MATCH_WORKTREE
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -n "$REPO_PR_KEY" ]; then
  MODE=$MATCH_MODE
  YOLO=$MATCH_YOLO
  PROJECT=$MATCH_PROJECT
fi
case "$MODE" in
  no-mistakes|'') DONE_LINE="done: PR $URL checks green" ;;
  *) DONE_LINE="done: PR $URL" ;;
esac
if { [ -z "$PR_HEAD" ] || ! fm_dod_forge_head_is_named_head "$MODE"; } \
  && ! GATE_REASON=$(fm_dod_accept_ship_done "${KIND:-ship}" "$MODE" "$WT" "$PROJECT" "$DONE_LINE" "$STATE" "$ID" "$META"); then
  echo "error: $GATE_REASON" >&2
  exit 1
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
PR_POLL_PUBLISH_LOCK=
PR_POLL_PUBLISH_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$PR_POLL_PUBLISH_LOCK_HELD" = 1 ]; then
    fm_lock_release "$PR_POLL_PUBLISH_LOCK" || true
    PR_POLL_PUBLISH_LOCK_HELD=0
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *)
      if [ -n "$REPO_PR_KEY" ]; then
        case "$line" in
          "$REPO_PR_KEY="*|"${REPO_PR_KEY}_head="*) continue ;;
        esac
      fi
      printf '%s\n' "$line" >> "$META_TMP" || exit 1
      ;;
  esac
done < "$META"
# The PR's own repository record precedes pr=, after which
# fm_pr_metadata_identity_parse accepts only pr_head= and Relay lines.
if [ -n "$REPO_PR_KEY" ]; then
  printf '%s=%s\n' "$REPO_PR_KEY" "$URL" >> "$META_TMP" || exit 1
  [ -z "$PR_HEAD" ] || printf '%s_head=%s\n' "$REPO_PR_KEY" "$PR_HEAD" >> "$META_TMP" || exit 1
fi
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

PR_POLL_PUBLISH_LOCK="$STATE/.pr-poll-publish-$ID.lock"
fm_lock_acquire_wait "$PR_POLL_PUBLISH_LOCK"
PR_POLL_PUBLISH_LOCK_HELD=1
if fm_pr_poll_publish_prepared; then
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
else
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
  echo "error: could not publish PR poll" >&2
  exit 1
fi
# The contribution observer uses the same authenticated check mechanism and
# owns verdict freshness, required actors and external feedback separately from
# the exact merged-state poll. Registration is local and performs no forge read.
if command -v jq >/dev/null 2>&1; then
  "$SCRIPT_DIR/fm-contributions.sh" arm >/dev/null \
    || printf 'contributions: observation not armed; coverage is unconfirmed\n' >&2
else
  printf 'contributions: jq unavailable; coverage is unconfirmed\n' >&2
fi
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
[ -z "$MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$MODE")"
[ -z "$YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
