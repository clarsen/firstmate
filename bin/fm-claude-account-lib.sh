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
# inference-only, so quota-axi usually cannot read its remaining allowance.
# The primary signal is instead a per-slot "limited" mark,
# <shared-state>/.claude-account-limited-<slot>, holding only an ISO-8601 UTC
# until-timestamp. A usage limit belongs to the account, so <shared-state>
# (fm_claude_account_state_dir, via bin/fm-wake-lib.sh's
# fm_firstmate_root_home) is the local primary home's state/, shared by every
# home in that local tree. Marks are written by `bin/fm-claude-account.sh
# mark-limited` and removed by `clear-limited`. fm_claude_account_select:
#   1. skips every slot whose mark exists and has not yet expired;
#   2. among the remaining slots, prefers the one with the most remaining
#      allowance (above 0%) when quota-axi can measure it (`CLAUDE_CODE_OAUTH_TOKEN=<token>
#      quota-axi --provider claude --json --no-credential-refresh`, never an
#      inference probe), and otherwise takes the first eligible slot in file
#      order - a slot with no reading is still eligible, a slot measured at
#      0% is used only when no other readable unmarked slot remains, and a
#      slot whose token cannot be read is used only when nothing readable is;
#   3. when every slot is marked limited, takes the one whose mark expires
#      soonest and explains that choice on stderr.
# A token is held only in a local shell variable for the duration of one
# measurement and is never printed, logged, or written to any file.
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

# Print the all_models scope's effectivePercentRemaining for a token, or
# nothing with a non-zero exit when quota-axi cannot measure it.
fm_claude_account_measure() {
  local token=$1 json pct
  command -v quota-axi >/dev/null 2>&1 || return 1
  json=$(CLAUDE_CODE_OAUTH_TOKEN="$token" quota-axi --provider claude --json --no-credential-refresh 2>/dev/null) || return 1
  pct=$(printf '%s' "$json" | jq -r '
    ((.providers // []) | map(select(.provider=="claude")) | .[0].quotaSemantics.effectiveAvailability // [])
    | map(select(.scope=="all_models"))
    | .[0].effectivePercentRemaining // empty
  ' 2>/dev/null) || return 1
  case "$pct" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pct"
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
  local state_dir slots slot token pct now until
  local best_slot='' best_pct=0 first_eligible='' exhausted_slot='' unreadable_slot='' soonest_slot='' soonest_until=''
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
    pct=$(fm_claude_account_measure "$token") || pct=
    token=
    if [ "$pct" = 0 ]; then
      [ -n "$exhausted_slot" ] || exhausted_slot=$slot
      continue
    fi
    [ -n "$first_eligible" ] || first_eligible=$slot
    [ -n "$pct" ] || continue
    if [ "$pct" -gt "$best_pct" ]; then
      best_pct=$pct
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
