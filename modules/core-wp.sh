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

# Issue #17: `wp_navigation` -- the block themes' navigation post type -- was
# declared by no module at all, so it fell into protect._unclaimed and was
# never migrated, even from a block-theme A whose header component
# referenced one.
#
# NOT a third static entry in core_wp_post_types above, and settling that
# took actually reading WordPress core rather than assuming it from the
# type's name: wp_navigation (like wp_template/wp_global_styles, which
# modules/etch.sh's own header comment already makes the identical point
# about) is registered by WordPress core UNCONDITIONALLY -- verified
# directly against wp-includes/post.php's create_initial_post_types(), where
# register_post_type('wp_navigation', ...) carries no
# current_theme_supports()/theme-type guard of any kind, exactly like
# page/post a few lines above it in the very same function. So
# scan.post_types will list wp_navigation as registered on a plain
# classic-theme site too -- checking for the post type's REGISTRATION (the
# way core_wp_detect checks for "page") proves nothing about whether A has
# any actual navigation content worth migrating.
#
# What core_wp_option_keys_dynamic's "claim the key only if the scan shows
# it present" reasoning (issue #15) demands here, translated from an option
# key to a post type: claim wp_navigation only when the scan carries
# POSITIVE EVIDENCE A actually holds a wp_navigation POST, not merely that
# the type exists.
#
# FIX-PACK (Nat's review, second pass on this PR): the first version of this
# function gated on nav_uses_dynamic_page_list == true instead of on
# presence, which is backwards for #17's own acceptance criterion ("a
# block-theme source's navigation arrives on the target and points at the
# target's own page IDs"). A dynamic wp:page-list navigation carries NO ids
# at all, so it is precisely the case that needs no id-remap -- while a
# STATIC navigation (real navigation-link blocks with real page ids, the
# exact case _core_wp_remap_nav_page_ids below exists for) reads
# nav_uses_dynamic_page_list == false, IDENTICALLY to a source with no
# navigation at all, and was never claimed by the old gate. The old version
# would only ever have exercised the id-remap machinery on content that
# never needed remapping.
#
# nav_post_count (lib/inventory.sh, added in this fix-pack) is the actually
# missing fact: does A have ANY wp_navigation post at all, regardless of
# what its content looks like -- a different question from
# nav_uses_dynamic_page_list's shape question, which stays useful for other
# purposes (design doc §0 point 11/§6.1) but was never the right fact to
# gate a CLAIM on. `0`, `null` (the A-side query itself failed) and the key
# being entirely absent (a scan taken before this field existed) all fall
# through to "claim nothing" -- the fail-safe direction, deliberately: a
# false positive here is the expensive kind. verify_nav_present
# (lib/verify.sh) HARD FAILS the whole graft when wp_navigation is in the
# migrate selection and B ends up with none after import -- and plan's own
# default selection is "on" (plan_select_interactive pre-checks every
# claimed item; a scripted/accepted-defaults run keeps it). Claiming
# wp_navigation unconditionally would make every classic-theme graft fail
# verify by default, for a post type A never actually used. Both directions
# are covered by test: a scan recording nav_post_count > 0 claims
# wp_navigation (dynamic OR static content, either way — the tests cover
# both), a scan recording nav_post_count == 0 claims nothing.
core_wp_post_types_dynamic() {
  local scan_json="$1" nav_count

  # Same fail-closed treatment as core_wp_option_keys_dynamic's own "no
  # options list" check, and for the same reason: without a post_types
  # array this is not confirmably a real scan of a real WordPress site, and
  # "nothing to claim" must not read the same as "cannot tell".
  if ! jq -e 'has("post_types") and (.post_types | type == "array")' "$scan_json" >/dev/null 2>&1; then
    log_error "core-wp: ${scan_json} has no post_types list -- cannot confirm this is a real WordPress scan, so refusing to guess whether wp_navigation is worth migrating (re-run 'sitegraft scan')"
    return 1
  fi

  # B4 (Viktor's review, mutation-proven): the missing-key, explicit-null and
  # zero cases must NOT all collapse into the same silent "claim nothing",
  # even though they all end there. Missing-key and zero are legitimate,
  # unremarkable answers -- an old scan predating this field, and a real
  # classic-theme site with no navigation, respectively -- and stay silent.
  # An explicit `null`, though, means the scan record EXISTS and says the
  # A-side count query itself FAILED (lib/inventory.sh's
  # inventory_nav_post_count / inventory_scan_site never write a bare
  # `null` for any other reason) -- on a genuinely block-theme A whose
  # count query happened to fail, that reads to an operator as "verify
  # prints NAV:not-selected", indistinguishable from a deliberate,
  # successful decision that A has none. Proved by mutation before this
  # fix: changing the OTHER jq call's `// "unknown"` fallback to `// 0`
  # survived the entire suite, because nothing observed the difference
  # between "0" and "couldn't tell" -- ADR 0007 §4 is explicit that these
  # must read differently ("return 0 for 'nothing here', non-zero for 'I
  # could not tell'"), and core_wp_option_keys_dynamic already sets that
  # precedent in this very file by hard-failing when it cannot tell. This
  # function does not go that far (an unreadable count is not the same
  # class of "the scan itself is unusable" core_wp_option_keys_dynamic's
  # own hard-fail cases are), but it must not stay silent about it either.
  if jq -e 'has("nav_post_count") and .nav_post_count == null' "$scan_json" >/dev/null 2>&1; then
    log_warn "core-wp: ${scan_json} records nav_post_count as null -- the A-side wp_navigation count query failed (lib/inventory.sh's inventory_nav_post_count), so wp_navigation is NOT being claimed even though A may genuinely have navigation content. Re-run 'sitegraft scan' to retry, or migrate wp_navigation explicitly via a SITEGRAFT_MANIFEST_PREFILLED manifest if you already know A has some."
  fi

  # jq's `//` treats both an absent key and an explicit `null` as falsy --
  # correct for deciding whether to CLAIM (both mean "no evidence of
  # navigation to migrate"), which is all this second query is for; the
  # warn above already gave the null case its own, separate voice. `0` (a
  # real, meaningful "A has no navigation" answer) is NOT falsy to jq's
  # `//` (only `false`/`null` are), so a genuine zero count reaches the
  # numeric comparison below exactly as itself, never silently swapped for
  # "unknown".
  nav_count=$(jq -r '.nav_post_count // "unknown"' "$scan_json" 2>/dev/null) || nav_count=unknown
  case "$nav_count" in
    ''|*[!0-9]*) return 0 ;; # not a plain non-negative integer -- "unknown", or garbled -- claim nothing
  esac
  [ "$nav_count" -gt 0 ] || return 0

  echo wp_navigation
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
  _core_wp_remap_nav_page_ids "$id_map_tsv" "$wp_cmd_b"
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
      # An id that is not a plain integer never reaches `jq --argjson` (nit 2):
      # --argjson would fail to parse it, `fixed` would come back EMPTY, and
      # the push below would write that empty value to B — the same "BLANK B's
      # own theme_mods" this module warns about elsewhere, arrived at from the
      # other side. Unreachable today (column 2 is written by the mapping
      # mu-plugin from a WordPress post ID), so this is not a bug being fixed
      # but a guard on a path a future change could open without saying so.
      # A malformed id is treated exactly like a missing one: the key is
      # dropped, out loud.
      case "$logo_new" in
        ''|*[!0-9]*) logo_new="" ;;
      esac
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
    # Backstop for the same failure (nit 2): every rewrite above goes through
    # `jq`, and a `jq` that fails leaves `fixed` empty — which then propagates
    # unchanged through the remaining steps and would be written to B as an
    # empty option. An empty result is never a legitimate outcome here (the
    # value was a non-empty object one line above), so it can only mean a
    # rewrite failed. Leave B's value alone and say so.
    if [ -z "$fixed" ]; then
      log_warn "core-wp post_import: rewriting ${key} produced an empty value — a jq step must have failed. Leaving B's ${key} exactly as it is: writing this would BLANK the option rather than fix it. Report this with the run directory."
      continue
    fi

    [ -z "$removed" ] || log_warn "core-wp post_import: rewrote B's ${key} — removed:${removed}. These held A's own local IDs and had no counterpart on B."
    printf '%s' "$fixed" > "$f"
    # run_or_echo, for the same reason the page_on_front write above uses it:
    # module post_import hooks run unconditionally, dry-run included.
    # shellcheck disable=SC2086 # intentionally unquoted: wp_cmd_b may be a multi-word wrapper (e.g. ddev exec ... wp) and must word-split
    run_or_echo $wp_cmd_b option update "$key" "$fixed" --format=json
  done
}

