#!/usr/bin/env bash
# Mint a disposable firstmate lab home with real tmux panes for five crew members.
set -eu
WT=/home/ctlarsen/.no-mistakes/worktrees/6442e268076a/01M5M02BJCPYBRJ10F0A80A771
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TMUXD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
mkdir -p "$LAB/fakebin" "$LAB/nm"
# Stand-in for the external no-mistakes CLI only (the shared daemon cannot be
# initialized from a gate); serves a TOON run record keyed by the worktree branch.
cat > "$LAB/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); f="$FM_LAB_NM/${br//\//_}"
case "${1:-} ${2:-}" in
  "axi status"|"axi ") [ -f "$f" ] && cat "$f" || { echo "error: repo not initialized (run 'no-mistakes init' first)"; exit 1; } ;;
  "axi logs") : ;;
  "runs "*) : ;;
  "daemon "*) echo 'daemon running (pid 4242)' ;;
esac
SH
chmod +x "$LAB/fakebin/no-mistakes"
# Host tmux next-3.4 aborts its server on every capture-pane ("server exited
# unexpectedly"), so capture-pane alone is answered from each pane's own tee of
# its output; every other tmux call goes to the real lab server.
mkdir -p "$LAB/panes"
REAL_TMUX=$(command -v tmux)
cat > "$LAB/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = capture-pane ]; then
  t=; while [ \$# -gt 0 ]; do [ "\$1" = -t ] && { t=\$2; shift; }; shift; done
  w=\$("$REAL_TMUX" display-message -p -t "\$t" '#W') || exit 1
  cat "$LAB/panes/\$w.log"; exit 0
fi
exec "$REAL_TMUX" "\$@"
SH
chmod +x "$LAB/fakebin/tmux"
now=$(date +%s)
mk() { # id branch pr status_line
  id=$1 br=$2 pr=$3 st=$4
  wt="$LAB/projects/$id"; mkdir -p "$wt"
  git -C "$wt" init -q; git -C "$wt" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b "$br"; git -C "$wt" update-ref refs/remotes/origin/main HEAD
  head=$(git -C "$wt" rev-parse HEAD)
  if [ -n "$pr" ]; then cat > "$LAB/nm/${br//\//_}" <<TOON
run:
  id: "01RUN$id"
  branch: $br
  status: running
  head: "$head"
  pr: "$pr"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
TOON
  fi
  printf 'kind=ship\nharness=claude\nbackend=tmux\nwindow=firstmate:fm-%s\nworktree=%s\nbranch=%s\nspawn_gen=lab1\n' "$id" "$wt" "$br" > "$LAB/state/$id.meta"
  printf '%s\n' "$st" > "$LAB/state/$id.status"
  TMUX_TMPDIR="$TMUXD" tmux new-window -d -t firstmate -n "fm-$id" "printf '● Worked for 13m 58s\n\n> \n' | tee $LAB/panes/fm-$id.log; exec sleep 100000"
}
TMUX_TMPDIR="$TMUXD" tmux new-session -d -s firstmate -n placeholder "exec sleep 100000"
mk bearings-card-nav-fixed fm/bearings-card-nav-fixed https://github.com/clarsen/firstmate/pull/35 \
  "paused [at=$((now-6000))]: CI monitor still running; resume on gate or final CI result"
mk lagmon-uv-cache-guard fm/lagmon-uv-cache-guard https://lsg-git.lbl.gov/lblnet/generate_nagios_cfg/-/merge_requests/12416 \
  "paused [at=$((now-120))]: bounded CI wait elapsed; monitor reattached"
mk committed-idle fm/committed-idle "" "working [at=$((now-60))]: implementation committed"
mk busy-worker fm/busy-worker https://github.com/clarsen/firstmate/pull/35 \
  "paused [at=$((now-6000))]: CI monitor still running; resume on final CI result"
mk done-worker fm/done-worker "" "done [at=$((now-60))]: delivered PR https://github.com/clarsen/firstmate/pull/35"
for id in bearings-card-nav-fixed lagmon-uv-cache-guard committed-idle done-worker; do
  g=$("$WT/bin/fm-busy-event.sh" arm "$LAB/state" $id); "$WT/bin/fm-busy-event.sh" apply "$LAB/state" $id idle --gen "$g" --source claude-hook --event stop
done
"$WT/bin/fm-busy-event.sh" arm "$LAB/state" busy-worker >/dev/null   # launch-brief = busy turn
echo "LAB=$LAB"; echo "TMUXD=$TMUXD"
