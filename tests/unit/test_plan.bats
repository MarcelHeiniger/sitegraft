# tests/unit/test_plan.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  load '../../lib/inventory.sh'
  load '../../lib/manifest.sh'
  load '../../lib/plan.sh'
}

# Every scan_b fixture below carries `table_prefix` and `tables`, as a real
# scan-b.json does. Without the prefix manifest_compute_unclaimed cannot tell
# a plugin table from a core one and says so on stderr — which bats merges
# into $output, so the fixture's own incompleteness would surface as a jq
# parse error rather than as the behaviour under test.
@test "manifest_compute_unclaimed protects a post_type present on B but claimed nowhere" {
  local manifest='{"migrate":{},"protect":{"known":{"post_types":["booking"]}}}'
  local scan_b='{"table_prefix":"wp_","tables":[],"post_types":[{"name":"booking"},{"name":"mystery_cpt"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect._unclaimed.post_types == ["mystery_cpt"]' >/dev/null
}

@test "manifest_compute_unclaimed adds nothing when everything on B is already claimed" {
  local manifest='{"migrate":{},"protect":{"known":{"post_types":["booking"]}}}'
  local scan_b='{"table_prefix":"wp_","tables":[],"post_types":[{"name":"booking"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.post_types == []' >/dev/null
}

@test "manifest_compute_unclaimed also considers post_types already claimed by migrate" {
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":[],"post_types":[{"name":"page"},{"name":"mystery_cpt"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.post_types == ["mystery_cpt"]' >/dev/null
}

# --- option_keys coverage: MINOR fix (Viktor's review of PR #2) — design doc
# §3.6 says default-deny covers "post_type, table, OR option key", and
# option_keys is now extended the same way post_types always has been (no
# prefix-resolution issue for options, unlike tables — see the tracked
# comment above manifest_compute_unclaimed for why tables stays [] for now).
@test "manifest_compute_unclaimed protects an option_key present on B but claimed nowhere" {
  local manifest='{"migrate":{},"protect":{"known":{"option_keys":["known_plugin_settings"]}}}'
  local scan_b='{"table_prefix":"wp_","tables":[],"post_types":[],"options":[{"option_name":"known_plugin_settings"},{"option_name":"mystery_option"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect._unclaimed.option_keys == ["mystery_option"]' >/dev/null
}

@test "manifest_compute_unclaimed adds no option_keys when everything on B is already claimed" {
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":[],"post_types":[],"options":[{"option_name":"etch_settings"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.option_keys == []' >/dev/null
}

# --- tables. This list used to be left empty on purpose and a test asserted
# that it stayed empty. It no longer does: an empty list meant backup took no
# checksum for anything outside a module, so verify could report "protected
# data unchanged" having compared nothing. See the comment above
# manifest_compute_unclaimed.
@test "manifest_compute_unclaimed lists a table on B that no module claims" {
  local manifest='{"migrate":{},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":["wp_amelia_appointments"],"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect._unclaimed.tables == ["wp_amelia_appointments"]' >/dev/null
}

@test "manifest_compute_unclaimed excludes a table a module already claims by suffix" {
  local manifest='{"migrate":{},"protect":{"amelia":{"tables":["amelia_appointments"]}}}'
  local scan_b='{"table_prefix":"wp_","tables":["wp_amelia_appointments","wp_other_plugin"],"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.tables == ["wp_other_plugin"]' >/dev/null
}

@test "manifest_compute_unclaimed excludes the core tables graft itself writes" {
  local manifest='{"migrate":{},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":["wp_posts","wp_postmeta","wp_options","wp_terms","wp_termmeta","wp_term_taxonomy","wp_term_relationships","wp_someplugin"],"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.tables == ["wp_someplugin"]' >/dev/null
}

@test "manifest_compute_unclaimed keeps users and comments tables, which graft never writes" {
  local manifest='{"migrate":{},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":["wp_users","wp_comments"],"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.tables == ["wp_users","wp_comments"]' >/dev/null
}

