# tests/unit/test_inventory_custom_code.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
}

@test "inventory_custom_code_detected is false when every signal is empty" {
  local signals='{"child_theme":false,"functions_php":{"exists":false},"mu_plugins":[],"snippet_plugins_detected":[]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 1 ]
}

@test "inventory_custom_code_detected is true when the active theme is a child theme" {
  local signals='{"child_theme":true,"functions_php":{"exists":false},"mu_plugins":[],"snippet_plugins_detected":[]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 0 ]
}

@test "inventory_custom_code_detected is true when functions.php exists" {
  local signals='{"child_theme":false,"functions_php":{"exists":true,"bytes":100,"lines":10},"mu_plugins":[],"snippet_plugins_detected":[]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 0 ]
}

@test "inventory_custom_code_detected is true when any mu-plugin file is present" {
  local signals='{"child_theme":false,"functions_php":{"exists":false},"mu_plugins":["custom-redirects.php"],"snippet_plugins_detected":[]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 0 ]
}

@test "inventory_custom_code_detected is true when a known snippet plugin is active" {
  local signals='{"child_theme":false,"functions_php":{"exists":false},"mu_plugins":[],"snippet_plugins_detected":["code-snippets"]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 0 ]
}

@test "inventory_custom_code_detected is true when any signal could not be verified (M3, fail closed)" {
  local signals='{"child_theme":false,"functions_php":{"exists":false},"mu_plugins":[],"snippet_plugins_detected":[],"unknown_signals":["child_theme"]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 0 ]
}

@test "inventory_custom_code_signals fails closed (unknown, not false) when the active-theme query errors (M3, real execution)" {
  # Calling the function directly (not via bats' `run`) so stdout (the JSON
  # this test needs to parse) isn't merged with the log_warn message on
  # stderr that `run` combines into $output by default.
  wp_remote() { return 1; }
  local result fn_status
  result=$(inventory_custom_code_signals b 2>/dev/null)
  fn_status=$?
  [ "$fn_status" -eq 0 ]
  echo "$result" | jq -e '.unknown_signals == ["active_theme"]' >/dev/null
  run inventory_custom_code_detected "$result"
  [ "$status" -eq 0 ]
}

@test "inventory_custom_code_signals fails closed on child_theme only when just the template query errors (M3, real execution)" {
  wp_remote() {
    local alias_lc="$1"; shift
    case "$*" in
      "theme list --status=active --field=name") echo "twentytwentyfour" ;;
      "theme get twentytwentyfour --field=template") return 1 ;;
      eval*) echo '{"exists":false}' ;;
      "plugin list --format=json") echo '[]' ;;
      *) echo '[]' ;;
    esac
  }
  local result fn_status
  result=$(inventory_custom_code_signals b 2>/dev/null)
  fn_status=$?
  [ "$fn_status" -eq 0 ]
  echo "$result" | jq -e '.unknown_signals == ["child_theme"]' >/dev/null
  # The old code's fallback (`2>/dev/null || echo "$name"`) made this look
  # like "not a child theme" (false) on error — this must NOT be false here,
  # it must be absent/unknown, and the gate must still fire.
  echo "$result" | jq -e '.child_theme == false' >/dev/null
  run inventory_custom_code_detected "$result"
  [ "$status" -eq 0 ]
}

@test "inventory_custom_code_signals accepts a bare 'false'/'null' result as valid JSON, not as a query failure (found via CLI smoke-testing)" {
  # jq -e treats a top-level `false`/`null` result as failure (that is what
  # -e is FOR — boolean filters). Using it as a generic "is this valid
  # JSON" check was wrong: it would misclassify legitimately-valid-but-
  # falsy wp-cli output as an unverifiable signal. None of the three real
  # PHP snippets this guards (functions.php check, mu-plugins glob, plugin
  # list) can normally emit a bare null/false today, but the check itself
  # must not depend on that being true forever — fixed by dropping -e
  # (jq '.' only fails on a genuine parse error, regardless of truthiness).
  wp_remote() {
    local alias_lc="$1"; shift
    case "$*" in
      "theme list --status=active --field=name") echo "t" ;;
      "theme get t --field=template") echo "t" ;;
      eval*) echo 'null' ;;
      "plugin list --format=json") echo '[]' ;;
      *) echo '[]' ;;
    esac
  }
  local result fn_status
  result=$(inventory_custom_code_signals b 2>/dev/null)
  fn_status=$?
  [ "$fn_status" -eq 0 ]
  # A genuinely-valid "null" must NOT be recorded as unknown/unverifiable.
  echo "$result" | jq -e '.unknown_signals == []' >/dev/null
}

@test "inventory_custom_code_signals filters snippet plugins to active ones only (nit: status=active)" {
  wp_remote() {
    local alias_lc="$1"; shift
    case "$*" in
      "theme list --status=active --field=name") echo "t" ;;
      "theme get t --field=template") echo "t" ;;
      eval*) echo '{"exists":false}' ;;
      "plugin list --format=json") echo '[{"name":"code-snippets","status":"inactive"}]' ;;
      *) echo '[]' ;;
    esac
  }
  run inventory_custom_code_signals b
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.snippet_plugins_detected == []' >/dev/null
}
