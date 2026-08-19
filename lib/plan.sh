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

# _plan_confirm <prompt> — plain yes/no. gum if available, else a bare `read`
# defaulting to "no" (an unattended/non-interactive shell with no gum reads
# EOF on the `read`, which bash reports as a failing read — falls through to
# the [ "${ans:-n}" = "y" ] check, which is false; declining by default on an
# unanswerable prompt is the safe direction for every caller of this
# function).
_plan_confirm() {
  local prompt="$1"
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt"
  else
    local ans
    read -r -p "${prompt} [y/N] " ans
    [ "${ans:-n}" = "y" ]
  fi
}

# Deliberately a different, harder-to-trigger confirmation than _plan_confirm
# — design doc §12/§14: overwriting something already installed on B, or
# proceeding past the custom-code awareness gate, are heavier decisions than
# a plain yes/no and must never be one accidental keystroke away, let alone
# automatic.
_plan_confirm_strong() {
  local prompt="$1"
  if command -v gum >/dev/null 2>&1; then
    gum confirm --affirmative="Yes, I understand" --negative="Cancel" "$prompt"
  else
    local ans
    read -r -p "${prompt} Type YES (all caps) to confirm: " ans
    [ "$ans" = "YES" ]
  fi
}

# Presents a flat list of "module: item" toggles built from the manifest's
# migrate bucket and returns the subset the operator kept, one per line.
# gum first, fzf fallback, plain numbered-prompt fallback last.
_plan_prompt_items() {
  local items="$1" # newline-separated "module: item" strings
  if [ -z "$items" ]; then
    return 0
  fi
  if command -v gum >/dev/null 2>&1; then
    printf '%s\n' "$items" | gum choose --no-limit --selected.all
  elif command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$items" | fzf -m --bind 'ctrl-a:select-all'
  else
    log_warn "neither gum nor fzf found — falling back to a plain yes/no prompt per item"
    local line ans
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      read -r -p "Keep '${line}'? [Y/n] " ans
      case "${ans:-y}" in
        y|Y|'') printf '%s\n' "$line" ;;
      esac
    done <<< "$items"
  fi
}

# _plan_apply_selection <manifest_json> <kept_items> — pure(ish) half of
# selection handling, split out from plan_select_interactive specifically so
# it's unit-testable: given the manifest and the flat "module: item" list the
# operator decided to KEEP (one per line, exactly what _plan_prompt_items
# returns), rewrites every module's migrate.post_types/option_keys down to
# just the kept subset. An item is classified as a post_type or an
# option_key by checking which of the module's two original lists it came
# from — never by guessing from the string shape.
#
# v1 scope, same as the original plan's Task 2.3: only migrate items are
# touched here. Deselecting an item REMOVES it from migrate — it does not
# move it to protect. An operator who deselects something sitegraft would
# otherwise have migrated is left with that item in neither bucket for this
# run (manifest_validate accepts this, no conflict) rather than it being
# swept into protect, which the design's default-deny principle would
# arguably prefer. Documented as a known v1 gap, not silently shipped as if
# it were a non-issue — protect items (including `_unclaimed`, computed
# after this by phase_plan) stay visible-but-not-togglable here on purpose
# (design doc §3.6: lifting something out of the safe default should never
# be one accidental keystroke).
_plan_apply_selection() {
  local manifest="$1" kept="$2"
  local mod
  for mod in $(echo "$manifest" | jq -r '.migrate | keys[]'); do
    local mod_pt_list mod_kept_raw kept_pt kept_ok
    mod_pt_list=$(echo "$manifest" | jq -c --arg m "$mod" '.migrate[$m].post_types')
    mod_kept_raw=$(printf '%s\n' "$kept" | grep "^${mod}: " | sed "s/^${mod}: //")
    kept_pt=$(printf '%s\n' "$mod_kept_raw" | jq -R -s --argjson pt "$mod_pt_list" -c \
      'split("\n") | map(select(length > 0)) | map(select(. as $x | ($pt | index($x))))')
    kept_ok=$(printf '%s\n' "$mod_kept_raw" | jq -R -s --argjson pt "$mod_pt_list" -c \
      'split("\n") | map(select(length > 0)) | map(select(. as $x | ($pt | index($x)) | not))')
    manifest=$(echo "$manifest" | jq --arg m "$mod" --argjson pt "$kept_pt" --argjson ok "$kept_ok" \
      '.migrate[$m].post_types = $pt | .migrate[$m].option_keys = $ok')
  done
  echo "$manifest"
}

