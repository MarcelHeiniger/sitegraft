# tests/unit/test_wxr_taxonomies_cli.bats — lib/php/wxr-taxonomies-cli.php
# (issue #82). Orchestrator-local CLI driver behind lib/verify.sh's
# verify_taxonomy_terms_present — real end-to-end tests: genuine WXR
# file(s) on disk, the genuine php CLI driver, same pattern
# tests/unit/test_wxr_item_ids_cli.bats already uses for its sibling driver.
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CLI="${REPO_ROOT}/lib/php/wxr-taxonomies-cli.php"
  [ -f "$CLI" ] || skip "lib/php/wxr-taxonomies-cli.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

wxr_wrap() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel>
<wp:wxr_version>1.2</wp:wxr_version>
${1}
</channel>
</rss>
EOF
}

@test "wxr-taxonomies-cli exits 0 and prints one NDJSON line per well-formed <wp:term>" {
  local f="$BATS_TEST_TMPDIR/good.xml"
  wxr_wrap '<wp:term><wp:term_id>5</wp:term_id><wp:term_taxonomy>category</wp:term_taxonomy><wp:term_slug>uncategorized</wp:term_slug><wp:term_name><![CDATA[Uncategorized]]></wp:term_name></wp:term>
<wp:term><wp:term_id>9</wp:term_id><wp:term_taxonomy>etch_gallery</wp:term_taxonomy><wp:term_slug>landscapes</wp:term_slug><wp:term_name><![CDATA[Landscapes]]></wp:term_name></wp:term>' > "$f"
  run php "$CLI" "$f"
  [ "$status" -eq 0 ]
  run jq -s -e '. == [{"taxonomy":"category","slug":"uncategorized","name":"Uncategorized"},{"taxonomy":"etch_gallery","slug":"landscapes","name":"Landscapes"}]' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "wxr-taxonomies-cli skips a <wp:term> with no wp:term_taxonomy rather than guessing" {
  local f="$BATS_TEST_TMPDIR/no-taxonomy.xml"
  wxr_wrap '<wp:term><wp:term_id>5</wp:term_id><wp:term_slug>orphan</wp:term_slug><wp:term_name><![CDATA[Orphan]]></wp:term_name></wp:term>' > "$f"
  run php "$CLI" "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wxr-taxonomies-cli prints an empty result (exit 0) for a well-formed document with no <wp:term> elements" {
  local f="$BATS_TEST_TMPDIR/no-terms.xml"
  wxr_wrap '<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type></item>' > "$f"
  run php "$CLI" "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wxr-taxonomies-cli exits 1 (usage) with no argv at all" {
  run php "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]] || false
}

@test "wxr-taxonomies-cli exits 1 when the listed file does not exist" {
  run php "$CLI" "$BATS_TEST_TMPDIR/does-not-exist.xml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found or unreadable"* ]] || false
}

@test "wxr-taxonomies-cli exits 1 when the file does not parse as XML at all" {
  local f="$BATS_TEST_TMPDIR/malformed.xml"
  printf 'not xml' > "$f"
  run php "$CLI" "$f"
  [ "$status" -eq 1 ]
}

@test "wxr-taxonomies-cli reads terms across multiple files, in argv order" {
  local f1="$BATS_TEST_TMPDIR/one.xml" f2="$BATS_TEST_TMPDIR/two.xml"
  wxr_wrap '<wp:term><wp:term_id>1</wp:term_id><wp:term_taxonomy>category</wp:term_taxonomy><wp:term_slug>news</wp:term_slug><wp:term_name><![CDATA[News]]></wp:term_name></wp:term>' > "$f1"
  wxr_wrap '<wp:term><wp:term_id>2</wp:term_id><wp:term_taxonomy>etch_gallery</wp:term_taxonomy><wp:term_slug>portraits</wp:term_slug><wp:term_name><![CDATA[Portraits]]></wp:term_name></wp:term>' > "$f2"
  run php "$CLI" "$f1" "$f2"
  [ "$status" -eq 0 ]
  run jq -s -e 'length == 2 and .[0].taxonomy == "category" and .[1].taxonomy == "etch_gallery"' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "wxr-taxonomies-cli exits 1 on the second of several files failing to parse, even after the first streamed real NDJSON" {
  local f1="$BATS_TEST_TMPDIR/one.xml" f2="$BATS_TEST_TMPDIR/two.xml"
  wxr_wrap '<wp:term><wp:term_id>1</wp:term_id><wp:term_taxonomy>category</wp:term_taxonomy><wp:term_slug>news</wp:term_slug><wp:term_name><![CDATA[News]]></wp:term_name></wp:term>' > "$f1"
  printf 'not xml' > "$f2"
  run php "$CLI" "$f1" "$f2"
  [ "$status" -eq 1 ]
  [[ "$output" == *'{"taxonomy":"category","slug":"news","name":"News"}'* ]] || false
  [[ "$output" == *"$f2"* ]] || false
}

@test "wxr-taxonomies-cli does not confuse an <item>'s own <category> tag with a <wp:term> element" {
  local f="$BATS_TEST_TMPDIR/item-category.xml"
  wxr_wrap '<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type><category domain="category" nicename="news"><![CDATA[News]]></category></item>' > "$f"
  run php "$CLI" "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
