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
