bats_require_minimum_version 1.5.0

# tests/unit/test_graft_phase_wiring.bats — the marker-file resumability
# mechanism every graft sub-step uses (design doc §6.4: "an interrupted
# graft resumes at the sub-step after the last marker, never from scratch").
setup() {
  load '../../lib/core.sh'
  # lib/backup.sh: graft_local_prefix (lib/graft.sh) is a thin wrapper over
  # _backup_local_exec_prefix, needed by the wrapped-local-B trap cleanup
  # test below (issue #37, BLOCKER-1) — graft.sh itself only ever assumes
  # backup.sh is already sourced (bin/sitegraft's "graft" case does this),
  # same as every other test file that exercises a wrapped-local path
  # (e.g. tests/unit/test_graft_ssh_file_transfer.bats's own setup).
  load '../../lib/backup.sh'
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

# --- issue #37: a wp eval that hard-fails mid-media-step left the pushed
# payload/lib pair on B forever — graft_import_attachments only ever removed
# them (graft_remove_file, twice, right after its own `wp_remote b eval`)
# on the path where that eval SUCCEEDED; under bin/sitegraft's real
# `set -euo pipefail`, a non-zero eval aborts the function before either
# removal runs. The id-remap/domain-remap pair already had exactly this
# problem fixed for them (NIT-3 above, this same trap) when the media step
# was still Task 4.2 shaped; the media step (#30) copied their push/eval/
# remove structure faithfully but landed after that fix and was never added
# to this trap's own cleanup list. Fixed by adding the two fixed,
# predictable media-step filenames to the same unconditional cleanup block.
#
# Real files on a real (bare-local) SITE_B_WP_PATH, not a stubbed
# graft_remove_file — the whole point of this test is that the underlying
# `rm -f` actually runs. SITE_B_SSH_HOST/SITE_B_WP_CMD are unset explicitly
# (not merely never assigned), same reasoning as the dry-run-trap tests
# above: an inherited value would silently change which of
# graft_remove_file's three transfer shapes this test exercises.
@test "_graft_exit_trap removes the media-import payload and lib file left on B when wp eval fails (issue #37)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local site_b_wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  mkdir -p "$site_b_wp_content"
  printf '[{"old":10,"rel_path":"2024/01/a.jpg","title":"a"}]' \
    > "${site_b_wp_content}/sitegraft-media-import-payload.json"
  printf '<?php // stub media-import-functions.php\n' \
    > "${site_b_wp_content}/sitegraft-media-import-functions.php"

  unset SITE_B_SSH_HOST SITE_B_WP_CMD
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"

  SITEGRAFT_GRAFT_RUN_DIR="$run_dir" _graft_exit_trap

  [ ! -e "${site_b_wp_content}/sitegraft-media-import-payload.json" ]
  [ ! -e "${site_b_wp_content}/sitegraft-media-import-functions.php" ]
}

# --- issue #37, BLOCKER-1 (review, fix-pack round 2): graft_import_wxr's own
# wrapped-local-B branch stages A's ENTIRE WXR export under
# "${SITE_B_WP_PATH}/wp-content/sitegraft-import-$$/" and only removes it
# (graft_remove_dir) AFTER its own per-file `wp import` loop finishes. A
# `wp import` that exits non-zero partway through that loop aborts before
# the removal, same shape as the media-import pair just above, and this one
# was never added to the trap's cleanup list at all — the most sensitive
# artifact this trap covers: full post_content/excerpt, authors, and any
# custom field WordPress's own exporter includes, not just IDs and titles.
#
# `$$` is a bash special parameter (the current shell's PID), not a `local`
# — it reads back correctly from inside this trap for the identical reason
# SITEGRAFT_GRAFT_RUN_DIR has to be a plain global above: measured directly,
# `$$` inside this test body and `$$` inside _graft_exit_trap called from
# the SAME test body are the same value, so the exact path graft_import_wxr
# would have computed is reconstructible here with no extra state.
#
# SITE_B_WP_CMD is a real wrapper ("env -- wp") so this exercises the actual
# wrapped-local branch of graft_local_prefix/graft_remove_dir, not the
# bare-local one the sibling test above already covers implicitly.
@test "_graft_exit_trap removes the staged WXR import directory left on a wrapped-local B when wp import fails (issue #37, BLOCKER-1)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local site_b="$BATS_TEST_TMPDIR/site-b"
  local container_dir="${site_b}/wp-content/sitegraft-import-$$"
  mkdir -p "$container_dir"
  printf '<?xml version="1.0"?><rss><channel><wp:wxr_version>1.2</wp:wxr_version><item><wp:post_id>5</wp:post_id><wp:post_type>page</wp:post_type></item></channel></rss>' \
    > "${container_dir}/export.xml"

  unset SITE_B_SSH_HOST
  SITE_B_WP_PATH="$site_b"
  SITE_B_WP_CMD="env -- wp"

  SITEGRAFT_GRAFT_RUN_DIR="$run_dir" _graft_exit_trap

  [ ! -e "$container_dir" ]
}

