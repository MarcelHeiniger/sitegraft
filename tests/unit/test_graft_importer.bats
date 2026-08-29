# tests/unit/test_graft_importer.bats — graft_restore_importer_state (design
# doc §6.4 step 6 / review finding A7): puts wordpress-importer back exactly
# how it was found on B before graft installed/activated it.
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_restore_importer_state does nothing if no pre-state file was recorded" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  SITEGRAFT_DRY_RUN=1
  run graft_restore_importer_state "$run_dir"
  [ "$status" -eq 0 ]
}

@test "graft_restore_importer_state uninstalls the importer if it was absent before graft" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf 'absent\n' > "${run_dir}/.wordpress-importer-pre-state"
  SITEGRAFT_DRY_RUN=1
  run graft_restore_importer_state "$run_dir"
  [[ "$output" == *"plugin uninstall wordpress-importer"* ]]
}

@test "graft_restore_importer_state deactivates the importer if it was installed but inactive before graft" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf 'installed\ninactive\n' > "${run_dir}/.wordpress-importer-pre-state"
  SITEGRAFT_DRY_RUN=1
  run graft_restore_importer_state "$run_dir"
  [[ "$output" == *"plugin deactivate wordpress-importer"* ]] || false
  [[ "$output" != *"uninstall"* ]]
}

@test "graft_restore_importer_state leaves the importer alone if it was already installed and active before graft" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf 'installed\nactive\n' > "${run_dir}/.wordpress-importer-pre-state"
  SITEGRAFT_DRY_RUN=1
  run graft_restore_importer_state "$run_dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- issue #63, case 1: graft_ensure_importer's own pre-state write --------
# phase_graft wires this behind `graft_step_done ... importer_setup || {
# graft_ensure_importer ...; graft_mark_step ... }` (same test file's own
# sibling suite, test_graft_phase_wiring.bats), so a --dry-run against a run
# directory left behind by a REAL run that recorded state_file and then
# hard-failed before its marker was written (the wp-cli install/activate
# call right after the write failing, under set -euo pipefail) re-enters
# this function exactly like a real resume would.

@test "graft_ensure_importer does not overwrite a real pre-existing pre-state file under --dry-run (issue #63)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local state_file="${run_dir}/.wordpress-importer-pre-state"
  # A genuine prior REAL run determined the importer was absent on B, wrote
  # that, then crashed before marking importer_setup done (the shape #63
  # describes: the marker missing is exactly what lets --dry-run re-enter
  # this function at all).
  printf 'absent\n' > "$state_file"

  # wp_remote itself is not under test here — lib/inventory.sh already
  # routes every call through run_or_echo, so under --dry-run any stub
  # returning 0 stands in for it faithfully (a real wp_remote under
  # --dry-run also always returns 0, regardless of B's actual state — see
  # the fix's own comment in lib/graft.sh for why that's exactly what makes
  # the unguarded write dangerous).
  wp_remote() { :; }

  SITEGRAFT_DRY_RUN=1
  run graft_ensure_importer "$run_dir"
  [ "$status" -eq 0 ]

  [ "$(cat "$state_file")" = "absent" ]
}

@test "graft_ensure_importer still records the real pre-state on disk once dry-run is off (issue #63: a real resume must not be skipped)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local state_file="${run_dir}/.wordpress-importer-pre-state"

  wp_remote() {
    case "$*" in
      *"plugin is-installed"*) return 1 ;;
      *) return 0 ;;
    esac
  }

  unset SITEGRAFT_DRY_RUN
  run graft_ensure_importer "$run_dir"
  [ "$status" -eq 0 ]

  [ "$(cat "$state_file")" = "absent" ]
}
