#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html> [--for <task-id>] [--agent-reply-file <path>] [--one-shot]
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh silent <result-file>
#   fm-procevent-lavish.sh answered <source-id> <result-file> -- <argv>...
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh reconciles <result-file>
#   fm-procevent-lavish.sh read <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh canonical-path <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html> [--keep-session]
#   fm-procevent-lavish.sh retired <source-id> -- <argv>...
#   fm-procevent-lavish.sh poll <artifact.html> [--agent-reply-file <path>]
#   fm-procevent-lavish.sh deliver-reply poll <artifact.html> --agent-reply-file <path>
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, disconnected, missing, or unknown.
# read       Print a structured presentation of one already-captured result so a
#            handler consumes every queued item without grepping the raw file.
#            It is read-only over the capture: it does not arm, poll, or change
#            what Lavish delivered. The freeform message (tag=message) is its
#            own labeled field, printed first and distinct from per-element
#            annotations; it is labeled SESSION-ENDING MESSAGE only when the
#            session ended. Declared and presented item counts,
#            plus a completeness verdict, follow before all annotations so a
#            partial read is obvious. Each annotation retains its element uid,
#            selector, tag, and text. A non-choice freeform comment (`prompt`)
#            is printed as its own field even when a selector is also present
#            and even when that comment matches the element text, so typed
#            words are never dropped. Choice Context data is not a comment.
#            Captain-supplied body lines are visibly prefixed so they cannot
#            forge structural labels. Empty message and annotation sections
#            are reported explicitly. Both published block shapes are read
#            through bin/FmLavishPrompts.pm; a block it cannot parse prints
#            LAVISH RESULT UNREADABLE and exits 3 rather than reporting zero
#            items, because the raw capture may still hold the captain's words.
# canonical-path  Print the artifact path exactly as Lavish keys its session,
#            including the on-disk letter case on a case-insensitive volume.
#            Other scripts that match a board against Lavish's own records call
#            this rather than resolving the path themselves.
# poll       The registered listener command `arm` publishes, not a command to
#            run in a conversational turn. It runs the published blocking poll
#            and prints its response verbatim, absorbing only the one exact
#            transient interruption described below. A staged reply still
#            present when it starts is posted before the long-poll: through
#            `lavish-axi reply` when supported, otherwise through the legacy
#            best-effort `poll --agent-reply` path.
# deliver-reply
#            Run by `fm-procevent.sh register-task` under the source lock, only
#            after the task is eligible to own the board, with the listener argv
#            it is about to publish. Exit 0 once Lavish accepts the staged reply,
#            3 when the installed Lavish is a confirmed older release without
#            synchronous reply so the listener keeps the legacy path, and any
#            other status when the reply failed or the version is unknown.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
# silent     Exit 0 when the captured result is a routine no-op the runner should
#            record and never announce; any other exit publishes the wake. This
#            is the generic no-op contract bin/fm-procevent.sh calls, and the
#            only place Lavish's notion of "nothing was said" is decided.
#            Task-owned terminal rounds bypass generic silence so their owner
#            receives the stop-and-conclude instruction.
# answered   Exit 0 when every question key of the decision page the
#            registration's argv polls (the argument following the literal
#            `poll`, whose embedded `decision-page-data` payload lists the
#            questions) has a queued choice in this source's captured rounds,
#            up to and including <result-file> and captured no earlier than the
#            page itself; any other exit means the page still has an
#            unanswered question. A round that answers only some questions, or
#            carries only a freeform note, never completes the page, and an
#            artifact with no readable page payload is never complete. This is
#            the generic one-shot-retirement contract bin/fm-procevent.sh's
#            `handled` calls only for a source registered with
#            `arm --one-shot`: once such a page is fully answered and that
#            round is acknowledged, it retires exactly like a terminal round,
#            because it has nothing further to collect. A board kept armed
#            across many separate questions is never registered one-shot, so
#            this seam never retires it.
#
# AN EMPTY BOARD CLOSE IS NOT NEWS, and that is what `silent` exists to say.
# Closing a review surface that carried nothing is the single most common Lavish
# result: the captain reads a board, says nothing, and closes it. Announcing that
# put a wake in front of the handler whose entire content was that nothing
# happened. `silent` therefore holds two narrow, positively-determined shapes -
# a session this adapter classifies `ended` that carries no queued content block
# at all, or `browser_disconnected`, which carries no answer while the session
# remains open - and every other result stays announced.
#
# Deliberately narrow, in both directions. A `Send & End` close carrying the
# captain's actual answer arrives as `status: feedback` with `session_ended`, so
# it classifies `feedback`, never `ended`, and is announced exactly as before; so
# is any `ended` result that still carries a `prompts` or `feedback` block, which
# the published poll is not expected to produce but which must never be dropped
# on that expectation. A `waiting` session, a `missing` one, an `unknown` or
# unreadable result, and any error all stay announced, because none of them
# positively proves nothing was said. Silence is only ever an absence this
# adapter can see in the result, never an absence it assumes.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the currently published poll command,
# and how to read a completed result. Ownership, durable capture, publication,
# and restart recovery all belong to bin/fm-procevent.sh.
#
# The published poll vocabulary includes feedback, ended, waiting, and
# browser_disconnected. A waiting result from this no-timeout poll means a
# second poller was present; it is not a normal idle round. browser_disconnected
# means the session remains open and is handled as a silent reconnect wait.
# Before each poll attempt, resolve the artifact's saved URL from Lavish's own
# session store (LAVISH_AXI_STATE_DIR/state.json, default ~/.lavish-axi/state.json)
# and use its host and port. Opening the board writes that URL; polling does not.
# This is a routing lookup before the blocking call, not presence polling or a
# second route record. Ambient/configured addresses must not retarget a reply.
# An unreadable or missing session stops before the staged reply is consumed.
#
# retire     Retire the artifact's process-event source, then end its Lavish
#            session as the agent (`lavish-axi end`) so a finished decision
#            page reads as finished instead of lingering as a live session; a
#            plain reopen still works later. The source retirement comes first
#            and decides the exit status: ending the session is best effort, so
#            a missing or failing lavish-axi, or an unresolvable session host,
#            is reported as `session-end-skipped:` and never an error, while a
#            successful `lavish-axi end` prints `session-ended:`. `--keep-session`
#            retires only the source and leaves the session open; the board
#            reopen path in fm-bearings-board.sh uses it so a reopened board is
#            never ended by the retirement of its previous generation.
# retired    The generic post-retirement seam bin/fm-procevent.sh's `handled`
#            calls after it concludes a source by dropping its registration (a
#            task-owned board's terminal round, or a `--one-shot` source's
#            terminal or answered round), with that registration's stored argv.
#            The artifact is the argument following the literal `poll` in that
#            argv, and its session is ended exactly as `retire` ends it, with
#            the same best-effort `session-ended:`/`session-end-skipped:`
#            report, so a source `handled` concludes reads as finished in
#            Lavish just like one retired explicitly. An argv with no poll
#            artifact exits nonzero; the runner ignores this seam's status.
#
# `answers` is this adapter's half of the generic keyed-answer contract in
# bin/fm-procevent.sh. It reports what the captain actually chose, as
# `<task-id>\t<answer>\t<label>` lines, and stops there. It maps nothing to a
# task, records no decision, and closes nothing: a captain answer is not special
# to Lavish, so every rule about what a keyed answer DOES belongs to the one
# intake in bin/fm-captain-hold.sh, which the runner feeds. A Lavish review is
# just an ephemeral discussion format that happens to carry answers.
#
# Only rows tagged `choice` are read. A freeform captain message is prose that may
# contain anything, and must never be able to forge a decision key.
#
# `read` is the presentation command summarized above; keyed intake remains
# the separate `answers` contract described here.
#
# It wraps the published `lavish-axi poll` and `lavish-axi reply` interfaces,
# verified against 0.1.80. `poll` long-polls indefinitely; `reply` exits only
# after the server confirms acceptance. Older compatible versions retain the
# legacy poll-with-reply path, without the synchronous handoff guarantee.
#
# BOUNDED QUIET RETRY, owned here and nowhere else. A live listener can be cut
# short by the server with exactly this two-line response while the session's
# marks remain available:
#
#   error: Lavish Editor poll response was interrupted
#   code: SERVER_ERROR
#
# That is an internal retry, not news, so registering the raw poll made the
# generic runner capture it and wake the whole fleet. `poll` therefore re-runs
# the published poll up to POLL_RETRY_LIMIT times for that exact response, with
# attempt starts at least POLL_RETRY_DELAY_DEFAULT seconds apart. The match is exact and
# deliberately narrow: real feedback, ended and missing sessions, any other
# SERVER_ERROR, and the same interruption still standing after the bound is
# spent are all printed straight through and captured normally. The retry is a
# Lavish fact, so the generic runner in bin/fm-procevent.sh stays
# adapter-agnostic and learns nothing about it.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