# --- MINOR (review, fix-pack round 2): every removal in the block above used
# to be a silent `2>/dev/null || true`, indistinguishable from "already
# removed" whether B was reachable or not. B being unreachable is itself one
# of the more likely reasons a graft aborts at all — exactly when a silent
# cleanup attempt is least trustworthy, and precisely when the media payload
# and the WXR export (both now confirmed to carry real content, not just
# IDs) are most likely to still be sitting on B. `leftover` collects what
# could not be removed and reports it once, naming names, instead of the
# trap staying silent about them.
@test "_graft_exit_trap warns, naming what it could not remove, when B is unreachable (issue #37, MINOR: cleanup failure must not be silent)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  unset SITE_B_SSH_HOST SITE_B_WP_CMD
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"

  # Simulates B being unreachable: every removal this trap block attempts
  # fails, regardless of which of graft_remove_file's three transfer shapes
  # it would otherwise take.
  graft_remove_file() { return 1; }
  graft_remove_dir() { return 1; }

  SITEGRAFT_GRAFT_RUN_DIR="$run_dir"
  run _graft_exit_trap

  [[ "$output" == *"sitegraft-id-remap-payload.json"* ]] || false
  [[ "$output" == *"sitegraft-domain-remap-payload.json"* ]] || false
  [[ "$output" == *"sitegraft-content-remap-functions.php"* ]] || false
  [[ "$output" == *"sitegraft-media-import-payload.json"* ]] || false
  [[ "$output" == *"sitegraft-media-import-functions.php"* ]] || false
  [[ "$output" == *"sitegraft-import-"* ]] || false
}

