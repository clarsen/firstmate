# shellcheck shell=bash
# Claude account switching: pick which configured config/claude-accounts slot
# a Claude launch should use. Sourced by bin/fm-spawn.sh only when
# HARNESS=claude, and by bin/fm-claude-account.sh for the shared slot and
# limited-mark helpers.
#
# config/claude-accounts (absent means the feature is off, today's ambient
# Claude Code login unchanged) lists one Keychain slot name per line (blank
# lines and # comments allowed); bin/fm-claude-account.sh owns slot storage
# and retrieval.
#
# Selection is reactive. A setup token (`claude setup-token`) is
# inference-only, so quota-axi's usage endpoint always refuses it (403,
# scope `user:profile`); no live quota-axi call is ever made with a slot's
# token, which also means selection can never be fed another account's
# reading through quota-axi's env-then-stored fallback (the misattribution
# hazard a live call would otherwise carry).
# The primary signal is a per-slot "limited" mark,
# <shared-state>/.claude-account-limited-<slot>, holding only an ISO-8601 UTC
# until-timestamp. A usage limit belongs to the account, so <shared-state>
# (fm_claude_account_state_dir, via bin/fm-wake-lib.sh's
# fm_firstmate_root_home) is the local primary home's state/, shared by every
# home in that local tree. Marks are written by `bin/fm-claude-account.sh
# mark-limited` (by firstmate reactively, or by bin/fm-claude-usage-record.sh
# automatically once a reading shows a window at 100% used) and removed by
# `clear-limited`.
# The secondary signal is each slot's recorded usage reading,
# <shared-state>/.claude-account-usage-<slot>, written only by
# bin/fm-claude-usage-record.sh (the Claude worker statusLine recorder; see
# its header) from the documented `rate_limits.five_hour`/`.seven_day`
# `used_percentage`/`resets_at` status-line fields a running worker already
# receives at no extra quota cost. A window whose `resets_at` has passed
# counts as reset (0% used) rather than stale. fm_claude_account_select:
#   1. skips every slot whose mark exists and has not yet expired;
#   2. among the remaining slots, prefers the one whose recorded reading
#      shows the most room (100 minus the higher of its two current window
#      used-percentages; a slot with no reading yet counts as full room, with
#      file order breaking ties), and otherwise takes the first eligible slot
#      in file order - a slot whose reading cannot be parsed is still
#      eligible, a slot whose reading shows a window fully used (100%, no
#      room) is used only when no other readable unmarked slot remains, and
#      a slot whose token cannot be read by `fm-claude-account.sh get` (a
#      local Keychain read only, no network call) is used only when nothing
#      readable is;
#   3. when every slot is marked limited, takes the one whose mark expires
#      soonest and explains that choice on stderr.
# A token is held only in a local shell variable for the duration of one
# readability check and is never printed, logged, or written to any file.
#
# fm_claude_account_select <config-dir> <home> <own-state-dir> <claude-account-bin>
# Resolves the shared limited-mark directory (fm_claude_account_state_dir)
# only once config/claude-accounts names at least one slot.
# Prints the chosen slot name on stdout, or an empty line when the feature is
# off (config/claude-accounts absent or empty). Returns non-zero only for a
# malformed config/claude-accounts file.

FM_CLAUDE_ACCOUNT_LIMITED_PREFIX=".claude-account-limited-"
FM_CLAUDE_ACCOUNT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_claude_account_slot_name_valid() {
  case "$1" in
    '') return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  case "$1" in
    [A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print configured slot names, one per line, in file order, deduplicated.
# Empty output (exit 0) when the file is absent or empty.
fm_claude_account_configured_slots() {
  local config_dir=$1 file=$1/claude-accounts line slot seen=$'\n'
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    slot=${line#"${line%%[![:space:]]*}"}
    slot=${slot%"${slot##*[![:space:]]}"}
    case "$slot" in ''|'#'*) continue ;; esac
    if ! fm_claude_account_slot_name_valid "$slot"; then
      echo "error: config/claude-accounts holds an invalid slot name '$slot'; use letters, digits, '-', '_' only, starting with a letter or digit" >&2
      return 1
    fi
    case "$seen" in *$'\n'"$slot"$'\n'*) continue ;; esac
    seen="$seen$slot"$'\n'
    printf '%s\n' "$slot"
  done <"$file"
}

FM_CLAUDE_ACCOUNT_USAGE_PREFIX=".claude-account-usage-"

fm_claude_account_usage_file() {  # <state-dir> <slot>
  printf '%s/%s%s' "$1" "$FM_CLAUDE_ACCOUNT_USAGE_PREFIX" "$2"
}

