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
