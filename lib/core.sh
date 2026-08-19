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

# Registry of temp dirs to clean on exit — plain string, space-separated (bash 3.2).
SITEGRAFT_TMP_DIRS=""

sitegraft_cleanup() {
  local dir
  for dir in $SITEGRAFT_TMP_DIRS; do
    [ -d "$dir" ] && rm -rf "$dir"
  done
}
trap sitegraft_cleanup EXIT

sitegraft_mktemp_dir() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/sitegraft.XXXXXX")
  chmod 700 "$dir"
  SITEGRAFT_TMP_DIRS="${SITEGRAFT_TMP_DIRS} ${dir}"
  echo "$dir"
}