# Issue #17 -- the actual substitution logic behind _core_wp_remap_nav_page_ids
# below, kept in its OWN function (not inlined directly into that function's
# `wp eval` heredoc) specifically so tests/unit/test_core_wp_module.bats can
# capture this exact source and run it through a real `php` CLI process, no
# WordPress bootstrap needed -- the identical reason lib/php/content-remap-
# functions.php was pulled out of a bash string in the first place (that
# file's own header comment, review, Viktor, NIT-1): an inline bash-string
# PHP payload is syntactically impossible to unit test on its own, and a
# bash helper that used to build one can stay green for years after the
# thing it built stopped being called at all -- exactly the false-coverage
# trap that file's rewrite closed once already.
#
# WHY A REGEX OVER PARSE_BLOCKS()/SERIALIZE_BLOCKS(): those are WordPress
# functions, not portable PHP -- using them would reintroduce the exact
# "only exercisable through a live wp eval" problem NIT-1 already solved. A
# `wp:navigation-link`/`wp:navigation-submenu` block comment's attributes are
# a single, self-contained JSON object right after the block name; isolating
# just that object with a regex (balanced-brace via a recursive subpattern)
# and running it through plain json_decode/json_encode needs no WordPress
# bootstrap at all, and is exactly as precise -- the id/kind decision itself
# is still made by reading real, decoded JSON, only the surrounding HTML-
# comment framing is regex.
#
# WHY THE RECURSIVE SUBPATTERN SPECIFICALLY (fourth-round review, Viktor,
# correcting an earlier version of this comment): NOT because a naive
# `\{.*?\}` truncates on a nested value -- it doesn't. Checked directly: a
# non-greedy `\{.*?\}` anchored by this same pattern's `\s*(/)?-->` tail
# backtracks correctly and captures a real nested object
# (`{"ref":77,"style":{"typography":{...}},"layout":{...}}`) exactly like
# the recursive form does, for ordinary single-line content. The actual,
# verified divergence is multi-line attrs: `.` does not match a newline
# without PCRE's `/s` modifier (not used here), so `\{.*?\}` fails outright
# on attributes split across lines, while `[^{}]++` inside the recursive
# form matches any character including newlines and succeeds. Checked both
# ways directly, not assumed.
#
# WHY THE "kind":"post-type" CHECK IS LOAD-BEARING, not decoration: a
# navigation-link's `"id"` attribute is AMBIGUOUS on its own --
# {"id":7,"kind":"taxonomy","type":"category"} carries a TERM id, not a post
# id. CORRECTION (Viktor's review, B1): an earlier version of this comment
# claimed "sitegraft migrates no term id-map at all" -- that is factually
# wrong. mu-plugins/sitegraft-id-mapper.php's wp_import_insert_term handler
# DOES log one, as id-map.tsv rows tagged `term:<taxonomy>` in column 3 --
# theme_mods' nav_menu_locations (B2 above) is REMOVED rather than remapped
# because nothing CONSUMES that term map for a content remap today, not
# because it doesn't exist. It does, and _core_wp_remap_nav_page_ids's own
# `map_json` below MUST exclude those rows explicitly (not just
# "attachment"), or jq's `add` lets a term row's key silently overwrite a
# real page mapping that happens to share the same OLD numeric id -- exactly
# the collision this comment is otherwise warning about, self-inflicted. A
# blind `"id":<old>(?!\d)` substitution run against id-map.tsv's POST ids --
# the same sentinel technique graft_remap_attachment_ids already uses for
# attachment ids -- would silently rewrite a category's term id whenever it
# happens to numerically coincide with a migrated post's OLD id, corrupting
# a reference that was never a post reference to begin with. Only a value
# that decodes with `"kind":"post-type"` (covers `"type":"page"` and
# `"type":"post"` alike) is ever touched; a "custom" link (a bare URL, no
# id) or a "taxonomy" link is left untouched by construction, whether or not
# its id happens to collide with something in the map.
_core_wp_nav_remap_php() {
  cat <<'PHP'
function sitegraft_core_wp_serialize_block_attributes( $attrs ) {
	// Replicates WordPress core's serialize_block_attributes()
	// (wp-includes/blocks.php) exactly -- verified directly against that
	// file's real source, not reverse-engineered. wp_json_encode() itself
	// falls through to a plain json_encode() call with the same flags
	// whenever encoding succeeds (wp-includes/functions.php), so
	// reproducing it here needs no WordPress bootstrap. B3 (Viktor's
	// review, execution-proven): a bare json_encode( $attrs ) does NONE of
	// this -- a label containing a literal "-->" survives untouched and
	// lands INSIDE the rewritten block's own attrs, ahead of the block's
	// real closing delimiter. A subsequent parse_blocks() call (Site
	// Editor, front-end render, anything) would then read that leaked
	// "-->" as the block's actual end, truncating the JSON attrs
	// mid-string and leaking the remainder into the page as plain text.
	$encoded = json_encode( $attrs, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE );
	return strtr(
		$encoded,
		array(
			'\\\\' => '\\u005c',
			'--'   => '\\u002d\\u002d',
			'<'    => '\\u003c',
			'>'    => '\\u003e',
			'&'    => '\\u0026',
			'\\"'  => '\\u0022',
		)
	);
}

function sitegraft_core_wp_remap_nav_link_ids( $map, $content ) {
	// B5 (Viktor's review, execution-proven): three DIFFERENT block shapes
	// carry a page/navigation id, not just navigation-link/-submenu's
	// "id". A wp:page-list block SCOPED to a parent page carries that
	// page's id in "parentPageID" -- a dynamic navigation (no hardcoded
	// CHILD ids) can still name its own SCOPE by id. A bare wp:navigation
	// block's "ref" attribute embeds ANOTHER wp_navigation post by id.
	// Third-round review (Viktor): an earlier version of this comment
	// claimed this handles "how a shared/reusable navigation gets
	// referenced from a page or template" -- that overstates this
	// function's actual reach. _core_wp_remap_nav_page_ids (below) only
	// ever passes content from posts id-map.tsv tags wp_navigation; a
	// migrated PAGE is never in that scan at all. Fourth-round review
	// (Viktor), one more precision on the same point: modules/etch.sh
	// DOES migrate wp_template -- the canonical place a block theme's
	// own `wp:navigation {"ref":N}` actually lives (a header/footer
	// template embedding the site's shared navigation) -- so "no shipped
	// module migrates a template" would be the wrong reason for this
	// scope limit even though it happens to be true of
	// wp_template_part specifically. The real reason is narrower and
	// holds regardless of what other modules migrate: this function's
	// OWN scan is restricted to wp_navigation rows, full stop, so a ref
	// inside a migrated wp_template is out of reach here no matter what.
	// On an Etch source it is not actually left unremapped in practice --
	// etch_post_import's own blind "ref":<old> substitution (this file,
	// above) scans EVERY non-attachment migrated post, wp_template
	// included, and catches it incidentally, the same way it already
	// covers a ref inside wp_navigation's own content. On a block-theme
	// source without Etch, nothing remaps a ref inside a migrated
	// wp_template. So the ref rule here can only ever fire, on its own,
	// on a wp:navigation block NESTED inside another migrated
	// wp_navigation post's own content -- one navigation embedding
	// another by reference -- not one embedded in a page or template.
	// That narrower case is still real and still worth remapping
	// correctly; it just is not the broader one the old wording implied.
	// Neither shape needs a "kind" disambiguation the way navigation-
	// link's "id" does: parentPageID can only ever mean a page
	// (core/page-list has no other id-bearing attribute), and ref can
	// only ever mean a wp_navigation post -- both safe to remap
	// unconditionally whenever present and non-zero.
	$pattern = '~<!--\s*wp:((?:core/)?(?:navigation-link|navigation-submenu|navigation|page-list))\s+(\{(?:[^{}]++|(?2))*+\})\s*(/)?-->~';
	return preg_replace_callback( $pattern, function ( $m ) use ( $map ) {
		$attrs = json_decode( $m[2], true );
		if ( ! is_array( $attrs ) ) {
			return $m[0];
		}
		// Strip an optional "core/" prefix so all three ways WordPress can
		// spell a block name resolve to the same three-way switch below.
		$name = preg_replace( '~^core/~', '', $m[1] );

		$changed = false;
		// Nit (Viktor's review): a navigation-link/-submenu carrying "id" and
		// "type" but NO "kind" field at all is deliberately left untouched,
		// same as a "kind":"taxonomy" one, and for the same reason -- not
		// because it is known to be safe or known to be a term reference,
		// but because it is NOT known to be a post reference. "kind" is the
		// one field this whole function trusts to disambiguate "id"; a block
		// saved by an older Gutenberg version (or hand-authored/imported)
		// that predates "kind" being written at all is a real possibility,
		// not a contrived one, and guessing "type":"page" implies
		// "kind":"post-type" would be exactly the guess this function exists
		// to refuse making. isset( $attrs['kind'], ... ) already requires
		// BOTH keys present, so this case falls through unchanged by
		// construction; documented here so that omission reads as a decision
		// rather than an oversight.
		if ( ( 'navigation-link' === $name || 'navigation-submenu' === $name )
			&& isset( $attrs['kind'], $attrs['id'] ) && 'post-type' === $attrs['kind'] ) {
			$old_id = (string) $attrs['id'];
			if ( array_key_exists( $old_id, $map ) ) {
				$attrs['id'] = (int) $map[ $old_id ];
				$changed = true;
			}
		} elseif ( 'page-list' === $name && isset( $attrs['parentPageID'] ) && (int) $attrs['parentPageID'] > 0 ) {
			$old_id = (string) $attrs['parentPageID'];
			if ( array_key_exists( $old_id, $map ) ) {
				$attrs['parentPageID'] = (int) $map[ $old_id ];
				$changed = true;
			}
		} elseif ( 'navigation' === $name && isset( $attrs['ref'] ) && (int) $attrs['ref'] > 0 ) {
			$old_id = (string) $attrs['ref'];
			if ( array_key_exists( $old_id, $map ) ) {
				$attrs['ref'] = (int) $map[ $old_id ];
				$changed = true;
			}
		}

		if ( ! $changed ) {
			return $m[0];
		}
		$new_attrs = sitegraft_core_wp_serialize_block_attributes( $attrs );
		if ( false === $new_attrs ) {
			return $m[0];
		}
		$close = ( isset( $m[3] ) && $m[3] !== '' ) ? '/' : '';
		return '<!-- wp:' . $m[1] . ' ' . $new_attrs . ' ' . $close . '-->';
	}, $content );
}
PHP
}

