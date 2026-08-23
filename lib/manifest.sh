#!/usr/bin/env bash
# lib/manifest.sh — pure functions to build, validate, and freeze the run manifest.
# All functions take/return JSON on stdin-less args/stdout so they are trivially
# testable with bats — no filesystem or network access in this file (design doc §4).
#
# `sitegraft_manifest_version` (nit, Kimi's review of PR #2): the manifest
# JSON SCHEMA's own version, independent of SITEGRAFT_VERSION (bin/sitegraft
# — the tool's own release version, bumped on every user-visible behavior
# change per CLAUDE.md). This one is bumped only when the FORMAT of
# manifest.json itself changes in a way an older reader (a `graft` from a
# previous release, or a hand-inspecting operator) couldn't parse correctly
# — new optional keys with safe defaults (like `profile`/aliases/
# `options.search_replace`, added in this fix-pack) don't need a bump; a
# renamed or restructured key would. Currently 1, unbumped since Task 2.1.

# manifest_new <site_a_url> <site_b_url> [profile] [alias_a] [alias_b] — the
# three bracketed args are new in this fix-pack (MINOR, PR #2 review:
# design doc §4's manifest shows `profile`, `site_a.alias`/`site_b.alias`,
# and `options.search_replace`, none of which the original schema here
# actually produced). All three default to values that keep every existing
# 2-arg call site (plan_defaults, and every bats test written against the
# original 2-arg signature) working unchanged: profile defaults to "",
# alias_a/alias_b default to "a"/"b" (the same hardcoded fallback wp_remote
# and lib/profile.sh already use everywhere an alias isn't explicitly
# known). `options.search_replace` needs no extra parameter at all — it's
# exactly the {from, to} domain remap graft §9.4 needs, fully derivable from
# the two URLs this function already receives.
manifest_new() {
  local site_a_url="$1" site_b_url="$2" profile="${3:-}" alias_a="${4:-a}" alias_b="${5:-b}"
  jq -n \
    --arg a "$site_a_url" --arg b "$site_b_url" \
    --arg profile "$profile" --arg alias_a "$alias_a" --arg alias_b "$alias_b" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      sitegraft_manifest_version: 1,
      profile: $profile,
      frozen: false,
      created_at: $now,
      site_a: {url: $a, alias: $alias_a},
      site_b: {url: $b, alias: $alias_b},
      migrate: {},
      protect: {},
      clean: {enabled: false, post_types: []},
      options: {search_replace: {from: $a, to: $b}}
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
# (design doc §3.6): every post_type AND option_key present on B that isn't
# claimed by ANY module, migrate or protect, is added to protect._unclaimed.
# Pure and idempotent — safe to call more than once, and deliberately called
# exactly once by phase_plan, after the manifest's migrate/protect buckets
# have reached their FINAL state for the run (module defaults, the
# custom-code gate, stack resolution, and any interactive adjustment all
# happen first) — not from inside plan_defaults, where it would only ever
# see the module defaults and go stale the moment the operator adjusts a
# selection.
#
# `tables` is deliberately left `[]` here — a MINOR review finding on PR #2
# (Viktor) flagged this as a design/impl gap (§3.6 says "post_type, table, OR
# option key"), considered and NOT extended in this fix-pack, for two
# stacked reasons, not one:
#  1. Module-declared tables are SUFFIXES ("fakebooking_reservations"), never
#     the live-prefixed name scan-b.json's `.tables` actually holds
#     ("wp_fakebooking_reservations") — matching them correctly needs either
#     the live table prefix (a wp-cli round-trip this function, and `plan`
#     as a phase, deliberately never makes — see design doc §6.2's title,
#     "writes only locally", which has always implicitly meant reads too:
#     every other plan_* function in lib/plan.sh works only from already-
#     scanned JSON on disk) or an `endswith($suffix)` heuristic, which is
#     resolvable without a live call but only solves the STRING-matching
#     half of the problem.
#  2. The harder half endswith-matching does NOT solve: no `core-wp` module
#     exists yet (that's Step 4, Task 4.1) to claim WordPress's OWN tables
#     (wp_posts, wp_options, wp_users, ...) as "core, handled via WXR/
#     options, not the table-copy path" — so a naive extension today would
#     flood `_unclaimed.tables` with every core WP table on B, mislabeled as
#     "protected by default-deny" when in fact graft's content-migration
#     path (WXR + `wp option`) touches several of them regardless. That's
#     not a bigger protected set, it's a WRONG one — actively misleading
#     about what "unclaimed" means for a table.
# Safety invariant that holds regardless of this gap (the actual protection
# mechanism does not depend on `_unclaimed.tables` enumerating anything):
# graft (Step 4) must build its DB-table-copy step exclusively from
# `protect.<module>.tables`/`migrate.<module>.tables` — an explicit
# allowlist read from the manifest — NEVER from a live "whatever's on B"
# scan. `_unclaimed` is a reporting/audit bucket, not itself the enforcement
# point; an incomplete `tables` enumeration is a visibility gap, not a
# protection gap. Tracked identically in the design doc (§3.6) so Step 4
# can't build graft's table-copy step against a live table listing without
# re-reading this reasoning first.
manifest_compute_unclaimed() {
  local manifest="$1" scan_b="$2"
  local claimed_pt all_pt unclaimed_pt
  local claimed_ok all_ok unclaimed_ok

  claimed_pt=$(echo "$manifest" | jq -c '[.migrate[]?.post_types[]?, .protect[]?.post_types[]?] | unique')
  # `?` added (MINOR, PR #2 review): `.post_types[].name` errors on a
  # scan-b.json that lacks `.post_types` entirely (fails closed today only
  # because the caller happens to be under `set -e`/checked — `?` makes the
  # "no post_types key" case a clean empty result instead of relying on
  # that).
  all_pt=$(echo "$scan_b" | jq -c '[.post_types[]?.name]')
  # Bug found via TDD against the plan's literal spec: `select(($claimed |
  # index(.)) | not)` looks right but isn't — the `|` into `index(.)` rebinds
  # `.` to $claimed itself before `index` ever sees it, so it always searches
  # $claimed for $claimed, never for the outer $all[] element. `$x` binds the
  # element explicitly so `index($x)` searches for the right thing.
  unclaimed_pt=$(jq -n --argjson all "$all_pt" --argjson claimed "$claimed_pt" \
    '[$all[] as $x | select(($claimed | index($x)) | not) | $x]')

  # option_keys extended here (MINOR, PR #2 review — Viktor leaned toward
  # extending where reasonable): unlike tables, option_keys need no prefix
  # resolution — scan-b.json's `.options[].option_name` is already the exact
  # same string space manifest option_keys use, comparable with the exact
  # same claimed/all/unclaimed shape as post_types above, no architecture
  # change required.
  claimed_ok=$(echo "$manifest" | jq -c '[.migrate[]?.option_keys[]?, .protect[]?.option_keys[]?] | unique')
  all_ok=$(echo "$scan_b" | jq -c '[.options[]?.option_name]')
  unclaimed_ok=$(jq -n --argjson all "$all_ok" --argjson claimed "$claimed_ok" \
    '[$all[] as $x | select(($claimed | index($x)) | not) | $x]')

  # Tables. This list used to be left empty on purpose, for two stated
  # reasons: the prefix needed to match a module's SUFFIX against a scanned,
  # prefixed table name was only obtainable from the live site, and no
  # core-wp module existed to claim WordPress's own tables, so filling the
  # list would have flooded it with wp_posts/wp_options and mislabelled them
  # as "protected".
  #
  # Both are now addressed: scan records `table_prefix` (lib/inventory.sh),
  # so the match is a plain string operation on already-scanned data and plan
  # stays offline; and the tables graft genuinely writes are excluded by name
  # below rather than pretended away.
  #
  # It matters because "protected" and "provably untouched" were not the same
  # thing. graft only ever writes what the manifest names, so an empty list
  # was never a protection hole — but backup_compute_protected_checksums
  # iterates `.protect[].tables`, so an empty list meant NO checksum was
  # taken for anything outside a module, and verify then reported "protected
  # data unchanged" having compared nothing at all. On a real run that came
  # out as a green PASS covering a WooCommerce, a booking plugin and a
  # multilingual stack, none of which had been looked at.
  #
  # EXCLUDED, because graft writes them by design and a checksum over them
  # would fail on every single run: the content and taxonomy tables reached
  # by the WXR import, and the options table. Everything else — every plugin
  # table, users, comments — stays in. A change there is worth surfacing.
  # Note that usermeta legitimately moves whenever anyone logs in; verify
  # reports unclaimed changes as information, not as an accusation.
  local prefix core_suffixes claimed_tb all_tb unclaimed_tb
  prefix=$(echo "$scan_b" | jq -r '.table_prefix // ""')
  core_suffixes='["posts","postmeta","options","terms","termmeta","term_taxonomy","term_relationships"]'
  claimed_tb=$(echo "$manifest" | jq -c '[.migrate[]?.tables[]?, .protect[]?.tables[]?] | unique')
  all_tb=$(echo "$scan_b" | jq -c '[.tables[]?]')

  if [ -z "$prefix" ]; then
    log_warn "scan-b.json has no table_prefix — cannot tell a plugin table from a core one, so unclaimed tables are left unlisted (re-run 'sitegraft scan' with a current sitegraft to populate it)"
    unclaimed_tb='[]'
  else
    unclaimed_tb=$(jq -n --argjson all "$all_tb" --argjson claimed "$claimed_tb" \
      --argjson core "$core_suffixes" --arg p "$prefix" \
      '[ $all[] as $t
         | ($t | if startswith($p) then .[($p | length):] else . end) as $suffix
         | select(($claimed | index($suffix)) | not)
         | select(($core    | index($suffix)) | not)
         | $t ]' 2>/dev/null || echo '[]')
  fi

  echo "$manifest" | jq --argjson u "$unclaimed_pt" --argjson uo "$unclaimed_ok" --argjson ut "$unclaimed_tb" \
    '.protect._unclaimed = {post_types: $u, tables: $ut, option_keys: $uo,
      note: "found on B, unclaimed by any module — protected by default-deny. Tables listed here are checksummed and reported by verify as information; a hard failure is reserved for tables a module explicitly declares."}'
}
