# tests/unit/test_phase_backup.bats — phase_backup's own control flow (guard
# clauses, verification-before-declaring-good, checksum computation, dry-run
# semantics, permissions). Stubs backup_db_export/backup_wp_content/wp_remote/
# inventory_table_prefix so this stays a fast, real-execution unit test
# rather than needing a live wp-cli/DDEV install — same convention as
# tests/unit/test_phase_scan.bats. The DDEV integration harness is the
# separate, real end-to-end proof (tests/integration/ddev-harness.sh).
setup() {
  load '../../lib/core.sh'
  load '../../lib/profile.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'

  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  export SITEGRAFT_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$SITEGRAFT_PROFILES_DIR" "$SITEGRAFT_STATE_DIR"

  # A real directory for B: the wp-content manifest is read from B's own
  # filesystem, not from the pulled archive (see
  # backup_write_wp_content_manifest's comment), and it is cross-checked
  # against the archive by entry count — so B has to hold exactly what the
  # backup_wp_content stub below pulls.
  B_ROOT="$BATS_TEST_TMPDIR/site-b"
  mkdir -p "${B_ROOT}/wp-content/themes"
  touch "${B_ROOT}/wp-content/themes/dummy-theme.txt"

  cat > "${SITEGRAFT_PROFILES_DIR}/t.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="${B_ROOT}"
SITE_B_WP_CMD="wp"
SITEGRAFT_STATE_DIR="${SITEGRAFT_STATE_DIR}"
EOF

  RUN_DIR="${SITEGRAFT_STATE_DIR}/t-20260101T000000"
  mkdir -p "$RUN_DIR"
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "migrate": {},
  "protect": {
    "fakebooking": {"post_types": [], "tables": ["fakebooking_reservations"], "option_keys": []},
    "_unclaimed": {"post_types": [], "tables": [], "option_keys": []}
  }
}
EOF

  # Stand-ins for the two functions that actually talk to B over ssh/rsync —
  # write small, deterministic fake artifacts instead. Every other function
  # under test (phase_backup's own guard clauses, verification, checksumming,
  # permissions, dry-run branching) runs for real, unstubbed.
  #
  # Bug found by review (Viktor): the previous version of these stubs wrote
  # their fake artifact UNCONDITIONALLY, even under dry-run — the opposite of
  # what the real backup_db_export/backup_wp_content do (run_or_echo prints
  # instead of writing anything). That made the dry-run tests below
  # vacuously pass without ever exercising the real dry-run code path in
  # phase_backup, which is exactly how the MAJOR chmod/subshell-exit-status
  # bug (see lib/backup.sh's phase_backup comment) went undetected by the
  # unit suite and only surfaced on the live DDEV harness. Honoring
  # is_dry_run here closes that gap.
  backup_db_export() {
    local dest_dir="$1"
    is_dry_run && { echo "[dry-run] would export B database to ${dest_dir}/b-db.sql.gz"; return 0; }
    mkdir -p "$dest_dir"
    {
      printf -- '-- MySQL dump\n'
      printf 'CREATE TABLE `wp_options` (\n'
      local i; for i in $(seq 1 30); do printf "INSERT INTO t VALUES (%d,'%s%s');\n" "$i" "$RANDOM" "$RANDOM"; done
      printf ');\n'
      printf 'CREATE TABLE `wp_posts` (\n'
      for i in $(seq 1 30); do printf "INSERT INTO t VALUES (%d,'%s%s');\n" "$i" "$RANDOM" "$RANDOM"; done
      printf ');\n'
      # issue #99: backup_verify_db_export now requires mysqldump's own
      # completion marker, not just core-table presence — this stub stands
      # in for an export that genuinely finished, so it has to look like one.
      printf -- '-- Dump completed on 2026-08-19 10:00:00\n'
    } | gzip > "${dest_dir}/b-db.sql.gz"
  }
  backup_wp_content() {
    local dest_dir="$1"
    is_dry_run && { echo "[dry-run] would archive B wp-content to ${dest_dir}"; return 0; }
    mkdir -p "${dest_dir}/themes"
    touch "${dest_dir}/themes/dummy-theme.txt"
  }
  inventory_table_prefix() { echo "wp_"; }
  wp_remote() {
    local alias_lc="$1"; shift
    echo "INSERT INTO wp_fakebooking_reservations VALUES (1);"
  }
}

@test "phase_backup requires --profile" {
  run phase_backup --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--profile"* ]]
}

