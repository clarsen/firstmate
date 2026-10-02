# shellcheck shell=bash
# Claude account switching: pick which configured config/claude-accounts slot
# a Claude launch should use, by measured remaining quota-axi allowance.
# Sourced by bin/fm-spawn.sh only when HARNESS=claude, so an unconfigured or
# non-Claude spawn never pays quota-axi's network cost.
#
# config/claude-accounts (absent means the feature is off, today's ambient
# Claude Code login unchanged) lists one Keychain slot name per line (blank
# lines and # comments allowed); bin/fm-claude-account.sh owns slot storage
# and retrieval. fm_claude_account_select measures each configured slot's
# remaining allowance with `CLAUDE_CODE_OAUTH_TOKEN=<token> quota-axi
# --provider claude --json` (the env-token credential source quota-axi
# documents as preferred and never Keychain-delegated), reading the
# all_models scope's effectivePercentRemaining, and prints the slot with the
# most remaining allowance. A token is held only in a local shell variable
# for the duration of one measurement and is never printed, logged, or
# written to any file.
#
# When no slot can be measured (quota-axi missing, every reading unusable),
# selection falls back to the last slot that WAS successfully measured,
# durably recorded at state/.claude-account-last-good, and finally to the
# first configured slot. This mirrors AGENTS.md section 4's dispatch
# philosophy: disclosed measurement uncertainty keeps a candidate eligible
# rather than blocking the launch.
#
# fm_claude_account_select <config-dir> <state-dir> <claude-account-bin>
# Prints the chosen slot name on stdout, or an empty line when the feature is
# off (config/claude-accounts absent or empty). Returns non-zero only for a
# malformed config/claude-accounts file.

FM_CLAUDE_ACCOUNT_LAST_GOOD_REL=".claude-account-last-good"

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

fm_claude_account_select() {
  local config_dir=$1 state_dir=$2 bin=$3
  local slots slot token pct best_slot='' best_pct=-1 measured_any=0 last_good last_good_file tmp
  slots=$(fm_claude_account_configured_slots "$config_dir") || return 1
  if [ -z "$slots" ]; then
    printf '\n'
    return 0
  fi
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    token=$("$bin" get "$slot" 2>/dev/null) || { token=; continue; }
    [ -n "$token" ] || continue
    pct=$(fm_claude_account_measure "$token") || { token=; continue; }
    token=
    measured_any=1
    if [ "$pct" -gt "$best_pct" ]; then
      best_pct=$pct
      best_slot=$slot
    fi
  done <<EOF
$slots
EOF
  last_good_file="$state_dir/$FM_CLAUDE_ACCOUNT_LAST_GOOD_REL"
  if [ "$measured_any" = 1 ] && [ -n "$best_slot" ]; then
    tmp="$last_good_file.tmp.$$"
    if printf '%s\n' "$best_slot" >"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$last_good_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    fi
    printf '%s\n' "$best_slot"
    return 0
  fi
  last_good=$(cat "$last_good_file" 2>/dev/null || true)
  last_good=$(printf '%s' "$last_good" | tr -d '[:space:]')
  if [ -n "$last_good" ]; then
    while IFS= read -r slot; do
      if [ "$slot" = "$last_good" ]; then
        printf '%s\n' "$slot"
        return 0
      fi
    done <<EOF
$slots
EOF
  fi
  printf '%s\n' "$slots" | head -n1
}
