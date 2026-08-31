bats_require_minimum_version 1.5.0

# tests/unit/test_etch_module.bats — modules/etch.sh: Step 6 self-review
# finding (design doc §3.3 vs. code) — this module was fully specified in
# the design doc but never actually created under modules/, so a real Etch
# site's content never got auto-detected into `plan`'s migrate defaults.
# Loaded directly (not via modules_discover), same convention as
# tests/unit/test_core_wp_module.bats uses for modules/core-wp.sh.
setup() {
  load '../../lib/core.sh'
  # issue #52 fix-pack, review round 2: etch_post_import now calls
  # graft_record_module_content_rewrite (lib/graft.sh).
  load '../../lib/graft.sh'
  # shellcheck disable=SC1091
  load '../../modules/etch.sh'
}

@test "etch_name returns a human-readable label" {
  run etch_name
  [ "$output" = "Etch" ]
}

@test "etch_detect matches a scan showing the etch plugin" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"plugins":[{"name":"etch","version":"2.0"}]}' > "$scan"
  run etch_detect "$scan"
  [ "$status" -eq 0 ]
}

@test "etch_detect does not match a scan without the etch plugin" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"plugins":[{"name":"some-other-plugin"}]}' > "$scan"
  run etch_detect "$scan"
  [ "$status" -ne 0 ]
}

# This test used to assert etch_cfs/etch_cpts/etch_loops as POST TYPES, taken
# from the design doc. None of the three exists on a real Etch install —
# verified by querying wp_posts directly, which is independent of whether a
# plugin registers its types in a CLI context. Etch keeps its content in
# WordPress's own types, and `etch_cfs`/`etch_cpts` are real but are OPTIONS
# (asserted below). The old expectation was the reason plan offered three
# phantom types, graft exported an empty WXR, and verify still reported PASS.
@test "etch_post_types declares the WordPress types Etch actually stores content in" {
  run etch_post_types
  [[ "$output" == *"wp_block"* ]] || false
  [[ "$output" == *"wp_template"* ]] || false
  [[ "$output" == *"wp_global_styles"* ]] || false
}

@test "etch_post_types declares none of the three types that do not exist" {
  run etch_post_types
  [[ "$output" != *"etch_cfs"* ]] || false
  [[ "$output" != *"etch_cpts"* ]] || false
  [[ "$output" != *"etch_loops"* ]] || false
}

@test "etch_option_keys declares etch_cfs, etch_cpts and etch_loops, which are options" {
  run etch_option_keys
  [[ "$output" == *"etch_cfs"* ]] || false
  [[ "$output" == *"etch_cpts"* ]] || false
  [[ "$output" == *"etch_loops"* ]] || false
}

@test "etch_option_keys declares the settings/styles/toolbar/stylesheet keys" {
  run etch_option_keys
  [[ "$output" == *"etch_settings"* ]] || false
  [[ "$output" == *"etch_styles"* ]] || false
  [[ "$output" == *"etch_css_toolbar_values"* ]] || false
  [[ "$output" == *"etch_global_stylesheets"* ]] || false
}

# --- etch_post_types_dynamic: issue #16. Etch lets a site declare its own
# post types in the `etch_cpts` option. Migrating that option carried the
# DEFINITION to B and none of the POSTS, leaving the type registered and
# empty. The names are only knowable from the scanned site's own option
# data, so a static list cannot express them. See
# docs/decisions/0007-module-dynamic-selections.md.
@test "etch_post_types_dynamic claims the post types etch_cpts declares as a list of objects (#16)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"page"},{"name":"fotos"},{"name":"projekte"}],
 "options":[{"option_name":"etch_cpts","option_value":[{"slug":"fotos","label":"Fotos"},{"slug":"projekte","label":"Projekte"}]}]}
EOF
  run etch_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fotos"* ]] || false
  [[ "$output" == *"projekte"* ]] || false
}

@test "etch_post_types_dynamic reads etch_cpts when the scan carries it as a JSON string rather than a decoded structure (#16)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"fotos"}],
 "options":[{"option_name":"etch_cpts","option_value":"[{\"slug\":\"fotos\"}]"}]}
EOF
  run etch_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ "$output" = "fotos" ]
}

@test "etch_post_types_dynamic reads an etch_cpts map keyed by post-type slug (#16)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"fotos"}],
 "options":[{"option_name":"etch_cpts","option_value":{"fotos":{"label":"Fotos"}}}]}
EOF
  run etch_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ "$output" = "fotos" ]
}

@test "etch_post_types_dynamic claims nothing on a site that never used etch_cpts" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"post_types":[{"name":"page"}],"options":[{"option_name":"etch_settings","option_value":"{}"}]}' > "$scan"
  run etch_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "etch_post_types_dynamic treats an empty etch_cpts as 'nothing declared', not as an error" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"post_types":[{"name":"page"}],"options":[{"option_name":"etch_cpts","option_value":[]}]}' > "$scan"
  run etch_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# CLAUDE.md's first rule, in its original form: `plan` once offered post
# types that did not exist, `graft` exported an empty WXR, and `verify` said
# PASS. A name declared in etch_cpts but absent from the site's own
# post-type list is exactly that shape, so it is dropped — out loud.
@test "etch_post_types_dynamic drops, with a warning, a declared type the scanned site does not actually register" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"fotos"}],
 "options":[{"option_name":"etch_cpts","option_value":[{"slug":"fotos"},{"slug":"ghost_type"}]}]}
EOF
  # --separate-stderr: the warning names the dropped type, so a merged
  # $output could not tell "it was skipped, out loud" from "it was claimed".
  run --separate-stderr etch_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ "$output" = "fotos" ]
  [[ "$stderr" == *"ghost_type"* ]] || false
  [[ "$stderr" == *"not registered"* ]] || false
}

# B1 (third review round). This test used to RATIFY an abort here,
# and the abort was the defect: with the scan now recording unserialized
# option values (lib/inventory.sh passes --unserialize), a residual PHP
# serialized string is an oddity, but taking `plan` down over one module's
# unreadable option trades "an incomplete migration" for "an unusable tool"
# — including for the wholly benign empty array `a:0:{}`. A loud warning
# plus an empty claim satisfies CLAUDE.md's "a skipped step is visible"
# without stopping the run, and the operator still sees, by name, exactly
# what was not claimed.
@test "etch_post_types_dynamic warns loudly and claims nothing on an etch_cpts value it cannot read, instead of taking plan down" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"fotos"}],
 "options":[{"option_name":"etch_cpts","option_value":"a:1:{i:0;a:1:{s:4:\"slug\";s:5:\"fotos\";}}"}]}
