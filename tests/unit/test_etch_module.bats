bats_require_minimum_version 1.5.0

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

@test "etch_post_types_dynamic fails closed on an etch_cpts value it cannot read, rather than silently claiming nothing" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"fotos"}],
 "options":[{"option_name":"etch_cpts","option_value":"a:1:{i:0;a:1:{s:4:\"slug\";s:5:\"fotos\";}}"}]}
EOF
  run etch_post_types_dynamic "$scan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"etch_cpts"* ]] || false
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
