#!/usr/bin/env bash
# Task members: worktrees of OTHER registered projects that a ship or scout task
# holds beside its own worktree (the anchor). A `ref` member is read-only
# context - a contract, a specification, or a sibling repository at a pinned
# ref. An `edit` member is a delivered change in that repository: its own
# branch, its own delivery, its own PR, and its own landed-work test, so one
# worker can change several repositories in one task.
#
# This library is the single owner of the member contract: the --member spec,
# the durable lease identity, the task-record fields, the launch brief
# sections, the rule that tells which repository of a task a PR or a done line
# names, and the lease checks cleanup relies on. bin/fm-spawn.sh leases, pins,
# branches, and publishes members; bin/fm-teardown.sh proves edit members
# landed and returns every member; bin/fm-pr-check.sh, bin/fm-pr-merge.sh,
# bin/fm-merge-local.sh, bin/fm-dod-lib.sh, and bin/fm-crew-state.sh read the
# delivery of edit members. docs/configuration.md "Task members" is the
# operator summary that points here.
#
# Spec (fm-spawn.sh --member, repeatable):
#   <name>=<project-dir>:ref[@<ref>]
#   <name>=<project-dir>:edit
#   <name>  1-32 characters of [a-z0-9-], starting with a letter; unique in the
#           task. The worker's pane receives FM_MEMBER_<NAME> (upper-cased, - as
#           _) holding the member's absolute path.
#   ref     read-only context the worker never modifies, commits in, or pushes
#           from. A ref member is never delivered; cleanup discards anything
#           left in it, exactly like a scout's scratch copy.
#   <ref>   optional branch, tag, commit, or fetchable ref such as
#           refs/pull/<n>/head. Absent means origin's current default-branch
#           tip, or the copy's own HEAD for a project with no origin.
#   edit    ship spawns only. The copy starts at origin's current
#           default-branch tip on a new branch fm/<task-id> that spawn creates,
#           and takes no @<ref>. Its delivery mode and merge posture are that
#           project's registered posture (bin/fm-project-mode.sh, whose
#           mechanical answer maps a conditional policy to its most rigorous
#           leg), because delivery is per repository.
#   A member is a clone this home already holds, other than the task's own
#   project; two members may not share one Treehouse project identity.
#
# Lease: a task's own worktree is held by the process running in its pane. A
# member has no such process - the worker reads or edits it by path - so it is
# taken with `treehouse [--root <home pool root>] get --lease --lease-holder
# <holder> --json` from the member's clone, which Treehouse never hands to
# another get until that lease is returned. <holder> is
# fm-member:<home-hash>:<task-id> (fm_member_lease_holder). The slot also
# carries the ordinary slot-owner claim (bin/fm-wake-lib.sh), naming this task,
# so another task's stale record never resets it. Cleanup returns a member only
# while Treehouse still reports this task's exact lease id on it
# (fm_member_lease_state), so a slot this task no longer holds is never reset.
#
# Record (state/<id>.meta), one block per member in spawn order. Every key sits
# under member.<name>., so readers of the task's own worktree=, project=, and
# pr= lines never see them, and a relaunch preserves them unchanged:
#   member.<name>.project=    absolute member project directory
#   member.<name>.worktree=   absolute leased member worktree
#   member.<name>.role=       ref or edit
#   member.<name>.ref=        requested ref, empty for the default and for edit
#   member.<name>.commit=     commit a ref member was pinned at, or the base an
#                             edit member's branch started from
#   member.<name>.lease_id=   Treehouse lease identity
#   member.<name>.pool_root=  --root used for the lease; empty for Treehouse's
#                             default root
#   member.<name>.mode=       edit only: that repository's delivery mode
#   member.<name>.yolo=       edit only: that repository's merge posture
#   member.<name>.pr=         edit only: that repository's PR, recorded by
#   member.<name>.pr_head=    bin/fm-pr-check.sh, with the forge's head when
#                             available
# A task with edit members also records its own repository's PR as
# anchor_pr= and anchor_pr_head=, because its task-level pr= then names the PR
# currently in delivery, whichever repository that is (below).
#
# Delivery of edit members: every repository of the task - its own and each
# edit member - ships one PR (or, for local-only, one fm/<task-id> branch) and
# lands separately. Validation runs one repository at a time in land order, a
# consumer only after its provider has merged, so at most one PR of a task is
# open for delivery at a time. The task-level pr=/pr_head= therefore name the
# PR currently in delivery, and the merge poll, the merge helper, the merge
# authority, and the merge-notified marker keep binding to that one PR exactly
# as for a single-repository task. bin/fm-pr-check.sh resolves which repository
# a PR belongs to (fm_member_resolve_pr_repo), records it per repository, and
# moves pr= to another repository's PR only once the PR it named has merged or
# closed. Firstmate enforces the land order itself; nothing here orders
# repositories.
#
# Record lines travel between these functions as rows, one per line, whose
# fields are separated by FM_MEMBER_FS (the ASCII unit separator, which, unlike
# a tab, `read` never merges, so an empty ref or pool root keeps its column):
#   name  project  worktree  role  ref  commit  lease_id  pool_root  mode  yolo
# fm_member_records reads them from a task record; fm_member_meta_lines and
# fm_member_brief_section consume them on stdin. A reader naming fewer fields
# must end its field list with a catch-all variable. No field may hold a
# control character; fm_member_spec_parse and fm_member_value_safe refuse those.