EOF
  run --separate-stderr etch_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"etch_cpts"* ]] || false
  # The residual-serialization case is named as such, not reported as some
  # generic parse failure — that is the one hint that tells an operator
  # their scan predates --unserialize.
  [[ "$stderr" == *"PHP-serialized"* ]] || false
}

@test "etch_post_types_dynamic does not abort on an empty PHP-serialized array, the most harmless value there is" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"fotos"}],
 "options":[{"option_name":"etch_cpts","option_value":"a:0:{}"}]}
EOF
  run --separate-stderr etch_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"etch_cpts"* ]] || false
}

# N1 (third review round): a SINGLE definition object
# {"slug":"fotos","label":"Fotos"} is a fourth shape, and the map branch used
# to swallow it — reading its FIELD NAMES ("slug", "label") as post-type
# names and exiting 0. Silently wrong beats loudly wrong here, so the map
# branch now requires every value to be an object.
@test "etch_post_types_dynamic refuses a single etch_cpts definition object instead of reading its field names as post types (N1)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"fotos"},{"name":"slug"},{"name":"label"}],
 "options":[{"option_name":"etch_cpts","option_value":{"slug":"fotos","label":"Fotos"}}]}
EOF
  run --separate-stderr etch_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"single definition object"* ]] || false
}

# N2 (third review round): neutralising either name guard used to
# leave this file green, so neither was actually proven to catch anything.
@test "etch_post_types_dynamic refuses a declared name carrying an uppercase letter, which no WordPress post type may (N2)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"Fotos"}],
 "options":[{"option_name":"etch_cpts","option_value":["Fotos"]}]}
EOF
  run etch_post_types_dynamic "$scan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Fotos"* ]] || false
  [[ "$output" == *"not a valid WordPress post-type name"* ]] || false
}

@test "etch_post_types_dynamic refuses a declared name longer than WordPress's 20-character limit (N2)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  # 21 characters exactly — one past the limit, so the guard's boundary is
  # what is under test, not merely "something very long".
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"abcdefghijklmnopqrstu"}],
 "options":[{"option_name":"etch_cpts","option_value":["abcdefghijklmnopqrstu"]}]}
EOF
  run etch_post_types_dynamic "$scan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"20-character"* ]] || false
}

@test "etch_post_types_dynamic fails closed on a scan with no options list, rather than reporting 'nothing declared'" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"post_types":[{"name":"page"}]}' > "$scan"
  run etch_post_types_dynamic "$scan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"options"* ]] || false
}

@test "etch_post_types_dynamic fails closed when the scan has no post-type list to check declarations against" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"options":[{"option_name":"etch_cpts","option_value":[{"slug":"fotos"}]}]}' > "$scan"
  run etch_post_types_dynamic "$scan"
  [ "$status" -ne 0 ]
}

@test "etch_option_keys_exclude excludes license and db_version globs" {
  run etch_option_keys_exclude
  [[ "$output" == *"etch_license_*"* ]] || false
  [[ "$output" == *"etch_db_version"* ]] || false
}

# --- etch_post_type_defining_option_keys (issue #16, second half): the
# registered-but-empty-post-type defect was an ORDERING bug, not a
# selection bug — etch_post_types_dynamic (above) already claimed 'fotos'
# correctly. graft.sh's graft_migrate_post_type_defining_options
# (lib/graft.sh) calls this to know WHICH of etch's own option keys must
# reach B before the WXR import runs.
@test "etch_post_type_defining_option_keys names etch_cpts" {
  run etch_post_type_defining_option_keys
  [ "$output" = "etch_cpts" ]
}

# Every name this function returns is a narrowing of an existing claim
# (same relationship etch_option_keys_exclude has), never a claim of its
# own — a name it returns that etch_option_keys does not also list would
# be pre-migrated by graft_migrate_post_type_defining_options but then
# never appear in plan's selection at all, since only etch_option_keys
# (and etch_option_keys_dynamic, which etch.sh does not define) ever
# reaches the manifest in the first place.
@test "every name etch_post_type_defining_option_keys returns is also claimed by etch_option_keys" {
  local declared_keys option_keys name found
  declared_keys=$(etch_post_type_defining_option_keys)
  option_keys=$(etch_option_keys)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    found=0
    while IFS= read -r ok; do
      [ "$ok" = "$name" ] && found=1
    done <<< "$option_keys"
    [ "$found" -eq 1 ] || { echo "'${name}' is not in etch_option_keys"; false; }
  done <<< "$declared_keys"
}

# --- etch_taxonomy_defining_option_keys (issue #82): the exact same
# ordering defect as issue #16, one level down -- a taxonomy Etch
# registers dynamically from etch_taxonomies (Etch\Services\
# ContentTypeService::register_taxonomies(), init priority 11) must reach
# B before the WXR import runs, or wordpress-importer silently drops
# every term (and term relationship) that taxonomy defines, landing the
# post it was attached to regardless.
@test "etch_option_keys declares etch_taxonomies" {
  run etch_option_keys
  [[ "$output" == *"etch_taxonomies"* ]] || false
}

@test "etch_taxonomy_defining_option_keys names etch_taxonomies" {
  run etch_taxonomy_defining_option_keys
  [ "$output" = "etch_taxonomies" ]
}

# Same "must also be claimed by etch_option_keys" invariant as the
# post-type-defining hook's own test above, and for the identical reason:
# a name this function returns that etch_option_keys does not also list
# would be pre-migrated by graft_migrate_taxonomy_defining_options but
# never appear in plan's selection at all.
@test "every name etch_taxonomy_defining_option_keys returns is also claimed by etch_option_keys" {
  local declared_keys option_keys name found
  declared_keys=$(etch_taxonomy_defining_option_keys)
  option_keys=$(etch_option_keys)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    found=0
    while IFS= read -r ok; do
      [ "$ok" = "$name" ] && found=1
    done <<< "$option_keys"
    [ "$found" -eq 1 ] || { echo "'${name}' is not in etch_option_keys"; false; }
  done <<< "$declared_keys"
}

# --- etch_stack_candidates: the one addition beyond the design doc's §3.3
# code block, flagged in the PR as a judgment call (see modules/etch.sh's
# own comment on this function for the full reasoning).
@test "etch_stack_candidates declares the single unambiguous 'etch' slug" {
  run etch_stack_candidates
  [ "$output" = "etch" ]
}