# Fail safe, not silent: without a prefix a plugin table cannot be told from a
# core one, so the list stays empty AND the operator is told why.
@test "manifest_compute_unclaimed leaves tables empty and warns when the scan has no table_prefix" {
  local manifest='{"migrate":{},"protect":{}}'
  local scan_b='{"tables":["wp_amelia_appointments"],"post_types":[],"options":[]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no table_prefix"* ]]
  # Take the JSON from its opening brace onwards. bats merges stderr into
  # $output, so the colourised warning is prepended — and it cannot be
  # stripped by matching a leading "[" (it starts with an ANSI escape) nor by
  # taking the last line (the JSON is pretty-printed over several).
  echo "$output" | awk '/^\{/{f=1} f' | jq -e '.protect._unclaimed.tables == []' >/dev/null
}

# Fail closed when the table list itself cannot be computed. Written first as
# `2>/dev/null || echo '[]'`, which turns any jq error into "no unclaimed
# tables" -- indistinguishable from a site that genuinely has none, and it
# silently reinstates the very gap this function was changed to close.
@test "manifest_compute_unclaimed fails rather than returning an empty table list it could not compute" {
  local manifest='{"migrate":{},"protect":{}}'
  local scan_b='{"table_prefix":"wp_","tables":["wp_amelia_appointments"],"post_types":[],"options":[]}'
  # Fail only the one jq call that computes the table list -- it is the only
  # one passed `--argjson core`. Malformed INPUT cannot be used to trigger
  # this: the jq program guards its iterations with `?`, so a `.tables` that
  # is a string yields an empty list instead of an error. The failure being
  # guarded against is jq itself failing, so that is what is simulated. It
  # matters because without this guard, a jq error would silently become an
  # empty unclaimed list, and `backup` would checksum nothing against it.
  jq() {
    case "$*" in
      *--argjson\ core\ *) return 5 ;;
      *) command jq "$@" ;;
    esac
  }
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to write a manifest"* ]] || false
}

@test "plan_warn_scope_gaps warns about A's classic menus but never about B's, and always exits 0" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"classic_menus_detected":true,"classic_menu_names":["Main Menu"]}' > "$a"
  echo '{"classic_menus_detected":true,"classic_menu_names":["Legacy Menu"]}' > "$b"
  run plan_warn_scope_gaps "$a" "$b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Main Menu"* ]] || false
  [[ "$output" != *"Legacy Menu"* ]]
}

