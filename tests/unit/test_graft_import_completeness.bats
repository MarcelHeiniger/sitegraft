bats_require_minimum_version 1.5.0
# tests/unit/test_graft_import_completeness.bats — graft_verify_import_completeness
# (issue #53). wordpress-importer INSERTS, never updates: an item it reports
# as "already exists" is skipped with no wp_import_insert_post fired at all
# (verified live against the shipped 0.9.5 — see the function's own header
# comment in lib/graft.sh for the exact source read). Failing loudly on that
# is still correct (a real completion path exists but is deliberately not
# used yet — see lib/graft.sh's own header and issue #58 for why). This
# cross-references the WXR this run staged for import against id-map.tsv
# (written by the mapping mu-plugin) and must fail the run when an item
# never made it across.
#
# Real end-to-end tests throughout: genuine WXR file(s) on disk, the genuine
# php CLI driver (lib/php/wxr-item-ids-cli.php) — not a bash-level stub of
# it, same reasoning tests/unit/test_verify.bats's own _verify_wxr_items_
# remapped tests give for doing the same against verify-content-remap-cli.php.
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

# --- helpers ---------------------------------------------------------------

# _write_wxr <file> <id:type> [<id:type> ...] — a REAL WXR shape: every
# namespace the wp:/content:/excerpt: prefixes below actually use is
# declared, exactly like a genuine `wp export` document (and
# tests/unit/test_verify.bats's own wxr_item_xml fixture, lib/php/wxr-
# content-functions.php's own bats tests). An earlier version of this
# helper omitted the xmlns declarations entirely — harmless against the
# previous line-oriented awk scan, which never looked at namespaces at
# all, but the real XMLReader-based parser this function now calls
# resolves `wp:post_id` against its DECLARED namespace URI, not against
# the bare string "wp:post_id" — an undeclared "wp" prefix is a real
# (non-fatal, level 2) libxml namespace error, and the element's localName
# comes back as the literal "wp:post_id" with an EMPTY namespaceURI, which
# matches nothing. Verified live: every test in this file silently found
# ZERO items with the undeclared-namespace fixture, each masked by
# whichever assertion direction happened to make "found nothing" look like
# a pass (an empty "expected" set reads as "nothing to check", not "the
# parser broke").
_write_wxr() {
  local file="$1"; shift
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<rss version="2.0"\n'
    printf '  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"\n'
    printf '  xmlns:content="http://purl.org/rss/1.0/modules/content/"\n'
    printf '  xmlns:wp="http://wordpress.org/export/1.2/">\n'
    printf '<channel><wp:wxr_version>1.2</wp:wxr_version>\n'
    local pair id type
    for pair in "$@"; do
      id="${pair%%:*}"
      type="${pair##*:}"
      printf '<item>\n<title><![CDATA[Item %s]]></title>\n<wp:post_id>%s</wp:post_id>\n<wp:post_type>%s</wp:post_type>\n</item>\n' "$id" "$id" "$type"
    done
    printf '</channel></rss>\n'
  } > "$file"
}

# --- happy path --------------------------------------------------------------

@test "graft_verify_import_completeness returns 3 (not 1, not 2), without leaking a bare '/stderr' path, when sitegraft_mktemp_dir cannot create a temp dir (issue #109)" {
  # Same mechanism as lib/graft.sh's other sitegraft_mktemp_dir caller
  # (graft_integrity_gate, see tests/unit/test_graft_integrity_gate.bats'
  # sibling test): this function's own only production caller,
  # phase_graft (lib/graft.sh:3095), calls it as
  # `if graft_verify_import_completeness ...; then :; else ...; fi` --
  # not `|| return` (an earlier draft of this comment claimed that, and a
  # `sitegraft verify` caller that does not exist; corrected). Bash
  # disables errexit for a command's entire call tree while it is the
  # TESTED condition of `if`, same as the left side of `||`/`&&`, so this
  # only proves the fix if the tmp_dir assignment here checks
  # sitegraft_mktemp_dir's own exit status explicitly.
  #
  # rc=3, specifically (reviewer-mandated correction): NOT 1 (phase_graft
  # treats rc=1 as "safe to retry", clears four resumability markers, and
  # reruns graft_prune_previous_run for real -- destructive here, since
  # this failure happens before the staged WXR is ever even read) and
  # NOT 2 (phase_graft's own rc=2 message names run_dir/export
  # specifically, which this failure never reached -- misleading). See
  # this function's own header comment, and phase_graft's rc=3 branch,
  # for the full reasoning.
  #
  # Content of the staged .xml is irrelevant -- execution reaches
  # sitegraft_mktemp_dir before the file is ever parsed, as long as at
  # least one *.xml exists under run_dir/export.
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  echo 'placeholder' > "${run_dir}/export/export.xml"
  local missing_tmpdir="$BATS_TEST_TMPDIR/does-not-exist"
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo "SITEGRAFT_ROOT='${SITEGRAFT_ROOT}'"
    echo ". '${BATS_TEST_DIRNAME}/../../lib/core.sh'"
    echo ". '${BATS_TEST_DIRNAME}/../../lib/graft.sh'"
    echo "graft_verify_import_completeness '${run_dir}' 'page'"
  } > "$probe"
  TMPDIR="$missing_tmpdir" run --separate-stderr bash "$probe"
  [ "$status" -eq 3 ]
  [[ "$stderr" != *"/stderr"* ]] || false
  [[ "$output" != *"/stderr"* ]] || false
}