# Several libraries source this one; a second source must not reset the
# globals a first caller is already using.
[ -z "${FM_TASK_MEMBERS_LIB_LOADED:-}" ] || return 0
FM_TASK_MEMBERS_LIB_LOADED=1

FM_MEMBER_FS=$'\037'

FM_MEMBER_SPEC_NAME=
FM_MEMBER_SPEC_PROJECT=
FM_MEMBER_SPEC_ROLE=
FM_MEMBER_SPEC_REF=
FM_MEMBER_ERROR=
FM_MEMBER_LEASE_PATH=
FM_MEMBER_LEASE_ID=
FM_MEMBER_PIN_COMMIT=
FM_MEMBER_MATCH_NAME=
FM_MEMBER_MATCH_WORKTREE=
FM_MEMBER_MATCH_PROJECT=
FM_MEMBER_MATCH_MODE=
FM_MEMBER_MATCH_YOLO=

# A record value is safe when it carries no control character, so it can
# neither split a row nor forge a record line.
fm_member_value_safe() {  # <value>
  case "$1" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

fm_member_name_valid() {  # <name>
  case "$1" in
    '' | *[!a-z0-9-]*) return 1 ;;
    [a-z]*) ;;
    *) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

# Parse one --member spec into FM_MEMBER_SPEC_{NAME,PROJECT,ROLE,REF}. The
# project is returned as given; the caller resolves it. Returns 1 and sets
# FM_MEMBER_ERROR on a malformed spec.
# shellcheck disable=SC2034 # FM_MEMBER_SPEC_* are read by the sourcing caller.
fm_member_spec_parse() {  # <spec>
  local spec=$1 rest
  FM_MEMBER_SPEC_NAME=
  FM_MEMBER_SPEC_PROJECT=
  FM_MEMBER_SPEC_ROLE=
  FM_MEMBER_SPEC_REF=
  FM_MEMBER_ERROR=
  if ! fm_member_value_safe "$spec"; then
    FM_MEMBER_ERROR="--member '$spec' contains a control character"
    return 1
  fi
  case "$spec" in
    *=*) ;;
    *)
      FM_MEMBER_ERROR="--member '$spec' is not <name>=<project-dir>:ref[@<ref>] or <name>=<project-dir>:edit"
      return 1
      ;;
  esac
  FM_MEMBER_SPEC_NAME=${spec%%=*}
  rest=${spec#*=}
  if ! fm_member_name_valid "$FM_MEMBER_SPEC_NAME"; then
    FM_MEMBER_ERROR="--member name '$FM_MEMBER_SPEC_NAME' must be 1-32 characters of a-z, 0-9, and -, starting with a letter"
    return 1
  fi
  case "$rest" in
    *:ref@*)
      FM_MEMBER_SPEC_ROLE=ref
      FM_MEMBER_SPEC_PROJECT=${rest%%:ref@*}
      FM_MEMBER_SPEC_REF=${rest#*:ref@}
      if [ -z "$FM_MEMBER_SPEC_REF" ]; then
        FM_MEMBER_ERROR="--member '$spec' names an empty ref after @"
        return 1
      fi
      ;;
    *:ref)
      FM_MEMBER_SPEC_ROLE=ref
      FM_MEMBER_SPEC_PROJECT=${rest%:ref}
      ;;
    *:edit@*)
      FM_MEMBER_ERROR="--member '$spec' gives an edit member a ref; an edit member always starts from its origin's default-branch tip"
      return 1
      ;;
    *:edit)
      FM_MEMBER_SPEC_ROLE=edit
      FM_MEMBER_SPEC_PROJECT=${rest%:edit}
      ;;
    *:*)
      FM_MEMBER_ERROR="--member '$spec' asks for role '${rest##*:}'; a member is ref or edit"
      return 1
      ;;
    *)
      FM_MEMBER_ERROR="--member '$spec' names no role; write <name>=<project-dir>:ref[@<ref>] or <name>=<project-dir>:edit"
      return 1
      ;;
  esac
  if [ -z "$FM_MEMBER_SPEC_PROJECT" ]; then
    FM_MEMBER_ERROR="--member '$spec' names no project directory"
    return 1
  fi
  case "$FM_MEMBER_SPEC_REF" in
    -*)
      FM_MEMBER_ERROR="--member '$spec' names a ref starting with -"
      return 1
      ;;
  esac
  return 0
}

