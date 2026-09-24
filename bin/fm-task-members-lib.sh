#!/usr/bin/env bash
# Reference members: read-only worktrees of OTHER registered projects that a
# ship or scout task holds beside its own worktree, so a worker can read a
# contract, a specification, or a sibling repository at a pinned ref.
#
# This library is the single owner of the member contract: the --member spec,
# the durable lease identity, the task-record fields, the launch brief section,
# and the lease checks cleanup relies on. bin/fm-spawn.sh leases, pins, and
# publishes members; bin/fm-teardown.sh returns them. docs/configuration.md
# "Reference members" is the operator summary that points here.
#
# Spec (fm-spawn.sh --member, repeatable):
#   <name>=<project-dir>:ref[@<ref>]
#   <name>  1-32 characters of [a-z0-9-], starting with a letter; unique in the
#           task. The worker's pane receives FM_MEMBER_<NAME> (upper-cased, - as
#           _) holding the member's absolute path.
#   role    `ref` is the only role: read-only context the worker never modifies,
#           commits in, or pushes from. A member is never delivered; cleanup
#           discards anything left in it, exactly like a scout's scratch copy.
#   <ref>   optional branch, tag, commit, or fetchable ref such as
#           refs/pull/<n>/head. Absent means origin's current default-branch
#           tip, or the copy's own HEAD for a project with no origin.
#   A member is a clone this home already holds, other than the task's own
#   project; two members may not share one Treehouse project identity.
#
# Lease: a task's own worktree is held by the process running in its pane. A
# member has no such process - the worker reads it by path - so it is taken
# with `treehouse [--root <home pool root>] get --lease --lease-holder <holder>
# --json` from the member's clone, which Treehouse never hands to another get
# until that lease is returned. <holder> is fm-member:<home-hash>:<task-id>
# (fm_member_lease_holder). The slot also carries the ordinary slot-owner claim
# (bin/fm-wake-lib.sh), naming this task, so another task's stale record never
# resets it. Cleanup returns a member only while Treehouse still reports this
# task's exact lease id on it (fm_member_lease_state), so a slot this task no
# longer holds is never reset.
#
# Record (state/<id>.meta), one block per member in spawn order. Every key sits
# under member.<name>., so readers of the task's own worktree=, project=, and
# pr= lines never see them, and a relaunch preserves them unchanged:
#   member.<name>.project=    absolute member project directory
#   member.<name>.worktree=   absolute leased member worktree
#   member.<name>.role=ref
#   member.<name>.ref=        requested ref, empty for the default
#   member.<name>.commit=     commit the member was pinned at
#   member.<name>.lease_id=   Treehouse lease identity
#   member.<name>.pool_root=  --root used for the lease; empty for Treehouse's
#                             default root
#
# Record lines travel between these functions as rows, one per line, whose
# fields are separated by FM_MEMBER_FS (the ASCII unit separator, which, unlike
# a tab, `read` never merges, so an empty ref or pool root keeps its column):
#   name  project  worktree  role  ref  commit  lease_id  pool_root
# fm_member_records reads them from a task record; fm_member_meta_lines and
# fm_member_brief_section consume them on stdin. No field may hold a control
# character; fm_member_spec_parse and fm_member_value_safe refuse those.

FM_MEMBER_FS=$'\037'