@test "graft_verify_import_completeness passes when every non-attachment item landed in id-map.tsv" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page" "102:page"
  printf '101\t5001\tpage\n102\t5002\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 0 ]
}

@test "graft_verify_import_completeness passes when there are zero non-attachment items to check (nothing staged, nothing selected)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  run graft_verify_import_completeness "$run_dir" ""
  [ "$status" -eq 0 ]
}

# --- the actual defect (issue #53) ------------------------------------------

@test "graft_verify_import_completeness FAILS and names the skipped item when wordpress-importer reported it already-exists (no id-map row at all)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page" "102:page"
  # Only 101 actually landed -- 102 was skipped by wordpress-importer and
  # never fired wp_import_insert_post, so the mu-plugin never logged it.
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2"* ]] || false
  [[ "$output" == *"page#102"* ]] || false
}

@test "graft_verify_import_completeness FAILS when id-map.tsv does not exist at all yet every expected item is missing" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page"
  [ ! -e "${run_dir}/id-map.tsv" ]
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 1"* ]] || false
}

@test "graft_verify_import_completeness reports the CORRECT count when several items are missing, not just one" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page" "102:page" "103:post" "104:post"
  printf '101\t5001\tpage\n103\t5003\tpost\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page,post"
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 of 4"* ]] || false
  [[ "$output" == *"page#102"* ]] || false
  [[ "$output" == *"post#104"* ]] || false
}

# --- attachment exemption (WordPress's own exporter unions attachments in,
# regardless of --post_type, and graft_import_wxr passes --skip=attachment
# deliberately -- see graft_integrity_gate's identical exemption) ----------

@test "graft_verify_import_completeness does not false-positive on attachment items the WXR always carries but wordpress-importer never inserts" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page" "999:attachment"
  # 999 (attachment) correctly has NO row here -- attachments are migrated
  # entirely outside this path (graft_import_attachments), never expected.
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 0 ]
}

@test "graft_verify_import_completeness ignores an attachment ROW in id-map.tsv when checking for a genuinely skipped page (must not accidentally satisfy it)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page"
  # A coincidental attachment row sharing the SAME old_id number must never
  # be read as satisfying post 101's own expectation.
  printf '101\t9999\tattachment\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 1 ]
  [[ "$output" == *"page#101"* ]] || false
}

@test "graft_verify_import_completeness ignores a term ROW in id-map.tsv when checking for a genuinely skipped post (different id space, must not satisfy it)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "200:page"
  printf '200\t9\tterm:category\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 1 ]
  [[ "$output" == *"page#200"* ]] || false
}

# --- nav_menu_item exemption (review, MINOR-2) ------------------------------
# process_posts() (wordpress-importer 0.9.5, ~line 782) special-cases
# nav_menu_item BEFORE the generic insert path, dispatching to
# process_menu_item() -> wp_update_nav_menu_item() instead of
# wp_insert_post() -- wp_import_insert_post never fires for one, imported or
# not, so the mu-plugin never logs a row for it regardless of success.
# Unreachable via any shipped module today (nothing declares
# nav_menu_item), but the exemption must already be correct for the day a
# menus module does.