# The single owner of how firstmate names a board the way Lavish does. Lavish
# keys a session on Node's native realpath, which on a case-insensitive volume
# returns the ON-DISK letter case, whereas Perl's Cwd::realpath and GNU
# realpath(1) keep the caller's case. Resolving through the same Node call
# lavish-axi runs on is the only way a board reached through a differently
# cased path still finds its saved session and one source identity.
lavish_canonical_path() {  # <artifact>
  node -e 'process.stdout.write(require("node:fs").realpathSync.native(process.argv[1]))' \
    "$1" 2>/dev/null
}

apply_session_host() {  # <artifact>
  local endpoint real
  real=$(lavish_canonical_path "$1") \
    || die "cannot resolve the board server from its Lavish session: $1"
  endpoint=$(perl -MJSON::PP -MEncode=decode,FB_CROAK -e '
    use strict;
    use warnings;
    my ($path, $real) = @ARGV;
    $real = decode("UTF-8", $real, FB_CROAK);
    open my $file, "<", $path or die "cannot read Lavish session store\n";
    -f $file or die "Lavish session store is not a regular file\n";
    local $/;
    my $state = eval { decode_json(<$file>) };
    !$@ or die "invalid Lavish session store\n";
    ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH"
      or die "invalid Lavish session store\n";
    my @sessions = grep {
      ref($_) eq "HASH" && defined($_->{file}) && $_->{file} eq $real
    } values %{$state->{sessions}};
    @sessions == 1 or die "board must have one saved Lavish session\n";
    my $url = $sessions[0]->{url} // "";
    $url =~ m{\Ahttp://(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+):([0-9]+)/session/[0-9a-f]{16}(?:\?[^\s#]*)?\z}
      or die "invalid saved Lavish session URL\n";
    my ($host, $port) = ($1, $2);
    $host =~ s/^\[|\]$//g;
    $host ne "0.0.0.0" && $host ne "::" && $port >= 1 && $port <= 65535
      or die "invalid saved Lavish server address\n";
    print "$host\n$port\n";
  ' "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json" "$real") \
    || die "cannot resolve the board server from its Lavish session: $1"
  LAVISH_AXI_HOST=${endpoint%$'\n'*}
  LAVISH_AXI_PORT=${endpoint##*$'\n'}
  export LAVISH_AXI_HOST LAVISH_AXI_PORT
}

lavish_reply_compatible() {
  local status=0
  "$FM_ROOT/bin/fm-bootstrap.sh" lavish-reply-compatible >/dev/null 2>&1 || status=$?
  case "$status" in
    0|1) return "$status" ;;
  esac
  die "cannot confirm a supported lavish-axi version, so the staged reply was not posted; retry once \`lavish-axi --version\` reports a supported release"
}

post_lavish_reply() {  # <artifact> <reply-file>
  local output
  if ! output=$(lavish-axi reply "$1" --agent-reply-file "$2" 2>&1); then
    [ -n "$output" ] || output="lavish-axi reply exited nonzero"
    die "Lavish did not accept the staged reply: $output"
  fi
}

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the native realpath of the artifact, so two names for one file -
# including two letter cases of it on a case-insensitive volume - are one
# source and must never become two owners.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(lavish_canonical_path "$artifact") \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

cmd_arm() {
  local artifact='' task='' reply_file='' one_shot=0 id real owner listening
  local -a listener=() register_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for)
        [ "$#" -ge 2 ] || usage
        task=$2
        shift 2
        ;;
      --agent-reply-file)
        [ "$#" -ge 2 ] || usage
        reply_file=$2
        shift 2
        ;;
      --one-shot)
        one_shot=1
        shift
        ;;
      --*) usage ;;
      *)
        [ -z "$artifact" ] || usage
        artifact=$1
        shift
        ;;
    esac
  done
  [ -n "$artifact" ] || usage
  [ -z "$reply_file" ] || [ -n "$task" ] || usage
  # --one-shot is a plain-register concept: a task-owned board already
  # concludes its own terminal round through `handled`, by task, not by
  # adapter-declared lifecycle.
  [ "$one_shot" -eq 0 ] || [ -z "$task" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  poll_retry_delay >/dev/null
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(lavish_canonical_path "$artifact") \
    || die "cannot resolve the artifact path: $artifact"
  listener=("$SCRIPT_DIR/fm-procevent-lavish.sh" poll "$real")
  [ -z "$reply_file" ] || listener+=(--agent-reply-file "$reply_file")
  if [ -n "$task" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register-task lavish "$id" "$task" -- \
      "${listener[@]}" || exit 1
  else
    # This adapter's own listener command, which runs the plain blocking form
    # with no --timeout-ms so completion is a server event, and absorbs only
    # the exact transient interruption.
    register_args=(lavish "$id")
    [ "$one_shot" -eq 0 ] || register_args+=(--one-shot)
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register "${register_args[@]}" \
      -- "${listener[@]}" || exit 1
  fi
  # Registration is not a running listener. Readiness is the process-event
  # owner's evidence for this generation; a miss retires a source that never
  # started so arm does not leave it registered.
  listening=0
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$id" || listening=$?
  if [ "$listening" -eq 3 ]; then
    printf 'still-listening: %s\n' "$id"
    printf 'artifact: %s\n' "$real"
    [ -z "$task" ] || printf 'owner-task: %s\n' "$task"
    printf 'note: an earlier listener is still live and serving this board; this registration takes effect only after fm-procevent-lavish.sh retire <artifact> --keep-session and a fresh arm\n'
    exit 0
  fi
  if [ "$listening" -ne 0 ]; then
    owner=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
      | awk -v id="$id" '$1 == id { print $3; exit }')
    case "$owner" in
      live|orphaned|task:*/listening|task:*/round-open) ;;
      *) FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" retire "$id" >/dev/null 2>&1 || true ;;
    esac
    exit 1
  fi
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
  [ -z "$task" ] || printf 'owner-task: %s\n' "$task"
}

