#!/usr/bin/env bash
# Live validation driver for config/claude-accounts switching (branch
# fm/claude-account-switch). Drives the REAL bin/fm-spawn.sh against a REAL,
# throwaway, non-default Herdr lab session (bin/fm-herdr-lab.sh contract), a
# REAL treehouse pool rooted in a scratch dir, and REAL pane shells that source
# the generated launch file. Only two things are stand-ins:
#   - `security`: the file-backed Keychain fake from
#     tests/fm-claude-account-fakes.sh (never touches the login Keychain);
#   - `claude`: a probe that records the CLAUDE_CODE_OAUTH_TOKEN /
#     FM_CLAUDE_ACCOUNT_INJECTED it was launched with, then exits.
# Pane shells get those fakes first on PATH via a scratch ZDOTDIR .zshrc
# (macOS path_helper otherwise reorders /usr/bin/security ahead of them).
set -u
ROOT=${1:?usage: $0 <worktree-root> <evidence-dir>}
EV=${2:?usage: $0 <worktree-root> <evidence-dir>}
LOG="$EV/live-claude-account-herdr-lab.log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
PASSES=0; FAILS=0
ok()  { PASSES=$((PASSES+1)); say "PASS - $*"; }
bad() { FAILS=$((FAILS+1)); say "FAIL - $*"; }

# shellcheck source=/dev/null
. "$ROOT/tests/fm-claude-account-fakes.sh"

T=$(mktemp -d /private/tmp/fmca-live.XXXXXX)
FB="$T/fb"; mkdir -p "$FB" "$T/zdot" "$T/claude-cfg" "$T/pool"
PROBE="$T/probe.log"; : > "$PROBE"
QMAP="$T/qmap"; : > "$QMAP"
fm_claude_account_fake_security "$FB" "$T/keychain"
mv "$FB/security" "$FB/security.fake"
# Pane-side failure toggle: when $T/fail-in-pane exists, `security` refuses
# only inside lab panes (FM_LAB_IN_PANE=1 is set in the lab server env only),
# so selection in the spawn process still sees the slot but the pane fetch fails.
cat > "$FB/security" <<SH
#!/bin/sh
if [ "\${FM_LAB_IN_PANE:-}" = 1 ] && [ -e "$T/fail-in-pane" ]; then exit 51; fi
exec "$FB/security.fake" "\$@"
SH
chmod +x "$FB/security"
fm_claude_account_fake_quota_axi "$FB" "$QMAP"
cat > "$FB/claude" <<SH
#!/bin/sh
printf 'pwd=%s token=%s marker=%s\n' "\$(pwd -P)" "\${CLAUDE_CODE_OAUTH_TOKEN-<unset>}" "\${FM_CLAUDE_ACCOUNT_INJECTED-<unset>}" >> "$PROBE"
echo "PROBE-CLAUDE launched token=\${CLAUDE_CODE_OAUTH_TOKEN-<unset>} marker=\${FM_CLAUDE_ACCOUNT_INJECTED-<unset>}"
SH
chmod +x "$FB/claude"
printf 'export PATH=%q:"$PATH"\nPROMPT="lab%% "\n' "$FB" > "$T/zdot/.zshrc"

HELPER="$ROOT/bin/fm-herdr-lab.sh"
S=$("$HELPER" name fmca-live) || { say "could not name lab"; exit 1; }
WTS=()
cleanup() {
  local wt
  for wt in ${WTS[@]+"${WTS[@]}"}; do
    TREEHOUSE_ROOT="$T/pool" treehouse return --force "$wt" >/dev/null 2>&1 || true
  done
  "$HELPER" teardown "$S" >>"$LOG" 2>&1; say "lab teardown exit=$? session=$S"
  rm -rf "$T"
}
trap cleanup EXIT
say "lab session: $S   scratch: $T"
env -u HERDR_PANE_ID -u HERDR_ENV -u HERDR_SOCKET_PATH \
  ZDOTDIR="$T/zdot" TREEHOUSE_ROOT="$T/pool" FM_LAB_IN_PANE=1 \
  CLAUDE_CODE_OAUTH_TOKEN=ambient-operator-tok \
  PATH="$FB:$PATH" "$HELPER" provision "$S" >>"$LOG" 2>&1 || { say "provision failed"; exit 1; }
lab() { "$HELPER" run "$S" "$@"; }

PROJ="$T/project"
mkdir -p "$PROJ"; git -C "$PROJ" init -q; printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

