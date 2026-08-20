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

# graft_content_tables_csv's own test used to live here — removed (review,
# Viktor, NIT-1) along with the function itself: it went orphaned the
# moment graft_remap_attachment_ids/graft_search_replace_domain stopped
# scanning whole tables (MAJOR-2 fix-pack). See
# tests/unit/test_content_remap_functions.bats for where the remap logic's
# real test coverage lives now.
