# tests/unit/test_plan_stack.bats
bats_require_minimum_version 1.5.0

setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  load '../../lib/inventory.sh'
  load '../../lib/manifest.sh'
  load '../../lib/plan.sh'
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  # module_validate_contract (lib/modules.sh, Step 1) requires _name/_detect
  # and at least one of _post_types/_option_keys/_tables — a module declaring
  # ONLY _stack_candidates (as the plan's own Task 2.4 test fixture did) is
  # rejected at discovery time and never registered, which made
  # inventory_stack_diff silently skip it entirely (found via TDD: the tests
  # below failed with .stack.etch == null, not the assertion they were meant
  # to check). Minimal but contract-complete fixtures below.
  cat > "$SITEGRAFT_MODULES_DIR/acss.sh" <<'EOF'
acss_name() { echo "Automatic.css"; }
acss_detect() { jq -e '.plugins[]? | select(.name == "automatic-css" or .name == "acss-legacy-slug")' "$1" >/dev/null 2>&1; }
acss_option_keys() { printf 'automatic_css_settings\n'; }
acss_stack_candidates() { printf 'automatic-css\nacss-legacy-slug\n'; }
EOF
  cat > "$SITEGRAFT_MODULES_DIR/etch.sh" <<'EOF'
etch_name() { echo "Etch"; }
etch_detect() { jq -e '.plugins[]? | select(.name == "etch")' "$1" >/dev/null 2>&1; }
etch_option_keys() { printf 'etch_settings\n'; }
etch_stack_candidates() { printf 'etch\n'; }
EOF
  modules_discover
}

@test "plan_resolve_stack records resolution=copy for an absent component when confirmed" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"etch","version":"2.0"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$b"
  _plan_confirm() { return 0; }        # simulate the operator accepting
  _plan_confirm_strong() { return 1; } # not exercised in this case
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run --separate-stderr plan_resolve_stack "$manifest" "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.stack.etch.resolution == "copy" and .stack.etch.slug_a == "etch" and .stack.etch.slug_b == null' >/dev/null
}

@test "plan_resolve_stack records resolution=skip for an absent component when declined" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"etch","version":"2.0"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$b"
  _plan_confirm() { return 1; }
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run --separate-stderr plan_resolve_stack "$manifest" "$a" "$b"
  echo "$output" | jq -e '.stack.etch.resolution == "skip"' >/dev/null
}

@test "plan_resolve_stack uses the STRONG confirm (not the plain one) when B already has the plugin under a different slug — the ACSS v4 case" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"acss-legacy-slug","version":"3.9"}]}' > "$b"
  _plan_confirm() { echo "PLAIN CONFIRM CALLED — WRONG PATH FOR A MISMATCH WHERE B ALREADY HAS SOMETHING" >&2; return 1; }
  _plan_confirm_strong() { return 0; } # simulate the operator explicitly accepting the overwrite
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run --separate-stderr plan_resolve_stack "$manifest" "$a" "$b"
  echo "$output" | jq -e '.stack.acss.resolution == "copy" and .stack.acss.slug_a == "automatic-css" and .stack.acss.slug_b == "acss-legacy-slug"' >/dev/null
  [[ "$stderr" != *"WRONG PATH"* ]]
}

@test "plan_resolve_stack touches nothing when the stack already matches" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$b"
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run --separate-stderr plan_resolve_stack "$manifest" "$a" "$b"
  echo "$output" | jq -e '.stack == null or (.stack | length) == 0' >/dev/null
}

@test "plan_resolve_stack records resolution=skip for a version mismatch when the strong confirm is declined" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"automatic-css","version":"3.9"}]}' > "$b"
  _plan_confirm_strong() { return 1; }
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run --separate-stderr plan_resolve_stack "$manifest" "$a" "$b"
  echo "$output" | jq -e '.stack.acss.resolution == "skip"' >/dev/null
}

@test "plan_resolve_stack treats a component name containing a space as ONE component, not two word-split fragments (issue #40)" {
  # inventory_stack_diff is stubbed directly: its own keys come from
  # modules_discover's filename-derived module names (plan.sh's own comment
  # on _plan_apply_selection documents nothing stops an author picking a
  # filename with a space in it) — stubbing it is the simplest way to feed
  # plan_resolve_stack a spaced key without wiring up a whole fixture module.
  inventory_stack_diff() { echo '{"my component":{"slug_a":"a-slug","slug_b":null,"version_a":"1.0","version_b":null}}'; }
  _plan_confirm() { return 0; } # simulate the operator accepting
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run --separate-stderr plan_resolve_stack "$manifest" "/dev/null" "/dev/null"
  [ "$status" -eq 0 ]
  # Issue #40: the loop used to be `for component in $(echo "$diff" | jq -r
  # 'keys[]')` — UNQUOTED command substitution, so the shell word-split "my
  # component" into "my" and "component". Neither is a real key of $diff, so
  # both resolved every field to null and got recorded as bogus new stack
  # entries — while "my component" itself, the one component this run was
  # actually meant to resolve, was never looked at.
  echo "$output" | jq -e '.stack["my component"].resolution == "copy" and .stack["my component"].slug_a == "a-slug"' >/dev/null
  echo "$output" | jq -e '(.stack | has("my")) or (.stack | has("component")) | not' >/dev/null
}

@test "plan_resolve_stack records a theme mismatch the same way as a module component" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"etch-theme","version":"1.0"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"twentytwentyfour","version":"1.0"},"plugins":[]}' > "$b"
  _plan_confirm_strong() { return 0; }
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run --separate-stderr plan_resolve_stack "$manifest" "$a" "$b"
  echo "$output" | jq -e '.stack.theme.resolution == "copy" and .stack.theme.slug_a == "etch-theme" and .stack.theme.slug_b == "twentytwentyfour"' >/dev/null
}
