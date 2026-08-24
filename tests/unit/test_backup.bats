# tests/unit/test_backup.bats — pure/near-pure functions in lib/backup.sh:
# backup_checksum (design doc §6.3, review finding A5), backup_wp_cmd_literal
# (used only decoratively in restore.sh's header comment), and the two
# artifact-integrity checks (backup_verify_db_export/backup_verify_wp_content
# — Marcel's nightshift mandate: verify a backup genuinely looks usable
# before declaring it good, not just "the command exited 0").
setup() {
  load '../../lib/core.sh'
  # lib/inventory.sh for sq() — backup_generate_restore_script emits every
  # operator-supplied path through it, and bin/sitegraft sources inventory
  # before backup for every phase that reaches this code.
  load '../../lib/inventory.sh'
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
  [[ "$output" == *"ssh"* ]] || false
  [[ "$output" == *"user@host-b.example.com"* ]] || false
  [[ "$output" != *"wp_remote"* ]]
}

@test "backup_wp_cmd_literal builds a plain local command with no ssh for a local site" {
  unset SITE_B_SSH_HOST
  SITE_B_WP_PATH="/var/www/site-b"
  # Multi-word wrapper — exercises word-splitting of an arbitrary multi-word
  # SITE_*_WP_CMD, same shape wp_remote itself has to handle (lib/inventory.sh).
  SITE_B_WP_CMD="ddev exec --raw -p test-b -- wp"
  run backup_wp_cmd_literal b
  [[ "$output" != *"ssh"* ]] || false
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

# NIT hardening (Viktor, taken in this same PR): the previous
# `${prefix/--raw /}` only stripped the FIRST occurrence and required a
# trailing space. Real DDEV invocations never trigger this (see the
# function's own comment), but the helper is meant to be general.

@test "_backup_local_exec_prefix strips a REPEATED --raw token (hardening, not an observed real-world case)" {
  SITE_B_WP_CMD="ddev exec --raw --raw -p sitegraft-test-b -- wp"
  run _backup_local_exec_prefix b
  [ "$status" -eq 0 ]
  [[ "$output" != *"--raw"* ]] || false
  [ "$output" = "ddev exec -p sitegraft-test-b --" ]
}

@test "_backup_local_exec_prefix strips a TRAILING --raw with no following token (hardening)" {
  SITE_B_WP_CMD="ddev exec -p sitegraft-test-b --raw wp"
  run _backup_local_exec_prefix b
  [ "$status" -eq 0 ]
  [[ "$output" != *"--raw"* ]] || false
  [ "$output" = "ddev exec -p sitegraft-test-b" ]
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
  [[ "$output" != *"--raw"* ]] || false
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

# --- backup_prefix_tables_csv / backup_compute_protected_checksums ---------
# Real bug found live via the Step 5 DDEV harness, NOT caught by any earlier
# unit test (every existing wp_remote/inventory_table_prefix stub in this
# suite returns canned content regardless of the --tables= value it's
# handed): lib/manifest.sh documents that a module's declared `tables` are
# bare SUFFIXES ("fakebooking_reservations"), never a live-prefixed name
# ("wp_fakebooking_reservations") — the checksum loop needs to resolve that
# suffix to B's REAL live table name before calling `wp db export
# --tables=`, or it silently checksums empty content (a nonexistent table)
# instead of the actual protected data.

@test "backup_prefix_tables_csv joins each bare suffix with the given prefix" {
  run backup_prefix_tables_csv "wp_" "fakebooking_reservations,fakebooking_log"
  [ "$status" -eq 0 ]
  [ "$output" = "wp_fakebooking_reservations,wp_fakebooking_log" ]
}

@test "backup_prefix_tables_csv is a no-op (empty output) for an empty tables_csv" {
  run backup_prefix_tables_csv "wp_" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "backup_prefix_tables_csv skips an empty element between two commas rather than emitting a bare prefix" {
  run backup_prefix_tables_csv "wp_" "a,,b"
  [ "$output" = "wp_a,wp_b" ]
}

@test "backup_compute_protected_checksums resolves table suffixes to B's live prefix before exporting" {
  local manifest='{"protect":{"fakebooking":{"tables":["fakebooking_reservations"]}}}'
  local captured="$BATS_TEST_TMPDIR/captured-tables-arg"
  inventory_table_prefix() { echo "wp_"; }
  wp_remote() {
    local alias_lc="$1"; shift
    for a in "$@"; do
      case "$a" in
        --tables=*) printf '%s' "${a#--tables=}" > "$captured" ;;
      esac
    done
    echo "INSERT INTO t VALUES (1);"
  }
  run backup_compute_protected_checksums b "$manifest"
  [ "$status" -eq 0 ]
  [ "$(cat "$captured")" = "wp_fakebooking_reservations" ]
  run jq -e '.fakebooking | startswith("sha256:")' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "backup_compute_protected_checksums skips a module with no tables (empty --tables= is not a meaningful export)" {
  local manifest='{"protect":{"_unclaimed":{"tables":[]}}}'
  inventory_table_prefix() { echo "wp_"; }
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run backup_compute_protected_checksums b "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  run jq -e 'has("_unclaimed") | not' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "backup_compute_protected_checksums fails when B's live table prefix cannot be determined (fail closed, not open)" {
  local manifest='{"protect":{"fakebooking":{"tables":["fakebooking_reservations"]}}}'
  inventory_table_prefix() { return 1; }
  run backup_compute_protected_checksums b "$manifest"
  [ "$status" -eq 1 ]
}

# --- issue #14: exact-state restore on a wrapped-local target ---------------
# `restore` used to leave behind, on a wrapped-local B, every file a graft had
# added to wp-content: the copied theme, the copied plugins, new uploads. The
# database came back; the filesystem did not. The obstacle was never deletion
# itself but the *wipe*: `rm -rf wp-content` fails with "Device or resource
# busy" when a container sync (DDEV's Mutagen) mounts a subdirectory of it.
#
# The fix records, at backup time, a manifest of what wp-content contained,
# and removes on restore exactly the paths that manifest does not list — no
# wiping, only the removal of known additions, which is compatible with a
# directory that cannot be removed.
#
# These tests execute the wrapped-local branch FOR REAL, against real files on
# this machine, by giving it a "container wrapper" that is a genuine no-op
# passthrough (`env --`). `_backup_local_exec_prefix` derives its prefix from
# WP_CMD's documented shape, so `env -- wp` produces the prefix `env --` and
# every wrapped command the generator bakes (`<prefix> find ...`,
# `<prefix> tar ...`, `<prefix> xargs ...`) runs locally, unchanged. That makes
# the deletion path testable without a container — the thing that let it ship
# untested in the first place.

# _wrapped_fixture [restore-wrapper] — builds a live wp-content, a real backup
# of it (archive + manifest + a plausible db dump), and the generated
# restore.sh. Sets B_ROOT and RUN_DIR for the caller.
#
# The optional argument replaces the wrapper for the RESTORE side only: the
# backup is always taken through a plain `env --`, then restore.sh is
# regenerated against the given wrapper. That separation is what the shims
# below need — they model a wrapper that misbehaves when the restore lists or
# deletes on B, and a backup taken through the same misbehaving wrapper would
# simply fail at backup time (which it does, and which is tested separately),
# never reaching the code under test.
_wrapped_fixture() {
  local wrapper="env --"
  B_ROOT="$BATS_TEST_TMPDIR/site-b"
  RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "${B_ROOT}/wp-content/themes/t" "${B_ROOT}/wp-content/plugins" "${RUN_DIR}/backup"
  printf 'original\n' > "${B_ROOT}/wp-content/themes/t/style.css"
  printf 'index\n' > "${B_ROOT}/wp-content/index.php"
  # Opt-in accented file, written in NFC bytes (C3 A9), for the normalization
  # tests below. Off by default so every other test's expected path counts and
  # removal lists stay exactly as they were.
  if [ -n "${B_ROOT_EXTRA_NFC:-}" ]; then
    printf 'accented\n' > "${B_ROOT}/wp-content/themes/$(printf 'Caf\xc3\xa9.css')"
  fi

  SITE_B_SSH_HOST=""
  SITE_B_WP_PATH="$B_ROOT"
  SITE_B_WP_CMD="${wrapper} wp"

  # A stub `wp` on PATH: restore.sh's db-import step is not what these tests
  # are about (it has its own coverage above and in the DDEV harness), and no
  # real wp-cli/database exists here.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Drains stdin ONLY for `db import -`, which is the one invocation that is
  # handed a pipe. An unconditional `cat` here blocks forever on any invocation
  # that has no pipe on stdin — `db export -`, which phase_restore's
  # pre-restore snapshot runs — whenever bats hands the test a stdin that never
  # reaches EOF. Found live: the suite hung mid-run, intermittently, depending
  # on what stdin the process that started bats happened to have. Keyed off
  # argv instead, so it does not depend on that at all.
  cat > "$BATS_TEST_TMPDIR/bin/wp" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" db import "*) cat > /dev/null ;;
esac
echo "stub wp ran"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/wp"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  backup_wp_content "${RUN_DIR}/backup/b-wp-content" >/dev/null
  backup_write_wp_content_manifest "${RUN_DIR}/backup/b-wp-content" "${RUN_DIR}/backup/b-wp-content.manifest"
  _fake_dump_rows 50 | gzip > "${RUN_DIR}/backup/b-db.sql.gz"
  if [ -n "${1:-}" ]; then
    SITE_B_WP_CMD="${1} wp"
  fi
  backup_generate_restore_script "$RUN_DIR"
}

# _wrapper_shim <name> <body> — writes an executable that stands in for a
# container wrapper, so a specific misbehavior of one (swallowing output,
# dropping stdin, returning a path from somewhere else entirely) can be
# reproduced without a container.
_wrapper_shim() {
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BATS_TEST_TMPDIR/shim/$1"
  chmod +x "$BATS_TEST_TMPDIR/shim/$1"
  printf '%s' "$BATS_TEST_TMPDIR/shim/$1"
}

# --- backup_write_wp_content_manifest ---

# _manifest_fixture <name> — a B whose wp-content is <name>/wp-content, plus an
# archive dir that is a plain copy of it. The manifest is read from B (see
# backup_write_wp_content_manifest's comment for why it is not read from the
# archive), and cross-checked against the archive by entry count.
# Sets WPC (B's wp-content) in the CALLER — not printed, because a $(...)
# capture would run it in a subshell and the SITE_B_* assignments would be lost
# with it.
_manifest_fixture() {
  local d="$BATS_TEST_TMPDIR/$1"
  SITE_B_SSH_HOST=""
  SITE_B_WP_PATH="$d"
  SITE_B_WP_CMD="wp"
  WPC="${d}/wp-content"
  mkdir -p "$WPC"
}

@test "backup_write_wp_content_manifest records every path in the backup, relative and NUL-delimited" {
  _manifest_fixture b1; local wpc="$WPC"
  mkdir -p "${wpc}/themes/t"
  touch "${wpc}/themes/t/a.css"
  cp -R "${wpc}/." "$BATS_TEST_TMPDIR/src"
  run backup_write_wp_content_manifest "$BATS_TEST_TMPDIR/src" "$BATS_TEST_TMPDIR/m"
  [ "$status" -eq 0 ]
  local entries
  entries=$(tr '\0' '\n' < "$BATS_TEST_TMPDIR/m" | LC_ALL=C sort | tr '\n' '|')
  [ "$entries" = "./themes|./themes/t|./themes/t/a.css|" ]
}

@test "backup_write_wp_content_manifest keeps a filename containing a space intact (NUL-delimited, not whitespace-split)" {
  _manifest_fixture b2; local wpc="$WPC"
  touch "${wpc}/two words.css"
  cp -R "${wpc}/." "$BATS_TEST_TMPDIR/src2"
  backup_write_wp_content_manifest "$BATS_TEST_TMPDIR/src2" "$BATS_TEST_TMPDIR/m2"
  local count
  count=$(tr -dc '\0' < "$BATS_TEST_TMPDIR/m2" | wc -c | tr -d ' ')
  [ "$count" -eq 1 ]
  [ "$(tr '\0' '\n' < "$BATS_TEST_TMPDIR/m2")" = "./two words.css" ]
}

@test "backup_write_wp_content_manifest fails closed when the archived wp-content does not exist" {
  run backup_write_wp_content_manifest "$BATS_TEST_TMPDIR/no-such-dir" "$BATS_TEST_TMPDIR/m3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]] || false
  [ ! -s "$BATS_TEST_TMPDIR/m3" ]
}

# An empty manifest is the single most dangerous artifact this feature can
# produce: it means "the backup contained nothing", which on restore reads as
# "delete every file in wp-content". Refused at both ends — here at writing
# time, and again in the generated restore.sh.
@test "backup_write_wp_content_manifest refuses to write an EMPTY manifest (an empty keep-list would delete everything)" {
  _manifest_fixture b4
  mkdir -p "$BATS_TEST_TMPDIR/empty-src"
  run backup_write_wp_content_manifest "$BATS_TEST_TMPDIR/empty-src" "$BATS_TEST_TMPDIR/m4"
  [ "$status" -eq 1 ]
  [ ! -s "$BATS_TEST_TMPDIR/m4" ]
}

@test "backup_write_wp_content_manifest writes nothing under --dry-run and still succeeds" {
  mkdir -p "$BATS_TEST_TMPDIR/src5/themes"
  touch "$BATS_TEST_TMPDIR/src5/themes/a.css"
  SITEGRAFT_DRY_RUN=1 run backup_write_wp_content_manifest "$BATS_TEST_TMPDIR/src5" "$BATS_TEST_TMPDIR/m5"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/m5" ]
}

@test "backup_write_wp_content_manifest is owner-only (it lists a real site's file tree)" {
  _manifest_fixture b6; local wpc="$WPC"
  touch "${wpc}/a"
  cp -R "${wpc}/." "$BATS_TEST_TMPDIR/src6"
  backup_write_wp_content_manifest "$BATS_TEST_TMPDIR/src6" "$BATS_TEST_TMPDIR/m6"
  local mode
  mode=$(stat -c '%a' "$BATS_TEST_TMPDIR/m6" 2>/dev/null || stat -f '%Lp' "$BATS_TEST_TMPDIR/m6" 2>/dev/null)
  [ "$mode" = "600" ]
}

# --- the generated restore.sh says what it provides ---

@test "the generated restore.sh states its own restore semantics at RUN time, not only in the backup log (issue #14)" {
  _wrapped_fixture
  run "${RUN_DIR}/restore.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore semantics:"* ]] || false
  [[ "$output" == *"exact-state"* ]] || false
}

