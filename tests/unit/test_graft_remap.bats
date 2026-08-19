# tests/unit/test_graft_remap.bats — the two-pass sentinel ID remap (design
# doc §9.1), scoped exclusively to content tables (review finding A6).
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/graft.sh'
}

@test "graft_build_sentinel_commands emits pass-1 sentinel substitutions for attachments only" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n11\t43\tpage\n' > "$tsv"
  run graft_build_sentinel_commands "$tsv"
  [[ "$output" == *'"id":10(?!\d)'*'"id":__SITEGRAFT_10__'* ]]
  [[ "$output" != *"11"*"page"* ]] || true  # page rows must not produce id-remap commands
}

@test "graft_build_sentinel_commands pass-2 maps each sentinel to the real new id" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n' > "$tsv"
  run graft_build_sentinel_commands "$tsv"
  [[ "$output" == *'__SITEGRAFT_10__'*'42'* ]]
}

@test "graft_build_sentinel_commands skips non-attachment rows entirely" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t99\tpage\n' > "$tsv"
  run graft_build_sentinel_commands "$tsv"
  [ -z "$output" ]
}

@test "graft_remap_attachment_ids scopes every search-replace to content tables only (finding A6)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n' > "$tsv"
  SITEGRAFT_DRY_RUN=1
  run graft_remap_attachment_ids "$tsv" "wp_prefix_posts,wp_prefix_postmeta,wp_prefix_options"
  [[ "$output" == *"--tables=wp_prefix_posts,wp_prefix_postmeta,wp_prefix_options"* ]]
}

@test "graft_remap_attachment_ids runs all pass-1 substitutions before any pass-2 (sentinel ordering)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n11\t43\tattachment\n' > "$tsv"
  SITEGRAFT_DRY_RUN=1
  run graft_remap_attachment_ids "$tsv" "wp_posts,wp_postmeta,wp_options"
  # Every pass-1 sentinel substitution line must appear before every pass-2
  # resolution line in the output — never interleaved per-ID. The FIRST
  # occurrence of a bare sentinel-only replacement (pass 2 has the sentinel
  # as the SEARCH pattern with no surrounding "id": or wp-image- text) must
  # come after the LAST occurrence of a pass-1 pattern (which always
  # contains '"id":' or 'wp-image-').
  local first_pass2 last_pass1
  first_pass2=$(echo "$output" | grep -n '^\[dry-run\] wp_remote b search-replace __SITEGRAFT_' | head -1 | cut -d: -f1)
  last_pass1=$(echo "$output" | grep -n '"id":\|wp-image-' | tail -1 | cut -d: -f1)
  [ -n "$first_pass2" ]
  [ -n "$last_pass1" ]
  [ "$first_pass2" -gt "$last_pass1" ]
}
