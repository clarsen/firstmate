#!/usr/bin/env bash
# Manage named Claude setup-token credentials in the macOS login Keychain, for
# config/claude-accounts switching across two or more subscription-plan Claude
# accounts (docs/configuration.md "Claude account switching").
#
# Usage: fm-claude-account.sh add <slot>
#        fm-claude-account.sh remove <slot>
#        fm-claude-account.sh list
#        fm-claude-account.sh get <slot>
#        fm-claude-account.sh mark-limited <slot> [--until <iso8601>]
#        fm-claude-account.sh clear-limited <slot>
#        fm-claude-account.sh status [<slot>...]
#
#   add     Prompt (hidden input, read from stdin) for a Claude Code setup
#           token (from `claude setup-token`, used as CLAUDE_CODE_OAUTH_TOKEN)
#           and store it under this slot's Keychain item, replacing any
#           existing value. The token is never accepted as a command-line
#           argument, is handed to `security -i` on stdin rather than in any
#           process's argv, and is never echoed back.
#   remove  Delete the slot's Keychain item. Missing is not an error.
#   list    Print each slot named in config/claude-accounts (or passed as
#           arguments) with "present" or "missing", never a token value.
#   get     Print the slot's raw token to stdout and nothing else. Intended
#           for capture by a caller (`$(fm-claude-account.sh get <slot>)`),
#           never for a human to read on screen. A missing or unreadable slot
#           is a plain, loud failure naming the slot only.
#   mark-limited
#           Record that the slot has hit a Claude usage limit, so launch
#           selection skips it until <iso8601> (UTC, YYYY-MM-DDTHH:MM:SSZ;
#           default now + 5 hours). Writes only that timestamp to
#           .claude-account-limited-<slot> in the local primary home's
#           state/ (shared by every home in its tree), one file per slot.
#   clear-limited
#           Remove the slot's limited mark. Missing is not an error.
#   status  Print, for each slot named in config/claude-accounts (or passed
#           as arguments), its limited mark (if any) and its last recorded
#           usage reading - the one bin/fm-claude-usage-record.sh's statusLine
#           capture writes - with that reading's age. Names, percentages, and
#           times only, never a token value. A quota-array-dispatch intake
#           uses this as the claude candidate's quota evidence when
#           config/claude-accounts is configured, because the plain
#           `quota-axi` row then describes the ambient login, not these
#           per-slot accounts (docs/configuration.md "Claude account
#           switching").
#
# Each slot is one macOS Keychain generic-password item, service
# "firstmate-claude-account-<slot>", account the current OS user, added with
# `-A` so any process running as this user can read it back without a
# per-run Keychain prompt - the same same-user trust boundary every other
# locally stored credential in this repo already relies on (see
# docs/configuration.md "Worker launch environment"). This is a distinct
# Keychain service from Claude Code's own session item, so it never collides
# with, overwrites, or is read by ordinary `claude` or `quota-axi` Keychain
# discovery.
# A slot name is a bare identifier: letters, digits, '-', '_', starting with a
# letter or digit.
#
# `security` is resolved from PATH (stubbed in tests); this script never
# prints, logs, or writes a token value anywhere except `get`'s single-line
# stdout.
set -u

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-claude-account-lib.sh
. "$SCRIPT_DIR/fm-claude-account-lib.sh"

FM_CLAUDE_ACCOUNT_SERVICE_PREFIX="firstmate-claude-account-"

fm_claude_account_service() {
  printf '%s%s' "$FM_CLAUDE_ACCOUNT_SERVICE_PREFIX" "$1"
}

cmd_add() {
  local slot=$1 account token service stored
  fm_claude_account_slot_name_valid "$slot" || {
    echo "error: '$slot' is not a valid slot name; use letters, digits, '-', '_' only, starting with a letter or digit" >&2
    return 1
  }
  account=$(id -un 2>/dev/null) || account=${USER:-}
  [ -n "$account" ] || {
    echo "error: could not determine the current OS user to scope the Keychain item" >&2
    return 1
  }
  # shellcheck disable=SC2016 # Backtick is literal prompt text, not expansion.
  printf 'Claude setup token for slot %s (hidden, from `claude setup-token`): ' "$slot" >&2
  if ! IFS= read -rs token; then
    printf '\n' >&2
    echo "error: could not read a token from stdin" >&2
    return 1
  fi
  printf '\n' >&2
  case "$token" in
    '' | *[!A-Za-z0-9._~+/=-]*)
      token=
      echo "error: the token must be a single non-empty line of letters, digits, and . _ ~ + / = - only" >&2
      return 1
      ;;
  esac
  service=$(fm_claude_account_service "$slot")
  printf 'add-generic-password -a "%s" -s "%s" -w "%s" -U -A\n' "$account" "$service" "$token" | security -i >/dev/null 2>&1
  stored=$(security find-generic-password -a "$account" -s "$service" -w 2>/dev/null)
  if [ "$stored" != "$token" ]; then
    token=
    stored=
    echo "error: could not store the token for slot '$slot' in the Keychain" >&2
    return 1
  fi
  token=
  stored=
  echo "stored slot '$slot'"
}

cmd_remove() {
  local slot=$1 account
  fm_claude_account_slot_name_valid "$slot" || {
    echo "error: '$slot' is not a valid slot name" >&2
    return 1
  }
  account=$(id -un 2>/dev/null) || account=${USER:-}
  security delete-generic-password -a "$account" -s "$(fm_claude_account_service "$slot")" >/dev/null 2>&1 || true
  echo "removed slot '$slot' (if it existed)"
}