@test "the generated ssh-remote restore.sh also states its semantics and still uses rsync --delete" {
  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh-sem"
  mkdir -p "$run_dir"
  backup_generate_restore_script "$run_dir"
  run grep -c 'RESTORE_SEMANTICS=' "${run_dir}/restore.sh"
  [ "$output" = "1" ]
  run grep -c 'rsync -avz --delete' "${run_dir}/restore.sh"
  [ "$output" = "1" ]
}

# --- the acceptance criterion of issue #14 ---

@test "the generated wrapped-local restore.sh removes files added to wp-content since the backup (issue #14 acceptance)" {
  _wrapped_fixture
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  mkdir -p "${B_ROOT}/wp-content/plugins/grafted-plugin"
  printf 'x\n' > "${B_ROOT}/wp-content/plugins/grafted-plugin/main.php"
  printf 'mutated\n' > "${B_ROOT}/wp-content/themes/t/style.css"

  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 0 ]
  # the additions are gone ...
  [ ! -e "${B_ROOT}/wp-content/themes/GRAFTED.css" ]
  [ ! -e "${B_ROOT}/wp-content/plugins/grafted-plugin" ]
  # ... the overwrite still happened ...
  [ "$(cat "${B_ROOT}/wp-content/themes/t/style.css")" = "original" ]
  # ... and nothing the backup contained was removed.
  [ -f "${B_ROOT}/wp-content/index.php" ]
  [ -d "${B_ROOT}/wp-content/plugins" ]
}

