# tests/unit/test_backup.bats — pure/near-pure functions in lib/backup.sh:
# backup_checksum (design doc §6.3, review finding A5), backup_wp_cmd_literal
# (used only decoratively in restore.sh's header comment), and the two
# artifact-integrity checks (backup_verify_db_export/backup_verify_wp_content
# — Marcel's nightshift mandate: verify a backup genuinely looks usable
# before declaring it good, not just "the command exited 0").
setup() {
  load '../../lib/core.sh'
  load '../../lib/backup.sh'
}

@test "backup_checksum computes a stable sha256 for identical content" {
  run backup_checksum "hello world"
  [ "$status" -eq 0 ]
  local first="$output"
  run backup_checksum "hello world"
  [ "$output" = "$first" ]
}

@test "backup_checksum differs for different content" {
  run backup_checksum "hello world"
  local a="$output"
  run backup_checksum "hello world!"
  [ "$output" != "$a" ]
}

@test "backup_checksum ignores mysqldump comment lines (timestamp instability, finding A5)" {
  local dump1="INSERT INTO t VALUES (1);
-- Dump completed on 2026-08-19 10:00:00"
  local dump2="INSERT INTO t VALUES (1);
-- Dump completed on 2026-08-19 10:00:07"
  run backup_checksum "$dump1"
  local sum1="$output"
  run backup_checksum "$dump2"
  [ "$output" = "$sum1" ]
}

# Plan bug found and fixed here (not in the original plan's pseudocode):
# under `set -o pipefail` (bin/sitegraft's own mode, and the DDEV harness's),
# `grep -v` matching ZERO lines exits 1 — content that is empty or entirely
# "-- "-prefixed comment lines (a legitimate `wp db export --tables=` result
# for a genuinely empty table) would make the whole pipeline report failure
# even though shasum/awk go on to compute a perfectly valid checksum right
# after. Same guard already established in lib/plan.sh's
# _plan_apply_selection for the identical reason.
@test "backup_checksum does not fail under pipefail when content has no non-comment lines (plan bug A5b)" {
  set -o pipefail
  run backup_checksum "-- Dump completed on 2026-08-19 10:00:00"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "backup_checksum handles empty content without failing under pipefail" {
  set -o pipefail
  run backup_checksum ""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "backup_wp_cmd_literal builds a literal ssh-wrapped command for a remote site" {
  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  run backup_wp_cmd_literal b
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"user@host-b.example.com"* ]]
  [[ "$output" != *"wp_remote"* ]]
}

@test "backup_wp_cmd_literal builds a plain local command with no ssh for a local site" {
  unset SITE_B_SSH_HOST
  SITE_B_WP_PATH="/var/www/site-b"
  # Multi-word wrapper — exercises word-splitting of an arbitrary multi-word
  # SITE_*_WP_CMD, same shape wp_remote itself has to handle (lib/inventory.sh).
  SITE_B_WP_CMD="ddev exec --raw -p test-b -- wp"
  run backup_wp_cmd_literal b
  [[ "$output" != *"ssh"* ]]
  [[ "$output" == *"ddev exec"* ]]
}

@test "backup_wp_cmd_literal fails clearly (not a bash 3.2 unbound-variable crash) when WP_PATH is missing" {
  unset SITE_B_SSH_HOST SITE_B_WP_PATH SITE_B_WP_CMD
  run backup_wp_cmd_literal b
  [ "$status" -eq 1 ]
  [[ "$output" == *"SITE_B_WP_PATH"* ]]
}

# --- _backup_local_exec_prefix ---
# Bug found running the real DDEV harness (see backup_wp_content's own
# comment): a plain rsync against SITE_B_WP_PATH breaks for a wrapped-local
# site (DDEV) because that path is container-internal. This helper derives
# the wrapper's raw-exec prefix from WP_CMD's own documented shape
# (design doc §5.1: always "wp" or "<wrapper...> -- wp").

@test "_backup_local_exec_prefix returns empty for a bare local WP_CMD (no wrapper)" {
  SITE_B_WP_CMD="wp"
  run _backup_local_exec_prefix b
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_backup_local_exec_prefix returns empty when WP_CMD is unset (defaults to bare wp)" {
  unset SITE_B_WP_CMD
  run _backup_local_exec_prefix b
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_backup_local_exec_prefix strips the trailing 'wp' token AND '--raw' from a DDEV-style wrapper" {
  SITE_B_WP_CMD="ddev exec --raw -p sitegraft-test-b -- wp"
  run _backup_local_exec_prefix b
  [ "$status" -eq 0 ]
  # --raw is stripped (bug found live: it silently breaks piped stdin into
  # the container, which the tar-streaming callers of this prefix need) —
  # see this function's own comment for the reproduction.
  [ "$output" = "ddev exec -p sitegraft-test-b --" ]
  [[ "$output" != *"--raw"* ]]
}

