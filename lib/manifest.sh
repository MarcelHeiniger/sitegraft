#!/usr/bin/env bash
# lib/manifest.sh — pure functions to build, validate, and freeze the run manifest.
# All functions take/return JSON on stdin-less args/stdout so they are trivially
# testable with bats — no filesystem or network access in this file (design doc §4).

manifest_new() {
  local site_a_url="$1" site_b_url="$2"
  jq -n \
    --arg a "$site_a_url" --arg b "$site_b_url" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      sitegraft_manifest_version: 1,
      frozen: false,
      created_at: $now,
      site_a: {url: $a},
      site_b: {url: $b},
      migrate: {},
      protect: {},
      clean: {enabled: false, post_types: []},
      options: {}
    }'
}

manifest_add_migrate() {
  local manifest="$1" module="$2" post_types_json="$3" option_keys_json="$4"
  echo "$manifest" | jq \
    --arg mod "$module" --argjson pt "$post_types_json" --argjson ok "$option_keys_json" \
    '.migrate[$mod] = {post_types: $pt, option_keys: $ok}'
}

manifest_add_protect() {
  local manifest="$1" module="$2" post_types_json="$3" tables_json="$4" option_keys_json="$5"
  echo "$manifest" | jq \
    --arg mod "$module" --argjson pt "$post_types_json" --argjson tb "$tables_json" --argjson ok "$option_keys_json" \
    '.protect[$mod] = {post_types: $pt, tables: $tb, option_keys: $ok}'
}

# Fails (exit 1) if any post_type/table/option_key appears in both migrate and
# protect (design doc §4 validation rules). Tolerant of a minimal/empty
# manifest — every field read below defaults to [] via the `?` optional
# chaining, so a manifest missing .migrate or .protect entirely still passes
# cleanly instead of erroring on a jq null-iteration.
manifest_validate() {
  local manifest="$1"
  local migrate_pt protect_pt migrate_ok protect_ok migrate_tb protect_tb
  local overlap_pt overlap_ok overlap_tb

  migrate_pt=$(echo "$manifest" | jq -c '[.migrate[]?.post_types[]?] | sort')
  protect_pt=$(echo "$manifest" | jq -c '[.protect[]?.post_types[]?] | sort')
  migrate_ok=$(echo "$manifest" | jq -c '[.migrate[]?.option_keys[]?] | sort')
  protect_ok=$(echo "$manifest" | jq -c '[.protect[]?.option_keys[]?] | sort')
  migrate_tb=$(echo "$manifest" | jq -c '[.migrate[]?.tables[]?] | sort')
  protect_tb=$(echo "$manifest" | jq -c '[.protect[]?.tables[]?] | sort')

  overlap_pt=$(jq -n --argjson a "$migrate_pt" --argjson b "$protect_pt" \
    '[$a[] as $x | select($b | index($x))] | length')
  overlap_ok=$(jq -n --argjson a "$migrate_ok" --argjson b "$protect_ok" \
    '[$a[] as $x | select($b | index($x))] | length')
  overlap_tb=$(jq -n --argjson a "$migrate_tb" --argjson b "$protect_tb" \
    '[$a[] as $x | select($b | index($x))] | length')

  local bad=false
  if [ "$overlap_pt" != "0" ]; then
    log_error "manifest invalid: ${overlap_pt} post_type(s) present in both migrate and protect"
    bad=true
  fi
  if [ "$overlap_ok" != "0" ]; then
    log_error "manifest invalid: ${overlap_ok} option_key(s) present in both migrate and protect"
    bad=true
  fi
  if [ "$overlap_tb" != "0" ]; then
    log_error "manifest invalid: ${overlap_tb} table(s) present in both migrate and protect"
    bad=true
  fi
  [ "$bad" = false ]
}

manifest_freeze() {
  local manifest="$1"
  manifest_validate "$manifest" || return 1
  echo "$manifest" | jq '.frozen = true'
}

# manifest_compute_unclaimed <manifest_json> <scan_b_json> — default-deny
# (design doc §3.6): every post_type present on B that isn't claimed by ANY
# module, migrate or protect, is added to protect._unclaimed. Pure and
# idempotent — safe to call more than once, and deliberately called exactly
# once by phase_plan, after the manifest's migrate/protect buckets have
# reached their FINAL state for the run (module defaults, the custom-code
# gate, stack resolution, and any interactive adjustment all happen first) —
# not from inside plan_defaults, where it would only ever see the module
# defaults and go stale the moment the operator adjusts a selection.
manifest_compute_unclaimed() {
  local manifest="$1" scan_b="$2"
  local claimed_pt all_pt unclaimed_pt
  claimed_pt=$(echo "$manifest" | jq -c '[.migrate[]?.post_types[]?, .protect[]?.post_types[]?] | unique')
  all_pt=$(echo "$scan_b" | jq -c '[.post_types[].name]')
  # Bug found via TDD against the plan's literal spec: `select(($claimed |
  # index(.)) | not)` looks right but isn't — the `|` into `index(.)` rebinds
  # `.` to $claimed itself before `index` ever sees it, so it always searches
  # $claimed for $claimed, never for the outer $all[] element. `$x` binds the
  # element explicitly so `index($x)` searches for the right thing.
  unclaimed_pt=$(jq -n --argjson all "$all_pt" --argjson claimed "$claimed_pt" \
    '[$all[] as $x | select(($claimed | index($x)) | not) | $x]')
  echo "$manifest" | jq --argjson u "$unclaimed_pt" \
    '.protect._unclaimed = {post_types: $u, tables: [], option_keys: [],
      note: "found on B, unclaimed by any module — protected by default-deny"}'
}