# Atomically write a slot's usage reading. <json> must already be the
# complete record object (bin/fm-claude-usage-record.sh builds it); this
# function only owns the atomic write, shared with fm_claude_account_usage_room's
# read side.
fm_claude_account_usage_write() {  # <state-dir> <slot> <json>
  local state_dir=$1 slot=$2 json=$3 file tmp
  mkdir -p "$state_dir" || return 1
  file=$(fm_claude_account_usage_file "$state_dir" "$slot")
  tmp="$file.tmp.$$"
  if ! { printf '%s\n' "$json" >"$tmp" && mv -f "$tmp" "$file"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# jq definitions shared by every reader of a usage reading (selection here and
# bin/fm-claude-account.sh status), so both apply one reset rule: a window is
# current only while it has a used_percentage and a resets_at still ahead of
# $now; any other window counts as reset (0% used) rather than stale.
# shellcheck disable=SC2016  # jq program text; $now and $w are jq variables.
FM_CLAUDE_ACCOUNT_USAGE_JQ_DEFS='
  def window_current($w):
    $w != null and ($w.used_percentage // null) != null
    and ($w.resets_at // null) != null and $w.resets_at > $now;
  def window_used($w): if window_current($w) then $w.used_percentage else 0 end;
'

# Print 100 minus the binding (higher-used) window's used_percentage from a
# slot's recorded usage reading, clamped to 0, floored to a whole number. A
# slot with no recorded reading yet prints full room (100), optimistically,
# until its first worker records a real one. Nothing with a non-zero exit when
# a recorded reading cannot be parsed - callers treat that as an unknown, not
# a zero.
fm_claude_account_usage_room() {  # <state-dir> <slot> <now-epoch>
  local state_dir=$1 slot=$2 now=$3 file room
  file=$(fm_claude_account_usage_file "$state_dir" "$slot")
  if [ ! -f "$file" ]; then
    printf '100\n'
    return 0
  fi
  room=$(jq -r --argjson now "$now" "$FM_CLAUDE_ACCOUNT_USAGE_JQ_DEFS"'
    ([window_used(.five_hour), window_used(.seven_day)] | max) as $used
    | ([0, (100 - $used)] | max) | floor
  ' "$file" 2>/dev/null) || return 1
  case "$room" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$room"
}

# Print the limited-mark directory shared by every home in this home's local
# tree: the root home's state/ when the home is a secondmate, else <own-state>.
# An unresolvable parent binding falls back to <own-state> with a stderr note.
fm_claude_account_state_dir() {  # <home> <own-state>
  local home=$1 own_state=$2 root self
  if ! command -v fm_firstmate_root_home >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_CLAUDE_ACCOUNT_LIB_DIR/fm-wake-lib.sh"
  fi
  if ! root=$(fm_firstmate_root_home "$home"); then
    echo "note: could not resolve the primary home above $home; Claude account limited marks stay local to $own_state" >&2
    printf '%s\n' "$own_state"
    return 0
  fi
  self=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P)
  if [ "$root" = "$self" ]; then
    printf '%s\n' "$own_state"
  else
    printf '%s/state\n' "$root"
  fi
}

fm_claude_account_limited_file() {  # <state-dir> <slot>
  printf '%s/%s%s' "$1" "$FM_CLAUDE_ACCOUNT_LIMITED_PREFIX" "$2"
}

# Print a slot's limited-mark expiry as epoch seconds, or nothing with a
# non-zero exit when the slot carries no readable mark.
fm_claude_account_limited_until() {  # <state-dir> <slot>
  local file until epoch
  file=$(fm_claude_account_limited_file "$1" "$2")
  [ -f "$file" ] || return 1
  until=$(tr -d '[:space:]' <"$file" 2>/dev/null)
  epoch=$(jq -nr --arg u "$until" '$u | fromdateiso8601' 2>/dev/null)
  case "$epoch" in
    '' | *[!0-9]*)
      echo "warning: ignoring unreadable Claude account limited mark $file" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$epoch"
}

fm_claude_account_select() {
  local config_dir=$1 home=$2 own_state=$3 bin=$4
  local state_dir slots slot token room now until
  local best_slot='' best_room=-1 first_eligible='' exhausted_slot='' unreadable_slot='' soonest_slot='' soonest_until=''
  slots=$(fm_claude_account_configured_slots "$config_dir") || return 1
  if [ -z "$slots" ]; then
    printf '\n'
    return 0
  fi
  state_dir=$(fm_claude_account_state_dir "$home" "$own_state")
  now=$(date +%s)
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    if until=$(fm_claude_account_limited_until "$state_dir" "$slot") && [ "$until" -gt "$now" ]; then
      if [ -z "$soonest_slot" ] || [ "$until" -lt "$soonest_until" ]; then
        soonest_slot=$slot
        soonest_until=$until
      fi
      continue
    fi
    token=$("$bin" get "$slot" 2>/dev/null) || token=
    if [ -z "$token" ]; then
      [ -n "$unreadable_slot" ] || unreadable_slot=$slot
      continue
    fi
    token=
    room=$(fm_claude_account_usage_room "$state_dir" "$slot" "$now") || room=
    if [ "$room" = 0 ]; then
      [ -n "$exhausted_slot" ] || exhausted_slot=$slot
      continue
    fi
    [ -n "$first_eligible" ] || first_eligible=$slot
    [ -n "$room" ] || continue
    if [ "$room" -gt "$best_room" ]; then
      best_room=$room
      best_slot=$slot
    fi
  done <<EOF
$slots
EOF
  if [ -n "$best_slot" ]; then
    printf '%s\n' "$best_slot"
  elif [ -n "$first_eligible" ]; then
    printf '%s\n' "$first_eligible"
  elif [ -n "$exhausted_slot" ]; then
    printf '%s\n' "$exhausted_slot"
  elif [ -n "$unreadable_slot" ]; then
    printf '%s\n' "$unreadable_slot"
  else
    echo "note: every configured Claude account slot is marked limited; launching on '$soonest_slot', whose mark expires soonest ($(jq -nr --argjson e "$soonest_until" '$e | todateiso8601'))" >&2
    printf '%s\n' "$soonest_slot"
  fi
}
