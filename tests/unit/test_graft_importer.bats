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
  [[ "$output" == *"plugin deactivate wordpress-importer"* ]]
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
