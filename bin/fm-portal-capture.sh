#!/usr/bin/env bash
# Capture Claude's captain-facing Stop message for the Lavish portal.
# Usage: fm-portal-capture.sh hook | prune
# The presence of config/portal-capture enables capture only in a lock-owning
# primary home. Hook and prune always exit 0 and print nothing. Errors go to
# state/portal-capture.log as fm-portal-capture.sh:<line>: <message>.
# Sidecar schema 1 contains the full message, parsed final-line trailer, and
# enforcement:"off". A repeated (session_id,prompt_id,content_hash) is one turn.
# FM_PORTAL_SIDECAR_KEEP_DAYS defaults to 30; the watcher runs prune on its
# crew-ledger cadence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SIDECARS="$STATE/portal-sidecars"
LOG="$STATE/portal-capture.log"

log_error() { printf 'fm-portal-capture.sh:%s: %s\n' "$1" "$2" >> "$LOG" 2>/dev/null || true; }

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d ' ' -f 1
  else return 1
  fi
}

prune() {
  local days=${FM_PORTAL_SIDECAR_KEEP_DAYS:-30}
  [ -d "$SIDECARS" ] || return 0
  case "$days" in ''|*[!0-9]*|0) log_error "$LINENO" "invalid FM_PORTAL_SIDECAR_KEEP_DAYS"; return 0 ;; esac
  find "$SIDECARS" -maxdepth 1 -type f -name '*.json' -mtime "+$((days - 1))" -exec rm -f -- {} + 2>/dev/null ||
    log_error "$LINENO" "sidecar pruning failed"
}

hook() {
  local payload parsed session prompt hash key stamp name tmp existing
  [ -e "$CONFIG/portal-capture" ] || return 0
  [ -d "$STATE" ] || return 0
  [ ! -e "$FM_ROOT/.fm-secondmate-home" ] && [ ! -e "$FM_HOME/.fm-secondmate-home" ] || return 0
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  payload=$(cat 2>/dev/null) || { log_error "$LINENO" "cannot read Stop payload"; return 0; }
  [ -n "$payload" ] || { log_error "$LINENO" "empty Stop payload"; return 0; }
  command -v jq >/dev/null 2>&1 || { log_error "$LINENO" "jq unavailable"; return 0; }
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  fm_hook_payload_is_foreign_host "$payload" && return 0
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$STATE" || return 0
  parsed=$(printf '%s' "$payload" | jq -ce '
    if type != "object" then error("payload is not an object") else
      {session_id:(.session_id // ""),prompt_id:(.prompt_id // .generation_id // ""),
       cwd:(.cwd // ""),message_text:(.last_assistant_message // null)}
      | if (.session_id|type) != "string" or (.prompt_id|type) != "string" or
           (.cwd|type) != "string" or (.message_text != null and (.message_text|type) != "string")
        then error("invalid Stop fields") else . end
    end' 2>/dev/null) || { log_error "$LINENO" "invalid JSON Stop payload"; return 0; }
  jq -e '.message_text != null and .message_text != ""' <<< "$parsed" >/dev/null || {
    [ "$(jq -r '.message_text == null' <<< "$parsed")" != true ] || log_error "$LINENO" "Stop payload missing last_assistant_message"
    return 0
  }
  session=$(jq -r '.session_id' <<< "$parsed")
  prompt=$(jq -r '.prompt_id' <<< "$parsed")
  hash=$(jq -j '.message_text' <<< "$parsed" | sha256_text) || { log_error "$LINENO" "sha256 unavailable"; return 0; }
  [[ $hash =~ ^[0-9a-f]{64}$ ]] || { log_error "$LINENO" "sha256 failed"; return 0; }
  key=$(printf '%s\0%s\0%s' "$session" "$prompt" "$hash" | sha256_text) || { log_error "$LINENO" "sha256 unavailable"; return 0; }
  [[ $key =~ ^[0-9a-f]{64}$ ]] || { log_error "$LINENO" "sha256 failed"; return 0; }
  if ! mkdir -p "$SIDECARS" 2>/dev/null; then log_error "$LINENO" "cannot create sidecar directory"; return 0; fi
  # The stable suffix makes repeat delivery idempotent across seconds.
  for existing in "$SIDECARS"/*-"${key:0:16}".json; do
    [ ! -f "$existing" ] || return 0
  done
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  name="$stamp-$(printf '%s' "$session" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-64)-${key:0:16}.json"
  tmp=$(umask 077; mktemp "$SIDECARS/.capture.XXXXXX" 2>/dev/null) || { log_error "$LINENO" "cannot create temporary sidecar"; return 0; }
  if ! jq -cn --argjson input "$parsed" --arg hash "$hash" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      ($input.message_text) as $text
      | ($text | split("\n") | map(select(test("\\S"))) | last // "") as $last
      | ([$last | capture("^PORTAL:\\s+(?<kind>none|page=(?<pages>[A-Za-z0-9_-]+(?:,[A-Za-z0-9_-]+)*))(?:\\s+task=(?<tasks>[A-Za-z0-9._-]+(?:,[A-Za-z0-9._-]+)*))?\\s*$")][0] // null) as $trailer
      | ($text == "Captain, shipshape.") as $shipshape
      | (if $shipshape then "valid" elif $trailer != null then "valid"
         elif ($last | startswith("PORTAL:")) then "malformed" else "missing" end) as $status
      | (if $shipshape or $trailer.kind == "none" then "none"
         elif $trailer != null then "page" else null end) as $kind
      | (if $shipshape then 0 elif $trailer != null then
           ($text | sub("[^\\n]*PORTAL:[^\\n]*\\s*$"; "") | length)
         else ($text | length) end) as $outside
      | {schema:1,session_id:$input.session_id,prompt_id:$input.prompt_id,
         timestamp:$timestamp,cwd:$input.cwd,hook_version:"1",
         trailer_status:$status,trailer_kind:$kind,
         page_ids:(if $kind == "page" then ($trailer.pages | split(",")) else [] end),
         task_ids:(if $trailer.tasks != null then ($trailer.tasks | split(",")) else [] end),
         message_text:$text,text_outside_trailer_chars:$outside,
         content_hash:("sha256:" + $hash),enforcement:"off"}' > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    rm -f -- "$tmp" 2>/dev/null
    log_error "$LINENO" "sidecar serialization failed"
    return 0
  fi
  if ! mv -- "$tmp" "$SIDECARS/$name" 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null
    log_error "$LINENO" "sidecar rename failed"
  fi
}

case "${1:-}" in
  hook) hook >/dev/null ;;
  prune) prune >/dev/null ;;
esac
exit 0
