# tests/unit/test_core_wp_module.bats — modules/core-wp.sh: the module that
# claims WordPress's own page/post content and the core options graft needs
# (design doc §9.3 names "the core-wp module's hook" explicitly, but no such
# module existed before this Step — see modules/core-wp.sh's own header
# comment). Loaded directly (not via modules_discover) so the module
# contract functions are exercised in isolation, same convention as
# tests/unit/test_modules.bats uses for its own fabricated modules.
setup() {
  load '../../lib/core.sh'
  # shellcheck disable=SC1091
  load '../../modules/core-wp.sh'
}

@test "core_wp_name returns a human-readable label" {
  run core_wp_name
  [ "$output" = "WordPress Core" ]
}

@test "core_wp_detect matches a scan showing the page post_type" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"post_types":[{"name":"page"},{"name":"post"}]}' > "$scan"
  run core_wp_detect "$scan"
  [ "$status" -eq 0 ]
}

@test "core_wp_detect does not match a scan without the page post_type" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"post_types":[{"name":"some_cpt"}]}' > "$scan"
  run core_wp_detect "$scan"
  [ "$status" -ne 0 ]
}

@test "core_wp_post_types declares page and post" {
  run core_wp_post_types
  [[ "$output" == *"page"* ]]
  [[ "$output" == *"post"* ]]
}

@test "core_wp_option_keys declares the front-page trio plus site identity" {
  run core_wp_option_keys
  [[ "$output" == *"page_on_front"* ]]
  [[ "$output" == *"page_for_posts"* ]]
  [[ "$output" == *"show_on_front"* ]]
}

@test "core_wp_post_import remaps page_on_front through id-map.tsv" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_cmd_b_stub() { echo "wp_cmd_b_stub $*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  run cat "$BATS_TEST_TMPDIR/calls.log"
  [[ "$output" == *"option update page_on_front 105"* ]]
}

@test "core_wp_post_import is a no-op when A never had a front page set" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf 'false' > "${run_dir}/option-page_on_front.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  : > "$tsv"
  wp_cmd_b_stub() { echo "SHOULD NOT BE CALLED" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
}

@test "core_wp_post_import warns instead of erroring when the old page has no id-map.tsv entry" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  : > "$tsv" # page 5 was never actually imported
  wp_cmd_b_stub() { echo "SHOULD NOT BE CALLED" >> "$BATS_TEST_TMPDIR/calls.log"; }
  run core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
}