# The pane variable that carries a member's path: FM_MEMBER_<NAME>.
fm_member_env_name() {  # <name>
  local upper
  upper=$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf 'FM_MEMBER_%s\n' "$upper"
}

# The Treehouse lease holder for one task's members. The home hash keeps equal
# task ids in different homes apart.
fm_member_lease_holder() {  # <home> <task-id>
  local home hash
  home=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || home=$1
  hash=$(printf '%s' "$home" | git hash-object --stdin 2>/dev/null) || return 1
  printf 'fm-member:%s:%s\n' "${hash:0:12}" "$2"
}

# Print the task record's members as rows (header above), in record order.
fm_member_records() {  # <meta>
  local meta=$1 line key rest name field value names='' n
  local -a order=()
  [ -f "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      member.*.worktree=*)
        key=${line%%=*}
        rest=${key#member.}
        name=${rest%.worktree}
        case "$names" in
          *"|$name|"*) ;;
          *)
            names="$names|$name|"
            order+=("$name")
            ;;
        esac
        ;;
    esac
  done < "$meta"
  for n in "${order[@]+"${order[@]}"}"; do
    printf '%s' "$n"
    for field in project worktree role ref commit lease_id pool_root mode yolo; do
      value=$(fm_member_meta_field "$meta" "$n" "$field")
      printf '%s%s' "$FM_MEMBER_FS" "$value"
    done
    printf '\n'
  done
}

# The task record's edit members only, as rows.
fm_member_edit_records() {  # <meta>
  local row name project wt role rest
  while IFS= read -r row; do
    IFS=$FM_MEMBER_FS read -r name project wt role rest <<<"$row"
    [ -n "$name" ] && [ "$role" = edit ] || continue
    printf '%s\n' "$row"
  done < <(fm_member_records "$1")
}

# 0 when the task record holds at least one edit member.
fm_member_has_edit() {  # <meta>
  [ -n "$(fm_member_edit_records "$1")" ]
}

# One member field from a task record (last occurrence wins, like fm_meta_get).
fm_member_meta_field() {  # <meta> <name> <field>
  local meta=$1 key="member.$2.$3" line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$meta"
  printf '%s' "$value"
}

# Rows on stdin -> the task-record lines that describe them.
fm_member_meta_lines() {
  local name project worktree role ref commit lease_id pool_root mode yolo
  while IFS=$FM_MEMBER_FS read -r name project worktree role ref commit lease_id pool_root mode yolo; do
    [ -n "$name" ] || continue
    printf 'member.%s.project=%s\n' "$name" "$project"
    printf 'member.%s.worktree=%s\n' "$name" "$worktree"
    printf 'member.%s.role=%s\n' "$name" "$role"
    printf 'member.%s.ref=%s\n' "$name" "$ref"
    printf 'member.%s.commit=%s\n' "$name" "$commit"
    printf 'member.%s.lease_id=%s\n' "$name" "$lease_id"
    printf 'member.%s.pool_root=%s\n' "$name" "$pool_root"
    if [ "$role" = edit ]; then
      printf 'member.%s.mode=%s\n' "$name" "$mode"
      printf 'member.%s.yolo=%s\n' "$name" "$yolo"
    fi
  done
}

