# tests/unit/test_manifest.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/manifest.sh'
}

@test "manifest_new produces an unfrozen manifest with both site URLs" {
  run manifest_new "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.frozen == false' >/dev/null
  echo "$output" | jq -e '.site_a.url == "https://a.example.com"' >/dev/null
  echo "$output" | jq -e '.site_b.url == "https://b.example.com"' >/dev/null
}

@test "manifest_new produces a schema-complete skeleton (design doc §4)" {
  run manifest_new "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.sitegraft_manifest_version == 1' >/dev/null
  echo "$output" | jq -e '.migrate == {}' >/dev/null
  echo "$output" | jq -e '.protect == {}' >/dev/null
  echo "$output" | jq -e '.clean.enabled == false' >/dev/null
  echo "$output" | jq -e '.clean.post_types == []' >/dev/null
  echo "$output" | jq -e '.options.search_replace == {"from":"https://a.example.com","to":"https://b.example.com"}' >/dev/null
}

# --- MINOR fixes (Viktor's review of PR #2): design doc §4's manifest shows
# `profile`, `site_a.alias`/`site_b.alias`, and `options.search_replace`,
# none of which the original 2-arg manifest_new actually produced.
@test "manifest_new defaults profile to empty and aliases to a/b when only URLs are given (2-arg call sites keep working unchanged)" {
  run manifest_new "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.profile == ""' >/dev/null
  echo "$output" | jq -e '.site_a.alias == "a"' >/dev/null
  echo "$output" | jq -e '.site_b.alias == "b"' >/dev/null
}

@test "manifest_new records the profile name and real aliases when given" {
  run manifest_new "https://a.example.com" "https://b.example.com" "my-profile" "site-a" "site-b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.profile == "my-profile"' >/dev/null
  echo "$output" | jq -e '.site_a.alias == "site-a"' >/dev/null
  echo "$output" | jq -e '.site_b.alias == "site-b"' >/dev/null
}

@test "manifest_new populates options.search_replace from the two site URLs — the A-to-B domain remap graft §9.4 needs" {
  run manifest_new "https://a.example.com" "https://b.example.com"
  echo "$output" | jq -e '.options.search_replace.from == "https://a.example.com"' >/dev/null
  echo "$output" | jq -e '.options.search_replace.to == "https://b.example.com"' >/dev/null
}

@test "manifest_add_migrate adds a module entry with post_types and option_keys" {
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run manifest_add_migrate "$manifest" "etch" '["etch_cfs","etch_cpts"]' '["etch_settings"]'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.etch.post_types == ["etch_cfs","etch_cpts"]' >/dev/null
  echo "$output" | jq -e '.migrate.etch.option_keys == ["etch_settings"]' >/dev/null
}

@test "manifest_add_protect adds a module entry with post_types, tables, and option_keys" {
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run manifest_add_protect "$manifest" "booking" '["booking_cpt"]' '["booking_meta"]' '["booking_settings"]'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect.booking.post_types == ["booking_cpt"]' >/dev/null
  echo "$output" | jq -e '.protect.booking.tables == ["booking_meta"]' >/dev/null
  echo "$output" | jq -e '.protect.booking.option_keys == ["booking_settings"]' >/dev/null
}

@test "manifest_validate fails when a post_type is in both migrate and protect" {
  local bad_manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["page"]}}}'
  run manifest_validate "$bad_manifest"
  [ "$status" -eq 1 ]
}

@test "manifest_validate fails when an option_key is in both migrate and protect" {
  local bad_manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}},"protect":{"x":{"option_keys":["etch_settings"]}}}'
  run manifest_validate "$bad_manifest"
  [ "$status" -eq 1 ]
}

@test "manifest_validate fails when a table is in both migrate and protect" {
  local bad_manifest='{"migrate":{"mod":{"tables":["mod_data"]}},"protect":{"x":{"tables":["mod_data"]}}}'
  run manifest_validate "$bad_manifest"
  [ "$status" -eq 1 ]
}

@test "manifest_validate passes for a conflict-free manifest" {
  local ok_manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["booking"]}}}'
  run manifest_validate "$ok_manifest"
  [ "$status" -eq 0 ]
}

@test "manifest_validate passes on an empty/minimal manifest" {
  run manifest_validate '{}'
  [ "$status" -eq 0 ]
}

@test "manifest_freeze refuses an invalid manifest" {
  local bad_manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["page"]}}}'
  run manifest_freeze "$bad_manifest"
  [ "$status" -eq 1 ]
}

@test "manifest_freeze sets frozen=true for a valid manifest" {
  local ok_manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["booking"]}}}'
  run manifest_freeze "$ok_manifest"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.frozen == true' >/dev/null
}

@test "manifest_freeze never mutates a manifest that fails validation into frozen=true (recommended: refuse to be a partial no-op)" {
  local bad_manifest='{"frozen":false,"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["page"]}}}'
  run manifest_freeze "$bad_manifest"
  [ "$status" -eq 1 ]
  [[ "$output" != *'"frozen":true'* ]]
}
