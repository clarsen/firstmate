#!/bin/bash
set -eu
unset TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_HOME="$PWD/.test-validation/compat-home" TMPDIR="$PWD/.test-validation/tmp"
mkdir -p "$FM_HOME/data" "$FM_HOME/state" "$FM_HOME/config"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
. bin/fm-tasks-axi-lib.sh
. bin/fm-backlog-transition-lib.sh
for provider in github forgejo; do
 case "$provider" in github) url=https://github.com/example/repo/pull/17 ;; forgejo) url=https://codeberg.org/example/repo/pulls/17 ;; esac
 (cd "$FM_HOME" && tasks-axi add "$provider" "Compatibility $provider" --kind ship --start)
 fm_backlog_done "$FM_HOME/data" "$provider" --pr "$url"
 show=$(cd "$FM_HOME" && tasks-axi show "$provider" --full)
 printf '%s\n' "$show"
 [[ "$show" == *"state: done"* && "$show" == *"pr:$url"* ]] || exit 1
 (cd "$FM_HOME" && tasks-axi add "$provider-held" "Retained $provider" --kind ship --start && tasks-axi hold "$provider-held" --kind captain --reason fixture)
 fm_backlog_retain "$FM_HOME/data" "$provider-held" --pr "$url"
 show=$(cd "$FM_HOME" && tasks-axi show "$provider-held" --full)
 printf '%s\n' "$show"
 [[ "$show" == *"state: queued"* && "$show" == *"pr:$url"* && "$show" == *"hold_kind: captain"* ]] || exit 1
done
(cd "$FM_HOME" && tasks-axi add invalid "Invalid link" --kind ship --start)
if fm_backlog_done "$FM_HOME/data" invalid --pr https://github.com:abc/pull/1; then exit 1; fi
printf 'Invalid link refused: %s\n' "$FM_BACKLOG_TRANSITION_ERROR"
show=$(cd "$FM_HOME" && tasks-axi show invalid --full)
printf '%s\n' "$show"
[[ "$show" == *"state: in_flight"* ]] || exit 1
(cd "$FM_HOME" && tasks-axi add baseline "Original rejection" --kind ship --start)
if (cd "$FM_HOME" && tasks-axi done baseline --pr https://lsg-git.lbl.gov/lblnet/platform-improvement/-/merge_requests/17); then exit 1; fi
printf 'Original tasks-axi 0.2.6 rejection reproduced.\n'