cmd_get() {
  local slot=$1 account token
  fm_claude_account_slot_name_valid "$slot" || {
    echo "error: '$slot' is not a valid slot name" >&2
    return 1
  }
  account=$(id -un 2>/dev/null) || account=${USER:-}
  [ -n "$account" ] || {
    echo "error: could not determine the current OS user to scope the Keychain item" >&2
    return 1
  }
  token=$(security find-generic-password -a "$account" -s "$(fm_claude_account_service "$slot")" -w 2>/dev/null)
  if [ -z "$token" ]; then
    echo "error: no stored Claude credential for slot '$slot' (or it could not be read)" >&2
    return 1
  fi
  printf '%s' "$token"
  token=
}

cmd_list() {
  local account slot slots=""
  account=$(id -un 2>/dev/null) || account=${USER:-}
  if [ "$#" -gt 0 ]; then
    slots=$(printf '%s\n' "$@")
  else
    slots=$(fm_claude_account_configured_slots "$CONFIG") || return 1
  fi
  [ -n "$slots" ] || {
    echo "no slots configured (config/claude-accounts is absent or empty)"
    return 0
  }
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    if ! fm_claude_account_slot_name_valid "$slot"; then
      printf '%s: invalid slot name\n' "$slot"
      continue
    fi
    if security find-generic-password -a "$account" -s "$(fm_claude_account_service "$slot")" >/dev/null 2>&1; then
      printf '%s: present\n' "$slot"
    else
      printf '%s: missing\n' "$slot"
    fi
  done <<EOF
$slots
EOF
}

cmd_mark_limited() {
  local slot=$1 until=${2:-} state file tmp
  fm_claude_account_slot_name_valid "$slot" || {
    echo "error: '$slot' is not a valid slot name" >&2
    return 1
  }
  if [ -n "$until" ]; then
    until=$(jq -nr --arg u "$until" '$u | fromdateiso8601 | todateiso8601' 2>/dev/null) || until=
    [ -n "$until" ] || {
      echo "error: --until must be a UTC ISO-8601 timestamp like 2026-01-02T15:04:05Z" >&2
      return 1
    }
  else
    until=$(jq -nr 'now + 5 * 3600 | floor | todateiso8601')
  fi
  state=$(fm_claude_account_state_dir "$FM_HOME" "$STATE")
  mkdir -p "$state" || return 1
  file=$(fm_claude_account_limited_file "$state" "$slot")
  tmp="$file.tmp.$$"
  if ! { printf '%s\n' "$until" >"$tmp" && mv -f "$tmp" "$file"; }; then
    rm -f "$tmp"
    echo "error: could not write the limited mark for slot '$slot'" >&2
    return 1
  fi
  echo "marked slot '$slot' limited until $until"
}

cmd_clear_limited() {
  local slot=$1
  fm_claude_account_slot_name_valid "$slot" || {
    echo "error: '$slot' is not a valid slot name" >&2
    return 1
  }
  rm -f "$(fm_claude_account_limited_file "$(fm_claude_account_state_dir "$FM_HOME" "$STATE")" "$slot")" || return 1
  echo "cleared limited mark for slot '$slot' (if it existed)"
}

cmd_status() {
  local state slots slot now until mark reading file
  state=$(fm_claude_account_state_dir "$FM_HOME" "$STATE")
  if [ "$#" -gt 0 ]; then
    slots=$(printf '%s\n' "$@")
  else
    slots=$(fm_claude_account_configured_slots "$CONFIG") || return 1
  fi
  [ -n "$slots" ] || {
    echo "no slots configured (config/claude-accounts is absent or empty)"
    return 0
  }
  now=$(date +%s)
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    if ! fm_claude_account_slot_name_valid "$slot"; then
      printf '%s: invalid slot name\n' "$slot"
      continue
    fi
    if until=$(fm_claude_account_limited_until "$state" "$slot"); then
      if [ "$until" -gt "$now" ]; then
        mark="limited until $(jq -nr --argjson e "$until" '$e | todateiso8601')"
      else
        mark="limited mark expired"
      fi
    else
      mark="no limited mark"
    fi
    file=$(fm_claude_account_usage_file "$state" "$slot")
    if [ -f "$file" ]; then
      reading=$(jq -r --argjson now "$now" '
        "5h=\(.five_hour.used_percentage // "?")% 7d=\(.seven_day.used_percentage // "?")% (observed \($now - (.observed_at // $now))s ago)"
      ' "$file" 2>/dev/null) || reading="reading unreadable"
    else
      reading="no recorded reading"
    fi
    printf '%s: %s; %s\n' "$slot" "$mark" "$reading"
  done <<EOF
$slots
EOF
}

case "${1:-}" in
  -h | --help | '')
    usage
    exit 0
    ;;
  add)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    cmd_add "$2"
    ;;
  remove)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    cmd_remove "$2"
    ;;
  get)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    cmd_get "$2"
    ;;
  mark-limited)
    if [ "$#" -eq 2 ]; then
      cmd_mark_limited "$2"
    elif [ "$#" -eq 4 ] && [ "$3" = --until ]; then
      cmd_mark_limited "$2" "$4"
    else
      usage >&2
      exit 2
    fi
    ;;
  clear-limited)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    cmd_clear_limited "$2"
    ;;
  list)
    shift
    cmd_list "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