@test "_graft_exit_trap stays silent about cleanup when every removal succeeds (issue #37, MINOR: no false alarms on the happy abort path)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  unset SITE_B_SSH_HOST SITE_B_WP_CMD
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"

  graft_remove_file() { return 0; }
  graft_remove_dir() { return 0; }

  SITEGRAFT_GRAFT_RUN_DIR="$run_dir"
  run _graft_exit_trap

  [[ "$output" != *"could not remove"* ]] || false
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
    # Review, fix-pack round 2 (BLOCKER): SITE_B_WP_PATH was NOT unset here,
    # unlike the two SSH_HOST vars right above it. A real profile_load
    # (lib/profile.sh) exports SITE_B_WP_PATH on every real invocation --
    # this stub REPLACES profile_load, but does not run in a vacuum: if the
    # invoking shell already has SITE_B_WP_PATH set (exported from an
    # earlier real sitegraft run in the same shell, or from whatever
    # environment bats itself inherited), it leaks straight through into
    # these tests. The two BLOCKER-B tests below call the REAL phase_graft,
    # which arms the REAL _graft_exit_trap -- and that trap's own cleanup
    # block (lib/graft.sh) runs unconditionally whenever SITE_B_WP_PATH is
    # non-empty, with no notion of "this is only a test fixture's path".
    # Measured live (same technique the dry-run-trap tests above already
    # document for exactly this class of leak): with SITE_B_WP_PATH
    # exported to a real directory before running this file, `bats
    # tests/unit/test_graft_phase_wiring.bats` deleted real files planted
    # there -- 3 of them on main, 5 once issue #37's fix-pack extended the
    # trap's own cleanup list, growing with every filename that list ever
    # gains. Explicit `unset`, not "just never assigned in this stub" --
    # the whole point is to override whatever the invoking shell already
    # exported, the same reasoning the dry-run-trap tests give for their
    # own explicit unset.
    unset SITE_B_WP_PATH
    return 0
  }
  modules_discover() { SITEGRAFT_MODULES=""; }
  graft_sync_stack() { :; }
  graft_check_stack_precondition() { return 0; }
  graft_media_sync() { :; }
  graft_deploy_mu_plugin() { :; }
  graft_prune_previous_run() {
    echo "STUB: graft_prune_previous_run $*"
    # issue #36 fix-pack, third review round: this loop is what actually
    # proves the prune block's own `rm -f` fired for real BEFORE this
    # stub runs (the rm -f sits ahead of graft_prune_previous_run's own
    # call site in phase_graft, on purpose) -- not merely that
    # prune_will_rerun forced these four steps to rerun regardless.
    # Without it, prune_will_rerun alone made every existing assertion in
    # BOTH MAJOR-4 tests below pass even with the rm -f itself replaced
    # by `if false` (measured for this fix-pack: 38/38 green across every
    # test file in this repo that asserts on these markers, with the
    # rm -f neutered) -- a marker LEFT ON DISK untouched is not the same
    # thing as a marker CLEARED then re-written by the step that reran,
    # and nothing distinguished the two once the flag made the four steps
    # rerun unconditionally either way. $2 is run_dir -- every real and
    # stubbed call site already passes it positionally, unchanged by this
    # addition.
    local _m
    for _m in media_sync import_attachments import fetch_id_map; do
      [ -f "${2}/graft.${_m}.done" ] && echo "MARKER STILL SET AT PRUNE: ${_m}"
    done
    return 0
  }
  # issue #36 fix-pack, second review round: graft_import_attachments and
  # graft_import_wxr ("import") are two of the four steps prune_will_rerun
  # now ALSO forces regardless of dry-run (see phase_graft's own comment on
  # that flag) -- their own message text no longer says "should not
  # happen" unconditionally, since whether that's true now depends on
  # which of the two MAJOR-4 tests below is asking. graft_export_wxr's
  # marker is NOT one of the four the prune-safety rm -f invalidates, so
  # it keeps the "should not happen" wording -- that one stays true in
  # BOTH tests.
  graft_import_attachments() { echo "STUB: graft_import_attachments called"; }
  graft_ensure_importer() { :; }
  graft_export_wxr() { echo "STUB: graft_export_wxr called -- should not happen"; }
  graft_integrity_gate() { return 0; }
  graft_import_wxr() { echo "STUB: graft_import_wxr called"; }
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
  # issue #36 fix-pack, second review round: import_attachments/import DO
  # show themselves running now -- this is the CORRECT, intended behavior
  # (prune_will_rerun forces their preview even though their on-disk
  # marker still reads "done"), not a regression of this test's own
  # original MAJOR-4 point. That point survives unchanged above: the
  # marker FILES are untouched. What changed is that a dry-run preview
  # now tells the truth about what the matching real run does to these
  # two steps, instead of silently omitting them (issue #36 fix-pack's
  # own BLOCKER-2/NIT). graft_export_wxr is the one step here whose
  # marker this prune-rm -f never invalidates, so it alone must still
  # never run.
  #
  # NOTE (issue #36 fix-pack, third review round): the four assertions
  # below (the two "STUB: ... called" lines here, plus their mirror pair
  # in the sibling real-run test) prove prune_will_rerun fired -- they do
  # NOT, on their own, prove the prune block's own `rm -f` fired, since
  # prune_will_rerun now forces these steps regardless of the on-disk
  # marker either way. Measured: replacing that `rm -f` with `if false`
  # leaves every one of these four assertions (in BOTH tests) green.
  # `[[ "$output" == *"MARKER STILL SET AT PRUNE"* ]]`, below, is the one
  # that actually discriminates the `rm -f` -- see
  # _major4_stub_everything_but_the_marker_block's own comment on
  # graft_prune_previous_run for why.
  [[ "$output" == *"STUB: graft_import_attachments called"* ]] || false
  [[ "$output" == *"STUB: graft_import_wxr called"* ]] || false
  [[ "$output" != *"STUB: graft_export_wxr called"* ]] || false

  # These three are NOT what catches a broken is_dry_run guard on that
  # `rm -f` -- the pre-existing `[ -f "${run_dir}/graft.*.done" ]` pair
  # ABOVE (lines 332-333) does, and bats stops there first. Measured:
  # removing the
  # is_dry_run guard reddens that pair, and these three are never even
  # evaluated. Nor is the reason stated in an earlier draft of this
  # comment true here: under --dry-run graft_mark_step returns early
  # (lib/graft.sh, `is_dry_run && return 0`), so prune_will_rerun's forced
  # reruns cannot re-touch a marker mid-pass -- "present at prune time"
  # and "present at the end" are the same fact in a dry run.
  #
  # What they DO earn: they make the real-run test's negative assertion
  # non-vacuous. Wire this stub to the wrong argument (${9} instead of
  # ${2}) and it silently reports nothing -- the real-run
  # `!= *"MARKER STILL SET AT PRUNE"*` would then pass for the wrong
  # reason, while these positives fail. The two tests cross-check each
  # other's stub wiring; that is why these belong here.
  # fetch_id_map is deliberately absent from this assertion: it was never
  # marked done in this test's own setup (that absence is what forces
  # entry into the block at all), so it can never appear in this stub's
  # "still set" output regardless of the rm -f's own behavior -- asserting
  # on it here would prove nothing about is_dry_run's guard.
  [[ "$output" == *"MARKER STILL SET AT PRUNE: media_sync"* ]] || false
  [[ "$output" == *"MARKER STILL SET AT PRUNE: import_attachments"* ]] || false
  [[ "$output" == *"MARKER STILL SET AT PRUNE: import"* ]] || false
}

