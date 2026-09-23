#!/usr/bin/env bash
# Live validation of config/project-setup/<project>.sh against a real Herdr lab
# session, real treehouse pool worktrees, and a scratch copy of the real
# clarsen/taskbase repo, using the operator's exact bmad setup commands.
set -u
ROOT=/Users/clarsen/.no-mistakes/worktrees/bf7f38e6f6d2/01M36E07187GAE99XBGW38PPTX
EV=/Users/clarsen/.no-mistakes/evidence/01M36E07187GAE99XBGW38PPTX
LAB="$ROOT/bin/fm-herdr-lab.sh"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export FM_GATE_REFUSE_BYPASS=1
SESSION=$("$LAB" name setuphook)
export HERDR_SESSION="$SESSION"
TMP_ROOT=$(mktemp -d "$(cd /Users/clarsen/Tmp && pwd -P)/fm-setup-live.XXXXXX")
export TREEHOUSE_ROOT="$TMP_ROOT/treehouse-pool"
WTS=()
say() { printf '\n===== %s =====\n' "$*"; }
cleanup() {
  say "cleanup"
  local w
  for w in "${WTS[@]}"; do [ -n "$w" ] && treehouse return --force "$w" >/dev/null 2>&1 && echo "returned $w"; done
  "$LAB" teardown "$SESSION" && echo "lab $SESSION torn down"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

say "provision lab $SESSION"
"$LAB" provision "$SESSION" || exit 1

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
brief() { mkdir -p "$HOME_DIR/data/$1"; printf '# Task\n## Captain'"'"'s intent\nLive setup hook check.\n\n## Firstmate spec\nNothing.\n' > "$HOME_DIR/data/$1/brief.md"; }

say "scratch taskbase project (local bare mirror of github clarsen/taskbase)"
git clone --quiet --bare https://github.com/clarsen/taskbase.git "$TMP_ROOT/taskbase.origin.git" || exit 1
git clone --quiet "file://$TMP_ROOT/taskbase.origin.git" "$TMP_ROOT/taskbase" || exit 1
git -C "$TMP_ROOT/taskbase" log --oneline -1
mkdir -p "$TMP_ROOT/otherproj"; git -C "$TMP_ROOT/otherproj" init -q -b main
echo x > "$TMP_ROOT/otherproj/README.md"; git -C "$TMP_ROOT/otherproj" add README.md
git -C "$TMP_ROOT/otherproj" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone --quiet --bare "$TMP_ROOT/otherproj" "$TMP_ROOT/otherproj.origin.git"
git -C "$TMP_ROOT/otherproj" remote add origin "file://$TMP_ROOT/otherproj.origin.git"

install_hook() { mkdir -p "$HOME_DIR/config/project-setup"; printf '#!/usr/bin/env bash\n%s\n' "$1" > "$HOME_DIR/config/project-setup/taskbase.sh"; chmod 0755 "$HOME_DIR/config/project-setup/taskbase.sh"; }
# The operator's exact commands, made safe to re-run on a reused pool slot.
TASKBASE_HOOK='set -euo pipefail
echo "hook: FM_TASK_ID=$FM_TASK_ID FM_TASK_KIND=$FM_TASK_KIND FM_PROJECT=$FM_PROJECT cwd=$(pwd)"
[ -d bmad-submodule/.git ] || git clone https://github.com/clarsen/bmad-submodule.git
(cd bmad-submodule; git checkout ctlarsen-v6.12.1-2026-09-10)
bmad-submodule/install.sh'
AGENT="$TMP_ROOT/agent.sh"
cat > "$AGENT" <<'EOF'
echo "AGENT-START cwd=$(pwd)"
echo "AGENT bmad-submodule checkout: $(git -C bmad-submodule rev-parse --abbrev-ref HEAD) @ $(git -C bmad-submodule rev-parse --short HEAD)"
echo "AGENT .agents -> $(readlink .agents)"
echo "AGENT _bmad entries: $(ls _bmad | tr '\n' ' ')"
echo "AGENT git-status-lines: $(git status --porcelain | wc -l | tr -d ' ')"
echo AGENT-END
sleep 900
EOF

spawn() { # <id> <project> [args...]
  local id=$1 proj=$2; shift 2
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "bash $AGENT" --backend herdr "$@" 2>&1
}
panes() { herdr pane list --session "$SESSION" 2>/dev/null | jq -r '[.result.panes[]?] | length'; }
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
capture() { fm_backend_herdr_capture "$SESSION:$1" 40; }
meta_val() { grep "^$2=" "$HOME_DIR/state/$1.meta" 2>/dev/null | cut -d= -f2-; }
wt_from_err() { printf '%s\n' "$1" | sed -n 's/.* in \(\/[^ ;:]*\).*/\1/p' | head -1; }

say "S1 ship spawn of taskbase runs the real bmad setup before launch"
brief tb-ship1
install_hook "$TASKBASE_HOOK"
out=$(spawn tb-ship1 "$TMP_ROOT/taskbase" --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out"; echo "exit=$rc"
WT1=$(meta_val tb-ship1 worktree); WTS+=("$WT1"); P1=$(meta_val tb-ship1 herdr_pane_id)
echo "meta worktree=$WT1 pane=$P1"
sleep 3
echo "--- agent pane capture ---"; capture "$P1" | grep AGENT
echo "--- worktree git status (expect empty) ---"; git -C "$WT1" status --porcelain; echo "[end status]"

say "S2 teardown of the set-up ship task is not blocked by setup output"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  "$ROOT/bin/fm-teardown.sh" tb-ship1 2>&1 | tail -8; echo "teardown exit=${PIPESTATUS[0]}"
[ -f "$HOME_DIR/state/tb-ship1.meta" ] && echo "meta still present" || echo "meta removed"

say "S3 scout spawn reuses the pooled slot; hook is idempotent over its earlier output"
brief tb-scout1
out=$(spawn tb-scout1 "$TMP_ROOT/taskbase" --scout); rc=$?
printf '%s\n' "$out"; echo "exit=$rc"
WT2=$(meta_val tb-scout1 worktree); WTS+=("$WT2"); P2=$(meta_val tb-scout1 herdr_pane_id)
echo "meta worktree=$WT2 (same slot as S1: $([ "$WT2" = "$WT1" ] && echo yes || echo no)) pane=$P2"
sleep 3; capture "$P2" | grep AGENT

say "S4 failing hook refuses the launch and publishes no task"
brief tb-fail1
install_hook 'echo "clone failed (simulated)" >&2; exit 7'
before=$(panes)
out=$(spawn tb-fail1 "$TMP_ROOT/taskbase" --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out"; echo "exit=$rc"
w=$(wt_from_err "$out"); WTS+=("$w"); echo "left worktree for inspection: $w"
[ -f "$HOME_DIR/state/tb-fail1.meta" ] && echo "meta PRESENT (bad)" || echo "no task meta published"
echo "panes before=$before after=$(panes)"

say "S5 hook exceeding FM_PROJECT_SETUP_TIMEOUT refuses the launch"
brief tb-hang1
install_hook 'echo "hanging"; sleep 120'
start=$(date +%s)
out=$(FM_PROJECT_SETUP_TIMEOUT=3 spawn tb-hang1 "$TMP_ROOT/taskbase" --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out"; echo "exit=$rc elapsed=$(( $(date +%s) - start ))s"
w=$(wt_from_err "$out"); WTS+=("$w")
[ -f "$HOME_DIR/state/tb-hang1.meta" ] && echo "meta PRESENT (bad)" || echo "no task meta published"

say "S6 hook leaving git-visible output refuses the launch"
brief tb-dirty1
install_hook 'echo junk > setup-junk.txt'
out=$(spawn tb-dirty1 "$TMP_ROOT/taskbase" --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out"; echo "exit=$rc"
w=$(wt_from_err "$out"); WTS+=("$w")
[ -n "$w" ] && rm -f "$w/setup-junk.txt"
[ -f "$HOME_DIR/state/tb-dirty1.meta" ] && echo "meta PRESENT (bad)" || echo "no task meta published"

say "S7 non-executable hook refuses before any pane or worktree exists"
brief tb-noexec1
install_hook 'echo should-not-run'; chmod 0644 "$HOME_DIR/config/project-setup/taskbase.sh"
before=$(panes)
out=$(spawn tb-noexec1 "$TMP_ROOT/taskbase" --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out"; echo "exit=$rc panes before=$before after=$(panes)"

say "S8 bad FM_PROJECT_SETUP_TIMEOUT refuses before any pane"
install_hook 'echo should-not-run'
before=$(panes)
out=$(FM_PROJECT_SETUP_TIMEOUT=0 spawn tb-noexec1 "$TMP_ROOT/taskbase" --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out"; echo "exit=$rc panes before=$before after=$(panes)"

say "S9 project without a setup script spawns unchanged"
brief other1
out=$(spawn other1 "$TMP_ROOT/otherproj" --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out"; echo "exit=$rc"
WTS+=("$(meta_val other1 worktree)")
printf '%s\n' "$out" | grep -q "project setup" && echo "mentions project setup (bad)" || echo "no project setup activity"
