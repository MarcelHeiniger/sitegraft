# tests/unit/test_wxr_item_ids_cli.bats — lib/php/wxr-item-ids-cli.php
# (issue #53/#54's own fix-pack, issue #72, issue #73). Orchestrator-local
# CLI driver behind lib/graft.sh's graft_verify_import_completeness AND
# graft_integrity_gate — real end-to-end tests: genuine WXR file(s) on
# disk, the genuine php CLI driver, same pattern tests/unit/
# test_verify_content_remap_cli.bats already uses for the sibling driver.
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CLI="${REPO_ROOT}/lib/php/wxr-item-ids-cli.php"
  [ -f "$CLI" ] || skip "lib/php/wxr-item-ids-cli.php not found"
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

@test "wxr-item-ids-cli exits 0 and prints one NDJSON line per well-formed item" {
  local f="$BATS_TEST_TMPDIR/good.xml"
  wxr_wrap '<item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item>
<item><wp:post_id>102</wp:post_id><wp:post_type>post</wp:post_type></item>' > "$f"
  run php "$CLI" "$f"
  [ "$status" -eq 0 ]
  run jq -s -e '. == [{"post_id":101,"post_type":"page"},{"post_id":102,"post_type":"post"}]' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "wxr-item-ids-cli exits 1 (usage) with no argv at all" {
  run php "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]] || false
}

@test "wxr-item-ids-cli exits 1 when the listed file does not exist" {
  run php "$CLI" "$BATS_TEST_TMPDIR/does-not-exist.xml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found or unreadable"* ]] || false
}

@test "wxr-item-ids-cli exits 1 when the file does not parse as XML at all" {
  local f="$BATS_TEST_TMPDIR/malformed.xml"
  printf 'not xml' > "$f"
  run php "$CLI" "$f"
  [ "$status" -eq 1 ]
}

# --- issue #73: items_seen vs items_emitted (the real DDEV harness bypass) -

@test "wxr-item-ids-cli exits 1 when an <item> is structurally present but malformed (no wp:post_id), even though a real item is also present" {
  local f="$BATS_TEST_TMPDIR/mixed.xml"
  # Exactly the DDEV harness reproduction: a real, well-formed item, plus a
  # second <item> carrying ONLY a forbidden post_type -- no wp:post_id at
  # all -- injected into an otherwise real export.
  wxr_wrap '<item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item>
<item><wp:post_type>injected_evil_type</wp:post_type></item>' > "$f"
  run php "$CLI" "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has 2 <item> element(s) but only 1 could be parsed"* ]] || false
  # The well-formed item's own row DID stream to stdout before the
  # mismatch was detected (review, MINOR-D) -- a caller must never read
  # partial stdout as a complete result on a nonzero exit, but the bytes
  # themselves are real, not garbled.
  [[ "$output" == *'{"post_id":101,"post_type":"page"}'* ]] || false
  # And the forbidden type itself never silently reaches a caller relying
  # on this driver's output as "every post_type in the file".
  [[ "$output" != *"injected_evil_type"* ]] || false
}

@test "wxr-item-ids-cli exits 1 when EVERY item in the file is malformed" {
  local f="$BATS_TEST_TMPDIR/all-malformed.xml"
  wxr_wrap '<item><wp:post_type>page</wp:post_type></item>
<item><wp:post_type>injected_evil_type</wp:post_type></item>' > "$f"
  run php "$CLI" "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has 2 <item> element(s) but only 0 could be parsed"* ]] || false
}

@test "wxr-item-ids-cli exits 1 on a mismatch in the SECOND of several files, even after the first file streamed real NDJSON" {
  local f1="$BATS_TEST_TMPDIR/one.xml" f2="$BATS_TEST_TMPDIR/two.xml"
  wxr_wrap '<item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item>' > "$f1"
  wxr_wrap '<item><wp:post_id>201</wp:post_id><wp:post_type>page</wp:post_type></item>
<item><wp:post_type>injected_evil_type</wp:post_type></item>' > "$f2"
  run php "$CLI" "$f1" "$f2"
  [ "$status" -eq 1 ]
  [[ "$output" == *'{"post_id":101,"post_type":"page"}'* ]] || false
  [[ "$output" == *'{"post_id":201,"post_type":"page"}'* ]] || false
  [[ "$output" == *"$f2"* ]] || false
}

@test "wxr-item-ids-cli exits 0 when every item across multiple files is well-formed" {
  local f1="$BATS_TEST_TMPDIR/one.xml" f2="$BATS_TEST_TMPDIR/two.xml"
  wxr_wrap '<item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item>' > "$f1"
  wxr_wrap '<item><wp:post_id>201</wp:post_id><wp:post_type>post</wp:post_type></item>' > "$f2"
  run php "$CLI" "$f1" "$f2"
  [ "$status" -eq 0 ]
  run jq -s -e 'length == 2' <<< "$output"
  [ "$status" -eq 0 ]
}
