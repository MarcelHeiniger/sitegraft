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
  # N1: the actual shipped file (modules/motopress.sh.example, design doc
  # §2/§3.5), copied in — not a re-typed synthetic stand-in. This is a
  # real, complete worked-example module (name/detect/post_types/
  # option_keys/tables/post_import, all matching the §3.2 contract); the
  # only thing under test here is that its .example suffix keeps it from
  # ever being sourced/registered by default.
  cp "${BATS_TEST_DIRNAME}/../../modules/motopress.sh.example" "$SITEGRAFT_MODULES_DIR/motopress.sh.example"
}

@test "modules_discover finds demo-mod but skips _template.sh and the real motopress.sh.example (N1)" {
  modules_discover
  [[ " $SITEGRAFT_MODULES " == *" demo_mod "* ]] || false
  [[ " $SITEGRAFT_MODULES " != *" template "* ]] || false
  [[ " $SITEGRAFT_MODULES " != *" motopress "* ]]
}

@test "modules/motopress.sh.example is itself a valid, complete module once activated (N1)" {
  # Simulates exactly what §3.5 documents as the expected move: copy it to
  # modules/motopress.sh, dropping the .example suffix, to activate it for
  # real. Confirms the shipped worked example genuinely satisfies the
  # module contract (module_validate_contract) rather than merely looking
  # plausible in the design doc's prose.
  cp "${BATS_TEST_DIRNAME}/../../modules/motopress.sh.example" "$SITEGRAFT_MODULES_DIR/motopress.sh"
  modules_discover
  [[ " $SITEGRAFT_MODULES " == *" motopress "* ]] || false
  run module_call motopress name
  [ "$status" -eq 0 ]
  [ "$output" = "MotoPress Hotel Booking" ]
  run module_call motopress post_types
  [ "$status" -eq 0 ]
  [[ "$output" == *"mphb_booking"* ]] || false
  run module_call motopress tables
  [ "$status" -eq 0 ]
  [ "$output" = "mphb_room_type_meta" ]
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
  [[ " $SITEGRAFT_MODULES " != *" broken "* ]] || false
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