@test "phase_graft tells the operator what state B is in when media_sync fails after prune (issue #36, second-reviewer finding)" {
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
  graft_verify_import_completeness() { return 0; }
  # The failure this message exists for: rsync dies (disk full on B, network
  # drop) on a RE-graft, i.e. after prune has already deleted the previous
  # run's attachments and their files.
  # Fails MID-BODY, not on its last command, so this stub reproduces the
  # real hazard's SHAPE: the pull from A dying (rsync exit 23) with
  # execution carrying on to push an empty staging tree to B -- which
  # returned 0, marked the step done, and imported against a stripped B.
  #
  # What this test pins is the CALL SITE's handling of a failing
  # media_sync: the message, the absent marker, and not importing against a
  # stripped B. It does NOT pin graft_media_sync's own `|| return $?`
  # guards -- it cannot, since the real function is never called here
  # (measured: all four guard mutations leave this file at 0 failures).
  # The TWO PULL guards are pinned in tests/unit/test_graft_mediastep.bats,
  # which runs the real function -- one test per branch, local and remote-A.
  # The other two are deliberately not, and measured so: removing
  # graft_push_dir's guard changes nothing because it is the function's LAST
  # command, so its status propagates without it; and `mkdir -p "$staging"`
  # is not a realistic failure on a run dir this process just created. Both
  # mutations leave every test file in the repo at 0 failures, which is the
  # honest reason, not an oversight.
  graft_media_sync() {
    echo "STUB: graft_media_sync called"
    false || return $?
    echo "STUB: graft_media_sync PUSHED ANYWAY"
    return 0
  }

  unset SITEGRAFT_DRY_RUN
  run --separate-stderr phase_graft --profile demo --run "$run_dir"

  # Fail closed, and do not mark a step that did not happen.
  [ "$status" -ne 0 ]
  [ ! -f "${run_dir}/graft.media_sync.done" ]
  # The step after it must not have run on a B whose media are gone.
  [[ "$output" != *"STUB: graft_media_sync PUSHED ANYWAY"* ]] || false
  [[ "$output" != *"STUB: graft_import_attachments called"* ]] || false

  # The message itself: a bare rsync error leaves the operator unable to
  # tell "B lost its media permanently" from "B lost its media until you
  # rerun". Say which, and say how.
  [[ "$stderr" == *"deleted by prune"* ]] || false
  [[ "$stderr" == *"Nothing is lost that a resume cannot restore"* ]] || false
  [[ "$stderr" == *"${run_dir}"* ]] || false
  [[ "$stderr" == *"backup"* ]] || false
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
  # phase_graft returns, exactly as they should be. The stubs from
  # _major4_stub_everything_but_the_marker_block (still installed,
  # un-overridden) prove the STEPS THEMSELVES ran again: they only print
  # if genuinely invoked.
  #
  # issue #36 fix-pack, third review round: these two assertions no
  # longer discriminate the `rm -f`'s own effect the way this comment used
  # to claim -- prune_will_rerun now forces import_attachments/import to
  # run regardless of whether the `rm -f` actually cleared their markers,
  # so replacing that `rm -f` with `if false` leaves both of these green
  # too (measured for this fix-pack). What they still DO prove is that
  # phase_graft genuinely entered the prune-rerun block at all (armed
  # prune_will_rerun) rather than skipping it — a real, if narrower,
  # regression guard. The assertion below is the one that actually
  # discriminates the `rm -f`'s own effect.
  [[ "$output" == *"STUB: graft_import_attachments called"* ]] || false
  [[ "$output" == *"STUB: graft_import_wxr called"* ]] || false
  [ -f "${run_dir}/graft.import_attachments.done" ]
  [ -f "${run_dir}/graft.import.done" ]

  # The actual `rm -f`-fired acceptance criterion, and the one this test's
  # own name promises ("DOES clear real markers"): by the moment
  # graft_prune_previous_run's stub runs, the `rm -f` immediately above its
  # call site in phase_graft must already have removed all three markers
  # this test pre-marked (media_sync/import_attachments/import) for real —
  # none of them may still be readable as "still set" at that exact point,
  # regardless of prune_will_rerun re-writing them moments later via each
  # step's own graft_mark_step. Confirmed for this fix-pack: replacing the
  # `rm -f` with `if false` makes this assertion fail while every
  # assertion above it (including the two STUB lines) stays green — this
  # is the one that actually catches that mutation, and the reason the
  # `rm -f` is not redundant with prune_will_rerun despite the two
  # overlapping in what they force to rerun within a single phase_graft
  # call (see phase_graft's own comment on prune_will_rerun for the
  # cross-invocation case this `rm -f` alone still protects: a run killed
  # between the prune block and these four gates, with prune_will_rerun
  # gone the moment that process exits).
  [[ "$output" != *"MARKER STILL SET AT PRUNE"* ]] || false
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
    # Same leak, same fix, as _major4_stub_everything_but_the_marker_block's
    # own profile_load stub above (see its comment for the measured
    # reproduction) -- this stub also replaces profile_load ahead of a REAL
    # phase_graft call below, so SITE_B_WP_PATH needs the same explicit
    # unset, not just SSH_HOST.
    unset SITE_B_WP_PATH
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
    # Same leak, same fix, as _major4_stub_everything_but_the_marker_block's
    # own profile_load stub above (see its comment for the measured
    # reproduction) -- this stub also replaces profile_load ahead of a REAL
    # phase_graft call below, so SITE_B_WP_PATH needs the same explicit
    # unset, not just SSH_HOST.
    unset SITE_B_WP_PATH
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

# --- Issue #36: graft_media_sync (rsync --ignore-existing, never overwrite
# a file already on B) used to run near the very top of phase_graft, well
# before graft_prune_previous_run several steps below. Prune's own
# `wp post delete --force` on a previously-migrated attachment deletes that
# attachment's underlying FILE as a side effect (verified live against a
# disposable site -- see the issue's own DDEV reproduction). In that order,
# a SECOND graft against a target that already carries a first graft's
# attachments was silently destructive: media_sync saw every file already
# present and skipped all of them, prune then deleted every one of those
# same files for real, and import_attachments found nothing left on disk to
# register. The fix is this ordering -- prune, THEN media_sync, THEN
# import_attachments -- proven directly here rather than trusted from
# graft_media_sync/graft_prune_previous_run's own unit tests (which cover
# their internal behavior but not WHERE phase_graft calls them), the same
# way the sibling issue #16 test above proves its own reordering fix at
# this exact call-site level.
_issue36_stub_everything_but_ordering() {
  profile_load() {
    SITE_A_ALIAS=a; SITE_B_ALIAS=b
    unset SITE_A_SSH_HOST SITE_B_SSH_HOST
    # Same leak, same fix, as _major4_stub_everything_but_the_marker_block's
    # own profile_load stub above (see its comment for the measured
    # reproduction) -- this stub also replaces profile_load ahead of a REAL
    # phase_graft call below, so SITE_B_WP_PATH needs the same explicit
    # unset, not just SSH_HOST.
    unset SITE_B_WP_PATH
    return 0
  }
  modules_discover() { SITEGRAFT_MODULES=""; }
  graft_sync_stack() { :; }
  graft_check_stack_precondition() { return 0; }
  graft_deploy_mu_plugin() { :; }
  graft_migrate_post_type_defining_options() { :; }
  graft_prune_previous_run() { echo "ORDER: prune"; }
  graft_media_sync() { echo "ORDER: media_sync"; }
  graft_import_attachments() { echo "ORDER: import_attachments"; }
  graft_ensure_importer() { :; }
  graft_export_wxr() { :; }
  graft_integrity_gate() { return 0; }
  # import/fetch_id_map echo too (second review round, issue #36 fix-pack):
  # the SAME `rm -f` that invalidates media_sync.done also invalidates
  # import_attachments.done, import.done and fetch_id_map.done -- these
  # two are the other markers that pattern covers. Existing callers of
  # this stub don't assert on their absence, only on prune/media_sync/
  # import_attachments' relative order, so echoing here is additive.
  graft_import_wxr() { echo "ORDER: import"; }
  graft_fetch_id_map() { echo "ORDER: fetch_id_map"; }
  graft_verify_import_completeness() { return 0; }
  graft_remove_mu_plugin() { :; }
  graft_restore_importer_state() { :; }
  graft_remap_attachment_ids() { :; }
  graft_remap_featured_images() { :; }
  graft_search_replace_domain() { :; }
  graft_migrate_options() { :; }
  graft_run_module_post_import() { :; }
}

@test "phase_graft calls graft_prune_previous_run, then graft_media_sync, then graft_import_attachments, in that order (issue #36 — the fix IS this ordering)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  touch "${run_dir}/backup.complete"
  cat > "${run_dir}/manifest.json" <<'MANIFESTEOF'
{"migrate":{"core-wp":{"post_types":["page","attachment"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}
MANIFESTEOF

  _issue36_stub_everything_but_ordering

  # SITEGRAFT_DRY_RUN=1 for the same reason the issue #16 ordering test
  # above uses it: the export step's "did graft_export_wxr actually produce
  # an .xml file" check (unrelated to what this test is about) is skipped
  # rather than failing against the stubbed no-op graft_export_wxr. It has
  # no bearing on the ordering under test: every function this test cares
  # about is stubbed to unconditionally echo, dry-run or not.
  SITEGRAFT_DRY_RUN=1
  run phase_graft --profile demo --run "$run_dir" --dry-run
  [ "$status" -eq 0 ]

  local prune_line=-1 media_sync_line=-1 import_attachments_line=-1 i
  for i in "${!lines[@]}"; do
    case "${lines[$i]}" in
      "ORDER: prune") prune_line=$i ;;
      "ORDER: media_sync") media_sync_line=$i ;;
      "ORDER: import_attachments") import_attachments_line=$i ;;
    esac
  done
  [ "$prune_line" -ge 0 ]
  [ "$media_sync_line" -ge 0 ]
  [ "$import_attachments_line" -ge 0 ]
  [ "$prune_line" -lt "$media_sync_line" ]
  [ "$media_sync_line" -lt "$import_attachments_line" ]
}

