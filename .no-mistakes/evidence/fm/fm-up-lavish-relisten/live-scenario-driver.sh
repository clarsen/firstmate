#!/usr/bin/env bash
# usage: scenario.sh <bin-dir> <label> <port>
set -u
BIN=$1; LABEL=$2; PORT=$3
T=$(mktemp -d /tmp/fmlv-$LABEL.XXXXXX)
export LAVISH_AXI_STATE_DIR="$T/lavish-state" LAVISH_AXI_NO_OPEN=1 LAVISH_AXI_PORT=$PORT LAVISH_AXI_TELEMETRY=0
export FM_PROCEVENT_CLAIM_ROOT="$T/claims" FM_HOME="$T/home"
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p "$LAVISH_AXI_STATE_DIR" "$FM_HOME/state" "$T/art"
ts(){ date +%H:%M:%S.%N | cut -c1-12; }
log(){ echo "[$(ts)] [$LABEL] $*"; }
ART="$T/art/board.html"; printf '<h1>relisten board</h1>\n' > "$ART"
open_out=$(lavish-axi "$ART" 2>&1); log "lavish-axi open: $(echo "$open_out" | tr '\n' ' ' | cut -c1-200)"
URL=$(echo "$open_out" | grep -oE 'http://[^ "]+/session/[0-9a-f]+' | head -1); log "session url: $URL"
ID=$("$BIN/fm-procevent-lavish.sh" source-id "$ART"); log "source id: $ID"
# headless chrome attaches to the board and exits on its own after 10s (= browser disconnect)
timeout 10 google-chrome --headless=new --no-first-run --no-default-browser-check --disable-gpu --user-data-dir="$T/chrome" "$URL" >/dev/null 2>&1 &
log "headless chrome attached for 10s"; sleep 3
log "arm: $("$BIN/fm-procevent-lavish.sh" arm "$ART" 2>&1 | tr '\n' ' ')"
log "claim file: $(tr '\n' ' ' < "$FM_PROCEVENT_CLAIM_ROOT/$ID.claim" 2>/dev/null | cut -c1-200)"
nres(){ ls "$FM_HOME"/state/procevent-inbox/ 2>/dev/null | grep -c "\.result$"; }
npoll(){ pgrep -f "lavish-axi poll $T" | wc -l; }
for i in $(seq 1 40); do
  sleep 1
  log "t+${i}s results=$(nres) wakes=$(wc -l < "$FM_HOME/state/.wake-queue" 2>/dev/null || echo 0) claim=$([ -e "$FM_PROCEVENT_CLAIM_ROOT/$ID.claim" ] && echo present || echo absent) lavish_polls_running=$(npoll)"
done
log "captured results:"; for f in "$FM_HOME"/state/procevent-inbox/*.result; do [ -e "$f" ] && { echo "--- $(basename "$f")"; cat "$f"; }; done
log "wake queue: $(cat "$FM_HOME/state/.wake-queue" 2>/dev/null)"
log "second arm: $("$BIN/fm-procevent-lavish.sh" arm "$ART" 2>&1 | tr '\n' ' ')"
sleep 2
log "after second arm lavish_polls_running=$(npoll) results=$(nres)"
"$BIN/fm-procevent.sh" sweep-home >/dev/null 2>&1; log "sweep-home rc=$?"
lavish-axi end "$ART" >/dev/null 2>&1; lavish-axi stop >/dev/null 2>&1
sleep 1; log "leftover lavish polls=$(npoll)"
echo "TMPDIR=$T"