@test "plan_warn_scope_gaps says nothing when A has no classic menus" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"classic_menus_detected":false}' > "$a"
  echo '{"classic_menus_detected":true,"classic_menu_names":["Legacy Menu"]}' > "$b"
  run plan_warn_scope_gaps "$a" "$b"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- MAJOR-2(b) (issue #73, second round), MOVED and CORRECTED (third
# round): plan_warn_scope_gaps used to run this check itself, comparing
# scan's own home_url against scan's own site_url — before plan_defaults
# had run, so it could not know whether SITE_A_URL had overridden
# home_url as the actual remap source. plan_warn_asset_domain_gap now
# takes the FINISHED manifest and compares its real
# options.search_replace.from against A's scanned site_url instead.

@test "plan_warn_asset_domain_gap warns when the CHOSEN remap source and A's siteurl are on different origins" {
  local manifest='{"options":{"search_replace":{"from":"https://a.example.com","to":"https://b.example.com"}}}'
  local a="$BATS_TEST_TMPDIR/a.json"
  echo '{"site_url":"https://cdn-a.example.com"}' > "$a"
  run plan_warn_asset_domain_gap "$manifest" "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"different origins"* ]] || false
  [[ "$output" == *"https://a.example.com"* ]] || false
  [[ "$output" == *"https://cdn-a.example.com"* ]] || false
}

@test "plan_warn_asset_domain_gap says nothing when the chosen source and siteurl share an origin (subdirectory install, same domain different path)" {
  local manifest='{"options":{"search_replace":{"from":"https://a.example.com/blog","to":"https://b.example.com"}}}'
  local a="$BATS_TEST_TMPDIR/a.json"
  echo '{"site_url":"https://a.example.com"}' > "$a"
  run plan_warn_asset_domain_gap "$manifest" "$a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plan_warn_asset_domain_gap says nothing when either side is missing or unknown (that is manifest_validate's #73 guard's job, not this warning's)" {
  local manifest='{"options":{"search_replace":{"from":"unknown","to":"unknown"}}}'
  local a="$BATS_TEST_TMPDIR/a.json"
  echo '{"site_url":"https://cdn-a.example.com"}' > "$a"
  run plan_warn_asset_domain_gap "$manifest" "$a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- MAJOR-1 (third review round): the two failure directions the OLD
# placement (inside plan_warn_scope_gaps, comparing two scanned values
# before plan_defaults ever ran) provably got wrong on real reproductions.

@test "plan_warn_asset_domain_gap fires when scan's home_url==site_url (old check would stay silent) but SITE_A_URL overrode home_url to a genuinely different domain (MAJOR-1, #73)" {
  # The exact shape that made the OLD placement silent: A's scanned
  # home_url and site_url are IDENTICAL (both the proxy's own internal
  # address) — comparing those two, as the old check did, sees no
  # divergence at all. But plan_defaults chose SITE_A_URL (the real
  # public domain) as `from`, and THAT genuinely diverges from site_url.
  local manifest='{"options":{"search_replace":{"from":"https://a.example.com","to":"https://b.example.com"}}}'
  local a="$BATS_TEST_TMPDIR/a.json"
  echo '{"home_url":"https://a.ddev.site:8443","site_url":"https://a.ddev.site:8443"}' > "$a"
  run plan_warn_asset_domain_gap "$manifest" "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"different origins"* ]] || false
}

@test "plan_warn_asset_domain_gap names the CHOSEN source in its message, not scan's home_url, when they differ (MAJOR-1, #73)" {
  # The exact shape that made the OLD message FALSE: it named A's scanned
  # home_url as "this run's domain remap source" when the manifest's real
  # chosen `from` (SITE_A_URL) was a completely different value.
  local manifest='{"options":{"search_replace":{"from":"https://public-a.example.com","to":"https://b.example.com"}}}'
  local a="$BATS_TEST_TMPDIR/a.json"
  echo '{"home_url":"https://a.ddev.site:8443","site_url":"https://cdn-a.example.com"}' > "$a"
  run plan_warn_asset_domain_gap "$manifest" "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://public-a.example.com"* ]] || false
  [[ "$output" != *"https://a.ddev.site:8443"* ]] || false
}

@test "_plan_url_origin strips path/query/fragment, keeping only scheme://host[:port]" {
  run _plan_url_origin "https://a.example.com:8443/blog/page?x=1#frag"
  [ "$status" -eq 0 ]
  [ "$output" = "https://a.example.com:8443" ]
}

@test "_plan_url_origin treats a bare host with no scheme as its own origin (never errors, never empties)" {
  run _plan_url_origin "not-a-url"
  [ "$status" -eq 0 ]
  [ "$output" = "not-a-url" ]
}

# --- plan_defaults: not covered by the plan's own bats spec (called out there
# as "not a pure function... tested separately") — added here for real
# coverage of the module-dispatch logic itself, using fabricated modules the
# same way Task 2.4's test file does (SITEGRAFT_MODULES_DIR override).
_plan_defaults_setup_modules() {
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/etch.sh" <<'EOF'
etch_name() { echo "Etch"; }
etch_detect() { jq -e '.plugins[] | select(.name == "etch")' "$1" >/dev/null 2>&1; }
etch_post_types() { printf 'etch_cfs\netch_cpts\n'; }
etch_option_keys() { printf 'etch_settings\n'; }
EOF
  cat > "$SITEGRAFT_MODULES_DIR/fakebooking.sh" <<'EOF'
fakebooking_name() { echo "Fake Booking"; }
fakebooking_detect() { jq -e '.plugins[] | select(.name == "fake-booking")' "$1" >/dev/null 2>&1; }
fakebooking_post_types() { printf 'fake_reservation\n'; }
fakebooking_tables() { printf 'fakebooking_reservations\n'; }
fakebooking_option_keys() { printf 'fakebooking_settings\n'; }
EOF
  modules_discover
}

@test "plan_defaults migrates a module detected on A and protects one detected only on B" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[{"name":"etch","version":"2.0"}],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[{"name":"fake-booking","version":"1.0"}],"post_types":[{"name":"fake_reservation"}],"options":[],"tables":["fakebooking_reservations"]}' > "$b"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.etch.post_types == ["etch_cfs","etch_cpts"]' >/dev/null
  echo "$output" | jq -e '.migrate.etch.option_keys == ["etch_settings"]' >/dev/null
  echo "$output" | jq -e '.protect.fakebooking.post_types == ["fake_reservation"]' >/dev/null
  echo "$output" | jq -e '.protect.fakebooking.tables == ["fakebooking_reservations"]' >/dev/null
  # A module detected on A never also lands in protect for the same run.
  echo "$output" | jq -e '.protect.etch == null' >/dev/null
}