mkhome() {  # <home> <id>...
  local h=$1 id; shift
  mkdir -p "$h/state" "$h/config" "$h/data" "$h/projects"
  printf 'off\n' > "$h/config/herdr-presentation-spaces"
  for id in "$@"; do
    mkdir -p "$h/data/$id"
    printf '# Task\n## Captain%ss intent\nlive claude-account check %s\n\n## Firstmate spec\nnone\n' "'" "$id" > "$h/data/$id/brief.md"
  done
}
acct() { env PATH="$FB:$PATH" FM_HOME="$1" "$ROOT/bin/fm-claude-account.sh" "${@:2}"; }
spawn() {  # <home> <id> [args...]
  local h=$1 id=$2; shift 2
  env -u HERDR_PANE_ID -u HERDR_ENV -u HERDR_SOCKET_PATH -u CLAUDE_CODE_OAUTH_TOKEN \
    HERDR_SESSION="$S" TREEHOUSE_ROOT="$T/pool" CLAUDE_CONFIG_DIR="$T/claude-cfg" \
    PATH="$FB:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$@" >"$T/$id.spawn.out" 2>&1
  local rc=$?
  local wt; wt=$(grep '^worktree=' "$h/state/$id.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WTS+=("$wt")
  say "  spawn $id rc=$rc (stderr tail: $(tail -3 "$T/$id.spawn.out" | tr '\n' ' '))"
  return $rc
}
pane_of() { grep '^herdr_pane_id=' "$1/state/$2.meta" | cut -d= -f2-; }
wait_probe() {  # <count>
  local i; for i in $(seq 1 120); do [ "$(wc -l < "$PROBE")" -ge "$1" ] && return 0; sleep 0.5; done; return 1
}
pane_text() { lab pane read "$1" --source recent --lines 40 --format text 2>/dev/null; }
dump_pane() {  # <label> <pane>
  { echo "----- pane text: $1 ($2) -----"; pane_text "$2" | jq -r '.result.read.text // .result.text // .' 2>/dev/null || pane_text "$2"; echo "-----"; } >> "$LOG"
}

# Real quota-axi check: an injected token is honored (no ambient fallback).
say "== S0 real quota-axi with an injected non-allowance token"
QA=$(CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-lab-bogus /opt/homebrew/bin/quota-axi --provider claude --json --no-credential-refresh 2>&1)
printf '%s\n' "$QA" >> "$LOG"
st=$(printf '%s' "$QA" | jq -r '.providers[0].state.status'); ea=$(printf '%s' "$QA" | jq -r '.providers[0].quotaSemantics.effectiveAvailability | length')
[ "$st" != ok ] && [ "$ea" = 0 ] && ok "S0 real quota-axi with injected token reports status=$st, no effectiveAvailability (no ambient-login reading)" || bad "S0 quota-axi status=$st ea=$ea"

# ---- S1: limited slot skipped; pane claude gets the other slot's token -----
say "== S1 limited slot skipped on spawn"
H1="$T/home1"; mkhome "$H1" ca1
printf 'account-a\naccount-b\n' > "$H1/config/claude-accounts"
printf 'tok-aaa\n' | acct "$H1" add account-a >>"$LOG" 2>&1
printf 'tok-bbb\n' | acct "$H1" add account-b >>"$LOG" 2>&1
acct "$H1" list >>"$LOG" 2>&1
acct "$H1" mark-limited account-a >>"$LOG" 2>&1
spawn "$H1" ca1 "$PROJ" "claude --lab-probe" --backend herdr --mode no-mistakes --yolo off
wait_probe 1 || bad "S1 probe claude never ran"
P1=$(pane_of "$H1" ca1); dump_pane S1 "$P1"
l=$(sed -n 1p "$PROBE"); say "  probe: $l"
case "$l" in *"token=tok-bbb marker=1"*) ok "S1 pane claude launched with account-b's token (account-a marked limited)";; *) bad "S1 probe line: $l";; esac
grep -q '^claude_account=account-b$' "$H1/state/ca1.meta" && ok "S1 task meta records claude_account=account-b" || bad "S1 meta: $(grep claude_account "$H1/state/ca1.meta")"
if grep -rq 'tok-bbb\|tok-aaa' "$H1/state" 2>/dev/null; then bad "S1 a raw token appears under state/ (launch file or meta)"; else ok "S1 no raw token in state/ (meta, launch files)"; fi
if pane_text "$P1" | grep -q 'tok-aaa'; then bad "S1 limited slot's token visible in pane"; fi
# Token is scoped to the launch: the persistent pane shell no longer carries it.
lab pane run "$P1" "printf 'after=%s/%s\n' \"\${CLAUDE_CODE_OAUTH_TOKEN-<unset>}\" \"\${FM_CLAUDE_ACCOUNT_INJECTED-<unset>}\" > $T/s1-after.out" >/dev/null
for _ in $(seq 1 20); do [ -s "$T/s1-after.out" ] && break; sleep 0.5; done
a=$(cat "$T/s1-after.out" 2>/dev/null); say "  pane shell after launch: $a"
[ "$a" = "after=<unset>/<unset>" ] && ok "S1 pane shell holds no CLAUDE_CODE_OAUTH_TOKEN/marker after claude exits" || bad "S1 post-launch pane env: $a"

