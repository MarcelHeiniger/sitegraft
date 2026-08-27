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

# --- MAJOR-4 (review): the `is_dry_run ||` guard in front of phase_graft's
# own prune-safety marker-clearing (`rm -f
# "${run_dir}/graft.import_attachments.done" "${run_dir}/graft.import.done"
# "${run_dir}/graft.fetch_id_map.done"`, right where graft_safety_step_done
# gates the prune block) had NO test of its own before this fix-pack. It
# works (verified live: a real `graft --dry-run` leaves
# graft.import_attachments.done intact and issues no real wp-cli calls),
# but removing it left the rest of the suite entirely green — exactly the
# class of bug this repo already shipped once (the identical guard on
# graft_mark_step itself, MAJOR-B above, and on _graft_exit_trap's own
# marker clear, "dry-run-trap" above). This is that same shape's test,
# applied to phase_graft's OWN inline `rm -f`, which is not itself a
# graft_mark_step call site and so was not covered by either of those.
#
# phase_graft is exercised directly here (not via bin/sitegraft) with every
# heavy dependency it calls stubbed out, isolating the ONE branch under
# test: entering the prune-safety block (forced by leaving fetch_id_map's
# own marker unmarked) while SITEGRAFT_DRY_RUN=1. `run` is used even though
# this is a same-process function call, not a subprocess — bats' `run`
# forks a subshell to capture output, and phase_graft installs `trap
# _graft_exit_trap EXIT` on entry; that trap firing inside `run`'s own
# throwaway subshell (rather than this test's real process) is the exact,
# documented-safe pattern lib/core.sh's own sitegraft_cleanup comment
# describes ("verified live against bats' own run... the trap fires within
# that subshell only").
_major4_stub_everything_but_the_marker_block() {
  profile_load() {
    SITE_A_ALIAS=a; SITE_B_ALIAS=b
    unset SITE_A_SSH_HOST SITE_B_SSH_HOST
    return 0
  }
  modules_discover() { SITEGRAFT_MODULES=""; }
  graft_sync_stack() { :; }
  graft_check_stack_precondition() { return 0; }
  graft_media_sync() { :; }
  graft_deploy_mu_plugin() { :; }
  graft_prune_previous_run() { echo "STUB: graft_prune_previous_run $*"; }
  graft_import_attachments() { echo "STUB: graft_import_attachments called -- should not happen"; }
  graft_ensure_importer() { :; }
  graft_export_wxr() { echo "STUB: graft_export_wxr called -- should not happen"; }
  graft_integrity_gate() { return 0; }
  graft_import_wxr() { echo "STUB: graft_import_wxr called -- should not happen"; }
  graft_fetch_id_map() { :; }
  graft_remove_mu_plugin() { :; }
  graft_restore_importer_state() { :; }
  graft_remap_attachment_ids() { :; }
  graft_remap_featured_images() { :; }
  graft_search_replace_domain() { :; }
  graft_migrate_options() { :; }
  graft_run_module_post_import() { :; }
}

@test "phase_graft's prune-safety marker-clearing does not touch REAL markers under --dry-run (MAJOR-4)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  touch "${run_dir}/backup.complete"
  cat > "${run_dir}/manifest.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}
EOF
  # Every step through `import` already completed for real on an earlier
  # pass -- EXCEPT fetch_id_map, which never ran (interrupted right after
  # import). graft_safety_step_done "$run_dir" prune import_attachments
  # import fetch_id_map therefore reads false (fetch_id_map is missing),
  # entering the marker-clearing block even though import_attachments and
  # import genuinely finished.
  local step
  for step in stack_sync media_sync mu_plugin prune import_attachments importer_setup export import; do
    touch "${run_dir}/graft.${step}.done"
  done
  [ ! -f "${run_dir}/graft.fetch_id_map.done" ]

  _major4_stub_everything_but_the_marker_block

  SITEGRAFT_DRY_RUN=1
  run phase_graft --profile demo --run "$run_dir" --dry-run
  [ "$status" -eq 0 ]

  # The acceptance criterion: real, on-disk markers from the completed
  # pass must survive a dry-run pass through this exact block. Removing
  # `is_dry_run ||` from phase_graft's own `rm -f` here (MAJOR-4) makes
  # this assertion fail -- confirmed by hand for this fix-pack.
  [ -f "${run_dir}/graft.import_attachments.done" ]
  [ -f "${run_dir}/graft.import.done" ]

  # Sanity: the block really was entered (not vacuously skipped) --
  # graft_prune_previous_run's own stub only prints if actually called.
  [[ "$output" == *"STUB: graft_prune_previous_run"* ]] || false
  # And nothing downstream of the (correctly still-marked-done)
  # import_attachments/import steps re-ran for real.
  [[ "$output" != *"should not happen"* ]] || false
}

