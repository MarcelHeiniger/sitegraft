# tests/unit/test_modules.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/demo-mod.sh" <<'EOF'
demo_mod_name() { echo "Demo Module"; }
demo_mod_detect() { return 0; }
demo_mod_post_types() { printf 'demo_cpt\n'; }
EOF
  cat > "$SITEGRAFT_MODULES_DIR/_template.sh" <<'EOF'
template_name() { echo "should not be loaded"; }
EOF
  cat > "$SITEGRAFT_MODULES_DIR/future.sh.example" <<'EOF'
future_name() { echo "should not be loaded either"; }
EOF
}

@test "modules_discover finds demo-mod but skips _template and .example files" {
  modules_discover
  [[ " $SITEGRAFT_MODULES " == *" demo_mod "* ]]
  [[ " $SITEGRAFT_MODULES " != *" template "* ]]
  [[ " $SITEGRAFT_MODULES " != *" future "* ]]
}

@test "module_has_fn detects an existing function and rejects a missing one" {
  modules_discover
  run module_has_fn demo_mod post_types
  [ "$status" -eq 0 ]
  run module_has_fn demo_mod option_keys
  [ "$status" -eq 1 ]
}

@test "module_call returns the function output when it exists" {
  modules_discover
  run module_call demo_mod post_types
  [ "$status" -eq 0 ]
  [ "$output" = "demo_cpt" ]
}

@test "modules_discover rejects a module missing _name/_detect and does not register it (m2)" {
  cat > "$SITEGRAFT_MODULES_DIR/broken.sh" <<'EOF'
broken_post_types() { printf 'broken_cpt\n'; }
EOF
  # Called directly, not via bats' `run` — `run` executes in a subshell, so
  # the side effect this test inspects (SITEGRAFT_MODULES) would never make
  # it back to this shell regardless of correctness.
  modules_discover >/dev/null 2>&1
  [[ " $SITEGRAFT_MODULES " != *" broken "* ]]
  # The good module in the same directory must still load fine.
  [[ " $SITEGRAFT_MODULES " == *" demo_mod "* ]]
}

@test "modules_discover rejects a module with name/detect but no post_types/option_keys/tables (m2)" {
  cat > "$SITEGRAFT_MODULES_DIR/empty-claim.sh" <<'EOF'
empty_claim_name() { echo "Empty Claim"; }
empty_claim_detect() { return 0; }
EOF
  modules_discover
  [[ " $SITEGRAFT_MODULES " != *" empty_claim "* ]]
}
