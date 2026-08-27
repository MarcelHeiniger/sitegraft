# tests/unit/test_graft_post_type_defining_options.bats — issue #16's actual
# fix: graft_migrate_post_type_defining_options (lib/graft.sh). Migrating an
# option that DEFINES a post type (etch_cpts, for Etch) only wins if it
# reaches B before graft_import_wxr runs — graft_migrate_options alone
# migrates it too late (it runs AFTER import, design doc §6.4 step 8), which
# left a real graft reporting wordpress-importer skipped an item instead of
# migrating its content (issue #53's completeness gate is what actually
# caught this on a real site — see modules/etch.sh's own header comment on
# etch_post_type_defining_option_keys for the live-site trace of why this
# ordering matters).
setup() {
  load '../../lib/core.sh'
  load '../../lib/backup.sh'
  load '../../lib/modules.sh'
  load '../../lib/graft.sh'
}

@test "graft_migrate_post_type_defining_options pre-migrates a key a module names via its own _post_type_defining_option_keys hook" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"post_types":["fotos"],"option_keys":["etch_cpts","etch_settings"]}}}'
  etch_post_type_defining_option_keys() { printf 'etch_cpts\n'; }
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      echo '{"fotos":{"slug":"fotos"}}'
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_post_type_defining_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"option update etch_cpts"* ]] || false
  # etch_settings is NOT named by the defining-keys hook -- must not be
  # pre-migrated here (graft_migrate_options, later, still carries it).
  [[ "$output" != *"option update etch_settings"* ]] || false
  [ -f "${run_dir}/option-etch_cpts.value" ]
}

@test "graft_migrate_post_type_defining_options touches nothing for a module with no _post_type_defining_option_keys hook" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"],"option_keys":["show_on_front"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() { echo "STUB: wp_remote called -- should not happen, core-wp declares no defining option"; false; }
  run graft_migrate_post_type_defining_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"STUB: wp_remote called"* ]] || false
}

@test "graft_migrate_post_type_defining_options skips (does not migrate) a defining key the plan did not select for that module, and says so" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  # etch_cpts named by the hook but NOT present in this module's own
  # selected option_keys -- an operator deselected it in `plan`.
  local manifest='{"migrate":{"etch":{"post_types":["fotos"],"option_keys":["etch_settings"]}}}'
  etch_post_type_defining_option_keys() { printf 'etch_cpts\n'; }
  SITEGRAFT_DRY_RUN=1
  wp_remote() { echo "STUB: wp_remote called for $*"; }
  run graft_migrate_post_type_defining_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"STUB: wp_remote called"* ]] || false
  [[ "$output" == *"not pre-migrating it"* ]] || false
  [ ! -f "${run_dir}/option-etch_cpts.value" ]
}

@test "graft_migrate_post_type_defining_options fails loud, not empty, when the module's own hook exits non-zero" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"post_types":["fotos"],"option_keys":["etch_cpts"]}}}'
  etch_post_type_defining_option_keys() { return 3; }
  run graft_migrate_post_type_defining_options "$run_dir" "$manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"etch_post_type_defining_option_keys"* ]] || false
}

@test "graft_migrate_post_type_defining_options uses the exact same domain-remap value rewrite as graft_migrate_options" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"post_types":["fotos"],"option_keys":["etch_cpts"]}}}'
  etch_post_type_defining_option_keys() { printf 'etch_cpts\n'; }
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      echo '"https://a.example.com/fotos"'
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_post_type_defining_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  [ "$(cat "${run_dir}/option-etch_cpts.value")" = '"https://b.example.com/fotos"' ]
}

@test "graft_migrate_post_type_defining_options refuses (issue #73 guard) when domain_from is real but domain_to is broken, before touching any key" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"post_types":["fotos"],"option_keys":["etch_cpts"]}}}'
  etch_post_type_defining_option_keys() { printf 'etch_cpts\n'; }
  wp_remote() { echo "STUB: wp_remote called -- should NOT happen, the top-level #73 guard must abort first"; }
  run graft_migrate_post_type_defining_options "$run_dir" "$manifest" "https://a.example.com" "unknown"
  [ "$status" -ne 0 ]
  [[ "$output" != *"STUB: wp_remote called"* ]] || false
  [[ "$output" == *"unknown"* ]] || false
}

@test "graft_migrate_post_type_defining_options is a no-op (not an error) for a manifest with no modules at all" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{}}'
  run graft_migrate_post_type_defining_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
}
