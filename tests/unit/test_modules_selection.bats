# tests/unit/test_modules_selection.bats — module_selection(), the single
# place where a module's claim on post_types/option_keys/tables is expanded
# into the list `plan` puts in the manifest.
#
# Covers three issues that are one piece of work (see
# docs/decisions/0007-module-dynamic-selections.md):
#   #13 — <mod>_option_keys_exclude was documented as the way to carve a
#         license key out of a broad prefix, and nothing ever called it.
#   #15 — a module could not declare theme_mods_<active-theme>, whose key
#         name is only knowable after `scan`.
#   #16 — a module could not declare post types whose names come from a
#         site's own option data (etch_cpts).
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  SCAN="$BATS_TEST_TMPDIR/scan.json"
  echo '{"post_types":[{"name":"page"}],"options":[{"option_name":"demo_settings"}]}' > "$SCAN"
}

_write_module() {
  cat > "$SITEGRAFT_MODULES_DIR/$1.sh"
}

# --- #13: the exclusion is actually applied -------------------------------

@test "module_selection drops a statically-declared option key matching an exclusion glob (#13)" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_option_keys() { printf 'demo_settings\ndemo_license_key\ndemo_license_status\n'; }
demo_option_keys_exclude() { printf 'demo_license_*\n'; }
EOF
  modules_discover
  run module_selection demo option_keys "$SCAN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"demo_settings"* ]] || false
  [[ "$output" != *"demo_license_key"* ]] || false
  [[ "$output" != *"demo_license_status"* ]] || false
}

@test "module_selection expands a broad prefix and still excludes the secrets inside it (#13, the exact scenario the issue describes)" {
  # The module returns everything the scan shows under its prefix — the
  # "broad prefix" style docs/usage.md §5 has always advertised — and relies
  # solely on _option_keys_exclude to keep the secrets out.
  _write_module broad <<'EOF'
broad_name() { echo "Broad"; }
broad_detect() { return 0; }
broad_option_keys_dynamic() {
  jq -r '.options[]?.option_name | select(startswith("broad_"))' "$1"
}
broad_option_keys_exclude() { printf 'broad_license_*\nbroad_*_api_key\n'; }
EOF
  cat > "$BATS_TEST_TMPDIR/broad-scan.json" <<'EOF'
{"post_types":[],"options":[
  {"option_name":"broad_settings"},
  {"option_name":"broad_styles"},
  {"option_name":"broad_license_key"},
  {"option_name":"broad_ai_api_key"},
  {"option_name":"unrelated_option"}
]}
EOF
  modules_discover
  run module_selection broad option_keys "$BATS_TEST_TMPDIR/broad-scan.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"broad_settings"* ]] || false
  [[ "$output" == *"broad_styles"* ]] || false
  [[ "$output" != *"broad_license_key"* ]] || false
  [[ "$output" != *"broad_ai_api_key"* ]] || false
  [[ "$output" != *"unrelated_option"* ]] || false
}

@test "module_selection never applies option-key exclusions to post types" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_post_types() { printf 'demo_license_thing\n'; }
demo_option_keys() { printf 'demo_settings\n'; }
demo_option_keys_exclude() { printf 'demo_license_*\n'; }
EOF
  modules_discover
  run module_selection demo post_types "$SCAN"
  [ "$status" -eq 0 ]
  [ "$output" = "demo_license_thing" ]
}

# --- #15/#16: selections computed from the scan ---------------------------

@test "module_selection merges a dynamic option key computed from the scan into the static list (#15)" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_option_keys() { printf 'demo_settings\n'; }
demo_option_keys_dynamic() { printf 'theme_mods_%s\n' "$(jq -r '.active_theme.stylesheet' "$1")"; }
EOF
  echo '{"active_theme":{"stylesheet":"some-child"},"post_types":[],"options":[]}' > "$SCAN"
  modules_discover
  run module_selection demo option_keys "$SCAN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"demo_settings"* ]] || false
  [[ "$output" == *"theme_mods_some-child"* ]] || false
}

@test "module_selection merges dynamic post types into the static list (#16)" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_post_types() { printf 'wp_block\n'; }
demo_post_types_dynamic() { jq -r '.post_types[]?.name | select(. != "page")' "$1"; }
EOF
  echo '{"post_types":[{"name":"page"},{"name":"fotos"}],"options":[]}' > "$SCAN"
  modules_discover
  run module_selection demo post_types "$SCAN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp_block"* ]] || false
  [[ "$output" == *"fotos"* ]] || false
}

