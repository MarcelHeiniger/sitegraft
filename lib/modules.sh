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
# <prefix>_post_types / <prefix>_option_keys / <prefix>_tables, or the
# `_dynamic` counterpart of any of them (the module's actual claim on what
# it protects — see modules/_template.sh and
# docs/decisions/0007-module-dynamic-selections.md).
#
# The `_dynamic` variants count as a claim in their own right: a module whose
# entire claim is computed from the scan (nothing static to list) is a
# legitimate module, and rejecting it here would have made the contract
# extension unusable for exactly the cases it exists for.
# `_option_keys_exclude` deliberately does NOT count — an exclusion narrows a
# claim, it never makes one.
module_validate_contract() {
  local prefix="$1"
  local ok=true

  module_has_fn "$prefix" name || { log_error "module '${prefix}' is missing ${prefix}_name() — rejected"; ok=false; }
  module_has_fn "$prefix" detect || { log_error "module '${prefix}' is missing ${prefix}_detect() — rejected"; ok=false; }

  local kind claims=false
  for kind in post_types option_keys tables; do
    if module_has_fn "$prefix" "$kind" || module_has_fn "$prefix" "${kind}_dynamic"; then
      claims=true
    fi
  done
  if [ "$claims" != true ]; then
    log_error "module '${prefix}' declares none of ${prefix}_post_types/_option_keys/_tables (or their _dynamic counterparts) — rejected (a module must claim at least one)"
    ok=false
  fi

  [ "$ok" = true ]
}

# _module_glob_match <subject> <patterns> — does $subject match any of the
# newline-separated shell globs in $patterns? Non-zero (no match) for an
# empty pattern list, which is the common case.
_module_glob_match() {
  local subject="$1" patterns="$2" pat
  [ -n "$patterns" ] || return 1
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254 # deliberate and load-bearing: $pat is a GLOB PATTERN supplied by <mod>_option_keys_exclude (design doc §3.2), so it MUST stay unquoted here for `case` to treat `*` as a wildcard. Quoting it would turn every exclusion into a literal-string comparison and silently stop carving license keys out of a prefix — the exact defect issue #13 is about.
    case "$subject" in
      $pat) return 0 ;;
    esac
  done <<< "$patterns"
  return 1
}

# module_selection <prefix> <kind> <scan_json> — THE single expansion point
# for a module's claim on one kind (`post_types`, `option_keys`, `tables`).
# Emits the effective list, one name per line, on stdout; returns non-zero,
# having emitted nothing, if the module could not produce it.
#
# The contract it implements (docs/decisions/0007-module-dynamic-selections.md):
#
#   1. `<prefix>_<kind>`                       — static list, optional.
#   2. `<prefix>_<kind>_dynamic <scan_json>`   — list computed from the scan
#      the caller is resolving this module against, optional. This is what
#      makes `theme_mods_<active-theme>` (issue #15) and "whatever post types
#      etch_cpts declares" (issue #16) expressible at all: both names are
#      only knowable after `scan`.
#   3. `<prefix>_option_keys_exclude`          — globs, applied to the union
#      of 1 and 2 when kind is `option_keys`. Issue #13: this was documented
#      as the way to carve a license key out of a broad prefix and nothing
#      ever called it, so a module author who trusted it shipped the secret.
#      It is called here, so it applies to static and dynamic keys alike.
#
# Fail closed, at every step. "This module claims nothing here" and "this
# module could not tell me what it claims" are different answers and must not
# come out of this function the same way (CLAUDE.md: a check must distinguish
# "verified true" from "could not verify"). A dynamic function that exits
# non-zero aborts the whole plan rather than contributing an empty list —
# an empty list is a legitimate answer only when the module returned it
# deliberately, with exit 0.
#
# A failing `_option_keys_exclude` is treated exactly as hard: continuing
# with the unfiltered union would migrate precisely the keys the module
# asked to keep back.
module_selection() {
  local prefix="$1" kind="$2" scan_json="$3"
  local static_lines="" dynamic_lines="" exclude_lines="" rc

  if module_has_fn "$prefix" "$kind"; then
    if ! static_lines=$("${prefix}_${kind}"); then
      rc=$?
      log_error "module '${prefix}': ${prefix}_${kind}() exited ${rc} — refusing to build a plan from a claim this module could not produce (an error is not an empty list)"
      return 1
    fi
  fi

  if module_has_fn "$prefix" "${kind}_dynamic"; then
    if ! dynamic_lines=$("${prefix}_${kind}_dynamic" "$scan_json"); then
      rc=$?
      log_error "module '${prefix}': ${prefix}_${kind}_dynamic() exited ${rc} against ${scan_json} — refusing to continue with an incomplete ${kind} selection (an error is not an empty list). Fix the module, re-run 'sitegraft scan' if the scan is stale, or drive this run from a SITEGRAFT_MANIFEST_PREFILLED manifest."
      return 1
    fi
  fi

  if [ "$kind" = "option_keys" ] && module_has_fn "$prefix" option_keys_exclude; then
    if ! exclude_lines=$("${prefix}_option_keys_exclude"); then
      rc=$?
      log_error "module '${prefix}': ${prefix}_option_keys_exclude() exited ${rc} — refusing to migrate this module's option keys unfiltered, since the exclusions are exactly what keeps license/secret keys out"
      return 1
    fi
  fi

  local combined nl seen="" out="" line
  nl=$'\n'
  combined=$(printf '%s\n%s\n' "$static_lines" "$dynamic_lines")
  seen="$nl"

  # fd 3, not stdin: this loop's body must leave fd 0 alone (the same
  # discipline _plan_prompt_items already follows in lib/plan.sh), and a
  # here-STRING rather than a here-doc so nothing in a module's output is
  # ever re-expanded by the shell.
  while IFS= read -r line <&3; do
    [ -n "$line" ] || continue
    # Names travel onward through a comma-joined `--post_type=` CSV
    # (graft_export_wxr) and through unquoted `for key in $(...)` word
    # splitting (graft_migrate_options). A name containing a comma or
    # whitespace cannot survive either — it would silently become two
    # wrong names. That is a bug in the module, so it is reported as one
    # instead of being dropped quietly.
    case "$line" in
      *,*|*[[:space:]]*)
        log_error "module '${prefix}': ${kind} entry '${line}' contains a comma or whitespace — rejected (such a name cannot survive graft's post-type CSV or option-key word splitting, and would silently be read as two different names)"
        return 1
        ;;
    esac
    case "$seen" in
      *"${nl}${line}${nl}"*) continue ;;
    esac
    seen="${seen}${line}${nl}"
    if [ "$kind" = "option_keys" ] && _module_glob_match "$line" "$exclude_lines"; then
      continue
    fi
    out="${out}${line}${nl}"
  done 3<<< "$combined"

  printf '%s' "$out"
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