@test "phase_graft's prune-safety marker-clearing DOES clear real markers once dry-run is off (MAJOR-4: a real interrupted-graft resume must not be skipped)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  touch "${run_dir}/backup.complete"
  cat > "${run_dir}/manifest.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}
EOF
  local step
  for step in stack_sync media_sync mu_plugin prune import_attachments importer_setup export import; do
    touch "${run_dir}/graft.${step}.done"
  done

  _major4_stub_everything_but_the_marker_block
  # graft_verify_import_completeness is real everywhere else in this suite
  # (tests/unit/test_graft_import_completeness.bats) -- stubbed here only
  # because this test has no real staged WXR/id-map.tsv to give it and
  # isn't the one exercising that gate's own behavior.
  graft_verify_import_completeness() { return 0; }

  unset SITEGRAFT_DRY_RUN
  run phase_graft --profile demo --run "$run_dir"
  [ "$status" -eq 0 ]

  # NOT marker-absence: once cleared, import_attachments/import legitimately
  # RERUN (that's the entire point of clearing them) and, succeeding for
  # real under a non-dry-run pass, immediately re-touch their own markers
  # via graft_mark_step -- so both files are back on disk by the time
  # phase_graft returns, exactly as they should be. The real acceptance
  # criterion is that the STEPS THEMSELVES actually ran again, which the
  # "should not happen" stubs from _major4_stub_everything_but_the_marker_
  # block (still installed, un-overridden) prove directly: they only print
  # if genuinely invoked. Under the MAJOR-4 bug (guard inverted or
  # removed so `rm -f` never fires under dry-run OR, the mutation that
  # actually matters here, a guard that ALSO wrongly suppresses it under a
  # real run), these markers would stay "done" from the earlier pass,
  # import_attachments/import would be skipped, and neither stub would ever
  # print -- this assertion goes red exactly then.
  [[ "$output" == *"STUB: graft_import_attachments called"* ]] || false
  [[ "$output" == *"STUB: graft_import_wxr called"* ]] || false
  [ -f "${run_dir}/graft.import_attachments.done" ]
  [ -f "${run_dir}/graft.import.done" ]
}

# --- BLOCKER-B (review): MAJOR-3 + BLOCKER-1c together used to form a
# destructive, non-recoverable loop --------------------------------------
#
# A run that finished SUCCESSFULLY (every step through fetch_id_map marked
# done); the operator later removes run_dir/export/*.xml (a real run dir's
# largest files -- an unremarkable disk-cleanup action, not a bug). A
# resume then: (1) graft_verify_import_completeness's own BLOCKER-1c
# branch hard-fails on the missing export; (2) MAJOR-3's marker-clearing
# used to fire on ANY nonzero return, clearing import_attachments.done/
# import.done/fetch_id_map.done and telling the operator a retry WOULD
# fix it; (3) a retry then trips graft_safety_step_done, reruns
# graft_prune_previous_run FOR REAL -- deleting every post/attachment this
# tool had already correctly migrated onto B -- and (4) still fails
# afterward, because graft.export.done was never touched and the (now
# permanently empty) export step stays marked done, never regenerating the
# file the retry needed. Net: B's migrated content destroyed, run dir
# still cannot recover. graft_verify_import_completeness now returns a
# distinct code (2) for exactly this "my own staged data isn't here,
# not a wordpress-importer skip" case, and phase_graft's own call site
# refuses to clear any marker or invite a retry for it -- this is the
# acceptance test for that fix.
@test "BLOCKER-B acceptance: a completed run whose staged export vanished fails WITHOUT clearing markers or invoking prune" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  touch "${run_dir}/backup.complete"
  cat > "${run_dir}/manifest.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}
