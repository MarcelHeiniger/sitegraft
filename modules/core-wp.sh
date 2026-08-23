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

# Issue #15, closed through the extended module contract rather than by a
# special case in `plan` (docs/decisions/0007-module-dynamic-selections.md).
# The active theme's customizer settings live in `theme_mods_<stylesheet>`,
# which belongs with a migrated design — but its KEY NAME depends on the
# site's active theme slug, so no static list can name it. It is declared
# here, resolved from the scan `plan` hands this function.
#
# WHY core-wp and not etch, where the gap was originally noted: `theme_mods_`
# is written by WordPress core for whatever theme is active, on classic and
# block themes alike. modules/etch.sh's own §-note explains why it keeps
# wp_template/wp_global_styles (they are core post types that only carry a
# design worth migrating when the target's theme is being replaced by a block
# theme, which is what etch_detect identifies) — theme_mods_ has no such
# condition attached, so it goes with the module that claims core's own
# content. etch.sh's KNOWN GAP note now points here.
#
# The key name is correct for B as well as for A: graft's §12 stack
# precondition refuses to run unless B's active theme matches A's, so the
# option lands on B under the name B's own theme reads.
#
# Two fail-closed cases, deliberately distinguished from "nothing to claim":
#   - the scan records no active theme  -> error. There is no such WordPress
#     site; a scan saying otherwise cannot be reasoned from.
#   - the scan has no options list      -> error, for the same reason. Its
#     absence would otherwise be indistinguishable from "A never customized
#     this theme", and those must not produce the same answer.
# The genuine "A never customized this theme" case (an active theme with no
# theme_mods_ row) returns nothing, successfully — and must: graft_migrate_
# options (lib/graft.sh) falls back to the literal `null` when `wp option
# get` finds nothing on A and writes that to B, so claiming a key A does not
# have would BLANK B's own theme_mods.
core_wp_option_keys_dynamic() {
  local scan_json="$1" slug

  if ! jq -e 'has("options") and (.options | type == "array")' "$scan_json" >/dev/null 2>&1; then
    log_error "core-wp: ${scan_json} has no options list — cannot tell whether this site stored theme_mods for its active theme, so refusing to guess (re-run 'sitegraft scan')"
    return 1
  fi

  slug=$(jq -r '.active_theme.stylesheet // .active_theme.name // ""' "$scan_json" 2>/dev/null) || slug=""
  if [ -z "$slug" ] || [ "$slug" = "null" ]; then
    log_error "core-wp: ${scan_json} records no active theme (active_theme.stylesheet) — every WordPress site has one, so this scan cannot be trusted to say which theme_mods_ option belongs to the design (re-run 'sitegraft scan')"
    return 1
  fi

  jq -r --arg k "theme_mods_${slug}" '.options[]?.option_name | select(. == $k)' "$scan_json"
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
    # Fix-pack BLOCKER-severity bug found live (via the DDEV harness's new
    # MAJOR-B dry-run assertion, but NOT actually a dry-run-specific bug —
    # this reproduces on ANY graft, real or dry-run): graft_migrate_options
    # (lib/graft.sh) only ever writes "option-<key>.value" for a key that is
    # actually in the manifest's migrate.*.option_keys — a manifest that
    # selects page_on_front but NOT page_for_posts (or vice versa; both are
    # legitimate, independent operator choices) leaves the OTHER key's
    # ".value" file never created at all. `cat` on a missing file exits
    # non-zero; under bin/sitegraft's `set -o pipefail`, that makes the
    # WHOLE `cat | tr` pipe's exit status non-zero too, and the bare
    # `old_id=$(...)` assignment then aborted the entire graft under `set
    # -e` — silently, with no error message (2>/dev/null hides cat's own
    # complaint), reproduced live as a bare unlogged "exit 1". This
    # function's own header comment already documents the INTENDED
    # behavior ("a manifest excluding a page from migrate is a valid,
    # deliberate choice, not a bug... never an error") — the missing
    # existence check below is what actually makes that true, rather than
    # just being true whenever bats' non-set-e test context happened to
    # mask the crash.
    [ -f "${run_dir}/option-${key}.value" ] || continue
    old_id=$(tr -d '"' 2>/dev/null < "${run_dir}/option-${key}.value")
    case "$old_id" in
      ''|null|false|0) continue ;;
    esac
    # Fix-pack bug found live (DDEV harness, MAJOR-B's new graft --dry-run
    # assertion, same root cause and same fix as graft_remap_featured_images
    # in lib/graft.sh — see that function's own comment): graft_fetch_id_map
    # never creates id_map_tsv under --dry-run, so on a first-time dry run
    # against a fresh run directory the file doesn't exist at all yet. `awk`
    # on a genuinely missing file exits non-zero (2, "can't open file") —
    # `2>/dev/null` on the call below hid the message, but the bare `new_id=
    # $(...)` assignment still failed under this codebase's `set -e`,
    # aborting the whole graft silently (no error printed anywhere, just a
    # bare process exit 2 — reproduced live via the harness). A missing
    # id-map.tsv is exactly the same "nothing to remap yet" case this
    # function already treats as a graceful no-op for an unmatched old_id
    # (see the header comment above), so it gets the same treatment here.
    [ -f "$id_map_tsv" ] || continue
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
      # shellcheck disable=SC2086 # intentionally unquoted: wp_cmd_b may be a multi-word wrapper (e.g. ddev exec ... wp) and must word-split
      run_or_echo $wp_cmd_b option update "$key" "$new_id"
    else
      log_warn "core-wp post_import: A's ${key} (page ${old_id}) has no corresponding entry in id-map.tsv — leaving B's ${key} unchanged (the page was likely not included in this run's migrate selection)"
    fi
  done

  _core_wp_fix_theme_mods "$run_dir" "$id_map_tsv" "$wp_cmd_b"
}

