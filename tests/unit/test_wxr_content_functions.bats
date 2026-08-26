# tests/unit/test_wxr_content_functions.bats — lib/php/wxr-content-functions.php
# (issue #52, lib/verify.sh's content-equality guard). Pure PHP (DOMDocument
# + XPath), no WordPress bootstrap, no DDEV, no wp-cli — same
# bare-`php`-CLI-testable property tests/unit/test_content_remap_functions.bats
# already established for lib/php/content-remap-functions.php's own pure
# functions, and for the same reason: this file is `require`d directly by
# lib/php/verify-content-remap-cli.php in production, so these tests run the
# literal same code that runs for real.
setup() {
  PHP_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/lib/php/wxr-content-functions.php"
  [ -f "$PHP_LIB" ] || skip "lib/php/wxr-content-functions.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

# wxr_wrap <items_xml> — wraps one or more <item> blocks in a minimal but
# real WXR envelope (the three namespaces this file's XPath queries
# register: wp, content, excerpt) so every test exercises the same
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
# printing the result as JSON) so every test's XML travels through a real
# file on disk (never embedded inside a `php -r` string, which would need
# its own separate, error-prone layer of bash/PHP quoting for content that
# is itself testing quoting-sensitive bytes like CDATA markers).
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
  # this is exactly why this file uses DOMDocument (->textContent merges
  # sibling CDATA sections into one logical string) instead of a regex.
  run parse_file '<item><wp:post_id>5</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[before]]]]><![CDATA[>after]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>'
  [ "$status" -eq 0 ]
  run jq -e '.[0].post_content == "before]]>after"' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "sitegraft_parse_wxr_items returns an empty array, not a fatal error, for a document with no items" {
  run parse_file ''
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "sitegraft_parse_wxr_items returns an empty array (fails closed, never a fatal) on unparsable XML" {
  local bad_file="$BATS_TEST_TMPDIR/bad.xml"
  printf 'not xml at all <<<' > "$bad_file"
  run php -r "
    require '${PHP_LIB}';
    \$items = sitegraft_parse_wxr_items(file_get_contents('${bad_file}'));
    echo json_encode(\$items);
  "
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
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
