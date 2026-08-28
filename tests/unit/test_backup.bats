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

  # Opt-in: wp-content/uploads is ALREADY a symlink to a real, populated
  # directory BEFORE the backup ever runs -- the issue's own motivating case
  # (media on a separate volume, an NFS mount, a CDN-synced directory), not a
  # symlink introduced later by a botched graft. The archive therefore
  # captures "uploads" as a symlink entry, never as a directory tree (neither
  # tar creation side dereferences it). Off by default, same reasoning as
  # B_ROOT_EXTRA_NFC above.
  if [ -n "${B_ROOT_SYMLINK_AT_BACKUP:-}" ]; then
    mkdir -p "$BATS_TEST_TMPDIR/media-volume"
    printf 'media\n' > "$BATS_TEST_TMPDIR/media-volume/photo.jpg"
    ln -s "$BATS_TEST_TMPDIR/media-volume" "${B_ROOT}/wp-content/uploads"
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
  # Opt-in, and separate from B_ROOT_EXTRA_NFC: only the REFUSAL test wants the
  # archive pinned. The positive round-trip test needs the archive exactly as
  # the pull produced it, because on macOS that is what makes it agree with B
  # after the extraction.
  #
  # AFTER the manifest, on purpose: the manifest must still be able to carry
  # B's own bytes, which is what proves it is read from B rather than from the
  # archive (see the "read from B, not from the pulled archive" test, and
  # mutant M14).
  [ -n "${ARCHIVE_FORCE_NFC:-}" ] && _force_archive_nfc "${RUN_DIR}/backup/b-wp-content"
  _fake_dump_rows 50 | gzip > "${RUN_DIR}/backup/b-db.sql.gz"
  if [ -n "${1:-}" ]; then
    SITE_B_WP_CMD="${1} wp"
  fi
  backup_generate_restore_script "$RUN_DIR"
}

# _force_archive_nfc <archive-dir> — pins the archive's accented entry to NFC,
# whatever the pull produced.
#
# Without this the normalization test was macOS-only by construction: it
# borrowed bsdtar's NFC->NFD rewrite to manufacture the divergence it was
# supposed to be testing. GNU tar does not rewrite anything, so on Linux the
# archive and B agreed, nothing diverged, the restore succeeded, and the test
# that asserts a REFUSAL went red in CI. A test must build its own premise.
#
# Written by deleting both spellings and re-creating the NFC one: on a
# normalization-INSENSITIVE volume (APFS) the two names resolve to the same
# entry, so the second `rm` is a no-op and the fresh `printf` is what fixes the
# stored bytes. A bare `mv` between two equivalent names is not reliable there.
_force_archive_nfc() {
  local dir="$1" nfc nfd content
  nfc=$(printf 'Caf\xc3\xa9.css')
  nfd=$(printf 'Cafe\xcc\x81.css')
  content=$(cat "${dir}/themes/${nfd}" 2>/dev/null || cat "${dir}/themes/${nfc}" 2>/dev/null || echo accented)
  rm -f "${dir}/themes/${nfd}" "${dir}/themes/${nfc}"
  printf '%s\n' "$content" > "${dir}/themes/${nfc}"
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
  # The wp-content restore command itself, not RESTORE_SEMANTICS (which also
  # mentions "rsync --delete" in its own descriptive text).
  run grep -c "if ! { ssh .* && rsync .*--delete" "${run_dir}/restore.sh"
  [ "$output" = "1" ]
}

# --- issue #44: the ssh-remote rsync destination is a SECOND shell's problem
# ---
# rsync builds its OWN remote command line out of the `host:path` destination
# and hands that to ssh, on the far end, after this script has already run —
# a construction step sq() (this file's local-quoting helper) never reaches.
# See backup_generate_restore_script's own comment on the `rsync ...
# host:path` line for the full history: `--protect-args` was the FIRST
# version of this fix and was reverted after review measured it live against
# a real openrsync SERVER — it makes the transfer fail outright (refused by
# restricted shells too, per `man rsync`, which is exactly what a hardened
# backup account's forced command often is). The fix that shipped instead
# depends on nothing but the LOCAL rsync's own default arg-escaping (GNU
# rsync >= 3.2.4), which needs nothing from B's rsync at all — the actual
# rsync invocation below is therefore IDENTICAL, flag for flag, to the
# bare-local branch's; only the generated script's runtime PREFLIGHT CHECK
# differs by branch (see the NEEDS_RSYNC_ARG_ESCAPING tests below).

