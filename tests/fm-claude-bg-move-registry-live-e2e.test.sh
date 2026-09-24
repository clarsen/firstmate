#!/usr/bin/env bash
# tests/fm-claude-bg-move-registry-live-e2e.test.sh - default-on drift guard for
# the Claude Code session-registry proof behind a session-lock takeover by a
# conversation moved to the background (fm_session_lock_moved_to_self in
# bin/fm-session-lock-lib.sh).
#
# That proof reads records the harness vendor writes and may reshape in any
# release: <config>/sessions/<pid>.json with its pid, sessionId, kind, jobId,
# parkedJobId, and procStart in the exact `LC_ALL=C TZ=UTC ps -o lstart=` form.
# A stubbed registry can only confirm the shape transcribed into the stub, so
# this guard reads the REAL records of every live Claude Code process on this
# host through the library's own readers, and proves every live parked
# conversation against its live background job. A reshaped record fails here
# naming the installed version instead of silently leaving a moved session
# read-only.
#
# It is read-only and launches nothing, so it spends no model tokens. It needs at
# least one live Claude Code session on the host to check anything, and says so
# rather than passing when there is none. A parked pair exists only after a real
# /background, so run this guard after moving a session to the background and
# after every Claude Code upgrade to cover the move pair itself.
# tests/fm-session-lock-ancestry.test.sh pins the proof's logic portably.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_BG_MOVE_LIVE claude jq

# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

VERSION=$(claude --version 2>/dev/null | head -n 1)
[ -n "$VERSION" ] || fail "claude --version printed nothing"
REGISTRY=$(fm_claude_session_registry_dir) || fail "no Claude Code config directory could be resolved"
[ -d "$REGISTRY" ] || fail "Claude $VERSION has no session registry at $REGISTRY"

# Pass 1: every record whose file names a live Claude-shaped process. A record
# counts only when its procStart is that process's start time, because a file
# left by an earlier process under a reused pid is not this contract; if every
# candidate mismatches, the start-time form itself has drifted.
candidates=0
pids=() ids=() kinds=() jobs=()
for file in "$REGISTRY"/*.json; do
  [ -f "$file" ] && [ ! -L "$file" ] || continue
  pid=$(basename "$file" .json)
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  kill -0 "$pid" 2>/dev/null || continue
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" && [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || continue
  candidates=$((candidates + 1))
  id=$(jq -r 'if type == "object" and (.sessionId | type) == "string" then .sessionId else empty end' "$file" 2>/dev/null)
  [ -n "$id" ] || continue
  kind=$(_fm_claude_registry_field "$pid" "$id" kind) || continue
  job=
  if [ "$kind" = bg ]; then
    job=$(_fm_claude_registry_field "$pid" "$id" jobId) \
      || fail "Claude $VERSION background process $pid records no jobId, so no moved conversation can prove its job"
  fi
  pids+=("$pid") ids+=("$id") kinds+=("$kind") jobs+=("$job")
done

if [ "$candidates" -eq 0 ]; then
  printf 'skip: live: no running Claude Code session is registered in %s to check\n' "$REGISTRY"
  exit 0
fi
[ "${#pids[@]}" -gt 0 ] \
  || fail "Claude $VERSION: none of $candidates live session record(s) binds its pid, sessionId, kind, and procStart the way the move proof reads them"

# Pass 2: every live parked front-end whose job still runs must prove the move.
background=0 proved=0
for i in "${!pids[@]}"; do
  [ "${kinds[$i]}" = bg ] && background=$((background + 1))
  parked=$(_fm_claude_registry_field "${pids[$i]}" "${ids[$i]}" parkedJobId) || continue
  for j in "${!pids[@]}"; do
    [ "${kinds[$j]}" = bg ] && [ "${jobs[$j]}" = "$parked" ] || continue
    fm_claude_session_moved "${pids[$i]}" "${ids[$i]}" "${pids[$j]}" "${ids[$j]}" \
      || fail "Claude $VERSION: pid ${pids[$i]} parked its conversation in live job $parked (pid ${pids[$j]}) but the move proof refused it: $FM_SESSION_LOCK_MOVE_UNPROVEN"
    proved=$((proved + 1))
  done
done

note=
[ "$proved" -gt 0 ] || note='; no live parked conversation on this host, so run again after a /background to cover the move pair'
printf 'ok - Claude %s: %s live session record(s) carry the registry contract, %s background job(s), %s parked conversation(s) proved moved into their live job%s\n' \
  "$VERSION" "${#pids[@]}" "$background" "$proved" "$note"
