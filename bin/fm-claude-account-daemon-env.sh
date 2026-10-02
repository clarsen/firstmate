#!/usr/bin/env bash
# Point the shared no-mistakes daemon's validation agents at one
# config/claude-accounts slot (docs/configuration.md "Claude account
# switching"). Run by hand by the captain or firstmate only; a worker never
# runs it.
#
# Usage: fm-claude-account-daemon-env.sh
#
# Today this always refuses, without reading any token or touching the daemon.
# `no-mistakes daemon start` installs a launchd user agent whose
# EnvironmentVariables are curated to HOME and PATH, so a
# CLAUDE_CODE_OAUTH_TOKEN exported before `daemon start`/`restart` never
# reaches the relaunched daemon, and no-mistakes offers no supported way to set
# a daemon environment variable without persisting it into that plist on disk.
# Writing a setup token into the plist is exactly what this repo forbids, so
# the script names the limitation and exits non-zero until no-mistakes ships a
# per-run or per-repo credential override.
set -u

case "${1:-}" in
  -h | --help)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

cat >&2 <<'MSG'
error: cannot switch the no-mistakes daemon's Claude account.
no-mistakes has no supported non-persisted way to set the daemon's environment today:
its launchd service passes only HOME and PATH, and the only way to add CLAUDE_CODE_OAUTH_TOKEN
would write the token into the daemon's plist on disk, which this script refuses to do.
Validation agents keep using the daemon's own Claude credential; see docs/configuration.md
"Claude account switching".
MSG
exit 1