# issue #44, second review round: the capability probe alone (does this
# rsync KNOW about --old-args?) is not enough -- `RSYNC_OLD_ARGS=1` in the
# environment (an operator's profile, a wrapper script; rsync's own
# COMPATIBILITY docs explicitly suggest exporting it for old scripts) makes
# a fully-capable rsync default to the OLD, unescaped behavior even with no
# flag on the command line, while the probe still passes (the binary still
# recognizes --old-args). `--no-old-args` on the actual invocation forces
# escaping regardless of that variable, closing the gap the probe alone
# left open.
@test "the generated ssh-remote restore.sh's wp-content rsync command forces escaping with --no-old-args, not just a --protect-args-shaped flag (issue #44)" {
  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh-rsync-shape"
  mkdir -p "$run_dir"
  backup_generate_restore_script "$run_dir"
  run grep -c -- "if ! { ssh .* && rsync -avz --no-old-args --delete " "${run_dir}/restore.sh"
  [ "$output" = "1" ]
  # No --protect-args, no bare -s, anywhere on that command line.
  run grep -E "if ! \{ ssh .*rsync" "${run_dir}/restore.sh"
  [[ "$output" != *"--protect-args"* ]] || false
  [[ "$output" != *" -s "* ]] || false
}

# A REAL end-to-end exercise, not just a text/shape assertion: a loopback
# `ssh` that hands its command to a real local shell (real ssh's own
# documented behavior for a multi-word command), a REAL local `rsync`
# (whatever GNU rsync this machine has -- the project's own documented
# dependency), and a target path under $BATS_TEST_TMPDIR that mkdir can
# actually create -- so the `mkdir && rsync` chain reaches the rsync half
# instead of failing earlier on an unwritable path like `/var/www` and
# never invoking rsync at all (a masking bug an earlier draft of this exact
# test had -- caught only by first confirming the mutant it was meant to
# catch stayed green).
@test "the generated ssh-remote restore.sh's --no-old-args forces escaping even when RSYNC_OLD_ARGS=1 is exported (issue #44, closes the capability-probe bypass)" {
  local sentinel="$BATS_TEST_TMPDIR/INJECTED_ENVBYPASS"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'EOS'
#!/usr/bin/env bash
host="$1"; shift
exec sh -c "$*"
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  SITE_B_SSH_HOST="fakehost"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/b-target/\$(touch ${sentinel})html"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh-envbypass"
  _ssh_remote_real_backup_fixture "$run_dir"
  backup_generate_restore_script "$run_dir"

  RSYNC_OLD_ARGS=1 run "${run_dir}/restore.sh"
  # The mkdir half of the chain must actually have succeeded (proving rsync
  # was reached, not short-circuited past by a failed mkdir) ...
  [ -d "$BATS_TEST_TMPDIR/b-target" ]
  # ... and the injected command must not have run.
  [ ! -e "$sentinel" ]
}

@test "the generated ssh-remote restore.sh alone sets NEEDS_RSYNC_ARG_ESCAPING=1 (only its wp-content step goes through a second shell)" {
  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh-needsflag"
  mkdir -p "$run_dir"
  backup_generate_restore_script "$run_dir"
  # Anchored to the actual assignment line -- the check's own comment,
  # right below it, also says "NEEDS_RSYNC_ARG_ESCAPING=1" in prose.
  run grep -c '^NEEDS_RSYNC_ARG_ESCAPING=1$' "${run_dir}/restore.sh"
  [ "$output" = "1" ]

  SITE_B_SSH_HOST=""
  local run_dir2="$BATS_TEST_TMPDIR/run-bare-needsflag"
  mkdir -p "$run_dir2"
  backup_generate_restore_script "$run_dir2"
  run grep -c '^NEEDS_RSYNC_ARG_ESCAPING=0$' "${run_dir2}/restore.sh"
  [ "$output" = "1" ]

  SITE_B_WP_CMD="env -- wp"
  local run_dir3="$BATS_TEST_TMPDIR/run-wrapped-needsflag"
  mkdir -p "$run_dir3"
  backup_generate_restore_script "$run_dir3"
  run grep -c '^NEEDS_RSYNC_ARG_ESCAPING=0$' "${run_dir3}/restore.sh"
  [ "$output" = "1" ]
}