@test "phase_graft's dry-run preview shows media_sync rerunning whenever prune is about to rerun, matching what the real run does (issue #36 fix-pack, BLOCKED-2)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  touch "${run_dir}/backup.complete"
  cat > "${run_dir}/manifest.json" <<'MANIFESTEOF'
{"migrate":{"core-wp":{"post_types":["page","attachment"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}
MANIFESTEOF

  _issue36_stub_everything_but_ordering

  # Simulates a resume: an earlier REAL pass got as far as media_sync and
  # prune (both marked done for real) but never finished import_attachments
  # -- so graft_safety_step_done's own gate reads prune as "not really
  # done" (import_attachments is a consumer) and reruns it.
  graft_mark_step "$run_dir" prune
  graft_mark_step "$run_dir" media_sync

  SITEGRAFT_DRY_RUN=1
  run phase_graft --profile demo --run "$run_dir" --dry-run
  [ "$status" -eq 0 ]

  local prune_line=-1 media_sync_line=-1 i
  for i in "${!lines[@]}"; do
    case "${lines[$i]}" in
      "ORDER: prune") prune_line=$i ;;
      "ORDER: media_sync") media_sync_line=$i ;;
    esac
  done
  [ "$prune_line" -ge 0 ]
  # The acceptance criterion: media_sync's dry-run preview must show it
  # rerunning too, even though its on-disk marker (set above) still says
  # "done" -- exactly matching what a REAL (non-dry-run) pass through this
  # same on-disk state would do (clear the marker for real, then rerun).
  # Before the fix this stayed -1: the `rm -f` that would have cleared
  # media_sync.done is guarded by `is_dry_run`, so under --dry-run the
  # marker is never cleared and this step is silently skipped from the
  # preview -- a dry-run under-reporting what the real run will do, the
  # same class of bug MAJOR-B (above) already fixed once for
  # graft_mark_step, just in the opposite direction here (an operator
  # reading this preview would not be told media_sync -- the expensive
  # step -- reruns).
  [ "$media_sync_line" -ge 0 ]
  [ "$prune_line" -lt "$media_sync_line" ]
}

