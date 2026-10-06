#!/usr/bin/env bash
# Unit tests for bin/fm-herdr-resume-config.py's pure TOML-editing logic
# (AGENTS.md task firstmate-resume-wrong-copy). Offline and herdr-free: it
# never touches a real herdr config.toml or socket.
set -eu

python3 "$(dirname "${BASH_SOURCE[0]}")/fm-herdr-resume-config.test.py" -v
