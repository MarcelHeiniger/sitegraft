# tests/unit/test_graft_phase_wiring.bats — the marker-file resumability
# mechanism every graft sub-step uses (design doc §6.4: "an interrupted
# graft resumes at the sub-step after the last marker, never from scratch").
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_step_done and graft_mark_step track completion via marker files" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  run graft_step_done "$run_dir" media_sync
  [ "$status" -eq 1 ]
  graft_mark_step "$run_dir" media_sync
  run graft_step_done "$run_dir" media_sync
  [ "$status" -eq 0 ]
}

# --- MAJOR-B / BLOCKER (review fix-pack, reproduced live by Viktor):
# graft_mark_step used to `touch` its marker unconditionally, dry-run or
# not. Every step in phase_graft is wired as `graft_step_done ... || {
# <step>; graft_mark_step ...; }`, so a `--dry-run` graft against a run
# directory wrote every single graft.<step>.done marker for real — a REAL
# graft against that SAME run directory afterward then sees every step as
# already done and silently skips the entire pipeline (reports "graft
# complete" without migrating anything). Reachable via the realistic
# sequence scan -> plan -> backup -> graft --dry-run -> graft. Fixed by
# guarding graft_mark_step itself so no marker is ever written while
# SITEGRAFT_DRY_RUN=1, regardless of which of the dozen call sites in
# lib/graft.sh triggered it.
@test "graft_mark_step writes no marker at all under SITEGRAFT_DRY_RUN=1 (MAJOR-B)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  SITEGRAFT_DRY_RUN=1 graft_mark_step "$run_dir" media_sync
  run graft_step_done "$run_dir" media_sync
  [ "$status" -eq 1 ]
  [ ! -e "${run_dir}/graft.media_sync.done" ]
}

@test "graft_mark_step still writes the marker for real once dry-run is off, even after an earlier dry-run call for the same step (MAJOR-B: a real graft after a dry-run graft must not be skipped)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  # Simulates the exact reported sequence: a dry-run graft touches this
  # step first (writes nothing, per the test above), then a REAL graft
  # runs the same step and must both (a) actually run it — proven at the
  # phase_graft call-site level by `graft_step_done` still reading false
  # going INTO the step, not asserted here — and (b) mark it done for real
  # afterward, exactly like any other non-dry-run step.
  SITEGRAFT_DRY_RUN=1 graft_mark_step "$run_dir" media_sync
  run graft_step_done "$run_dir" media_sync
  [ "$status" -eq 1 ]
  unset SITEGRAFT_DRY_RUN
  graft_mark_step "$run_dir" media_sync
  run graft_step_done "$run_dir" media_sync
  [ "$status" -eq 0 ]
}

# graft_content_tables_csv's own test used to live here — removed (review,
# Viktor, NIT-1) along with the function itself: it went orphaned the
# moment graft_remap_attachment_ids/graft_search_replace_domain stopped
# scanning whole tables (MAJOR-2 fix-pack). See
# tests/unit/test_content_remap_functions.bats for where the remap logic's
# real test coverage lives now.

# --- dry-run-trap: _graft_exit_trap's own `rm -f` of the mu-plugin markers
# was the ONE mutation in that trap never guarded by is_dry_run, unlike
# graft_mark_step above (MAJOR-B), which exists specifically to prevent this
# exact class of bug. The on-disk state this exercises — mu_plugin.done
# written, mu_cleanup.done never written — is NOT the ordinary state of an
# in-flight graft: this very trap fires and clears it on every gracefully
# handled exit (verified: SIGINT/SIGTERM/SIGHUP all reach it, same as a
# normal successful/failed run). It's left behind only by `kill -9`, an
# OOM/crash, a run directory written by a pre-fix sitegraft, or a second
# invocation racing the first one on the same run dir — rare, but exactly
# the case this trap's whole branch exists to handle, so it's what these
# tests set up directly rather than trying to reproduce the crash itself.
# Given that state, running `sitegraft graft --dry-run` against the same
# run directory used to delete graft.mu_plugin.done for real even though
# graft_remove_mu_plugin (dry-run-safe, built on run_or_echo) touched
# nothing on B — see the fix's own comment in lib/graft.sh for what a
# second dry-run pass then silently stopped reporting. Fixed the same way
# MAJOR-B fixed graft_mark_step: `is_dry_run ||` in front of the mutation.
@test "_graft_exit_trap deletes neither marker under SITEGRAFT_DRY_RUN=1 (dry-run-trap)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  # mu_plugin deployed, cleanup never ran — see the comment above for why
  # this state, though rare, is exactly what this branch exists to handle.
  graft_mark_step "$run_dir" mu_plugin
  [ -e "${run_dir}/graft.mu_plugin.done" ]
  # (mu_cleanup.done is never written by this fixture, so a matching
  # `[ ! -e ... ]` here would pass unconditionally, before or after the
  # fix — the trap's own `if` guard above already requires it absent to
  # even enter this branch. Omitted per review, NIT-1: it doesn't prove
  # anything a mutation on the code under test could ever fail.)

  # Stub out everything the trap talks to on B so this stays a unit test —
  # no site, no wp-cli, no ssh. graft_remove_mu_plugin is overridden rather
  # than left to run for real. SITE_B_WP_PATH is unset explicitly, because
  # profile_load (lib/profile.sh) exports it for every real sitegraft
  # invocation — an inherited value from the surrounding shell would make
  # the trap's second block (the id/domain-remap payload cleanup below)
  # run graft_remove_file against a real path instead of the no-op this
  # test intends (review, MAJOR-1: an inherited SITE_B_WP_PATH pointing at
  # a real site directory made this exact suite delete real files there).
  unset SITE_B_WP_PATH
  graft_remove_mu_plugin() { :; }

  SITEGRAFT_GRAFT_RUN_DIR="$run_dir" SITEGRAFT_DRY_RUN=1 _graft_exit_trap

  [ -e "${run_dir}/graft.mu_plugin.done" ]
}

