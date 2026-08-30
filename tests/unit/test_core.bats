bats_require_minimum_version 1.5.0
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

@test "the EXIT trap preserves a genuinely successful run even when cleanup's own internal rm fails (M1, discriminating mutation test)" {
  # This is the test that actually discriminates the fix from its absence
  # (a second review round showed the previous version of this test did
  # not: mutating away BOTH `local rc=$?` and `return $rc` still left the
  # whole suite, including that test, green — because the previous
  # scenario's "stale dir" only affected an internal loop iteration, not
  # sitegraft_cleanup's own actual LAST executed command, which was
  # already an unconditional `rm -f "$SITEGRAFT_TMP_REGISTRY"` that
  # (almost) always succeeds on its own regardless of rc-capture).
  #
  # This scenario instead makes the registry directory read-only right
  # before the trap fires, so `rm -f "$SITEGRAFT_TMP_REGISTRY"` genuinely
  # fails with EACCES — verified directly (see the mutation proof below)
  # that this is real, not synthetic.
  #
  # Systematic empirical finding this test is built on (a full truth
  # table, not guesswork): on this bash version, when an EXIT trap's own
  # last executed command fails, that failure code REPLACES the script's
  # true original exit status — even discarding a distinguishable one
  # (e.g. `exit 2` becomes 1, the trap's own generic failure code), and
  # even flipping a genuine success (0) into a failure. When the trap's
  # own last command succeeds, the true original status survives
  # untouched. Two things follow from that, both present in
  # sitegraft_cleanup: (1) `rm -rf`/`rm -f` need `|| true` so a failure to
  # remove something never becomes the trap's own last (failing) status —
  # proven load-bearing by this test; (2) `local rc=$?; ...; return $rc`
  # is additionally kept as portable, low-cost defense in depth — on this
  # specific bash version, with the `|| true` guards already in place,
  # every code path through sitegraft_cleanup ends in a command that
  # succeeds on its own, which independently preserves the true original
  # status per the rule above, so no black-box scenario was found where
  # rc-capture is *independently* discriminable given (1) already holds.
  # Removing it was considered and rejected: relying solely on an
  # unwritten, version-specific bash trap behavior for correctness here
  # would be more fragile than keeping the explicit, portable pattern.
  local regdir="$BATS_TEST_TMPDIR/regdir"
  mkdir -p "$regdir"
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo 'set -euo pipefail'
    echo "TMPDIR=\"${regdir}\""
    echo ". \"${BATS_TEST_DIRNAME}/../../lib/core.sh\""
    echo 'trap sitegraft_cleanup EXIT'
    echo "chmod 555 \"${regdir}\""
    echo 'echo "script succeeding normally now"'
  } > "$probe"
  run bash "$probe"
  chmod 755 "$regdir"
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

@test "sitegraft_mktemp_dir fails loudly, naming the cause, instead of returning an empty path when mktemp -d fails (issue #109)" {
  # A non-existent TMPDIR makes the underlying `mktemp -d` fail with a real,
  # measured error ("No such file or directory") — not a synthetic stub.
  local missing_tmpdir="$BATS_TEST_TMPDIR/does-not-exist"
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo ". \"${BATS_TEST_DIRNAME}/../../lib/core.sh\""
    echo 'sitegraft_mktemp_dir'
  } > "$probe"
  TMPDIR="$missing_tmpdir" run --separate-stderr bash "$probe"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"temp"* ]] || false
}

@test "sitegraft_cleanup skips an empty registered entry without touching anything else (issue #109 — measured, not assumed)" {
  # #109 asked, specifically, what the cleanup trap does with an empty
  # entry — the shape a caller used to be able to register before
  # sitegraft_mktemp_dir was hardened to fail loudly instead of handing
  # back "". Measured directly rather than reasoned about: a real
  # registered dir with a sentinel file sits alongside a genuinely empty
  # entry, and cleanup must remove the real one and leave everything else
  # (including the process's own cwd, which an unguarded `rm -rf ""`
  # could reach) alone.
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo ". \"${BATS_TEST_DIRNAME}/../../lib/core.sh\""
    echo 'sitegraft_register_tmp_dir ""'
    echo 'realdir=$(mktemp -d)'
    echo 'touch "${realdir}/sentinel"'
    echo 'sitegraft_register_tmp_dir "$realdir"'
    echo '[ -d "$realdir" ] || exit 1'
    echo 'sitegraft_cleanup'
    echo '[ -d "$PWD" ] || { echo "cwd was destroyed"; exit 1; }'
    echo '[ ! -d "$realdir" ] || { echo "real registered dir was NOT cleaned up"; exit 1; }'
  } > "$probe"
  run bash "$probe"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