# Rows on stdin -> the launch brief sections that show the worker its members.
# Prints nothing when there are no rows. The edit section extends the brief's
# own Definition of done to every repository; bin/fm-spawn.sh appends the
# Definition of done for any edit member mode the task's own mode does not
# already cover (bin/fm-dod-lib.sh fm_dod_member_block).
# shellcheck disable=SC2016 # Backticks are Markdown for the worker to read.
fm_member_brief_section() {  # <task-id>
  local id=$1 name project worktree role ref commit lease_id pool_root mode yolo env pinned
  local ref_lines='' edit_lines=''
  while IFS=$FM_MEMBER_FS read -r name project worktree role ref commit lease_id pool_root mode yolo; do
    [ -n "$name" ] || continue
    env=$(fm_member_env_name "$name")
    if [ "$role" = edit ]; then
      # shellcheck disable=SC2016 # A literal $NAME for the worker to read.
      edit_lines="$edit_lines$(printf -- '- `%s`: %s (`$%s`), a copy of %s, on branch `fm/%s` from %s, delivery mode=%s' \
        "$name" "$worktree" "$env" "$project" "$id" "$commit" "$mode")"$'\n'
      continue
    fi
    if [ -n "$ref" ]; then
      pinned="$ref at $commit"
    else
      pinned="default branch at $commit"
    fi
    # shellcheck disable=SC2016 # A literal $NAME for the worker to read.
    ref_lines="$ref_lines$(printf -- '- `%s`: %s (`$%s`), a copy of %s, %s' "$name" "$worktree" "$env" "$project" "$pinned")"$'\n'
  done
  if [ -n "$edit_lines" ]; then
    printf '\n# Edit worktrees\n'
    printf 'This task changes several repositories: your own worktree and each edit worktree below is a separate repository with its own branch `fm/%s`, its own delivery, and its own PR.\n' "$id"
    printf 'Spawn already created that branch in each edit worktree from the commit shown; commit there only on it, and never on a default branch.\n'
    printf 'Rule 2 covers them: modify only your own worktree and these edit worktrees.\n\n'
    printf '%s' "$edit_lines"
    printf '\nDeliver the repositories one at a time, in the land order firstmate gives you: a repository that relies on another is validated only after the PR of the repository it relies on has merged, so never run more than one no-mistakes validation for this task at once.\n'
    printf 'Keep changes to anything another repository relies on additive (new endpoints, optional parameters) so each PR is safe to land alone.\n'
    printf 'Deliver each repository by the Definition of done for its delivery mode, working from inside that repository'"'"'s worktree; where it says you are finished, that repository is finished, not the task.\n'
    printf 'In a no-mistakes repository, run `no-mistakes doctor` first and `no-mistakes init` if it reports the repository is not initialized.\n'
    printf 'Name exactly one repository in each `done:` line: its PR URL, or, for a local-only repository and for any repository whose PR does not exist yet (such as the no-mistakes handoff), start the line `ready in branch fm/%s of <name>` using the name above; your own worktree has no name, so a done line naming no repository is about your own.\n' "$id"
    printf 'After each repository'"'"'s done line, append `paused [at=<epoch>]: waiting for <repository> to merge` and stop; firstmate relays the merge and tells you which repository comes next.\n'
    printf 'Before validating the next repository, rebase its branch onto its updated default branch and regenerate any checked-in generated code against what merged, then commit.\n'
  fi
  if [ -n "$ref_lines" ]; then
    printf '\n# Reference worktrees\n'
    printf 'Besides your own worktree, this task holds read-only copies of other repositories, each pinned at the commit shown.\n'
    printf 'Read them freely by path; never edit, commit in, push from, or check out another ref in them, and never run their project tooling in a way that writes into them.\n'
    printf 'Rule 2 still binds every change you make: modify only your own worktree%s.\n' "${edit_lines:+ and your edit worktrees}"
    printf 'Treat a reference repository as a contract: rely on the behavior and API it defines, never on its internal code, and keep changes to anything another repository relies on additive (new endpoints, optional parameters) so each repository stays safe to land alone.\n'
    printf 'Each repository'"'"'s own AGENTS.md or CLAUDE.md, when present, describes how to read it.\n'
    printf 'They are cleanup-owned scratch: anything left in them is discarded when this task is cleaned up.\n\n'
    printf '%s' "$ref_lines"
  fi
}

