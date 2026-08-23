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

@test "phase_plan fails and never reaches freeze when manifest_compute_unclaimed cannot compute the unclaimed list" {
  # lib/plan.sh's manifest_compute_unclaimed call carries no `|| return 1` of
  # its own (unlike the three calls above it) — the only thing that made a
  # failed assignment here abort the run was bin/sitegraft's `set -e`, which
  # bats' function-call context does not have.
  #
  # A stub that fails with EMPTY stdout would not actually prove this guard:
  # manifest_validate/manifest_freeze already reject an empty/unparsable
  # manifest on their own, so the run would abort either way and the test
  # would pass whether or not `|| return 1` is there — a mutation of this
  # line would go undetected, same defect class as the topology test this
  # fix-pack also had to repair. Instead this stub echoes the ORIGINAL,
  # still-valid manifest (no `_unclaimed` bucket at all) before failing —
  # the realistic failure shape, since manifest_compute_unclaimed's own jq
  # failure happens after several earlier, successful jq calls, not before
  # anything has been computed. That output is syntactically fine and
  # SAILS THROUGH manifest_validate, so only the `|| return 1` on this
  # specific line stands between a failed unclaimed computation and a
  # manifest silently frozen without its default-deny bucket.
  echo '{"post_types":[],"plugins":[],"classic_menus_detected":false,"custom_code_detected":false,"active_theme":{}}' > "${RUN_DIR}/scan-b.json"
  cat > "${RUN_DIR}/prefilled.json" <<'EOF'
{"migrate":{},"protect":{},"clean":{"enabled":false,"post_types":[]},"options":{}}
EOF
  manifest_compute_unclaimed() {
    echo "manifest_compute_unclaimed: simulated failure" >&2
    echo "$1"
    return 1
  }
  SITEGRAFT_MANIFEST_PREFILLED="${RUN_DIR}/prefilled.json" run phase_plan --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ ! -f "${RUN_DIR}/manifest.json" ]
}

@test "phase_plan writes manifest.json chmod 600" {
  echo '{"post_types":[],"plugins":[],"classic_menus_detected":false,"custom_code_detected":false,"active_theme":{}}' > "${RUN_DIR}/scan-b.json"
  cat > "${RUN_DIR}/prefilled.json" <<'EOF'
{"migrate":{},"protect":{},"clean":{"enabled":false,"post_types":[]},"options":{}}
EOF
  SITEGRAFT_MANIFEST_PREFILLED="${RUN_DIR}/prefilled.json" run phase_plan --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  local mode
  mode=$(stat -c '%a' "${RUN_DIR}/manifest.json" 2>/dev/null || stat -f '%Lp' "${RUN_DIR}/manifest.json" 2>/dev/null)
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

# N6 (third review round). "no manifest will be frozen from this run"
# is true and misleading in the same breath: a manifest.json left by an
# EARLIER, successful plan is still sitting in the run directory, still
# `frozen: true`, and `sitegraft graft` reads that file and nothing else. An
# operator who fixes nothing and simply runs `graft` gets the stale plan. The
# file is NOT deleted here (destructive, and the old plan may be exactly what
# they want) — it is named, along with what would happen if they ran graft.
@test "phase_plan warns that a stale frozen manifest.json is still on disk when the plan itself fails (N6)" {
  echo '{"post_types":[],"plugins":[],"classic_menus_detected":false,"custom_code_detected":false,"active_theme":{}}' > "${RUN_DIR}/scan-b.json"
  # A manifest from an earlier, successful plan.
  echo '{"frozen":true,"migrate":{},"protect":{}}' > "${RUN_DIR}/manifest.json"
  cat > "${RUN_DIR}/prefilled.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["page"]}},"clean":{"enabled":false,"post_types":[]},"options":{}}
EOF
  SITEGRAFT_MANIFEST_PREFILLED="${RUN_DIR}/prefilled.json" run phase_plan --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"${RUN_DIR}/manifest.json"* ]] || false
  [[ "$output" == *"graft"* ]] || false
  # Never deleted — that is the operator's call, not this tool's.
  [ -f "${RUN_DIR}/manifest.json" ]
}

@test "phase_plan says nothing about a stale manifest when there is none (N6)" {
  echo '{"post_types":[],"plugins":[],"classic_menus_detected":false,"custom_code_detected":false,"active_theme":{}}' > "${RUN_DIR}/scan-b.json"
  cat > "${RUN_DIR}/prefilled.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["page"]}},"clean":{"enabled":false,"post_types":[]},"options":{}}
EOF
  SITEGRAFT_MANIFEST_PREFILLED="${RUN_DIR}/prefilled.json" run phase_plan --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" != *"still present"* ]] || false
}