# Behavioral, not just textual: a fake `ssh` that reproduces real ssh's own
# documented behavior (join every argument after the host with a single
# space, hand the result to the remote user's shell) proves the two `ssh`
# invocations on this branch (mkdir, and the piped db import) are already
# safe — sq() applied twice (see backup_generate_restore_script's header
# comment) quotes the path for THAT shell, not just the local one. This is
# the "measure it, don't assume it" check issue #44 asks for on the ssh
# invocations specifically, mutation-provable: point SITE_B_WP_PATH at a
# command substitution, and prove it is never executed.
_ssh_remote_loopback_shim() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'EOS'
#!/usr/bin/env bash
# Real ssh's own behavior for a command given as multiple argv words: join
# them with a single space and execute the result through the remote user's
# shell. This does the identical join and runs it through a LOCAL shell
# instead of a network hop -- enough to prove whether a value baked into the
# joined string is treated as data or as syntax, without a real remote host.
shift # drop the host argument; this stand-in never actually connects
exec sh -c "$*"
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# _extract_if_body <file> <pattern> — pulls just the command chain out of a
# generated "if ! { <chain>; }; then" line, stripping the `if`/`then`
# scaffolding around it. Evaluating the WHOLE line (scaffolding included) is
# not valid on its own -- it is half of a compound statement with no
# matching `fi` -- so `eval` on it fails to PARSE and never runs any of the
# embedded commands at all. That failure looks identical to "the injection
# didn't fire," which is exactly backwards: it hides the very thing these
# tests exist to catch instead of proving it closed. (Found by mutation-
# testing these tests themselves: neutering the inner sq() call on
# SITE_B_WP_PATH — the exact regression issue #44 asks to guard against —
# did not turn the naive version of this test red.)
_extract_if_body() {
  local file="$1" pattern="$2" line
  line=$(grep "$pattern" "$file")
  line="${line#if ! { }"
  # The suffix pattern must be quoted: unquoted, its own literal "}" closes
  # the "${line%...}" expansion early and the rest leaks through as text —
  # found the same way as the bug above, by mutation-testing this helper.
  line="${line%"; }; then"}"
  printf '%s' "$line"
}

@test "the generated ssh-remote restore.sh's mkdir command is data, not syntax, for a SITE_B_WP_PATH holding a command substitution (issue #44)" {
  _ssh_remote_loopback_shim
  local sentinel="$BATS_TEST_TMPDIR/INJECTED_MKDIR"
  SITE_B_SSH_HOST="fakehost"
  SITE_B_WP_PATH="/var/www/\$(touch ${sentinel})html"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh-mkdir-inject"
  mkdir -p "${run_dir}/backup"
  backup_generate_restore_script "$run_dir"
  local chain; chain=$(_extract_if_body "${run_dir}/restore.sh" '^if ! { ssh')
  [ -n "$chain" ]
  # Isolate the ssh/mkdir half from the ` && rsync ...` half that follows it
  # — only the ssh half is under test here (the rsync half is protected by a
  # different mechanism entirely — see the preflight-check tests below).
  local mkdir_part="${chain%% && rsync*}"
  [[ "$mkdir_part" == ssh* ]] || false
  eval "$mkdir_part" || true
  [ ! -e "$sentinel" ]
}

@test "the generated ssh-remote restore.sh's db-import command is data, not syntax, for a SITE_B_WP_PATH holding a command substitution (issue #44)" {
  _ssh_remote_loopback_shim
  local sentinel="$BATS_TEST_TMPDIR/INJECTED_DBIMPORT"
  SITE_B_SSH_HOST="fakehost"
  SITE_B_WP_PATH="/var/www/\$(touch ${sentinel})html"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh-dbimport-inject"
  mkdir -p "${run_dir}/backup"
  echo fake-dump > "${run_dir}/backup/b-db.sql.gz"
  backup_generate_restore_script "$run_dir"
  local chain; chain=$(_extract_if_body "${run_dir}/restore.sh" '^if ! { gunzip')
  [ -n "$chain" ]
  [[ "$chain" == gunzip* ]] || false
  # `wp` is unresolvable through the loopback shim -- that is fine, the only
  # thing under test is whether the substitution ran on the way to failing.
  eval "$chain" || true
  [ ! -e "$sentinel" ]
}