@test "plan_defaults leaves both buckets empty when no module is detected on either site" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$b"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate == {}' >/dev/null
  echo "$output" | jq -e '.protect == {}' >/dev/null
}

# --- issue #73: the domain search-replace never ran, because plan_defaults
# read `.site_url`, a key `scan` never wrote — every real scan produced
# search_replace.from/to = "unknown"/"unknown", and graft_search_replace_domain
# only short-circuited on an EMPTY from, so it ran a real, silently-successful
# no-op pass replacing "unknown" with "unknown". Reproduced here on the exact
# real scan-a.json key set the issue names (no fabricated `site_url` key).
@test "plan_defaults derives options.search_replace.from/to from each scan's home_url, not a fabricated site_url key (#73)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  # site_url deliberately differs from home_url on both sides (the real
  # WordPress case this whole distinction is about, per
  # inventory_scan_site's own comment) — if plan_defaults ever regressed
  # back to reading .site_url, this test would derive the WRONG from/to
  # pair instead of merely deriving a coincidentally-identical one.
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://a.example.com","site_url":"https://cdn-a.example.com"}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://b.example.com","site_url":"https://cdn-b.example.com"}' > "$b"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.options.search_replace.from == "https://a.example.com"' >/dev/null
  echo "$output" | jq -e '.options.search_replace.to == "https://b.example.com"' >/dev/null
}

@test "plan_defaults falls back to the 'unknown' placeholder when a scan carries no home_url at all — a real scan-a.json's actual key set, per issue #73 (nothing named site_url or home_url)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  # The exact key set issue #73 quotes from a real scan-a.json, deliberately
  # WITHOUT home_url or site_url — this is what every scan looked like
  # before this fix-pack, and the manifest it produces must still say so
  # honestly (as "unknown"), never silently invent a URL.
  echo '{"active_theme":{},"classic_menu_names":[],"classic_menus_detected":false,"classic_menus_unknown":false,"custom_code_detected":false,"custom_code_signals":{},"nav_post_count":null,"nav_uses_dynamic_page_list":null,"options":[],"plugins":[],"post_types":[],"table_prefix":"wp_","tables":[]}' > "$a"
  echo '{"active_theme":{},"classic_menu_names":[],"classic_menus_detected":false,"classic_menus_unknown":false,"custom_code_detected":false,"custom_code_signals":{},"nav_post_count":null,"nav_uses_dynamic_page_list":null,"options":[],"plugins":[],"post_types":[],"table_prefix":"wp_","tables":[]}' > "$b"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.options.search_replace.from == "unknown"' >/dev/null
  echo "$output" | jq -e '.options.search_replace.to == "unknown"' >/dev/null
}

# --- Marcel's own catch, second review round: the profile ALREADY carries
# SITE_A_URL/SITE_B_URL (design doc §5.1, whitelisted since day one), filled
# in by hand by an operator who knows the real public domain — and until
# this fix plan_defaults ignored both, guessing from scan's own `home_url`
# instead. Reproduced live against a real migration: a site served behind
# a proxy (DDEV, in the reproducing case) records `home` as the proxy's
# own internal address — zero occurrences of that address in the site's
# real content — while the profile's own SITE_A_URL already named the
# public domain that actually appears there. profile_load exports both as
# real shell variables before plan_defaults runs (same pattern every other
# SITE_*_* consumer already relies on), so these tests set them the same
# way. Domains below are this repo's own placeholders throughout
# (a.example.com/b.example.com — see e.g. tests/integration/ddev-harness.sh,
# profiles/example.conf), never real hosts.

@test "plan_defaults prefers the profile's SITE_A_URL/SITE_B_URL over scan's home_url (Marcel's catch, #73)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://a.ddev.site:8443"}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://b.ddev.site:8443"}' > "$b"
  SITE_A_URL="https://a.example.com"
  SITE_B_URL="https://b.example.com"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.options.search_replace.from == "https://a.example.com"' >/dev/null
  echo "$output" | jq -e '.options.search_replace.to == "https://b.example.com"' >/dev/null
  echo "$output" | jq -e '.options.search_replace.from != "https://a.ddev.site:8443"' >/dev/null
}