EOF
  # Every step through fetch_id_map already completed for real -- but
  # export/ is empty right now (its .xml file(s) removed since).
  local step
  for step in stack_sync media_sync mu_plugin prune import_attachments importer_setup export import fetch_id_map; do
    touch "${run_dir}/graft.${step}.done"
  done
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"

  _major4_stub_everything_but_the_marker_block
  # graft_verify_import_completeness is deliberately REAL here (not
  # stubbed like the sibling MAJOR-4 tests above) -- it's exactly what's
  # under test: its own BLOCKER-1c branch must return 2 for this run_dir
  # shape, and phase_graft's call site must treat that 2 differently from
  # the 1 those sibling tests exercise.

  unset SITEGRAFT_DRY_RUN
  run phase_graft --profile demo --run "$run_dir"
  [ "$status" -eq 1 ]

  # The acceptance criterion: NONE of the three retry markers were
  # cleared, and prune (the STUB from _major4_stub_everything_but_the_
  # marker_block, which prints "STUB: graft_prune_previous_run" whenever
  # actually invoked) was NEVER called.
  [ -f "${run_dir}/graft.import_attachments.done" ]
  [ -f "${run_dir}/graft.import.done" ]
  [ -f "${run_dir}/graft.fetch_id_map.done" ]
  [[ "$output" != *"STUB: graft_prune_previous_run"* ]] || false

  # The message says what actually happened and what to do -- never
  # implies a retry will fix it (the OPPOSITE of the rc=1 message the
  # MAJOR-3 tests above check for).
  [[ "$output" == *"cannot self-heal"* ]] || false
  [[ "$output" == *"fresh run"* ]] || false
  [[ "$output" != *"WILL retry"* ]] || false
}

# --- foreign-file message clarity (review — the DDEV harness's OWN bug,
# reproduced here at the phase_graft level, not sitegraft's): a test
# fixture (assertion (e), tests/integration/ddev-harness.sh) wrote a
# mutated WXR straight into a completed run's own export/ and never
# cleaned it up, so the harness's OWN "re-running graft is a no-op"
# resumability check died on it -- fail-closed working exactly as
# designed, but the message it produced read as "your export is corrupt"
# rather than naming the far more likely real cause. Fixed on the harness
# side (it no longer writes there, see that file's own comment); this is
# the phase_graft-level proof that the message itself now names the
# foreign-file possibility for any operator who hits the identical shape
# by hand.
@test "BLOCKER-B message names the foreign-file possibility when export/ holds a file this run never produced, not just 'corrupt'" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "${run_dir}/export"
  touch "${run_dir}/backup.complete"
  cat > "${run_dir}/manifest.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}
EOF
  local step
  for step in stack_sync media_sync mu_plugin prune import_attachments importer_setup export import fetch_id_map; do
    touch "${run_dir}/graft.${step}.done"
  done
  # This run's own real export never happened to write anything (marker
  # already done) -- what's actually sitting in export/ is a file nobody
  # here produced, exactly the DDEV harness's own reproduction.
  cat > "${run_dir}/export/leftover-from-somewhere-else.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_type>injected_evil_type</wp:post_type></item>
</channel></rss>
EOF

  _major4_stub_everything_but_the_marker_block
  # graft_verify_import_completeness is REAL here, same as the sibling
  # BLOCKER-B test above -- it's exactly what's under test.

  unset SITEGRAFT_DRY_RUN
  run phase_graft --profile demo --run "$run_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"was NOT produced by this run"* ]] || false
  [[ "$output" == *"foreign or malformed"* ]] || false
  # Still no marker touched, still no prune invoked -- the underlying
  # BLOCKER-B fix is unaffected by this message-only change.
  [ -f "${run_dir}/graft.import_attachments.done" ]
  [[ "$output" != *"STUB: graft_prune_previous_run"* ]] || false
}