# --- issue #44: the local-rsync capability preflight check ---
# GNU rsync has escaped a remote destination by DEFAULT since 3.2.4 (April
# 2022) — not since 3.0.0, which only added `--protect-args` as something an
# operator had to opt INTO. `--old-args` is the probe used below: it is the
# explicit opt-OUT of that default, so a rsync that recognizes it is, by
# construction, one that escapes by default when the flag is absent (which
# is exactly how the real restore command runs). Confirmed live against
# macOS's own /usr/bin/rsync (openrsync, a different codebase, the only
# rsync macOS 15+ ships): it recognizes neither `--old-args` nor default
# escaping, and performs no escaping at all.
#
# A fixture with a REAL-shaped backup (valid gzip past the size floor, a
# non-empty wp-content dir) is required for these — the check runs AFTER
# restore.sh's own integrity check and, since the --dry-run fix below, also
# after the --dry-run early exit, so a fixture that fails integrity first
# would never reach it and every assertion here would pass for the wrong
# reason (the same trap the mkdir/db-import tests above already document).
_ssh_remote_real_backup_fixture() {
  local run_dir="$1"
  mkdir -p "${run_dir}/backup/b-wp-content"
  touch "${run_dir}/backup/b-wp-content/index.php"
  # Past the 200-byte floor after compression -- repetitive content
  # compresses too well to clear it, so this needs real entropy.
  head -c 2000 /dev/urandom | base64 | gzip > "${run_dir}/backup/b-db.sql.gz"
}

_rsync_stub_rejecting_old_args() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Stands in for openrsync: rejects the flag exactly like the real one does
  # (confirmed live against macOS's own /usr/bin/rsync).
  cat > "$BATS_TEST_TMPDIR/bin/rsync" <<'EOS'
#!/usr/bin/env bash
case " $* " in
  *" --old-args "*) echo "rsync: unrecognized option \`--old-args'" >&2; exit 1 ;;
esac
exit 0
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/rsync"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "the generated ssh-remote restore.sh refuses, with a clear reason, when the local rsync does not default-escape (issue #44)" {
  _rsync_stub_rejecting_old_args

  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh-no-escaping"
  _ssh_remote_real_backup_fixture "$run_dir"
  backup_generate_restore_script "$run_dir"

  run "${run_dir}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"openrsync"* ]] || false
  [[ "$output" == *"3.2.4"* ]] || false
  [[ "$output" == *"Nothing was restored"* ]] || false
  # It must NOT claim --protect-args is the requirement -- that flag was
  # reverted; the requirement now is default escaping.
  [[ "$output" != *"--protect-args"* ]] || false
}

@test "the generated ssh-remote restore.sh --dry-run does NOT refuse on a local rsync that lacks default-escaping (issue #44 NIT: preview must survive this check)" {
  _rsync_stub_rejecting_old_args

  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh-dryrun-noescaping"
  _ssh_remote_real_backup_fixture "$run_dir"
  backup_generate_restore_script "$run_dir"

  run "${run_dir}/restore.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]] || false
  [[ "$output" != *"openrsync"* ]] || false
}

@test "the generated ssh-remote restore.sh does NOT refuse when the local rsync default-escapes (issue #44, prove the check can pass too)" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Stands in for a real GNU rsync >= 3.2.4: accepts --old-args.
  cat > "$BATS_TEST_TMPDIR/bin/rsync" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/rsync"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh-yes-escaping"
  _ssh_remote_real_backup_fixture "$run_dir"
  backup_generate_restore_script "$run_dir"

  run "${run_dir}/restore.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"openrsync"* ]] || false
}

