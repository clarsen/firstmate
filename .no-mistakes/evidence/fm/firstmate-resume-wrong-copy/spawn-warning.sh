#!/usr/bin/env bash
# Real bin/fm-spawn.sh herdr spawns in a guarded fm-lab-* session; shows the
# spawn-time resume-safety warning (unsafe config) and its absence (safe config).
set -u
export FM_GATE_REFUSE_BYPASS=1  # same sandbox-only hatch tests/herdr-test-safety.sh exports; scratch FM_HOME + fm-lab session only
ROOT=$1
LAB="$ROOT/bin/fm-herdr-lab.sh"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
T=$(mktemp -d "$(cd /tmp && pwd -P)/fmsw.XXXX")
S=$("$LAB" name spawnwarn); export HERDR_SESSION="$S"
WTS=()
cleanup() {
  for w in "${WTS[@]}"; do treehouse return --force "$w" >/dev/null 2>&1; done
  "$LAB" teardown "$S" >/dev/null 2>&1; echo "teardown $S rc=$?"; rm -rf "$T"
}
trap cleanup EXIT
"$LAB" prepare "$S" || exit 1
echo "lab session: $S"
SM="$T/sm-home"; mkdir -p "$SM/state" "$SM/config" "$SM/projects" "$SM/bin"
printf 'off\n' > "$SM/config/herdr-presentation-spaces"
printf '# placeholder\n' > "$SM/AGENTS.md"; printf 'smx\n' > "$SM/.fm-secondmate-home"; printf 'charter\n' > "$SM/data-charter"
mkproj() { mkdir -p "$1"; git -C "$1" init -q; echo x > "$1/README.md"; git -C "$1" add README.md; git -C "$1" -c user.name=t -c user.email=t@e.invalid commit -qm i; git clone -q --bare "$1" "$1.origin.git"; git -C "$1" remote add origin "file://$1.origin.git"; }
spawn() { # <id> <config-path> <label>
  local id=$1 cfg=$2 proj="$SM/projects/p-$1"
  mkproj "$proj"; mkdir -p "$SM/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nprobe\n\n## Firstmate spec\nprobe\n' > "$SM/data/$id/brief.md"
  echo "----- $3"
  echo "\$ FM_HOME=<secondmate-home> FM_BACKEND_HERDR_CONFIG_PATH_OVERRIDE=$cfg bin/fm-spawn.sh $id <secondmate-home>/projects/p-$id ... --backend herdr"
  FM_SPAWN_NO_GUARD=1 FM_HOME="$SM" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND_HERDR_CONFIG_PATH_OVERRIDE="$cfg" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo $id-launched; sleep 600'" --mode no-mistakes --yolo off --backend herdr \
    >"$T/$id.out" 2>"$T/$id.err"
  echo "exit=$?"; echo "stderr tail:"; tail -5 "$T/$id.err" | sed "s/^/    /"
  echo "stderr resume lines:"; grep -n -A3 'resume_agents_on_restore' "$T/$id.err" || echo "  (none)"
  local wt pane; wt=$(grep '^worktree=' "$SM/state/$id.meta" 2>/dev/null | cut -d= -f2-); pane=$(grep '^herdr_pane_id=' "$SM/state/$id.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WTS+=("$wt")
  echo "meta: worktree=$wt herdr_pane_id=$pane"
  sleep 1
  echo "pane output: $("$LAB" run "$S" pane read "$pane" 2>/dev/null | jq -r '.result.text? // .result.read.text? // empty' 2>/dev/null | grep -m1 "$id-launched" || "$LAB" run "$S" pane read "$pane" 2>&1 | grep -o "$id-launched" | head -1)"
  echo "config file exists after spawn? $([ -e "$cfg" ] && echo yes || echo no)"
}
spawn rw1 "$T/herdr-unset/config.toml" "unsafe: Herdr config.toml absent (Herdr default resume=true)"
mkdir -p "$T/herdr-safe"; printf '[session]\nresume_agents_on_restore = false\n' > "$T/herdr-safe/config.toml"; before=$(cksum < "$T/herdr-safe/config.toml")
spawn rw2 "$T/herdr-safe/config.toml" "safe: resume_agents_on_restore = false"
[ "$before" = "$(cksum < "$T/herdr-safe/config.toml")" ] && echo "safe config unchanged by spawn: yes"