@test "the generated wrapped-local restore.sh LISTS what it will remove before removing it" {
  _wrapped_fixture
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"will be REMOVED"* ]] || false
  [[ "$output" == *"GRAFTED.css"* ]] || false
}

@test "the generated wrapped-local restore.sh never wipes wp-content itself (the un-removable-mount constraint)" {
  _wrapped_fixture
  run grep -E "rm -rf '?${B_ROOT}/wp-content'?( |$)" "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
}

@test "the generated wrapped-local restore.sh removes added paths whose names contain spaces, quotes and glob characters" {
  _wrapped_fixture
  touch "${B_ROOT}/wp-content/themes/a file with spaces & 'quotes'.css"
  touch "${B_ROOT}/wp-content/themes/*.css"
  touch "${B_ROOT}/wp-content/themes/-dash-leading.css"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 0 ]
  [ ! -e "${B_ROOT}/wp-content/themes/a file with spaces & 'quotes'.css" ]
  [ ! -e "${B_ROOT}/wp-content/themes/*.css" ]
  [ ! -e "${B_ROOT}/wp-content/themes/-dash-leading.css" ]
  [ -f "${B_ROOT}/wp-content/themes/t/style.css" ]
}

# The real danger of this issue: code that deletes, driven by a list of paths.
# An added symlink is removed as a symlink — the thing it points at, outside
# wp-content, is never followed and never touched.
@test "the generated wrapped-local restore.sh removes an added symlink without following it out of wp-content" {
  _wrapped_fixture
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  printf 'precious\n' > "$BATS_TEST_TMPDIR/outside/keep.txt"
  ln -s "$BATS_TEST_TMPDIR/outside" "${B_ROOT}/wp-content/escape"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 0 ]
  [ ! -e "${B_ROOT}/wp-content/escape" ]
  [ -f "$BATS_TEST_TMPDIR/outside/keep.txt" ]
  [ -d "$BATS_TEST_TMPDIR/outside" ]
}