@test "graft_verify_import_completeness does not false-positive on a nav_menu_item, which wordpress-importer never routes through wp_import_insert_post" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page" "77:nav_menu_item"
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page,nav_menu_item"
  [ "$status" -eq 0 ]
}

@test "graft_verify_import_completeness still catches a genuinely skipped page sitting next to an exempt nav_menu_item" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page" "102:page" "77:nav_menu_item"
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page,nav_menu_item"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2"* ]] || false
  [[ "$output" == *"page#102"* ]] || false
}

# --- multi-file WXR export (design doc / graft_import_wxr's own comment:
# `wp export` can split a large site across multiple WXR files) -----------

@test "graft_verify_import_completeness aggregates expected items across multiple WXR files" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.000.xml" "101:page"
  _write_wxr "${run_dir}/export/export.001.xml" "102:page"
  printf '101\t5001\tpage\n102\t5002\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 0 ]
}

@test "graft_verify_import_completeness catches a skip in the SECOND of several WXR files" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.000.xml" "101:page"
  _write_wxr "${run_dir}/export/export.001.xml" "102:page"
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 1 ]
  [[ "$output" == *"page#102"* ]] || false
}

# --- dry-run: nothing meaningful to check (graft_export_wxr never wrote a
# real file under --dry-run in the first place — see graft_import_attachments'
# own dry-run comment for the identical reasoning) --------------------------

@test "graft_verify_import_completeness is a no-op under --dry-run, even against a run_dir with no export/ directory at all" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  [ ! -d "${run_dir}/export" ]
  SITEGRAFT_DRY_RUN=1
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 0 ]
}

# --- CDATA tolerance -- and the exact BLOCKER-1(a) shape the previous awk
# scan could not tell apart from a real, structural <wp:post_type> ----------

@test "graft_verify_import_completeness also parses CDATA-wrapped wp:post_id/wp:post_type, if ever encountered" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  cat > "${run_dir}/export/export.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item>
<wp:post_id><![CDATA[303]]></wp:post_id>
<wp:post_type><![CDATA[page]]></wp:post_type>
</item>
</channel></rss>
EOF
  printf '303\t5303\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 0 ]
}

# BLOCKER-1(a) (review): a real page whose OWN post_content happens to
# contain the literal text "<wp:post_type>attachment</wp:post_type>" (a
# plausible real case -- content describing or copy-pasted from another
# WXR export) must NOT be read as an attachment and exempted. The previous
# awk scan assigned `type` unconditionally on any line matching
# `/<wp:post_type>/`, wherever in the file that line sat, last write wins --
# this exact fixture flipped a real unmapped page into the "already
# handled, nothing to check" bucket. The real parser resolves an <item>'s
# OWN direct <wp:post_type> child by namespace, never text sitting inside a
# DIFFERENT element's CDATA body, so this must still be caught as missing.
@test "graft_verify_import_completeness is not fooled by a literal <wp:post_type>attachment</wp:post_type> string inside an item's own post_content (BLOCKER-1a)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  cat > "${run_dir}/export/export.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item>
<title><![CDATA[Item 102]]></title>
<content:encoded><![CDATA[See how a WXR item looks: <item><wp:post_id>1</wp:post_id><wp:post_type>attachment</wp:post_type></item>]]></content:encoded>
<wp:post_id>102</wp:post_id>
<wp:post_type>page</wp:post_type>
</item>
</channel></rss>
EOF
  # 102 was skipped for real (no id-map row) -- the gate must still catch
  # it as a missing "page", never read the CDATA-embedded text above as
  # this item's real type.
  : > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 1"* ]] || false
  [[ "$output" == *"page#102"* ]] || false
}

# BLOCKER-1(b) (review): wp:post_id/wp:post_type each split across MULTIPLE
# lines (open tag, value, close tag each their own line) -- unreachable by
# the previous line-oriented awk, which matched a whole value against a
# single line. Real document structure, not line layout, drives the real
# parser.
@test "graft_verify_import_completeness parses wp:post_id/wp:post_type whose open tag, value, and close tag each sit on their own line (BLOCKER-1b)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  cat > "${run_dir}/export/export.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item>
<wp:post_id>
102
</wp:post_id>
<wp:post_type>
page
</wp:post_type>
</item>
</channel></rss>
EOF
  : > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 1"* ]] || false
  [[ "$output" == *"page#102"* ]] || false
}