@test "modules_discover accepts the real modules/etch.sh as a valid module (full contract satisfied)" {
  load '../../lib/modules.sh'
  # Same convention as test_modules.bats' own motopress.sh.example coverage
  # (N1): copy the real shipped file into an isolated temp modules dir,
  # rather than pointing SITEGRAFT_MODULES_DIR at the repo's real modules/
  # directly — this test only cares about etch.sh, not every module that
  # happens to exist in the repo at the same time.
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules-etch"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cp "${BATS_TEST_DIRNAME}/../../modules/etch.sh" "$SITEGRAFT_MODULES_DIR/etch.sh"
  modules_discover
  [[ " ${SITEGRAFT_MODULES} " == *" etch "* ]] || false
}

# --- etch_post_import: Etch's own component references ----------------------
#
# Etch templates address components by post ID (`{"ref":14468}`), those ids
# change on import, and graft's generic content remap only handles attachment
# `"id":` and `wp-image-`. One dangling reference takes a whole template down:
# on a real graft every page served HTTP 200 with an empty body while the 404
# template, which references no component, rendered perfectly.
#
# These exercise the bash half — which mappings are built, and from which rows
# — by capturing the PHP the hook hands to wp-cli.
_etch_capture_eval() {
  case "$1" in
    option) echo '{}' ;;
    eval)   printf '%s' "$2" > "$BATS_TEST_TMPDIR/php.txt" ;;
  esac
}

@test "etch_post_import builds its ref map from non-attachment rows only" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '14468\t15506\twp_block\n900\t901\tattachment\n14279\t15505\twp_template\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  grep -q '"14468":15506' "$BATS_TEST_TMPDIR/php.txt"
  grep -q '"14279":15505' "$BATS_TEST_TMPDIR/php.txt"
  # `"ref"` addresses blocks; feeding attachment ids in would only give a
  # numeric coincidence something to match. Checked against the \$map line
  # SPECIFICALLY (issue #84: the file as a whole now legitimately mentions
  # "900" too, in the SEPARATE \$media_map line -- checking the whole file,
  # as this test used to, would fail on that correct new behavior). Written
  # as an explicit if/return (SC2314) rather than `! grep -q ... || false`
  # as the test's last statement — that shape is only load-bearing because
  # nothing follows it; an assertion appended after it would silently stop
  # being checked.
  local map_line
  map_line=$(grep '^\$map = json_decode' "$BATS_TEST_TMPDIR/php.txt")
  if printf '%s' "$map_line" | grep -q '"900"'; then
    echo "attachment id leaked into the ref map" >&2; return 1
  fi
}

@test "etch_post_import scopes the rewrite to the posts this run imported" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '14468\t15506\twp_block\n14279\t15505\twp_template\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  # NEW ids (column 2) are the posts to walk — B's pre-existing content is
  # protected by default-deny and is not this hook's to rewrite.
  grep -q '\[15505,15506\]\|\[15506,15505\]' "$BATS_TEST_TMPDIR/php.txt"
}

@test "etch_post_import does nothing when the run mapped only attachments" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '900\t901\tattachment\n' > "$tsv"
  rm -f "$BATS_TEST_TMPDIR/php.txt"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/php.txt" ]
}

# --- issue #52 fix-pack, review round 2 (B2's real fix): recording which --
# posts etch_post_import actually rewrote, for lib/verify.sh's guard 1 to
# exclude by POST, not by post_type.

@test "etch_post_import records each ACTUALLY-rewritten post id via graft_record_module_content_rewrite, and only those" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '14468\t15506\twp_block\n14279\t15505\twp_template\n' > "$tsv"
  # Simulates the real wp-cli eval: of the two posts in scope, only 15506
  # actually contained a "ref" that changed -- 15505 has no ref to
  # rewrite, so the real PHP loop's own `if ($content !== $before)` guard
  # would never echo it.
  _etch_capture_eval_real() {
    case "$1" in
      option) echo '{}' ;;
      eval) echo "15506" ;;
    esac
  }
  etch_post_import "$run_dir" "$tsv" "_etch_capture_eval_real"
  [ -f "${run_dir}/module-content-rewrites.tsv" ]
  [ "$(cat "${run_dir}/module-content-rewrites.tsv")" = "15506" ]
}

@test "etch_post_import records nothing when the eval reports no post actually changed" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '14468\t15506\twp_block\n' > "$tsv"
  _etch_capture_eval_empty() {
    case "$1" in
      option) echo '{}' ;;
      eval) : ;; # no post actually contained a ref to rewrite
    esac
  }
  etch_post_import "$run_dir" "$tsv" "_etch_capture_eval_empty"
  [ ! -f "${run_dir}/module-content-rewrites.tsv" ]
}

@test "etch_post_import does not record anything under --dry-run (nothing was actually rewritten)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '14468\t15506\twp_block\n' > "$tsv"
  _etch_capture_eval_dryrun_stub() {
    case "$1" in
      option) echo '{}' ;;
      eval) echo "SHOULD NOT BE CALLED FOR REAL UNDER DRY-RUN" ;;
    esac
  }
  SITEGRAFT_DRY_RUN=1 run etch_post_import "$run_dir" "$tsv" "_etch_capture_eval_dryrun_stub"
  [ "$status" -eq 0 ]
  [ ! -f "${run_dir}/module-content-rewrites.tsv" ]
  [[ "$output" == *"[dry-run]"* ]] || false
}

# --- etch_post_import: mediaId (issue #84) -----------------------------------
#
# wp:etch/dynamic-image addresses its media by ATTACHMENT id, under a
# differently-named attribute ("mediaId", not "id"), so neither graft's
# generic content remap (lib/php/content-remap-functions.php, which only
# ever matches the literal key "id") nor this hook's own pre-existing "ref"
# remap (a DIFFERENT id space -- component/template posts, never
# attachments) ever touched it. Measured on a real graft: 12 distinct
# mediaId values, 12 of 12 broken, all already present in id-map.tsv.

@test "etch_post_import builds its media map from attachment rows only, the OPPOSITE filter of the ref map" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '14468\t15506\twp_block\n900\t901\tattachment\n35199\t763\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  # media_map must carry the attachment rows...
  grep -q '"900":901' "$BATS_TEST_TMPDIR/php.txt"
  grep -q '"35199":763' "$BATS_TEST_TMPDIR/php.txt"
  # ...and media_map must be a SEPARATE variable from map (the ref map),
  # which must still carry only the non-attachment row.
  grep -q '\$media_map = json_decode' "$BATS_TEST_TMPDIR/php.txt"
  grep -q '"14468":15506' "$BATS_TEST_TMPDIR/php.txt"
}