# --- MAJOR-1 (issue #73, second review round): the reviewer's own live
# reproduction — a run_dir left over from an rc10 (pre-#73-fix) release
# already carries graft.remap_domain.done, from a pass where
# graft_search_replace_domain's in-function guard did not exist yet. On
# resume, `graft_step_done "$run_dir" remap_domain || { ... }` sees that
# marker and skips the ENTIRE block — guard included — never
# re-evaluating it, and graft_migrate_options (which had no guard of its
# own at all before this fix) runs immediately after with the same broken
# domain_to. graft_verify_domain_remap_usable is now called UNCONDITIONALLY,
# before either consumer, specifically so a marker like this one cannot
# hide the check from ever running again.
_blocker1_stub_everything_but_domain_check() {
  profile_load() {
    SITE_A_ALIAS=a; SITE_B_ALIAS=b
    unset SITE_A_SSH_HOST SITE_B_SSH_HOST
    return 0
  }
  modules_discover() { SITEGRAFT_MODULES=""; }
  graft_sync_stack() { :; }
  graft_check_stack_precondition() { return 0; }
  graft_media_sync() { :; }
  graft_deploy_mu_plugin() { :; }
  graft_prune_previous_run() { :; }
  graft_import_attachments() { :; }
  graft_ensure_importer() { :; }
  graft_export_wxr() { :; }
  graft_integrity_gate() { return 0; }
  graft_import_wxr() { :; }
  graft_fetch_id_map() { :; }
  graft_verify_import_completeness() { return 0; }
  graft_remove_mu_plugin() { :; }
  graft_restore_importer_state() { :; }
  graft_remap_attachment_ids() { :; }
  graft_remap_featured_images() { :; }
  graft_search_replace_domain() { echo "STUB: graft_search_replace_domain called -- should NOT happen, the top-level guard must abort before this"; }
  graft_migrate_options() { echo "STUB: graft_migrate_options called -- should NOT happen, the top-level guard must abort before this"; }
  graft_run_module_post_import() { echo "STUB: graft_run_module_post_import called -- should NOT happen"; }
}

@test "phase_graft refuses to run — before graft_migrate_options is ever reached — when resuming a run_dir whose remap_domain marker pre-dates this fix and domain_to is broken (MAJOR-1, #73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  touch "${run_dir}/backup.complete"
  # A's scan succeeded (a real, non-empty from); B's scan failed
  # (plan_defaults' own "unknown" default) — BLOCKER-1's exact
  # reproduction, on a manifest that (pre-dating manifest_validate's own
  # #73 guard) was frozen anyway.
  cat > "${run_dir}/manifest.json" <<'MANIFESTEOF'
{"migrate":{"core-wp":{"post_types":["page"],"option_keys":["show_on_front"]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"https://a.example.com","to":"unknown"}}}
MANIFESTEOF
  # Every step through remap_featured_images already completed on an
  # earlier, rc10 pass -- INCLUDING remap_domain, whose in-function guard
  # did not exist yet at the time it ran and "succeeded".
  local step
  for step in stack_sync media_sync mu_plugin prune import_attachments importer_setup export import fetch_id_map mu_cleanup importer_cleanup remap_ids remap_featured_images remap_domain; do
    touch "${run_dir}/graft.${step}.done"
  done

  _blocker1_stub_everything_but_domain_check

  run phase_graft --profile demo --run "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" != *"STUB: graft_search_replace_domain called"* ]] || false
  [[ "$output" != *"STUB: graft_migrate_options called"* ]] || false
  [[ "$output" == *"unknown"* ]] || false
  # And the pre-existing (now stale) remap_domain marker did not fool the
  # NEXT step's own marker into being written either -- migrate_options
  # never ran, so it must not be marked done.
  [ ! -f "${run_dir}/graft.migrate_options.done" ]
}

