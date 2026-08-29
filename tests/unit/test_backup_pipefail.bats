# tests/unit/test_backup_pipefail.bats — issue #99: every `run_or_echo bash
# -c "... | ..."` in lib/backup.sh starts a CHILD bash that does NOT inherit
# bin/sitegraft's own `set -o pipefail` (verified: a child started by `bash
# -c` gets a fresh, default SHELLOPTS). Without pipefail, a pipeline's exit
# status is the LAST command's — so a producer that dies mid-stream while
# its consumer (gzip, or the second tar) still exits 0 is reported as
# success by backup_db_export/backup_wp_content, which is exactly what lets
# phase_backup write backup.complete over a truncated database export or a
# partial wp-content archive.
#
# Every test below reproduces the real failure mode end to end (a real
# stubbed producer that dies mid-stream, a real gzip/tar consumer that goes
# on to exit 0 on whatever it was handed) rather than mocking the mechanism
# under test, so each one is RED without `set -o pipefail;` at the head of
# the string handed to `bash -c` and GREEN with it.
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
}

# --- backup_db_export ---------------------------------------------------

@test "backup_db_export (local branch) fails when the wp export dies mid-stream, not swallowed by gzip's own success" {
  unset SITE_B_SSH_HOST
  SITE_B_WP_PATH="/var/www/site-b"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # A `wp` stand-in that writes a real, partial dump then dies — mysqldump's
  # own behavior when killed or erroring mid-export: whatever it had
  # buffered is flushed, then the process exits non-zero. gzip on the far
  # end of the pipe sees a clean EOF and completes normally, exit 0 — the
  # exact swallow the issue describes.
  cat > "$BATS_TEST_TMPDIR/bin/wp" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" db export "*)
    printf -- '-- MySQL dump\nCREATE TABLE `wp_options` (\n'
    exit 1
    ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/wp"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  SITE_B_WP_CMD="wp"

  run backup_db_export "$BATS_TEST_TMPDIR/backup"
  [ "$status" -ne 0 ]
}

@test "backup_db_export (ssh branch) fails when the remote export dies mid-stream, not swallowed by gzip's own success" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Minimal ssh stand-in: runs the remote command locally and propagates its
  # exit status — the same contract real ssh has for a remote command that
  # connects fine and then fails.
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
shift
bash -c "$1"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  cat > "$BATS_TEST_TMPDIR/bin/wp" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" db export "*)
    printf -- '-- MySQL dump\nCREATE TABLE `wp_options` (\n'
    exit 1
    ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/wp"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  SITE_B_WP_CMD="wp"

  run backup_db_export "$BATS_TEST_TMPDIR/backup"
  [ "$status" -ne 0 ]
}

@test "backup_db_export (local branch) still succeeds and writes a real archive when the export genuinely succeeds (regression)" {
  unset SITE_B_SSH_HOST
  SITE_B_WP_PATH="/var/www/site-b"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/wp" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" db export "*)
    printf -- '-- MySQL dump\nCREATE TABLE `wp_options` (\n);\n-- Dump completed on 2026-08-19 10:00:00\n'
    exit 0
    ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/wp"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  SITE_B_WP_CMD="wp"

  run backup_db_export "$BATS_TEST_TMPDIR/backup"
  [ "$status" -eq 0 ]
  gzip -t "$BATS_TEST_TMPDIR/backup/b-db.sql.gz"
}

# --- backup_wp_content (wrapped-local branch) ---------------------------

@test "backup_wp_content (wrapped-local branch) fails when the source tar exits non-zero, even though the archive it produced was extracted cleanly" {
  local real_tar; real_tar=$(command -v tar)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # A `tar` stand-in used for BOTH ends of the pipe (the source side runs
  # through the wrapper prefix, the destination side runs directly — both
  # resolve `tar` off the same PATH). It behaves exactly like real tar
  # except that the create ("czf") side always exits 2 after writing a
  # complete, valid archive — the real-world shape of a tar that hit a
  # non-fatal-to-the-archive problem (e.g. a file changed while being read)
  # and still exits non-zero. The extract ("xzf") side is unmodified real
  # tar, so it succeeds on the complete stream it receives — reproducing
  # the exact swallow: the pipeline's last command exits 0.
  cat > "$BATS_TEST_TMPDIR/bin/tar" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "czf" ]; then
  "$real_tar" "\$@"
  exit 2
fi
exec "$real_tar" "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/tar"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  unset SITE_B_SSH_HOST
  local b_root="$BATS_TEST_TMPDIR/site-b"
  mkdir -p "${b_root}/wp-content/themes"
  printf 'x' > "${b_root}/wp-content/themes/style.css"
  SITE_B_WP_PATH="$b_root"
  # "env --" as the wrapper prefix so _backup_local_exec_prefix takes the
  # wrapped-local branch (same fixture shape test_phase_backup.bats uses).
  SITE_B_WP_CMD="env -- wp"

  run backup_wp_content "$BATS_TEST_TMPDIR/backup"
  [ "$status" -ne 0 ]
  # The archive landed on disk in full — what was wrong is only the exit
  # status silently reporting success over tar's own reported failure.
  [ -f "$BATS_TEST_TMPDIR/backup/themes/style.css" ]
}

@test "backup_wp_content (wrapped-local branch) still succeeds when both tar legs genuinely succeed (regression)" {
  unset SITE_B_SSH_HOST
  local b_root="$BATS_TEST_TMPDIR/site-b"
  mkdir -p "${b_root}/wp-content/themes"
  printf 'x' > "${b_root}/wp-content/themes/style.css"
  SITE_B_WP_PATH="$b_root"
  SITE_B_WP_CMD="env -- wp"

  run backup_wp_content "$BATS_TEST_TMPDIR/backup"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/backup/themes/style.css" ]
}