@test "etch_post_import does nothing (no eval call at all) when the run mapped only attachments (no post to scan)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '900\t901\tattachment\n' > "$tsv"
  rm -f "$BATS_TEST_TMPDIR/php.txt"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  # Unchanged behavior from before mediaId existed (see the sibling test
  # above this section): zero non-attachment rows means zero posts in
  # scope for EITHER map, attachments included -- there is no migrated
  # post left for a mediaId reference to even live inside.
  [ ! -f "$BATS_TEST_TMPDIR/php.txt" ]
}

# _etch_run_captured_php <post_id> <post_content> — executes the REAL PHP
# text etch_post_import handed to `wp eval` (captured by _etch_capture_eval
# above, verbatim, never a second hand-copied version of the substitution
# logic) against a minimal, purpose-built WordPress stub: get_post_field
# returns the given canned content for the given id, $wpdb->update records
# what it was asked to write, clean_post_cache is a no-op. Prints the
# post_content $wpdb->update was actually called with, or the literal
# string "NO-WRITE" if $wpdb->update was never called (content unchanged).
#
# A dedicated, tiny stub rather than tests/unit/fixtures/wpstub.php: that
# file's own get_post_field models a "display" context filter prefix
# ("DISPLAYFILTERED:") that is real WordPress behavior for OTHER fields,
# but orthogonal to what this test is proving, and reusing it here would
# make every assertion below account for a prefix that has nothing to do
# with mediaId's own correctness.
_etch_run_captured_php() {
  local post_id="$1" content="$2"
  # Dynamic values reach PHP as real $argv entries (after --), never
  # interpolated into the PHP source string itself -- sidesteps the
  # nested-quoting mess a bash command substitution embedded inside a
  # single-quoted `php -r` argument would otherwise be.
  php -r '
    $post_id = (int) $argv[1];
    $content = $argv[2];
    $capture_file = $argv[3];
    function get_post_field( $field, $id ) {
      global $post_id, $content;
      return ( $field === "post_content" && $id === $post_id ) ? $content : "";
    }
    function clean_post_cache( $id ) {}
    class _EtchTestWpdb {
      public $posts = "wp_posts";
      public function update( $table, $data, $where ) {
        echo $data["post_content"];
        return 1;
      }
    }
    $GLOBALS["wpdb"] = new _EtchTestWpdb();
    ob_start();
    eval( file_get_contents( $capture_file ) );
    $out = ob_get_clean();
    echo ( $out === "" ) ? "NO-WRITE" : $out;
  ' -- "$post_id" "$content" "$BATS_TEST_TMPDIR/php.txt"
}

@test "etch_post_import mediaId remap: quoted-string form is rewritten to the new attachment id, quotes preserved" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n35199\t763\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"35199"}} -->'
  [[ "$output" == *'"mediaId":"763"'* ]] || false
  [[ "$output" != *'35199'* ]] || false
}

@test "etch_post_import mediaId remap: bare-number form is rewritten too, defensively (not yet observed on a real site, but not ruled out)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n35199\t763\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":35199}} -->'
  [[ "$output" == *'"mediaId":763'* ]] || false
  [[ "$output" != *'35199'* ]] || false
}

@test "etch_post_import mediaId remap: HTML-attribute form (mediaId equals quoted 35199) is rewritten too, defensively -- fix-pack: seen in Etch editor UI, never in stored content" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n35199\t763\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '<etch:img class="home-intro__featured" mediaId="35199" useSrcSet="true" />'
  [[ "$output" == *'mediaId="763"'* ]] || false
  [[ "$output" != *'35199'* ]] || false
}

@test "etch_post_import mediaId remap: digit-boundary safety -- remapping mediaId 1 never touches mediaId 12" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n1\t999\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 'keep "mediaId":12 untouched, only remap "mediaId":1 here'
  [[ "$output" == *'"mediaId":12'* ]] || false
  [[ "$output" == *'"mediaId":999'* ]] || false
  [[ "$output" != *'"mediaId":1 '* ]] || false
}

@test "etch_post_import mediaId remap: chained remap (16 -> 173, 173 -> 200) does not double-substitute" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n16\t173\tattachment\n173\t200\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '"mediaId":"16" and "mediaId":"173"'
  [[ "$output" == *'"mediaId":"173" and "mediaId":"200"'* ]] || false
}

# Issue #86 CLOSES the gap the test above this section used to pin (see git
# history / PR #85's own description for the "known, documented gap" this
# replaces). `bild` is a name only the referenced COMPONENT'S OWN body
# knows the meaning of; this hook now reads that body once (the discovery
# pass, above the main loop) and remaps the prop AT the call site using the
# discovered kind. This single test needs TWO posts in the stub (the
# citing page AND the component it calls), so it uses
# _etch_run_captured_php_multi below rather than the single-post harness
# every other test in this file uses.
@test "etch_post_import mediaId remap: a component prop with an operator-chosen name (e.g. \"bild\") is now discovered and remapped through the component that declares it (#86)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n37496\t40000\twp_block\n35253\t888\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php_multi \
    105 '<!-- wp:etch/component {"ref":37496,"attributes":{"text":"Alpha","bild":"35253"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"class":"item-card__image","mediaId":"{props.bild}"}} -->'
  local write_105
  write_105=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  [[ "$write_105" == *'"ref":40000'* ]] || false
  [[ "$write_105" == *'"bild":"888"'* ]] || false
  [[ "$write_105" != *'35253'* ]] || false
  # A non-id-bearing prop on the SAME call ("text") must be left byte-exact.
  [[ "$write_105" == *'"text":"Alpha"'* ]] || false
}

@test "etch_post_import mediaId remap: leaves \"ref\" untouched and vice versa -- the two id spaces never cross-contaminate" {
  # A pathological but real-shaped case: the SAME numeric value used as
  # both an old component-post id (ref) and an old attachment id
  # (mediaId), remapped to DIFFERENT new ids. If the two maps were ever
  # merged into one, one of these would corrupt the other.
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n42\t9001\twp_block\n42\t9002\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '"ref":42 next to "mediaId":"42"'
  [[ "$output" == *'"ref":9001'* ]] || false
  [[ "$output" == *'"mediaId":"9002"'* ]] || false
}

