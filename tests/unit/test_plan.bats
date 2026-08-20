# tests/unit/test_plan.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  load '../../lib/inventory.sh'
  load '../../lib/manifest.sh'
  load '../../lib/plan.sh'
}

@test "manifest_compute_unclaimed protects a post_type present on B but claimed nowhere" {
  local manifest='{"migrate":{},"protect":{"known":{"post_types":["booking"]}}}'
  local scan_b='{"post_types":[{"name":"booking"},{"name":"mystery_cpt"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect._unclaimed.post_types == ["mystery_cpt"]' >/dev/null
}

@test "manifest_compute_unclaimed adds nothing when everything on B is already claimed" {
  local manifest='{"migrate":{},"protect":{"known":{"post_types":["booking"]}}}'
  local scan_b='{"post_types":[{"name":"booking"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.post_types == []' >/dev/null
}

@test "manifest_compute_unclaimed also considers post_types already claimed by migrate" {
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{}}'
  local scan_b='{"post_types":[{"name":"page"},{"name":"mystery_cpt"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.post_types == ["mystery_cpt"]' >/dev/null
}

# --- option_keys coverage: MINOR fix (Viktor's review of PR #2) — design doc
# §3.6 says default-deny covers "post_type, table, OR option key", and
# option_keys is now extended the same way post_types always has been (no
# prefix-resolution issue for options, unlike tables — see the tracked
# comment above manifest_compute_unclaimed for why tables stays [] for now).
@test "manifest_compute_unclaimed protects an option_key present on B but claimed nowhere" {
  local manifest='{"migrate":{},"protect":{"known":{"option_keys":["known_plugin_settings"]}}}'
  local scan_b='{"post_types":[],"options":[{"option_name":"known_plugin_settings"},{"option_name":"mystery_option"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect._unclaimed.option_keys == ["mystery_option"]' >/dev/null
}

@test "manifest_compute_unclaimed adds no option_keys when everything on B is already claimed" {
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}},"protect":{}}'
  local scan_b='{"post_types":[],"options":[{"option_name":"etch_settings"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.option_keys == []' >/dev/null
}

@test "manifest_compute_unclaimed still leaves tables as [] (tracked, not a silent gap — see design doc §3.6)" {
  local manifest='{"migrate":{},"protect":{}}'
  local scan_b='{"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.tables == []' >/dev/null
}

@test "plan_warn_scope_gaps warns about A's classic menus but never about B's, and always exits 0" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"classic_menus_detected":true,"classic_menu_names":["Main Menu"]}' > "$a"
  echo '{"classic_menus_detected":true,"classic_menu_names":["Legacy Menu"]}' > "$b"
  run plan_warn_scope_gaps "$a" "$b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Main Menu"* ]] || false
  [[ "$output" != *"Legacy Menu"* ]]
}

@test "plan_warn_scope_gaps says nothing when A has no classic menus" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"classic_menus_detected":false}' > "$a"
  echo '{"classic_menus_detected":true,"classic_menu_names":["Legacy Menu"]}' > "$b"
  run plan_warn_scope_gaps "$a" "$b"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- plan_defaults: not covered by the plan's own bats spec (called out there
# as "not a pure function... tested separately") — added here for real
# coverage of the module-dispatch logic itself, using fabricated modules the
# same way Task 2.4's test file does (SITEGRAFT_MODULES_DIR override).
_plan_defaults_setup_modules() {
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/etch.sh" <<'EOF'
etch_name() { echo "Etch"; }
etch_detect() { jq -e '.plugins[] | select(.name == "etch")' "$1" >/dev/null 2>&1; }
etch_post_types() { printf 'etch_cfs\netch_cpts\n'; }
etch_option_keys() { printf 'etch_settings\n'; }
EOF
  cat > "$SITEGRAFT_MODULES_DIR/fakebooking.sh" <<'EOF'
fakebooking_name() { echo "Fake Booking"; }
fakebooking_detect() { jq -e '.plugins[] | select(.name == "fake-booking")' "$1" >/dev/null 2>&1; }
fakebooking_post_types() { printf 'fake_reservation\n'; }
fakebooking_tables() { printf 'fakebooking_reservations\n'; }
fakebooking_option_keys() { printf 'fakebooking_settings\n'; }
EOF
  modules_discover
}

@test "plan_defaults migrates a module detected on A and protects one detected only on B" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[{"name":"etch","version":"2.0"}],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[{"name":"fake-booking","version":"1.0"}],"post_types":[{"name":"fake_reservation"}],"options":[],"tables":["fakebooking_reservations"]}' > "$b"
  run plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.etch.post_types == ["etch_cfs","etch_cpts"]' >/dev/null
  echo "$output" | jq -e '.migrate.etch.option_keys == ["etch_settings"]' >/dev/null
  echo "$output" | jq -e '.protect.fakebooking.post_types == ["fake_reservation"]' >/dev/null
  echo "$output" | jq -e '.protect.fakebooking.tables == ["fakebooking_reservations"]' >/dev/null
  # A module detected on A never also lands in protect for the same run.
  echo "$output" | jq -e '.protect.etch == null' >/dev/null
}

@test "plan_defaults leaves both buckets empty when no module is detected on either site" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$b"
  run plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate == {}' >/dev/null
  echo "$output" | jq -e '.protect == {}' >/dev/null
}
