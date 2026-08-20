# tests/unit/test_graft_stack_sync.bats — graft_sync_stack (design doc §6.4
# step 0a / §12): rsync's every manifest.stack.<component> marked
# resolution=copy from A to B using ONLY the manifest's resolved slug_a,
# never a hardcoded/re-derived name — the exact bug (ACSS v4 legacy-slug
# case) Marcel caught in an earlier draft.
#
# lib/backup.sh is loaded alongside lib/graft.sh because graft_sync_stack
# calls _backup_local_exec_prefix (via graft_local_prefix) to decide whether
# a non-ssh transfer needs the wrapped-local (DDEV-style) tar-through-the-
# wrapper path or a plain rsync — none of these tests set a SITE_*_WP_CMD
# wrapper, so they all exercise the plain-rsync (bare-local) branch, which
# is the exact command shape asserted below.
setup() {
  load '../../lib/core.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

@test "graft_sync_stack copies and activates every component marked resolution=copy, skipping resolution=skip" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"etch":{"slug_a":"etch","slug_b":null,"version_a":"2.0","version_b":null,"resolution":"copy"},"theme":{"slug_a":"etch-theme","slug_b":"divi","version_a":"1.0","version_b":"4.2","resolution":"skip"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp-content/plugins/etch"* ]] || false
  [[ "$output" == *"plugin activate etch"* ]] || false
  [[ "$output" != *"divi"* ]]  # resolution=skip must never be touched here
}

@test "graft_sync_stack uses slug_a from the manifest, never a hardcoded name — the ACSS v4 legacy-slug case" {
  # This is the exact bug Marcel caught: an earlier draft hardcoded "automatic-css"
  # for the acss component instead of reading the manifest's resolved slug_a. A
  # plugin under a legacy folder name on B must still be correctly synced FROM
  # A's real (possibly different) resolved path — never guessed from the
  # component's internal key name.
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"acss":{"slug_a":"automatic-css","slug_b":"acss-legacy-slug","version_a":"4.1","version_b":"3.9","resolution":"copy"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp-content/plugins/automatic-css/"* ]] || false  # pulled FROM A under A's resolved slug
  [[ "$output" == *"plugin activate automatic-css"* ]] || false      # activated under that same resolved slug
  [[ "$output" != *"wp-content/plugins/acss/"* ]] || false            # never the internal component key "acss"
  [[ "$output" != *"acss-legacy-slug"* ]]                    # never B's old slug either — A's is authoritative
}

@test "graft_sync_stack reads theme's slug_a the same way as any other component (no special-casing)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"theme":{"slug_a":"etch-theme","slug_b":null,"version_a":"1.0","version_b":null,"resolution":"copy"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" "$manifest"
  [[ "$output" == *"wp-content/themes/etch-theme"* ]] || false
  [[ "$output" == *"theme activate etch-theme"* ]]
}

@test "graft_sync_stack does nothing when the manifest has no stack key" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