@test "etch_post_import mediaId remap: an editor-internal data-etch-context ref (alphanumeric, quoted) is left untouched, not mistaken for a numeric component ref" {
  # Fix-pack finding, confirmed live: a base64-encoded JSON blob under a
  # data-etch-context HTML attribute (found in a real revision post) can
  # carry its OWN "ref" key, e.g. decoded:
  #   {"name":"If (Condition)","structureState":"open","ref":"b753cpd"}
  # That "ref" is Etch's OWN editor-element id (the structure panel's
  # bookkeeping), never a WordPress post id -- and it is always a quoted,
  # non-digit string, so the digits-only "ref":N pattern this hook
  # actually matches can never touch it. No code change needed for this;
  # this test pins the observation so a future reader does not "fix" a
  # false alarm here.
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n42\t9001\twp_block\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 ' data-etch-context="eyJyZWYiOiJiNzUzY3BkIn0=" "ref":42'
  [[ "$output" == *'"ref":9001'* ]] || false
  [[ "$output" == *'data-etch-context="eyJyZWYiOiJiNzUzY3BkIn0="'* ]] || false
}

# --- issue #88: whitespace-tolerant JSON matching -------------------------
#
# Every pattern below that matches a JSON key/value pair used to match ONLY
# the exact compact byte sequence -- zero whitespace either side of the
# colon (or, for the HTML-attribute mediaId form, the `=`). Real Etch/
# WordPress content never emits the spaced form (json_encode()'s default has
# no whitespace), so this was never observed live -- but a hand-edited call
# site was silently left holding A's old id, with no error and no warning.
# These tests are MUTATION-TESTED: reverting any one of the `\s*`
# insertions in modules/etch.sh's etch_post_import back to a literal `:`
# (or `=`) turns the matching test below red.

@test "etch_post_import ref remap: tolerates whitespace around the colon (issue #88)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n14468\t15506\twp_block\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '<!-- wp:etch/component {"ref" : 14468,"attributes":[]} -->'
  [[ "$output" == *'"ref":15506'* ]] || false
  [[ "$output" != *'14468'* ]] || false
}

@test "etch_post_import mediaId remap: quoted-string form tolerates whitespace around the colon (issue #88)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n35199\t763\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId"   :   "35199"}} -->'
  [[ "$output" == *'"mediaId":"763"'* ]] || false
  [[ "$output" != *'35199'* ]] || false
}

@test "etch_post_import mediaId remap: bare-number form tolerates whitespace around the colon (issue #88)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n35199\t763\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":  35199}} -->'
  [[ "$output" == *'"mediaId":763'* ]] || false
  [[ "$output" != *'35199'* ]] || false
}

@test "etch_post_import mediaId remap: HTML-attribute form tolerates whitespace around the '=' (issue #88)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n35199\t763\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '<etch:img mediaId = "35199" useSrcSet="true" />'
  [[ "$output" == *'mediaId="763"'* ]] || false
  [[ "$output" != *'35199'* ]] || false
}

@test "etch_post_import component-prop remap: a spaced call-site attribute (\"bild\" : \"35253\") is still discovered and remapped (issue #88)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n37496\t40000\twp_block\n35253\t888\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php_multi \
    105 '<!-- wp:etch/component {"ref":37496,"attributes":{"text":"Alpha","bild"  :  "35253"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"class":"item-card__image","mediaId":"{props.bild}"}} -->'
  local write_105
  write_105=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  [[ "$write_105" == *'"bild":"888"'* ]] || false
  [[ "$write_105" != *'35253'* ]] || false
}

@test "etch_post_import component-prop remap: space BEFORE the outer \"attributes\" colon is still found and rewritten (issue #88, Viktor's blocking repro)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n37496\t40000\twp_block\n35253\t888\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php_multi \
    105 '<!-- wp:etch/component {"ref":37496,"attributes" : {"bild":"35253"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  local write_105
  write_105=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  [[ "$write_105" == *'"bild":"888"'* ]] || false
  [[ "$write_105" != *'35253'* ]] || false
}

@test "etch_post_import component-prop discovery: a spaced component-body declaration (\"mediaId\" : \"{props.bild}\") is still discovered (issue #88)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n37496\t40000\twp_block\n35253\t888\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php_multi \
    105 '<!-- wp:etch/component {"ref":37496,"attributes":{"bild":"35253"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId"  :  "{props.bild}"}} -->'
  local write_105
  write_105=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  [[ "$write_105" == *'"bild":"888"'* ]] || false
  [[ "$write_105" != *'35253'* ]] || false
}

# --- issue #88: the cheap interim "decided but text unchanged" guard ------
#
# The remap already KNOWS, for every (post, old id) pair it looks at, that
# it decided that id might need rewriting -- it is iterating $map/$media_map,
# built from exactly the ids this run migrated. If that old id is still
# textually present, digit-bounded, in the post's content after every
# sentinel pass ran, this hook cannot silently move on: it echoes
# `UNMATCHED_ID_REF:<pid>:<old>:<kind>`, surfaced by the bash side as a
# named `log_warn`. This is the documented fallback for exactly the forms
# whitespace-tolerance above does not anticipate (curly/smart quotes from a
# pasted edit, here) -- not a hypothetical, CLAUDE.md's own "prove the check
# can fail" rule applied to this fix-pack.
@test "etch_post_import UNMATCHED-guard PHP proof: a mediaId reference in curly/smart quotes (a pasted-from-rich-text edit, not valid JSON quoting) is neither rewritten nor silently dropped -- it is named" {
  # MUTATION-TESTED: removing the UNMATCHED_ID_REF foreach block from
  # modules/etch.sh's etch_post_import turns this red -- with the guard gone
  # the captured PHP produces no output at all for this content (the
  # smart-quoted form was never a shape any \s*-tolerant pattern matches
  # either, before or after this fix-pack).
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n35199\t763\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '<!-- wp:etch/dynamic-image {"attributes":{“mediaId”:“35199”}} -->'
  [[ "$output" == *'UNMATCHED_ID_REF:105:35199:mediaId'* ]] || false
  # Correctly NOT rewritten -- the guard reports, it never invents a fix.
  [[ "$output" == *'35199'* ]] || false
}

@test "etch_post_import UNMATCHED-guard PHP proof: stays silent when the mediaId remap actually succeeded (no false-positive noise on the common case)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n35199\t763\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"35199"}} -->'
  [[ "$output" != *'UNMATCHED_ID_REF'* ]] || false
}