# plan_select_interactive <manifest_json> — fine-tunes the migrate selection
# at post_type/option_key granularity (design doc §6.2 step 6). The prompting
# half (this function) is genuinely not unit-testable — no TTY, no gum/fzf in
# CI — covered by the DDEV harness via the non-interactive
# SITEGRAFT_MANIFEST_PREFILLED path instead, same as the original plan's
# Task 2.3 documents. The selection-APPLICATION half is split out into
# _plan_apply_selection above precisely so that part isn't shipped untested.
plan_select_interactive() {
  local manifest="$1"
  local items kept
  items=$(echo "$manifest" | jq -r '.migrate | to_entries[] | .key as $m | (.value.post_types[]?, .value.option_keys[]? | "\($m): \(.)")')
  if [ -z "$items" ]; then
    echo "$manifest"
    return 0
  fi
  echo "Review the items sitegraft will MIGRATE from A onto B (space to toggle, enter to confirm):" >&2
  kept=$(_plan_prompt_items "$items")
  _plan_apply_selection "$manifest" "$kept"
}

phase_plan() {
  local profile="" run_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      *) log_error "unknown flag for plan: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "plan requires --profile <name>"; return 1; }
  profile_load "$profile"
  [ -n "$run_dir" ] || run_dir=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1)
  [ -n "$run_dir" ] || { log_error "no scan run found for profile ${profile} — run 'sitegraft scan' first"; return 1; }

  modules_discover
  plan_warn_scope_gaps "${run_dir}/scan-a.json" "${run_dir}/scan-b.json"

  local manifest
  manifest=$(plan_defaults "${run_dir}/scan-a.json" "${run_dir}/scan-b.json")

  if [ -n "${SITEGRAFT_MANIFEST_PREFILLED:-}" ]; then
    manifest=$(cat "$SITEGRAFT_MANIFEST_PREFILLED")
  else
    manifest=$(plan_select_interactive "$manifest")
  fi

  # design doc §3.6: default-deny — computed once, here, after the manifest
  # (whether built interactively above or supplied prefilled) has reached its
  # final migrate/protect state for this run, not inside plan_defaults where
  # it would only ever see the module defaults (see the Task 2.2 commit for
  # why that ordering is wrong).
  manifest=$(manifest_compute_unclaimed "$manifest" "$(cat "${run_dir}/scan-b.json")")

  if [ -z "${SITEGRAFT_MANIFEST_PREFILLED:-}" ]; then
    echo "$manifest" | jq -r '
      "migrate: " + ([.migrate | keys[]] | join(", ")),
      "protect: " + ([.protect | keys[]] | join(", "))
    ' >&2
    _plan_confirm "Freeze this manifest? Nothing outside migrate/protect above will ever be touched by graft." || {
      log_error "manifest not frozen — re-run 'sitegraft plan' when ready"
      return 1
    }
  fi

  manifest=$(manifest_freeze "$manifest") || { log_error "manifest failed validation — not frozen"; return 1; }
  # Recommended, matching phase_scan's own treatment of anything this tool
  # writes to the state dir (Task 1.5's M4 note): the manifest names every
  # module/post_type/option_key/table this run will touch, which is
  # information a shared/group-readable state dir shouldn't leak by default,
  # even though (unlike scan-*.json) it holds no raw option values. chmod
  # AFTER writing (not a umask change before it) — a umask change here would
  # leak out of this function for the rest of the process, the exact
  # subshell-scoping problem phase_scan's own M4 fix (lib/inventory.sh)
  # deliberately avoids.
  echo "$manifest" > "${run_dir}/manifest.json"
  chmod 600 "${run_dir}/manifest.json" 2>/dev/null || true
  log_info "manifest frozen: ${run_dir}/manifest.json"
}
