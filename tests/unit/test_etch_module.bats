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

@test "etch_post_import mediaId remap: leaves a component prop with an operator-chosen name (e.g. \"bild\") untouched -- known, documented gap" {
  # The dynamic-expression form, mediaId: {props.bild}, never carries a
  # literal id at THIS call site at all -- the real id lives one post away,
  # under whatever custom name the component author chose ("bild" on the
  # real site this issue was measured against). No fixed-key scan can find
  # it; this test pins that this is a deliberate, known limit, not
  # something silently and accidentally working. The "ref" in the same
  # block DOES have a mapping here, so the content genuinely changes --
  # proving the hook actually ran over this post, rather than the
  # "nothing changed at all" case a missing mapping would also produce.
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n37496\t40000\twp_block\n35253\t888\tattachment\n' > "$tsv"
  run etch_post_import "$BATS_TEST_TMPDIR" "$tsv" "_etch_capture_eval"
  [ "$status" -eq 0 ]
  run _etch_run_captured_php 105 '<!-- wp:etch/component {"ref":37496,"attributes":{"bild":"35253"}} -->'
  [[ "$output" == *'"ref":40000'* ]] || false
  # "bild" is untouched: the digits 35253 must still be present, unremapped,
  # because nothing in this hook's known-attribute list is named "bild".
  [[ "$output" == *'"bild":"35253"'* ]] || false
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
