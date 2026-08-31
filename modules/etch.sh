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
# ANYTHING ELSE IS WARNED ABOUT, LOUDLY, and claims nothing. This used to
# abort, and the abort was the defect (B1, third review round): it traded
# "this run migrates less than it could" for "this tool does not run at all",
# on the strength of one module failing to read one option — and it fired on
# `a:0:{}`, an empty array, as readily as on anything else. `scan` now asks
# wp-cli to unserialize (lib/inventory.sh), which removes the shape that made
# this common in the first place; what is left is genuinely unusual, and a
# warning naming the option and the consequence satisfies CLAUDE.md's "a
# skipped step is visible" without putting `plan` on the floor. The two
# fail-closed cases below (a scan with no options list, a scan with no
# post-type list) are NOT the same thing and still abort: those say the SCAN
# cannot be reasoned from at all, not that one value is odd.
#
# CONFIRMED (issue #16 fix-pack): a live Etch 1.6.6 install with a real,
# in-use custom post type was queried directly (`wp option get etch_cpts
# --format=json`). The row is the THIRD shape above — a map keyed by
# post-type name, each value a full registration-args object whose own
# `slug` field echoes the key:
#
#   {"fotos":{"name":"fotos","slug":"fotos","labels":{...},"public":true,...}}
#
# — which also settles where Etch reads it: `Etch\Services\ContentTypeService
# ::register_post_types()` (hooked on `init`, priority 5) calls
# `get_option('etch_cpts', [])` and `register_post_type($id, $args)` for
# every entry on EVERY request, including the one `wp import` itself
# bootstraps. That is the mechanism this file's `etch_post_type_defining_
# option_keys` below relies on: writing `etch_cpts` to B before `wp import`
# runs is sufficient for B to register the type in time, no mu-plugin
# involvement needed. The other two shapes remain plausible-but-unconfirmed
# defensive handling for a site this wasn't checked against.
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
      elif type == "object" then
        # N1: a SINGLE definition object -- {"slug":"fotos","label":"Fotos"} --
        # is a fourth shape, and `else .key` used to swallow it: it read the
        # FIELD NAMES ("slug", "label") as post-type names and exited 0. A map
        # of post types has an object on every value; a definition object does
        # not. Requiring that tells the two apart instead of guessing.
        (if (to_entries | all(.value | type == "object"))
         then (to_entries | map(.value.slug // .value.post_type // .key))
         else error("etch_cpts looks like a single definition object, not a map of post types")
         end)
      else error("etch_cpts is neither a list nor a map") end'

  if ! declared=$(printf '%s' "$raw" | jq -c "$prog" 2>&1); then
    # A value that is STILL a PHP-serialized string at this point means the
    # scan was taken before `sitegraft scan` started passing --unserialize to
    # wp-cli, or that the row is double-serialized. Worth saying by name: it
    # is the one diagnosis with a one-command fix. `a:`/`O:`/`s:`/`i:`/`b:`/
    # `d:`/`N:` are PHP's serialization type prefixes.
    local raw_str="" hint=""
    raw_str=$(printf '%s' "$raw" | jq -r 'if type == "string" then . else "" end' 2>/dev/null) || raw_str=""
    case "$raw_str" in
      [aOsibdN]:*) hint="The recorded value is still PHP-serialized, so this scan predates sitegraft passing --unserialize to 'wp option list' (or the row is doubly serialized) — re-run 'sitegraft scan' first. " ;;
    esac
    log_warn "etch: could not read the etch_cpts option recorded in ${scan_json} (${declared}) — claiming NO post types from it, and continuing. ${hint}If this site really does declare custom post types through etch_cpts, they will NOT be migrated, while etch_option_keys still carries the DEFINITION to B — which is issue #16's registered-but-empty post type, out loud this time. Fix or extend etch_post_types_dynamic for this site's shape, or name the post types by hand in a SITEGRAFT_MANIFEST_PREFILLED manifest."
    return 0
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
#
# `etch_taxonomies` (issue #82, found by Viktor while reviewing #16's own
# fix-pack): the exact same shape as `etch_cpts`, one level down.
# Etch\Services\ContentTypeService::register_taxonomies() -- hooked on
# `init`, priority 11, right alongside register_post_types()'s own
# priority-5 hook that etch_post_types_dynamic's header already traces --
# reads THIS option on every request and calls register_taxonomy() per
# entry. `etch_option_keys` never named it before this fix: `grep -rn
# etch_taxonomies` across the pre-#82 repo returned nothing, so a site
# using this feature had its taxonomy DEFINITION migrated nowhere, not
# even late -- worse than #16, whose etch_cpts at least reached B
# eventually via graft_migrate_options. Unlike etch_cpts, nothing here
# needs to PARSE this option's internal shape: no post-type-name-style
# selection exists for taxonomies (a taxonomy's own terms travel inside
# the WXR automatically, attached to whichever posts carry them -- see
# lib/php/wxr-taxonomies-cli.php's own header), so the value only ever
# needs to arrive on B intact, as an opaque blob, the same as every other
# name in this list. That also means this fix carries none of
# etch_post_types_dynamic's own shape risk: NOT independently re-verified
# against a live site in this session (no such install was reachable from
# it) -- but there is no parser here to be wrong about, only a value that
# either arrives on B before `wp import` runs (etch_taxonomy_defining_
# option_keys, below) or does not.
etch_option_keys() {
  cat <<'EOF'
etch_cfs
etch_cpts
etch_css_toolbar_values
etch_global_stylesheets
etch_loops
etch_settings
etch_styles
etch_taxonomies
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

# Issue #16, second half: migrating `etch_cpts` (etch_option_keys above)
# only wins if it lands on B before the WXR import runs. `etch_cpts` is
# what Etch reads on every `init` to register the post types it declares
# (see etch_post_types_dynamic's own "CONFIRMED" comment above for the
# live-site trace) — a static <mod>_post_types list can name the type, and
# etch_option_keys can carry its definition, but `graft` used to migrate
# ALL options (this one included) only in graft_migrate_options, which
# runs AFTER the WXR import. B's WordPress boot never saw the definition
# in time, `wp import` treated the type as unknown, and
# wordpress-importer silently skipped every post of it — caught loud only
# because issue #53's completeness gate now exists to catch it; before
# that, `verify` reported PASS with the content simply missing.
#
# graft_migrate_post_type_defining_options (lib/graft.sh) calls this
# function for every module in the manifest and pre-migrates exactly the
# option keys it names — the SAME guarded per-key logic
# graft_migrate_options itself uses (domain remap, the #73 usability gate,
# the "A has no such key, don't blank B" guard), never a shortcut around
# any of it. graft_migrate_options still migrates this key again, later,
# as always; writing the identical value twice is a harmless no-op.
#
# Every name returned here MUST also appear in etch_option_keys above —
# this narrows an existing claim, the same relationship
# etch_option_keys_exclude has to it, and does not establish one of its
# own. No _dynamic counterpart: unlike the CPT names themselves, WHICH
# option defines them is fixed knowledge about the plugin, not something
# that depends on any particular site's scan.
etch_post_type_defining_option_keys() {
  cat <<'EOF'
etch_cpts
EOF
}

# Issue #82: `etch_taxonomies`' own sibling of the hook just above, one
# level down -- a DIFFERENT module-contract hook, not etch_cpts's, because
# a taxonomy is not a post type (Etch's own ContentTypeService::
# register_taxonomies() is a separate `init`-priority-11 hook from
# register_post_types()'s priority-5 one -- see etch_option_keys' own
# comment on etch_taxonomies for the live trace), and conflating the two
# under one name would make graft_migrate_post_type_defining_options'
# own name a lie about what it migrates. graft_migrate_taxonomy_defining_
# options (lib/graft.sh) is the exact sibling function this hook feeds --
# same shared guarded path (_graft_migrate_options_named_by_hook), called
# from phase_graft at the identical point, right after mu-plugin deploy
# and before the WXR import: without this, `wp import` boots against a B
# that has not yet seen etch_taxonomies, Etch never registers the
# taxonomy in time, and wordpress-importer silently drops every term (and
# term relationship) that taxonomy defines -- landing the POST it was
# attached to regardless, since the post's own type is unaffected. That
# is exactly why issue #53's own item-count completeness gate cannot see
# this failure at all (its own header notes as much) and why this issue
# adds a dedicated guard instead: lib/verify.sh's
# verify_taxonomy_terms_present, fed by lib/php/wxr-taxonomies-cli.php,
# checks term-level completeness directly against the staged WXR rather
# than trusting anything read back out of this option.
#
# Same "MUST also appear in etch_option_keys above" and "no _dynamic
# counterpart" rules as etch_post_type_defining_option_keys, for the
# identical reason: WHICH option defines Etch's taxonomies is fixed
# knowledge about the plugin's own code, not something that depends on
# any particular site's scan.
etch_taxonomy_defining_option_keys() {
  cat <<'EOF'
etch_taxonomies
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
  # run_dir (design doc Sec3.2's 3rd hook parameter) is used below (issue
  # #52 fix-pack, review round 2): graft_record_module_content_rewrite
  # writes into it, so this is no longer the unused parameter the previous
  # comment here documented.
  local run_dir="$1" id_map_tsv="$2" wp_cmd_b="$3"

  local ai_key
  ai_key=$($wp_cmd_b option get etch_settings --format=json 2>/dev/null \
    | jq -r '.ai_api_key // ""' 2>/dev/null || true)
  if [ -n "$ai_key" ]; then
    log_warn "etch post_import: B's etch_settings now carries a non-empty ai_api_key, copied from A along with the rest of the option. If B must not hold A's credential, clear it from Etch's settings on B."
  fi

  # Remap Etch's own component references, AND (issue #84, added below)
  # dynamic-image mediaId references.
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
  # `wp:etch/dynamic-image` addresses its media the same broken way, one
  # differently-named attribute over:
  #
  #     <!-- wp:etch/dynamic-image {"attributes":{"mediaId":"35199"}} -->
  #
  # graft's generic content remap does not catch THIS either, and for the
  # same root cause: it only ever matches the literal JSON key `"id"`, never
  # `"mediaId"`. Measured on a real graft (this issue's own description):
  # 12 distinct mediaId values, 12 of 12 broken, all 12 already present in
  # id-map.tsv -- the mapping existed, nothing applied it. Its failure mode
  # is loud rather than silent (DynamicImageBlock::render_block renders
  # "Image with ID <n> not found" as the actual page content when
  # wp_get_attachment_metadata() finds nothing), which is precisely why a
  # human, not `verify`, is what caught it: a byte-for-byte content-equality
  # check cannot see a value that was supposed to change and did not (see
  # this issue's own report for the full reasoning) -- lib/verify.sh's
  # verify_id_references_resolve is issue #84's other half, and exists for
  # exactly that blind spot.
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

  local map_json ids_json media_map_json
  map_json=$(awk -F'\t' '$3 != "attachment" && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { printf "%s %s\n", $1, $2 }' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ")) | map({(.[0]): (.[1] | tonumber)}) | add // {}')
  ids_json=$(awk -F'\t' '$3 != "attachment" && $2 ~ /^[0-9]+$/ { print $2 }' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber) | unique')

  # OBSERVATION (review of PR #87): this scope does NOT exclude `term:`
  # rows the way lib/verify.sh's own guards do (verify_id_references_
  # resolve's `$3 !~ /^term:/`, and this issue's own new verify_component_
  # prop_references_resolve). Not a defect introduced here -- $ids_json
  # predates this issue (issue #52/#84) -- and NOT proven safe either:
  # term ids and post ids are INDEPENDENT sequences that both start at 1,
  # so a term row's second column CAN coincidentally equal a real post id,
  # in which case get_post_field would fetch that unrelated post's
  # content, and $ids would additionally offer it as a rewrite candidate.
  # This is pre-existing behavior, not something this issue's own fix
  # introduces or is asked to correct here -- recorded as an open
  # observation, not a settled safety claim, so a future reader does not
  # inherit a false "harmless miss" conclusion this comment used to state.
  # verify's own scope is the strictly narrower of the two either way.
  #
  # Issue #84: `wp:etch/dynamic-image`'s `mediaId` attribute holds an
  # ATTACHMENT id -- a different id space than "ref" above (component/
  # template posts), and the OPPOSITE filter of $map_json's for exactly the
  # same reason graft_remap_attachment_ids (lib/graft.sh) excludes
  # wp_navigation from ITS scope: an attachment id and a non-attachment
  # post id are independent sequences that both start at 1 on a fresh
  # site, so building one combined map from both kinds would let a
  # coincidental collision rewrite a "ref" as if it were a "mediaId" or
  # vice versa. Same shape as $map_json (a JSON object keyed by the OLD id,
  # mapping to the NEW id) -- kept a plain object rather than
  # graft_remap_attachment_ids' own {old,new} array-of-objects shape
  # (built for a different consumer, lib/php/verify-content-remap-cli.php)
  # so this stays a drop-in sibling of $map_json's own established
  # convention in this same function, not a second shape to remember.
  media_map_json=$(awk -F'\t' '$3 == "attachment" && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { printf "%s %s\n", $1, $2 }' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ")) | map({(.[0]): (.[1] | tonumber)}) | add // {}')

  # Issue #86 fix-pack (Viktor's review, blockers 1-3): OLD -> NEW id of every
  # migrated Etch COMPONENT (wp_block), same {old:new} object shape as
  # $map_json above -- not just the NEW ids. The component-prop remap pass
  # below now runs BEFORE $map/$media_map are applied, on content that
  # still carries A's OLD ids everywhere, including in a call site's own
  # "ref" -- so it needs the OLD id to look a component up by, the same way
  # every OTHER lookup in this function works from an OLD id. Discovery
  # itself still reads each component's CURRENT body from B (fetched by
  # its NEW id, the only id that resolves to a real post there) --
  # $component_map's VALUE, not its key.
  local component_map_json
  component_map_json=$(awk -F'\t' '$3 == "wp_block" && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { printf "%s %s\n", $1, $2 }' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ")) | map({(.[0]): (.[1] | tonumber)}) | add // {}')

  if [ "$(printf '%s' "$map_json" | jq 'length')" = "0" ]; then
    # A run whose id-map.tsv has zero non-attachment rows has, by
    # construction, zero rows in $ids_json too (both are filtered from the
    # exact same `$3 != "attachment"` rows) -- so there is no migrated
    # post left for a mediaId reference to even live inside, regardless of
    # how many attachments this run also mapped. Confirmed by this
    # function's own "does nothing when the run mapped only attachments"
    # test.
    log_info "etch post_import: no non-attachment id mappings in this run — no component or media references to remap"
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
  # issue #52 fix-pack, review round 2 (B2): the PHP body now echoes the
  # ACTUAL post ID it rewrote, one per line, instead of a bare unused
  # count ("$changed" was computed but never read by anything on the bash
  # side) -- graft_record_module_content_rewrite (lib/graft.sh) is what
  # turns that into the record lib/verify.sh's guard 1 excludes by.
  # Issue #84: mediaId. "mediaId" is DynamicImageBlock's own attribute --
  # declared type string in its register_block_type call, and read back
  # with is_string test, media id, else empty -- so a non-string value is
  # silently treated as ABSENT, never as a numeric id.
  #
  # THREE forms are matched below, and only ONE of them is actually
  # OBSERVED on the real Etch 1.6.6 site this fix-pack was measured
  # against -- the other two are deliberately defensive, not encountered:
  #
  #   1. quoted-string JSON, mediaId colon quote 35199 quote -- OBSERVED.
  #      Measured directly against wp_posts: 215 occurrences, 13 distinct
  #      attachment ids, zero of the other two forms anywhere in
  #      wp_posts/wp_options/wp_postmeta.
  #   2. bare-number JSON, mediaId colon 35199 with no quotes -- NOT
  #      observed. Nothing rules it out for a differently configured
  #      block or a future Etch version, and matching it costs nothing
  #      extra once the string form's sentinel technique exists.
  #   3. HTML-attribute form, mediaId equals quote 35199 quote (no colon)
  #      -- NOT observed either. Etch's own editor UI can render a block
  #      this way (fix-pack finding: shown directly in the editor as
  #      `<etch:img ... mediaId="35199" ... />`), but that is a rendered
  #      VIEW of the block, not what gets persisted -- confirmed by the
  #      same measurement above finding zero occurrences of this shape in
  #      any of the three tables. Matched anyway, defensively: if a
  #      future Etch version starts persisting this form somewhere this
  #      tool touches, it will already be covered rather than silently
  #      missed a second time.
  #
  # Same two-full-passes-through-a-sentinel technique as $map above, for
  # the identical reason -- a mapping that rewrites attachment 16 to 173
  # immediately followed by one that rewrites 173 to 200 must never
  # re-match what the first substitution just produced -- and the SAME
  # sentinel token, @@MEDIA_<old>@@, closes all three forms in one second
  # pass: pass 1 always leaves the token wrapped in whichever quoting (or
  # lack of it) the original value had, so a single str_replace of the
  # bare token in pass 2 resolves every case alike without needing to
  # know which one it was.
  #
  # NOT a "ref" false positive: Etch's editor also embeds a base64 JSON
  # blob under a `data-etch-context` HTML attribute on some raw-HTML
  # block content (confirmed present, in a `revision` post, on the real
  # site) carrying its OWN "ref" key, e.g. decoded:
  # {"name":"If (Condition)","structureState":"open","ref":"b753cpd"} --
  # an alphanumeric EDITOR element id (the UI's own bookkeeping for the
  # structure panel), never a WordPress post id. Quoted, and never purely
  # digits, so it can never match this file's own `"ref":[0-9]` pattern
  # (below) or verify_id_references_resolve's identical one
  # (lib/verify.sh) -- nothing to exclude in code, this is documentation
  # only, so the next reader does not mistake it for a missed reference.
  #
  # Issue #86: a component PROP with an operator-chosen name. `bild` above is
  # not a name this codebase can know in advance -- it is whatever the
  # component's AUTHOR called it. Measured on the real site this issue
  # reports (Etch 1.6.6): the component's OWN body reads its `mediaId` from
  # `{props.bild}`, and every CALL site
  # (`wp:etch/component {"ref":37496,"attributes":{"bild":"35253"}}`) still
  # carries A's raw attachment id under that name after graft, because no
  # fixed-key scan -- this hook's own `mediaId`/`ref` passes above, or
  # lib/verify.sh's `verify_id_references_resolve` -- ever looks at a key
  # named "bild". The component post is the source of truth for what "bild"
  # MEANS at every site that calls it, so this closes it in two passes: (1)
  # read each migrated component's OWN body once, to learn which of ITS
  # props feed directly into `mediaId`/`ref`/`parentPageID` -- the SAME
  # three attribute names verify_id_references_resolve treats as
  # unambiguous id references, so this discovery can never call a prop
  # id-bearing that guard would not also recognize; (2) at every
  # `wp:etch/component {"ref":R,...}` CALL SITE across this run's migrated
  # content, for exactly the props THAT component's own body marked
  # id-bearing, remap the literal value with the matching map (mediaId ->
  # $media_map, ref/parentPageID -> $map) -- never any OTHER prop, however
  # it is named. That is what keeps exigence #3 (a prop consumed somewhere
  # NOT id-bearing, e.g. a component's own `titre` holding the literal
  # string "2024") safe by construction: the per-prop verdict is scoped to
  # ONE component's OWN discovered map, never a global "this prop name
  # always means an id" table -- two different components are free to
  # reuse the same prop name for unrelated things without either one
  # leaking into the other.
  #
  # MEASURED, not assumed, on the real reference site: 9 migrated
  # components, 28 distinct `{props.X}` usages across them, exactly ONE
  # (`bild`, feeding `mediaId`) inside an id-bearing attribute -- everything
  # else lands in `href`/`content`/`aria-label`/`data-*`/`tag`, confirming
  # the "never touch a non-id-bearing prop" risk this issue calls out is
  # real, not hypothetical, and that this discovery mechanism actually
  # discriminates rather than sweeping every prop it sees.
  #
  # CASCADE DEPTH, decided from the same measurement: none of those 9
  # components' own bodies contains a NESTED `wp:etch/component` reference
  # -- every real call site on this site is a page/template calling a
  # component directly, one level deep. This fix therefore implements
  # DEPTH 1 ONLY: it discovers a prop as id-bearing when it feeds DIRECTLY
  # into a known attribute inside the SAME component that declares it,
  # never by tracing a prop passed straight through into ANOTHER
  # component's own id-bearing prop (component Y wrapping component X,
  # `{"ref":X,"attributes":{"innerBild":"{props.outerBild}"}}` inside Y's
  # own body). Going to depth N would mean building and maintaining a
  # fixpoint over the component call graph for a case that does not exist
  # anywhere on the one real site this was measured against. The gap is
  # not silent, though (CLAUDE.md: "a skipped step is visible"): the SAME
  # discovery pass below also checks whether a migrated component's own
  # body contains a nested `wp:etch/component` reference at all, and warns
  # BY NAME, every time, whether or not that nesting happens to carry an
  # id-bearing prop -- so a future site that composes components will
  # surface this fix's own scope limit instead of a quietly wrong
  # migration.
  #
  # FIX-PACK (Viktor's review of PR #87, execution-proven against PHP 8.5.7)
  # replaced the FIRST version's mechanism entirely -- it had three
  # interlocking defects, all with the same root cause: a pass grafted
  # AFTER the existing sentinel-protected ref/mediaId passes, without
  # inheriting their protection, that failed by opening up instead of
  # closing down.
  #
  # BLOCKER 1 (this file's OLD `$component_block_pattern`, a PCRE recursive
  # subpattern `(?P<attrs>\{(?:[^{}]+|(?P>attrs))*\})`): a single
  # UNBALANCED brace anywhere in a call site's JSON -- not even a whole
  # malformed block, one stray `{` or `}` -- drove `preg_match_all()` into
  # catastrophic backtracking, returning `false` (PREG_BACKTRACK_LIMIT_
  # ERROR) for the WHOLE post. Both this hook and lib/verify.sh's matching
  # guard treated `false` as "zero matches", so a single damaged block
  # silently reinstated issue #86 itself one level up: three raw ids left
  # on B, verify's guard reporting a green "(0 found to check)". Replaced
  # below with `sitegraft_json_span`/`sitegraft_find_component_blocks`/
  # `sitegraft_attributes_span` -- a hand-rolled, LINEAR, JSON-string-aware
  # brace scanner (never backtracks: one pass, one character at a time,
  # ignores braces inside quoted strings the same way a real JSON parser
  # would) that returns `null` on a genuinely unbalanced object instead of
  # hanging, and this hook now WARNS by post id (`MALFORMED_COMPONENT_
  # BLOCK:<pid>`, handled below) rather than silently treating the failure
  # as "nothing here". Measured: 4000 real component-call blocks in one
  # post, one deliberately truncated, parse and remap correctly in under a
  # second, no backtracking blowup, the malformed one flagged and skipped
  # -- see this PR's own description for the exact reproduction.
  #
  # BLOCKER 2 (no sentinel of its own): the FIRST version ran this pass
  # AFTER the ref/mediaId sentinel passes, reading its "old" value straight
  # out of `$content` -- which, whenever the component author's prop is
  # literally NAMED `mediaId` or `ref` (the single most natural name for a
  # prop that feeds exactly that attribute), had ALREADY been correctly
  # rewritten once by the fixed-key pass above. This pass then treated that
  # ALREADY-correct new id as if it were still an old one and looked it up
  # a second time -- a genuine double remap whenever id-map.tsv happened to
  # chain (a real attachment's NEW id equal to a DIFFERENT attachment's OLD
  # id, both legitimate rows). Worse than the bug being fixed: not a loud
  # "Image with ID … not found", but a real attachment silently swapped for
  # the WRONG one. Fixed by running this pass FIRST, against genuinely
  # untouched original content (so "old" always means A's real value, never
  # something an earlier pass already produced), and by disguising every
  # value it computes behind a token (`@@CPROP_<pid>_<seq>@@`) that cannot
  # possibly match ANY fixed-key pass's own digit-only patterns -- resolved
  # to the real final value only after the ref/mediaId passes have already
  # run. Two different mechanisms, one deliberately un-overlapping with the
  # other, rather than one mechanism trying to out-guess the other's timing.
  #
  # BLOCKER 3 (substitution scoped to the WHOLE block, not to `attributes`):
  # the FIRST version's `str_replace()` searched the block's entire JSON
  # text, so a prop literally named `ref` collided with that SAME block's
  # own top-level `"ref"` (the component pointer), and a component using
  # Etch's `metadata.bindings` mirror (`{"attributes":{"bild":"35253"},
  # "metadata":{"bindings":{"bild":"35253"}}}`) had BOTH copies rewritten
  # though only the `attributes` one was ever discovered as id-bearing.
  # `sitegraft_attributes_span` now locates the byte span of JUST the
  # `"attributes":{...}` value (the same linear scanner, applied to a
  # narrower search), and every substitution is bounded to exactly that
  # span -- text outside it, including the block's own `"ref"` and any
  # `metadata` sibling, is byte-for-byte unreachable by construction, not
  # merely unlikely to collide.
  #
  # A prop that resolves to nothing NEW to say for a given call (its value
  # is not a literal digit -- most commonly an unresolved `{props.X}`
  # pass-through, issue #86's own depth-1 cascade case) is left completely
  # untouched, same guarantee as before this fix-pack, now proven directly
  # against the exact scenario BLOCKER 2 exploited (see this file's own
  # test suite).
  #

#
# NOTE ON WHY THE PHP BELOW STAYS COMMENT-FREE: an inline "//" PHP
  # comment holding an UNBALANCED parenthesis on its own line (an opening
  # "(" on one line, its matching ")" only on a later line) breaks this
  # bash 3.2's own here-doc-inside-command-substitution parser --
  # execution-proven while writing this fix-pack (a "syntax error near
  # unexpected token" pointing at the PHP comment line itself, gone the
  # moment the same explanation moved up here instead). Keeping the
  # heredoc body itself free of prose comments, exactly as it already was
  # before this change, sidesteps the whole class of bug rather than
  # hunting for which single parenthesis broke it.
  local php
  php=$(cat <<PHP
function sitegraft_json_span( \$text, \$start ) {
	\$len = strlen( \$text );
	if ( \$start >= \$len || \$text[ \$start ] !== '{' ) { return null; }
	\$depth = 0;
	\$in_string = false;
	\$escaped = false;
	for ( \$i = \$start; \$i < \$len; \$i++ ) {
		\$ch = \$text[ \$i ];
		if ( \$in_string ) {
			if ( \$escaped ) {
				\$escaped = false;
			} elseif ( '\\\\' === \$ch ) {
				\$escaped = true;
			} elseif ( '"' === \$ch ) {
				\$in_string = false;
			}
			continue;
		}
		if ( '"' === \$ch ) {
			\$in_string = true;
		} elseif ( '{' === \$ch ) {
			\$depth++;
		} elseif ( '}' === \$ch ) {
			\$depth--;
			if ( 0 === \$depth ) {
				return array( \$start, \$i + 1 );
			}
		}
	}
	return null;
}
function sitegraft_find_component_blocks( \$content ) {
	\$blocks = array();
	\$prefix = '<!-- wp:etch/component ';
	\$offset = 0;
	\$len = strlen( \$content );
	while ( true ) {
		\$pos = strpos( \$content, \$prefix, \$offset );
		if ( false === \$pos ) { break; }
		\$json_start = \$pos + strlen( \$prefix );
		while ( \$json_start < \$len && ( ' ' === \$content[ \$json_start ] || "\t" === \$content[ \$json_start ] || "\n" === \$content[ \$json_start ] || "\r" === \$content[ \$json_start ] ) ) {
			\$json_start++;
		}
		if ( \$json_start >= \$len || '{' !== \$content[ \$json_start ] ) {
			if ( '-->' === substr( \$content, \$json_start, 3 ) || '/-->' === substr( \$content, \$json_start, 4 ) ) {
				\$offset = \$json_start;
				continue;
			}
			\$blocks[] = array( 'ok' => false, 'offset' => \$pos );
			\$offset = \$pos + strlen( \$prefix );
			continue;
		}
		\$span = sitegraft_json_span( \$content, \$json_start );
		if ( null === \$span ) {
			\$blocks[] = array( 'ok' => false, 'offset' => \$pos );
			\$offset = \$json_start + 1;
			continue;
		}
		\$blocks[] = array( 'ok' => true, 'start' => \$span[0], 'end' => \$span[1] );
		\$offset = \$span[1];
	}
	return \$blocks;
}
function sitegraft_attributes_span( \$content, \$block_start, \$block_end ) {
	\$needle = '"attributes":';
	\$pos = strpos( \$content, \$needle, \$block_start );
	if ( false === \$pos || \$pos >= \$block_end ) { return null; }
	\$val_start = \$pos + strlen( \$needle );
	while ( \$val_start < \$block_end && ' ' === \$content[ \$val_start ] ) { \$val_start++; }
	if ( \$val_start >= \$block_end || '{' !== \$content[ \$val_start ] ) { return null; }
	\$span = sitegraft_json_span( \$content, \$val_start );
	if ( null === \$span || \$span[1] > \$block_end ) { return null; }
	return \$span;
}

global \$wpdb;
\$map = json_decode('${map_json}', true);
\$media_map = json_decode('${media_map_json}', true);
\$ids = json_decode('${ids_json}', true);
\$component_map = json_decode('${component_map_json}', true);
if ( ! is_array( \$map ) || ! is_array( \$media_map ) || ! is_array( \$ids ) || ! is_array( \$component_map ) ) { return; }
\$component_prop_map = array();
foreach ( \$component_map as \$old_cid => \$new_cid ) {
	\$new_cid = (int) \$new_cid;
	\$cbody = get_post_field( 'post_content', \$new_cid );
	if ( is_string( \$cbody ) && '' !== \$cbody ) {
		if ( preg_match_all( '/"(mediaId|ref|parentPageID)":"\{props\.([A-Za-z0-9_]+)\}"/', \$cbody, \$pm, PREG_SET_ORDER ) ) {
			foreach ( \$pm as \$prow ) {
				\$component_prop_map[ (string) \$old_cid ][ \$prow[2] ] = \$prow[1];
			}
		}
		if ( preg_match( '#<!--\s+wp:etch/component\s+#', \$cbody ) ) {
			echo 'NESTED_COMPONENT:' . \$new_cid . "\n";
		}
	}
}
foreach ( \$ids as \$pid ) {
	\$content = get_post_field( 'post_content', \$pid );
	if ( ! is_string( \$content ) || '' === \$content ) { continue; }
	\$before = \$content;
	\$cprop_tokens = array();
	if ( ! empty( \$component_prop_map ) ) {
		\$blocks = sitegraft_find_component_blocks( \$content );
		\$edits = array();
		\$seq = 0;
		foreach ( \$blocks as \$block ) {
			if ( empty( \$block['ok'] ) ) {
				echo 'MALFORMED_COMPONENT_BLOCK:' . \$pid . "\n";
				continue;
			}
			\$block_text = substr( \$content, \$block['start'], \$block['end'] - \$block['start'] );
			\$decoded = json_decode( \$block_text, true );
			if ( null === \$decoded ) {
				echo 'MALFORMED_COMPONENT_BLOCK:' . \$pid . "\n";
				continue;
			}
			if ( ! is_array( \$decoded ) || ! isset( \$decoded['ref'] ) ) { continue; }
			\$old_ref = (string) (int) \$decoded['ref'];
			if ( ! isset( \$component_prop_map[ \$old_ref ] ) ) { continue; }
			\$call_attrs = ( isset( \$decoded['attributes'] ) && is_array( \$decoded['attributes'] ) ) ? \$decoded['attributes'] : array();
			if ( empty( \$call_attrs ) ) { continue; }
			\$attrs_span = sitegraft_attributes_span( \$content, \$block['start'], \$block['end'] );
			if ( null === \$attrs_span ) { continue; }
			\$attrs_text = substr( \$content, \$attrs_span[0], \$attrs_span[1] - \$attrs_span[0] );
			\$attrs_before = \$attrs_text;
			foreach ( \$component_prop_map[ \$old_ref ] as \$propname => \$kind ) {
				if ( ! array_key_exists( \$propname, \$call_attrs ) ) { continue; }
				\$val = \$call_attrs[ \$propname ];
				\$old_val = null;
				\$quoted = false;
				if ( is_int( \$val ) ) {
					\$old_val = (string) \$val;
				} elseif ( is_string( \$val ) && preg_match( '/^\d+\z/', \$val ) ) {
					\$old_val = \$val;
					\$quoted = true;
				}
				if ( null === \$old_val ) { continue; }
				\$submap = ( 'mediaId' === \$kind ) ? \$media_map : \$map;
				if ( ! isset( \$submap[ \$old_val ] ) ) { continue; }
				\$new_val = \$submap[ \$old_val ];
				\$seq++;
				\$token = '@@CPROP_' . \$pid . '_' . \$seq . '@@';
				\$search = \$quoted ? ( '"' . \$propname . '":"' . \$old_val . '"' ) : ( '"' . \$propname . '":' . \$old_val );
				\$replace = \$quoted ? ( '"' . \$propname . '":"' . \$token . '"' ) : ( '"' . \$propname . '":' . \$token );
				\$attrs_text = str_replace( \$search, \$replace, \$attrs_text );
				\$cprop_tokens[ \$token ] = \$new_val;
			}
			if ( \$attrs_text !== \$attrs_before ) {
				\$edits[ \$attrs_span[0] ] = array( \$attrs_span[1] - \$attrs_span[0], \$attrs_text );
			}
		}
		if ( ! empty( \$edits ) ) {
			krsort( \$edits );
			foreach ( \$edits as \$eoffset => \$edata ) {
				\$content = substr_replace( \$content, \$edata[1], \$eoffset, \$edata[0] );
			}
		}
	}
	foreach ( \$map as \$old => \$new ) {
		\$content = preg_replace( '/"ref":' . \$old . '(?!\d)/', '"ref":@@' . \$old . '@@', \$content );
	}
	foreach ( \$map as \$old => \$new ) {
		\$content = str_replace( '"ref":@@' . \$old . '@@', '"ref":' . \$new, \$content );
	}
	foreach ( \$media_map as \$old => \$new ) {
		\$content = preg_replace( '/"mediaId":"' . \$old . '"/', '"mediaId":"@@MEDIA_' . \$old . '@@"', \$content );
		\$content = preg_replace( '/"mediaId":' . \$old . '(?!\d)/', '"mediaId":@@MEDIA_' . \$old . '@@', \$content );
		\$content = preg_replace( '/mediaId="' . \$old . '"/', 'mediaId="@@MEDIA_' . \$old . '@@"', \$content );
	}
	foreach ( \$media_map as \$old => \$new ) {
		\$content = str_replace( '@@MEDIA_' . \$old . '@@', \$new, \$content );
	}
	if ( ! empty( \$cprop_tokens ) ) {
		foreach ( \$cprop_tokens as \$token => \$new_val ) {
			\$content = str_replace( \$token, \$new_val, \$content );
		}
	}
	if ( \$content !== \$before ) {
		\$wpdb->update( \$wpdb->posts, array( 'post_content' => \$content ), array( 'ID' => \$pid ) );
		clean_post_cache( \$pid );
		echo \$pid . "\n";
	}
}
PHP
)

  log_info "etch post_import: remapping Etch component and mediaId references across $(printf '%s' "$ids_json" | jq 'length') migrated post(s)..."
  # `&&`/`||`, not a bare assignment -- run_or_echo's own real exit status
  # (the eval call's) must survive as THIS function's return value, the
  # same as it did before this restructuring; without it, the while loop
  # a few lines below becomes the last command bash evaluates, and a
  # `while read` over an EMPTY here-string returns 1 (its own EOF), which
  # would silently turn a successful, no-op run into a false failure --
  # execution-proven (existing tests broke on exactly this before the fix).
  local rewritten_ids rc
  # shellcheck disable=SC2086 # intentionally unquoted: wp_cmd_b may be a multi-word wrapper (e.g. ddev exec ... wp) and must word-split, same pattern as this repo's other documented run_or_echo call sites
  rewritten_ids=$(run_or_echo $wp_cmd_b eval "$php") && rc=0 || rc=$?
  # Under --dry-run, run_or_echo never ran the real eval -- $rewritten_ids
  # is its own "[dry-run] ..." echo text, printed here (unchanged CLI
  # contract: an operator running --dry-run still sees what would have
  # run) rather than fed to graft_record_module_content_rewrite, which
  # would otherwise try to parse that text as a post ID and correctly
  # refuse it (digit-only guard), but silently -- printing it is the
  # existing, tested behavior this preserves.
  if is_dry_run; then
    [ -n "$rewritten_ids" ] && printf '%s\n' "$rewritten_ids"
  else
    local pid
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      case "$pid" in
        NESTED_COMPONENT:*)
          # Issue #86's own documented scope limit, surfaced rather than
          # silently swallowed by graft_record_module_content_rewrite's own
          # digit-only guard (it would otherwise just refuse this line and
          # say nothing): a migrated component's OWN body calls ANOTHER
          # component. This hook's discovery only looks one level deep — a
          # prop the OUTER component passes straight through into the
          # INNER one's id-bearing prop is not learned, so a caller of the
          # OUTER component supplying a raw id through that chain will not
          # be remapped here. Not observed on the reference site this fix
          # was measured against; named so a future site that composes
          # components this way does not migrate silently wrong.
          log_warn "etch post_import: component ${pid#NESTED_COMPONENT:} itself calls another wp:etch/component — component composition detected, one level deeper than this fix's prop discovery looks (issue #86). A prop this component passes straight through into the nested component's own mediaId/ref/parentPageID will not be remapped at THIS component's own call sites."
          ;;
        MALFORMED_COMPONENT_BLOCK:*)
          # Issue #86 fix-pack (blocker 1): a wp:etch/component call site on
          # this post did not parse as balanced JSON -- sitegraft_json_span
          # (this hook's own PHP) returned null for it rather than hanging
          # or guessing. That ONE occurrence's props were left unremapped
          # (fail closed, not silently skipped); every OTHER, well-formed
          # occurrence on the SAME post was still processed normally, and
          # the post may still have been recorded as rewritten below for
          # those. Surfaced by name so an operator can inspect the post
          # directly rather than trusting a scan that quietly gave up.
          log_warn "etch post_import: post ${pid#MALFORMED_COMPONENT_BLOCK:} has a wp:etch/component block whose JSON did not parse as balanced (issue #86 fix-pack) — that occurrence's props were left unremapped; every other occurrence on the same post was still processed."
          ;;
        *)
          graft_record_module_content_rewrite "$run_dir" "$pid"
          ;;
      esac
    done <<< "$rewritten_ids"
  fi
  return "$rc"
}

# design doc §12: Etch is one of the three rendering-stack components whose
# absence or version mismatch on B must block `graft`. The folder name is not
# ambiguous — it is the same literal "etch" that etch_detect searches
# .plugins[] for, verified on two real installs (1.4.11 and 1.6.5).
etch_stack_candidates() {
  echo "etch"
}