@test "etch_post_import UNMATCHED-guard bash wiring: an UNMATCHED_ID_REF marker from the eval becomes a named log_warn, never a recorded content rewrite" {
  # Mirrors this file's own NESTED_COMPONENT wiring test just above: the
  # eval's marker line is hand-supplied here (a realistic canned line, not a
  # real PHP execution) specifically to isolate and pin the BASH side's
  # reaction to it, independent of the PHP-level proof above.
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n35199\t763\tattachment\n' > "$tsv"
  _etch_capture_eval_unmatched() {
    case "$1" in
      option) echo '{}' ;;
      eval)
        printf '%s' "$2" > "$BATS_TEST_TMPDIR/php.txt"
        echo "UNMATCHED_ID_REF:105:35199:mediaId"
        ;;
    esac
  }
  run --separate-stderr etch_post_import "$run_dir" "$tsv" "_etch_capture_eval_unmatched"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"post 105"* ]] || false
  [[ "$stderr" == *"old mediaId id 35199"* ]] || false
  [[ "$stderr" == *"issue #88"* ]] || false
  # A warning marker, not a post id -- must never be counted as a rewrite.
  [ ! -f "${run_dir}/module-content-rewrites.tsv" ]
}

# --- etch_post_import: component PROPS with an operator-chosen name (#86) ---
#
# Follow-up to #84/PR #85: `bild` is a name only the referenced component's
# OWN body knows the meaning of ("mediaId":"{props.bild}"), so no fixed-key
# scan at the CALL site (page 37468 on the real reference site,
# "bild":"35253") can ever find it. The component post is the source of
# truth for what the prop means; these tests exercise the two-post
# discovery-then-remap mechanism modules/etch.sh's etch_post_import now
# implements for it.

# _etch_run_captured_php_multi <id1> <content1> [<id2> <content2> ...] --
# same discipline as _etch_run_captured_php above (executes the REAL
# captured PHP, never a hand-copied re-implementation of it), extended to
# more than one stubbed post: this mechanism reads TWO kinds of post while
# it runs -- the citing post (whatever calls a component) AND the
# component's own body (to learn which props are id-bearing) -- and the
# single-post harness above cannot stand in for both at once. Prints one
# "WRITE:<id>:<content>" line per post $wpdb->update was actually called
# for (never for a post left unchanged), plus one "ECHO:<line>" per line
# etch_post_import's PHP itself echoed (post ids it recorded as rewritten,
# and any "NESTED_COMPONENT:<id>" marker -- see modules/etch.sh's own
# comment on why that marker exists).
_etch_run_captured_php_multi() {
  php -r '
    $capture_file = $argv[1];
    $store = array();
    for ( $i = 2; $i < count( $argv ); $i += 2 ) {
      $store[ (int) $argv[ $i ] ] = $argv[ $i + 1 ];
    }
    function get_post_field( $field, $id ) {
      global $store;
      return ( $field === "post_content" && array_key_exists( (int) $id, $store ) ) ? $store[ (int) $id ] : "";
    }
    function clean_post_cache( $id ) {}
    class _EtchTestWpdbMulti {
      public $posts = "wp_posts";
      public $writes = array();
      public function update( $table, $data, $where ) {
        $this->writes[ (int) $where["ID"] ] = $data["post_content"];
        return 1;
      }
    }
    $GLOBALS["wpdb"] = new _EtchTestWpdbMulti();
    ob_start();
    eval( file_get_contents( $capture_file ) );
    $echoed = ob_get_clean();
    foreach ( explode( "\n", $echoed ) as $line ) {
      if ( $line !== "" ) { echo "ECHO:" . $line . "\n"; }
    }
    foreach ( $GLOBALS["wpdb"]->writes as $wid => $wcontent ) {
      echo "WRITE:" . $wid . ":" . $wcontent . "\n";
    }
  ' -- "$BATS_TEST_TMPDIR/php.txt" "$@"
}

@test "etch_post_import component-prop remap: three call sites to the SAME component, three DIFFERENT ids, each rewritten to its own new id (page 37468 calling the same component with three different attachment ids) (#86)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t37468\tpage\n37496\t40000\twp_block\n35253\t888\tattachment\n35255\t889\tattachment\n35254\t890\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  local page='<!-- wp:etch/component {"ref":37496,"attributes":{"text":"Alpha","bild":"35253"}} --><!-- /wp:etch/component --><!-- wp:etch/component {"ref":37496,"attributes":{"text":"Beta","bild":"35255"}} --><!-- /wp:etch/component --><!-- wp:etch/component {"ref":37496,"attributes":{"text":"Gamma","bild":"35254"}} --><!-- /wp:etch/component -->'
  local component='<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  run _etch_run_captured_php_multi 37468 "$page" 40000 "$component"
  local write
  write=$(printf '%s\n' "$output" | grep '^WRITE:37468:')
  [[ "$write" == *'"bild":"888"'* ]] || false
  [[ "$write" == *'"bild":"889"'* ]] || false
  [[ "$write" == *'"bild":"890"'* ]] || false
  [[ "$write" != *'35253'* ]] || false
  [[ "$write" != *'35255'* ]] || false
  [[ "$write" != *'35254'* ]] || false
  # the "text" prop of every call, not id-bearing, must survive byte-exact
  [[ "$write" == *'"text":"Alpha"'* ]] || false
  [[ "$write" == *'"text":"Beta"'* ]] || false
  [[ "$write" == *'"text":"Gamma"'* ]] || false
}

@test "etch_post_import component-prop remap: exigence #3 -- a prop the SAME component consumes in a NON-id-bearing attribute is never touched, even when its value COLLIDES with a real old id in the map" {
  # A component can legitimately have a prop like "titre" holding "2024".
  # Rewriting it would be a silent corruption. The value chosen here, "9",
  # is deliberately a REAL old id that a broader (buggy) discovery would
  # actually find a mapping for (id-map.tsv's own "9\t105\tpage" row) --
  # a value that could never collide (like "2024") would let a
  # too-broad "content" is also id-bearing" mutation pass unnoticed,
  # since the map simply has no entry for it either way. This pins that
  # the per-component discovery only marks a prop id-bearing when THAT
  # prop feeds a known id-bearing attribute (mediaId/ref/parentPageID),
  # never "content" or any other attribute, and never by the prop's name
  # or its value merely looking numeric.
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n35253\t888\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php_multi \
    105 '<!-- wp:etch/component {"ref":37496,"attributes":{"titre":"9","bild":"35253"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} --><!-- wp:etch/text {"content":"{props.titre}"} /-->'
  local write
  write=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  [[ "$write" == *'"bild":"888"'* ]] || false
  [[ "$write" == *'"titre":"9"'* ]] || false
}