@test "phase_graft's dry-run preview and a real run agree on ALL FOUR markers the prune rm -f invalidates -- media_sync, import_attachments, import, fetch_id_map (issue #36 fix-pack, second review round)" {
  local manifest_json='{"migrate":{"core-wp":{"post_types":["page","attachment"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}'

  # Every marker EXCEPT fetch_id_map pre-marked done, on BOTH run_dirs --
  # simulating a prior pass that completed everything through `import` but
  # was interrupted before fetch_id_map. fetch_id_map missing is what
  # makes graft_safety_step_done's own gate read prune as "not really
  # done" (fetch_id_map is one of its consumers) and enter the rerun
  # block -- the SAME block whose `rm -f` invalidates media_sync.done,
  # import_attachments.done, import.done and fetch_id_map.done together.
  local step

  # --- dry-run pass ---
  local run_dir_dry="$BATS_TEST_TMPDIR/run-dry"
  mkdir -p "$run_dir_dry"
  touch "${run_dir_dry}/backup.complete"
  printf '%s' "$manifest_json" > "${run_dir_dry}/manifest.json"
  for step in stack_sync mu_plugin prune media_sync import_attachments importer_setup export import; do
    touch "${run_dir_dry}/graft.${step}.done"
  done

  _issue36_stub_everything_but_ordering

  SITEGRAFT_DRY_RUN=1
  run phase_graft --profile demo --run "$run_dir_dry" --dry-run
  [ "$status" -eq 0 ]
  local dry_output="$output"

  # --- real pass, identical setup, fresh run_dir ---
  local run_dir_real="$BATS_TEST_TMPDIR/run-real"
  mkdir -p "$run_dir_real"
  touch "${run_dir_real}/backup.complete"
  printf '%s' "$manifest_json" > "${run_dir_real}/manifest.json"
  for step in stack_sync mu_plugin prune media_sync import_attachments importer_setup export import; do
    touch "${run_dir_real}/graft.${step}.done"
  done

  unset SITEGRAFT_DRY_RUN
  run phase_graft --profile demo --run "$run_dir_real"
  [ "$status" -eq 0 ]
  local real_output="$output"

  # The acceptance criterion: the SAME four markers this `rm -f` invalidates
  # rerun under BOTH modes, not a subset under one and all four under the
  # other. Before this fix-pack's second review round, only media_sync had
  # the prune_will_rerun treatment: the dry-run preview showed
  # prune+media_sync+fetch_id_map (the last one only because it was left
  # genuinely un-marked here, to force entry into the rerun block, not
  # because its own gate was fixed yet) while OMITTING import_attachments
  # and import entirely -- an operator reading that preview would not be
  # told two of the four steps the real run is about to redo. Mutation-
  # tested for this fix-pack: reverting import_attachments'/import's own
  # gates back to a bare `graft_step_done` (leaving only media_sync's
  # fixed) reproduces exactly that asymmetry and fails this loop at
  # import_attachments on the dry-run side.
  local name
  for name in prune media_sync import_attachments import fetch_id_map; do
    [[ "$dry_output" == *"ORDER: ${name}"* ]] || false
    [[ "$real_output" == *"ORDER: ${name}"* ]] || false
  done
}
