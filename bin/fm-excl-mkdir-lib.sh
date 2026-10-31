#!/usr/bin/env bash
# fm-excl-mkdir-lib.sh - the single owner of "exactly one caller creates this
# directory", the primitive every mkdir-as-lock and mkdir-as-claim site uses.
#
# Sourced, never executed. uutils coreutils mkdir (the ubuntu-26.04 default) is
# not atomic under contention: concurrent `mkdir X` calls can all report
# success, so two claimants win the same sequence number or lock. GNU and BSD
# mkdir, and the mkdir(2) syscall itself, are exclusive.
#
#   fm_mkdir_exclusive <dir>
#       Creates <dir> (parent must exist) and returns 0 only for the one caller
#       that created it; non-zero when it already exists or cannot be created.
#       Honors the caller's umask, so `(umask 077; fm_mkdir_exclusive d)` makes
#       a private directory.
#
# Implementation choice, in order: plain mkdir unless `mkdir --version` reports
# uutils (GNU, BSD and busybox mkdir are exclusive); then GNU coreutils
# gnumkdir, which Ubuntu installs beside uutils; then perl's mkdir syscall as
# the last resort. Preferring gnumkdir keeps a uutils host free of a perl
# dependency and of a perl start per claim. The choice is made once when this
# library is sourced, in the sourcing shell, so the usual subshell call
# `(umask 077; fm_mkdir_exclusive d)` reuses it instead of probing again.

fm_mkdir_exclusive_select() {
  if ! mkdir --version 2>/dev/null | grep -qi 'uutils'; then
    FM_MKDIR_EXCLUSIVE_IMPL='mkdir'
  elif command -v gnumkdir >/dev/null 2>&1 \
    && gnumkdir --version 2>/dev/null | grep -q 'GNU coreutils'; then
    FM_MKDIR_EXCLUSIVE_IMPL=gnumkdir
  else
    FM_MKDIR_EXCLUSIVE_IMPL=perl
  fi
}

fm_mkdir_exclusive() {
  [ -n "${FM_MKDIR_EXCLUSIVE_IMPL:-}" ] || fm_mkdir_exclusive_select
  case "$FM_MKDIR_EXCLUSIVE_IMPL" in
    perl) perl -e 'mkdir($ARGV[0], 0777) or exit 1' -- "$1" ;;
    *) "$FM_MKDIR_EXCLUSIVE_IMPL" -- "$1" ;;
  esac
}

FM_MKDIR_EXCLUSIVE_IMPL=
fm_mkdir_exclusive_select