# B2 (third review round), and the same class of bug as page_on_front just
# above: `theme_mods_<slug>` is FULL of A's own local IDs, and
# core_wp_option_keys_dynamic is what started migrating it.
#
# graft_migrate_options pushes that option to B verbatim; graft_remap_
# attachment_ids only ever rewrites post_content/post_excerpt, never an option
# value. So every id inside theme_mods_ travels to B unchanged:
#
#   custom_logo          an ATTACHMENT id      -> remapped through id-map.tsv
#   nav_menu_locations   TERM ids per location -> removed
#   custom_css_post_id   a POST id             -> removed
#
# custom_logo is the dangerous one, and its failure mode is the bad kind: if B
# happens to own an attachment carrying A's number, B's logo silently becomes
# a DIFFERENT, WRONG image rather than a missing one. Nothing on B looks
# broken, so nothing prompts a second look.
#
# The other two are REMOVED, not remapped, because there is nothing to remap
# through: sitegraft v1 migrates neither classic nav menus (design doc §13)
# nor `custom_css`, so B has no counterpart for those ids and id-map.tsv has
# no rows for them. Removing the key restores WordPress's own "not
# configured" default; carrying A's number would point B's theme at whatever
# term or post happens to hold it.
#
# And when id-map.tsv has no row for the logo, the key is DROPPED, out loud,
# rather than guessed at — CLAUDE.md's "a check must distinguish verified-true
# from could-not-verify", applied to a value rather than to a check.
#
# Runs after graft_migrate_options by construction (graft_run_module_
# post_import is the step immediately after it, lib/graft.sh), so the
# option-*.value files this reads are already on disk and B has already
# received the unfixed value this corrects.
_core_wp_fix_theme_mods() {
  local run_dir="$1" id_map_tsv="$2" wp_cmd_b="$3"
  local f key value fixed removed logo_old logo_new

  # A glob, because the key name carries the active theme's slug and is only
  # knowable from the scan (that is the whole point of #15). `nullglob` is not
  # available on the bash 3.2 this repo targets in the portable way this needs,
  # so the no-match case is handled with the usual existence test instead.
  for f in "${run_dir}"/option-theme_mods_*.value; do
    [ -f "$f" ] || continue
    key=$(basename "$f" .value); key="${key#option-}"
    value=$(cat "$f")
    # A value that is not an object carries no ids to fix. Not an error: an
    # unset theme_mods_ row legitimately reads as `false` or `null`.
    printf '%s' "$value" | jq -e 'type == "object"' >/dev/null 2>&1 || continue

    removed=""
    fixed="$value"

    logo_old=$(printf '%s' "$value" | jq -r '.custom_logo // empty' 2>/dev/null) || logo_old=""
    case "$logo_old" in
      ''|null|false|0) logo_old="" ;;
    esac
    if [ -n "$logo_old" ]; then
      logo_new=""
      if [ -f "$id_map_tsv" ]; then
        logo_new=$(awk -F'\t' -v old="$logo_old" '$1==old && $3=="attachment"{print $2}' "$id_map_tsv" 2>/dev/null | head -1)
      fi
      if [ -n "$logo_new" ]; then
        fixed=$(printf '%s' "$fixed" | jq -c --argjson n "$logo_new" '.custom_logo = $n')
      else
        fixed=$(printf '%s' "$fixed" | jq -c 'del(.custom_logo)')
        removed="${removed} custom_logo(attachment ${logo_old}, no id-map.tsv row — dropped rather than pointed at whatever B numbers ${logo_old})"
      fi
    fi

    if printf '%s' "$fixed" | jq -e 'has("nav_menu_locations")' >/dev/null 2>&1; then
      fixed=$(printf '%s' "$fixed" | jq -c 'del(.nav_menu_locations)')
      removed="${removed} nav_menu_locations(classic menus are not migrated, design doc §13)"
    fi
    if printf '%s' "$fixed" | jq -e 'has("custom_css_post_id")' >/dev/null 2>&1; then
      fixed=$(printf '%s' "$fixed" | jq -c 'del(.custom_css_post_id)')
      removed="${removed} custom_css_post_id(custom_css is not migrated)"
    fi

    [ "$fixed" != "$value" ] || continue

    [ -z "$removed" ] || log_warn "core-wp post_import: rewrote B's ${key} — removed:${removed}. These held A's own local IDs and had no counterpart on B."
    printf '%s' "$fixed" > "$f"
    # run_or_echo, for the same reason the page_on_front write above uses it:
    # module post_import hooks run unconditionally, dry-run included.
    # shellcheck disable=SC2086 # intentionally unquoted: wp_cmd_b may be a multi-word wrapper (e.g. ddev exec ... wp) and must word-split
    run_or_echo $wp_cmd_b option update "$key" "$fixed" --format=json
  done
}