cmd_deliver_reply() {
  [ "$#" -eq 4 ] && [ "$1" = poll ] && [ "$3" = --agent-reply-file ] || usage
  lavish_reply_compatible || exit 3
  apply_session_host "$2"
  post_lavish_reply "$2" "$4"
}

cmd_retire() {
  local artifact='' keep_session=0 id
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep-session) keep_session=1; shift ;;
      --*) usage ;;
      *) [ -z "$artifact" ] || usage; artifact=$1; shift ;;
    esac
  done
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id" || exit $?
  [ "$keep_session" = 0 ] || return 0
  end_session_best_effort "$artifact"
}

# The artifact a registered listener argv polls: the argument following the
# literal `poll`.
poll_artifact() {  # <argv>...
  while [ "$#" -gt 0 ]; do
    if [ "$1" = poll ] && [ "$#" -ge 2 ]; then
      printf '%s\n' "$2"
      return 0
    fi
    shift
  done
  return 1
}

cmd_retired() {
  local artifact
  [ "$#" -ge 2 ] && [ -n "$1" ] && [ "$2" = -- ] || usage
  shift 2
  artifact=$(poll_artifact "$@") || die "the retired source's argv names no poll artifact"
  end_session_best_effort "$artifact"
}

# The source is retired; now end the Lavish session as the agent so the page
# reads as finished instead of lingering as a live session. Best effort: a
# missing or failing lavish-axi never fails the retirement.
end_session_best_effort() {  # <artifact>
  local artifact=$1 real
  if ! command -v lavish-axi >/dev/null 2>&1; then
    printf 'session-end-skipped: lavish-axi is not installed\n'
    return 0
  fi
  real=$(lavish_canonical_path "$artifact") || real=$artifact
  if (apply_session_host "$real" && lavish-axi end "$real") >/dev/null 2>&1; then
    printf 'session-ended: %s\n' "$real"
  else
    printf 'session-end-skipped: no open Lavish session ended for %s\n' "$real"
  fi
}

