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

  cat > "${SITEGRAFT_PROFILES_DIR}/t.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/var/www/b"
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
}

@test "phase_backup's checksum loop skips a protect module with no tables (plan bug fix, empty --tables=)" {
  phase_backup --profile t --run "$RUN_DIR"
  run jq -e '.checksums_protected_pre_graft | has("_unclaimed") | not' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
}

@test "phase_backup writes the backup dir/files and manifest.json as owner-only" {
  phase_backup --profile t --run "$RUN_DIR"
  local dir_mode db_mode manifest_mode complete_mode
  dir_mode=$(stat -f '%Lp' "${RUN_DIR}/backup" 2>/dev/null || stat -c '%a' "${RUN_DIR}/backup")
  db_mode=$(stat -f '%Lp' "${RUN_DIR}/backup/b-db.sql.gz" 2>/dev/null || stat -c '%a' "${RUN_DIR}/backup/b-db.sql.gz")
  manifest_mode=$(stat -f '%Lp' "${RUN_DIR}/manifest.json" 2>/dev/null || stat -c '%a' "${RUN_DIR}/manifest.json")
  complete_mode=$(stat -f '%Lp' "${RUN_DIR}/backup.complete" 2>/dev/null || stat -c '%a' "${RUN_DIR}/backup.complete")
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
