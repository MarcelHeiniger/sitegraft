#!/usr/bin/env bash
# modules/etch.sh — graft module for Etch (page builder).
#
# REWRITTEN after the first run against a real Etch site. The previous
# version of this file was copied verbatim from the design doc's §3.3 and had
# never been confronted with an actual install; every one of its post types
# was wrong. What follows is what a live Etch 1.6.5 site actually contains,
# each point verified by querying the database directly rather than by asking
# WordPress what it has registered (a plugin that registers its types only
# behind is_admin() is invisible to `wp post-type list` under wp-cli, so that
# command alone could not have settled it).
#
# What the old version declared, and what was actually there:
#
#   etch_cfs, etch_cpts, etch_loops as POST TYPES
#     -> none of the three exists. Zero rows in wp_posts for any of them, on
#        a fully built site. `etch_loops` is real, but it is an OPTION: the
#        right name filed under the wrong kind.
#
#   four options, no post types beyond those three
#     -> Etch does use post types, just none of its own. Its content lives in
#        WordPress's native ones (below), and its settings in five options,
#        not four (etch_loops was the missing one).
#
# Where Etch actually stores things:
#
#   post_content of ordinary page/post   the page markup itself, as Gutenberg
#                                        blocks (wp:etch/element, wp:etch/text
#                                        ...). Already covered by core-wp.
#   wp_block                             Etch components, carrying
#                                        etch_component_properties and
#                                        etch_component_html_key postmeta.
#   wp_template                          the block theme's templates — on the
#                                        reference site, 35 of them. Without
#                                        these B receives pages and nothing
#                                        to render them with.
#   wp_global_styles                     the block theme's global styles.
#   five wp_options                      see etch_option_keys below.
#   NO custom tables                     verified: no etch_* table exists.
#
# JUDGMENT CALL worth a second look: wp_template, wp_global_styles and
# wp_block are WordPress CORE post types, not Etch's, so an argument exists
# for putting them in core-wp instead. They are declared here on purpose:
# they only carry a design worth migrating when the target's theme is being
# replaced by a block theme, which is precisely the situation etch_detect
# identifies. In core-wp they would be offered on every migration, including
# classic-theme pairs where they are empty noise.
#
# KNOWN GAP, not fixable inside this module: the active theme's
# `theme_mods_<slug>` option (theme_mods_etch-theme-child on the reference
# site) also belongs with a migrated design, but its NAME depends on the
# site's active theme slug and the module contract only accepts a static
# list. Declaring it needs a contract change, not a line here.

etch_name() { echo "Etch"; }

etch_detect() {
  # $1 = path to a scan-*.json produced by `sitegraft scan`
  jq -e '.plugins[]? | select(.name == "etch")' "$1" >/dev/null 2>&1
}

etch_post_types() {
  cat <<'EOF'
wp_block
wp_template
wp_global_styles
EOF
}

# Explicit allowlist, never a broad `etch_*` prefix — the same reasoning as
# modules/acss.sh: `<mod>_option_keys_exclude` is documented but inert, so a
# prefix would ship etch_license_key, etch_license_status,
# etch_license_options and etchtheme_license_options straight to B. Also
# deliberately left out, being schema state rather than design:
# etch_db_version, etch_migrations, etch_svg_version.
# `etch_cfs` and `etch_cpts` deserve a note. The original version of this
# module declared those two names as POST TYPES, and no such post type exists
# on any real site — that was the headline error. But the names themselves
# were not invented: on a second real Etch site they turn up as OPTIONS,
# holding the custom-field-set and custom-post-type definitions the builder
# lets you declare. The first site had neither option, which is what made the
# earlier conclusion ("these names are fiction") look safe. Right names,
# wrong kind.
#
# KNOWN CONSEQUENCE, not solved here: `etch_cpts` DEFINES post types, so a
# site using it stores real content under names only that option knows
# (`fotos`, on the site this was found on). Migrating the definition without
# migrating the posts it describes leaves B with a registered-but-empty post
# type. A static post_types list cannot express "whatever etch_cpts happens
# to declare" — closing that needs a contract change, not another line here.
etch_option_keys() {
  cat <<'EOF'
etch_cfs
etch_cpts
etch_css_toolbar_values
etch_global_stylesheets
etch_loops
etch_settings
etch_styles
EOF
}

# Declared for contract completeness. Inert today — nothing in lib/ or bin/
# ever calls module_has_fn "$mod" option_keys_exclude, so this function's
# return value is never read. It is documented in docs/usage.md §5 as the way
# to carve secrets out of a broad prefix, which is exactly the thing not to
# rely on: etch_option_keys above is an explicit allowlist for that reason.
etch_option_keys_exclude() {
  cat <<'EOF'
etch_license_*
etchtheme_license_*
etch_db_version
etch_migrations
etch_svg_version
EOF
}

# etch_settings is migrated as a whole because it carries the settings the
# builder needs to render — but it also contains an `ai_api_key` field. On
# the reference site that field was empty; on a site where it is set, copying
# the option copies the key. The key is not stripped here: A and B are the
# same client's site in every case sitegraft is built for, and silently
# clearing a credential the operator deliberately configured would break
# Etch's AI features on B with no explanation. Warned about instead, so the
# operator decides.
#
# Read-only: this hook never writes to B, so it needs no run_or_echo wrapper
# (hooks run unconditionally, including under --dry-run — a write here would
# have to be wrapped, see modules/motopress.sh.example).
etch_post_import() {
  local run_dir="$1" id_map_tsv="$2" wp_cmd_b="$3"
  local ai_key
  ai_key=$($wp_cmd_b option get etch_settings --format=json 2>/dev/null \
    | jq -r '.ai_api_key // ""' 2>/dev/null || true)
  if [ -n "$ai_key" ]; then
    log_warn "etch post_import: B's etch_settings now carries a non-empty ai_api_key, copied from A along with the rest of the option. If B must not hold A's credential, clear it from Etch's settings on B."
  fi
}

# design doc §12: Etch is one of the three rendering-stack components whose
# absence or version mismatch on B must block `graft`. The folder name is not
# ambiguous — it is the same literal "etch" that etch_detect searches
# .plugins[] for, verified on two real installs (1.4.11 and 1.6.5).
etch_stack_candidates() {
  echo "etch"
}
