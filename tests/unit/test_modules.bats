# tests/unit/test_modules.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/demo-mod.sh" <<'EOF'
demo_mod_name() { echo "Demo Module"; }
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
