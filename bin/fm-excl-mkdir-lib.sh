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
#       a private directory. Uses perl's mkdir syscall only when
#       `mkdir --version` reports uutils (the one known non-exclusive mkdir);
#       GNU, BSD and busybox mkdir are exclusive and keep the remote worker
#       free of a perl dependency. The choice is made once per shell.

fm_mkdir_exclusive() {
  if [ -z "${FM_MKDIR_EXCLUSIVE_IMPL:-}" ]; then
    if mkdir --version 2>/dev/null | grep -qi 'uutils'; then
      FM_MKDIR_EXCLUSIVE_IMPL=perl
    else
      FM_MKDIR_EXCLUSIVE_IMPL='mkdir'
    fi
  fi
  if [ "$FM_MKDIR_EXCLUSIVE_IMPL" = mkdir ]; then
    mkdir -- "$1"
  else
    perl -e 'mkdir($ARGV[0], 0777) or exit 1' -- "$1"
  fi
}