# --- --dry-run on the path that deletes ---

@test "the generated wrapped-local restore.sh --dry-run lists what it would remove and removes NOTHING" {
  _wrapped_fixture
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  printf 'mutated\n' > "${B_ROOT}/wp-content/themes/t/style.css"
  run "${RUN_DIR}/restore.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"GRAFTED.css"* ]] || false
  [ -f "${B_ROOT}/wp-content/themes/GRAFTED.css" ]
  [ "$(cat "${B_ROOT}/wp-content/themes/t/style.css")" = "mutated" ]
}

# _wrapped_profile — writes a profile matching _wrapped_fixture's site B, so
# phase_restore (which loads a profile) can be driven end-to-end against the
# same real directory.
_wrapped_profile() {
  load '../../lib/profile.sh'
  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  mkdir -p "$SITEGRAFT_PROFILES_DIR"
  cat > "${SITEGRAFT_PROFILES_DIR}/w.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="${B_ROOT}"
SITE_B_WP_CMD="env -- wp"
SITEGRAFT_STATE_DIR="${BATS_TEST_TMPDIR}/state"
EOF
}

# `sitegraft restore --dry-run` used to print the path of restore.sh and stop,
# which said nothing about what a restore would do. The removal list is the one
# thing worth previewing, so a dry run now runs restore.sh's own dry-run mode
# for real: it reads B, reports, and writes nothing.
@test "phase_restore --dry-run runs the generated restore.sh in ITS dry-run mode, so the removal list is actually previewed" {
  _wrapped_fixture
  _wrapped_profile
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  printf 'mutated\n' > "${B_ROOT}/wp-content/themes/t/style.css"
  run phase_restore --profile w --run "$RUN_DIR" --yes --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"will be REMOVED"* ]] || false
  [[ "$output" == *"GRAFTED.css"* ]] || false
  # ... and it really was a preview
  [ -f "${B_ROOT}/wp-content/themes/GRAFTED.css" ]
  [ "$(cat "${B_ROOT}/wp-content/themes/t/style.css")" = "mutated" ]
  # the pre-restore snapshot was simulated, not taken (phase_restore still
  # creates the empty directory under dry-run — pre-existing behavior — but
  # no artifact is written into it)
  [ -z "$(ls "${RUN_DIR}"/pre-restore-*/backup/b-db.sql.gz 2>/dev/null)" ]
}