@test "the generated ssh-remote restore.sh gives a DISTINCT message when rsync is not installed at all, vs. installed-but-incapable (issue #44)" {
  mkdir -p "$BATS_TEST_TMPDIR/bin-norsync"
  # An otherwise-normal PATH with no `rsync` binary anywhere on it.
  for cmd in bash gzip gunzip wc cat grep sort comm mktemp xargs find tr sh mkdir rm ssh cmp awk sed ls printf; do
    p=$(command -v "$cmd" 2>/dev/null) || continue
    ln -sf "$p" "$BATS_TEST_TMPDIR/bin-norsync/$cmd"
  done

  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  local run_dir="$BATS_TEST_TMPDIR/run-ssh-norsync"
  _ssh_remote_real_backup_fixture "$run_dir"
  backup_generate_restore_script "$run_dir"

  PATH="$BATS_TEST_TMPDIR/bin-norsync" run "${run_dir}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found on PATH"* ]] || false
  # Must not claim it looked at a version/capability it never got to check.
  [[ "$output" != *"does not do that"* ]] || false
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

# --- issue #35: refuse to extract THROUGH a symlinked wp-content entry ------
# The sibling of the test immediately above, and the other half of the same
# operation: that test is about the PRUNE side (rm -rf on an added symlink
# removes the link, never its target — already safe via find's own default
# -P). This is about the EXTRACT side, which had no equivalent guard: if a
# path this backup's archive covers (e.g. "themes", standing in for the real
# report's "uploads") is a symlink on B instead of a real directory, writing
# the archive on top of it can land files at the symlink's target instead of
# inside wp-content.
#
# This is a real vulnerability on this tool's ACTUAL archive shape, measured
# across three extractors, not a defensive guard against a case that never
# occurs. Every archive here is built by a plain recursive `tar c` over a real
# pulled-down directory tree (never `--no-recursion`) — the only shape
# backup_generate_restore_script ever produces — fed through the exact
# `tar czf - -C src . | tar xzf - -C dst` pipeline it bakes, against a
# destination directory symlink:
#
#   GNU tar 1.30 / 1.34 / 1.35      replaces the symlink with a real dir — safe
#   bsdtar 3.5.3 (macOS)            replaces the symlink with a real dir — safe
#   busybox tar 1.36 / 1.37 / 1.38  writes straight through the symlink — UNSAFE
#
# busybox tar ignores the archive's own directory entry for the symlinked
# name (verified present) and follows the symlink anyway — archives built by
# EITHER gtar or bsdtar reproduce it the same way once busybox is the one
# extracting. Reachable today: a bare `alpine` or `nginx:alpine` container
# ships busybox tar; `wordpress:cli` and the `*-fpm-alpine` WordPress/PHP
# images install GNU tar 1.35 instead, so they are unaffected as of this
# writing. Which extractor a given restore target actually has is exactly
# what the generated script cannot know (see backup_generate_restore_script's
# own comment on why no flag can be relied on), so the fix does not lean on
# "safe on the tars I checked" as a property of the target — it detects the
# unsafe target state before extracting, the same "read, decide, refuse"
# shape the manifest checks above already use, rather than trusting whichever
# tar happens to be on PATH.
@test "the generated wrapped-local restore.sh refuses to extract through a symlinked wp-content entry, naming it" {
  _wrapped_fixture
  rm -rf "${B_ROOT}/wp-content/themes"
  mkdir -p "$BATS_TEST_TMPDIR/outside-themes"
  printf 'should never appear\n' > "$BATS_TEST_TMPDIR/outside-themes/leak.txt"
  ln -s "$BATS_TEST_TMPDIR/outside-themes" "${B_ROOT}/wp-content/themes"

  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 1 ]
  # names the link
  [[ "$output" == *"${B_ROOT}/wp-content/themes"* ]] || false
  # the symlink itself is untouched -- refused, not "fixed" by deleting it
  [ -L "${B_ROOT}/wp-content/themes" ]
  # nothing from the archive landed through it
  [ ! -e "$BATS_TEST_TMPDIR/outside-themes/style.css" ]
  [ ! -d "$BATS_TEST_TMPDIR/outside-themes/t" ]
  [ "$(ls "$BATS_TEST_TMPDIR/outside-themes")" = "leak.txt" ]
  # nothing else ran either -- refused before the first byte was written
  [[ "$output" != *"stub wp ran"* ]] || false
  [ ! -e "${B_ROOT}/wp-content/index.php.sitegraft-tmp" ]
}

