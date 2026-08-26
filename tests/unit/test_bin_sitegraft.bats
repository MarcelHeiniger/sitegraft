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

# --- MINOR-2 (review): graft/verify require `php` up front -----------------
#
# graft_integrity_gate and graft_verify_import_completeness (both
# lib/graft.sh, both security-relevant WXR gates as of issue #53/#54's
# fix-pack) now invoke `php` for every real graft. Before this, a PATH
# missing php stayed invisible until the `export` step deep inside
# phase_graft -- well AFTER backup, media sync, prune, and attachment
# import had already mutated B -- instead of failing in the first second,
# the same way a missing jq/rsync already does via the existing
# require_cmd calls right next to this one.
#
# _build_php_free_path (review, CI-found regression -- reproduced live,
# not assumed): the FIRST version of these two tests built PATH from
# hardcoded directories ("/usr/bin:/bin" plus a symlinked rsync from
# `command -v rsync`'s own real location), reasoning that excluding
# `/opt/homebrew/bin` -- the one directory holding php on the machine that
# wrote the test -- was what isolated php out. True only on THAT machine.
# On the GitHub Actions Ubuntu runner, php lives in /usr/bin, which the
# test's own hardcoded PATH keeps -- so php resolves fine, require_cmd php
# passes, "php" never appears in $output, and the assertion fails. The
# test encoded one developer's filesystem layout instead of the property
# it exists to prove ("php is absent") -- exactly the class of bug this
# whole fix-pack spent its nights on, this time caught by CI running
# somewhere other than where the test was written.
#
# Deterministic instead: walk every directory actually in $PATH (whatever
# they are, on whatever machine or CI runner this executes on) and symlink
# every executable found in each -- except any literally named "php" --
# into one isolated directory, first match per name wins (same precedence
# order the real PATH already had). This carries over jq/rsync/bash/every
# coreutil bin/sitegraft's own preamble needs (mktemp, at lib/core.sh's
# own source time, for SITEGRAFT_TMP_REGISTRY, before either test's own
# `graft`/`verify` case is ever reached) from wherever they actually live,
# on any layout, while genuinely never placing php on the resulting PATH
# regardless of which directory happens to hold it.
_build_php_free_path() {
  local target="$1"
  mkdir -p "$target"
  local old_ifs="$IFS" dir entry base
  IFS=':'
  # shellcheck disable=SC2086 # intentionally unquoted: splitting $PATH on IFS=':' is the whole point
  for dir in $PATH; do
    IFS="$old_ifs"
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    for entry in "$dir"/*; do
      [ -e "$entry" ] || continue
      base=$(basename "$entry")
      [ "$base" = "php" ] && continue
      [ -e "${target}/${base}" ] && continue
      ln -s "$entry" "${target}/${base}" 2>/dev/null || true
    done
    IFS=':'
  done
  IFS="$old_ifs"
}

@test "sitegraft graft fails fast (before any mutation) when php is not on PATH" {
  local isolated_bin="$BATS_TEST_TMPDIR/isolated-bin"
  _build_php_free_path "$isolated_bin"
  PATH="$isolated_bin" run "$SITEGRAFT_BIN" graft --profile does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"php"* ]] || false
}

@test "sitegraft verify fails fast when php is not on PATH" {
  local isolated_bin="$BATS_TEST_TMPDIR/isolated-bin"
  _build_php_free_path "$isolated_bin"
  PATH="$isolated_bin" run "$SITEGRAFT_BIN" verify --profile does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"php"* ]] || false
}