# BLOCKER-2 (review): an item's OWN wp:post_id and wp:post_type sharing the
# SAME physical line as each other -- a real shape wp-cli's own exporter
# produces routinely. The previous awk's four rules all matched/gsub'd
# against the WHOLE line ($0): a line containing BOTH tags fired every
# rule, and each gsub only strips ITS OWN tag pair, leaving the OTHER
# item's raw markup sitting inside the "cleaned" value -- id and type both
# came out as garbled XML fragments instead of "101" / "page". Structural
# parsing has no such failure mode: an <item>'s own children are read from
# its own subtree by namespace, never by what else shares its line. Two
# items are used here (one landed, one skipped) specifically so a
# regression back to the awk's failure mode would show up as a WRONG
# missing-count/name, not merely as "the file still parses".
@test "graft_verify_import_completeness correctly parses an item whose own post_id/post_type tags share one physical line (BLOCKER-2)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  cat > "${run_dir}/export/export.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item>
<wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type>
</item>
<item>
<wp:post_id>102</wp:post_id><wp:post_type>page</wp:post_type>
</item>
</channel></rss>
EOF
  # 101 landed for real; 102 was skipped -- must report exactly "1 of 2",
  # naming page#102 by its real, structurally-parsed value, never a
  # garbled fragment of either tag's own markup.
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2"* ]] || false
  [[ "$output" == *"page#102"* ]] || false
  # Never a raw XML fragment standing in for a name -- the previous awk's
  # failure mode on this exact shape printed something containing "<item>"
  # or "<wp:" in the sample instead of a clean "type#id" pair.
  [[ "$output" != *"<item>"* ]] || false
  [[ "$output" != *"<wp:"* ]] || false
}

# --- fails CLOSED, never open (review, BLOCKER-1's remaining manifestations) -

# Both HARD FAILS below now return 2, not 1 (review, BLOCKER-B): a missing
# or unparseable staged export is NOT the same failure as issue #53's own
# "wordpress-importer skipped a real, present item" (still 1 -- see the
# tests above). phase_graft's own call site treats the two differently --
# rc=1 clears resumability markers and invites a retry (prune + reimport
# fixes it); rc=2 must not, because neither prune nor reimport can
# regenerate a missing/corrupt local file, and retrying anyway would
# delete B's already-migrated content for nothing while never actually
# fixing what's wrong. See graft_verify_import_completeness's own header
# for the full three-valued contract, and
# tests/unit/test_graft_phase_wiring.bats for the phase_graft-level
# acceptance test proving rc=2 leaves every marker untouched.

@test "graft_verify_import_completeness returns 2 (NOT retryable) when post_types are selected but export/ has no .xml file at all (BLOCKER-1c / BLOCKER-B)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  # export/ exists but is genuinely empty -- an interrupted run resumed
  # past a step that never actually produced its file, or the file was
  # removed from underneath this run. Must not read as "nothing to check".
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 2 ]
  [[ "$output" == *"page"* ]] || false
}

@test "graft_verify_import_completeness returns 2 (NOT retryable) when a listed WXR file is unreadable/malformed, never silently reads it as zero items" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  printf 'this is not xml at all' > "${run_dir}/export/export.xml"
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 2 ]
}

@test "graft_verify_import_completeness returns 2 (NOT retryable) when ONE of several WXR files fails to parse, even if the others are fine" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.000.xml" "101:page"
  printf 'not xml' > "${run_dir}/export/export.001.xml"
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 2 ]
}

# --- BLOCKER-A (review, issue #70 -- FIXED, see below) ---------------------
#
# lib/php/wxr-content-functions.php's own streaming reader
# (_sitegraft_stream_wxr_reader) used to silently drop the SECOND of two
# sibling <item> elements when there was NO intervening whitespace/text
# node between them (`</item><item>` with literally nothing between): its
# `XMLReader::next()` positioned the cursor ON that next sibling, but the
# outer `while(true){ read(); ... }` loop then called `read()` again on
# its NEXT iteration, advancing PAST it instead of processing it. This was
# exactly BLOCKER-1's own failure shape (a real, present, skipped item
# silently exempted), reopened by the very parser this fix-pack switched
# to in order to CLOSE BLOCKER-1 in the first place. Confirmed live,
# root-caused while building this fix-pack's own test fixtures, filed as
# issue #70 and fixed on a separate branch (PR #71, merged, rebased onto
# here) -- this test went green on its own the moment that landed, with no
# change needed here; kept exactly as originally written as the
# regression guard for it. See lib/php/wxr-item-ids-cli.php's own header
# for the fuller history.
@test "graft_verify_import_completeness catches a skipped item even when it is a sibling <item> with NO whitespace before it (BLOCKER-A / issue #70)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  cat > "${run_dir}/export/export.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version><item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item><item><wp:post_id>102</wp:post_id><wp:post_type>page</wp:post_type></item></channel></rss>
EOF
  # 101 landed for real; 102 was skipped -- must report "1 of 2", naming
  # page#102, exactly like the BLOCKER-2 test above. Today (pre-#70) the
  # second <item> (102) is never even seen by the parser, so this run
  # reports a false, silent PASS instead.
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2"* ]] || false
  [[ "$output" == *"page#102"* ]] || false
}

