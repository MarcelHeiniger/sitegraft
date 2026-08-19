# tests/unit/test_graft_options.bats — graft_migrate_options (design doc
# §6.4 step 8 / review finding A1): fetches every migrate.*.option_keys from
# A, writes each to disk (for core_wp_post_import, §9.3), and pushes every
# key EXCEPT page_on_front/page_for_posts straight to B.
setup() {
  load '../../lib/core.sh'
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

@test "graft_search_replace_domain runs both the plain and JSON-escaped passes, scoped to content tables" {
  SITEGRAFT_DRY_RUN=1
  wp_remote() { echo "[dry-run] wp_remote $*"; }
  run graft_search_replace_domain "https://a.example.com" "https://b.example.com" "wp_posts,wp_postmeta,wp_options"
  [[ "$output" == *"https://a.example.com"*"https://b.example.com"* ]]
  [[ "$output" == *'https:\/\/a.example.com'*'https:\/\/b.example.com'* ]]
  [[ "$output" == *"--tables=wp_posts,wp_postmeta,wp_options"* ]]
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
