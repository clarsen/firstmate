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
# state/.claude-account-limited-<slot>, holding only an ISO-8601 UTC
# until-timestamp, written by `bin/fm-claude-account.sh mark-limited` and
# removed by `clear-limited`. fm_claude_account_select:
#   1. skips every slot whose mark exists and has not yet expired;
#   2. among the remaining slots, prefers the one with the most remaining
#      allowance when quota-axi can measure it (`CLAUDE_CODE_OAUTH_TOKEN=<token>
#      quota-axi --provider claude --json --no-credential-refresh`, never an
#      inference probe), and otherwise takes the first eligible slot in file
#      order - a slot with no reading is still eligible;
#   3. when every slot is marked limited, takes the one whose mark expires
#      soonest and explains that choice on stderr.
# A token is held only in a local shell variable for the duration of one
# measurement and is never printed, logged, or written to any file.
#
# fm_claude_account_select <config-dir> <state-dir> <claude-account-bin>
# Prints the chosen slot name on stdout, or an empty line when the feature is
# off (config/claude-accounts absent or empty). Returns non-zero only for a
# malformed config/claude-accounts file.

FM_CLAUDE_ACCOUNT_LIMITED_PREFIX=".claude-account-limited-"

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
  local config_dir=$1 state_dir=$2 bin=$3
  local slots slot token pct now until
  local best_slot='' best_pct=-1 first_eligible='' soonest_slot='' soonest_until=''
  slots=$(fm_claude_account_configured_slots "$config_dir") || return 1
  if [ -z "$slots" ]; then
    printf '\n'
    return 0
  fi
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
    [ -n "$first_eligible" ] || first_eligible=$slot
    token=$("$bin" get "$slot" 2>/dev/null) || { token=; continue; }
    [ -n "$token" ] || continue
    pct=$(fm_claude_account_measure "$token") || { token=; continue; }
    token=
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
  else
    echo "note: every configured Claude account slot is marked limited; launching on '$soonest_slot', whose mark expires soonest ($(jq -nr --argjson e "$soonest_until" '$e | todateiso8601'))" >&2
    printf '%s\n' "$soonest_slot"
  fi
}