# A restore.sh generated before that mode existed ignores unknown arguments —
# handing it --dry-run would run a REAL restore. It is printed, never executed.
@test "phase_restore --dry-run REFUSES to execute a restore.sh that predates dry-run support, and says why" {
  _wrapped_fixture
  _wrapped_profile
  cat > "${RUN_DIR}/restore.sh" <<'OLD'
#!/usr/bin/env bash
echo "OLD RESTORE RAN FOR REAL"
OLD
  chmod +x "${RUN_DIR}/restore.sh"
  run phase_restore --profile w --run "$RUN_DIR" --yes --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"OLD RESTORE RAN FOR REAL"* ]] || false
  [[ "$output" == *"before restore.sh grew its own --dry-run mode"* ]] || false
}

# "Even a restore has to stay reversible" has to mean reversible to the same
# standard. Without a manifest of its own, rolling the restore back on a
# wrapped-local B would (correctly) refuse to remove anything, and the safety
# net would be weaker than the thing it is a net for.
@test "phase_restore's pre-restore safety snapshot gets its own wp-content manifest" {
  _wrapped_fixture
  _wrapped_profile
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  run phase_restore --profile w --run "$RUN_DIR" --yes
  [ "$status" -eq 0 ]
  local snap
  snap=$(ls -dt "${RUN_DIR}"/pre-restore-* | head -1)
  [ -s "${snap}/backup/b-wp-content.manifest" ]
  # the snapshot describes B as it was BEFORE the restore — additions included
  tr '\0' '\n' < "${snap}/backup/b-wp-content.manifest" | grep -q 'GRAFTED.css'
  [ -x "${snap}/restore.sh" ]
  # ... and the restore it was a net for really did remove that addition
  [ ! -e "${B_ROOT}/wp-content/themes/GRAFTED.css" ]
}

@test "phase_restore --dry-run fails when the restore.sh preview itself fails (a preview that cannot run is not a green light)" {
  _wrapped_fixture
  _wrapped_profile
  rm -f "${RUN_DIR}/backup/b-wp-content.manifest"
  run phase_restore --profile w --run "$RUN_DIR" --yes --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest"* ]] || false
}

# --- fail closed: no manifest, no deletion, and no silent downgrade ---

@test "the generated wrapped-local restore.sh REFUSES to restore at all when the manifest is missing (no silent overwrite-only)" {
  _wrapped_fixture
  rm -f "${RUN_DIR}/backup/b-wp-content.manifest"
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  printf 'mutated\n' > "${B_ROOT}/wp-content/themes/t/style.css"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  # the refusal is its own diagnosis, not bash tripping over a missing file
  [[ "$output" == *"has no wp-content manifest"* ]] || false
  [[ "$output" == *"quietly downgrading to overwrite-only"* ]] || false
  # it did not quietly fall back to overwriting either
  [ "$(cat "${B_ROOT}/wp-content/themes/t/style.css")" = "mutated" ]
  [ -f "${B_ROOT}/wp-content/themes/GRAFTED.css" ]
}

@test "the generated wrapped-local restore.sh REFUSES when the manifest is empty (an empty keep-list must never mean 'delete everything')" {
  _wrapped_fixture
  : > "${RUN_DIR}/backup/b-wp-content.manifest"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest"*"is empty"* ]] || false
  # the whole point: an unguarded empty manifest deletes every file in wp-content
  [ -f "${B_ROOT}/wp-content/index.php" ]
  [ -f "${B_ROOT}/wp-content/themes/t/style.css" ]
}

@test "the generated wrapped-local restore.sh REFUSES when the manifest is unreadable" {
  _wrapped_fixture
  chmod 000 "${RUN_DIR}/backup/b-wp-content.manifest"
  run "${RUN_DIR}/restore.sh"
  local st="$status" out="$output"
  chmod 600 "${RUN_DIR}/backup/b-wp-content.manifest"
  [ "$st" -ne 0 ]
  [[ "$out" == *"is not readable"* ]] || false
}

@test "the generated wrapped-local restore.sh REFUSES when the manifest holds a path that escapes wp-content" {
  _wrapped_fixture
  printf './themes\0../../../etc\0' > "${RUN_DIR}/backup/b-wp-content.manifest"
  printf 'mutated\n' > "${B_ROOT}/wp-content/themes/t/style.css"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"safe relative path"* ]] || false
  [ "$(cat "${B_ROOT}/wp-content/themes/t/style.css")" = "mutated" ]
}

@test "the generated wrapped-local restore.sh REFUSES when the manifest holds an absolute path" {
  _wrapped_fixture
  printf './themes\0/etc/passwd\0' > "${RUN_DIR}/backup/b-wp-content.manifest"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"safe relative path"* ]] || false
}

# --- fail closed: a listing that cannot be trusted is not "nothing to do" ---