@test "plan_defaults falls back to scan's home_url when the profile does not set SITE_A_URL/SITE_B_URL (#73)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://a.example.com"}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://b.example.com"}' > "$b"
  unset SITE_A_URL SITE_B_URL
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.options.search_replace.from == "https://a.example.com"' >/dev/null
  echo "$output" | jq -e '.options.search_replace.to == "https://b.example.com"' >/dev/null
}

@test "plan_defaults mixes sources independently — SITE_A_URL set, SITE_B_URL not, B still falls back to scan's home_url (#73)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://a.ddev.site"}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://b.example.com"}' > "$b"
  SITE_A_URL="https://a-public.example.com"
  unset SITE_B_URL
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.options.search_replace.from == "https://a-public.example.com"' >/dev/null
  echo "$output" | jq -e '.options.search_replace.to == "https://b.example.com"' >/dev/null
}

@test "plan_defaults treats an empty SITE_A_URL exactly like an unset one — still falls back to scan's home_url" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://a.example.com"}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://b.example.com"}' > "$b"
  SITE_A_URL=""
  SITE_B_URL=""
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.options.search_replace.from == "https://a.example.com"' >/dev/null
}

# --- BLOCKER-1 (third review round): SITE_A_URL/SITE_B_URL are taken
# verbatim, never validated for form. Before the profile-priority
# change, `from`/`to` always came from `wp option get home` — WordPress
# stores it untrailingslashit'd and always with a scheme, so both ends
# were structurally guaranteed to match in form. A hand-typed profile
# value breaks that guarantee two concrete ways, reproduced against the
# real sitegraft_remap_domain (a bare string split()/join(), see
# tests/unit/test_content_remap_functions.bats for that function's own
# tests): a trailing slash on one side desyncs the split point from the
# other, and a missing scheme lets the value match as a bare substring
# inside a scheme-qualified URL, re-inserting `to`'s scheme INSIDE the
# original one. Both corrupt every migrated URL instead of rewriting it,
# and verify_domain_absent finds the corrupted `from` legitimately
# missing and reports the check green.

@test "plan_defaults strips a trailing slash from SITE_A_URL/SITE_B_URL before it ever reaches the manifest (BLOCKER-1, #73)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$b"
  SITE_A_URL="https://a.example.com/"
  SITE_B_URL="https://b.example.com"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.options.search_replace.from == "https://a.example.com"' >/dev/null
  echo "$output" | jq -e '.options.search_replace.to == "https://b.example.com"' >/dev/null
}

@test "plan_defaults refuses (fails loud, never a corrupting remap) when SITE_A_URL has no scheme (BLOCKER-1, #73)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$b"
  SITE_A_URL="a.example.com"
  SITE_B_URL="https://b.example.com"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"a.example.com"* ]] || false
  [[ "$stderr" == *"scheme"* ]] || false
}

@test "plan_defaults refuses when SITE_B_URL has no scheme (BLOCKER-1, #73)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$b"
  SITE_A_URL="https://a.example.com"
  SITE_B_URL="b.example.com"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"b.example.com"* ]] || false
}

@test "plan_defaults normalizes a half-profile/half-scan pair to the SAME canonical form (BLOCKER-1, #73 — the shape this priority order makes newly possible)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  # A's remap source is the profile (with a trailing slash, the way an
  # operator is likely to type it — Marcel's own first draft had one);
  # B's is scan's home_url (already clean, the way wp-cli actually
  # produces it). Both must land in the manifest in the SAME form.
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://b.example.com"}' > "$b"
  SITE_A_URL="https://a.example.com/"
  unset SITE_B_URL
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.options.search_replace.from == "https://a.example.com"' >/dev/null
  echo "$output" | jq -e '.options.search_replace.to == "https://b.example.com"' >/dev/null
}

@test "plan_defaults still treats scan's own "unknown" placeholder as passable, not as a malformed URL to reject (BLOCKER-1, #73 — that is manifest_validate's job, not this normalizer's)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://b.example.com"}' > "$b"
  unset SITE_A_URL SITE_B_URL
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.options.search_replace.from == "unknown"' >/dev/null
}

@test "plan_defaults logs which source (profile or scan) supplied each end of the remap (NIT-1, #73)" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[],"home_url":"https://a.ddev.site"}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$b"
  SITE_A_URL="https://a.example.com"
  unset SITE_B_URL
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"SITE_A_URL"* ]] || false
  [[ "$stderr" == *"scan's home_url"* ]] || false
}

