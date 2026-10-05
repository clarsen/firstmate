#!/usr/bin/env bash
# bin/fm-claude-usage-record.sh - Claude Code `statusLine` command injected
# only into a slot-injected Claude worker launch (config/claude-accounts;
# bin/fm-spawn.sh sets FM_CLAUDE_ACCOUNT_SLOT to the plain slot name, never
# the token, for exactly that launch).
#
# Claude Code invokes a statusLine command on every status-line refresh,
# feeding it the documented status-line JSON on stdin and using its stdout as
# the rendered line (https://code.claude.com/docs/en/statusline). That JSON
# carries `rate_limits.five_hour` / `.seven_day`, each with
# `used_percentage` and `resets_at` (epoch seconds), sourced from the same
# response headers every model request already returns - a setup-token
# worker therefore gets a per-account reading at no extra quota cost. This
# script records that reading into
# <shared-state>/.claude-account-usage-<slot> (bin/fm-claude-account-lib.sh's
# fm_claude_account_usage_write/_room own the atomic write and the selection
# read), and refreshes the slot's limited mark with the real reset time
# (`fm-claude-account.sh mark-limited --until <resets_at>`) when a window
# reports 100% used with a reset still ahead, rather than firstmate guessing a
# five-hour default. Several workers can share one slot, each seeing only its
# own last response, so each window is merged with the slot's stored reading:
# within one window generation (same resets_at) usage only rises, so a lower
# incoming used_percentage never replaces a higher stored one, while a new
# generation (different resets_at) replaces it outright.
#
# Never fails the worker: every exit is 0, and every step is best-effort. It
# stores no session content and no token, and it never reads or prints one;
# FM_CLAUDE_ACCOUNT_SLOT is the only credential-adjacent input, and it is a
# bare slot name, not a secret.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-claude-account-lib.sh
. "$SCRIPT_DIR/fm-claude-account-lib.sh"

SLOT="${FM_CLAUDE_ACCOUNT_SLOT:-}"
STATUSLINE="firstmate"

if [ -n "$SLOT" ] && fm_claude_account_slot_name_valid "$SLOT"; then
  STATUSLINE="firstmate:$SLOT"
  INPUT=$(cat 2>/dev/null) || INPUT=
  if [ -n "$INPUT" ]; then
    RECORD=$(printf '%s' "$INPUT" | jq -c --argjson now "$(date +%s)" '
      {
        five_hour: {
          used_percentage: (.rate_limits.five_hour.used_percentage // null),
          resets_at: (.rate_limits.five_hour.resets_at // null)
        },
        seven_day: {
          used_percentage: (.rate_limits.seven_day.used_percentage // null),
          resets_at: (.rate_limits.seven_day.resets_at // null)
        },
        observed_at: $now
      }
    ' 2>/dev/null) || RECORD=
    if [ -n "$RECORD" ] && printf '%s' "$RECORD" | jq -e '
      (.five_hour.used_percentage != null) or (.seven_day.used_percentage != null)
    ' >/dev/null 2>&1; then
      STATE_DIR=$(fm_claude_account_state_dir "$FM_HOME" "$STATE" 2>/dev/null) || STATE_DIR=
      if [ -n "$STATE_DIR" ]; then
        EXISTING=$(jq -c 'objects' "$(fm_claude_account_usage_file "$STATE_DIR" "$SLOT")" 2>/dev/null) || EXISTING=
        [ -n "$EXISTING" ] || EXISTING=null
        RECORD=$(printf '%s' "$RECORD" | jq -c --argjson old "$EXISTING" '
          def merge($o; $n):
            if $n.used_percentage == null then ($o // $n)
            elif ($o != null) and ($o.resets_at == $n.resets_at)
              and (($o.used_percentage // -1) > $n.used_percentage) then $o
            else $n
            end;
          .five_hour = merge($old.five_hour; .five_hour)
          | .seven_day = merge($old.seven_day; .seven_day)
        ' 2>/dev/null) || RECORD=
      fi
      if [ -n "$STATE_DIR" ] && [ -n "$RECORD" ]; then
        fm_claude_account_usage_write "$STATE_DIR" "$SLOT" "$RECORD" 2>/dev/null || true
        SATURATED_UNTIL=$(printf '%s' "$RECORD" | jq -r --argjson now "$(date +%s)" '
          [.five_hour, .seven_day]
          | map(select((.used_percentage // 0) >= 100 and (.resets_at != null) and (.resets_at > $now)))
          | map(.resets_at)
          | max // empty
        ' 2>/dev/null)
        case "$SATURATED_UNTIL" in
          '' | *[!0-9.]*) : ;;
          *)
            UNTIL_ISO=$(jq -nr --argjson e "$SATURATED_UNTIL" '$e | floor | todateiso8601' 2>/dev/null) || UNTIL_ISO=
            if [ -n "$UNTIL_ISO" ]; then
              "$SCRIPT_DIR/fm-claude-account.sh" mark-limited "$SLOT" --until "$UNTIL_ISO" >/dev/null 2>&1 || true
            fi
            ;;
        esac
      fi
    fi
  fi
fi

printf '%s\n' "$STATUSLINE"
exit 0
