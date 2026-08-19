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
