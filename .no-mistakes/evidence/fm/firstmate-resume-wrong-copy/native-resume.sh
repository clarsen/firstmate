#!/usr/bin/env bash
# Live Herdr native-resume reproduction in a guarded fm-lab-* session.
# usage: native-resume.sh <repo-root> <label> <config-mode: default|false>
set -u
ROOT=$1; LABEL=$2; MODE=$3
LAB="$ROOT/bin/fm-herdr-lab.sh"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
SCR=$(mktemp -d "$(cd /tmp && pwd -P)/fmnr.XXXX")
mkdir -p "$SCR/bin" "$SCR/home/projects/proj" "$SCR/worktrees/task-wt"
cat > "$SCR/bin/fm-fake-resume" <<EOS
#!/bin/sh
printf 'native-resume ran: pwd=%s args=%s\n' "\$PWD" "\$*" >> "$SCR/resume.log"
exec sleep 600
EOS
chmod +x "$SCR/bin/fm-fake-resume"
CFG="$SCR/herdr-config.toml"
if [ "$MODE" = false ]; then printf '[session]\nresume_agents_on_restore = false\n' > "$CFG"; else printf '# herdr defaults\n' > "$CFG"; fi
export HERDR_CONFIG_PATH="$CFG" PATH="$SCR/bin:$PATH"
S=$("$LAB" name "$LABEL")
echo "lab session: $S   config($MODE): $(tr '\n' ' ' < "$CFG")"
cleanup() { "$LAB" teardown "$S" >/dev/null 2>&1; echo "teardown rc=$?"; rm -rf "$SCR"; }
trap cleanup EXIT
"$LAB" provision "$S" || { echo "provision failed"; exit 1; }
WS=$("$LAB" run "$S" workspace create --cwd "$SCR/home/projects/proj" --label resume-probe --no-focus)
PANE=$(printf '%s' "$WS" | jq -r '.. | objects | .pane_id? // empty' | head -1)
echo "pane $PANE created with cwd=$SCR/home/projects/proj (the project clone)"
"$LAB" run "$S" pane run "$PANE" "sh -c 'cd $SCR/worktrees/task-wt && exec sh'" >/dev/null
sleep 1
"$LAB" run "$S" pane report-agent --source fm-test --agent claude --state idle --agent-session-id sess-123 "$PANE" -- fm-fake-resume --resume sess-123 >/dev/null || echo "report-agent failed"
sleep 1
echo "pane before restart: $("$LAB" run "$S" pane get "$PANE" | jq -c '.result.pane | {cwd, foreground_cwd, agent}')"
"$LAB" stop "$S" >/dev/null || { echo "stop failed"; exit 1; }
sleep 1
"$LAB" provision "$S" || { echo "re-provision failed"; exit 1; }
sleep 6
echo "pane after restart: $("$LAB" run "$S" pane get "$PANE" 2>&1 | jq -c '.result.pane | {cwd, foreground_cwd, agent}' 2>&1)"
if [ -s "$SCR/resume.log" ]; then echo "RESULT: herdr natively resumed the agent -> $(cat "$SCR/resume.log")"; else echo "RESULT: no native resume ran"; fi