# The check runs during the preflight pass, which also drives --dry-run's
# preview -- a preview must not stay silent about a restore that would in
# fact be refused.
@test "the generated wrapped-local restore.sh --dry-run also refuses (and reports) a symlinked wp-content entry" {
  _wrapped_fixture
  rm -rf "${B_ROOT}/wp-content/themes"
  mkdir -p "$BATS_TEST_TMPDIR/outside-themes-dry"
  ln -s "$BATS_TEST_TMPDIR/outside-themes-dry" "${B_ROOT}/wp-content/themes"

  run "${RUN_DIR}/restore.sh" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"${B_ROOT}/wp-content/themes"* ]] || false
  [ -L "${B_ROOT}/wp-content/themes" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/outside-themes-dry")" ]
}

# Discrimination, not just detection: a symlink on B that this backup's
# archive never covers is inert (tar has no entry by that name to extract),
# and must not block an otherwise-ordinary restore. Without this, the guard
# above would not be proof it distinguishes the real hazard from an unrelated
# symlink -- it would just be refusing on sight of any symlink anywhere.
@test "the generated wrapped-local restore.sh does NOT refuse for a symlink the archive never covers" {
  _wrapped_fixture
  mkdir -p "$BATS_TEST_TMPDIR/unrelated-target"
  ln -s "$BATS_TEST_TMPDIR/unrelated-target" "${B_ROOT}/wp-content/not-in-the-backup"

  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "${B_ROOT}/wp-content/themes/t/style.css")" = "original" ]
}

# Bug found by review: `[ -d "${WP_CONTENT_DIR}/${rel#./}" ]` follows
# symlinks. If wp-content/uploads was ALREADY a symlink at BACKUP time --
# the issue's own motivating case, media on a separate volume, an NFS mount,
# or a CDN-synced directory -- the archive holds "uploads" as a symlink
# entry, not a directory. On the machine that generates and runs this
# restore.sh (this test, and potentially the real orchestrator if it can
# resolve the same path), a bare `-d` on that archived symlink can still
# return true whenever its target happens to exist and be a directory --
# which it always does here, by construction. That wrongly classifies
# "uploads" as an archive DIRECTORY, matches it against B's live symlink at
# the same name, and refuses a restore that was never unsafe: the archive
# holds no files under "uploads" at all, so there is nothing for extraction
# to write through it.
@test "the generated wrapped-local restore.sh does NOT refuse when wp-content/uploads was ALREADY a symlink at backup time (legitimate separate-volume setup)" {
  B_ROOT_SYMLINK_AT_BACKUP=1 _wrapped_fixture
  # B is unchanged since the backup: "uploads" is still the very same symlink.
  [ -L "${B_ROOT}/wp-content/uploads" ]

  run "${RUN_DIR}/restore.sh"
  [ "$status" -eq 0 ]
  [ -L "${B_ROOT}/wp-content/uploads" ]
  [ "$(cat "${B_ROOT}/wp-content/themes/t/style.css")" = "original" ]
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
  # Only misbehaves for the PLAIN listing call (_sg_list_live, no -type l) --
  # the symlink-only listing (_sg_list_live_symlinks, issue #35) is let
  # through untouched, so this still exercises _sg_scan_prune's own guard
  # rather than being silently absorbed by the newer, narrower one.
  shim=$(_wrapper_shim silentfind 'if [ "$1" = "find" ]; then
  case " $* " in
    *" -type l "*) exec "$@" ;;
  esac
  exit 0
fi
exec "$@"')
  _wrapped_fixture "$shim"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"zero entries"* ]] || false
}

