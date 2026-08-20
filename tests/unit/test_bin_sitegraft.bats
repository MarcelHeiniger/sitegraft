# tests/unit/test_bin_sitegraft.bats — bin/sitegraft: the actual CLI
# entrypoint (usage/help/version, phase dispatch, and Task 6.1's global
# --dry-run handling). Every other test file loads lib/*.sh functions
# directly and calls phase_* functions in-process; this one is the only
# place the real executable itself, as an operator would actually run it,
# gets exercised — it can't be `load`-ed (its last line is `main "$@"`,
# which would run immediately), so every test invokes it as a real
# subprocess via `run`.
setup() {
  SITEGRAFT_BIN="${BATS_TEST_DIRNAME}/../../bin/sitegraft"
  # Isolated, guaranteed-empty profiles dir — these tests care about flag
  # parsing and dispatch, never about a real profile actually loading
  # successfully, and must never accidentally pick up a real profile from
  # this repo's own profiles/ directory.
  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  mkdir -p "$SITEGRAFT_PROFILES_DIR"
}

@test "sitegraft with no phase prints usage and exits non-zero" {
  run "$SITEGRAFT_BIN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: sitegraft"* ]] || false
}

@test "sitegraft --help prints usage and exits 0" {
  run "$SITEGRAFT_BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: sitegraft"* ]] || false
}

@test "sitegraft -h prints usage and exits 0" {
  run "$SITEGRAFT_BIN" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: sitegraft"* ]] || false
}

@test "sitegraft --version prints the version and exits 0" {
  run "$SITEGRAFT_BIN" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "sitegraft "* ]] || false
}

@test "sitegraft with an unknown phase errors clearly and exits non-zero" {
  run "$SITEGRAFT_BIN" bogus-phase --profile x
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown phase: bogus-phase"* ]] || false
}

# --- Task 6.1 Step 1: global --dry-run handling, applied before dispatch to
# every phase's argv uniformly.

@test "sitegraft plan --dry-run does not error as an unknown flag (--dry-run is stripped before dispatch)" {
  # plan never had, and still doesn't have, its own --dry-run case (it never
  # writes to B — only scan/backup/graft/verify/restore do). Before this
  # fix, passing --dry-run through the real CLI to plan would fail with
  # "unknown flag for plan: --dry-run" BEFORE ever reaching profile_load.
  # After this fix, that flag is stripped by bin/sitegraft's own global
  # handling ahead of the phase dispatch, so plan proceeds straight to
  # profile_load and fails for a completely different, expected reason
  # (no such profile) instead.
  run "$SITEGRAFT_BIN" plan --profile does-not-exist --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" != *"unknown flag for plan"* ]] || false
  [[ "$output" == *"profile not found: does-not-exist"* ]] || false
}

@test "sitegraft graft --dry-run still reaches phase_graft's own --profile validation (global stripping doesn't eat --profile too)" {
  run "$SITEGRAFT_BIN" graft --profile does-not-exist --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" != *"unknown flag for graft"* ]] || false
  [[ "$output" == *"profile not found: does-not-exist"* ]] || false
}

@test "sitegraft scan --dry-run still reaches profile_load (scan's own --dry-run handling is unaffected by the global strip)" {
  run "$SITEGRAFT_BIN" scan --profile does-not-exist --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" != *"unknown flag for scan"* ]] || false
  [[ "$output" == *"profile not found: does-not-exist"* ]] || false
}

# NIT-D (review fix-pack): --dry-run BEFORE the phase name used to read as
# the phase itself (`local phase="${1:-}"` ran before any stripping), so
# `sitegraft --dry-run graft ...` failed with the confusing "unknown phase:
# --dry-run" instead of being accepted like every other position in the
# argv. Fixed by stripping --dry-run from the whole argv before the phase
# is ever read out of it.
@test "sitegraft --dry-run graft (flag BEFORE the phase name) is accepted, not read as the phase itself (NIT-D)" {
  run "$SITEGRAFT_BIN" --dry-run graft --profile does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" != *"unknown phase"* ]] || false
  [[ "$output" == *"profile not found: does-not-exist"* ]] || false
}

@test "sitegraft --dry-run plan (flag BEFORE the phase name, on the phase that has no own --dry-run case) is also accepted (NIT-D)" {
  run "$SITEGRAFT_BIN" --dry-run plan --profile does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" != *"unknown phase"* ]] || false
  [[ "$output" != *"unknown flag for plan"* ]] || false
  [[ "$output" == *"profile not found: does-not-exist"* ]] || false
}