@test "the generated wrapped-local restore.sh REFUSES when listing B's wp-content comes back empty (could-not-verify is not 'nothing to remove')" {
  local shim
  shim=$(_wrapper_shim silentfind 'if [ "$1" = "find" ]; then exit 0; fi
exec "$@"')
  _wrapped_fixture "$shim"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"zero entries"* ]] || false
}

@test "the generated wrapped-local restore.sh REFUSES when listing B returns a path outside wp-content" {
  local shim
  shim=$(_wrapper_shim evilfind 'if [ "$1" = "find" ]; then printf "%s\0" /etc/passwd; exit 0; fi
exec "$@"')
  _wrapped_fixture "$shim"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside"* ]] || false
  [ -f /etc/passwd ]
}

# A newline in a filename is legal and rare. The set difference below is
# line-oriented, so such a path cannot be told apart from two paths — and two
# paths that match nothing in the manifest are two extra deletions. Refusing
# the whole listing is the only honest answer; guessing is how this kind of
# code removes the wrong thing.
@test "the generated wrapped-local restore.sh REFUSES rather than guess when a real filename contains a newline" {
  _wrapped_fixture
  local weird="${B_ROOT}/wp-content/themes/new"$'\n'"line.css"
  touch "$weird"
  printf 'mutated\n' > "${B_ROOT}/wp-content/themes/t/style.css"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe path"* ]] || false
  [[ "$output" == *"newline"* ]] || false
  # nothing removed, nothing overwritten
  [ -e "$weird" ]
  [ "$(cat "${B_ROOT}/wp-content/themes/t/style.css")" = "mutated" ]
}

@test "the generated wrapped-local restore.sh REFUSES when listing B returns a path with a '..' component" {
  local shim
  shim=$(_wrapper_shim dotdotfind 'if [ "$1" = "find" ]; then printf "%s\0" "$2/../../escape"; exit 0; fi
exec "$@"')
  _wrapped_fixture "$shim"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe path"* ]] || false
}

# --- never report a deletion that did not happen ---
# The exact shape of the worst bug this codebase has already hit twice: a
# wrapper that reports success while silently swallowing what it was given
# (`ddev exec --raw` dropping piped stdin). A removal command that deletes
# nothing and exits 0 must not be reported as an exact-state restore.
@test "the generated wrapped-local restore.sh FAILS LOUDLY when the wrapper swallows the removal list and deletes nothing" {
  local shim
  shim=$(_wrapper_shim nostdin 'if [ "$1" = "xargs" ]; then exec "$@" < /dev/null; fi
exec "$@"')
  _wrapped_fixture "$shim"
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"still present"* ]] || false
  [ -f "${B_ROOT}/wp-content/themes/GRAFTED.css" ]
}

@test "the generated wrapped-local restore.sh FAILS LOUDLY when the removal command itself errors" {
  local shim
  shim=$(_wrapper_shim failingrm 'if [ "$1" = "xargs" ]; then exit 7; fi
exec "$@"')
  _wrapped_fixture "$shim"
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]] || false
}

@test "the generated wrapped-local restore.sh reports 'nothing will be removed' (and succeeds) when B has no extra file" {
  _wrapped_fixture
  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing will be removed"* ]] || false
  [ -f "${B_ROOT}/wp-content/index.php" ]
}

@test "the generated restore.sh stays self-contained: the prune logic adds no sitegraft function or lib reference" {
  _wrapped_fixture
  run grep -Ei 'wp_remote|sitegraft_|backup_checksum|backup_write_wp_content_manifest|phase_backup|phase_restore|^[[:space:]]*\.[[:space:]]+.*lib/|^[[:space:]]*source[[:space:]]+.*lib/' "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
}

# --- fail closed: a manifest that cannot be believed ---
# `[ -s ]` only proves the manifest FILE is non-empty. The set difference below
# is driven by the manifest's PARSED content, and the two can disagree: a file
# holding bytes but no NUL delimiter parses to zero entries, and zero entries
# means "the backup contained nothing" — i.e. every path on B is an addition.
# The re-verification pass cannot catch this: it re-reads the same manifest, so
# it agrees with itself.

@test "the generated wrapped-local restore.sh REFUSES a manifest that holds no NUL delimiter (non-empty file, zero parsed entries)" {
  _wrapped_fixture
  # Newline-delimited instead of NUL-delimited: `[ -s ]` passes, `read -d ''`
  # yields not one entry.
  tr '\0' '\n' < "${RUN_DIR}/backup/b-wp-content.manifest" > "$BATS_TEST_TMPDIR/nl-manifest"
  cat "$BATS_TEST_TMPDIR/nl-manifest" > "${RUN_DIR}/backup/b-wp-content.manifest"
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no entries"* ]] || false
  # everything the backup contained is still there — this is the whole point
  [ -f "${B_ROOT}/wp-content/index.php" ]
  [ -f "${B_ROOT}/wp-content/themes/t/style.css" ]
  [ -d "${B_ROOT}/wp-content/plugins" ]
}