# The bounded quiet retry described in the header. The bound is a constant
# because it is a property of the transient response, not an operator choice;
# only the delay takes an override, so a test can exercise the real bound
# without waiting it out.
POLL_RETRY_LIMIT=12
POLL_RETRY_DELAY_DEFAULT=5
POLL_RETRY_DELAY_MIN=1
POLL_RETRY_DELAY_MAX=60

# Exit 0 only for the exact two-line interruption, and nothing else. The whole
# response must be those two lines with those exact bytes: whitespace variants,
# a longer response that merely opens with them, and any other SERVER_ERROR are
# genuine errors this adapter must never swallow.
poll_response_filter() {  # <response-file>
  perl -e '
    use strict;
    use warnings;
    my ($stage) = @ARGV;
    my $expected = "error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n";
    open my $staged, ">", $stage or exit 2;
    binmode STDIN;
    binmode STDOUT;
    binmode $staged;
    my ($candidate, $streaming) = ("", 0);
    sub write_all {
      my ($handle, $bytes) = @_;
      my $offset = 0;
      while ($offset < length $bytes) {
        my $written = syswrite $handle, $bytes, length($bytes) - $offset, $offset;
        exit 2 unless defined $written;
        $offset += $written;
      }
    }
    while (1) {
      my $count = sysread STDIN, my $chunk, 65536;
      exit 2 unless defined $count;
      last if $count == 0;
      if ($streaming) {
        write_all(*STDOUT, $chunk);
        next;
      }
      my $room = length($expected) + 1 - length($candidate);
      my $take = length($chunk) < $room ? length($chunk) : $room;
      my $prefix = substr($chunk, 0, $take);
      $candidate .= $prefix;
      write_all($staged, $prefix);
      my $matches_prefix = length($candidate) <= length($expected)
        && substr($expected, 0, length($candidate)) eq $candidate;
      if (!$matches_prefix) {
        write_all(*STDOUT, $candidate);
        write_all(*STDOUT, substr($chunk, $take));
        $streaming = 1;
      }
    }
    exit 10 if !$streaming && $candidate eq $expected;
    write_all(*STDOUT, $candidate) unless $streaming;
  ' "$1"
}