# --- plan_defaults: dynamic selections and option-key exclusions (issues
# #13/#15/#16, docs/decisions/0007-module-dynamic-selections.md). Asserted
# through plan_defaults rather than through module_selection alone, because
# the manifest is what graft and verify actually read — a mechanism that
# works in isolation but never reaches the manifest fixes nothing.
_plan_dynamic_scans() {
  cat > "$BATS_TEST_TMPDIR/a.json" <<'EOF'
{"plugins":[{"name":"demo","version":"1.0"}],
 "active_theme":{"stylesheet":"a-child-theme"},
 "post_types":[{"name":"page"},{"name":"fotos"}],
 "options":[{"option_name":"demo_settings"},{"option_name":"demo_license_key"},{"option_name":"demo_ai_api_key"}],
 "tables":[],"table_prefix":"wp_"}
EOF
  cat > "$BATS_TEST_TMPDIR/b.json" <<'EOF'
{"plugins":[],"active_theme":{"stylesheet":"b-theme"},
 "post_types":[{"name":"page"}],"options":[],"tables":[],"table_prefix":"wp_"}
EOF
}

_plan_dynamic_module() {
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/demo.sh"
  modules_discover
  _plan_dynamic_scans
}

@test "plan_defaults keeps a module's excluded option keys out of the manifest even when its list is a broad prefix (#13)" {
  _plan_dynamic_module <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { jq -e '.plugins[]? | select(.name == "demo")' "$1" >/dev/null 2>&1; }
demo_option_keys_dynamic() { jq -r '.options[]?.option_name | select(startswith("demo_"))' "$1"; }
demo_option_keys_exclude() { printf 'demo_license_*\ndemo_*_api_key\n'; }
EOF
  run --separate-stderr plan_defaults "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.demo.option_keys == ["demo_settings"]' >/dev/null
}

@test "plan_defaults puts a dynamic, scan-derived option key into migrate (#15)" {
  _plan_dynamic_module <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { jq -e '.plugins[]? | select(.name == "demo")' "$1" >/dev/null 2>&1; }
demo_option_keys() { printf 'demo_settings\n'; }
demo_option_keys_dynamic() { printf 'theme_mods_%s\n' "$(jq -r '.active_theme.stylesheet' "$1")"; }
EOF
  run --separate-stderr plan_defaults "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -eq 0 ]
  # A's theme slug, not B's: a module bound for migrate is resolved against scan A.
  echo "$output" | jq -e '.migrate.demo.option_keys | index("theme_mods_a-child-theme")' >/dev/null
  echo "$output" | jq -e '.migrate.demo.option_keys | index("theme_mods_b-theme") | not' >/dev/null
}

@test "plan_defaults puts dynamic, scan-derived post types into migrate (#16)" {
  _plan_dynamic_module <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { jq -e '.plugins[]? | select(.name == "demo")' "$1" >/dev/null 2>&1; }
demo_post_types() { printf 'wp_block\n'; }
demo_post_types_dynamic() { jq -r '.post_types[]?.name | select(. == "fotos")' "$1"; }
EOF
  run --separate-stderr plan_defaults "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.demo.post_types == ["wp_block","fotos"]' >/dev/null
}

@test "a dynamic post type is individually deselectable in plan's interactive selection (#16)" {
  # #16 asks for each such type to appear individually in plan's selection.
  # _plan_apply_selection is the half of that flow that is testable without
  # a TTY: it must classify a dynamic name as a post_type (from the
  # manifest's own list, never from the string's shape) and drop it when the
  # operator deselects it, leaving the rest alone.
  local manifest='{"migrate":{"demo":{"post_types":["wp_block","fotos"],"option_keys":["demo_settings","theme_mods_a-child-theme"]}}}'
  run _plan_apply_selection "$manifest" "$(printf 'demo: wp_block\ndemo: demo_settings\n')"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.demo.post_types == ["wp_block"]' >/dev/null
  echo "$output" | jq -e '.migrate.demo.option_keys == ["demo_settings"]' >/dev/null
}