@test "phase_backup fails clearly when no run dir can be found for the profile" {
  rm -rf "$SITEGRAFT_STATE_DIR"/*
  run phase_backup --profile t
  [ "$status" -eq 1 ]
  [[ "$output" == *"scan"* ]]
}

@test "phase_backup fails clearly when the run dir has no manifest.json (plan never ran)" {
  rm -f "${RUN_DIR}/manifest.json"
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"frozen manifest"* ]]
}

@test "phase_backup refuses to run against an unfrozen manifest" {
  jq '.frozen = false' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not frozen"* ]]
}

@test "phase_backup produces a verified backup, checksums, restore.sh, and a completion marker" {
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  local backup_output="$output"
  [ -f "${RUN_DIR}/backup/b-db.sql.gz" ]
  [ -d "${RUN_DIR}/backup/b-wp-content" ]
  [ -f "${RUN_DIR}/backup.complete" ]
  [ -x "${RUN_DIR}/restore.sh" ]
  run jq -e '.checksums_protected_pre_graft.fakebooking | startswith("sha256:")' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
  [[ "$backup_output" == *"to restore this backup"* ]] || false
  # NIT (review): the success message used to say "core tables present"
  # without ever naming the completion marker, even though that marker is
  # now the load-bearing signal — exactly the false reassurance #99 itself
  # cites as the pattern to avoid.
  [[ "$backup_output" == *"completion marker present"* ]] || false
}

# issue #52 / ADR 0008's "Required regardless" list: phase_backup must also
# record the pre-graft content-checksum snapshot lib/verify.sh's content
# guards read back after graft runs — same moment, same manifest, same
# reasoning as checksums_protected_pre_graft immediately above.
@test "phase_backup records a pre-graft content-checksum snapshot keyed by post ID for the selected post_types" {
  jq '.migrate = {"core-wp": {"post_types": ["page"], "option_keys": []}}' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  wp_remote() {
    local alias_lc="$1"; shift
    for a in "$@"; do
      case "$a" in
        post) : ;;
      esac
    done
    case "$*" in
      *"post list"*) echo '[{"ID":16,"post_content":"old front page","post_excerpt":""}]' ;;
      *) echo "INSERT INTO wp_fakebooking_reservations VALUES (1);" ;;
    esac
  }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  run jq -e '.content_checksums_pre_graft["16"] | startswith("sha256:")' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
}

@test "phase_backup aborts, before completion, when the pre-graft content-checksum snapshot cannot be computed" {
  jq '.migrate = {"core-wp": {"post_types": ["page"], "option_keys": []}}' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  wp_remote() {
    case "$*" in
      *"post list"*) return 1 ;;
      *) echo "INSERT INTO wp_fakebooking_reservations VALUES (1);" ;;
    esac
  }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ ! -f "${RUN_DIR}/backup.complete" ]
}

@test "phase_backup --dry-run writes no content-checksum snapshot either" {
  jq '.migrate = {"core-wp": {"post_types": ["page"], "option_keys": []}}' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  run phase_backup --profile t --run "$RUN_DIR" --dry-run
  [ "$status" -eq 0 ]
  run jq -e 'has("content_checksums_pre_graft") | not' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
}

# issue #14: the wp-content manifest is what lets restore.sh put a
# containerized B back to exactly its pre-graft state. Without it the
# generated restore.sh refuses to remove anything at all, so a phase_backup
# that quietly stopped writing it would turn every future restore back into
# the overwrite-only behavior the issue was about — silently, and only
# visible on a real container.
@test "phase_backup records a wp-content manifest listing what the archive contains (issue #14)" {
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ -s "${RUN_DIR}/backup/b-wp-content.manifest" ]
  local entries
  entries=$(tr '\0' '\n' < "${RUN_DIR}/backup/b-wp-content.manifest" | LC_ALL=C sort | tr '\n' '|')
  [ "$entries" = "./themes|./themes/dummy-theme.txt|" ]
  local mode
  mode=$(stat -c '%a' "${RUN_DIR}/backup/b-wp-content.manifest" 2>/dev/null || stat -f '%Lp' "${RUN_DIR}/backup/b-wp-content.manifest" 2>/dev/null)
  [ "$mode" = "600" ]
}

# A backup that could not record its manifest is not a backup this tool can
# restore from on a containerized target — it must fail, not leave a
# backup.complete marker behind that `graft` will happily accept.
@test "phase_backup FAILS and writes no completion marker when the wp-content manifest cannot be recorded" {
  backup_write_wp_content_manifest() { return 1; }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -f "${RUN_DIR}/backup.complete" ]
}

@test "phase_backup FAILS when the wp-content manifest is written but comes out empty (verified, not assumed)" {
  backup_write_wp_content_manifest() { : > "$2"; return 0; }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest"* ]] || false
  [ ! -f "${RUN_DIR}/backup.complete" ]
}

@test "phase_backup --dry-run writes no wp-content manifest (a dry run must not look like a restorable backup)" {
  run phase_backup --profile t --run "$RUN_DIR" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "${RUN_DIR}/backup/b-wp-content.manifest" ]
}

@test "phase_backup's checksum loop skips a protect module with no tables (plan bug fix, empty --tables=)" {
  phase_backup --profile t --run "$RUN_DIR"
  run jq -e '.checksums_protected_pre_graft | has("_unclaimed") | not' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
}

# --- issue #97: backup_compute_protected_checksums's own internal
# `|| echo ""` used to swallow a per-table export failure and checksum it as
# empty content — indistinguishable from a table that really is empty. See
# that function's own header comment (lib/backup.sh) for the declared vs.
# `_unclaimed` split these two tests exercise.
@test "phase_backup FAILS, and writes no completion marker or checksum, when a DECLARED protect module's table export fails (issue #97)" {
  wp_remote() {
    return 1   # every wp-cli call fails, including the fakebooking db export
  }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ ! -f "${RUN_DIR}/backup.complete" ]
  [[ "$output" == *"could not compute protected-data checksums"* ]] || false
  # never wrote an empty-content checksum standing in for the read that failed
  run jq -e 'has("checksums_protected_pre_graft")' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 1 ]
}

@test "phase_backup SUCCEEDS when only an UNCLAIMED (out-of-scope) table's export fails, recording it as unreadable rather than blocking the backup (issue #97)" {
  jq '.protect._unclaimed.tables = ["wp_actionscheduler_actions"]' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  wp_remote() {
    local alias_lc="$1"; shift
    for a in "$@"; do
      case "$a" in
        --tables=wp_actionscheduler_actions) return 1 ;;
      esac
    done
    echo "INSERT INTO wp_fakebooking_reservations VALUES (1);"
  }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ -f "${RUN_DIR}/backup.complete" ]
  run jq -e '.checksums_protected_pre_graft["_unclaimed:wp_actionscheduler_actions"] == "unreadable"' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
  # the unrelated DECLARED module, whose table read fine, still gets a real checksum
  run jq -e '.checksums_protected_pre_graft.fakebooking | startswith("sha256:")' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
}

@test "phase_backup writes the backup dir/files and manifest.json as owner-only" {
  phase_backup --profile t --run "$RUN_DIR"
  local dir_mode db_mode manifest_mode complete_mode
  dir_mode=$(stat -c '%a' "${RUN_DIR}/backup" 2>/dev/null || stat -f '%Lp' "${RUN_DIR}/backup" 2>/dev/null)
  db_mode=$(stat -c '%a' "${RUN_DIR}/backup/b-db.sql.gz" 2>/dev/null || stat -f '%Lp' "${RUN_DIR}/backup/b-db.sql.gz" 2>/dev/null)
  manifest_mode=$(stat -c '%a' "${RUN_DIR}/manifest.json" 2>/dev/null || stat -f '%Lp' "${RUN_DIR}/manifest.json" 2>/dev/null)
  complete_mode=$(stat -c '%a' "${RUN_DIR}/backup.complete" 2>/dev/null || stat -f '%Lp' "${RUN_DIR}/backup.complete" 2>/dev/null)
  [ "$dir_mode" = "700" ]
  [ "$db_mode" = "600" ]
  [ "$manifest_mode" = "600" ]
  [ "$complete_mode" = "600" ]
}

@test "phase_backup aborts and does not write backup.complete when the db export fails verification" {
  backup_db_export() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    printf 'not a real gzip' > "${dest_dir}/b-db.sql.gz"
  }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ ! -f "${RUN_DIR}/backup.complete" ]
}

@test "phase_backup aborts and does not write backup.complete when wp-content archive is empty" {
  backup_wp_content() { mkdir -p "$1"; }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ ! -f "${RUN_DIR}/backup.complete" ]
}

# The cross-check that gives the wp-content pull a real downstream test, which
# it never had: backup_verify_wp_content only asks whether the archive is
# non-empty, so a PULL THAT STOPPED HALFWAY passed. With the manifest read from
# B instead of from the archive, the two listings are independent, and a
# short archive is a countable fact rather than an invisible one. It matters
# because the restore treats the archive as the keep-set: a partial archive
# restored as an exact state deletes files that were never additions.
@test "phase_backup aborts when the wp-content pull is PARTIAL (non-empty, but short of what B holds)" {
  mkdir -p "${B_ROOT}/wp-content/plugins/acss"
  touch "${B_ROOT}/wp-content/plugins/acss/acss.php"
  # the stub still pulls only the themes half
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"path(s) but the archive"* ]] || false
  [ ! -f "${RUN_DIR}/backup.complete" ]
}

@test "phase_backup --dry-run generates restore.sh but writes no completion marker or checksums" {
  run phase_backup --profile t --run "$RUN_DIR" --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "${RUN_DIR}/backup.complete" ]
  [ -f "${RUN_DIR}/restore.sh" ]
  run jq -e 'has("checksums_protected_pre_graft") | not' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"CHECK-NOT-USED"* ]]
}

@test "SITEGRAFT_DRY_RUN=1 env var is honored the same way as --dry-run" {
  SITEGRAFT_DRY_RUN=1 run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "${RUN_DIR}/backup.complete" ]
}

@test "phase_backup's generated restore.sh never references a sitegraft function (self-containment, finding A2)" {
  phase_backup --profile t --run "$RUN_DIR"
  run grep -Ei 'wp_remote|sitegraft_|backup_checksum|backup_db_export|backup_wp_content|phase_backup|phase_restore' "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
}

@test "phase_backup's generated restore.sh never sources a sitegraft lib file" {
  phase_backup --profile t --run "$RUN_DIR"
  run grep -E '^\s*\.\s+.*lib/|^\s*source\s+.*lib/' "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
}

# --- a failed pull is a failed backup, not a smaller one ---
# bash suppresses `errexit` for a compound command that is the LEFT operand of
# `||`, and phase_backup's artifact subshell is exactly that (`) || return 1`).
# So `set -e` inside it does not stop it: a failing backup_db_export or
# backup_wp_content lets execution carry on. That is not symmetric between the
# two — the db dump has real downstream checks (gzip -t, a size floor, core
# tables), wp-content has only "non-empty", so a PARTIAL pull sails through.
# And with the wp-content manifest derived from that partial copy, the restore
# no longer merely leaves things behind: it deletes files that were never
# additions.

@test "phase_backup fails, and writes no backup.complete, when the wp-content pull fails while leaving a partial copy" {
  backup_wp_content() {
    local dest_dir="$1"
    mkdir -p "${dest_dir}/themes"
    touch "${dest_dir}/themes/dummy-theme.txt"   # non-empty: passes verification
    return 1                                     # ... but the pull FAILED
  }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "${RUN_DIR}/backup.complete" ]
  # NIT (review): the backup/restore subshell used to abort silently here —
  # no sitegraft-level summary, just whatever the failing tool itself wrote
  # to stderr. An operator relying on this for the restore path deserves a
  # log line that says the subshell failed, not just raw tool output.
  [[ "$output" == *"backup failed"* ]] || false
}

@test "phase_backup fails, and writes no backup.complete, when the database export fails while leaving a plausible dump" {
  backup_db_export() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    {
      printf -- '-- MySQL dump\n'
      printf 'CREATE TABLE `wp_options` (\n'
      local i; for i in $(seq 1 30); do printf "INSERT INTO t VALUES (%d,'%s%s');\n" "$i" "$RANDOM" "$RANDOM"; done
      printf ');\n'
      printf 'CREATE TABLE `wp_posts` (\n'
      for i in $(seq 1 30); do printf "INSERT INTO t VALUES (%d,'%s%s');\n" "$i" "$RANDOM" "$RANDOM"; done
      printf ');\n'
    } | gzip > "${dest_dir}/b-db.sql.gz"
    return 1
  }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "${RUN_DIR}/backup.complete" ]
  [[ "$output" == *"backup failed"* ]] || false
}

@test "phase_backup writes no backup.complete when the restore.sh generator fails" {
  # The generator now refuses (and discards) a restore.sh that bash cannot
  # parse — see backup_generate_restore_script. That refusal only means
  # anything if phase_backup acts on it: a backup whose restore script does not
  # exist must not be marked complete, because `graft` accepts any run dir that
  # carries the marker.
  backup_generate_restore_script() { return 1; }
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "${RUN_DIR}/backup.complete" ]
}

# --- issue #99 acceptance, end to end -------------------------------------
# Everything above stubs backup_db_export/backup_wp_content (this file's own
# setup()) so phase_backup's OWN control flow can be tested fast and in
# isolation. These two tests re-load the real lib/backup.sh so the actual
# `bash -c "set -o pipefail; ..."` pipelines run for real, proving the full
# chain the issue's acceptance criteria describe end to end — not just that
# phase_backup trusts whatever exit status it's handed (already covered
# above) or that the low-level functions fail on their own in isolation
# (test_backup_pipefail.bats).
#
# `load` re-SOURCES the whole file, which restores BOTH backup_db_export
# and backup_wp_content to their real implementations, not just the one
# each test means to exercise — found live writing these: the first attempt
# left the other one real too, so it went through its OWN wrapper-prefixed
# ssh/wp invocation with no `wp` stub on PATH at all, failed for THAT
# unrelated reason before ever reaching the code path under test, and the
# test passed for the wrong reason. Each test below re-stubs the sibling
# function immediately after `load`, deliberately, so only the one function
# named in its own title runs for real.

@test "phase_backup (real backup_db_export): an export that dies mid-stream fails the backup, before completion (issue #99 acceptance)" {
  load '../../lib/backup.sh'
  backup_wp_content() {
    local dest_dir="$1"
    mkdir -p "${dest_dir}/themes"
    touch "${dest_dir}/themes/dummy-theme.txt"
  }
  # The stub dump below deliberately writes BOTH core tables the old
  # table-probe checked (options, posts) with real bulk — clears the
  # 200-byte floor, and would have satisfied the pre-issue-#99
  # backup_verify_db_export outright — then dies WITHOUT mysqldump's
  # completion footer. This is the issue's own measured shape (truncated
  # after posts, before usermeta), so a false green here would mean neither
  # the pipefail fix nor the footer-check fix is doing its job, not just
  # one of the two.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/wp" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" db export "*)
    printf -- '-- MySQL dump\n'
    printf 'CREATE TABLE `wp_options` (\n'
    for i in $(seq 1 50); do printf "INSERT INTO t VALUES (%d,'%s%s');\n" "$i" "$RANDOM" "$RANDOM"; done
    printf ');\n'
    printf 'CREATE TABLE `wp_posts` (\n'
    for i in $(seq 1 50); do printf "INSERT INTO t VALUES (%d,'%s%s');\n" "$i" "$RANDOM" "$RANDOM"; done
    printf ');\n'
    exit 1
    ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/wp"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "${RUN_DIR}/backup.complete" ]
}

@test "phase_backup (real backup_wp_content): a source-side tar that exits non-zero fails the backup, before completion, even though extraction succeeded (issue #99 acceptance)" {
  load '../../lib/backup.sh'
  backup_db_export() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    {
      printf -- '-- MySQL dump\n'
      printf 'CREATE TABLE `wp_options` (\n'
      local i; for i in $(seq 1 30); do printf "INSERT INTO t VALUES (%d,'%s%s');\n" "$i" "$RANDOM" "$RANDOM"; done
      printf ');\n'
      printf 'CREATE TABLE `wp_posts` (\n'
      for i in $(seq 1 30); do printf "INSERT INTO t VALUES (%d,'%s%s');\n" "$i" "$RANDOM" "$RANDOM"; done
      printf ');\n'
      printf -- '-- Dump completed on 2026-08-19 10:00:00\n'
    } | gzip > "${dest_dir}/b-db.sql.gz"
  }
  # backup_wp_content's OWN wrapped-local branch (tar | tar) only runs when
  # SITE_B_WP_CMD names a wrapper — setup()'s profile uses a bare "wp"
  # (bare-local, plain rsync, no pipe to break). Rewrite it to a wrapper so
  # this test actually exercises the pipe.
  cat > "${SITEGRAFT_PROFILES_DIR}/t.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="${B_ROOT}"
SITE_B_WP_CMD="env -- wp"
SITEGRAFT_STATE_DIR="${SITEGRAFT_STATE_DIR}"
EOF
  # exit 1, not an arbitrary non-zero: measured against real GNU tar
  # (1.35) as its own exit status for "file shrank/changed while being
  # read" — a complete archive, tar still reports failure. Same fixture
  # shape as test_backup_pipefail.bats's own tar stand-in.
  local real_tar; real_tar=$(command -v tar)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/tar" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "czf" ]; then
  "$real_tar" "\$@"
  exit 1
fi
exec "$real_tar" "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/tar"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run phase_backup --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "${RUN_DIR}/backup.complete" ]
}