# _core_wp_remap_nav_page_ids <id_map_tsv> <wp_cmd_b> -- issue #17's id-remap.
# A wp_navigation post's navigation-link content holds POST ids for the
# pages/posts it links to, and those ids change on import -- the same class
# of problem design doc §9.3 documents for page_on_front and B2 documents
# for theme_mods' custom_logo, one field over.
#
# MEASURED, not assumed, that graft's existing generic remap does not already
# cover this (see this PR's own description for how): graft_remap_
# attachment_ids (lib/graft.sh) calls sitegraft_remap_attachment_refs
# (lib/php/content-remap-functions.php) with an `$attachments` map built
# exclusively from id-map.tsv rows tagged "attachment" -- read directly,
# `awk -F'\t' '$3=="attachment"'` in graft_remap_attachment_ids itself -- so
# a page or post id inside navigation content is never in that set and
# travels to B unrewritten. This module's own post_import hook is where it
# happens instead, the same division of labour design doc §11's edge-case
# table already draws for a module-specific reference ("outside the core's
# generic remap — that's the job of the relevant module's post_import
# hook"), and the one etch_post_import already uses for Etch's own
# component "ref" ids just above.
#
# SCOPE: only wp_navigation posts THIS run imported (id-map.tsv's own
# wp_navigation rows), and within those, only ids id-map.tsv actually maps --
# the same "concretely reachable, never a blind sweep" discipline
# graft_remap_featured_images documents for its own scope. A wp:page-list
# (dynamic) navigation has no navigation-link/-submenu blocks carrying a
# post-type id at all, so this is a correct, harmless no-op against one --
# no separate "is it dynamic" branch is needed here, the pattern simply
# never matches anything in that content.
_core_wp_remap_nav_page_ids() {
  local id_map_tsv="$1" wp_cmd_b="$2"
  # Same guard, same reason, as graft_remap_attachment_ids/
  # graft_remap_featured_images: id-map.tsv genuinely not existing yet
  # (a first-time --dry-run, graft_fetch_id_map never creates it under
  # --dry-run) and existing-but-empty are the same "nothing to remap yet"
  # case. `-s` (exists AND non-empty) matches those siblings' own check.
  [ -s "$id_map_tsv" ] || return 0

  local nav_ids_json
  # Nit (Viktor's review): `| unique` was missing here -- modules/etch.sh's
  # own equivalent (`ids_json`, its component-ref remap) already dedupes,
  # for the same reason: a hand-edited or otherwise duplicated id-map.tsv
  # row would otherwise walk the same post id twice through the PHP loop
  # below, applying the substitution to whatever its FIRST pass already
  # produced -- harmless for a straight id swap once, but not a guarantee
  # this function's own logic depends on holding.
  nav_ids_json=$(awk -F'\t' '$3=="wp_navigation" && $2 ~ /^[0-9]+$/ {print $2}' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0)) | unique')
  # No wp_navigation post travelled in this run -- legitimately nothing to
  # do, not an error (a manifest excluding wp_navigation from migrate is a
  # valid, deliberate choice, same as page_on_front's own header comment
  # documents for page/post).
  [ "$(printf '%s' "$nav_ids_json" | jq 'length')" != "0" ] || return 0

  # The substitution map is every NON-ATTACHMENT id-map.tsv row (old post id
  # -> new post id) -- a navigation-link can point at any migrated post
  # type, not only at other wp_navigation posts. Attachment rows are
  # excluded on purpose: they would only create an opportunity for a
  # numeric coincidence to match a "kind":"post-type" id that was never an
  # attachment reference to begin with (etch_post_import's own component-ref
  # remap excludes them from its map for the identical reason).
  local map_json
  # B1 (Viktor's review, execution-proven): excluding "attachment" alone is
  # NOT enough. mu-plugins/sitegraft-id-mapper.php's wp_import_insert_term
  # handler writes id-map.tsv rows tagged `term:<taxonomy>` in column 3 --
  # real rows, not hypothetical -- and jq's `add` below lets the LAST row
  # for a given OLD id win. Without this second exclusion, a term whose old
  # id collides with a migrated page's old id (both id sequences start at 1
  # on a fresh WordPress site) silently overwrites the correct page mapping
  # with the term's new id -- corrupting a "kind":"post-type" reference that
  # was never a term reference to begin with. Proved live before this fix.
  map_json=$(awk -F'\t' '$3 != "attachment" && $3 !~ /^term:/ && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {printf "%s\t%s\n", $1, $2}' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")) | map({(.[0]): .[1]}) | add // {}')

  local remap_fn php
  remap_fn=$(_core_wp_nav_remap_php)
  # The payload is embedded via bash-side interpolation into a PHP single-
  # quoted string literal, same technique etch_post_import's own component-
  # ref remap already uses just above -- safe here because both $map_json and
  # $nav_ids_json are built entirely from id-map.tsv's own digit-only old/new
  # id columns (the awk filters above require `~ /^[0-9]+$/` on both), so
  # neither can ever contain a single quote to break out of the literal.
  php=$(cat <<PHP
${remap_fn}
\$map = json_decode('${map_json}', true);
\$nav_ids = json_decode('${nav_ids_json}', true);
if ( ! is_array( \$map ) || ! is_array( \$nav_ids ) ) { echo "0"; return; }
\$changed = 0;
global \$wpdb;
foreach ( \$nav_ids as \$pid ) {
	\$pid = (int) \$pid;
	\$content = get_post_field( 'post_content', \$pid );
	if ( ! is_string( \$content ) || '' === \$content ) { continue; }
	\$new_content = sitegraft_core_wp_remap_nav_link_ids( \$map, \$content );
	if ( \$new_content !== \$content ) {
		\$wpdb->update( \$wpdb->posts, array( 'post_content' => \$new_content ), array( 'ID' => \$pid ) );
		clean_post_cache( \$pid );
		\$changed++;
	}
}
echo \$changed;
PHP
)

  log_info "core-wp post_import: remapping navigation-link page/post ids across $(printf '%s' "$nav_ids_json" | jq 'length') migrated wp_navigation post(s)..."
  # run_or_echo, for the same reason every other write in this file uses it:
  # module post_import hooks run unconditionally, dry-run included.
  # shellcheck disable=SC2086 # intentionally unquoted: wp_cmd_b may be a multi-word wrapper (e.g. ddev exec ... wp) and must word-split
  run_or_echo $wp_cmd_b eval "$php"
}
