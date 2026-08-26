# tests/unit/test_verify_content_remap_cli.bats — lib/php/verify-content-remap-cli.php
# (issue #52). Orchestrator-local driver for lib/verify.sh's content-equality
# guard: parses A's already-exported WXR file(s) (lib/php/wxr-content-
# functions.php) and applies the SAME two remaps `sitegraft graft` itself
# applies to a migrated post (lib/php/content-remap-functions.php's
# sitegraft_remap_attachment_refs / sitegraft_remap_domain) — never a third,
# independently-drifting reimplementation of what "the value graft was
# supposed to produce" means. Runs entirely on the orchestrator against a
# local payload file and local WXR file(s); no WordPress bootstrap, no
# network call to A or B.
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CLI="${REPO_ROOT}/lib/php/verify-content-remap-cli.php"
  [ -f "$CLI" ] || skip "lib/php/verify-content-remap-cli.php not found"
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

@test "verify-content-remap-cli remaps an attachment id reference and a domain string, in that order, for a plain post" {
  local xml_file="$BATS_TEST_TMPDIR/export.xml"
  wxr_wrap '<item><wp:post_id>10</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[<!-- wp:etch/image {"id":7,"src":"https:\/\/a.example.com\/x.jpg"} -->]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>' > "$xml_file"

  local payload_file="$BATS_TEST_TMPDIR/payload.json"
  cat > "$payload_file" <<EOF
{
  "wxr_files": ["${xml_file}"],
  "attachments": [{"old": "7", "new": "42"}],
  "domain": {"from": "https://a.example.com", "to": "https://b.example.com"}
}
EOF
  run php "$CLI" "$payload_file"
  [ "$status" -eq 0 ]
  # Built via jq --arg (not a hand-typed JSON literal): the remapped content
  # carries a real backslash-then-slash byte pair (sitegraft_remap_domain's
  # JSON-escaped-form pass), and json_encode's own default escaping of both
  # "\" and "/" makes the RAW JSON text a poor thing to eyeball-match here —
  # jq parses both sides into actual string values first, so the comparison
  # is byte-for-byte on the decoded value, the same way verify_options_match
  # itself is documented to compare (lib/verify.sh).
  local want='<!-- wp:etch/image {"id":42,"src":"https:\/\/b.example.com\/x.jpg"} -->'
  run jq -e --arg want "$want" '.[0].post_id == 10 and .[0].post_type == "page" and .[0].post_content == $want and .[0].post_excerpt == ""' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "verify-content-remap-cli never applies the attachment-id remap to a wp_navigation item (mirrors graft_remap_attachment_ids' own exclusion)" {
  local xml_file="$BATS_TEST_TMPDIR/export.xml"
  wxr_wrap '<item><wp:post_id>20</wp:post_id><wp:post_type>wp_navigation</wp:post_type><content:encoded><![CDATA[<!-- wp:navigation-link {"id":7,"kind":"taxonomy"} -->]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>' > "$xml_file"

  local payload_file="$BATS_TEST_TMPDIR/payload.json"
  cat > "$payload_file" <<EOF
{
  "wxr_files": ["${xml_file}"],
  "attachments": [{"old": "7", "new": "42"}],
  "domain": {"from": "", "to": ""}
}
EOF
  run php "$CLI" "$payload_file"
  [ "$status" -eq 0 ]
  run jq -e '.[0].post_content | contains("\"id\":7")' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "verify-content-remap-cli applies the domain remap to a wp_navigation item (domain remap is NOT excluded there)" {
  local xml_file="$BATS_TEST_TMPDIR/export.xml"
  wxr_wrap '<item><wp:post_id>21</wp:post_id><wp:post_type>wp_navigation</wp:post_type><content:encoded><![CDATA[<!-- wp:navigation-link {"url":"https://a.example.com/about"} -->]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>' > "$xml_file"

  local payload_file="$BATS_TEST_TMPDIR/payload.json"
  cat > "$payload_file" <<EOF
{
  "wxr_files": ["${xml_file}"],
  "attachments": [],
  "domain": {"from": "https://a.example.com", "to": "https://b.example.com"}
}
EOF
  run php "$CLI" "$payload_file"
  [ "$status" -eq 0 ]
  run jq -e '.[0].post_content == "<!-- wp:navigation-link {\"url\":\"https://b.example.com/about\"} -->"' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "verify-content-remap-cli applies no remap at all when attachments is empty and domain.from is empty (byte-identical passthrough)" {
  local xml_file="$BATS_TEST_TMPDIR/export.xml"
  wxr_wrap '<item><wp:post_id>30</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[plain content, nothing to remap]]></content:encoded><excerpt:encoded><![CDATA[an excerpt]]></excerpt:encoded></item>' > "$xml_file"

  local payload_file="$BATS_TEST_TMPDIR/payload.json"
  cat > "$payload_file" <<EOF
{"wxr_files": ["${xml_file}"], "attachments": [], "domain": {"from": "", "to": ""}}
EOF
  run php "$CLI" "$payload_file"
  [ "$status" -eq 0 ]
  run jq -e '. == [{"post_id":30,"post_type":"page","post_content":"plain content, nothing to remap","post_excerpt":"an excerpt"}]' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "verify-content-remap-cli merges items across multiple WXR files (a large export split by wp-cli)" {
  local xml_file1="$BATS_TEST_TMPDIR/export-1.xml"
  local xml_file2="$BATS_TEST_TMPDIR/export-2.xml"
  wxr_wrap '<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[a]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>' > "$xml_file1"
  wxr_wrap '<item><wp:post_id>2</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[b]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>' > "$xml_file2"

  local payload_file="$BATS_TEST_TMPDIR/payload.json"
  cat > "$payload_file" <<EOF
{"wxr_files": ["${xml_file1}", "${xml_file2}"], "attachments": [], "domain": {"from": "", "to": ""}}
EOF
  run php "$CLI" "$payload_file"
  [ "$status" -eq 0 ]
  run jq -e 'length == 2 and (map(.post_id) | sort) == [1,2]' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "verify-content-remap-cli exits non-zero and says why when a listed WXR file does not exist" {
  local payload_file="$BATS_TEST_TMPDIR/payload.json"
  cat > "$payload_file" <<EOF
{"wxr_files": ["${BATS_TEST_TMPDIR}/does-not-exist.xml"], "attachments": [], "domain": {"from": "", "to": ""}}
EOF
  run php "$CLI" "$payload_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does-not-exist.xml"* ]] || false
}

@test "verify-content-remap-cli exits non-zero when the payload file itself is missing" {
  run php "$CLI" "${BATS_TEST_TMPDIR}/nope.json"
  [ "$status" -ne 0 ]
}

@test "verify-content-remap-cli exits non-zero on a payload that is not valid JSON" {
  local payload_file="$BATS_TEST_TMPDIR/payload.json"
  printf 'not json' > "$payload_file"
  run php "$CLI" "$payload_file"
  [ "$status" -ne 0 ]
}

# review finding m1 (issue #52 fix-pack): a WXR file that exists and is
# readable but is not valid XML must be a loud, distinguishable failure --
# not silently treated the same as a file that parsed fine and genuinely
# has zero items.
@test "verify-content-remap-cli exits non-zero and says why when a listed WXR file is not valid XML" {
  local xml_file="$BATS_TEST_TMPDIR/garbage.xml"
  printf 'this is not xml at all <<<' > "$xml_file"
  local payload_file="$BATS_TEST_TMPDIR/payload.json"
  cat > "$payload_file" <<EOF
{"wxr_files": ["${xml_file}"], "attachments": [], "domain": {"from": "", "to": ""}}
EOF
  run php "$CLI" "$payload_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not parse"* ]] || false
  [[ "$output" == *"garbage.xml"* ]] || false
}

# review finding M1 (execution-verified, same measurement point the review
# itself used): a 62MB WXR export was FATAL under the OLD
# file_get_contents() + DOMDocument::loadXML() driver at BOTH 128M and
# 256M memory_limit. This is the identical 62MB scenario against the NEW
# streaming driver, at the identical two limits -- both now succeed
# (measured peak RSS ~157MB regardless of the limit between 128M and 256M,
# i.e. bounded by the export's own content size, not by a DOM multiplier
# of it).
@test "verify-content-remap-cli survives the exact 62MB/128M scenario that was fatal before this fix (review finding M1)" {
  local xml_file="$BATS_TEST_TMPDIR/big62.xml"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<rss version="2.0" xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:wp="http://wordpress.org/export/1.2/"><channel><wp:wxr_version>1.2</wp:wxr_version>\n'
    local i chunk
    chunk=$(head -c 62000 /dev/zero | tr '\0' 'x')
    for i in $(seq 1 1000); do
      printf '<item><wp:post_id>%d</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[%s]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>\n' "$i" "$chunk"
    done
    printf '</channel></rss>\n'
  } > "$xml_file"

  local payload_file="$BATS_TEST_TMPDIR/payload.json"
  cat > "$payload_file" <<EOF
{"wxr_files": ["${xml_file}"], "attachments": [], "domain": {"from": "", "to": ""}}
EOF
  run php -d memory_limit=128M "$CLI" "$payload_file"
  [ "$status" -eq 0 ]
  run jq -e 'length == 1000' <<< "$output"
  [ "$status" -eq 0 ]
}