@test "the generated wrapped-local restore.sh REFUSES a manifest that does not describe the archive sitting next to it" {
  _wrapped_fixture
  # Truncated to its first entry: non-empty, NUL-delimited, every entry a safe
  # relative path — internally consistent, and describing a different archive.
  printf './themes\0' > "${RUN_DIR}/backup/b-wp-content.manifest"
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not describe"* ]] || false
  [[ "$output" == *"b-wp-content.manifest"* ]] || false
  [[ "$output" == *"b-wp-content"* ]] || false
  [ -f "${B_ROOT}/wp-content/index.php" ]
  [ -f "${B_ROOT}/wp-content/themes/t/style.css" ]
  [ -f "${B_ROOT}/wp-content/themes/GRAFTED.css" ]
}

# --- the generated script treats profile values as data, never as code ---
# Every path baked into the script's header is interpolated into an EXPANDING
# heredoc, so what lands in the file is re-parsed by bash when the script RUNS.
# A profile value is operator-supplied text (and a profile can arrive with a
# repo, or be edited by someone who is not the person running the restore),
# so it has to be emitted as a shell literal, not as bare text between quotes.

@test "a profile path containing a command substitution is baked as data, never executed by the generated restore.sh" {
  local sentinel="$BATS_TEST_TMPDIR/INJECTED"
  SITE_B_SSH_HOST=""
  SITE_B_WP_PATH="/var/www/html\$(touch ${sentinel})"
  SITE_B_WP_CMD="env -- wp"
  local run_dir="$BATS_TEST_TMPDIR/run-inject"
  mkdir -p "${run_dir}/backup"
  backup_generate_restore_script "$run_dir"
  run bash -n "${run_dir}/restore.sh"
  [ "$status" -eq 0 ]
  # It cannot complete (there is no backup here), but it must not have run the
  # substitution on its way to failing — that happens at line ~31, long before
  # the first integrity check.
  "${run_dir}/restore.sh" --dry-run >/dev/null 2>&1 || true
  [ ! -e "$sentinel" ]
}

@test "a profile path containing a backtick is baked as data, never executed by the generated restore.sh" {
  local sentinel="$BATS_TEST_TMPDIR/INJECTED_BT"
  SITE_B_SSH_HOST=""
  SITE_B_WP_PATH="/var/www/html\`touch ${sentinel}\`"
  SITE_B_WP_CMD="env -- wp"
  local run_dir="$BATS_TEST_TMPDIR/run-inject-bt"
  mkdir -p "${run_dir}/backup"
  backup_generate_restore_script "$run_dir"
  run bash -n "${run_dir}/restore.sh"
  [ "$status" -eq 0 ]
  "${run_dir}/restore.sh" --dry-run >/dev/null 2>&1 || true
  [ ! -e "$sentinel" ]
}

@test "a profile path containing an apostrophe still produces a syntactically valid restore.sh, on all three target shapes" {
  local run_dir
  # ssh-remote
  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/d'artagnan/html"
  SITE_B_WP_CMD="wp"
  run_dir="$BATS_TEST_TMPDIR/run-apos-ssh"; mkdir -p "${run_dir}/backup"
  backup_generate_restore_script "$run_dir"
  run bash -n "${run_dir}/restore.sh"
  [ "$status" -eq 0 ]
  # bare-local
  SITE_B_SSH_HOST=""
  run_dir="$BATS_TEST_TMPDIR/run-apos-bare"; mkdir -p "${run_dir}/backup"
  backup_generate_restore_script "$run_dir"
  run bash -n "${run_dir}/restore.sh"
  [ "$status" -eq 0 ]
  # wrapped-local
  SITE_B_WP_CMD="env -- wp"
  run_dir="$BATS_TEST_TMPDIR/run-apos-wrapped"; mkdir -p "${run_dir}/backup"
  backup_generate_restore_script "$run_dir"
  run bash -n "${run_dir}/restore.sh"
  [ "$status" -eq 0 ]
}

@test "backup_generate_restore_script FAILS instead of leaving behind a restore.sh that does not parse" {
  SITE_B_SSH_HOST=""
  SITE_B_WP_PATH="/var/www/b'\" ; ("
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-parsecheck"
  mkdir -p "${run_dir}/backup"
  # Stand in for a future regression in the quoting helper: sq() that hands
  # back its input unquoted. The generator must not report success while
  # leaving behind a script bash cannot even read — phase_backup goes on to
  # write backup.complete on the strength of that return code.
  sq() { printf '%s' "$1"; }
  run backup_generate_restore_script "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not parse"* ]] || false
  [ ! -e "${run_dir}/restore.sh" ]
}

