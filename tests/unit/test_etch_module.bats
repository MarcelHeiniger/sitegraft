# tests/unit/test_etch_module.bats — modules/etch.sh: Step 6 self-review
# finding (design doc §3.3 vs. code) — this module was fully specified in
# the design doc but never actually created under modules/, so a real Etch
# site's content never got auto-detected into `plan`'s migrate defaults.
# Loaded directly (not via modules_discover), same convention as
# tests/unit/test_core_wp_module.bats uses for modules/core-wp.sh.
setup() {
  load '../../lib/core.sh'
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

@test "etch_option_keys_exclude excludes license and db_version globs" {
  run etch_option_keys_exclude
  [[ "$output" == *"etch_license_*"* ]] || false
  [[ "$output" == *"etch_db_version"* ]] || false
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
  # numeric coincidence something to match.
  ! grep -q '"900"' "$BATS_TEST_TMPDIR/php.txt"
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
