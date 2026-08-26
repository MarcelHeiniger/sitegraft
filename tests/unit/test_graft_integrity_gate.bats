# tests/unit/test_graft_integrity_gate.bats — graft_integrity_gate (design
# doc §6.4 step 4): non-empty, has <wp:wxr_version>, >=1 <item>, and every
# <wp:post_type> found is in the manifest's allowlist. This is a SECURITY
# control (the leak test below is the load-bearing one — see lib/graft.sh's
# own comment on the jq `index(.)` rebinding trap fixed in commit 770e4c1).
#
# issue #72: post_type extraction now runs through the SAME structural,
# namespace-aware driver (lib/php/wxr-item-ids-cli.php, over lib/php/wxr-
# content-functions.php's streaming XMLReader) graft_verify_import_
# completeness already uses — not this function's own former line-oriented
# `grep -o ... | sed` scan. Every fixture below therefore needs a REAL WXR
# shape: the wp:/content:/excerpt: namespaces actually declared, and a
# <wp:post_id> alongside every <wp:post_type> (the driver requires BOTH
# before it recognizes an <item> at all — see wxr-content-functions.php's
# own _sitegraft_wxr_item_from_node). An earlier version of these fixtures
# had neither and still passed, because the previous awk/grep-based scan
# never looked at namespaces or post_id at all — verified live while
# building issue #72's fix: every one of them silently found ZERO items
# against the real driver until fixed here.
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

# _wxr_wrap <items_xml> — wraps one or more <item> blocks in a minimal but
# real WXR envelope (the three namespaces wp:/content:/excerpt: the shared
# driver's own namespace-resolution relies on), same pattern
# tests/unit/test_wxr_content_functions.bats and tests/unit/
# test_verify_content_remap_cli.bats already use for the identical reason.
_wxr_wrap() {
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

@test "graft_integrity_gate passes a well-formed WXR file with allowed post types" {
  local f="$BATS_TEST_TMPDIR/good.xml"
  _wxr_wrap '<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type></item>' > "$f"
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 0 ]
}

@test "graft_integrity_gate fails on an empty file" {
  local f="$BATS_TEST_TMPDIR/empty.xml"
  : > "$f"
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
}

@test "graft_integrity_gate fails when there is no wxr_version marker" {
  local f="$BATS_TEST_TMPDIR/nover.xml"
  cat > "$f" <<'EOF'
<rss><channel><item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type></item></channel></rss>
EOF
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"wxr_version"* ]]
}

@test "graft_integrity_gate fails when there is no item" {
  local f="$BATS_TEST_TMPDIR/noitem.xml"
  _wxr_wrap '' > "$f"
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"item"* ]]
}

@test "graft_integrity_gate fails when a post_type is outside the allowlist" {
  local f="$BATS_TEST_TMPDIR/leak.xml"
  _wxr_wrap '<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type></item>
<item><wp:post_id>2</wp:post_id><wp:post_type>unexpected_cpt</wp:post_type></item>' > "$f"
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected_cpt"* ]]
}

@test "graft_integrity_gate: the leak check actually distinguishes leaked from allowed (guards the jq index(.) rebinding trap)" {
  # A discriminating regression test: the buggy form `select(($allowed |
  # index(.)) | not)` rebinds `.` to $allowed itself before index() runs, so
  # it always searches $allowed for $allowed — `leaked` is always `[]`
  # regardless of what actually leaked, and this gate silently never fires.
  # A file whose ONLY post_type is NOT in the allowlist must still fail.
  local f="$BATS_TEST_TMPDIR/onlyleak.xml"
  _wxr_wrap '<item><wp:post_id>1</wp:post_id><wp:post_type>totally_unexpected</wp:post_type></item>' > "$f"
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"totally_unexpected"* ]]
}

# Real-world format check (verified live against an actual `wp export` from
# wp-cli 2.x / WordPress 7.1, both by direct output inspection and by reading
# wp-cli's own WP_Export_WXR_Formatter.php source): `<wp:post_type>` is
# plain text there, NOT CDATA-wrapped — unlike title/content/meta_value,
# which ARE. The fixture below matches that real shape exactly.
@test "graft_integrity_gate passes a WXR file shaped exactly like a real wp-cli export (plain wp:post_type, CDATA title/meta)" {
  local f="$BATS_TEST_TMPDIR/real-shape.xml"
  _wxr_wrap '<item>
  <title><![CDATA[Sample Page]]></title>
  <wp:post_id>1</wp:post_id>
  <wp:post_type>page</wp:post_type>
  <wp:postmeta>
    <wp:meta_key>_wp_page_template</wp:meta_key>
    <wp:meta_value><![CDATA[default]]></wp:meta_value>
  </wp:postmeta>
</item>' > "$f"
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 0 ]
}