@test "_graft_exit_trap still deletes the marker for real once dry-run is off (dry-run-trap: a real interrupted-graft cleanup must not be skipped)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  graft_mark_step "$run_dir" mu_plugin
  [ -e "${run_dir}/graft.mu_plugin.done" ]

  # See the sibling test above for why SITE_B_WP_PATH is unset explicitly
  # rather than merely never assigned (review, MAJOR-1).
  unset SITE_B_WP_PATH
  graft_remove_mu_plugin() { :; }

  SITEGRAFT_GRAFT_RUN_DIR="$run_dir" _graft_exit_trap

  [ ! -e "${run_dir}/graft.mu_plugin.done" ]
}

# --- graft_run_module_post_import creates module-content-rewrites.tsv -----
# unconditionally (issue #52 fix-pack, review round 3, MAJOR) — lib/verify.
# sh's guard 1 reads this file's mere PRESENCE (even empty) as "this run's
# hooks were given the chance to record what they rewrote"; its absence
# used to be ambiguous with "hooks ran and rewrote nothing", which let a
# genuinely correct graft's module-rewritten content read as a false HARD
# FAIL.
setup_no_op_module() {
  # A module discovered with a post_import hook that changes nothing, so
  # this exercises the "created even when nothing gets rewritten" case,
  # not merely "created when something does".
  SITEGRAFT_MODULES="noop"
  noop_post_import() { :; }
}

@test "graft_run_module_post_import creates module-content-rewrites.tsv even when no hook rewrites anything (review round 3, MAJOR)" {
  setup_no_op_module
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  graft_run_module_post_import "$run_dir" "${run_dir}/id-map.tsv"
  [ -f "${run_dir}/module-content-rewrites.tsv" ]
  [ ! -s "${run_dir}/module-content-rewrites.tsv" ]
}

@test "graft_run_module_post_import does NOT create module-content-rewrites.tsv under SITEGRAFT_DRY_RUN=1" {
  setup_no_op_module
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  SITEGRAFT_DRY_RUN=1 graft_run_module_post_import "$run_dir" "${run_dir}/id-map.tsv"
  [ ! -f "${run_dir}/module-content-rewrites.tsv" ]
}

# --- graft_safety_step_done (issue #54) -------------------------------------
#
# A "safety" step's own marker is not, by itself, grounds to skip it on
# resume — only true once whatever it protects (its "consumer" step(s))
# has also completed. See lib/graft.sh's own header comment on this
# function, right above graft_mark_step, for the full reasoning and the
# three designs weighed. tests/unit/test_graft_resume_safety.bats covers
# the real end-to-end resume behavior this function exists to enable
# (phase_graft, invoked twice as a real subprocess); these are the pure
# gate-logic unit tests, in the same style as this file's own
# graft_step_done/graft_mark_step tests above.

@test "graft_safety_step_done is false when the safety step itself never ran" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  run graft_safety_step_done "$run_dir" prune import
  [ "$status" -eq 1 ]
}

@test "graft_safety_step_done is false when the safety step ran but its consumer has not (issue #54's exact scenario)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  graft_mark_step "$run_dir" prune
  run graft_safety_step_done "$run_dir" prune import
  [ "$status" -eq 1 ]
}

@test "graft_safety_step_done is true once the safety step AND its consumer have both completed" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  graft_mark_step "$run_dir" prune
  graft_mark_step "$run_dir" import
  run graft_safety_step_done "$run_dir" prune import
  [ "$status" -eq 0 ]
}

@test "graft_safety_step_done requires EVERY named consumer, not just one of several" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  graft_mark_step "$run_dir" prune
  graft_mark_step "$run_dir" import_attachments
  # "import" (the second consumer) is still incomplete.
  run graft_safety_step_done "$run_dir" prune import_attachments import
  [ "$status" -eq 1 ]
  graft_mark_step "$run_dir" import
  run graft_safety_step_done "$run_dir" prune import_attachments import
  [ "$status" -eq 0 ]
}

@test "graft_safety_step_done with no consumers named behaves exactly like plain graft_step_done" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  run graft_safety_step_done "$run_dir" prune
  [ "$status" -eq 1 ]
  graft_mark_step "$run_dir" prune
  run graft_safety_step_done "$run_dir" prune
  [ "$status" -eq 0 ]
}