# The host/path identity of <dir>'s origin remote, lower-cased and without a
# trailing .git or slash, or nothing when there is no origin or its URL is not
# a network URL. Accepts https, http, ssh, and git URLs and the scp-like
# user@host:path form.
fm_member_origin_identity() {  # <dir>
  local url rest host path
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  case "$url" in
    https://* | http://* | ssh://* | git://* | git+ssh://*)
      rest=${url#*://}
      rest=${rest#*@}
      host=${rest%%/*}
      path=${rest#*/}
      [ "$path" != "$rest" ] || return 0
      host=${host%%:*}
      ;;
    *@*:*)
      rest=${url#*@}
      host=${rest%%:*}
      path=${rest#*:}
      ;;
    *) return 0 ;;
  esac
  path=${path%/}
  path=${path%.git}
  [ -n "$host" ] && [ -n "$path" ] || return 0
  printf '%s/%s\n' "$host" "$path" | tr '[:upper:]' '[:lower:]'
}

# Set FM_MEMBER_MATCH_* to the task's own repository.
# shellcheck disable=SC2034 # FM_MEMBER_MATCH_* are read by the sourcing caller.
fm_member_match_anchor() {  # <meta>
  FM_MEMBER_MATCH_NAME=
  FM_MEMBER_MATCH_WORKTREE=$(grep '^worktree=' "$1" 2>/dev/null | tail -1 | cut -d= -f2-)
  FM_MEMBER_MATCH_PROJECT=$(grep '^project=' "$1" 2>/dev/null | tail -1 | cut -d= -f2-)
  FM_MEMBER_MATCH_MODE=$(grep '^mode=' "$1" 2>/dev/null | tail -1 | cut -d= -f2-)
  FM_MEMBER_MATCH_YOLO=$(grep '^yolo=' "$1" 2>/dev/null | tail -1 | cut -d= -f2-)
}

# Set FM_MEMBER_MATCH_* to edit member <name>; 1 when it is not one.
# shellcheck disable=SC2034 # FM_MEMBER_MATCH_* are read by the sourcing caller.
fm_member_match_edit() {  # <meta> <name>
  local row name project wt mode yolo
  while IFS= read -r row; do
    IFS=$FM_MEMBER_FS read -r name project wt _ _ _ _ _ mode yolo <<<"$row"
    [ "$name" = "$2" ] || continue
    FM_MEMBER_MATCH_NAME=$name
    FM_MEMBER_MATCH_WORKTREE=$wt
    FM_MEMBER_MATCH_PROJECT=$project
    FM_MEMBER_MATCH_MODE=$mode
    FM_MEMBER_MATCH_YOLO=$yolo
    return 0
  done < <(fm_member_edit_records "$1")
  return 1
}

# Which repository of a task a PR at <host>/<path> belongs to: the task's own
# (FM_MEMBER_MATCH_NAME empty) or an edit member, matched by origin identity.
# Sets FM_MEMBER_MATCH_{NAME,WORKTREE,PROJECT,MODE,YOLO}; returns 1 with
# FM_MEMBER_ERROR when no repository of the task has that origin. A PR is
# matched against every repository the task delivers, never a ref member.
fm_member_resolve_pr_repo() {  # <meta> <host> <path>
  local meta=$1 want row name project rest
  FM_MEMBER_ERROR=
  want=$(printf '%s/%s' "$2" "$3" | tr '[:upper:]' '[:lower:]')
  fm_member_match_anchor "$meta"
  if [ -n "$FM_MEMBER_MATCH_PROJECT" ] && [ "$(fm_member_origin_identity "$FM_MEMBER_MATCH_PROJECT")" = "$want" ]; then
    return 0
  fi
  while IFS= read -r row; do
    IFS=$FM_MEMBER_FS read -r name project rest <<<"$row"
    [ -n "$project" ] || continue
    if [ "$(fm_member_origin_identity "$project")" = "$want" ]; then
      fm_member_match_edit "$meta" "$name"
      return
    fi
  done < <(fm_member_edit_records "$meta")
  FM_MEMBER_ERROR="$2/$3 is not the origin of this task's own repository or of any of its edit members"
  return 1
}

# Which repository of a task a `done:` note names: the repository of the PR
# URL it reports, or the edit member named by a
# `ready in branch fm/<id> of <name>` note - a local-only repository's ready
# line, or any repository's done line before its PR exists, such as the
# no-mistakes pipeline handoff. Returns 1 when the note names no repository of
# the task, leaving the caller on the task's own repository.
# The caller has sourced bin/fm-pr-lib.sh, whose URL parser this uses in a
# subshell, so the caller's own parsed PR globals stay intact; it is not
# sourced here because sourcing it resets them too.
fm_member_resolve_done_note() {  # <meta> <note>
  local meta=$1 note=$2 url name host_path
  case "$note" in
    PR\ https://* | PR\ http://*)
      url=${note#PR }
      url=${url%% *}
      host_path=$(fm_pr_url_parse "$url" && printf '%s\n%s' "$FM_PR_HOST" "$FM_PR_PATH") || return 1
      fm_member_resolve_pr_repo "$meta" "${host_path%%$'\n'*}" "${host_path#*$'\n'}"
      return
      ;;
    *"ready in branch fm/"*" of "*)
      # A branch name holds no space, so the first " of " after it starts the
      # name, whatever the rest of the note says.
      name=${note#*ready in branch fm/}
      name=${name#* of }
      name=${name%%[!a-z0-9-]*}
      fm_member_name_valid "$name" || return 1
      fm_member_match_edit "$meta" "$name"
      return
      ;;
  esac
  return 1
}

# Lease one member slot from <project>'s pool. Sets FM_MEMBER_LEASE_PATH and
# FM_MEMBER_LEASE_ID; returns 1 with Treehouse's own words in FM_MEMBER_ERROR.
fm_member_lease() {  # <project> <pool-root-or-empty> <holder>
  local project=$1 root=$2 holder=$3 out json rc=0
  FM_MEMBER_LEASE_PATH=
  FM_MEMBER_LEASE_ID=
  FM_MEMBER_ERROR=
  if [ -n "$root" ]; then
    out=$(cd "$project" 2>/dev/null && treehouse --root "$root" get --lease --lease-holder "$holder" --json 2>&1) || rc=$?
  else
    out=$(cd "$project" 2>/dev/null && treehouse get --lease --lease-holder "$holder" --json 2>&1) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    FM_MEMBER_ERROR="treehouse could not lease a copy of $project: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    return 1
  fi
  # Treehouse writes its progress lines beside the one JSON line.
  json=$(printf '%s\n' "$out" | grep '^{' | tail -n 1)
  FM_MEMBER_LEASE_PATH=$(printf '%s\n' "$json" | jq -r '.path // empty' 2>/dev/null)
  FM_MEMBER_LEASE_ID=$(printf '%s\n' "$json" | jq -r '.lease_id // empty' 2>/dev/null)
  if [ -z "$FM_MEMBER_LEASE_PATH" ] || [ -z "$FM_MEMBER_LEASE_ID" ] \
     || ! fm_member_value_safe "$FM_MEMBER_LEASE_PATH" || ! fm_member_value_safe "$FM_MEMBER_LEASE_ID"; then
    FM_MEMBER_ERROR="treehouse leased a copy of $project but reported no usable path and lease id: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    return 1
  fi
  return 0
}

# Pin a clean member copy at <ref> (detached). When the copy has an origin,
# <ref> resolves first to what origin has now (its just-refreshed remote branch,
# then a fetch of <ref>), because pooled copies share local branches that may
# lag origin; a local lookup serves only what origin cannot supply. An empty
# <ref> keeps the copy's current HEAD, which the caller has already refreshed to
# origin's default-branch tip. Sets FM_MEMBER_PIN_COMMIT; returns 1 with
# FM_MEMBER_ERROR.
fm_member_pin() {  # <worktree> <ref>
  local worktree=$1 ref=$2 commit='' actual
  FM_MEMBER_PIN_COMMIT=
  FM_MEMBER_ERROR=
  if [ -z "$ref" ]; then
    commit=$(git -C "$worktree" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || commit=
  else
    if git -C "$worktree" remote get-url origin >/dev/null 2>&1; then
      commit=$(git -C "$worktree" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}" 2>/dev/null) || commit=
      if [ -z "$commit" ] && git -C "$worktree" fetch --quiet origin "$ref" >/dev/null 2>&1; then
        commit=$(git -C "$worktree" rev-parse --verify --quiet 'FETCH_HEAD^{commit}' 2>/dev/null) || commit=
      fi
    fi
    if [ -z "$commit" ]; then
      commit=$(git -C "$worktree" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null) || commit=
    fi
  fi
  if [ -z "$commit" ]; then
    FM_MEMBER_ERROR="ref '${ref:-HEAD}' does not name a commit in $worktree or on its origin"
    return 1
  fi
  if ! git -C "$worktree" checkout --quiet --detach "$commit" >/dev/null 2>&1; then
    FM_MEMBER_ERROR="could not check out $commit in $worktree"
    return 1
  fi
  actual=$(git -C "$worktree" rev-parse --verify --quiet HEAD 2>/dev/null) || actual=
  if [ "$actual" != "$commit" ]; then
    FM_MEMBER_ERROR="$worktree is at '${actual:-unknown}', not the pinned $commit"
    return 1
  fi
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_MEMBER_PIN_COMMIT=$commit
}

# Start an edit member's branch fm/<task-id> at the copy's current commit. A
# branch of that name already in the member's clone may hold another task's
# or an earlier incarnation's commits, so it refuses rather than reusing it.
# Sets FM_MEMBER_PIN_COMMIT to the base; returns 1 with FM_MEMBER_ERROR.
fm_member_branch_start() {  # <worktree> <task-id>
  local worktree=$1 branch="fm/$2" base actual
  FM_MEMBER_PIN_COMMIT=
  FM_MEMBER_ERROR=
  base=$(git -C "$worktree" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || base=
  if [ -z "$base" ]; then
    FM_MEMBER_ERROR="$worktree has no commit to start branch $branch from"
    return 1
  fi
  if git -C "$worktree" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    FM_MEMBER_ERROR="branch $branch already exists in the clone of $worktree; it may hold other work, so an edit member never reuses it"
    return 1
  fi
  if ! git -C "$worktree" checkout --quiet -b "$branch" "$base" >/dev/null 2>&1; then
    FM_MEMBER_ERROR="could not create branch $branch in $worktree"
    return 1
  fi
  actual=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null) || actual=
  if [ "$actual" != "$branch" ]; then
    FM_MEMBER_ERROR="$worktree is on '${actual:-a detached HEAD}', not the new $branch"
    return 1
  fi
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_MEMBER_PIN_COMMIT=$base
}

# Whether Treehouse still reports <lease-id> on <worktree>. Returns 0 when it
# does, 1 when the slot carries no lease or another one, and 2 when Treehouse's
# pool status could not be read at all (FM_MEMBER_ERROR says why).
fm_member_lease_state() {  # <project> <pool-root-or-empty> <worktree> <lease-id>
  local project=$1 root=$2 worktree=$3 lease_id=$4 out current rc=0
  FM_MEMBER_ERROR=
  if [ -n "$root" ]; then
    out=$(cd "$project" 2>/dev/null && treehouse --root "$root" status --json 2>/dev/null) || rc=$?
  else
    out=$(cd "$project" 2>/dev/null && treehouse status --json 2>/dev/null) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    FM_MEMBER_ERROR="treehouse could not report the pool of $project"
    return 2
  fi
  if ! current=$(printf '%s\n' "$out" | jq -r --arg p "$worktree" \
      '[.[]? | select(.path == $p)] | first | (.lease_id // "")' 2>/dev/null); then
    FM_MEMBER_ERROR="treehouse reported an unreadable pool status for $project"
    return 2
  fi
  [ "$current" = null ] && current=
  [ -n "$lease_id" ] && [ "$current" = "$lease_id" ]
}

# Return one member slot to its pool, but only while it still carries this
# task's lease. Treehouse resolves the pool from the copy's own path.
fm_member_return() {  # <project> <worktree> <lease-id>
  local project=$1 worktree=$2 lease_id=$3 out
  FM_MEMBER_ERROR=
  if out=$(cd "$project" 2>/dev/null && treehouse return --force --if-lease-id "$lease_id" "$worktree" 2>&1); then
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_MEMBER_ERROR=$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')
  return 1
}