@test "etch_post_import component-prop remap: the SAME prop name used by TWO DIFFERENT components for DIFFERENT purposes never cross-contaminates (per-component scoping)" {
  # Component A's "value" prop is id-bearing (mediaId); component B's
  # "value" prop is not (feeds a "content" text attribute). A call to B
  # with a numeric-looking "value" must be left alone even though the SAME
  # prop name is id-bearing for A -- discovery is scoped per component,
  # never a global "this prop name always means an id" table.
  #
  # Fix-pack (issue #86, blocker 2): the citing page's own "ref" values
  # below are A's OLD component ids (1, 2), not B's new ones (201, 202) --
  # this pass now runs against genuinely untouched original content,
  # BEFORE the fixed-key ref pass remaps "ref" itself, so the fixture must
  # reflect that ordering the same way a real graft's content would.
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t105\tpage\n1\t201\twp_block\n2\t202\twp_block\n42\t888\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  local page='<!-- wp:etch/component {"ref":1,"attributes":{"value":"42"}} --><!-- /wp:etch/component --><!-- wp:etch/component {"ref":2,"attributes":{"value":"42"}} --><!-- /wp:etch/component -->'
  local comp_a='<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.value}"}} -->'
  local comp_b='<!-- wp:etch/text {"content":"{props.value}"} /-->'
  run _etch_run_captured_php_multi 105 "$page" 201 "$comp_a" 202 "$comp_b"
  local write
  write=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  # ref 1 -> 201 (component A, id-bearing "value") is remapped...
  [[ "$write" == *'"ref":201,"attributes":{"value":"888"}}'* ]] || false
  # ...ref 2 -> 202 (component B, non-id-bearing "value") keeps its literal "42".
  [[ "$write" == *'"ref":202,"attributes":{"value":"42"}}'* ]] || false
}

@test "etch_post_import component-prop remap: a pass-through value ({props.X}, an unresolved cascade) is left untouched, never mistaken for a literal id" {
  # A citing post that has not resolved a value yet (this hook's own
  # depth-1 scope: a post that is ITSELF another component's body, calling
  # 40000 with "bild":"{props.outerBild}" instead of a literal digit) must
  # not have that placeholder text treated as if it were a plain string id
  # -- 40000's own body DOES directly declare "bild" as mediaId-bearing
  # (discovery fires, unlike the composition test below), so this pins the
  # VALUE-shape guard specifically, not "nothing was discovered".
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t200\tpage\n7\t40000\twp_block\n77\t999\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php_multi \
    200 '<!-- wp:etch/component {"ref":40000,"attributes":{"bild":"{props.outerBild}"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  # Nothing to remap at post 200's own call site (the value is not a
  # literal digit) -- no write for it at all, not a corrupted one.
  [[ "$output" != *'WRITE:200:'* ]] || false
}

@test "etch_post_import component-prop remap: a component that itself calls ANOTHER component is warned about by name (composition depth > 1, #86's documented scope limit)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t200\tpage\n8\t50000\twp_block\n7\t40000\twp_block\n' > "$tsv"
  _etch_capture_eval_nested() {
    case "$1" in
      option) echo '{}' ;;
      eval)
        printf '%s' "$2" > "$BATS_TEST_TMPDIR/php.txt"
        # Simulates the real wp-cli eval output for this exact fixture:
        # component 50000's own body contains a nested wp:etch/component
        # reference (to 40000), so the discovery pass echoes the marker.
        echo "NESTED_COMPONENT:50000"
        ;;
    esac
  }
  run --separate-stderr etch_post_import "$run_dir" "$tsv" "_etch_capture_eval_nested"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"50000"* ]] || false
  [[ "$stderr" == *"another wp:etch/component"* ]] || false
  # Never recorded as a content rewrite (it is a WARNING marker, not a post
  # id) -- graft_record_module_content_rewrite's own digit-only guard would
  # already refuse it, but this pins that it is INTERCEPTED and surfaced
  # rather than silently dropped by that guard.
  [ ! -f "${run_dir}/module-content-rewrites.tsv" ]
}

@test "etch_post_import component-prop remap: discovery is skipped entirely (no eval crash, existing behavior unchanged) when the run migrated no wp_block at all" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t105\tpage\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  grep -q '\$component_map = json_decode(.{}' "$BATS_TEST_TMPDIR/php.txt"
}

# --- issue #86 fix-pack (Viktor's review of PR #87): three blockers, one test
# each, all reproducing the EXACT scenarios the review measured against a
# real PHP 8.5.7 execution, not a paraphrase of them.

@test "etch_post_import component-prop remap: BLOCKER 1 -- a call site whose JSON does not balance (even inside a string, from the naive-regex era) is warned about, never hangs, and does not prevent a LATER, well-formed call site on the same post from being remapped" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t105\tpage\n1\t500\twp_block\n35253\t900\tattachment\n99999\t901\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  # First block: a STRING value containing a literal, unescaped "{" -- the
  # OLD PCRE-recursion pattern drove preg_match_all() into catastrophic
  # backtracking on exactly this shape (PREG_BACKTRACK_LIMIT_ERROR, false
  # treated as "no matches" both here and in lib/verify.sh). The current
  # linear, string-aware scanner parses it correctly (it IS balanced JSON,
  # a brace inside a quoted string is not a structural brace) and remaps
  # it -- proving the fix does more than merely fail safely on this exact
  # shape, it fixes it. Second block: genuinely truncated JSON (a hard
  # negative control the scanner really cannot parse), which must be
  # flagged loudly rather than silently ignored or hung on.
  local page='<!-- wp:etch/component {"ref":1,"attributes":{"t":"start { here","bild":"35253"}} --><!-- /wp:etch/component --><!-- wp:etch/component {"ref":1,"attributes":{"bild":"99999" -->'
  local component='<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  run _etch_run_captured_php_multi 105 "$page" 500 "$component"
  [ "$status" -eq 0 ]
  local write_105
  write_105=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  # The well-formed first block's "bild" is discovered and remapped...
  [[ "$write_105" == *'"bild":"900"'* ]] || false
  [[ "$write_105" != *'35253'* ]] || false
  # ...the string content containing a literal "{" survives byte-exact...
  [[ "$write_105" == *'"t":"start { here"'* ]] || false
  # ...and the truncated second block is named in a warning, not silently
  # dropped or left to hang the whole hook.
  [[ "$output" == *'ECHO:MALFORMED_COMPONENT_BLOCK:105'* ]] || false
}

