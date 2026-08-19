#!/usr/bin/env bash
# lib/plan.sh — phase: plan. Builds default selections from module detection,
# warns on scope gaps (design doc §12/§13), gates on custom code found on B
# (§14), drives interactive stack resolution and adjustment, freezes the
# manifest.

# plan_defaults <scan_a_json_path> <scan_b_json_path> — dispatches every
# discovered module against both scans (design doc §6.2 step 2-3): a module
# detected on A goes to migrate (with whatever post_types/option_keys/tables
# it declares); a module detected on B and NOT on A goes to protect instead.
# A module detected on both sites is only ever migrated — its content on B
# is expected to be replaced/merged by the graft, not separately protected.
# Not pure (reads scan files from disk and calls into the module registry),
# so tested directly with fabricated modules rather than as a jq one-liner —
# see tests/unit/test_plan.bats.
plan_defaults() {
  local scan_a_json="$1" scan_b_json="$2"
  local manifest
  manifest=$(manifest_new \
    "$(jq -r '.site_url // "unknown"' "$scan_a_json" 2>/dev/null || echo unknown)" \
    "$(jq -r '.site_url // "unknown"' "$scan_b_json" 2>/dev/null || echo unknown)")

  local mod
  for mod in $SITEGRAFT_MODULES; do
    if module_call "$mod" detect "$scan_a_json"; then
      local pt ok
      pt=$(module_has_fn "$mod" post_types && module_call "$mod" post_types | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
      ok=$(module_has_fn "$mod" option_keys && module_call "$mod" option_keys | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
      manifest=$(manifest_add_migrate "$manifest" "$mod" "$pt" "$ok")
    elif module_call "$mod" detect "$scan_b_json"; then
      local pt tb ok
      pt=$(module_has_fn "$mod" post_types && module_call "$mod" post_types | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
      tb=$(module_has_fn "$mod" tables && module_call "$mod" tables | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
      ok=$(module_has_fn "$mod" option_keys && module_call "$mod" option_keys | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
      manifest=$(manifest_add_protect "$manifest" "$mod" "$pt" "$tb" "$ok")
    fi
  done

  echo "$manifest"
}

# design doc §13 (review finding B2): plan only ever builds a manifest, it
# never touches B, so this is a warning, never a hard failure. The rendering-
# stack mismatch has its own, more useful per-component treatment now
# (plan_resolve_stack, Task 2.4) instead of being a separate blanket warning
# here — offering a fix beats restating that something doesn't match.
plan_warn_scope_gaps() {
  local scan_a_json="$1" scan_b_json="$2"
  if jq -e '.classic_menus_detected == true' "$scan_a_json" >/dev/null 2>&1; then
    log_warn "A has classic nav menu(s) with items ($(jq -r '.classic_menu_names | join(", ")' "$scan_a_json")) — sitegraft v1 does not migrate classic menu assignments (design doc §13). Migrate them by hand or write a module."
  fi
}