@test "module_selection supports a dynamic tables list too, for contract uniformity" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_tables() { printf 'demo_static\n'; }
demo_tables_dynamic() { printf 'demo_dynamic\n'; }
EOF
  modules_discover
  run module_selection demo tables "$SCAN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"demo_static"* ]] || false
  [[ "$output" == *"demo_dynamic"* ]] || false
}

@test "module_selection hands the scan path it was given to the dynamic function" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_option_keys() { printf 'demo_settings\n'; }
demo_option_keys_dynamic() { printf 'saw_%s\n' "$(basename "$1")"; }
EOF
  modules_discover
  run module_selection demo option_keys "$BATS_TEST_TMPDIR/scan.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"saw_scan.json"* ]] || false
}

@test "module_selection de-duplicates a name declared both statically and dynamically" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_option_keys() { printf 'demo_settings\n'; }
demo_option_keys_dynamic() { printf 'demo_settings\ndemo_extra\n'; }
EOF
  modules_discover
  run module_selection demo option_keys "$SCAN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^demo_settings$')" = "1" ]
  [[ "$output" == *"demo_extra"* ]] || false
}

@test "module_selection returns nothing, successfully, for a kind the module does not declare at all" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_option_keys() { printf 'demo_settings\n'; }
EOF
  modules_discover
  run module_selection demo tables "$SCAN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- fail closed ----------------------------------------------------------
#
# "returned nothing" and "could not run" are different answers and must not
# come out the same way (CLAUDE.md: a check must distinguish "verified true"
# from "could not verify").

@test "module_selection succeeds with an empty list when a dynamic function legitimately finds nothing" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_option_keys() { printf 'demo_settings\n'; }
demo_option_keys_dynamic() { return 0; }
EOF
  modules_discover
  run module_selection demo option_keys "$SCAN"
  [ "$status" -eq 0 ]
  [ "$output" = "demo_settings" ]
}

@test "module_selection fails loudly when a dynamic function exits non-zero" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_option_keys() { printf 'demo_settings\n'; }
demo_option_keys_dynamic() { echo "boom" >&2; return 3; }
EOF
  modules_discover
  run module_selection demo option_keys "$SCAN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo_option_keys_dynamic"* ]] || false
  # B3 (third review round): the message used to say "exited 0" for
  # EVERY failure, because `rc=$?` sat inside an `if ! cmd; then` body and so
  # read the status of the `!`, not of the function. A message that reports a
  # failure and names exit 0 as its cause is the bookkeeping lie CLAUDE.md's
  # first rule is about, and no test caught it. This one asserts the number.
  [[ "$output" == *"exited 3"* ]] || false
}

@test "module_selection fails loudly when the static function exits non-zero" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_option_keys() { printf 'demo_settings\n'; return 4; }
EOF
  modules_discover
  run module_selection demo option_keys "$SCAN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo_option_keys"* ]] || false
  [[ "$output" == *"exited 4"* ]] || false
}

@test "module_selection fails loudly when the exclusion function itself exits non-zero, rather than migrating unfiltered keys" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_option_keys() { printf 'demo_settings\ndemo_license_key\n'; }
demo_option_keys_exclude() { return 5; }
EOF
  modules_discover
  run module_selection demo option_keys "$SCAN"
  [ "$status" -ne 0 ]
  [[ "$output" != *"demo_license_key"* ]] || false
  [[ "$output" == *"demo_option_keys_exclude"* ]] || false
  [[ "$output" == *"exited 5"* ]] || false
}

@test "module_selection rejects a name carrying a comma or whitespace, which downstream CSV/word-splitting cannot represent" {
  _write_module demo <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { return 0; }
demo_post_types() { printf 'good_cpt\nbad,cpt\n'; }
EOF
  modules_discover
  run module_selection demo post_types "$SCAN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad,cpt"* ]] || false
}

# --- discovery-time contract ---------------------------------------------

@test "modules_discover accepts a module whose only claim is a dynamic one" {
  _write_module dynonly <<'EOF'
dynonly_name() { echo "Dyn Only"; }
dynonly_detect() { return 0; }
dynonly_option_keys_dynamic() { printf 'computed_key\n'; }
EOF
  modules_discover
  [[ " $SITEGRAFT_MODULES " == *" dynonly "* ]] || false
}

@test "modules_discover still rejects a module claiming nothing at all, static or dynamic" {
  _write_module noclaim <<'EOF'
noclaim_name() { echo "No Claim"; }
noclaim_detect() { return 0; }
noclaim_option_keys_exclude() { printf 'anything_*\n'; }
EOF
  modules_discover >/dev/null 2>&1
  [[ " $SITEGRAFT_MODULES " != *" noclaim "* ]]
}
