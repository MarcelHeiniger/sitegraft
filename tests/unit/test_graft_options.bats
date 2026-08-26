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
  [[ "$output" == *"option update show_on_front"* ]] || false
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
  [[ "$output" != *"option update page_on_front"* ]] || false
  [[ "$output" != *"option update page_for_posts"* ]] || false
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
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false

  : > "$tsv"
  run graft_search_replace_domain "https://a.example.com" "https://b.example.com" "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
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
  [[ "$output" != *"--tables"* ]] || false
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
  [[ "$output" == *"wp_remote b eval"* ]] || false
  [[ "$output" == *"require_once"* ]] || false
  [[ "$output" == *"sitegraft-content-remap-functions.php"* ]] || false
  [[ "$output" == *"sitegraft_remap_domain("* ]] || false
  # issue #43: writes via the shared sitegraft_write_remapped_post()
  # ($wpdb->update, never wp_update_post()) — this is the call site issue
  # #43 actually reproduces on: sitegraft_remap_domain writes the
  # JSON-escaped "https:\/\/" form, and wp_update_post( array(...) )
  # silently ate that backslash (never slashes the array form it's called
  # with, yet wp_insert_post() unconditionally unslashes before writing).
  # See tests/unit/test_content_remap_write.bats for the execution-level
  # proof this call site's actual generated PHP preserves them.
  #
  # The KEYED form (fix-pack round two, MAJOR-2 round two, Viktor): asserted
  # as the complete literal, not just the bare function name. A bare
  # `sitegraft_write_remapped_post(` match is blind to arguments -- Viktor
  # swapped $content/$excerpt at graft_remap_attachment_ids' call site
  # TWICE (once against the original 5-positional-argument form, once
  # against the first fix-pack's ($post, $content, $excerpt) form) and both
  # times every test in this suite that only matched the function name
  # stayed green. This is belt-and-suspenders on top of the real,
  # structural fix (the keyed array itself, in
  # lib/php/content-remap-functions.php's own sitegraft_write_remapped_post
  # -- see its docblock for why that closes the swap off at the one place
  # it's actually possible): this assertion re-reds if a future edit
  # reverts to two bare positional strings here.
  [[ "$output" == *'sitegraft_write_remapped_post( $post, array( "post_content" => $content, "post_excerpt" => $excerpt ) )'* ]] || false
  [[ "$output" != *"wp_update_post"* ]] || false
  # the substitution itself must live in the required file, not inline here
  [[ "$output" != *'str_replace( "/", "\\/", $from )'* ]] || false
  [[ "$output" != *"search-replace"* ]] || false
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
  [[ "$stored" == *"https://b.example.com/logo.png"* ]] || false
  # Test-quality fix-pack bug found live (this assertion was silently never
  # enforced before the fix-pack's `[[ ]] || false` pass — see the file's
  # own note on the bash 3.2 [[ ]]-under-set-e quirk): the ORIGINAL
  # assertion here checked for the literal escaped-slash text
  # 'https:\/\/b.example.com\/x' — but graft_migrate_options' domain rewrite
  # always re-serializes via jq (`jq -c ... walk(replace_domain)`), and jq
  # does NOT escape "/" on output by default (same documented fact
  # verify_options_match's own tests rely on) — REGARDLESS of whether the
  # INPUT JSON had it escaped. The stored value was always going to come
  # out with a plain, unescaped slash; asserting otherwise was asserting an
  # implementation detail that can never be true, not a real requirement.
  # What actually matters (and is what a downstream `wp option update
  # --format=json` correctly parses either way, since escaping "/" is
  # OPTIONAL in JSON, not required) is that the DECODED value is right —
  # checked here via jq, the same "compare decoded, not raw text"
  # discipline verify_options_match's own tests already established.
  run jq -e '.escaped == "https://b.example.com/x"' <<< "$stored"
  [ "$status" -eq 0 ]
  [[ "$stored" != *"a.example.com"* ]] || false
}

