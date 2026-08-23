# tests/unit/test_plan.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  load '../../lib/inventory.sh'
  load '../../lib/manifest.sh'
  load '../../lib/plan.sh'
}

# Every scan_b fixture below carries `table_prefix` and `tables`, as a real
# scan-b.json does. Without the prefix manifest_compute_unclaimed cannot tell
# a plugin table from a core one and says so on stderr — which bats merges
# into $output, so the fixture's own incompleteness would surface as a jq
# parse error rather than as the behaviour under test.
@test "manifest_compute_unclaimed protects a post_type present on B but claimed nowhere" {
  local manifest='{"migrate":{},"protect":{"known":{"post_types":["booking"]}}}'
  local scan_b='{"table_prefix":"wp_","tables":[],"post_types":[{"name":"booking"},{"name":"mystery_cpt"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect._unclaimed.post_types == ["mystery_cpt"]' >/dev/null
}

@test "manifest_compute_unclaimed adds nothing when everything on B is already claimed" {
  local manifest='{"migrate":{},"protect":{"known":{"post_types":["booking"]}}}'
  local scan_b='{"table_prefix":"wp_","tables":[],"post_types":[{"name":"booking"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.post_types == []' >/dev/null
}

@test "manifest_compute_unclaimed also considers post_types already claimed by migrate" {
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":[],"post_types":[{"name":"page"},{"name":"mystery_cpt"}]}'
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
  local scan_b='{"table_prefix":"wp_","tables":[],"post_types":[],"options":[{"option_name":"known_plugin_settings"},{"option_name":"mystery_option"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect._unclaimed.option_keys == ["mystery_option"]' >/dev/null
}

@test "manifest_compute_unclaimed adds no option_keys when everything on B is already claimed" {
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":[],"post_types":[],"options":[{"option_name":"etch_settings"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.option_keys == []' >/dev/null
}

# --- tables. This list used to be left empty on purpose and a test asserted
# that it stayed empty. It no longer does: an empty list meant backup took no
# checksum for anything outside a module, so verify could report "protected
# data unchanged" having compared nothing. See the comment above
# manifest_compute_unclaimed.
@test "manifest_compute_unclaimed lists a table on B that no module claims" {
  local manifest='{"migrate":{},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":["wp_amelia_appointments"],"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect._unclaimed.tables == ["wp_amelia_appointments"]' >/dev/null
}

@test "manifest_compute_unclaimed excludes a table a module already claims by suffix" {
  local manifest='{"migrate":{},"protect":{"amelia":{"tables":["amelia_appointments"]}}}'
  local scan_b='{"table_prefix":"wp_","tables":["wp_amelia_appointments","wp_other_plugin"],"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.tables == ["wp_other_plugin"]' >/dev/null
}

@test "manifest_compute_unclaimed excludes the core tables graft itself writes" {
  local manifest='{"migrate":{},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":["wp_posts","wp_postmeta","wp_options","wp_terms","wp_termmeta","wp_term_taxonomy","wp_term_relationships","wp_someplugin"],"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.tables == ["wp_someplugin"]' >/dev/null
}

@test "manifest_compute_unclaimed keeps users and comments tables, which graft never writes" {
  local manifest='{"migrate":{},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":["wp_users","wp_comments"],"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.tables == ["wp_users","wp_comments"]' >/dev/null
}

