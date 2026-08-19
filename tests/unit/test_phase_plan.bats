# tests/unit/test_phase_plan.bats — end-to-end phase_plan wiring, driven
# entirely through the non-interactive SITEGRAFT_MANIFEST_PREFILLED path
# (the only way to exercise this without a TTY/gum — same reasoning as the
# DDEV harness, tests/integration/ddev-harness.sh).
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  load '../../lib/inventory.sh'
  load '../../lib/profile.sh'
  load '../../lib/manifest.sh'
  load '../../lib/plan.sh'

  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  mkdir -p "$SITEGRAFT_PROFILES_DIR"
  export SITEGRAFT_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$SITEGRAFT_STATE_DIR"

  cat > "${SITEGRAFT_PROFILES_DIR}/t.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/var/www/b"
SITEGRAFT_STATE_DIR="${SITEGRAFT_STATE_DIR}"
EOF

  RUN_DIR="${SITEGRAFT_STATE_DIR}/t-20260101T000000"
  mkdir -p "$RUN_DIR"
  echo '{"post_types":[],"plugins":[],"classic_menus_detected":false,"active_theme":{}}' > "${RUN_DIR}/scan-a.json"
}

@test "phase_plan freezes a prefilled manifest and computes _unclaimed against scan-b" {
  echo '{"post_types":[{"name":"page"},{"name":"mystery_cpt"}],"plugins":[],"classic_menus_detected":false,"custom_code_detected":false,"active_theme":{}}' > "${RUN_DIR}/scan-b.json"
  cat > "${RUN_DIR}/prefilled.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"],"option_keys":[]}},"protect":{},"clean":{"enabled":false,"post_types":[]},"options":{}}
EOF
  SITEGRAFT_MANIFEST_PREFILLED="${RUN_DIR}/prefilled.json" run phase_plan --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ -f "${RUN_DIR}/manifest.json" ]
  run jq -e '.frozen == true' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
  run jq -e '.protect._unclaimed.post_types == ["mystery_cpt"]' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
}

@test "phase_plan writes manifest.json chmod 600" {
  echo '{"post_types":[],"plugins":[],"classic_menus_detected":false,"custom_code_detected":false,"active_theme":{}}' > "${RUN_DIR}/scan-b.json"
  cat > "${RUN_DIR}/prefilled.json" <<'EOF'
{"migrate":{},"protect":{},"clean":{"enabled":false,"post_types":[]},"options":{}}
EOF
  SITEGRAFT_MANIFEST_PREFILLED="${RUN_DIR}/prefilled.json" run phase_plan --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  local mode
  mode=$(stat -f '%Lp' "${RUN_DIR}/manifest.json" 2>/dev/null || stat -c '%a' "${RUN_DIR}/manifest.json")
  [ "$mode" = "600" ]
}

@test "phase_plan refuses to write a manifest when validation fails even on the prefilled path" {
  echo '{"post_types":[],"plugins":[],"classic_menus_detected":false,"custom_code_detected":false,"active_theme":{}}' > "${RUN_DIR}/scan-b.json"
  cat > "${RUN_DIR}/prefilled.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["page"]}},"clean":{"enabled":false,"post_types":[]},"options":{}}
EOF
  SITEGRAFT_MANIFEST_PREFILLED="${RUN_DIR}/prefilled.json" run phase_plan --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ ! -f "${RUN_DIR}/manifest.json" ]
}

@test "phase_plan fails cleanly when no --run and no prior scan run exists for the profile" {
  rm -rf "$RUN_DIR"
  run phase_plan --profile t
  [ "$status" -eq 1 ]
  [[ "$output" == *"no scan run found"* ]]
}

@test "phase_plan refuses a prefilled manifest that never acknowledged B's custom-code signal (design doc §14, never a silent skip)" {
  echo '{"post_types":[],"plugins":[],"classic_menus_detected":false,"custom_code_detected":true,"custom_code_signals":{"child_theme":true},"active_theme":{}}' > "${RUN_DIR}/scan-b.json"
  cat > "${RUN_DIR}/prefilled.json" <<'EOF'
{"migrate":{},"protect":{},"clean":{"enabled":false,"post_types":[]},"options":{}}
EOF
  SITEGRAFT_MANIFEST_PREFILLED="${RUN_DIR}/prefilled.json" run phase_plan --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ ! -f "${RUN_DIR}/manifest.json" ]
}

@test "phase_plan accepts a prefilled manifest that DOES carry the custom-code acknowledgment" {
  echo '{"post_types":[],"plugins":[],"classic_menus_detected":false,"custom_code_detected":true,"custom_code_signals":{"child_theme":true},"active_theme":{}}' > "${RUN_DIR}/scan-b.json"
  cat > "${RUN_DIR}/prefilled.json" <<'EOF'
{"migrate":{},"protect":{},"clean":{"enabled":false,"post_types":[]},"options":{},"custom_code_review":{"acknowledged":true,"signals":{"child_theme":true}}}
EOF
  SITEGRAFT_MANIFEST_PREFILLED="${RUN_DIR}/prefilled.json" run phase_plan --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  run jq -e '.custom_code_review.acknowledged == true' "${RUN_DIR}/manifest.json"
  [ "$status" -eq 0 ]
}
