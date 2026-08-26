# tests/unit/test_graft_import_completeness.bats — graft_verify_import_completeness
# (issue #53). wordpress-importer INSERTS, never updates: an item it reports
# as "already exists" is skipped with no wp_import_insert_post fired at all
# (verified live against the shipped 0.9.5 — see the function's own header
# comment in lib/graft.sh for the exact source read and why the two
# "complete the map instead" avenues issue #53 names do not exist there
# either). This cross-references the WXR this run staged for import against
# id-map.tsv (written by the mapping mu-plugin) and must fail the run when
# an item never made it across.
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

# --- helpers ---------------------------------------------------------------

_write_wxr() {
  # _write_wxr <file> <id:type> [<id:type> ...]
  local file="$1"; shift
  {
    printf '<rss><channel><wp:wxr_version>1.2</wp:wxr_version>\n'
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

@test "graft_verify_import_completeness passes when every non-attachment item landed in id-map.tsv" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page" "102:page"
  printf '101\t5001\tpage\n102\t5002\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir"
  [ "$status" -eq 0 ]
}

@test "graft_verify_import_completeness passes when there are zero non-attachment items to check (nothing staged)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  run graft_verify_import_completeness "$run_dir"
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
  run graft_verify_import_completeness "$run_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2"* ]] || false
  [[ "$output" == *"page#102"* ]] || false
}

@test "graft_verify_import_completeness FAILS when id-map.tsv does not exist at all yet every expected item is missing" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page"
  [ ! -e "${run_dir}/id-map.tsv" ]
  run graft_verify_import_completeness "$run_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 1"* ]] || false
}

@test "graft_verify_import_completeness reports the CORRECT count when several items are missing, not just one" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page" "102:page" "103:post" "104:post"
  printf '101\t5001\tpage\n103\t5003\tpost\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir"
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
  run graft_verify_import_completeness "$run_dir"
  [ "$status" -eq 0 ]
}

@test "graft_verify_import_completeness ignores an attachment ROW in id-map.tsv when checking for a genuinely skipped page (must not accidentally satisfy it)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "101:page"
  # A coincidental attachment row sharing the SAME old_id number must never
  # be read as satisfying post 101's own expectation.
  printf '101\t9999\tattachment\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"page#101"* ]] || false
}

@test "graft_verify_import_completeness ignores a term ROW in id-map.tsv when checking for a genuinely skipped post (different id space, must not satisfy it)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.xml" "200:page"
  printf '200\t9\tterm:category\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"page#200"* ]] || false
}

# --- multi-file WXR export (design doc / graft_import_wxr's own comment:
# `wp export` can split a large site across multiple WXR files) -----------

@test "graft_verify_import_completeness aggregates expected items across multiple WXR files" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.000.xml" "101:page"
  _write_wxr "${run_dir}/export/export.001.xml" "102:page"
  printf '101\t5001\tpage\n102\t5002\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir"
  [ "$status" -eq 0 ]
}

@test "graft_verify_import_completeness catches a skip in the SECOND of several WXR files" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  _write_wxr "${run_dir}/export/export.000.xml" "101:page"
  _write_wxr "${run_dir}/export/export.001.xml" "102:page"
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir"
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
  run graft_verify_import_completeness "$run_dir"
  [ "$status" -eq 0 ]
}

# --- CDATA tolerance, matching graft_integrity_gate's own defense-in-depth -

@test "graft_verify_import_completeness also parses CDATA-wrapped wp:post_id/wp:post_type, if ever encountered" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  cat > "${run_dir}/export/export.xml" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
<item>
<wp:post_id><![CDATA[303]]></wp:post_id>
<wp:post_type><![CDATA[page]]></wp:post_type>
</item>
</channel></rss>
EOF
  printf '303\t5303\tpage\n' > "${run_dir}/id-map.tsv"
  run graft_verify_import_completeness "$run_dir"
  [ "$status" -eq 0 ]
}
