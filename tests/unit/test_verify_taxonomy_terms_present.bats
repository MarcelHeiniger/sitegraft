bats_require_minimum_version 1.5.0
# tests/unit/test_verify_taxonomy_terms_present.bats — issue #82:
# verify_taxonomy_terms_present (lib/verify.sh). #53's own item-count
# completeness gate (graft_verify_import_completeness, lib/graft.sh) cannot
# see a post whose taxonomy terms were silently dropped by wordpress-
# importer -- the post itself still lands, so the count matches. This guard
# reads the staged WXR's own declared (taxonomy, slug) pairs and confirms
# each one exists on B, right now.
#
# Real end-to-end WXR parsing throughout (genuine files on disk, the genuine
# php CLI driver lib/php/wxr-taxonomies-cli.php — not a bash-level stub of
# it), same reasoning tests/unit/test_graft_import_completeness.bats gives
# for doing the same against wxr-item-ids-cli.php. The B-side write surface
# (graft_push_remap_payload / wp_remote / graft_remove_file) is stubbed,
# same convention tests/unit/test_verify.bats's own verify_domain_absent
# tests use for the identical push-payload/eval/remove-file mechanism.
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
  load '../../lib/verify.sh'
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

# _write_wxr_terms <file> <taxonomy:slug> [<taxonomy:slug> ...] — a REAL WXR
# shape, every namespace declared, exactly like a genuine `wp export`
# document (same discipline test_graft_import_completeness.bats's own
# _write_wxr uses, and for the identical reason: an undeclared "wp" prefix
# is a real libxml namespace error that silently matches nothing).
_write_wxr_terms() {
  local file="$1"; shift
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<rss version="2.0"\n'
    printf '  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"\n'
    printf '  xmlns:content="http://purl.org/rss/1.0/modules/content/"\n'
    printf '  xmlns:wp="http://wordpress.org/export/1.2/">\n'
    printf '<channel><wp:wxr_version>1.2</wp:wxr_version>\n'
    local pair taxonomy slug
    for pair in "$@"; do
      taxonomy="${pair%%:*}"
      slug="${pair##*:}"
      printf '<wp:term><wp:term_id>1</wp:term_id><wp:term_taxonomy>%s</wp:term_taxonomy><wp:term_slug>%s</wp:term_slug><wp:term_name><![CDATA[%s]]></wp:term_name></wp:term>\n' "$taxonomy" "$slug" "$slug"
    done
    printf '</channel></rss>\n'
  } > "$file"
}

@test "verify_taxonomy_terms_present is a no-op (TAX_TERMS:0:0) when the run dir has no export directory at all" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{}}'
  wp_remote() { echo "STUB: wp_remote called -- should NOT happen"; false; }
  run verify_taxonomy_terms_present "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TAX_TERMS:0:0"* ]] || false
  [[ "$output" != *"STUB: wp_remote called"* ]] || false
}

@test "verify_taxonomy_terms_present returns 2 (UNVERIFIED), not a pass, when post types were selected but the staged export is missing" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"post_types":["page"],"option_keys":[]}}}'
  wp_remote() { echo "STUB: wp_remote called -- should NOT happen"; false; }
  run verify_taxonomy_terms_present "$run_dir" "$manifest"
  [ "$status" -eq 2 ]
  [[ "$output" != *"STUB: wp_remote called"* ]] || false
}

@test "verify_taxonomy_terms_present is a no-op (TAX_TERMS:0:0) for a staged export with zero <wp:term> elements" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  printf '<?xml version="1.0"?><rss version="2.0" xmlns:wp="http://wordpress.org/export/1.2/"><channel><wp:wxr_version>1.2</wp:wxr_version></channel></rss>' > "${run_dir}/export/a.xml"
  local manifest='{"migrate":{}}'
  wp_remote() { echo "STUB: wp_remote called -- should NOT happen"; false; }
  run verify_taxonomy_terms_present "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TAX_TERMS:0:0"* ]] || false
  [[ "$output" != *"STUB: wp_remote called"* ]] || false
}

@test "verify_taxonomy_terms_present passes when every declared (taxonomy, slug) pair resolves on B" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr_terms "${run_dir}/export/a.xml" "etch_gallery:landscapes" "category:news"
  local manifest='{"migrate":{}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_remove_file() { :; }
  wp_remote() { echo "OK"; }
  run verify_taxonomy_terms_present "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TAX_TERMS:2:0"* ]] || false
}

@test "verify_taxonomy_terms_present's payload carries the exact (taxonomy, slug) pairs the staged WXR declares, deduplicated" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr_terms "${run_dir}/export/a.xml" "etch_gallery:landscapes" "etch_gallery:landscapes"
  local manifest='{"migrate":{}}'
  local captured="$BATS_TEST_TMPDIR/captured.json"
  graft_push_remap_payload() { printf '%s' "$2" > "$captured"; echo "/fake/remote/path.json"; }
  graft_remove_file() { :; }
  wp_remote() { echo "OK"; }
  run verify_taxonomy_terms_present "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  run jq -e '.pairs == [{"taxonomy":"etch_gallery","slug":"landscapes"}]' "$captured"
  [ "$status" -eq 0 ]
}

@test "verify_taxonomy_terms_present HARD FAILS and names the missing pair(s) when wp eval reports a term missing on B" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr_terms "${run_dir}/export/a.xml" "etch_gallery:landscapes"
  local manifest='{"migrate":{}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_remove_file() { :; }
  wp_remote() { echo "MISSING:etch_gallery:landscapes"; }
  run verify_taxonomy_terms_present "$run_dir" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"etch_gallery:landscapes"* ]] || false
  [[ "$output" == *"TAX_TERMS:1:1"* ]] || false
}

@test "verify_taxonomy_terms_present fails CLOSED (never a silent pass) when the wp eval call itself errors" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr_terms "${run_dir}/export/a.xml" "etch_gallery:landscapes"
  local manifest='{"migrate":{}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_remove_file() { :; }
  wp_remote() { return 1; }
  run verify_taxonomy_terms_present "$run_dir" "$manifest"
  [ "$status" -eq 1 ]
}

@test "verify_taxonomy_terms_present fails CLOSED when wp eval returns an unrecognized result instead of OK/MISSING" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr_terms "${run_dir}/export/a.xml" "etch_gallery:landscapes"
  local manifest='{"migrate":{}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_remove_file() { :; }
  wp_remote() { echo "GARBAGE"; }
  run verify_taxonomy_terms_present "$run_dir" "$manifest"
  [ "$status" -eq 1 ]
}

@test "verify_taxonomy_terms_present fails, does not report success, when the staged WXR fails to parse at all" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  printf 'not xml' > "${run_dir}/export/a.xml"
  local manifest='{"migrate":{}}'
  wp_remote() { echo "STUB: wp_remote called -- should NOT happen, parse failed first"; false; }
  run verify_taxonomy_terms_present "$run_dir" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" != *"STUB: wp_remote called"* ]] || false
}

@test "verify_taxonomy_terms_present always removes the pushed payload file, pass or fail" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr_terms "${run_dir}/export/a.xml" "etch_gallery:landscapes"
  local manifest='{"migrate":{}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  local removed="$BATS_TEST_TMPDIR/removed"
  graft_remove_file() { echo "$2" >> "$removed"; }
  wp_remote() { echo "MISSING:etch_gallery:landscapes"; }
  run verify_taxonomy_terms_present "$run_dir" "$manifest"
  [ "$status" -eq 1 ]
  [ "$(cat "$removed")" = "/fake/remote/path.json" ]
}
