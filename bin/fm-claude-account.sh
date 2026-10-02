#!/usr/bin/env bash
# Manage named Claude setup-token credentials in the macOS login Keychain, for
# config/claude-accounts switching across two or more subscription-plan Claude
# accounts (docs/configuration.md "Claude account switching").
#
# Usage: fm-claude-account.sh add <slot>
#        fm-claude-account.sh remove <slot>
#        fm-claude-account.sh list
#        fm-claude-account.sh get <slot>
#
#   add     Prompt (hidden input, read from stdin) for a Claude Code setup
#           token (from `claude setup-token`, used as CLAUDE_CODE_OAUTH_TOKEN)
#           and store it under this slot's Keychain item, replacing any
#           existing value. The token is never accepted as a command-line
#           argument and is never echoed back.
#   remove  Delete the slot's Keychain item. Missing is not an error.
#   list    Print each slot named in config/claude-accounts (or passed as
#           arguments) with "present" or "missing", never a token value.
#   get     Print the slot's raw token to stdout and nothing else. Intended
#           for capture by a caller (`$(fm-claude-account.sh get <slot>)`),
#           never for a human to read on screen. A missing or unreadable slot
#           is a plain, loud failure naming the slot only.
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
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_CLAUDE_ACCOUNT_SERVICE_PREFIX="firstmate-claude-account-"

fm_claude_account_slot_valid() {
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

fm_claude_account_service() {
  printf '%s%s' "$FM_CLAUDE_ACCOUNT_SERVICE_PREFIX" "$1"
}

fm_claude_account_configured_slots() {
  local file=$CONFIG/claude-accounts line slot
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    slot=${line#"${line%%[![:space:]]*}"}
    slot=${slot%"${slot##*[![:space:]]}"}
    case "$slot" in ''|'#'*) continue ;; esac
    printf '%s\n' "$slot"
  done <"$file"
}

cmd_add() {
  local slot=$1 account token
  fm_claude_account_slot_valid "$slot" || {
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
    '' | *[[:space:]]*)
      token=
      echo "error: the token must be a single non-empty line with no whitespace" >&2
      return 1
      ;;
  esac
  if ! security add-generic-password -a "$account" -s "$(fm_claude_account_service "$slot")" -w "$token" -U -A >/dev/null 2>&1; then
    token=
    echo "error: could not store the token for slot '$slot' in the Keychain" >&2
    return 1
  fi
  token=
  echo "stored slot '$slot'"
}

cmd_remove() {
  local slot=$1 account
  fm_claude_account_slot_valid "$slot" || {
    echo "error: '$slot' is not a valid slot name" >&2
    return 1
  }
  account=$(id -un 2>/dev/null) || account=${USER:-}
  security delete-generic-password -a "$account" -s "$(fm_claude_account_service "$slot")" >/dev/null 2>&1 || true
  echo "removed slot '$slot' (if it existed)"
}

cmd_get() {
  local slot=$1 account token
  fm_claude_account_slot_valid "$slot" || {
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
    slots=$(fm_claude_account_configured_slots)
  fi
  [ -n "$slots" ] || {
    echo "no slots configured (config/claude-accounts is absent or empty)"
    return 0
  }
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    if ! fm_claude_account_slot_valid "$slot"; then
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
  list)
    shift
    cmd_list "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