@test "the generated wrapped-local restore.sh REFUSES when listing B returns a path outside wp-content" {
  local shim
  # Same discrimination as silentfind above -- let the -type l (symlink)
  # listing through untouched, only poison the plain listing.
  shim=$(_wrapper_shim evilfind 'if [ "$1" = "find" ]; then
  case " $* " in
    *" -type l "*) exec "$@" ;;
  esac
  printf "%s\0" /etc/passwd
  exit 0
fi
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
  # Same discrimination as silentfind/evilfind above.
  shim=$(_wrapper_shim dotdotfind 'if [ "$1" = "find" ]; then
  case " $* " in
    *" -type l "*) exec "$@" ;;
  esac
  printf "%s\0" "$2/../../escape"
  exit 0
fi
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
# or a normalization-preserving target produces.
#
# The divergence is built by this test, not borrowed from the platform. That
# distinction cost a red CI: an earlier version pinned only the target's side
# and let `tar` supply the other, which works on macOS (bsdtar rewrites
# NFC->NFD during the pull) and is a no-op on Linux (GNU tar rewrites nothing),
# so on Linux both sides agreed, the restore succeeded, and a test asserting a
# REFUSAL failed. Now both ends are pinned: _force_archive_nfc holds the
# archive at NFC on either platform, and the shim below rewrites the target's
# listing to NFD. One macOS volume cannot hold both forms at once (APFS is
# normalization-insensitive; verified), so the target's LISTING — not its
# filesystem — is what has to be made to differ.
_nfd_find_shim() {
  _wrapper_shim nfdfind 'if [ "$1" = "find" ]; then
  "$@" | perl -0777 -pe "s/\xc3\xa9/e\xcc\x81/g"
  exit ${PIPESTATUS[0]}
fi
exec "$@"'
}

@test "the generated wrapped-local restore.sh REFUSES to delete when the target reports a backed-up name in a different Unicode normalization" {
  local shim; shim=$(_nfd_find_shim)
  B_ROOT_EXTRA_NFC=1
  ARCHIVE_FORCE_NFC=1
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

# issue #45: naming the paths is not the same as telling the operator what to
# do about it. These assert on the two things the issue's acceptance actually
# asks for, distinct from the test above (which only proves the refusal
# fires and nothing is deleted): the situation is NAMED in plain terms, and a
# concrete manual remedy is STATED, not just implied by the word
# "normalization" appearing somewhere in the output.
@test "the normalization refusal names the situation in plain terms (issue #45)" {
  local shim; shim=$(_nfd_find_shim)
  B_ROOT_EXTRA_NFC=1
  ARCHIVE_FORCE_NFC=1
  _wrapped_fixture "$shim"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup and the target disagree on Unicode normalization"* ]] || false
}

@test "the normalization refusal states a manual remedy, not just the missing paths (issue #45)" {
  local shim; shim=$(_nfd_find_shim)
  B_ROOT_EXTRA_NFC=1
  ARCHIVE_FORCE_NFC=1
  _wrapped_fixture "$shim"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rename"* ]] || false
  [[ "$output" == *"re-run"* ]] || false
}

@test "the normalization refusal points at the written decision on why this isn't detected/normalized earlier (issue #45)" {
  local shim; shim=$(_nfd_find_shim)
  B_ROOT_EXTRA_NFC=1
  ARCHIVE_FORCE_NFC=1
  _wrapped_fixture "$shim"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"docs/decisions/0009-restore-unicode-normalization-refusal.md"* ]] || false
  [ -f "${BATS_TEST_DIRNAME}/../../docs/decisions/0009-restore-unicode-normalization-refusal.md" ]
}

@test "the normalization refusal names the escape hatch for a normalization-INSENSITIVE target (issue #45 review: the stated remedy must not loop forever on APFS)" {
  local shim; shim=$(_nfd_find_shim)
  B_ROOT_EXTRA_NFC=1
  ARCHIVE_FORCE_NFC=1
  _wrapped_fixture "$shim"
  run "${RUN_DIR}/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-op"* ]] || false
  [[ "$output" == *"apply it by hand outside sitegraft"* ]] || false
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

# The keep-set coming back empty must never read as "keep nothing". Reaching it
# needs a directory that can be LISTED but not ENTERED — `ls -A` needs the read
# bit, `cd` needs the execute bit, and mode 400 has one and not the other. So
# the integrity check upstream is satisfied and the archive listing is still
# empty. The `cd` fails inside a process substitution, whose status neither
# `set -e` nor `pipefail` observes, so this guard is the only thing left.
@test "the generated wrapped-local restore.sh REFUSES when the archive cannot be entered and lists no entries" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: mode bits do not restrict root, so the archive stays listable"
  fi
  _wrapped_fixture
  printf 'grafted\n' > "${B_ROOT}/wp-content/themes/GRAFTED.css"
  chmod 400 "${RUN_DIR}/backup/b-wp-content"
  run "${RUN_DIR}/restore.sh"
  local st="$status" out="$output"
  chmod 700 "${RUN_DIR}/backup/b-wp-content"
  [ "$st" -ne 0 ]
  [[ "$out" == *"listed no entries"* ]] || false
  # nothing removed — least of all the files the backup contains
  [ -f "${B_ROOT}/wp-content/index.php" ]
  [ -f "${B_ROOT}/wp-content/themes/t/style.css" ]
  [ -f "${B_ROOT}/wp-content/themes/GRAFTED.css" ]
}

