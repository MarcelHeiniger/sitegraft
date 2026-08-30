bats_require_minimum_version 1.5.0
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

@test "graft_integrity_gate fails cleanly, without leaking a bare '/stderr' path, when sitegraft_mktemp_dir cannot create a temp dir (issue #109)" {
  # graft_integrity_gate is invoked by its own caller as
  # `graft_integrity_gate ... || return 1` (lib/graft.sh's phase_graft),
  # which disables errexit for its entire call tree -- so this only
  # actually proves the fix if the tmp_dir assignment inside
  # graft_integrity_gate itself checks sitegraft_mktemp_dir's exit status
  # explicitly, not merely relies on sitegraft_mktemp_dir being hardened
  # at the source. Reproduced here the same way: called as the left side
  # of `||`, same as production.
  #
  # A non-existent TMPDIR makes mktemp -d fail for real (measured), which
  # is what used to make stderr_file collapse to the bare path "/stderr"
  # -- a redirect target that fails to open on a real filesystem, leaking
  # a raw path into the output and misreporting an unrelated cause.
  local f="$BATS_TEST_TMPDIR/good.xml"
  _wxr_wrap '<item><wp:post_id>1</wp:post_id><wp:post_type>page</wp:post_type></item>' > "$f"
  local missing_tmpdir="$BATS_TEST_TMPDIR/does-not-exist"
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo "SITEGRAFT_ROOT='${SITEGRAFT_ROOT}'"
    echo ". '${BATS_TEST_DIRNAME}/../../lib/core.sh'"
    echo ". '${BATS_TEST_DIRNAME}/../../lib/graft.sh'"
    echo "graft_integrity_gate '${f}' '[\"page\"]' || exit 1"
  } > "$probe"
  TMPDIR="$missing_tmpdir" run --separate-stderr bash "$probe"
  [ "$status" -ne 0 ]
  [[ "$stderr" != *"/stderr"* ]] || false
  [[ "$output" != *"/stderr"* ]] || false
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

# MINOR-2: fail CLOSED, not open, when >=1 <item> exists per the cheap raw
# `grep -c '<item>'` pre-check but the shared STRUCTURAL driver finds ZERO
# real <item> ELEMENTS at all. This guard predates issue #72's own move to
# the shared driver and must survive it unchanged. issue #73's own new
# fail-closed path (items_seen > items_emitted, inside the driver itself)
# has since taken over every case where a real <item> element exists but
# is malformed (missing wp:post_id and/or wp:post_type) — see the two
# tests below this one for that, now more specific, path. What THIS guard
# still uniquely covers is the raw-grep-vs-structural DISAGREEMENT itself:
# the text "<item>" appearing in the file without there being a real
# <item> ELEMENT there at all (e.g. as a literal substring inside another
# element's own CDATA body) — grep's cheap pre-check sees it, the
# structural driver correctly does not, and `found_types` really is `[]`
# with items_seen genuinely 0 too (the driver succeeds, rc=0, with
# nothing to report).
@test "graft_integrity_gate fails closed when a raw grep '<item>' match does not correspond to a real <item> ELEMENT (MINOR-2)" {
  local f="$BATS_TEST_TMPDIR/text-only-item.xml"
  _wxr_wrap '<title><![CDATA[an example <item> mentioned in prose, not a real element]]></title>' > "$f"
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"no <wp:post_type> could be parsed"* ]]
}

# issue #73 (superseding the OLD message this test used to assert before
# the driver itself started catching this case — see that section's own
# header comment above for the full mechanism): a single <item> with
# wp:post_type but no wp:post_id now fails at the DRIVER level
# (items_seen=1, items_emitted=0), wrapped by this function's own
# existing `rc != 0` handling — never reaching the bash-level
# "found_types empty" branch the test above still covers for a genuinely
# different case.
@test "graft_integrity_gate HARD FAILS (fail-closed) when an item has wp:post_type but no wp:post_id — the shared driver's own well-formedness rule (issue #73)" {
  local f="$BATS_TEST_TMPDIR/no-post-id.xml"
  _wxr_wrap '<item><wp:post_type>page</wp:post_type></item>' > "$f"
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not parse WXR file"* ]] || false
  [[ "$output" == *"but only 0 could be parsed"* ]] || false
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

# --- issue #73: the real DDEV harness bypass -------------------------------
#
# graft_integrity_gate is a SECURITY control (design doc §6.4 step 4): a
# malformed <item> the shared driver silently dropped (missing wp:post_id
# alongside wp:post_type — see wxr-content-functions.php's own
# _sitegraft_wxr_item_from_node) was invisible to this gate's own leak
# check, because `found_types` was never empty (a real, well-formed item
# WAS also present in the file) — the pre-existing MINOR-2 fail-closed
# guard ("zero types found at all") never triggered, since "some found,
# one silently dropped" is a different case it was never written to
# catch. Confirmed live against a real DDEV harness run before this fix:
# a WXR carrying `<item><wp:post_type>injected_evil_type</wp:post_type>
# </item>` (no wp:post_id) alongside a real, allowed `page` item made
# this gate ACCEPT the file. The fix lives in the shared driver itself
# (lib/php/wxr-item-ids-cli.php, issue #73 — see its own header): it now
# refuses to succeed at all when it structurally saw more <item>s than it
# could parse as well-formed, and this function's own existing `rc != 0`
# handling (BLOCKER-1's original fail-closed path) already treats that
# the same as any other unparseable file — no new bash-level logic needed
# here, only this test proving the WHOLE chain closes the gap.

@test "graft_integrity_gate HARD FAILS on a WXR carrying a forbidden post_type on a malformed (no-post_id) item, even alongside a real allowed item (issue #73 — the DDEV harness reproduction)" {
  local f="$BATS_TEST_TMPDIR/harness-leak.xml"
  cat > "$f" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item>
<item><wp:post_type>injected_evil_type</wp:post_type></item>
</channel></rss>
EOF
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not parse WXR file"* ]] || false
  [[ "$output" == *"but only 1 could be parsed"* ]] || false
}

# --- reviewer's own BLOCKER: the orchestrator's own php.ini can put noise --
# on stdout, ahead of the driver's real NDJSON (display_errors => STDOUT is
# a common default; sitegraft does not control it). Simulated here with a
# `php` shell function that always prints a bogus line before delegating
# to the real interpreter — the exact shape a stray warning/notice/
# deprecation from the operator's own php.ini would produce.

_stub_php_with_stdout_noise() {
  # shellcheck disable=SC2317  # invoked indirectly, as the `php` command, by graft_integrity_gate's own `php ...` call
  php() {
    echo 'PHP Deprecated:  something something in some/unrelated/file.php on line 1'
    command php "$@"
  }
}

@test "graft_integrity_gate HARD FAILS (never silently passes) when the operator's own php.ini writes noise to stdout ahead of the driver's real NDJSON" {
  local f="$BATS_TEST_TMPDIR/noisy-php.xml"
  _wxr_wrap '<item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item>' > "$f"
  _stub_php_with_stdout_noise
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not return valid NDJSON"* ]] || false
  # NOT the old accidental failure mode (MINOR-1): a leak message naming a
  # post_type that was never actually in the file, or raw `jq: error`
  # text with no context.
  [[ "$output" != *"outside the manifest allowlist"* ]] || false
}
