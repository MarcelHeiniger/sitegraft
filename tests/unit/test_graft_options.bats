# tests/unit/test_graft_options.bats — graft_migrate_options (design doc
# §6.4 step 8 / review finding A1): fetches every migrate.*.option_keys from
# A, writes each to disk (for core_wp_post_import, §9.3), and pushes every
# key EXCEPT page_on_front/page_for_posts straight to B.
setup() {
  load '../../lib/core.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

@test "graft_migrate_options writes an option file per key and skips page_on_front for direct push" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["show_on_front","page_on_front"]}}}'
  SITE_A_WP_PATH="/site-a"; SITE_A_WP_CMD="wp"; SITEGRAFT_DRY_RUN=1
  wp_remote() { # stub: pretend A always returns a fixed JSON value for any option
    if [ "$1" = "a" ]; then echo '"stub-value"'; fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [ -f "${run_dir}/option-show_on_front.value" ]
  [ -f "${run_dir}/option-page_on_front.value" ]
}

@test "graft_migrate_options pushes a non-front-page key directly to B" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["show_on_front"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      echo '"page"'
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [[ "$output" == *"option update show_on_front"* ]]
}

@test "graft_migrate_options never pushes page_on_front/page_for_posts directly (remapped by core_wp_post_import instead)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["page_on_front","page_for_posts"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      echo '"5"'
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [[ "$output" != *"option update page_on_front"* ]]
  [[ "$output" != *"option update page_for_posts"* ]]
  [ "$(cat "${run_dir}/option-page_on_front.value")" = '"5"' ]
}

# MAJOR-2 (review, Viktor): rebuilt from a whole-content-tables
# `wp search-replace` (which put a protected plugin's own wp_options/
# wp_postmeta rows in scope) to a post_content/post_excerpt-only rewrite of
# exactly the posts THIS run migrated, via a pushed JSON payload + a single
# `wp eval` — same restructuring as graft_remap_attachment_ids
# (tests/unit/test_graft_remap.bats has the fuller comment on why).

@test "graft_search_replace_domain is a no-op when domain_from is empty or id-map.tsv has no rows" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_search_replace_domain "" "https://b.example.com" "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]]

  : > "$tsv"
  run graft_search_replace_domain "https://a.example.com" "https://b.example.com" "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}

@test "graft_search_replace_domain's payload carries from/to and every migrated post id, never a table name" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  local captured="$BATS_TEST_TMPDIR/captured.json"
  graft_push_remap_payload() { printf '%s' "$2" > "$captured"; echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  wp_remote() { echo "sitegraft: domain-remap rewrote 0 post(s)"; }
  graft_remove_file() { :; }
  run graft_search_replace_domain "https://a.example.com" "https://b.example.com" "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  run jq -e '.from == "https://a.example.com" and .to == "https://b.example.com"' "$captured"
  [ "$status" -eq 0 ]
  run jq -e '.post_ids == ["42","105"]' "$captured"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--tables"* ]]
}

@test "graft_search_replace_domain's wp eval call requires the shared content-remap library and calls its function, never a table-wide search-replace" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  SITEGRAFT_DRY_RUN=1
  run graft_search_replace_domain "https://a.example.com" "https://b.example.com" "$tsv" "$run_dir"
  [[ "$output" == *"wp_remote b eval"* ]]
  [[ "$output" == *"require_once"* ]]
  [[ "$output" == *"sitegraft-content-remap-functions.php"* ]]
  [[ "$output" == *"sitegraft_remap_domain("* ]]
  [[ "$output" == *"wp_update_post"* ]]
  [[ "$output" != *'str_replace( "/", "\\/", $from )'* ]]  # the substitution itself must live in the required file, not inline here
  [[ "$output" != *"search-replace"* ]]
}

@test "graft_migrate_options also rewrites the domain string inside a migrated option's own value, scoped only to that explicitly-listed key" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_styles"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      echo '{"logo_url":"https://a.example.com/logo.png","escaped":"https:\/\/a.example.com\/x"}'
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  local stored; stored=$(cat "${run_dir}/option-etch_styles.value")
  [[ "$stored" == *"https://b.example.com/logo.png"* ]]
  [[ "$stored" == *'https:\/\/b.example.com\/x'* ]]
  [[ "$stored" != *"a.example.com"* ]]
}

@test "graft_prune_previous_run deletes every post carrying _sitegraft_source_id from a prior run" {
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$1" = "post" ] && [ "$2" = "list" ]; then
      printf '5\n7\n'
    else
      echo "[dry-run] wp_remote $alias_lc $*"
    fi
  }
  run graft_prune_previous_run "page,post"
  [[ "$output" == *"post delete 5"* ]]
  [[ "$output" == *"post delete 7"* ]]
}

@test "graft_prune_previous_run is a no-op when the post_types list is empty" {
  SITEGRAFT_DRY_RUN=1
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run graft_prune_previous_run ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
