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
# The active theme's `theme_mods_<slug>` option (theme_mods_etch-theme-child
# on the reference site) also belongs with a migrated design, but its NAME
# depends on the site's active theme slug. That was a known gap here until
# the module contract gained scan-computed selections (issue #15,
# docs/decisions/0007-module-dynamic-selections.md); it is now claimed by
# modules/core-wp.sh's `core_wp_option_keys_dynamic`, since `theme_mods_` is
# core's own option for whatever theme is active, block or classic — see that
# function's comment for why it belongs there rather than here.

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

# Issue #16, closed through the extended module contract
# (docs/decisions/0007-module-dynamic-selections.md). `etch_cpts` DEFINES
# post types, and etch_option_keys above migrates that definition — so B
# used to receive the registration and none of the posts, leaving the type
# registered and empty. The names live in the site's own option data and are
# only knowable after `scan`, which is exactly what a `_dynamic` selection is
# for. Each name lands in the manifest individually, so `plan`'s interactive
# selection lists and toggles it like any other post type.
#
# WHAT SHAPES ARE ACCEPTED, and why this is written defensively rather than
# against one known layout: `etch_cpts` has been seen on a real site, but its
# internal structure has NOT been verified field by field here, and the scan
# records whatever `wp option list --format=json` produced — which may hand
# this function a decoded array/object or a JSON string, depending on the
# wp-cli version's own unserialization. Three shapes are read:
#   [ "fotos", ... ]                       a plain list of names
#   [ {"slug":"fotos", ...}, ... ]         a list of definitions (slug, else
#                                          post_type, else name, else key)
#   { "fotos": {...}, ... }                a map keyed by name
# — each also accepted as a JSON string holding the same.
#
# ANYTHING ELSE IS AN ERROR, not an empty list. A value this function cannot
# read means it cannot tell "this site declares no CPTs" from "this site
# declares CPTs I failed to parse", and only one of those is safe to act on:
# the second silently reproduces the exact defect this closes. `plan` stops
# and says so (see module_selection in lib/modules.sh).
#
# A declared name the scanned site does not actually register is DROPPED,
# with a warning — never offered. CLAUDE.md's first rule in its original
# form: `plan` once offered post types that did not exist, `graft` exported
# an empty WXR, and `verify` reported PASS.
etch_post_types_dynamic() {
  local scan_json="$1" raw declared registered slug kept=""

  # Same fail-closed treatment as core_wp_option_keys_dynamic, and for the
  # same reason: with no options list, "this site declares no custom post
  # types" and "nobody looked" are indistinguishable, and only one of them is
  # safe to act on.
  if ! jq -e 'has("options") and (.options | type == "array")' "$scan_json" >/dev/null 2>&1; then
    log_error "etch: ${scan_json} has no options list, so whether this site declares custom post types through etch_cpts cannot be determined — refusing to read that as 'it declares none' (re-run 'sitegraft scan')"
    return 1
  fi

  raw=$(jq -c '[.options[]? | select(.option_name == "etch_cpts") | .option_value][0]' "$scan_json" 2>/dev/null) \
    || { log_error "etch: could not read ${scan_json} while looking for the etch_cpts option — refusing to guess (re-run 'sitegraft scan')"; return 1; }
  [ -n "$raw" ] || raw=null

  # Kept as a single-quoted jq program on purpose (.shellcheckrc's SC2016
  # note): nothing in it is a shell variable.
  local prog='
    def decoded:
      if type != "string" then .
      elif test("^\\s*$") then null
      else (try fromjson catch error("etch_cpts is not JSON and could not be decoded")) end;
    def name_of:
      if type == "string" then .
      elif type == "object" then (.slug // .post_type // .name // error("an etch_cpts entry carries no slug/post_type/name"))
      else error("an etch_cpts entry is neither a name nor a definition object") end;
    decoded
    | if . == null then []
      elif type == "array" then map(name_of)
      elif type == "object" then (to_entries | map(if (.value | type) == "object" then (.value.slug // .value.post_type // .key) else .key end))
      else error("etch_cpts is neither a list nor a map") end'

  if ! declared=$(printf '%s' "$raw" | jq -c "$prog" 2>&1); then
    log_error "etch: cannot read the etch_cpts option recorded in ${scan_json} (${declared}). Refusing to continue: an unreadable value cannot be told apart from 'this site declares no custom post types', and treating it as the latter is what carries Etch's post-type definitions to B while leaving their content behind (issue #16). Fix or extend etch_post_types_dynamic for this site's shape, or drive the run from a SITEGRAFT_MANIFEST_PREFILLED manifest."
    return 1
  fi

  [ "$(printf '%s' "$declared" | jq 'length')" != "0" ] || return 0

  if ! jq -e 'has("post_types") and (.post_types | type == "array")' "$scan_json" >/dev/null 2>&1; then
    log_error "etch: ${scan_json} lists no post types, so a name declared by etch_cpts cannot be confirmed to exist on that site — refusing to offer post types that may not be there (re-run 'sitegraft scan')"
    return 1
  fi
  registered=$(jq -c '[.post_types[]?.name]' "$scan_json")

  while IFS= read -r slug <&3; do
    [ -n "$slug" ] || continue
    # WordPress caps a post-type name at 20 characters and allows only
    # lowercase letters, digits, underscore and hyphen. A name outside that
    # is not a post type, so it is a defect in the data, not something to
    # quietly skip.
    case "$slug" in
      *[!a-z0-9_-]*)
        log_error "etch: etch_cpts in ${scan_json} declares '${slug}', which is not a valid WordPress post-type name — refusing to plan a migration around it"
        return 1
        ;;
    esac
    if [ "${#slug}" -gt 20 ]; then
      log_error "etch: etch_cpts in ${scan_json} declares '${slug}', longer than WordPress's 20-character post-type limit — refusing to plan a migration around it"
      return 1
    fi
    if ! printf '%s' "$registered" | jq -e --arg s "$slug" 'index($s) != null' >/dev/null 2>&1; then
      log_warn "etch: etch_cpts declares post type '${slug}', but ${scan_json} shows it is not registered on that site — leaving it out of the plan rather than offering a post type whose export would come back empty"
      continue
    fi
    kept="${kept}${slug}"$'\n'
  done 3<<< "$(printf '%s' "$declared" | jq -r '.[]')"

  printf '%s' "$kept"
}

# Explicit allowlist rather than a broad `etch_*` prefix. This predates issue
# #13's fix and is KEPT on purpose now that `etch_option_keys_exclude` below
# is genuinely applied (docs/decisions/0007-module-dynamic-selections.md): a
# prefix plus exclusions is now safe, but an allowlist and an exclusion list
# fail in opposite directions, and for a plugin with this few options the
# allowlist's failure mode (a new Etch option is not migrated until someone
# adds it here) is the better one — the exclusion list's is that a new
# `etch_something_secret` ships to B until someone notices. Also deliberately
# left out, being schema state rather than design: etch_db_version,
# etch_migrations, etch_svg_version.
# `etch_cfs` and `etch_cpts` deserve a note. The original version of this
# module declared those two names as POST TYPES, and no such post type exists
# on any real site — that was the headline error. But the names themselves
# were not invented: on a second real Etch site they turn up as OPTIONS,
# holding the custom-field-set and custom-post-type definitions the builder
# lets you declare. The first site had neither option, which is what made the
# earlier conclusion ("these names are fiction") look safe. Right names,
# wrong kind.
#
# `etch_cpts` DEFINES post types, so a site using it stores real content
# under names only that option knows (`fotos`, on the site this was found
# on). Migrating the definition without migrating the posts it describes left
# B with a registered-but-empty post type — a static post_types list cannot
# express "whatever etch_cpts happens to declare". Closed by issue #16's
# contract change: etch_post_types_dynamic above reads this option and claims
# the types it declares.
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

# Applied for real as of issue #13's fix: module_selection (lib/modules.sh)
# calls this and drops every matching name from etch_option_keys above and
# from any dynamic option key, before anything reaches the manifest. It is a
# second line of defence rather than the only one — etch_option_keys is an
# explicit allowlist that never names a license key in the first place — but
# it is no longer decorative, and a name added here now genuinely cannot
# migrate.
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
  # shellcheck disable=SC2034 # run_dir (one of this hook's 3 documented parameters, design doc Sec3.2) is genuinely unused by this implementation -- same pattern as modules/motopress.sh.example's state_dir, kept for contract fidelity, not a real cross-file case
  local run_dir="$1" id_map_tsv="$2" wp_cmd_b="$3"

  local ai_key
  ai_key=$($wp_cmd_b option get etch_settings --format=json 2>/dev/null \
    | jq -r '.ai_api_key // ""' 2>/dev/null || true)
  if [ -n "$ai_key" ]; then
    log_warn "etch post_import: B's etch_settings now carries a non-empty ai_api_key, copied from A along with the rest of the option. If B must not hold A's credential, clear it from Etch's settings on B."
  fi

  # Remap Etch's own component references.
  #
  # Etch templates and components point at each other BY POST ID, in a block
  # attribute of the form:
  #
  #     <!-- wp:etch/component {"ref":14468,"attributes":[]} -->
  #
  # Those ids change on import. graft's generic content remap
  # (lib/php/content-remap-functions.php) only rewrites `"id":<old>` and
  # `wp-image-<old>`, and only for attachments, so a component reference
  # travels to B still holding A's id.
  #
  # A single dangling reference is not a cosmetic defect: it takes the whole
  # template down. Observed on a real graft — one component out of three
  # landed on a new id, its two referring templates kept pointing at the old
  # one, and every page on B rendered as HTTP 200 with an EMPTY body while
  # the 404 template (which references no component) rendered perfectly.
  # `verify` reported PASS throughout.
  #
  # SCOPE: only the posts THIS run imported. B's pre-existing content is
  # protected by default-deny and is not this hook's to rewrite, even when it
  # holds a reference to an id that moved — that case is B's own content
  # being stale, a different problem with a different answer. Concretely, on
  # the run this was found on, that means fixing the imported `page` template
  # and deliberately NOT touching the `index` template that already existed
  # on B.
  #
  # Attachment rows are excluded from the map: `"ref"` addresses blocks, and
  # feeding attachment ids in would only create opportunities for a numeric
  # coincidence to rewrite something it shouldn't.
  [ -s "$id_map_tsv" ] || return 0

  local map_json ids_json
  map_json=$(awk -F'\t' '$3 != "attachment" && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { printf "%s %s\n", $1, $2 }' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ")) | map({(.[0]): (.[1] | tonumber)}) | add // {}')
  ids_json=$(awk -F'\t' '$3 != "attachment" && $2 ~ /^[0-9]+$/ { print $2 }' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber) | unique')

  if [ "$(printf '%s' "$map_json" | jq 'length')" = "0" ]; then
    log_info "etch post_import: no non-attachment id mappings in this run — no component references to remap"
    return 0
  fi

  # Two passes through a sentinel, for the same reason
  # sitegraft_remap_attachment_refs uses one: with a single pass, a mapping
  # that rewrites 16 -> 173 followed by one that rewrites 173 -> 200 would
  # rewrite what the first pass had just produced. The sentinel form is
  # invalid JSON on purpose, and only ever exists in memory between the two
  # passes — nothing half-transformed is ever written back.
  #
  # $wpdb->update rather than wp_update_post: this is a mechanical id
  # substitution, and running B's content back through the save filters
  # (block re-parsing, kses, slashing) would be a second, unrequested
  # transformation. clean_post_cache keeps the object cache honest afterwards.
  local php
  php=$(cat <<PHP
global \$wpdb;
\$map = json_decode('${map_json}', true);
\$ids = json_decode('${ids_json}', true);
if ( ! is_array( \$map ) || ! is_array( \$ids ) ) { echo "0"; return; }
\$changed = 0;
foreach ( \$ids as \$pid ) {
	\$content = get_post_field( 'post_content', \$pid );
	if ( ! is_string( \$content ) || '' === \$content ) { continue; }
	\$before = \$content;
	foreach ( \$map as \$old => \$new ) {
		\$content = preg_replace( '/"ref":' . \$old . '(?!\d)/', '"ref":@@' . \$old . '@@', \$content );
	}
	foreach ( \$map as \$old => \$new ) {
		\$content = str_replace( '"ref":@@' . \$old . '@@', '"ref":' . \$new, \$content );
	}
	if ( \$content !== \$before ) {
		\$wpdb->update( \$wpdb->posts, array( 'post_content' => \$content ), array( 'ID' => \$pid ) );
		clean_post_cache( \$pid );
		\$changed++;
	}
}
echo \$changed;
PHP
)

  log_info "etch post_import: remapping Etch component references across $(printf '%s' "$ids_json" | jq 'length') migrated post(s)..."
  # shellcheck disable=SC2086 # intentionally unquoted: wp_cmd_b may be a multi-word wrapper (e.g. ddev exec ... wp) and must word-split, same pattern as this repo's other documented run_or_echo call sites
  run_or_echo $wp_cmd_b eval "$php"
}

# design doc §12: Etch is one of the three rendering-stack components whose
# absence or version mismatch on B must block `graft`. The folder name is not
# ambiguous — it is the same literal "etch" that etch_detect searches
# .plugins[] for, verified on two real installs (1.4.11 and 1.6.5).
etch_stack_candidates() {
  echo "etch"
}
