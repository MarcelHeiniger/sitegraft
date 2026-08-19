# tests/unit/test_graft_integrity_gate.bats — graft_integrity_gate (design
# doc §6.4 step 4): non-empty, has <wp:wxr_version>, >=1 <item>, and every
# <wp:post_type> found is in the manifest's allowlist. This is a SECURITY
# control (the leak test below is the load-bearing one — see lib/graft.sh's
# own comment on the jq `index(.)` rebinding trap fixed in commit 770e4c1).
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_integrity_gate passes a well-formed WXR file with allowed post types" {
  local f="$BATS_TEST_TMPDIR/good.xml"
  cat > "$f" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_type>page</wp:post_type></item>
</channel></rss>
EOF
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
<rss><channel><item><wp:post_type>page</wp:post_type></item></channel></rss>
EOF
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"wxr_version"* ]]
}

@test "graft_integrity_gate fails when there is no item" {
  local f="$BATS_TEST_TMPDIR/noitem.xml"
  cat > "$f" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version></channel></rss>
EOF
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"item"* ]]
}

@test "graft_integrity_gate fails when a post_type is outside the allowlist" {
  local f="$BATS_TEST_TMPDIR/leak.xml"
  cat > "$f" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_type>page</wp:post_type></item>
<item><wp:post_type>unexpected_cpt</wp:post_type></item>
</channel></rss>
EOF
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
  cat > "$f" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_type>totally_unexpected</wp:post_type></item>
</channel></rss>
EOF
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
  cat > "$f" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
<item>
  <title><![CDATA[Sample Page]]></title>
  <wp:post_type>page</wp:post_type>
  <wp:postmeta>
    <wp:meta_key>_wp_page_template</wp:meta_key>
    <wp:meta_value><![CDATA[default]]></wp:meta_value>
  </wp:postmeta>
</item>
</channel></rss>
EOF
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
  cat > "$f" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_type><![CDATA[page]]></wp:post_type></item>
</channel></rss>
EOF
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 0 ]
}

@test "graft_integrity_gate rejects a CDATA-wrapped leaked post_type too (defense-in-depth)" {
  local f="$BATS_TEST_TMPDIR/cdata-leak.xml"
  cat > "$f" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_type><![CDATA[injected_evil_type]]></wp:post_type></item>
</channel></rss>
EOF
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"injected_evil_type"* ]]
}

# MINOR-2: fail CLOSED, not open, when >=1 <item> exists but zero post_type
# could actually be parsed out of the file — the exact failure mode a
# format the regex doesn't recognize (CDATA-wrapped or otherwise) would
# produce: found_types silently [], leaked always [], the gate rubber-stamps
# everything. This is the layer above commit 770e4c1's jq fix — that one
# guards the COMPARISON once something was found; this guards against
# finding NOTHING in the first place.
@test "graft_integrity_gate fails closed when items exist but no post_type could be parsed at all (MINOR-2)" {
  local f="$BATS_TEST_TMPDIR/unparseable.xml"
  cat > "$f" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:something_else>page</wp:something_else></item>
</channel></rss>
EOF
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"no <wp:post_type> could be parsed"* ]]
}
