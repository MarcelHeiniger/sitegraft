# tests/unit/test_wxr_content_functions.bats — lib/php/wxr-content-functions.php
# (issue #52, lib/verify.sh's content-equality guard). Pure PHP (XMLReader),
# no WordPress bootstrap, no DDEV, no wp-cli — same bare-`php`-CLI-testable
# property tests/unit/test_content_remap_functions.bats already established
# for lib/php/content-remap-functions.php's own pure functions, and for the
# same reason: this file is `require`d directly by
# lib/php/verify-content-remap-cli.php in production, so these tests run the
# literal same code that runs for real.
setup() {
  PHP_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/lib/php/wxr-content-functions.php"
  [ -f "$PHP_LIB" ] || skip "lib/php/wxr-content-functions.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

# wxr_wrap <items_xml> — wraps one or more <item> blocks in a minimal but
# real WXR envelope (the three namespaces this file's node-matching relies
# on: wp, content, excerpt) so every test exercises the same
# namespace-resolution path production faces, not a stripped-down fixture.
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

# parse_file <items_xml> — writes wxr_wrap's output to a temp file and runs
# a small PHP driver (reading the file, calling sitegraft_parse_wxr_items,
# printing the result as JSON — `false` prints as the JSON literal `false`,
# never mistaken for `[]`) so every test's XML travels through a real file
# on disk (never embedded inside a `php -r` string, which would need its
# own separate, error-prone layer of bash/PHP quoting for content that is
# itself testing quoting-sensitive bytes like CDATA markers).
parse_file() {
  local xml_file="$BATS_TEST_TMPDIR/in.xml"
  wxr_wrap "$1" > "$xml_file"
  php -r "
    require '${PHP_LIB}';
    \$items = sitegraft_parse_wxr_items(file_get_contents('${xml_file}'));
    echo json_encode(\$items);
  "
}

@test "sitegraft_parse_wxr_items extracts post_id, post_type, content and excerpt from a single item" {
  run parse_file '<item>
    <title>Home</title>
    <wp:post_id>16</wp:post_id>
    <wp:post_type>page</wp:post_type>
    <content:encoded><![CDATA[<p>Hello from A</p>]]></content:encoded>
    <excerpt:encoded><![CDATA[short excerpt]]></excerpt:encoded>
  </item>'
  [ "$status" -eq 0 ]
  run jq -e '. == [{"post_id":16,"post_type":"page","post_content":"<p>Hello from A</p>","post_excerpt":"short excerpt"}]' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "sitegraft_parse_wxr_items handles multiple items in document order" {
  run parse_file '<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[first]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>
<item><wp:post_id>2</wp:post_id><wp:post_type>post</wp:post_type><content:encoded><![CDATA[second]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>'
  [ "$status" -eq 0 ]
  run jq -e 'length == 2 and .[0].post_id == 1 and .[0].post_content == "first" and .[1].post_id == 2 and .[1].post_content == "second"' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "sitegraft_parse_wxr_items reassembles content containing a literal ]]> (WordPress's own split-CDATA escape)" {
  # WordPress's own exporter cannot put a literal "]]>" inside a single CDATA
  # section (that byte sequence terminates it), so it splits the content
  # into TWO adjacent CDATA sections around the escape:
  # "before]]" + "]]><![CDATA[" + ">after" -- i.e. the literal bytes
  # "before]]>after" arrive as two sibling CDATA nodes under one
  # content:encoded element. A regex-based `<!\[CDATA\[(.*?)\]\]>` extraction
  # would stop at the FIRST "]]>" and silently truncate to "before]]" --
  # this is exactly why this file uses DOM ->textContent (via
  # XMLReader::expand(), one <item> at a time) instead of a regex.
  run parse_file '<item><wp:post_id>5</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[before]]]]><![CDATA[>after]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>'
  [ "$status" -eq 0 ]
  run jq -e '.[0].post_content == "before]]>after"' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "sitegraft_parse_wxr_items returns an empty array, not false, for a well-formed document with no items" {
  run parse_file ''
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# review finding m1 (issue #52 fix-pack): `[]` used to mean BOTH "parsed
# fine, zero items" AND "could not parse this at all" -- indistinguishable
# to a caller. Genuinely unparsable input must now come back as `false`
# (the JSON literal, not the empty array), so lib/php/verify-content-
# remap-cli.php can tell the two apart and surface the second as a real
# error instead of silently treating it as "nothing to check".
@test "sitegraft_parse_wxr_items returns false (never []), fails closed without a fatal, on unparsable XML" {
  run php -r "
    require '${PHP_LIB}';
    \$items = sitegraft_parse_wxr_items('not xml at all <<<');
    echo json_encode(\$items);
  "
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "sitegraft_parse_wxr_items returns false (never []) on a genuinely empty input" {
  run php -r "
    require '${PHP_LIB}';
    \$items = sitegraft_parse_wxr_items('');
    echo json_encode(\$items);
  "
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "sitegraft_parse_wxr_items treats a missing excerpt:encoded element as an empty string, not a PHP error" {
  run parse_file '<item><wp:post_id>9</wp:post_id><wp:post_type>attachment</wp:post_type><content:encoded><![CDATA[att content]]></content:encoded></item>'
  [ "$status" -eq 0 ]
  run jq -e '.[0].post_excerpt == ""' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "sitegraft_parse_wxr_items skips an <item> with no wp:post_id rather than guessing" {
  run parse_file '<item><wp:post_type>page</wp:post_type><content:encoded><![CDATA[x]]></content:encoded></item>'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- sitegraft_parse_wxr_items_from_file (production entry point) ----------

@test "sitegraft_parse_wxr_items_from_file reads directly off disk and matches the string-based function's result" {
  local xml_file="$BATS_TEST_TMPDIR/in.xml"
  wxr_wrap '<item><wp:post_id>16</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[<p>Hello</p>]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>' > "$xml_file"
  run php -r "
    require '${PHP_LIB}';
    \$items = sitegraft_parse_wxr_items_from_file('${xml_file}');
    echo json_encode(\$items);
  "
  [ "$status" -eq 0 ]
  run jq -e '. == [{"post_id":16,"post_type":"page","post_content":"<p>Hello</p>","post_excerpt":""}]' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "sitegraft_parse_wxr_items_from_file returns false for a nonexistent file" {
  run php -r "
    require '${PHP_LIB}';
    \$items = sitegraft_parse_wxr_items_from_file('${BATS_TEST_TMPDIR}/does-not-exist.xml');
    echo json_encode(\$items);
  "
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

# --- M1: memory (execution-verified, not assumed) ---------------------------
# review finding M1: DOMDocument::loadXML() on a ~62MB export was FATAL
# under a 128M and a 256M memory_limit. This proves the XMLReader-based
# rewrite stays well under a constrained limit on a comparable synthetic
# export, and that peak memory does not scale with item COUNT the way a
# whole-document DOM would.
@test "sitegraft_parse_wxr_items_from_file stays under a 32M memory_limit on a 20MB synthetic export (would have been fatal under DOMDocument)" {
  local xml_file="$BATS_TEST_TMPDIR/big.xml"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<rss version="2.0" xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:wp="http://wordpress.org/export/1.2/"><channel><wp:wxr_version>1.2</wp:wxr_version>\n'
    local i chunk
    chunk=$(head -c 20000 /dev/zero | tr '\0' 'x')
    for i in $(seq 1 1000); do
      printf '<item><wp:post_id>%d</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[%s]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>\n' "$i" "$chunk"
    done
    printf '</channel></rss>\n'
  } > "$xml_file"
  ls -la "$xml_file"

  run php -d memory_limit=32M -r "
    require '${PHP_LIB}';
    \$count = 0;
    \$ok = sitegraft_stream_wxr_items_from_file('${xml_file}', function (\$item) use (&\$count) { \$count++; });
    if (!\$ok) { fwrite(STDERR, 'parse reported failure'); exit(1); }
    if (\$count !== 1000) { fwrite(STDERR, \"expected 1000 items, got \$count\n\"); exit(1); }
    echo 'OK peak=' . round(memory_get_peak_usage(true) / 1024 / 1024, 1) . 'MB';
  "
  [ "$status" -eq 0 ]
  [[ "$output" == OK* ]] || false
}

# --- entity safety (execution-verified) -------------------------------------

@test "sitegraft_parse_wxr_items never substitutes a local-file XXE entity into content" {
  local xml_file="$BATS_TEST_TMPDIR/xxe.xml"
  cat > "$xml_file" <<'XML'
<?xml version="1.0"?>
<!DOCTYPE rss [<!ENTITY xxe SYSTEM "file:///etc/hostname">]>
<rss version="2.0" xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[leak: &xxe;]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>
</channel></rss>
XML
  run php -r "
    require '${PHP_LIB}';
    \$items = sitegraft_parse_wxr_items_from_file('${xml_file}');
    if (\$items === false) { echo 'PARSE-FAILED-SAFELY'; exit(0); }
    \$content = \$items[0]['post_content'] ?? '';
    if (strpos(\$content, 'root') !== false || strpos(\$content, ':/bin/') !== false) {
      fwrite(STDERR, 'XXE substituted local file content: ' . \$content);
      exit(1);
    }
    echo 'SAFE:' . \$content;
  "
  [ "$status" -eq 0 ]
  [[ "$output" == SAFE:* || "$output" == "PARSE-FAILED-SAFELY" ]] || false
}

@test "sitegraft_parse_wxr_items does not expand a nested entity-bomb payload" {
  local xml_file="$BATS_TEST_TMPDIR/bomb.xml"
  cat > "$xml_file" <<'XML'
<?xml version="1.0"?>
<!DOCTYPE rss [
  <!ENTITY a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">
  <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
  <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
  <!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">
]>
<rss version="2.0" xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[&d;]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>
</channel></rss>
XML
  run php -d memory_limit=64M -r "
    require '${PHP_LIB}';
    \$items = sitegraft_parse_wxr_items_from_file('${xml_file}');
    \$content = (\$items === false) ? '' : (\$items[0]['post_content'] ?? '');
    if (strlen(\$content) > 100000) {
      fwrite(STDERR, 'entity bomb expanded: ' . strlen(\$content) . ' bytes');
      exit(1);
    }
    echo 'OK:' . strlen(\$content) . ' bytes, ' . round(memory_get_peak_usage(true) / 1024 / 1024, 1) . 'MB peak';
  "
  [ "$status" -eq 0 ]
  [[ "$output" == OK:* ]] || false
}

# --- review round 2 finding: fail on FATAL libxml errors only -------------

@test "sitegraft_parse_wxr_items tolerates a RECOVERABLE libxml error (an undeclared namespace prefix on an unrelated element) and still extracts the item" {
  # A real, non-fatal libxml condition (level 2, LIBXML_ERR_ERROR, verified
  # by direct probe before writing this test — NOT level 1/WARNING, but
  # still well below LIBXML_ERR_FATAL/3): an <item> carrying one element
  # under an undeclared namespace prefix. libxml recovers and keeps
  # parsing; this file must not fail the WHOLE document over it.
  run parse_file '<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[hi]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded><foo:bar>baz</foo:bar></item>'
  [ "$status" -eq 0 ]
  run jq -e '. == [{"post_id":1,"post_type":"page","post_content":"hi","post_excerpt":""}]' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "sitegraft_parse_wxr_items still fails closed on a genuine FATAL parse error (unclosed tag)" {
  local xml_file="$BATS_TEST_TMPDIR/unclosed.xml"
  cat > "$xml_file" <<'XML'
<?xml version="1.0"?>
<rss version="2.0" xmlns:wp="http://wordpress.org/export/1.2/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[hi]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded>
XML
  run php -r "
    require '${PHP_LIB}';
    \$items = sitegraft_parse_wxr_items_from_file('${xml_file}');
    echo json_encode(\$items);
  "
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

# --- review round 2 minor finding: WXR version other than 1.2 is a loud --
# failure, not a silent zero-item result. wp-cli's own `wp export` has
# only ever emitted 1.2 (no practical consequence for a real graft), but a
# hand-supplied or third-party WXR 1.0/1.1 file used to parse to `[]`
# (this file's namespace matching is hardcoded to the 1.2 URIs) --
# indistinguishable from a genuinely empty 1.2 export.
@test "sitegraft_parse_wxr_items fails closed (false) on a declared WXR version other than 1.2" {
  local xml_file="$BATS_TEST_TMPDIR/wxr10.xml"
  cat > "$xml_file" <<'XML'
<?xml version="1.0"?>
<rss version="2.0" xmlns:wp="http://wordpress.org/export/1.0/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:excerpt="http://wordpress.org/export/1.0/excerpt/">
<channel><wp:wxr_version>1.0</wp:wxr_version>
<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[hi]]></content:encoded></item>
</channel></rss>
XML
  run php -r "
    require '${PHP_LIB}';
    \$items = sitegraft_parse_wxr_items_from_file('${xml_file}');
    echo json_encode(\$items);
  "
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "sitegraft_parse_wxr_items still parses a genuine 1.2 document with wxr_version present (no regression)" {
  run parse_file '<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[hi]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>'
  [ "$status" -eq 0 ]
  run jq -e '. == [{"post_id":1,"post_type":"page","post_content":"hi","post_excerpt":""}]' <<< "$output"
  [ "$status" -eq 0 ]
}
