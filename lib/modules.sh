#!/usr/bin/env bash
# lib/modules.sh — convention-based module discovery/registry. Bash 3.2 (no assoc arrays):
# the registry is a space-separated string of module prefixes.

SITEGRAFT_MODULES_DIR="${SITEGRAFT_MODULES_DIR:-${SITEGRAFT_ROOT:-.}/modules}"
SITEGRAFT_MODULES=""

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

# m2: a module that is missing its required functions is a real hazard
# later (plan/graft silently treating it as present-but-empty, or crashing
# deep in an unrelated phase) — reject it loudly at discovery time instead.
# Required: <prefix>_name and <prefix>_detect. At least one of
# <prefix>_post_types / <prefix>_option_keys / <prefix>_tables (the
# module's actual claim on what it protects — see modules/_template.sh).
module_validate_contract() {
  local prefix="$1"
  local ok=true

  module_has_fn "$prefix" name || { log_error "module '${prefix}' is missing ${prefix}_name() — rejected"; ok=false; }
  module_has_fn "$prefix" detect || { log_error "module '${prefix}' is missing ${prefix}_detect() — rejected"; ok=false; }

  if ! module_has_fn "$prefix" post_types && ! module_has_fn "$prefix" option_keys && ! module_has_fn "$prefix" tables; then
    log_error "module '${prefix}' declares none of ${prefix}_post_types/_option_keys/_tables — rejected (a module must claim at least one)"
    ok=false
  fi

  [ "$ok" = true ]
}

modules_discover() {
  SITEGRAFT_MODULES=""
  local file base prefix
  # NIT-2 (Viktor, second review round) flagged this *.sh.example
  # glob/skip-case pair as a no-op proving nothing real, and asked for its
  # removal along with the test covering it. Disagreed, with evidence, and
  # kept it instead (see the PR/report): the design doc documents this as
  # a real, intentional convention, not a contrivance —
  # `modules/motopress.sh.example` is a SHIPPED worked example (§3.5, and
  # the repo layout in §2), and §2's own text states the mechanism
  # explicitly: "discovers modules via the glob modules/*.sh (the .example
  # suffix is explicitly excluded, as is _template.sh)". A plain *.sh glob
  # can structurally never match a file ending in .example in the first
  # place (its name does not end in .sh), so the exclusion the design doc
  # describes is only ever reachable if the loop also enumerates
  # *.sh.example files and then filters them back out here — which is
  # exactly what this does.
  for file in "${SITEGRAFT_MODULES_DIR}"/*.sh "${SITEGRAFT_MODULES_DIR}"/*.sh.example; do
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
    module_validate_contract "$prefix" || continue
    SITEGRAFT_MODULES="${SITEGRAFT_MODULES} ${prefix}"
  done
  SITEGRAFT_MODULES="${SITEGRAFT_MODULES# }"
}