# Defense-in-depth, not a reproduction of a real wp-cli shape (see the test
# above): even if a WXR file — from a different export path, a future
# wp-cli version, or a hand-edited file — DID wrap wp:post_type in CDATA,
# the gate must still parse and enforce it correctly, both for an allowed
# type and a leaked one.
@test "graft_integrity_gate also correctly parses a CDATA-wrapped wp:post_type, if one is ever encountered (defense-in-depth, not today's real shape)" {
  local f="$BATS_TEST_TMPDIR/cdata-post-type.xml"
  _wxr_wrap '<item><wp:post_id><![CDATA[1]]></wp:post_id><wp:post_type><![CDATA[page]]></wp:post_type></item>' > "$f"
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 0 ]
}

@test "graft_integrity_gate rejects a CDATA-wrapped leaked post_type too (defense-in-depth)" {
  local f="$BATS_TEST_TMPDIR/cdata-leak.xml"
  _wxr_wrap '<item><wp:post_id>1</wp:post_id><wp:post_type><![CDATA[injected_evil_type]]></wp:post_type></item>' > "$f"
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"injected_evil_type"* ]]
}

# MINOR-2: fail CLOSED, not open, when >=1 <item> exists but zero post_type
# could actually be parsed out of the file — the exact failure mode a
# format the driver doesn't recognize (missing wp:post_id, an unexpected
# shape, or otherwise) would produce: found_types silently [], leaked
# always [], the gate rubber-stamps everything. This guard predates issue
# #72's own move to the shared driver and must survive it unchanged — this
# test is exactly what proves that: a real <item> with no wp:post_type AND
# no wp:post_id (the shared driver's own "not well-formed, skip" case)
# still hard-fails here, never silently passes.
@test "graft_integrity_gate fails closed when items exist but no post_type could be parsed at all (MINOR-2)" {
  local f="$BATS_TEST_TMPDIR/unparseable.xml"
  _wxr_wrap '<item><wp:something_else>page</wp:something_else></item>' > "$f"
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"no <wp:post_type> could be parsed"* ]]
}

@test "graft_integrity_gate HARD FAILS (fail-closed, MINOR-2) when an item has wp:post_type but no wp:post_id — the shared driver's own well-formedness rule" {
  local f="$BATS_TEST_TMPDIR/no-post-id.xml"
  _wxr_wrap '<item><wp:post_type>page</wp:post_type></item>' > "$f"
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"no <wp:post_type> could be parsed"* ]]
}

@test "graft_integrity_gate HARD FAILS when the WXR file cannot be parsed at all, never silently reads it as zero post_types" {
  local f="$BATS_TEST_TMPDIR/malformed.xml"
  printf 'this is not xml at all' > "$f"
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 1 ]
}

# --- issue #72: two <item>s sharing one physical line -------------------
#
# The exact regression this fix-pack round exists to close. Under the
# PREVIOUS `grep -o '<wp:post_type>.*</wp:post_type>' | sed` scan, `.*`
# spanned across both items' tags when they shared a line, extracting one
# garbled string covering everything from the FIRST `<wp:post_type>` to
# the LAST `</wp:post_type>` on that line — reproduced live as exactly
# this: an allowlist of `["page"]` against two real, ALLOWED `<item>`s
# (each a genuine `<wp:post_type>page</wp:post_type>`) still aborted with
# "WXR contains post_type(s) outside the manifest allowlist:
# page</item><item><wp:post_id>102</wp:post_id>page" — a false leak,
# reported as if it were real, for content the allowlist genuinely
# covers. The structural driver has no such failure mode: each <item>'s
# own children are read from its own subtree, never from what shares its
# physical line.
@test "graft_integrity_gate correctly passes two ALLOWED items sharing one physical line (issue #72 — the exact false-leak reproduction)" {
  local f="$BATS_TEST_TMPDIR/adjacent-allowed.xml"
  _wxr_wrap '<item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item><item><wp:post_id>102</wp:post_id><wp:post_type>page</wp:post_type></item>' > "$f"
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 0 ]
  [[ "$output" != *"page</item>"* ]] || false
}

@test "graft_integrity_gate still catches a REAL leaked post_type when it shares a line with an allowed one (issue #72)" {
  local f="$BATS_TEST_TMPDIR/adjacent-leak.xml"
  _wxr_wrap '<item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item><item><wp:post_id>102</wp:post_id><wp:post_type>unexpected_cpt</wp:post_type></item>' > "$f"
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected_cpt"* ]]
  # Never a raw XML fragment standing in for the leaked type name — the
  # previous grep/sed scan's exact failure mode on this shape.
  [[ "$output" != *"</item><item>"* ]] || false
}