@test "plan_defaults resolves a protect-only module's dynamic selection against scan B, not scan A" {
  _plan_dynamic_module <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { jq -e '.post_types[]? | select(.name == "page")' "$1" >/dev/null 2>&1; }
demo_tables() { printf 'demo_data\n'; }
demo_option_keys_dynamic() { printf 'theme_mods_%s\n' "$(jq -r '.active_theme.stylesheet' "$1")"; }
EOF
  run --separate-stderr plan_defaults "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect.demo.option_keys == ["theme_mods_b-theme"]' >/dev/null
}

@test "plan_defaults fails loudly instead of planning an empty selection when a module's dynamic function errors" {
  _plan_dynamic_module <<'EOF'
demo_name() { echo "Demo"; }
demo_detect() { jq -e '.plugins[]? | select(.name == "demo")' "$1" >/dev/null 2>&1; }
demo_post_types() { printf 'wp_block\n'; }
demo_post_types_dynamic() { echo "cannot parse that option" >&2; return 1; }
EOF
  run --separate-stderr plan_defaults "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/b.json"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"demo_post_types_dynamic"* ]] || false
}

# N5 (third review round). `tables` used to be expanded for EVERY
# discovered module before detection ran, because the expanded list was what
# decided which side the module got tested against first. So a module present
# on neither site could still abort the whole run through a failing
# `_tables_dynamic` — while the identical bug in a `_post_types_dynamic` of an
# undetected module was harmless, because that expansion happens after
# detection. Deciding the bucket from whether the module DECLARES a tables
# function (which is the claim of kind the ordering rule is actually about)
# removes the asymmetry.
@test "plan_defaults is not taken down by a broken _tables_dynamic in a module present on NEITHER site (N5)" {
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/absent.sh" <<'EOF'
absent_name() { echo "Absent"; }
absent_detect() { return 1; }
absent_tables_dynamic() { echo "boom" >&2; return 9; }
EOF
  modules_discover
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$b"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate == {} and .protect == {}' >/dev/null
}

# The counterpart: a module that IS detected and whose tables claim is what
# the manifest needs must still fail the run when it cannot produce it. The
# fix above must not turn fail-closed into fail-open.
@test "plan_defaults still fails when a DETECTED module's _tables_dynamic cannot answer (N5, the opposite direction)" {
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/present.sh" <<'EOF'
present_name() { echo "Present"; }
present_detect() { jq -e '.plugins[]? | select(.name == "present")' "$1" >/dev/null 2>&1; }
present_tables_dynamic() { echo "boom" >&2; return 9; }
EOF
  modules_discover
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"plugins":[],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[{"name":"present"}],"post_types":[],"options":[],"tables":[]}' > "$b"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -ne 0 ]
}

# --- plan_defaults: protect wins over migrate for a table-owning module -----
#
# The pair of tests below pins both halves of a rule that is easy to get
# half-right. "Present on A" used to mean "migrate", which is fine until A is
# a clone of B's production site — then the target's own business plugin is on
# both sides, wins that test, and graft overwrites live data with A's stale
# copy.
#
# The obvious repair, testing B first, silently breaks everything else: core-wp
# and etch are present on A and B in any real redesign, so they would land in
# protect and the run would migrate nothing. The second test exists to catch
# exactly that, and it fails against a naive swap.
@test "plan_defaults protects a table-owning module present on BOTH sites, never migrates it" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  # fake-booking installed on A as well: the normal shape when A was built
  # from a clone of B's production site.
  echo '{"plugins":[{"name":"etch"},{"name":"fake-booking"}],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[{"name":"fake-booking"}],"post_types":[{"name":"fake_reservation"}],"options":[],"tables":["fakebooking_reservations"]}' > "$b"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect.fakebooking.tables == ["fakebooking_reservations"]' >/dev/null
  echo "$output" | jq -e '.migrate.fakebooking == null' >/dev/null
}

@test "plan_defaults still migrates a module present on BOTH sites when it owns no tables" {
  _plan_defaults_setup_modules
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  # etch declares no tables and is installed on both, as it is on any real pair.
  echo '{"plugins":[{"name":"etch"}],"post_types":[],"options":[],"tables":[]}' > "$a"
  echo '{"plugins":[{"name":"etch"}],"post_types":[],"options":[],"tables":[]}' > "$b"
  run --separate-stderr plan_defaults "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.etch.option_keys == ["etch_settings"]' >/dev/null
  echo "$output" | jq -e '.protect.etch == null' >/dev/null
}
