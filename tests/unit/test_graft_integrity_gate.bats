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