# --- Issue #16: the actual defect was never "which post types get
# selected" (etch_post_types_dynamic already got that right — see its own
# header comment) but WHEN the option that defines them reaches B. Before
# this fix, graft_migrate_options (which carries etch_cpts) ran AFTER
# graft_import_wxr, so B's WordPress boot never saw the definition before
# the WXR import needed it, and wordpress-importer treated the type as
# unknown for the whole import. The fix is this ordering, proven directly
# here rather than trusted from graft_migrate_post_type_defining_options'
# own unit tests (tests/unit/test_graft_post_type_defining_options.bats),
# which cover its internal behavior but not WHERE phase_graft calls it.
_issue16_stub_everything_but_ordering() {
  profile_load() {
    SITE_A_ALIAS=a; SITE_B_ALIAS=b
    unset SITE_A_SSH_HOST SITE_B_SSH_HOST
    return 0
  }
  modules_discover() { SITEGRAFT_MODULES="etch"; }
  graft_sync_stack() { :; }
  graft_check_stack_precondition() { return 0; }
  graft_media_sync() { :; }
  graft_deploy_mu_plugin() { :; }
  graft_migrate_post_type_defining_options() { echo "ORDER: register_post_type_options"; }
  graft_prune_previous_run() { :; }
  graft_import_attachments() { :; }
  graft_ensure_importer() { :; }
  graft_export_wxr() { :; }
  graft_integrity_gate() { return 0; }
  graft_import_wxr() { echo "ORDER: import"; }
  graft_fetch_id_map() { :; }
  graft_verify_import_completeness() { return 0; }
  graft_remove_mu_plugin() { :; }
  graft_restore_importer_state() { :; }
  graft_remap_attachment_ids() { :; }
  graft_remap_featured_images() { :; }
  graft_search_replace_domain() { :; }
  graft_migrate_options() { echo "ORDER: migrate_options"; }
  graft_run_module_post_import() { :; }
}

@test "phase_graft calls graft_migrate_post_type_defining_options before graft_import_wxr, and before graft_migrate_options (issue #16 — the fix IS this ordering)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  touch "${run_dir}/backup.complete"
  cat > "${run_dir}/manifest.json" <<'MANIFESTEOF'
{"migrate":{"etch":{"post_types":["fotos"],"option_keys":["etch_cpts"]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}
MANIFESTEOF

  _issue16_stub_everything_but_ordering

  # SITEGRAFT_DRY_RUN=1 so the export step's "did graft_export_wxr actually
  # produce an .xml file" check (unrelated to what this test is about) is
  # skipped rather than failing against the stubbed no-op graft_export_wxr
  # above — same reasoning the MAJOR-4 tests above use SITEGRAFT_DRY_RUN=1
  # for. It has no bearing on the ordering under test: every function this
  # test cares about (graft_migrate_post_type_defining_options,
  # graft_import_wxr, graft_migrate_options) is stubbed to unconditionally
  # echo, dry-run or not.
  SITEGRAFT_DRY_RUN=1
  run phase_graft --profile demo --run "$run_dir" --dry-run
  [ "$status" -eq 0 ]

  local register_line=-1 import_line=-1 migrate_line=-1 i
  for i in "${!lines[@]}"; do
    case "${lines[$i]}" in
      "ORDER: register_post_type_options") register_line=$i ;;
      "ORDER: import") import_line=$i ;;
      "ORDER: migrate_options") migrate_line=$i ;;
    esac
  done
  [ "$register_line" -ge 0 ]
  [ "$import_line" -ge 0 ]
  [ "$migrate_line" -ge 0 ]
  [ "$register_line" -lt "$import_line" ]
  [ "$import_line" -lt "$migrate_line" ]
}

