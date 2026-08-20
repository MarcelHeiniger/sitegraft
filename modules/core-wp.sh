#!/usr/bin/env bash
# modules/core-wp.sh — WordPress core content itself (pages/posts and the
# handful of core options `graft` needs to migrate a "front page" A/B pair
# correctly). Filling a gap flagged directly in the plan/design doc: neither
# was implemented by any earlier step ("no `core-wp` module exists yet
# (that's Step 4, Task 4.1) to claim WordPress's OWN tables ... as core,
# handled via WXR/options, not the table-copy path" — lib/manifest.sh's own
# comment on manifest_compute_unclaimed; design doc §9.3 explicitly names
# "the core-wp module's hook" for the page_on_front remap). Without this
# file, `plan_defaults` (lib/plan.sh) never populates manifest.migrate with
# page/post at all, and `page_on_front`/`page_for_posts` are never migrated
# or remapped — this module is what makes both of those actually happen,
# through the exact same convention-based module mechanism every other
# plugin uses (zero changes needed to lib/ or bin/ to add it).
#
# core-wp is detected on every real WordPress site by construction (the
# `page` post_type is registered by WP core itself, never conditionally) —
# checked via the scan JSON like any other module, per design doc §3.2,
# rather than unconditionally returning true regardless of what was
# actually scanned.

core_wp_name() { echo "WordPress Core"; }

core_wp_detect() {
  jq -e '.post_types[]? | select(.name == "page")' "$1" >/dev/null 2>&1
}

core_wp_post_types() {
  cat <<'EOF'
page
post
EOF
}

# blogname/blogdescription: harmless, commonly-expected site identity values.
# show_on_front/page_on_front/page_for_posts: the front-page trio design doc
# §9.3 is specifically about — show_on_front is a plain string ("page" or
# "posts"), safe to blind-copy; page_on_front/page_for_posts hold A's OWN
# page IDs and are handled by core_wp_post_import below instead (graft_
# migrate_options, lib/graft.sh, already skips blind-copying these two for
# exactly this reason).
core_wp_option_keys() {
  cat <<'EOF'
blogname
blogdescription
show_on_front
page_on_front
page_for_posts
EOF
}

# design doc §9.3: page_on_front/page_for_posts on A hold A's OWN page IDs —
# a plain `wp option update` would copy the wrong ID onto B. Remaps each
# through id-map.tsv (Task 4.1's mu-plugin log, §7) after the WXR import has
# actually assigned B's new IDs. A no-op (silently) whenever A never had a
# front/posts page configured, or that page wasn't part of this run's import
# (id-map.tsv has no matching row) — never an error, since a manifest
# excluding "page" from migrate is a valid, deliberate operator choice, not
# a bug.
core_wp_post_import() {
  local run_dir="$1" id_map_tsv="$2" wp_cmd_b="$3"
  local key old_id new_id
  for key in page_on_front page_for_posts; do
    old_id=$(cat "${run_dir}/option-${key}.value" 2>/dev/null | tr -d '"')
    case "$old_id" in
      ''|null|false|0) continue ;;
    esac
    new_id=$(awk -F'\t' -v old="$old_id" '$1==old{print $2}' "$id_map_tsv" 2>/dev/null)
    if [ -n "$new_id" ]; then
      # Step 6 dry-run audit: this was a raw, unwrapped write — the ONE real
      # gap the audit found (design doc §3.2's module contract never said a
      # post_import hook must respect --dry-run, and graft_run_module_
      # post_import, lib/graft.sh, calls every module's hook unconditionally,
      # not only when NOT is_dry_run). Concretely reachable, not theoretical:
      # graft's step-idempotency markers (graft.*.done files) mean a
      # `--dry-run` re-run of `graft` against a run directory whose
      # id-map.tsv was already populated by an earlier REAL run would have
      # actually written to B's live page_on_front/page_for_posts option —
      # while the run overall was believed dry. run_or_echo is already this
      # codebase's one standard for exactly this (see lib/core.sh) — used
      # here instead of a second, module-local dry-run check.
      run_or_echo $wp_cmd_b option update "$key" "$new_id"
    else
      log_warn "core-wp post_import: A's ${key} (page ${old_id}) has no corresponding entry in id-map.tsv — leaving B's ${key} unchanged (the page was likely not included in this run's migrate selection)"
    fi
  done
}
