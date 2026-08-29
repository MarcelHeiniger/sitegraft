# tests/unit/test_graft_pipefail.bats — issue #99: the same missing-pipefail
# swallow test_backup_pipefail.bats reproduces for lib/backup.sh also exists
# in lib/graft.sh's wrapped-local transfer helpers, graft_pull_dir and
# graft_push_dir. Both run a `tar | tar` pipeline through `bash -c`, a fresh
# child shell that does not inherit bin/sitegraft's own `set -o pipefail` —
# so a tar leg that dies non-zero while the other leg still exits 0 on
# whatever it received is reported as a successful transfer.
#
# This matters even though both functions' call sites already check their
# return value (`graft_pull_dir ... || return $?`, design doc §6.4 step 1's
# media step) — see this file's own header note on that: the check is only
# as good as the status it's checking, and today that status is the WRONG
# one whenever the failing leg isn't the last one in the pipe.
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

# _install_fake_tar_failing_on_create — a `tar` stand-in for BOTH ends of a
# pipe: behaves exactly like real tar, except the create ("-c") side always
# writes a complete, valid archive for what it read and then exits 1 —
# measured against real GNU tar (1.35): racing a truncation against a
# large in-progress read produces "File shrank by N bytes; padding with
# zeros", exit status 1, with the archive itself still complete (tar pads
# and continues). Exit 1 is GNU tar's own non-fatal class for exactly this
# ("some files differ / changed while being read"); exit 2 is reserved for
# a genuinely fatal, archive-aborting error (measured separately: a
# Permission Denied read failure exits 2 and the archive is missing the
# unreadable entry entirely — a different, ALSO real failure shape, just
# not the one this fixture fabricates). The extract ("-x") side is
# unmodified real tar, so it always succeeds on the complete stream it
# receives — reproducing the exact swallow: the pipeline's LAST command
# exits 0 regardless of what the first one did.
_install_fake_tar_failing_on_create() {
  local real_tar; real_tar=$(command -v tar)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/tar" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "-c" ]; then
    "$real_tar" "\$@"
    exit 1
  fi
done
exec "$real_tar" "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/tar"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# --- graft_pull_dir (wrapped-local: prefixed create, plain extract) -----

@test "graft_pull_dir (wrapped-local) fails when the source-side (prefixed) tar exits non-zero, even though extraction succeeded" {
  _install_fake_tar_failing_on_create
  unset SITE_A_SSH_HOST
  local a_root="$BATS_TEST_TMPDIR/site-a"
  mkdir -p "${a_root}/uploads"
  printf 'x' > "${a_root}/uploads/photo.jpg"
  SITE_A_WP_PATH="$a_root"
  SITE_A_WP_CMD="env -- wp"

  run graft_pull_dir a "${a_root}/uploads" "$BATS_TEST_TMPDIR/staging"
  [ "$status" -ne 0 ]
  # the file still landed -- what's wrong is only the exit status
  [ -f "$BATS_TEST_TMPDIR/staging/photo.jpg" ]
}

@test "graft_pull_dir (wrapped-local) still succeeds when both tar legs genuinely succeed (regression)" {
  unset SITE_A_SSH_HOST
  local a_root="$BATS_TEST_TMPDIR/site-a"
  mkdir -p "${a_root}/uploads"
  printf 'x' > "${a_root}/uploads/photo.jpg"
  SITE_A_WP_PATH="$a_root"
  SITE_A_WP_CMD="env -- wp"

  run graft_pull_dir a "${a_root}/uploads" "$BATS_TEST_TMPDIR/staging"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/staging/photo.jpg" ]
}

# --- graft_push_dir (wrapped-local: plain create, prefixed extract) -----

@test "graft_push_dir (wrapped-local, no --keep-existing) fails when the source-side (plain) tar exits non-zero, even though extraction succeeded" {
  _install_fake_tar_failing_on_create
  unset SITE_B_SSH_HOST
  local staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging"
  printf 'x' > "${staging}/photo.jpg"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  SITE_B_WP_CMD="env -- wp"

  run graft_push_dir b "$staging" "${BATS_TEST_TMPDIR}/site-b/wp-content/uploads"
  [ "$status" -ne 0 ]
  [ -f "${BATS_TEST_TMPDIR}/site-b/wp-content/uploads/photo.jpg" ]
}

@test "graft_push_dir (wrapped-local, no --keep-existing) still succeeds when both tar legs genuinely succeed (regression)" {
  unset SITE_B_SSH_HOST
  local staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging"
  printf 'x' > "${staging}/photo.jpg"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  SITE_B_WP_CMD="env -- wp"

  run graft_push_dir b "$staging" "${BATS_TEST_TMPDIR}/site-b/wp-content/uploads"
  [ "$status" -eq 0 ]
  [ -f "${BATS_TEST_TMPDIR}/site-b/wp-content/uploads/photo.jpg" ]
}

# --keep-existing's own fallback path (no --skip-old-files support) already
# discards the pipeline's status on purpose (`${tolerate_exit}` = " || true"
# — see graft_push_dir's own comment on why: `-k`'s "file already exists"
# diagnostic is indistinguishable from a real failure, so it is warned about
# rather than trusted). Adding `set -o pipefail;` must not turn that
# deliberate tolerance into a hard failure — the `|| true` still has to win.
#
# NOTE (review, measured): this test is VACUOUS on macOS/bsdtar, the
# platform it was written and is run on. bsdtar's `-k` on a collision exits
# 0 on its own — measured directly, no `Cannot open: File exists` diagnostic
# at all — so this test passes identically whether or not `${tolerate_exit}`
# is even present; it exercises nothing about the fix under test here. GNU
# tar's `-k` on the same collision exits 2 (measured: "Cannot open: File
# exists" / "Exiting with failure status due to previous errors") — THAT is
# the platform (Linux CI, `runs-on: self-hosted`) where `${tolerate_exit}`'s
# `|| true` is load-bearing and this test has actual discriminating power.
# Left in for that reason (and because bats has no portable way to force a
# GNU-tar-shaped exit code here without reintroducing the fake-tar fixture
# this test is deliberately NOT using, to stay closer to a real tar
# invocation) — but do not read a green run of this specific test on a Mac
# as proof the fallback tolerance still works; only CI proves that.
@test "graft_push_dir --keep-existing fallback (-k, no --skip-old-files) still tolerates an existing-file collision (regression, unchanged by the pipefail fix)" {
  unset SITE_B_SSH_HOST
  local staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging"
  printf 'new\n' > "${staging}/photo.jpg"
  local dest="${BATS_TEST_TMPDIR}/site-b/wp-content/uploads"
  mkdir -p "$dest"
  printf 'existing\n' > "${dest}/photo.jpg"   # already present -> -k collision

  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  # A wrapper whose tar has no --skip-old-files, forcing the -k fallback:
  # override `tar --help` (probed through the wrapper) to say nothing about
  # it, without touching real tar's own behavior for the actual transfer.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  local real_tar; real_tar=$(command -v tar)
  cat > "$BATS_TEST_TMPDIR/bin/tar" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--help" ]; then
  echo "usage: tar (no such flag here)"
  exit 0
fi
exec "$real_tar" "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/tar"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  SITE_B_WP_CMD="env -- wp"

  run graft_push_dir b "$staging" "$dest" --keep-existing
  [ "$status" -eq 0 ]
  # -k means "refuse to touch it" -- the pre-existing file must survive
  # unchanged.
  [ "$(cat "${dest}/photo.jpg")" = "existing" ]
}
