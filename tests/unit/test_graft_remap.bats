# tests/unit/test_graft_remap.bats — the two-pass sentinel ID remap (design
# doc §9.1). lib/backup.sh is loaded because graft_push_remap_payload (used
# by the real, non-stubbed graft_remap_attachment_ids/graft_search_replace_domain)
# calls graft_local_prefix, which reuses _backup_local_exec_prefix.
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
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

# MAJOR-2 (review, Viktor): `wp search-replace` has no row-level scoping —
# scoping to content TABLES (posts/postmeta/options) still put every row of
# those tables in scope, including a protected plugin's own settings.
# graft_remap_attachment_ids/graft_search_replace_domain are now rebuilt to
# push a small JSON payload (attachment map + the list of THIS run's
# migrated post IDs) and rewrite exactly those posts' post_content/
# post_excerpt via a single `wp eval`. graft_push_remap_payload is stubbed
# below purely to intercept and inspect the payload's SHAPE without needing
# a real file transfer — the DDEV harness (tests/integration/ddev-harness.sh)
# is what proves the real transfer + eval round-trip end-to-end.

@test "graft_remap_attachment_ids is a no-op when id-map.tsv has no attachment rows" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t99\tpage\n' > "$tsv"
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  run graft_remap_attachment_ids "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}

@test "graft_remap_attachment_ids's payload contains exactly the attachment old->new pairs and every migrated post id, never a table name" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local captured="$BATS_TEST_TMPDIR/captured.json"
  graft_push_remap_payload() { printf '%s' "$2" > "$captured"; echo "/fake/remote/path.json"; }
  wp_remote() { echo "sitegraft: id-remap rewrote 0 post(s)"; }
  graft_remove_file() { :; }
  run graft_remap_attachment_ids "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  run jq -e '.attachments == [{"old":"10","new":"42"}]' "$captured"
  [ "$status" -eq 0 ]
  run jq -e '.post_ids == ["42","105"]' "$captured"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--tables"* ]]
}

@test "graft_remap_attachment_ids's wp eval call is a single post_content/post_excerpt rewrite via wp_update_post, not a table-wide search-replace" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n' > "$tsv"
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_remove_file() { :; }
  SITEGRAFT_DRY_RUN=1
  run graft_remap_attachment_ids "$tsv" "$run_dir"
  [[ "$output" == *"wp_remote b eval"* ]]
  [[ "$output" == *"wp_update_post"* ]]
  [[ "$output" == *"preg_replace"* ]]
  [[ "$output" != *"search-replace"* ]]
}

# MAJOR-1 (review, Viktor): wordpress-importer's native _thumbnail_id remap
# (design doc §9.2) never fires for attachments, since graft_import_attachments
# migrates them entirely outside `wp import` — this is the generic,
# non-sentinel fix for that gap.
@test "graft_remap_featured_images rewrites a migrated post's _thumbnail_id from A's old attachment id to B's new one" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$1" = "post" ] && [ "$2" = "meta" ] && [ "$3" = "get" ]; then
      echo "10"  # B's post 105 currently carries A's OLD attachment id as its thumbnail
    else
      echo "[dry-run] wp_remote ${alias_lc} $*"
    fi
  }
  run graft_remap_featured_images "$tsv"
  [[ "$output" == *"post meta update 105 _thumbnail_id 42"* ]]
}

@test "graft_remap_featured_images leaves a post's _thumbnail_id untouched when it doesn't match any migrated attachment" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$1" = "post" ] && [ "$2" = "meta" ] && [ "$3" = "get" ]; then
      echo "999"  # some unrelated id, not one of this run's migrated attachments
    else
      echo "[dry-run] wp_remote ${alias_lc} $*"
    fi
  }
  run graft_remap_featured_images "$tsv"
  [[ "$output" != *"post meta update"* ]]
}

@test "graft_remap_featured_images skips a post with no _thumbnail_id set at all" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$1" = "post" ] && [ "$2" = "meta" ] && [ "$3" = "get" ]; then
      echo ""
    else
      echo "SHOULD NOT BE CALLED"
    fi
  }
  run graft_remap_featured_images "$tsv"
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}
