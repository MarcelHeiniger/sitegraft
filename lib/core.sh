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
SITEGRAFT_TMP_REGISTRY="${TMPDIR:-/tmp}/sitegraft.registry.$$"

sitegraft_register_tmp_dir() {
  printf '%s\n' "$1" >> "$SITEGRAFT_TMP_REGISTRY"
}

sitegraft_cleanup() {
  # Capture the real exit status FIRST: this function runs as an EXIT trap,
  # and its own last command's status would otherwise silently become the
  # script's final exit status regardless of what actually failed —
  # verified live: without this, a `set -euo pipefail` script whose call
  # stack fails (function returns 1, explicit exit N, a failing command)
  # still exits 0. Every path below must end with `return $rc`.
  #
  # Known bash 3.2 limitation this does NOT cover: a raw "unbound
  # variable" parameter-expansion error under set -u reports $?=0 inside
  # *any* EXIT trap regardless of what that trap does (verified: even a
  # bare no-op trap masks it) — the shell's internal exit-status tracking
  # for that one error class isn't visible to trap handlers on this bash
  # version. The fix is to never let code reach an unguarded unbound
  # reference in the first place (explicit arity/existence checks before
  # dereferencing, e.g. phase_scan's --profile argument check) rather than
  # to try to recover it here.
  local rc=$?
  local dir
  if [ -f "$SITEGRAFT_TMP_REGISTRY" ]; then
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      [ -d "$dir" ] && rm -rf "$dir"
    done < "$SITEGRAFT_TMP_REGISTRY"
    rm -f "$SITEGRAFT_TMP_REGISTRY"
  fi
  return $rc
}
trap sitegraft_cleanup EXIT

sitegraft_mktemp_dir() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/sitegraft.XXXXXX")
  chmod 700 "$dir"
  sitegraft_register_tmp_dir "$dir"
  echo "$dir"
}
