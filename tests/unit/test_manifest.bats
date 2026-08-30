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
  echo "$output" | jq -e '.sitegraft_manifest_version == 2' >/dev/null
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

# --- B4 (third review round, second reviewer): one enforcement point is elegant and
# fragile. module_selection rejects a name carrying a comma or whitespace,
# but it only ever runs on the plan_defaults path. A SITEGRAFT_MANIFEST_
# PREFILLED or hand-edited manifest — a documented workflow for repairing or
# resuming a run — reaches graft without passing through it, and
# manifest_validate used to check nothing but migrate/protect overlap. Such
# an option key then survived into graft_migrate_options' word-splitting and
# became `wp option update` calls against names nobody planned, on B's live
# database. Same rule, second entry point.

@test "manifest_validate rejects an option key carrying whitespace, which graft cannot address unambiguously (B4)" {
  local m='{"migrate":{"demo":{"option_keys":["demo_settings","two words"]}},"protect":{}}'
  run manifest_validate "$m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"two words"* ]] || false
}

@test "manifest_validate rejects a post type carrying a comma (B4)" {
  local m='{"migrate":{"demo":{"post_types":["good_cpt","bad,cpt"]}},"protect":{}}'
  run manifest_validate "$m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad,cpt"* ]] || false
}

@test "manifest_validate applies the rule to the protect bucket and to tables too (B4)" {
  local m='{"migrate":{},"protect":{"demo":{"tables":["demo_ok","demo bad"]}}}'
  run manifest_validate "$m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo bad"* ]] || false
}

@test "manifest_validate still accepts every legitimate name shape, including hyphens and theme_mods slugs (B4)" {
  local m='{"migrate":{"core-wp":{"post_types":["page","wp_global_styles"],"option_keys":["theme_mods_etch-theme-child","blogname"]}},"protect":{"x":{"tables":["amelia_appointments"]}}}'
  run manifest_validate "$m"
  [ "$status" -eq 0 ]
}

@test "manifest_freeze refuses to freeze a manifest carrying such a name (B4, the path phase_plan actually uses)" {
  local m='{"migrate":{"demo":{"option_keys":["two words"]}},"protect":{}}'
  run manifest_freeze "$m"
  [ "$status" -ne 0 ]
}

# --- issue #73: scan never wrote the key plan_defaults read for the domain
# remap, so every manifest froze with search_replace.from/to = "unknown"/
# "unknown" — a non-empty value that slipped straight past
# graft_search_replace_domain's own `[ -z "$from" ]` no-op guard and ran a
# real, silently-successful search-replace pass that rewrote nothing.
# manifest_validate is the one place manifest_freeze gates on, so this is
# where a manifest carrying a remap that could never work gets refused.

@test "manifest_validate rejects search_replace.from == 'unknown' (#73, the actual defect this issue reproduces)" {
  local m='{"options":{"search_replace":{"from":"unknown","to":"https://b.example.com"}}}'
  run manifest_validate "$m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]] || false
}

@test "manifest_validate rejects search_replace.from == '' (#73)" {
  local m='{"options":{"search_replace":{"from":"","to":"https://b.example.com"}}}'
  run manifest_validate "$m"
  [ "$status" -ne 0 ]
}

@test "manifest_validate rejects search_replace.from == to, a real but useless domain remap (#73)" {
  local m='{"options":{"search_replace":{"from":"https://same.example.com","to":"https://same.example.com"}}}'
  run manifest_validate "$m"
  [ "$status" -ne 0 ]
}

@test "manifest_validate accepts a real, distinct search_replace.from/to (#73)" {
  local m='{"options":{"search_replace":{"from":"https://a.example.com","to":"https://b.example.com"}}}'
  run manifest_validate "$m"
  [ "$status" -eq 0 ]
}

@test "manifest_validate does not look at search_replace at all when the manifest never claims one (SITEGRAFT_MANIFEST_PREFILLED's own '\"options\":{}' shape, #73)" {
  local m='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{},"options":{}}'
  run manifest_validate "$m"
  [ "$status" -eq 0 ]
}

@test "manifest_freeze refuses to freeze a manifest whose search_replace.from is 'unknown' — the exact shape plan_defaults produced before this fix (#73)" {
  local m='{"migrate":{},"protect":{},"options":{"search_replace":{"from":"unknown","to":"unknown"}}}'
  run manifest_freeze "$m"
  [ "$status" -ne 0 ]
  [[ "$output" != *'"frozen":true'* ]] || false
}

# --- BLOCKER-1 (second review round): the checks above only ever tested
# `from`. plan_defaults fills `to` with the exact same `// "unknown"`
# default, independently of `from` — so A's scan can succeed (a real
# `from`) while B's fails (a broken `to`), and the original #73 checks let
# it straight through: `from` is real, not "unknown", and not equal to a
# `to` that is itself broken. That is NOT a smaller version of the
# original bug — graft would run a REAL rewrite using B's broken `to` as
# the replacement text, corrupting every migrated page/option, and
# reporting success.

@test "manifest_validate rejects search_replace.to == '' when from is real (BLOCKER-1, #73)" {
  local m='{"options":{"search_replace":{"from":"https://a.example.com","to":""}}}'
  run manifest_validate "$m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"to is empty"* ]] || false
}

@test "manifest_validate rejects search_replace.to == 'unknown' when from is real (BLOCKER-1, #73)" {
  local m='{"options":{"search_replace":{"from":"https://a.example.com","to":"unknown"}}}'
  run manifest_validate "$m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"to is"*"unknown"* ]] || false
}

@test "manifest_freeze refuses to freeze when from is real but to is broken — A's scan succeeded, B's didn't (BLOCKER-1, #73)" {
  local m='{"migrate":{},"protect":{},"options":{"search_replace":{"from":"https://a.example.com","to":"unknown"}}}'
  run manifest_freeze "$m"
  [ "$status" -ne 0 ]
  [[ "$output" != *'"frozen":true'* ]] || false
}

# MINOR-2 (second review round): re-scanning cannot fix from==to when both
# are real, distinct-looking-but-identical home URLs (an intra-domain
# graft) — the message must say so, not send the operator chasing a
# rescan that will report the identical pair again.
@test "manifest_validate's from==to message does not tell the operator to re-scan (MINOR-2, #73)" {
  local m='{"options":{"search_replace":{"from":"https://same.example.com","to":"https://same.example.com"}}}'
  run manifest_validate "$m"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Re-run 'sitegraft scan'"* ]] || false
  [[ "$output" == *"Neither re-scanning nor re-setting"* ]] || false
}

# --- feedback from a real scan (Nat, live DDEV run): A's home/siteurl came
# back as DDEV's own internal *.ddev.site address, not the public domain
# actually present in A's content -- a WELL-FORMED value this guard cannot
# itself detect (it's neither empty nor "unknown"). But when the guard DOES
# fire for a genuinely missing value, its advice must point the operator
# at the REAL, direct fix -- the profile's own SITE_A_URL/SITE_B_URL
# (Marcel's own catch, third review round: plan_defaults now reads those
# in PREFERENCE to scan's home_url guess) -- not just "re-scan", which
# cannot fix a proxied/tunneled site's wrong `home` value either way.
@test "manifest_validate's empty/unknown advice names SITE_A_URL as the primary fix, ahead of re-scanning/hand-editing (Marcel's catch, #73)" {
  local m='{"options":{"search_replace":{"from":"unknown","to":"https://b.example.com"}}}'
  run manifest_validate "$m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SITE_A_URL"* ]] || false
  [[ "$output" == *"hand-edit"* ]] || false
  [[ "$output" == *"ddev.site"* ]] || false
}