# --- backup_content_checksum_of_row / backup_compute_content_checksums -----
# issue #52 / ADR 0008's "Required regardless" list: the pre-graft
# content-checksum snapshot lib/verify.sh's guard 2
# (verify_migrated_content_changed_from_pregraft) compares a post-graft
# re-read against. Captured HERE, in backup — not in graft, not in verify —
# because backup is the one phase graft's own precondition guard
# (`[ -f "${run_dir}/backup.complete" ]`, phase_graft in lib/graft.sh)
# GUARANTEES has already run, completely, before graft's first write to B.
# See backup_compute_content_checksums' own header comment in lib/backup.sh
# for the full reasoning.

@test "backup_content_checksum_of_row is stable for identical content+excerpt" {
  local row='{"ID":5,"post_content":"hello","post_excerpt":"world"}'
  run backup_content_checksum_of_row "$row"
  [ "$status" -eq 0 ]
  local first="$output"
  run backup_content_checksum_of_row "$row"
  [ "$output" = "$first" ]
}

@test "backup_content_checksum_of_row does not collapse a content/excerpt boundary shift into the same checksum" {
  # "ab"+"c" must never checksum the same as "a"+"bc" -- a plain string
  # concatenation would have exactly this collision; this function encodes
  # both fields as a JSON pair first (lib/backup.sh's own comment explains
  # why), which is boundary-safe by construction.
  run backup_content_checksum_of_row '{"ID":1,"post_content":"ab","post_excerpt":"c"}'
  local sum1="$output"
  run backup_content_checksum_of_row '{"ID":1,"post_content":"a","post_excerpt":"bc"}'
  local sum2="$output"
  [ "$sum1" != "$sum2" ]
}

@test "backup_content_checksum_of_row changes when post_content changes" {
  run backup_content_checksum_of_row '{"ID":1,"post_content":"one","post_excerpt":""}'
  local sum1="$output"
  run backup_content_checksum_of_row '{"ID":1,"post_content":"two","post_excerpt":""}'
  local sum2="$output"
  [ "$sum1" != "$sum2" ]
}

@test "backup_content_checksum_of_row treats a missing post_excerpt key as an empty string, not an error" {
  run backup_content_checksum_of_row '{"ID":1,"post_content":"x"}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "backup_compute_content_checksums returns an empty object when no post_types are selected for migration" {
  local manifest='{"migrate":{}}'
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run backup_compute_content_checksums b "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "backup_compute_content_checksums excludes attachment from the post_type scope (media is verified by file sync, not content equality)" {
  local manifest='{"migrate":{"core-wp":{"post_types":["page","attachment"]}}}'
  local captured="$BATS_TEST_TMPDIR/captured-post-type"
  wp_remote() {
    local alias_lc="$1"; shift
    for a in "$@"; do
      case "$a" in
        --post_type=*) printf '%s' "${a#--post_type=}" > "$captured" ;;
      esac
    done
    echo '[]'
  }
  run backup_compute_content_checksums b "$manifest"
  [ "$status" -eq 0 ]
  [ "$(cat "$captured")" = "page" ]
}

@test "backup_compute_content_checksums keys the result by post ID with a sha256:-prefixed checksum" {
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  wp_remote() { echo '[{"ID":16,"post_content":"hello","post_excerpt":""},{"ID":17,"post_content":"world","post_excerpt":""}]'; }
  run backup_compute_content_checksums b "$manifest"
  [ "$status" -eq 0 ]
  run jq -e '(.["16"] | startswith("sha256:")) and (.["17"] | startswith("sha256:")) and (.["16"] != .["17"])' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "backup_compute_content_checksums fails closed when B's post list cannot be read" {
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  wp_remote() { return 1; }
  run backup_compute_content_checksums b "$manifest"
  [ "$status" -eq 1 ]
}

@test "backup_compute_content_checksums fails closed on a non-JSON reply from B" {
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  wp_remote() { echo "not json"; }
  run backup_compute_content_checksums b "$manifest"
  [ "$status" -eq 1 ]
}
