# tests/unit/test_core.bats
setup() {
  load '../../lib/core.sh'
}

@test "require_cmd succeeds for a command that exists" {
  run require_cmd bash
  [ "$status" -eq 0 ]
}

@test "require_cmd fails with a helpful message for a missing command" {
  run require_cmd this-command-does-not-exist-xyz
  [ "$status" -eq 1 ]
  [[ "$output" == *"this-command-does-not-exist-xyz"* ]]
}

@test "is_dry_run reflects SITEGRAFT_DRY_RUN" {
  SITEGRAFT_DRY_RUN=1
  run is_dry_run
  [ "$status" -eq 0 ]
  unset SITEGRAFT_DRY_RUN
  run is_dry_run
  [ "$status" -eq 1 ]
}

@test "the EXIT trap does not flip a successful run into a failure over a stale registered temp dir (M1, verified live)" {
  # This is the REAL bug (corrected from an earlier, wrong description of
  # it — see the note in lib/core.sh): a *stale* registered dir (one that
  # no longer exists on disk for any reason) makes the cleanup loop's last
  # evaluated command, `[ -d "$dir" ] && rm -rf "$dir"`, end on the FALSE
  # branch — exit 1, since `&&` short-circuits before rm -rf ever runs.
  # Without capturing $? before that loop runs, that stray 1 silently
  # replaced the exit status of an otherwise completely successful script.
  # Verified two ways before writing this test: (a) reproduced against a
  # minimal reimplementation of the pre-fix cleanup — a genuinely
  # successful script with a stale dir registered came out exit 1; (b)
  # confirmed the *opposite* claim an earlier draft of this test/comment
  # made — that normal failures (return 1/exit N/a failing command) were
  # being masked to exit 0 — is FALSE: those propagated correctly both
  # before and after this fix (see the baseline test below).
  #
  # A plain bats "run" cannot observe this (bats' own trap handling
  # interferes), so this writes a tiny script that installs the trap
  # itself — exactly as bin/sitegraft now does, not lib/core.sh — and
  # launches a real bash subprocess to inspect its actual exit code.
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo 'set -euo pipefail'
    echo ". \"${BATS_TEST_DIRNAME}/../../lib/core.sh\""
    echo 'trap sitegraft_cleanup EXIT'
    echo 'sitegraft_register_tmp_dir "/tmp/this-dir-does-not-exist-sitegraft-m1-test"'
    echo 'echo "script succeeding normally now"'
  } > "$probe"
  run bash "$probe"
  [ "$status" -eq 0 ]
}

@test "the EXIT trap still lets a normal failure propagate (baseline — this was never actually broken)" {
  # Kept as regression coverage, not as proof of a fix: return 1/exit N/a
  # failing command under set -e were verified to propagate correctly both
  # before and after the M1 fix above — this only guards against a future
  # change to sitegraft_cleanup accidentally breaking that.
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo 'set -euo pipefail'
    echo ". \"${BATS_TEST_DIRNAME}/../../lib/core.sh\""
    echo 'trap sitegraft_cleanup EXIT'
    echo 'boom() { return 1; }'
    echo 'boom'
  } > "$probe"
  run bash "$probe"
  [ "$status" -eq 1 ]
}

@test "sitegraft_mktemp_dir registers dirs newline-delimited so a space in TMPDIR does not word-split the cleanup registry (m4)" {
  local fake_tmpdir="$BATS_TEST_TMPDIR/has space"
  mkdir -p "$fake_tmpdir"
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo ". \"${BATS_TEST_DIRNAME}/../../lib/core.sh\""
    echo 'dir1=$(sitegraft_mktemp_dir)'
    echo 'dir2=$(sitegraft_mktemp_dir)'
    echo '[ -d "$dir1" ] && [ -d "$dir2" ] || exit 1'
    echo 'sitegraft_cleanup'
    echo '[ ! -d "$dir1" ] && [ ! -d "$dir2" ]'
  } > "$probe"
  TMPDIR="$fake_tmpdir" run bash "$probe"
  [ "$status" -eq 0 ]
}