# Minimum seconds between retry attempt starts. FM_LAVISH_POLL_RETRY_DELAY is a
# bounded test override; a malformed or out-of-range value is refused rather than quietly
# rounded, because silently changing a retry cadence is how a bound stops
# meaning anything.
poll_retry_delay() {
  local delay=${FM_LAVISH_POLL_RETRY_DELAY-}
  if [ -z "$delay" ]; then
    printf '%s\n' "$POLL_RETRY_DELAY_DEFAULT"
    return 0
  fi
  case "$delay" in
    *[!0-9]*) die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from $POLL_RETRY_DELAY_MIN to $POLL_RETRY_DELAY_MAX: $delay" ;;
  esac
  [ "$delay" -ge "$POLL_RETRY_DELAY_MIN" ] && [ "$delay" -le "$POLL_RETRY_DELAY_MAX" ] \
    || die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from $POLL_RETRY_DELAY_MIN to $POLL_RETRY_DELAY_MAX: $delay"
  printf '%s\n' "$delay"
}

poll_iteration_started() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
    'printf "%.6f\\n", clock_gettime(CLOCK_MONOTONIC)'
}

poll_iteration_floor_wait() {
  perl -MTime::HiRes=clock_gettime,sleep,CLOCK_MONOTONIC -e '
    my ($started, $floor) = @ARGV;
    my $remaining = $floor - (clock_gettime(CLOCK_MONOTONIC) - $started);
    sleep($remaining) if $remaining > 0;
  ' "$1" "$2"
}

cmd_poll() {
  local artifact=${1-} delay attempt=0 response cleanup_command rc filter_rc iteration_started
  local pipeline_status reply_file=''
  local reply_text='' reply_pending=0
  [ -n "$artifact" ] || usage
  if [ "$#" -eq 3 ] && [ "${2-}" = --agent-reply-file ]; then
    reply_file=$3
  elif [ "$#" -ne 1 ]; then
    usage
  fi
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  delay=$(poll_retry_delay) || exit 1
  response=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-poll.XXXXXX") || die "cannot stage the poll response"
  printf -v cleanup_command 'rm -f -- %q' "$response"
  # shellcheck disable=SC2064 # $cleanup_command must expand now, while the staged path is still set.
  trap "$cleanup_command" EXIT
  # Retirement stops this listener by signalling its process group, and bash runs
  # no EXIT trap for an uncaught signal, so each one cleans up the staged
  # response and then re-raises itself with the default disposition, leaving the
  # process dying exactly as the runner expects.
  local signal
  for signal in INT TERM HUP; do
    # shellcheck disable=SC2064 # Same reason: expand now, while both are set.
    trap "$cleanup_command; trap - $signal; kill -$signal $$" "$signal"
  done
  while :; do
    iteration_started=$(poll_iteration_started) || die "cannot start the poll rate governor"
    [ -f "$artifact" ] && [ ! -L "$artifact" ] && [ -r "$artifact" ] \
      || die "artifact is no longer a readable file: $artifact"
    apply_session_host "$artifact"
    # Newer Lavish builds expose a one-shot reply command whose success is the
    # server's acceptance receipt. Consume the staged file only after that
    # confirmation; older compatible builds retain the published poll reply
    # behavior and its best-effort delivery boundary.
    if [ -f "$reply_file" ] && [ ! -L "$reply_file" ]; then
      if lavish_reply_compatible; then
        post_lavish_reply "$artifact" "$reply_file"
        rm -f -- "$reply_file" || die "cannot consume agent reply file: $reply_file"
      else
        reply_text=$(cat -- "$reply_file") \
          || die "cannot read agent reply file: $reply_file"
        rm -f -- "$reply_file" || die "cannot consume agent reply file: $reply_file"
        reply_pending=1
      fi
    fi
    if [ "$reply_pending" -eq 1 ]; then
      lavish-axi poll "$artifact" --agent-reply "$reply_text" | poll_response_filter "$response"
    else
      lavish-axi poll "$artifact" | poll_response_filter "$response"
    fi
    pipeline_status=("${PIPESTATUS[@]}")
    reply_pending=0
    rc=${pipeline_status[0]}
    filter_rc=${pipeline_status[1]}
    case "$filter_rc" in
      0) break ;;
      10)
        if [ "$attempt" -lt "$POLL_RETRY_LIMIT" ]; then
          attempt=$((attempt + 1))
          poll_iteration_floor_wait "$iteration_started" "$delay" \
            || die "cannot enforce the poll rate governor"
        else
          cat -- "$response"
          break
        fi
        ;;
      *) die "cannot classify the poll response" ;;
    esac
  done
  return "$rc"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback)            printf 'feedback\n'; return 0 ;;
    ended)               printf 'ended\n'; return 0 ;;
    waiting)             printf 'waiting\n'; return 0 ;;
    browser_disconnected) printf 'disconnected\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