# Fix-pack bug found live (DDEV harness, MAJOR-B's new graft --dry-run
# assertion, running end to end for the first time): every other test in
# this file stubs wp_remote WITHOUT checking is_dry_run at all, so it
# always returns real canned data for "a" reads regardless of dry-run mode
# — which meant none of them ever actually exercised what the REAL
# wp_remote (lib/inventory.sh) does under --dry-run: wrap EVERY call,
# reads included, in run_or_echo, returning "[dry-run] wp_remote a option
# get ..." text instead of a real value. That garbage then hit `jq` in the
# domain-rewrite pass a few lines below graft_migrate_options' own read —
# jq errored (not valid JSON), and under this codebase's `set -euo
# pipefail`, that aborted the WHOLE graft with a bare, unlogged exit 5.
# This test's stub is deliberately is_dry_run-AWARE (mimicking exactly the
# real wp_remote/run_or_echo relationship, same technique as
# test_verify.bats' MAJOR-A regression tests) so it actually reproduces the
# failure before the fix and proves the fix after it: the read from A must
# return real data even under --dry-run (SITEGRAFT_DRY_RUN=0 is prefixed
# onto just that one call), while the write to B stays correctly simulated.
@test "graft_migrate_options reads A's real value even under --dry-run, so the domain-rewrite jq pass never chokes on dry-run-echo text (fix-pack regression)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_styles"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if is_dry_run; then
      echo "[dry-run] wp_remote ${alias_lc} $*"
      return 0
    fi
    if [ "$alias_lc" = "a" ]; then
      echo '{"logo_url":"https://a.example.com/logo.png"}'
    else
      echo "SHOULD NOT BE CALLED FOR REAL — the write to B must stay simulated under --dry-run"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  local stored; stored=$(cat "${run_dir}/option-etch_styles.value")
  [[ "$stored" == *"https://b.example.com/logo.png"* ]] || false
  [[ "$output" == *"[dry-run] wp_remote b"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED FOR REAL"* ]] || false
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
  [[ "$output" == *"post delete 5"* ]] || false
  [[ "$output" == *"post delete 7"* ]] || false
}

@test "graft_prune_previous_run is a no-op when the post_types list is empty" {
  SITEGRAFT_DRY_RUN=1
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run graft_prune_previous_run ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# N3 (third review round). `value=$(... option get ... || echo 'null')`
# wrote the LITERAL string `null` for any key A does not have — and then
# pushed it to B. Concretely: A has no Loop Manager, so A has no `etch_cfs`;
# the manifest still lists the key (etch_option_keys is a static allowlist);
# graft therefore ran `option update etch_cfs null` on B and ERASED B's own
# value. The same mechanism core_wp_option_keys_dynamic's own header comment
# already warns about ("claiming a key A does not have would BLANK B's own
# theme_mods") — documented there, unguarded here.
@test "graft_migrate_options skips a key A does not have instead of writing the literal null onto B (N3)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings","etch_cfs"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      case "$*" in
        "option get etch_cfs --format=json") return 1 ;;   # A simply has no such option
        *) echo '"real-value"' ;;
      esac
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"option update etch_settings"* ]] || false
  [[ "$output" != *"option update etch_cfs"* ]] || false
  [[ "$output" == *"etch_cfs"* ]] || false            # said out loud, not dropped silently
  [ ! -f "${run_dir}/option-etch_cfs.value" ]         # and no `null` left on disk either
}

# B4 (third review round, second reviewer), graft-side half. manifest_validate now
# rejects such a name too, but a manifest hand-edited AFTER being frozen never
# passes through validation again — and this loop writes to B's live database.
# The test is written so BOTH halves of the fix are load-bearing: with the
# guard removed it exits 0, and with the fd-3 read loop reverted to
# `for key in $(...)` the name splits into "two"/"words" (neither of which
# trips the guard) and B gets two `option update` calls nobody planned.
@test "graft_migrate_options refuses a manifest option key carrying whitespace, and never word-splits it into two keys (B4)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"demo":{"option_keys":["two words"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then echo '"v"'; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [ "$status" -ne 0 ]
  [[ "$output" != *"option update two "* ]] || false
  [[ "$output" != *"option update words"* ]] || false
}

# Nit 3 / mutant G1 (third review round, second reviewer): a manifest whose
# migrate entries carry no option_keys at all — the ordinary case for a
# content-only module — makes `jq -r '[…] | unique[]'` print nothing, and the
# read loop then sees a single empty line. Removing `[ -n "$key" ] || continue`
# left the suite green, so nothing proved the empty case was handled: without
# it, `wp option get ''` runs and, on the fd-3 loop, an empty key would reach
# B as `option update ''`.
@test "graft_migrate_options does nothing at all for a manifest with no option keys (nit 3)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then echo '"v"'; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"option update"* ]] || false
  [ -z "$(ls -A "$run_dir")" ]
}