# Fail safe, not silent: without a prefix a plugin table cannot be told from a
# core one, so the list stays empty AND the operator is told why.
@test "manifest_compute_unclaimed leaves tables empty and warns when the scan has no table_prefix" {
  local manifest='{"migrate":{},"protect":{}}'
  local scan_b='{"tables":["wp_amelia_appointments"],"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no table_prefix"* ]]
  # Take the JSON from its opening brace onwards. bats merges stderr into
  # $output, so the colourised warning is prepended — and it cannot be
  # stripped by matching a leading "[" (it starts with an ANSI escape) nor by
  # taking the last line (the JSON is pretty-printed over several).
  echo "$output" | awk '/^\{/{f=1} f' | jq -e '.protect._unclaimed.tables == []' >/dev/null
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

# --- plan_defaults: dynamic selections and option-key exclusions (issues
# #13/#15/#16, docs/decisions/0007-module-dynamic-selections.md). Asserted
# through plan_defaults rather than through module_selection alone, because
# the manifest is what graft and verify actually read — a mechanism that
# works in isolation but never reaches the manifest fixes nothing.
_plan_dynamic_scans() {
  cat > "$BATS_TEST_TMPDIR/a.json" <<'EOF'
{"plugins":[{"name":"demo","version":"1.0"}],
 "active_theme":{"stylesheet":"a-child-theme"},
 "post_types":[{"name":"page"},{"name":"fotos"}],
 "options":[{"option_name":"demo_settings"},{"option_name":"demo_license_key"},{"option_name":"demo_ai_api_key"}],
 "tables":[],"table_prefix":"wp_"}
EOF
  cat > "$BATS_TEST_TMPDIR/b.json" <<'EOF'
{"plugins":[],"active_theme":{"stylesheet":"b-theme"},
 "post_types":[{"name":"page"}],"options":[],"tables":[],"table_prefix":"wp_"}
EOF
}

_plan_dynamic_module() {
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/demo.sh"
  modules_discover
  _plan_dynamic_scans
}

@test "plan_defaults keeps a module's excluded option keys out of the manifest even when its list is a broad prefix (#13)" {
  _plan_dynamic_module <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { jq -e '.plugins[]? | select(.name == "demo")' "$1" >/dev/null 2>&1; }
demo_option_keys_dynamic() { jq -r '.options[]?.option_name | select(startswith("demo_"))' "$1"; }
demo_option_keys_exclude() { printf 'demo_license_*\ndemo_*_api_key\n'; }
EOF
  run plan_defaults "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.demo.option_keys == ["demo_settings"]' >/dev/null
}

@test "plan_defaults puts a dynamic, scan-derived option key into migrate (#15)" {
  _plan_dynamic_module <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { jq -e '.plugins[]? | select(.name == "demo")' "$1" >/dev/null 2>&1; }
demo_option_keys() { printf 'demo_settings\n'; }
demo_option_keys_dynamic() { printf 'theme_mods_%s\n' "$(jq -r '.active_theme.stylesheet' "$1")"; }
EOF
  run plan_defaults "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -eq 0 ]
  # A's theme slug, not B's: a module bound for migrate is resolved against scan A.
  echo "$output" | jq -e '.migrate.demo.option_keys | index("theme_mods_a-child-theme")' >/dev/null
  echo "$output" | jq -e '.migrate.demo.option_keys | index("theme_mods_b-theme") | not' >/dev/null
}

@test "plan_defaults puts dynamic, scan-derived post types into migrate (#16)" {
  _plan_dynamic_module <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { jq -e '.plugins[]? | select(.name == "demo")' "$1" >/dev/null 2>&1; }
demo_post_types() { printf 'wp_block\n'; }
demo_post_types_dynamic() { jq -r '.post_types[]?.name | select(. == "fotos")' "$1"; }
EOF
  run plan_defaults "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.demo.post_types == ["wp_block","fotos"]' >/dev/null
}

@test "a dynamic post type is individually deselectable in plan's interactive selection (#16)" {
  # #16 asks for each such type to appear individually in plan's selection.
  # _plan_apply_selection is the half of that flow that is testable without
  # a TTY: it must classify a dynamic name as a post_type (from the
  # manifest's own list, never from the string's shape) and drop it when the
  # operator deselects it, leaving the rest alone.
  local manifest='{"migrate":{"demo":{"post_types":["wp_block","fotos"],"option_keys":["demo_settings","theme_mods_a-child-theme"]}}}'
  run _plan_apply_selection "$manifest" "$(printf 'demo: wp_block\ndemo: demo_settings\n')"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.demo.post_types == ["wp_block"]' >/dev/null
  echo "$output" | jq -e '.migrate.demo.option_keys == ["demo_settings"]' >/dev/null
}

@test "plan_defaults resolves a protect-only module's dynamic selection against scan B, not scan A" {
  _plan_dynamic_module <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { jq -e '.post_types[]? | select(.name == "page")' "$1" >/dev/null 2>&1; }
demo_tables() { printf 'demo_data\n'; }
demo_option_keys_dynamic() { printf 'theme_mods_%s\n' "$(jq -r '.active_theme.stylesheet' "$1")"; }
EOF
  run plan_defaults "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect.demo.option_keys == ["theme_mods_b-theme"]' >/dev/null
}

@test "plan_defaults fails loudly instead of planning an empty selection when a module's dynamic function errors" {
  _plan_dynamic_module <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { jq -e '.plugins[]? | select(.name == "demo")' "$1" >/dev/null 2>&1; }
demo_post_types() { printf 'wp_block\n'; }
demo_post_types_dynamic() { echo "cannot parse that option" >&2; return 1; }
EOF
  run plan_defaults "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo_post_types_dynamic"* ]] || false
}