@test "etch_post_import component-prop remap: BLOCKER 2 -- a prop literally named \"mediaId\" does not get double-remapped through a chained id-map row (35253->900, 900->901)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t105\tpage\n37496\t500\twp_block\n35253\t900\tattachment\n900\t901\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  # The component's OWN prop happens to be named "mediaId" -- the single
  # most natural name an author would choose for a prop that feeds a
  # mediaId attribute, and exactly the name collision the fixed-key
  # mediaId pass above does not know to avoid.
  run _etch_run_captured_php_multi \
    105 '<!-- wp:etch/component {"ref":37496,"attributes":{"mediaId":"35253"}} -->' \
    500 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.mediaId}"}} -->'
  local write_105
  write_105=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  # Correct: the ONE real hop, 35253 -> 900 -- not chained a second time
  # into 901 by this pass re-reading its own OWN output as if it were still
  # an old value.
  [[ "$write_105" == *'"mediaId":"900"'* ]] || false
  [[ "$write_105" != *'"mediaId":"901"'* ]] || false
}

@test "etch_post_import component-prop remap: BLOCKER 3 -- substitution never leaks outside the attributes span (a prop named \"ref\" colliding with the block's own top-level ref; a metadata.bindings mirror of a remapped prop is left untouched)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t105\tpage\n37496\t500\twp_block\n500\t600\twp_block\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  # The component's own prop is literally named "ref" -- colliding, at the
  # TEXT level, with the SAME block's own top-level "ref" pointer. Correct
  # behavior: BOTH occurrences resolve to 37496's real new id (500) via the
  # fixed-key ref pass's own sentinel-protected chaining, since attributes.
  # ref is a plain fixed-key occurrence to THAT pass once this hook's own
  # component-prop pass has finished with it -- never chained a second hop
  # to 600 (the id-map's OWN unrelated 500->600 row) by a component-prop
  # substitution that reached outside its own bounded span.
  run _etch_run_captured_php_multi \
    105 '<!-- wp:etch/component {"ref":37496,"attributes":{"ref":37496}} -->' \
    500 '<!-- wp:etch/dynamic-image {"attributes":{"ref":"{props.ref}"}} -->'
  local write_105
  write_105=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  [[ "$write_105" == *'"ref":500,"attributes":{"ref":500}}'* ]] || false
  [[ "$write_105" != *'600'* ]] || false
}

@test "etch_post_import component-prop remap: BLOCKER 3b -- a metadata.bindings mirror of a remapped attributes prop (Etch's own editor-binding shape) is left untouched, only the attributes copy is rewritten" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n35253\t888\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php_multi \
    105 '<!-- wp:etch/component {"ref":37496,"attributes":{"bild":"35253"},"metadata":{"bindings":{"bild":"35253"}}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  local write_105
  write_105=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  [[ "$write_105" == *'"attributes":{"bild":"888"}'* ]] || false
  # The metadata.bindings MIRROR of the same digits, outside "attributes"
  # entirely, must survive byte-exact -- only ONE occurrence was ever
  # discovered as id-bearing (the attributes one), and this hook's
  # substitution is bounded to that exact span, not "wherever this digit
  # string happens to appear in the block".
  [[ "$write_105" == *'"metadata":{"bindings":{"bild":"35253"}}}'* ]] || false
}

# --- issue #86 SECOND fix-pack (independent review round 2): the block
# finder's OWN failure modes -- a span it says is "ok" but whose bytes are
# not actually valid JSON (BLOCKER A), and whitespace/void-block shapes the
# finder rejected too eagerly (BLOCKER B).

@test "etch_post_import component-prop remap: SECOND fix-pack BLOCKER A -- a call site whose span is BALANCED but whose bytes are not valid JSON (an unpaired quote desyncs string tracking) is warned about, not silently skipped" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n35253\t888\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  # sitegraft_json_span correctly finds a balanced { ... } span here (the
  # unpaired quote does not break brace counting), but json_decode() on
  # that span fails -- the exact case a bare "continue" used to swallow
  # with no marker at all, on either side of the guard.
  run _etch_run_captured_php_multi \
    105 '<!-- wp:etch/component {"ref":37496,"attributes":{"t":"a" b" c","bild":"35253"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  [[ "$output" == *'ECHO:MALFORMED_COMPONENT_BLOCK:105'* ]] || false
  local write_105
  write_105=$(printf '%s\n' "$output" | grep '^WRITE:105:')
  # the fixed-key ref pass is a SEPARATE, blind mechanism and still applies
  # (37496 -> 40000) -- what must NOT happen is the component-prop pass
  # treating this malformed occurrence as resolved: "bild" stays untouched.
  [[ "$write_105" == *'"ref":40000'* ]] || false
  [[ "$write_105" == *'"bild":"35253"'* ]] || false
}

@test "etch_post_import component-prop remap: SECOND fix-pack BLOCKER B -- a newline between the block prefix and its JSON is accepted (the old regex's \\\\s+ equivalent), and a JSON-less component occurrence is not treated as malformed" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n35253\t888\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  local page="<!-- wp:etch/component --><!-- wp:etch/component 
{\"ref\":37496,\"attributes\":{\"bild\":\"35253\"}} -->"
  local component='<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  run _etch_run_captured_php_multi 105 "$page" 40000 "$component"
  # neither occurrence is malformed: the JSON-less first one is a legitimate
  # no-op, and the newline-separated second one parses and remaps normally.
  # Asserted against the whole $output, not a single grep'd line: WRITE:105
  # itself spans two physical lines here (the citing content's own embedded
  # newline survives into the rewritten post), so a "^WRITE:105:" grep would
  # only capture the FIRST of them and miss the remapped "bild" on the
  # second -- there is only one WRITE in this fixture, so matching against
  # the whole output is unambiguous.
  [[ "$output" != *"MALFORMED_COMPONENT_BLOCK"* ]] || false
  [[ "$output" == *"WRITE:105:"* ]] || false
  [[ "$output" == *'"bild":"888"'* ]] || false
}
