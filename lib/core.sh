#!/usr/bin/env bash
# lib/core.sh — shared helpers: logging, dependency checks, temp/trap, dry-run.
# Bash 3.2 compatible — no associative arrays, no mapfile.

SITEGRAFT_COLOR_RED=$'\033[0;31m'
SITEGRAFT_COLOR_YELLOW=$'\033[0;33m'
SITEGRAFT_COLOR_GREEN=$'\033[0;32m'
SITEGRAFT_COLOR_RESET=$'\033[0m'

log_info()  { printf '%s[info]%s %s\n'  "$SITEGRAFT_COLOR_GREEN"  "$SITEGRAFT_COLOR_RESET" "$1"; }
log_warn()  { printf '%s[warn]%s %s\n'  "$SITEGRAFT_COLOR_YELLOW" "$SITEGRAFT_COLOR_RESET" "$1" >&2; }
log_error() { printf '%s[error]%s %s\n' "$SITEGRAFT_COLOR_RED"    "$SITEGRAFT_COLOR_RESET" "$1" >&2; }

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "required command not found: ${cmd} (install it before running sitegraft)"
    return 1
  fi
}

is_dry_run() {
  [ "${SITEGRAFT_DRY_RUN:-0}" = "1" ]
}

run_or_echo() {
  if is_dry_run; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Registry of temp dirs to clean on exit. File-backed, not a shell variable
# (verified live, a real bug beyond the word-splitting one this was first
# meant to fix): sitegraft_mktemp_dir is always called as
# dir=$(sitegraft_mktemp_dir), and command substitution forks a subshell —
# any in-process variable that function's body set (e.g. appending to
# SITEGRAFT_TMP_DIRS) is invisible to the caller once that subshell exits,
# so a pure-variable registry never actually recorded anything. A file
# write is a real side effect that survives the subshell. One line per
# registered dir; newline-delimited (not read with word-splitting) so a
# path containing a space (legal on macOS, e.g. under "Application
# Support") is never torn apart and used to rm -rf the wrong thing.
#
# The registry file itself is created with mktemp, not a predictable
# "sitegraft.registry.$$" path (verified as a real risk on a Linux box with
# a world-writable /tmp: an attacker who can predict the PID-based name can
# pre-create the file — group/world-writable by default umask — and seed it
# with arbitrary paths that this process will later rm -rf as "cleanup").
# mktemp's random suffix plus its own 0600 default closes that.
#
# Created HERE, eagerly, at source time in the parent shell — NOT lazily
# inside sitegraft_register_tmp_dir on first use. A lazy create-if-empty
# check re-introduces the exact subshell problem the file-backed registry
# exists to solve: sitegraft_mktemp_dir is called as
# dir=$(sitegraft_mktemp_dir), a subshell, so a lazy assignment to
# SITEGRAFT_TMP_REGISTRY made *inside* that subshell (on the first call)
# never reaches the parent either — verified live: two separate
# dir=$(sitegraft_mktemp_dir) calls each created their own throwaway
# registry file that only the subshell ever saw, leaving the parent's
# SITEGRAFT_TMP_REGISTRY permanently empty and cleanup a no-op.
SITEGRAFT_TMP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/sitegraft.registry.XXXXXX")

sitegraft_register_tmp_dir() {
  printf '%s\n' "$1" >> "$SITEGRAFT_TMP_REGISTRY"
}

# sitegraft_cleanup — meant to be installed as `trap sitegraft_cleanup EXIT`
# by bin/sitegraft (the entrypoint), NOT here at source time (see the note
# above `require_cmd` at the top of this file's history, and the fix-pack
# commit that moved it — installing a trap as a side effect of sourcing a
# library clobbers whatever EXIT trap the *caller* already had, which
# includes bats' own per-test trap machinery: any bats test that fails
# after `load`-ing this file used to come out as "Executed 0 instead of
# expected 1 tests" with no `not ok` line, not a normal failure report).
#
# Capture the real exit status FIRST: this function runs as an EXIT trap,
# and its own last command's status would otherwise silently become the
# script's final exit status. The bug this specifically fixes (verified
# live, and the opposite of what an earlier draft of this comment claimed):
# a *stale* registered dir — one that no longer exists on disk for any
# reason — makes the loop's last evaluated command `[ -d "$dir" ] && rm -rf
# "$dir"` end on the FALSE branch (exit 1, since `&&` short-circuits before
# rm -rf ever runs), and without capturing $? first, that stray 1 replaced
# the exit status of an otherwise completely successful script — a correct,
# non-erroring run reported as a failure. Normal command/function failures
# (`return 1`, `exit N`, a failing command under set -e) were NOT the
# problem — verified live, both before and after this fix, those already
# propagated correctly regardless of this trap.
#
# Known bash 3.2 limitation this does NOT cover: a raw "unbound
# variable" parameter-expansion error under set -u reports $?=0 inside
# *any* EXIT trap regardless of what that trap does (verified: even a
# bare no-op trap masks it) — the shell's internal exit-status tracking
# for that one error class isn't visible to trap handlers on this bash
# version. The fix is to never let code reach an unguarded unbound
# reference in the first place (explicit arity/existence checks before
# dereferencing — see phase_scan's --profile and SITEGRAFT_STATE_DIR
# guards) rather than to try to recover it here.
#
# Also found via a genuinely discriminating mutation test (second review
# round, after the first M1 test was shown not to distinguish the fix
# from its absence — see tests/unit/test_core.bats): `local rc=$?; ...;
# return $rc` alone is not sufficient. bin/sitegraft runs under
# `set -euo pipefail`, which is inherited into this trap's execution
# context — if `rm -rf`/`rm -f` below ever fails for real (permissions,
# a read-only parent dir, anything), set -e aborts sitegraft_cleanup
# *at that point*, before `return $rc` is ever reached, and the failing
# cleanup command's own status becomes the reported exit code instead —
# discarding a genuinely successful run's real status 0 same as the bug
# this function exists to fix in the first place. `|| true` on each
# cleanup operation means a failure to remove something never aborts the
# function early, so `return $rc` is always reached.
sitegraft_cleanup() {
  local rc=$?
  local dir
  if [ -n "$SITEGRAFT_TMP_REGISTRY" ] && [ -f "$SITEGRAFT_TMP_REGISTRY" ]; then
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      # shellcheck disable=SC2015 # best-effort cleanup: the right-hand `true` is a deliberate no-op, so the classic A&&B||C footgun doesn't apply
      [ -d "$dir" ] && rm -rf "$dir" 2>/dev/null || true
    done < "$SITEGRAFT_TMP_REGISTRY"
    rm -f "$SITEGRAFT_TMP_REGISTRY" 2>/dev/null || true
  fi
  return $rc
}

# issue #109: `mktemp -d` used to go unchecked here. A full/read-only/
# missing TMPDIR makes it fail with $dir left empty, and — before this
# guard — the function carried straight on: `chmod 700 ""` (itself a
# no-op failure, silently discarded by nothing catching it), a genuinely
# empty string registered with sitegraft_register_tmp_dir (see that
# function's own header for why an empty entry there is harmless — the
# cleanup loop's `[ -n "$dir" ] || continue` skips it, verified live, no
# rm -rf on anything unintended), and `echo ""` handing the empty path
# back to the caller with $? = 0. Every caller treats this function's
# result as a real directory it can build a path under
# (`"$(sitegraft_mktemp_dir)/whatever"`), so a silent empty string became
# a bare `/whatever` — measured on lib/backup.sh's own stderr-capture
# caller (PR #105) as a redirect to `/stderr`, which fails on a read-only
# filesystem and reports a perfectly good table export as unreadable,
# with a raw filesystem path leaked into the message on top. Fixed at the
# source rather than patched at each call site: this function is a
# contract ("hand back a real, usable temp dir, or fail"), and a contract
# that can silently return garbage isn't one. Two callers still needed
# their own explicit check on top of this (lib/graft.sh's
# graft_integrity_gate and graft_verify_import_completeness) because both
# are invoked as the left side of `||` by their own callers — under
# bin/sitegraft's `set -euo pipefail`, that disables errexit for their
# entire call tree (verified live), so even a loud `return 1` here would
# otherwise be silently absorbed and execution would fall through to the
# same broken bare-path construction this fix exists to prevent.
sitegraft_mktemp_dir() {
  local dir
  if ! dir=$(mktemp -d "${TMPDIR:-/tmp}/sitegraft.XXXXXX"); then
    log_error "could not create a temp directory under ${TMPDIR:-/tmp} (mktemp -d failed — check it exists, is writable, and has free space)"
    return 1
  fi
  chmod 700 "$dir"
  sitegraft_register_tmp_dir "$dir"
  echo "$dir"
}
