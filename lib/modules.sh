#!/usr/bin/env bash
# lib/modules.sh — convention-based module discovery/registry. Bash 3.2 (no assoc arrays):
# the registry is a space-separated string of module prefixes.

SITEGRAFT_MODULES_DIR="${SITEGRAFT_MODULES_DIR:-${SITEGRAFT_ROOT:-.}/modules}"
SITEGRAFT_MODULES=""

modules_discover() {
  SITEGRAFT_MODULES=""
  local file base prefix
  for file in "${SITEGRAFT_MODULES_DIR}"/*.sh; do
    [ -e "$file" ] || continue
    base="$(basename "$file")"
    case "$base" in
      _template.sh) continue ;;
      *.example) continue ;;
    esac
    prefix="${base%.sh}"
    prefix="${prefix//-/_}"
    # shellcheck disable=SC1090
    . "$file"
    SITEGRAFT_MODULES="${SITEGRAFT_MODULES} ${prefix}"
  done
  SITEGRAFT_MODULES="${SITEGRAFT_MODULES# }"
}

module_has_fn() {
  local prefix="$1" suffix="$2"
  type -t "${prefix}_${suffix}" >/dev/null 2>&1
}

module_call() {
  local prefix="$1" suffix="$2"
  shift 2
  module_has_fn "$prefix" "$suffix" || return 1
  "${prefix}_${suffix}" "$@"
}