# Whether a completed result carries any queued content block at all. The
# published response frames content as a top-level `prompts[N]{...}:` or
# `feedback[N]{...}:` header whose rows are INDENTED, so this anchors on column
# zero: an indented payload line is captain-supplied text and must never be able
# to forge - or, here, to hide behind - a content header. Any recognized block
# is content regardless of its declared count, while a malformed top-level
# prompts or feedback header makes the result indeterminate.
#
# 0 = content present, 1 = provably no content, anything else = the check did
# not complete. The caller must distinguish those three, because "the check
# failed" is never proof that nothing was said.
result_has_queued_content() {  # <result-file>
  awk '
    /^(prompts|feedback)\[[0-9]+\](\{[^}]*\})?:[[:space:]]*$/ {
      verdict = "present"
      exit
    }
    /^(prompts|feedback)/ {
      verdict = "indeterminate"
      exit
    }
    END {
      if (verdict == "present") exit 0
      if (verdict == "indeterminate") exit 2
      exit 1
    }
  ' "$1"
}

# Whether a captured result is a routine no-op the runner should record without
# announcing, for the generic runner's silence seam. Lavish's notion of "nothing
# was said" lives here and nowhere else: an ended session carrying no queued
# content block is a board the captain closed without saying anything, and the
# handler learns nothing from being told. Anything else - a real answer, a
# missing or waiting session, an unreadable result - is announced.
cmd_silent() {
  local file=${1-} content_rc
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = disconnected ] && return 0
  [ "$(cmd_classify "$file")" = ended ] || return 1
  result_has_queued_content "$file"
  content_rc=$?
  # Only a completed check that proved the result carries nothing declares
  # silence; a check that could not complete announces, like every other
  # uncertainty here.
  [ "$content_rc" -eq 1 ]
}