# --- BLOCKER (issue #16 fix-pack review, Viktor): moving domain_from/
# domain_to and graft_verify_domain_remap_usable's own `|| return 1` ahead
# of `SITEGRAFT_GRAFT_RUN_DIR="$run_dir"; trap _graft_exit_trap EXIT` (as
# the fix-pack's first draft did, to give the new
# graft_migrate_post_type_defining_options consumer domain_from/domain_to
# in time) would disarm mu-plugin cleanup on this exact refusal path: a
# `return 1` before the trap is installed skips the trap entirely, so a
# mapping mu-plugin already live on B from an earlier, interrupted run
# stays there UNWATCHED — precisely what issue #54's trap exists to
# prevent. Reproduced live by the reviewer against that first draft
# (RESULT=trap-DID-NOT-fire) before the trap was moved back above the
# domain block. This test is the regression guard: mu_plugin.done present,
# mu_cleanup.done absent (a genuinely live, unwatched mu-plugin — the exact
# state issue #54 is about), and a real, reachable domain-guard refusal
# (issue #73: domain_from real, domain_to the literal 'unknown').
_issue16_stub_everything_but_trap_and_domain_check() {
  profile_load() {
    SITE_A_ALIAS=a; SITE_B_ALIAS=b
    unset SITE_A_SSH_HOST SITE_B_SSH_HOST SITE_B_WP_PATH
    return 0
  }
  modules_discover() { SITEGRAFT_MODULES=""; }
  graft_sync_stack() { echo "STUB: graft_sync_stack called -- should NOT happen, the domain guard must abort before this"; }
  graft_check_stack_precondition() { echo "STUB: graft_check_stack_precondition called -- should NOT happen"; return 0; }
  graft_media_sync() { echo "STUB: graft_media_sync called -- should NOT happen"; }
  graft_deploy_mu_plugin() { echo "STUB: graft_deploy_mu_plugin called -- should NOT happen"; }
  graft_migrate_post_type_defining_options() { echo "STUB: graft_migrate_post_type_defining_options called -- should NOT happen"; }
  graft_prune_previous_run() { echo "STUB: graft_prune_previous_run called -- should NOT happen"; }
  graft_import_attachments() { echo "STUB: graft_import_attachments called -- should NOT happen"; }
  graft_ensure_importer() { echo "STUB: graft_ensure_importer called -- should NOT happen"; }
  graft_export_wxr() { echo "STUB: graft_export_wxr called -- should NOT happen"; }
  graft_import_wxr() { echo "STUB: graft_import_wxr called -- should NOT happen"; }
  graft_search_replace_domain() { echo "STUB: graft_search_replace_domain called -- should NOT happen, the top-level guard must abort before this"; }
  graft_migrate_options() { echo "STUB: graft_migrate_options called -- should NOT happen, the top-level guard must abort before this"; }
  graft_run_module_post_import() { echo "STUB: graft_run_module_post_import called -- should NOT happen"; }
  # The one function under test: a real, interrupted-run mapping mu-plugin
  # actually gets torn off B when the trap fires.
  graft_remove_mu_plugin() { echo "CLEANUP: mu-plugin removed from B"; }
}

@test "phase_graft's domain-remap refusal still runs mu-plugin cleanup — the trap must be armed BEFORE the domain guard can return 1 (issue #16 fix-pack, BLOCKER)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  touch "${run_dir}/backup.complete"
  # domain_from real, domain_to the literal 'unknown' -- issue #73's own
  # broken-remap reproduction, guaranteed to make
  # graft_verify_domain_remap_usable refuse.
  cat > "${run_dir}/manifest.json" <<'MANIFESTEOF'
{"migrate":{"core-wp":{"post_types":["page"],"option_keys":["show_on_front"]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"https://a.example.com","to":"unknown"}}}
MANIFESTEOF
  # A mapping mu-plugin from an earlier, killed-mid-run pass: deployed,
  # never cleaned up. This is the ONLY marker set -- every step this test
  # stubs is stubbed to prove it is NEVER reached, not to let it "complete".
  graft_mark_step "$run_dir" mu_plugin
  [ -e "${run_dir}/graft.mu_plugin.done" ]
  [ ! -e "${run_dir}/graft.mu_cleanup.done" ]

  _issue16_stub_everything_but_trap_and_domain_check

  run phase_graft --profile demo --run "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]] || false
  # The actual regression assertion: cleanup ran despite the refusal.
  [[ "$output" == *"CLEANUP: mu-plugin removed from B"* ]] || false
  # And nothing past the domain guard was ever reached.
  [[ "$output" != *"-- should NOT happen"* ]] || false
  # _graft_exit_trap's own documented behavior on this branch: CLEAR the
  # deploy marker (not mark cleanup done) since the mu-plugin was just
  # taken off B while the run is incomplete -- see that function's own
  # comment for why marking it "done" instead would be the wrong lie.
  [ ! -e "${run_dir}/graft.mu_plugin.done" ]
  [ ! -e "${run_dir}/graft.mu_cleanup.done" ]
}