@test "_backup_local_exec_prefix falls back to empty (no wrapper) for an unrecognized WP_CMD shape" {
  SITE_B_WP_CMD="some-custom-thing-not-ending-in-wp"
  run _backup_local_exec_prefix b
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- backup_verify_db_export ---

@test "backup_verify_db_export fails when the dump file is missing" {
  run backup_verify_db_export "$BATS_TEST_TMPDIR/nope.sql.gz" "wp_"
  [ "$status" -eq 1 ]
}

@test "backup_verify_db_export fails when the dump is suspiciously small" {
  printf 'x' | gzip > "$BATS_TEST_TMPDIR/tiny.sql.gz"
  run backup_verify_db_export "$BATS_TEST_TMPDIR/tiny.sql.gz" "wp_"
  [ "$status" -eq 1 ]
  [[ "$output" == *"suspiciously small"* ]]
}

@test "backup_verify_db_export fails when the file is not valid gzip" {
  # Padded past the size floor with junk bytes, but never gzip-compressed.
  printf 'not a gzip file at all %0200d' 0 > "$BATS_TEST_TMPDIR/bad.sql.gz"
  run backup_verify_db_export "$BATS_TEST_TMPDIR/bad.sql.gz" "wp_"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a valid gzip"* ]]
}

# _fake_dump_rows <n> — pseudo-random INSERT lines, so the fabricated dump
# below doesn't compress down under the 200-byte gzip floor the way a
# perfectly repetitive fixture (e.g. all-zero padding) would.
_fake_dump_rows() {
  local n="$1" i
  for i in $(seq 1 "$n"); do
    printf "INSERT INTO t VALUES (%d, '%s%s%s');\n" "$i" "$RANDOM" "$RANDOM" "$RANDOM"
  done
}

@test "backup_verify_db_export fails when an expected core table is missing from the dump" {
  { printf -- '-- MySQL dump\n'; printf 'CREATE TABLE `wp_options` (\n'; _fake_dump_rows 50; printf ');\n'; } \
    | gzip > "$BATS_TEST_TMPDIR/partial.sql.gz"
  run backup_verify_db_export "$BATS_TEST_TMPDIR/partial.sql.gz" "wp_"
  [ "$status" -eq 1 ]
  [[ "$output" == *"wp_posts"* ]]
}

@test "backup_verify_db_export passes for a dump that looks like a real, complete export" {
  {
    printf -- '-- MySQL dump\n'
    printf 'CREATE TABLE `wp_options` (\n'; _fake_dump_rows 50; printf ');\n'
    printf 'CREATE TABLE `wp_posts` (\n'; _fake_dump_rows 50; printf ');\n'
    printf -- '-- Dump completed on 2026-08-19 10:00:00\n'
  } | gzip > "$BATS_TEST_TMPDIR/good.sql.gz"
  run backup_verify_db_export "$BATS_TEST_TMPDIR/good.sql.gz" "wp_"
  [ "$status" -eq 0 ]
}

# --- backup_verify_wp_content ---

@test "backup_verify_wp_content fails when the directory does not exist" {
  run backup_verify_wp_content "$BATS_TEST_TMPDIR/no-such-dir"
  [ "$status" -eq 1 ]
}

@test "backup_verify_wp_content fails when the directory exists but is empty" {
  mkdir -p "$BATS_TEST_TMPDIR/empty-wp-content"
  run backup_verify_wp_content "$BATS_TEST_TMPDIR/empty-wp-content"
  [ "$status" -eq 1 ]
}

@test "backup_verify_wp_content passes when the directory has content" {
  mkdir -p "$BATS_TEST_TMPDIR/real-wp-content/themes"
  touch "$BATS_TEST_TMPDIR/real-wp-content/themes/dummy"
  run backup_verify_wp_content "$BATS_TEST_TMPDIR/real-wp-content"
  [ "$status" -eq 0 ]
}

# --- backup_generate_restore_script ---
# MAJOR-1 regression (Viktor's review, confirmed live on a real DDEV
# project): the generated db-import command used to keep SITE_B_WP_CMD's
# `--raw` flag for a wrapped-local site. `--raw` silently drops piped stdin
# into the container — reproduced live: exported a DB with a known option
# value, mutated the option, then `gunzip -c dump.sql.gz | ddev exec --raw
# -p X -- wp db import -` printed "Success: Imported from 'STDIN'." (exit 0)
# but the option was still the MUTATED value — the import ran against empty
# stdin and silently restored nothing. The same command without --raw
# correctly reverted it. A restore that reports success while restoring
# nothing is the worst failure mode this tool has.

@test "backup_generate_restore_script's wrapped-local db-import command drops --raw" {
  SITE_B_SSH_HOST=""
  SITE_B_WP_PATH="/var/www/html"
  SITE_B_WP_CMD="ddev exec --raw -p sitegraft-test-b -- wp"
  local run_dir="$BATS_TEST_TMPDIR/run-wrapped"
  mkdir -p "$run_dir"
  backup_generate_restore_script "$run_dir"
  run grep 'db import -' "${run_dir}/restore.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--raw"* ]]
  [[ "$output" == *"ddev exec -p sitegraft-test-b -- wp"* ]]
}

@test "backup_generate_restore_script's wp-content restore command (already fixed) also has no --raw, for consistency" {
  SITE_B_SSH_HOST=""
  SITE_B_WP_PATH="/var/www/html"
  SITE_B_WP_CMD="ddev exec --raw -p sitegraft-test-b -- wp"
  local run_dir="$BATS_TEST_TMPDIR/run-wrapped2"
  mkdir -p "$run_dir"
  backup_generate_restore_script "$run_dir"
  run grep -E 'tar (c|x)zf' "${run_dir}/restore.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--raw"* ]]
}

@test "backup_generate_restore_script's ssh-remote db-import command uses SITE_B_WP_CMD verbatim (no wrapper stripping applies)" {
  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh"
  mkdir -p "$run_dir"
  backup_generate_restore_script "$run_dir"
  run grep 'db import -' "${run_dir}/restore.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh 'user@host-b.example.com'"* ]]
}

@test "backup_generate_restore_script's bare-local db-import command is unaffected (no wrapper to strip)" {
  SITE_B_SSH_HOST=""
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-bare"
  mkdir -p "$run_dir"
  backup_generate_restore_script "$run_dir"
  run grep 'db import -' "${run_dir}/restore.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp --path='/var/www/site-b' db import -"* ]]
}
