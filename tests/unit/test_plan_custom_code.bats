# tests/unit/test_plan_custom_code.bats
bats_require_minimum_version 1.5.0

setup() {
  load '../../lib/core.sh'
  load '../../lib/plan.sh'
}

@test "plan_custom_code_gate passes through untouched when no signal was raised" {
  local manifest='{"frozen":false}'
  local scan_b='{"custom_code_detected":false}'
  run --separate-stderr plan_custom_code_gate "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -e '.custom_code_review // "absent"')" = "\"absent\"" ]
}

@test "plan_custom_code_gate records acknowledged=true and a copy of the signals when confirmed" {
  local manifest='{"frozen":false}'
  local scan_b='{"custom_code_detected":true,"custom_code_signals":{"child_theme":true,"functions_php":{"exists":false},"mu_plugins":[],"snippet_plugins_detected":[]}}'
  _plan_confirm_strong() { return 0; } # simulate the operator acknowledging
  run --separate-stderr plan_custom_code_gate "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.custom_code_review.acknowledged == true and .custom_code_review.signals.child_theme == true' >/dev/null
}

@test "plan_custom_code_gate exits 1 and writes nothing usable when declined" {
  local manifest='{"frozen":false}'
  local scan_b='{"custom_code_detected":true,"custom_code_signals":{"child_theme":true}}'
  _plan_confirm_strong() { return 1; } # simulate the operator declining
  run --separate-stderr plan_custom_code_gate "$manifest" "$scan_b"
  [ "$status" -eq 1 ]
}

# --- plan_custom_code_gate_check_prefilled: the non-interactive counterpart
# used on the SITEGRAFT_MANIFEST_PREFILLED path (phase_plan). Not in the
# plan's own Task 2.5 spec — added because the plan's literal phase_plan
# wiring called the INTERACTIVE gate unconditionally, before the prefilled
# branch, which would block a scripted run (e.g. the DDEV harness, whose B
# fixture DOES trigger custom_code_detected) on a live prompt with no TTY to
# answer it. This is the structural, never-prompting equivalent: it never
# silently skips the check, it just verifies the prefilled manifest already
# carries the acknowledgment instead of asking for one live.
@test "plan_custom_code_gate_check_prefilled passes when scan-b shows no signal, regardless of the manifest" {
  local scan_b="$BATS_TEST_TMPDIR/scan-b.json"
  echo '{"custom_code_detected":false}' > "$scan_b"
  run plan_custom_code_gate_check_prefilled '{"frozen":false}' "$scan_b"
  [ "$status" -eq 0 ]
}

@test "plan_custom_code_gate_check_prefilled passes when scan-b shows a signal AND the manifest already acknowledges it" {
  local scan_b="$BATS_TEST_TMPDIR/scan-b.json"
  echo '{"custom_code_detected":true,"custom_code_signals":{"child_theme":true}}' > "$scan_b"
  local manifest='{"frozen":false,"custom_code_review":{"acknowledged":true,"signals":{"child_theme":true}}}'
  run plan_custom_code_gate_check_prefilled "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
}

@test "plan_custom_code_gate_check_prefilled REFUSES when scan-b shows a signal but the prefilled manifest never acknowledged it (never a silent skip)" {
  local scan_b="$BATS_TEST_TMPDIR/scan-b.json"
  echo '{"custom_code_detected":true,"custom_code_signals":{"child_theme":true}}' > "$scan_b"
  run plan_custom_code_gate_check_prefilled '{"frozen":false}' "$scan_b"
  [ "$status" -eq 1 ]
}

@test "plan_custom_code_gate_check_prefilled REFUSES a manifest with acknowledged=false even when a signal was raised" {
  local scan_b="$BATS_TEST_TMPDIR/scan-b.json"
  echo '{"custom_code_detected":true,"custom_code_signals":{"child_theme":true}}' > "$scan_b"
  local manifest='{"frozen":false,"custom_code_review":{"acknowledged":false}}'
  run plan_custom_code_gate_check_prefilled "$manifest" "$scan_b"
  [ "$status" -eq 1 ]
}
