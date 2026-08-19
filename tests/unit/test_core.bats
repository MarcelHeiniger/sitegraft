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

@test "the EXIT trap does not mask a failing function's exit status (M1, verified live against a real bash process)" {
  # Reproduces the real bug: previously, sitegraft_cleanup's own last
  # command (a loop over an empty SITEGRAFT_TMP_DIRS) always evaluated to
  # status 0, and since the trap did not preserve $? before running, that 0
  # became the script's final exit status regardless of what actually
  # failed — a real fatal error looked like success under set -e. A plain
  # bats "run" does not catch this (bats own trap handling interferes), so
  # this writes a tiny script and launches a real bash subprocess to
  # inspect its actual exit code.
  #
  # NOTE on scope: this bash 3.2 build has a separate, narrower quirk for
  # ONE specific failure class — a raw "unbound variable" parameter-
  # expansion error under set -u reports $?=0 to *any* EXIT trap,
  # regardless of what the trap does (verified: even a bare `trap true
  # EXIT` — no cleanup logic at all — masks that one case, while it never
  # masks a normal `return 1`/`exit 1`/failing-command exit tested here).
  # That is a bash 3.2 limitation this trap cannot work around from inside
  # sitegraft_cleanup. It's why M2 additionally guards `--profile`'s
  # argument access with an explicit arity check instead of ever letting
  # bash hit that unbound-variable path: the guard's `return 1` is the
  # normal, fully-preserved failure class this test proves works.
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo 'set -euo pipefail'
    echo ". \"${BATS_TEST_DIRNAME}/../../lib/core.sh\""
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