# Whether a one-shot decision page has a queued choice for every question it
# asks (see `answered` in the header). The page's question keys come from its
# own embedded payload; the answered keys are every choice row, ordinary or
# reconcile, across this source's captured rounds up to <result-file>. A round
# captured before the page was last written belongs to an earlier page at the
# same path and answers nothing here.
cmd_answered() {
  local id=${1-} file=${2-} artifact base seq round round_seq questions
  [ -n "$id" ] && [ -n "$file" ] && [ "${3-}" = -- ] || usage
  shift 3
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  base=${file##*/}
  seq=${base#"$id."}
  seq=${seq%.result}
  case "$seq" in ''|*[!0-9]*) die "result file does not belong to $id: $file" ;; esac
  artifact=$(poll_artifact "$@") || die "the source's argv names no poll artifact"
  [ -f "$artifact" ] || return 1
  questions=$(perl -MJSON::PP -e '
    local $/; my $html = <STDIN>;
    $html =~ m{<script id="decision-page-data" type="application/json">\s*(.*?)\s*</script>}s or exit 1;
    my $data = eval { decode_json($1) };
    ref($data) eq "HASH" && ref($data->{questions}) eq "ARRAY" && @{ $data->{questions} } or exit 1;
    for my $q (@{ $data->{questions} }) {
      ref($q) eq "HASH" && defined($q->{key}) && !ref($q->{key}) && length($q->{key}) or exit 1;
      print "$q->{key}\n";
    }
  ' < "$artifact" | sort -u) || return 1
  [ -n "$questions" ] || return 1
  [ -z "$(
    for round in "${file%/*}/$id".*.result; do
      [ -f "$round" ] && [ ! -L "$round" ] || continue
      round_seq=${round##*/}
      round_seq=${round_seq#"$id."}
      round_seq=${round_seq%.result}
      case "$round_seq" in ''|*[!0-9]*) continue ;; esac
      [ "$round_seq" -le "$seq" ] || continue
      [ "$artifact" -nt "$round" ] && continue
      cmd_choice_rows answers "$round" 2>/dev/null
      cmd_choice_rows reconciles "$round" 2>/dev/null
    done | cut -f1 | sort -u | comm -23 <(printf '%s\n' "$questions") -
  )" ]
}

# Print `key<TAB>answer<TAB>label[<TAB>mode]` for each non-reconcile structured choice the
# captain submitted in a captured result; the optional mode column relays the
# card's declared close mode (`done` or `release`) to the keyed-answer intake. Rows are enumerated by bin/FmLavishPrompts.pm, the
# one parser shared with `read`, which owns both published shapes (tabular
# `prompts[N]{...}:` and list `prompts[N]:`); an unreadable block exits 3
# with an error rather than yielding no rows. This takes only rows whose `tag` field is
# `choice`. A freeform `message` row is captain prose and is deliberately never a
# source of decision keys. A row that does not carry both a slug-shaped `question`
# and the versioned `selection` and `note` fields inside its `Context data:` block
# (schema `fm-bearings-answer.v1` from the board or `fm-decision-page-answer.v1`
# from a decision page, both queued by the shared decision card)
# is skipped. A time-limited rollout branch accepts the old question/answer
# shape only for ordinary answers and rejects its bare or annotated reconcile
# values because old rows do not separate the selected option from its note.
# The question cap is 128 so any task id fits, including the long legacy
# `<origin>-decision-<key>` identities pre-collapse decks still carry; the
# security property is the slug SHAPE, which is unchanged.
cmd_choice_rows() {
  local selection=$1 file=${2-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -I"$SCRIPT_DIR" -MJSON::PP -MFmLavishPrompts=parse_blocks -e '
    use strict; use warnings;
    my ($selection, $path) = @ARGV;
    my $parsed = parse_blocks($path, "prompts");
    if ($parsed->{error}) { print STDERR "error: $parsed->{error}\n"; exit 3 }
    print STDERR "warning: $parsed->{malformed} of $parsed->{declared} captured prompts could not be read\n"
      if $parsed->{malformed} || @{ $parsed->{rows} } != $parsed->{declared};
    my %seen;
    my @choices;
    for my $f (@{ $parsed->{rows} }) {
      my %f = %$f;
      next unless defined $f{tag} && $f{tag} eq "choice";
      my $prompt = $f{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      my $data = eval { decode_json($ctx) };
      next unless ref($data) eq "HASH";
      my ($key, $selected, $note, $answer, $legacy);
      if (defined($data->{schema}) && !ref($data->{schema})
          && ($data->{schema} eq "fm-bearings-answer.v1"
            || $data->{schema} eq "fm-decision-page-answer.v1")) {
        $key = $data->{question};
        $selected = $data->{selection};
        $note = $data->{note};
        next if !defined($key) || ref($key) || !defined($selected) || ref($selected)
          || !defined($note) || ref($note);
        next unless $selected eq "" || $selected =~ /\A[A-Za-z0-9._-]{1,128}\z/;
        next unless length($note) <= 512;
        next unless length($selected) || length($note);
        $answer = length($selected) ? $selected : $note;
        $legacy = 0;
      # Time-limited compatibility for captures from pre-change boards; remove
      # once no board carrying the old question/answer context can remain armed.
      } elsif (!exists($data->{schema}) && !exists($data->{selection})
          && !exists($data->{note})) {
        $key = $data->{question};
        $answer = $data->{answer};
        next if !defined($key) || ref($key) || !defined($answer) || ref($answer);
        next unless length($answer) && length($answer) <= 512;
        next if $answer eq "reconcile" || index($answer, "reconcile - ") == 0;
        $selected = "";
        $note = "";
        $legacy = 1;
      } else {
        next;
      }
      next unless $key =~ /\A[A-Za-z0-9._-]{1,128}\z/;
      my $mode = "";
      if (exists $data->{close}) {
        next if !defined($data->{close}) || ref($data->{close})
          || ($data->{close} ne "done" && $data->{close} ne "release");
        $mode = $data->{close};
      }
      my $label = defined $f{text} ? $f{text} : "";
      s/[\x00-\x1f\x7f]/ /g for ($answer, $note, $label);
      $label = substr($label, 0, 512);
      if (defined $seen{$key}) { $choices[$seen{$key}] = undef }
      $seen{$key} = scalar @choices;
      push @choices, {
        key => $key, selection => $selected, note => $note, legacy => $legacy,
        answer => $answer, label => $label, mode => $mode
      };
    }
    for my $choice (grep { defined } @choices) {
      if ($selection eq "reconciles") {
        next if $choice->{legacy};
        if ($choice->{selection} eq "reconcile") {
          print length($choice->{note})
            ? "$choice->{key}\t$choice->{note}\n"
            : "$choice->{key}\n";
        }
        next;
      }
      next if $choice->{selection} eq "reconcile";
      print length $choice->{mode}
        ? "$choice->{key}\t$choice->{answer}\t$choice->{label}\t$choice->{mode}\n"
        : "$choice->{key}\t$choice->{answer}\t$choice->{label}\n";
    }
  ' "$selection" "$file"
}

cmd_answers() { cmd_choice_rows answers "$@"; }
cmd_reconciles() { cmd_choice_rows reconciles "$@"; }

# Present one already-captured result for a handler. Body lines are prefixed
# so a captain-supplied string cannot forge a section label. A freeform message
# is printed before the count line and before any annotation, because that is
# the field a truncated grep of the raw capture historically dropped.
# A non-choice annotation that carries a freeform `prompt` prints that comment
# as its own field; a selector must not hide the typed words, even when the
# comment matches the captured element text. Choice rows keep Context data
# out of that field. A pure annotation has no prompt.
cmd_read() {
  local file=${1-} lifecycle session_ended
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  lifecycle=$(cmd_classify "$file")
  session_ended=$(session_field "$file" session_ended)
  perl -I"$SCRIPT_DIR" -MFmLavishPrompts=parse_blocks -e '
    use strict; use warnings;
    my ($path, $lifecycle, $session_ended) = @ARGV;
    my $parsed = parse_blocks($path, "prompts", "feedback");
    if ($parsed->{error}) {
      print "LAVISH RESULT UNREADABLE: $parsed->{error}\n";
      print "The captured result may hold the captain'"'"'s answers; read the raw file.\n";
      exit 3;
    }
    my $want = $parsed->{declared};
    my @parsed = @{ $parsed->{rows} };
    my $malformed = $parsed->{malformed};
    my $complete = (@parsed == $want && !$malformed) ? "yes" : "no";
    my $presented = scalar @parsed;
    my @messages;
    my @annotations;
    for my $f (@parsed) {
      my $tag = defined $f->{tag} ? $f->{tag} : "";
      if ($tag eq "message") {
        push @messages, $f;
      } else {
        push @annotations, $f;
      }
    }
    sub emit_body {
      my ($text) = @_;
      $text = "" unless defined $text;
      $text =~ s/\r\n/\n/g;
      $text =~ s/\r/\n/g;
      my @lines = split /\n/, $text, -1;
      pop @lines if @lines && $lines[-1] eq "";
      return if !@lines || (@lines == 1 && $lines[0] eq "");
      print "| $_\n" for @lines;
    }
    if (@messages) {
      my $message_label = $session_ended =~ /^(?:true|True|TRUE)$/
        ? "SESSION-ENDING MESSAGE" : "CAPTAIN MESSAGE";
      print "$message_label\n";
      for my $i (0 .. $#messages) {
        print "$message_label PART ", ($i + 1), " of ", scalar(@messages), "\n" if @messages > 1;
        my $body = defined $messages[$i]{prompt} && length $messages[$i]{prompt}
          ? $messages[$i]{prompt}
          : (defined $messages[$i]{text} ? $messages[$i]{text} : "");
        emit_body($body);
      }
      print "END $message_label\n";
    } else {
      print "SESSION-ENDING MESSAGE: (none)\n";
    }
    print "\n";
    print "declared_items: $want\n";
    print "presented_items: $presented\n";
    print "malformed_items: $malformed\n";
    print "complete: $complete\n";
    print "lifecycle: $lifecycle\n";
    print "session_ended: ", (length $session_ended ? $session_ended : "(unset)"), "\n";
    print "annotation_count: ", scalar(@annotations), "\n";
    print "session_ending_message_count: ", scalar(@messages), "\n";
    print "\n";
    if (@annotations) {
      print "ANNOTATIONS\n";
      my $n = 0;
      for my $f (@annotations) {
        $n++;
        my $uid = defined $f->{uid} ? $f->{uid} : "";
        my $selector = defined $f->{selector} ? $f->{selector} : "";
        my $tag = defined $f->{tag} ? $f->{tag} : "";
        print "ANNOTATION $n of ", scalar(@annotations), "\n";
        print "element_uid: $uid\n";
        print "element_selector: $selector\n";
        print "tag: $tag\n";
        print "text:\n";
        my $elem = defined $f->{text} ? $f->{text} : "";
        my $comment = defined $f->{prompt} ? $f->{prompt} : "";
        my $body = length $elem ? $elem : $comment;
        emit_body($body);
        if ($tag ne "choice" && length $comment) {
          print "prompt:\n";
          emit_body($comment);
        }
      }
      print "END ANNOTATIONS\n";
    } else {
      print "ANNOTATIONS: (none)\n";
    }
    print "END LAVISH RESULT ($presented of $want)\n";
  ' "$file" "$lifecycle" "$session_ended"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  retired)   shift; cmd_retired "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  deliver-reply) shift; cmd_deliver_reply "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  canonical-path)
    shift
    [ "$#" -eq 1 ] && [ -n "$1" ] || usage
    lavish_canonical_path "$1" || die "cannot resolve the artifact path: $1"
    printf '\n'
    ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  answered)  shift; cmd_answered "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  reconciles) shift; cmd_reconciles "$@" ;;
  read)      shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