FM_MEMBER_SPEC_NAME=
FM_MEMBER_SPEC_PROJECT=
FM_MEMBER_SPEC_ROLE=
FM_MEMBER_SPEC_REF=
FM_MEMBER_ERROR=
FM_MEMBER_LEASE_PATH=
FM_MEMBER_LEASE_ID=
FM_MEMBER_PIN_COMMIT=

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
      FM_MEMBER_ERROR="--member '$spec' is not <name>=<project-dir>:ref[@<ref>]"
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
      FM_MEMBER_SPEC_PROJECT=${rest%%:ref@*}
      FM_MEMBER_SPEC_REF=${rest#*:ref@}
      if [ -z "$FM_MEMBER_SPEC_REF" ]; then
        FM_MEMBER_ERROR="--member '$spec' names an empty ref after @"
        return 1
      fi
      ;;
    *:ref)
      FM_MEMBER_SPEC_PROJECT=${rest%:ref}
      ;;
    *:*)
      FM_MEMBER_ERROR="--member '$spec' asks for role '${rest##*:}'; only ref members are supported"
      return 1
      ;;
    *)
      FM_MEMBER_ERROR="--member '$spec' names no role; write <name>=<project-dir>:ref[@<ref>]"
      return 1
      ;;
  esac
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_MEMBER_SPEC_ROLE=ref
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
    for field in project worktree role ref commit lease_id pool_root; do
      value=$(fm_member_meta_field "$meta" "$n" "$field")
      printf '%s%s' "$FM_MEMBER_FS" "$value"
    done
    printf '\n'
  done
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
  local name project worktree role ref commit lease_id pool_root
  while IFS=$FM_MEMBER_FS read -r name project worktree role ref commit lease_id pool_root; do
    [ -n "$name" ] || continue
    printf 'member.%s.project=%s\n' "$name" "$project"
    printf 'member.%s.worktree=%s\n' "$name" "$worktree"
    printf 'member.%s.role=%s\n' "$name" "$role"
    printf 'member.%s.ref=%s\n' "$name" "$ref"
    printf 'member.%s.commit=%s\n' "$name" "$commit"
    printf 'member.%s.lease_id=%s\n' "$name" "$lease_id"
    printf 'member.%s.pool_root=%s\n' "$name" "$pool_root"
  done
}

# Rows on stdin -> the launch brief section that shows the worker its members.
# Prints nothing when there are no rows.
fm_member_brief_section() {
  local name project worktree role ref commit lease_id pool_root started=0 env pinned
  while IFS=$FM_MEMBER_FS read -r name project worktree role ref commit lease_id pool_root; do
    [ -n "$name" ] || continue
    if [ "$started" = 0 ]; then
      started=1
      printf '\n# Reference worktrees\n'
      printf 'Besides your own worktree, this task holds read-only copies of other repositories, each pinned at the commit shown.\n'
      printf 'Read them freely by path; never edit, commit in, push from, or check out another ref in them, and never run their project tooling in a way that writes into them.\n'
      printf 'Rule 2 still binds every change you make: modify only your own worktree.\n'
      printf 'Treat a reference repository as a contract: rely on the behavior and API it defines, never on its internal code, and keep changes to anything another repository relies on additive (new endpoints, optional parameters) so each repository stays safe to land alone.\n'
      printf 'Each repository'"'"'s own AGENTS.md or CLAUDE.md, when present, describes how to read it.\n'
      printf 'They are cleanup-owned scratch: anything left in them is discarded when this task is cleaned up.\n\n'
    fi
    env=$(fm_member_env_name "$name")
    if [ -n "$ref" ]; then
      pinned="$ref at $commit"
    else
      pinned="default branch at $commit"
    fi
    # shellcheck disable=SC2016 # A literal $NAME for the worker to read.
    printf -- '- `%s`: %s (`$%s`), a copy of %s, %s\n' "$name" "$worktree" "$env" "$project" "$pinned"
  done
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

# Pin a clean member copy at <ref> (detached), fetching it from origin when it
# is not already a local commit. An empty <ref> keeps the copy's current HEAD,
# which the caller has already refreshed to origin's default-branch tip. Sets
# FM_MEMBER_PIN_COMMIT; returns 1 with FM_MEMBER_ERROR.
fm_member_pin() {  # <worktree> <ref>
  local worktree=$1 ref=$2 commit='' actual
  FM_MEMBER_PIN_COMMIT=
  FM_MEMBER_ERROR=
  if [ -z "$ref" ]; then
    commit=$(git -C "$worktree" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || commit=
  else
    commit=$(git -C "$worktree" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null) \
      || commit=$(git -C "$worktree" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}" 2>/dev/null) \
      || commit=
    if [ -z "$commit" ] && git -C "$worktree" remote get-url origin >/dev/null 2>&1; then
      if git -C "$worktree" fetch --quiet origin "$ref" >/dev/null 2>&1; then
        commit=$(git -C "$worktree" rev-parse --verify --quiet 'FETCH_HEAD^{commit}' 2>/dev/null) || commit=
      fi
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