# ---- S2: relaunch fails over once the in-use slot is marked limited --------
say "== S2 relaunch fails over to the other account"
acct "$H1" clear-limited account-a >>"$LOG" 2>&1
acct "$H1" mark-limited account-b >>"$LOG" 2>&1
spawn "$H1" ca1 --relaunch
wait_probe 2 || bad "S2 relaunch probe never ran"
l=$(sed -n 2p "$PROBE"); say "  probe: $l"; dump_pane S2 "$P1"
case "$l" in *"token=tok-aaa marker=1"*) ok "S2 relaunch launched on account-a after account-b was marked limited";; *) bad "S2 probe line: $l";; esac
grep -q '^claude_account=account-a$' "$H1/state/ca1.meta" && ok "S2 task meta now records claude_account=account-a" || bad "S2 meta: $(grep claude_account "$H1/state/ca1.meta")"

# ---- S3: stale injected token (aborted launch) cleared on slot-less relaunch
say "== S3 stale injected token cleared when the feature is turned off"
lab pane run "$P1" "export CLAUDE_CODE_OAUTH_TOKEN=stale-injected FM_CLAUDE_ACCOUNT_INJECTED=1" >/dev/null; sleep 1
rm -f "$H1/config/claude-accounts"
spawn "$H1" ca1 --relaunch
wait_probe 3 || bad "S3 relaunch probe never ran"
l=$(sed -n 3p "$PROBE"); say "  probe: $l"; dump_pane S3 "$P1"
case "$l" in *"token=<unset> marker=<unset>"*) ok "S3 slot-less relaunch cleared the marked stale token";; *) bad "S3 probe line: $l";; esac
grep -q '^claude_account=' "$H1/state/ca1.meta" && bad "S3 meta still has claude_account" || ok "S3 task meta carries no claude_account with the feature off"

# ---- S4: feature off leaves an operator-set (unmarked) ambient token alone --
say "== S4 feature off: ambient operator token untouched"
H4="$T/home4"; mkhome "$H4" ca4
spawn "$H4" ca4 "$PROJ" "claude --lab-probe" --backend herdr --mode no-mistakes --yolo off
wait_probe 4 || bad "S4 probe never ran"
l=$(sed -n 4p "$PROBE"); say "  probe: $l"; dump_pane S4 "$(pane_of "$H4" ca4)"
case "$l" in *"token=ambient-operator-tok marker=<unset>"*) ok "S4 no config/claude-accounts: claude keeps the pane's ambient operator token";; *) bad "S4 probe line: $l";; esac

# ---- S5: unreadable first slot is ranked after a readable one --------------
say "== S5 missing Keychain slot listed first does not block launches"
H5="$T/home5"; mkhome "$H5" ca5
printf 'ghost\naccount-b\n' > "$H5/config/claude-accounts"
acct "$H5" list >>"$LOG" 2>&1
spawn "$H5" ca5 "$PROJ" "claude --lab-probe" --backend herdr --mode no-mistakes --yolo off
wait_probe 5 || bad "S5 probe never ran"
l=$(sed -n 5p "$PROBE"); say "  probe: $l"; dump_pane S5 "$(pane_of "$H5" ca5)"
case "$l" in *"token=tok-bbb marker=1"*) ok "S5 selection skipped the missing 'ghost' slot and launched on account-b";; *) bad "S5 probe line: $l";; esac
grep -q '^claude_account=account-b$' "$H5/state/ca5.meta" && ok "S5 meta records account-b" || bad "S5 meta: $(grep claude_account "$H5/state/ca5.meta")"

# ---- S6: pane-side fetch failure aborts launch instead of ambient fallback --
say "== S6 token fetch fails in pane: no launch on ambient login"
H6="$T/home6"; mkhome "$H6" ca6
printf 'account-b\n' > "$H6/config/claude-accounts"
touch "$T/fail-in-pane"
spawn "$H6" ca6 "$PROJ" "claude --lab-probe" --backend herdr --mode no-mistakes --yolo off
P6=$(pane_of "$H6" ca6)
for _ in $(seq 1 60); do pane_text "$P6" | grep -q 'could not read the Claude credential' && break; sleep 0.5; done
dump_pane S6 "$P6"
pane_text "$P6" | grep -q "could not read the Claude credential for account slot 'account-b'; not launching on the ambient login" \
  && ok "S6 pane shows the named fetch error" || bad "S6 fetch error not shown in pane"
sleep 2
[ "$(wc -l < "$PROBE")" -eq 5 ] && ok "S6 claude never launched (no ambient-login fallback)" || bad "S6 probe ran: $(tail -1 "$PROBE")"
rm -f "$T/fail-in-pane"

say "== probe log"; cat "$PROBE" >> "$LOG"
say "RESULT passes=$PASSES fails=$FAILS"
[ "$FAILS" -eq 0 ]