# --- issue #73: weighed for this caller too (review — "pèse-le pour ---
# l'autre appelant"). The same underlying gap BLOCKER-1a/1b/1c/BLOCKER-2
# exist to close for THIS function's own purpose (a real, present item
# must never be silently unaccounted for) applies just as much to a
# malformed item as to a garbled one: a WXR item missing wp:post_id
# cannot be correlated against id-map.tsv at all, so it would otherwise
# simply vanish from "expected" -- indistinguishable from "nothing to
# check". Closed at the shared driver level (lib/php/wxr-item-ids-cli.php,
# issue #73), which now refuses to succeed when it saw more <item>s than
# it could parse as well-formed -- this function's own existing `rc != 0`
# handling (already `return 2`, "this run's own data is not trustworthy
# right now") already treats that the same as any other unparseable
# export, no new bash-level logic needed here.

@test "graft_verify_import_completeness returns 2 when the staged WXR carries a malformed item (no wp:post_id) alongside a real one (issue #73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  cat > "${run_dir}/export/export.xml" <<'EOF'
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
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not parse the staged WXR export"* ]] || false
}

# --- reviewer's own BLOCKER: same php-output-trust problem as
# graft_integrity_gate's own equivalent test, applied to this function.

_stub_php_with_stdout_noise() {
  # shellcheck disable=SC2317  # invoked indirectly, as the `php` command, by graft_verify_import_completeness's own `php ...` call
  php() {
    echo 'PHP Deprecated:  something something in some/unrelated/file.php on line 1'
    command php "$@"
  }
}

@test "graft_verify_import_completeness returns 2 (never a silent PASS) when the operator's own php.ini writes noise to stdout ahead of the driver's real NDJSON" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page" "102:page"
  # Only 101 landed -- if the noise bug silently degraded this to
  # "nothing was expected", this would incorrectly PASS instead of
  # catching the genuine skip of 102.
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  _stub_php_with_stdout_noise
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 2 ]
  [[ "$output" == *"did not return valid NDJSON"* ]] || false
}

# --- foreign-file message clarity (review — the DDEV harness's own bug,
# not sitegraft's): a test fixture (assertion (e), tests/integration/
# ddev-harness.sh) once wrote a mutated WXR straight into a real run_dir's
# export/ and never cleaned it up; the NEXT graft/verify against that
# same run_dir failed with a message that read as "your export got
# corrupted" when the real cause was "a file that was never part of this
# run's own output is sitting in export/ now". Fixed on the harness side
# (it no longer writes there); this covers the message itself naming that
# possibility, so an operator hitting the identical shape by hand (a
# manually-copied WXR, a leftover from an earlier experiment against the
# same run_dir) is not misled toward "restore from backup" when "remove
# the extra file" is the actual, cheaper fix.
@test "graft_verify_import_completeness's failure message names the foreign-file possibility, not just 'corrupt'" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  # A real, legitimate export this run staged...
  _write_wxr "${run_dir}/export/export.xml" "101:page"
  # ...plus a SECOND file this run never produced -- exactly the shape a
  # hand-copied WXR, or a leftover test artifact, would take.
  cat > "${run_dir}/export/leftover-from-somewhere-else.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_type>injected_evil_type</wp:post_type></item>
</channel></rss>
EOF
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir" "page"
  [ "$status" -eq 2 ]
  [[ "$output" == *"leftover-from-somewhere-else.xml"* ]] || false
  [[ "$output" == *"if anything else was ever added"* ]] || false
}