# --- Unicode normalization: two byte sequences, one filename ---
# "Café.css" has two legal UTF-8 encodings: NFC (é as one code point, C3 A9)
# and NFD (e followed by a combining acute, 65 CC 81). `comm` compares bytes,
# so a name held in one form on one side and the other form on the other is two
# different paths — which, for the side that lists B, means "added since the
# backup", which means deleted.
#
# What normally settles it is the extraction itself. Measured on macOS:
#
#   $ printf a > dst/$'Caf\xc3\xa9.css'          # NFC
#   $ printf b > src/$'Cafe\xcc\x81.css'         # NFD
#   $ tar czf - -C src . | tar xzf - -C dst
#   $ ls dst | od -c   ->   C a f e 314 201 . c s s
#
# B's file is RENAMED to the archive's form. That is why the keep-set is the
# archive and why it is compared after the extraction, not before. This test
# covers the case where that does not settle it — a target that reports a name
# the extraction did not align, which is what a run dir carried to another host
# or a normalization-preserving target produces. One macOS volume cannot hold
# both forms at once (APFS is normalization-insensitive; verified before writing
# this test), so the target's listing is what has to be made to differ.
_nfc_find_shim() {
  _wrapper_shim nfcfind 'if [ "$1" = "find" ]; then
  "$@" | perl -0777 -pe "s/e\xcc\x81/\xc3\xa9/g"
  exit ${PIPESTATUS[0]}
fi
exec "$@"'
}

@test "the generated wrapped-local restore.sh REFUSES to delete when the target reports a backed-up name in a different Unicode normalization" {
  local shim; shim=$(_nfc_find_shim)
  B_ROOT_EXTRA_NFC=1
  _wrapped_fixture "$shim"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"normalization"* ]] || false
  # it names the path it could not account for
  [[ "$output" == *"Caf"* ]] || false
  # and nothing was removed
  [ -e "${B_ROOT}/wp-content/themes/$(printf 'Caf\xc3\xa9.css')" ]
  [ -f "${B_ROOT}/wp-content/index.php" ]
  [ -f "${B_ROOT}/wp-content/themes/t/style.css" ]
}

@test "an accented filename that round-trips unchanged is never mistaken for an addition" {
  B_ROOT_EXTRA_NFC=1
  _wrapped_fixture
  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing will be removed"* ]] || false
  [ -f "${B_ROOT}/wp-content/themes/$(printf 'Caf\xc3\xa9.css')" ]
}

@test "an accented filename genuinely added since the backup is still removed" {
  _wrapped_fixture
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/$(printf 'R\xc3\xa9sum\xc3\xa9.css')"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 0 ]
  [ ! -e "${B_ROOT}/wp-content/themes/$(printf 'R\xc3\xa9sum\xc3\xa9.css')" ]
  [ -f "${B_ROOT}/wp-content/themes/t/style.css" ]
}

# A directory whose name merely ENDS in ".." is legal, and is not a path that
# climbs anywhere. A substring test for ".." rejected it, and because the
# rejection aborts the whole restore, one such name on B made the restore
# impossible to run at all — fail-closed, but closed on a valid filename at the
# moment the operator needs it open.
@test "a directory legally named 'foo..' does not abort the restore" {
  _wrapped_fixture
  mkdir -p "${B_ROOT}/wp-content/themes/legacy../inner"
  printf 'x\n' > "${B_ROOT}/wp-content/themes/legacy../inner/a.css"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 0 ]
  # it is an addition, so it is removed — but as an addition, not as an abort
  [ ! -e "${B_ROOT}/wp-content/themes/legacy.." ]
  [ -f "${B_ROOT}/wp-content/themes/t/style.css" ]
}

@test "the wp-content manifest is read from B, not from the pulled archive" {
  # The archive is a tar round-trip of B, and on macOS that round-trip rewrites
  # accented filenames from NFC to NFD. A manifest taken from the archive
  # therefore describes names B does not have, which is how an accented file
  # the backup CONTAINED ended up classified as an addition and deleted.
  B_ROOT_EXTRA_NFC=1
  _wrapped_fixture
  local from_b from_archive
  from_b=$(tr '\0' '\n' < "${RUN_DIR}/backup/b-wp-content.manifest" | grep -c "$(printf 'Caf\xc3\xa9')" || true)
  from_archive=$(cd "${RUN_DIR}/backup/b-wp-content" && find . -name "$(printf 'Caf\xc3\xa9.css')" | wc -l | tr -d ' ')
  [ "$from_b" -eq 1 ]
  # (on a filesystem that does not rewrite names the two agree; the assertion
  # that matters is the first one — the manifest carries B's own bytes)
  [ -n "$from_archive" ]
}

# The removal list the operator is shown is computed before the extraction; the
# list that is actually deleted is recomputed after it. They coincide when
# nothing moved. If they do not, the operator approved one thing and a
# different thing would be deleted — so nothing is.
@test "the generated wrapped-local restore.sh REFUSES when B changes between the preview and the extraction" {
  local shim
  shim=$(_wrapper_shim racytar 'if [ "$1" = "tar" ] && [ "$2" = "xzf" ]; then
  "$@"
  touch "$5/RACE-ADDED-DURING-EXTRACTION.txt"
  exit 0
fi
exec "$@"')
  _wrapped_fixture "$shim"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not the one reported above"* ]] || false
  # nothing was removed, and the file that appeared mid-restore is still there
  # for the operator to look at
  [ -f "${B_ROOT}/wp-content/RACE-ADDED-DURING-EXTRACTION.txt" ]
  [ -f "${B_ROOT}/wp-content/index.php" ]
  [ -f "${B_ROOT}/wp-content/themes/t/style.css" ]
}
