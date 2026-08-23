# tests/unit/test_phase_scan.bats — phase_scan's own flag/arity/dry-run
# behavior (M2, M4, M6). Stubs wp_remote so these stay fast, real-execution
# unit tests rather than needing a live wp-cli/DDEV install — the DDEV
# integration harness is the separate, real end-to-end proof.
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  load '../../lib/profile.sh'
  load '../../lib/inventory.sh'
  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_PROFILES_DIR" "$SITEGRAFT_MODULES_DIR"
  modules_discover

  cat > "$SITEGRAFT_PROFILES_DIR/demo.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/site-a"
SITE_A_WP_CMD="wp"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/site-b"
SITE_B_WP_CMD="wp"
SITEGRAFT_STATE_DIR="$BATS_TEST_TMPDIR/runs"
EOF

  # A deterministic stand-in for wp_remote so phase_scan can run for real
  # (not dry-run-only) without a live WordPress/wp-cli install.
  wp_remote() {
    local alias_lc="$1"; shift
    local args="$*"
    case "$args" in
      "post-type list --format=json") echo '[]' ;;
      "option list --format=json") echo '[]' ;;
      "db tables --format=list --all-tables-with-prefix") printf 'wp_options\nwp_posts\n' ;;
      "plugin list --format=json") echo '[]' ;;
      "theme list --status=active --format=json") echo '[{"stylesheet":"twentytwentyfour","version":"1.0"}]' ;;
      "theme list --status=active --field=name") echo "twentytwentyfour" ;;
      "theme get twentytwentyfour --field=template") echo "twentytwentyfour" ;;
      "menu list --format=json") echo '[]' ;;
      eval*)
        case "$args" in
          *wp_navigation*) echo 'false' ;;
          *functions.php*) echo '{"exists":false}' ;;
          *mu-plugins*) echo '[]' ;;
          *) echo 'null' ;;
        esac
        ;;
      *) echo '[]' ;;
    esac
  }
}

@test "phase_scan fails clearly instead of crashing when --profile is given no value (M2)" {
  run phase_scan --profile
  [ "$status" -eq 1 ]
  [[ "$output" == *"--profile"* ]]
}

@test "phase_scan accepts --dry-run as a flag and still produces valid scan JSON (M2 + M6)" {
  run phase_scan --profile demo --dry-run
  [ "$status" -eq 0 ]
  local run_dir
  run_dir=$(ls -dt "$BATS_TEST_TMPDIR"/runs/demo-* | head -1)
  # If --dry-run had actually short-circuited scan's real queries (the old
  # broken behavior), scan-a.json would contain "[dry-run] ..." text, which
  # is not valid JSON and jq would fail to parse it.
  run jq -e '.post_types == []' "${run_dir}/scan-a.json"
  [ "$status" -eq 0 ]
}

@test "phase_scan also honors SITEGRAFT_DRY_RUN=1 as an env var the same way (M6)" {
  SITEGRAFT_DRY_RUN=1
  run phase_scan --profile demo
  [ "$status" -eq 0 ]
  local run_dir
  run_dir=$(ls -dt "$BATS_TEST_TMPDIR"/runs/demo-* | head -1)
  run jq -e '.post_types == []' "${run_dir}/scan-a.json"
  [ "$status" -eq 0 ]
}

@test "phase_scan writes the run dir and scan JSON files as owner-only (M4)" {
  phase_scan --profile demo
  local run_dir
  run_dir=$(ls -dt "$BATS_TEST_TMPDIR"/runs/demo-* | head -1)
  local dir_mode file_mode
  dir_mode=$(stat -c '%a' "$run_dir" 2>/dev/null || stat -f '%Lp' "$run_dir" 2>/dev/null)
  file_mode=$(stat -c '%a' "${run_dir}/scan-a.json" 2>/dev/null || stat -f '%Lp' "${run_dir}/scan-a.json" 2>/dev/null)
  [ "$dir_mode" = "700" ]
  [ "$file_mode" = "600" ]
}

@test "phase_scan records nav_uses_dynamic_page_list on A only (M5, design doc §0 point 11)" {
  phase_scan --profile demo
  local run_dir
  run_dir=$(ls -dt "$BATS_TEST_TMPDIR"/runs/demo-* | head -1)
  run jq -e '.nav_uses_dynamic_page_list == false' "${run_dir}/scan-a.json"
  [ "$status" -eq 0 ]
  run jq -e '.nav_uses_dynamic_page_list == null' "${run_dir}/scan-b.json"
  [ "$status" -eq 0 ]
}

@test "phase_scan detects a dynamic page-list navigation on A when present (M5)" {
  wp_remote() {
    local alias_lc="$1"; shift
    local args="$*"
    case "$args" in
      "post-type list --format=json") echo '[]' ;;
      "option list --format=json") echo '[]' ;;
      "db tables --format=list --all-tables-with-prefix") echo 'wp_options' ;;
      "plugin list --format=json") echo '[]' ;;
      "theme list --status=active --format=json") echo '[{"stylesheet":"t","version":"1"}]' ;;
      "theme list --status=active --field=name") echo "t" ;;
      "theme get t --field=template") echo "t" ;;
      "menu list --format=json") echo '[]' ;;
      eval*)
        case "$args" in
          *wp_navigation*) echo 'true' ;;
          *functions.php*) echo '{"exists":false}' ;;
          *mu-plugins*) echo '[]' ;;
          *) echo 'null' ;;
        esac
        ;;
      *) echo '[]' ;;
    esac
  }
  phase_scan --profile demo
  local run_dir
  run_dir=$(ls -dt "$BATS_TEST_TMPDIR"/runs/demo-* | head -1)
  run jq -e '.nav_uses_dynamic_page_list == true' "${run_dir}/scan-a.json"
  [ "$status" -eq 0 ]
}

@test "phase_scan only counts a classic menu as detected when it has items (m3, .count > 0)" {
  wp_remote() {
    local alias_lc="$1"; shift
    local args="$*"
    case "$args" in
      "post-type list --format=json") echo '[]' ;;
      "option list --format=json") echo '[]' ;;
      "db tables --format=list --all-tables-with-prefix") echo 'wp_options' ;;
      "plugin list --format=json") echo '[]' ;;
      "theme list --status=active --format=json") echo '[{"stylesheet":"t","version":"1"}]' ;;
      "theme list --status=active --field=name") echo "t" ;;
      "theme get t --field=template") echo "t" ;;
      "menu list --format=json") echo '[{"name":"Empty Menu","count":0}]' ;;
      eval*) echo 'null' ;;
      *) echo '[]' ;;
    esac
  }
  phase_scan --profile demo
  local run_dir
  run_dir=$(ls -dt "$BATS_TEST_TMPDIR"/runs/demo-* | head -1)
  run jq -e '.classic_menus_detected == false' "${run_dir}/scan-a.json"
  [ "$status" -eq 0 ]
}

@test "a wp-cli deprecation notice on stderr during an otherwise-successful menu list call does not corrupt scan-a.json (N2)" {
  # Simulates exactly what N2 warned about: a notice/warning on stderr
  # from a call that still exits 0 and prints valid JSON on stdout. With
  # the old "2>&1" capture, that notice text would have been merged into
  # the value later parsed via --argjson, breaking jq. Here "menu list"
  # succeeds (exit 0, valid JSON on stdout) but also writes to stderr.
  wp_remote() {
    local alias_lc="$1"; shift
    local args="$*"
    case "$args" in
      "post-type list --format=json") echo '[]' ;;
      "option list --format=json") echo '[]' ;;
      "db tables --format=list --all-tables-with-prefix") echo 'wp_options' ;;
      "plugin list --format=json") echo '[]' ;;
      "theme list --status=active --format=json") echo '[{"stylesheet":"t","version":"1"}]' ;;
      "theme list --status=active --field=name") echo "t" ;;
      "theme get t --field=template") echo "t" ;;
      "menu list --format=json")
        echo "PHP Deprecated: some notice in wp-content/plugins/whatever.php on line 42" >&2
        echo '[{"name":"Main","count":2}]'
        ;;
      eval*) echo 'null' ;;
      *) echo '[]' ;;
    esac
  }
  run phase_scan --profile demo
  [ "$status" -eq 0 ]
  local run_dir
  run_dir=$(ls -dt "$BATS_TEST_TMPDIR"/runs/demo-* | head -1)
  run jq -e '.classic_menus_detected == true and .classic_menus_unknown == false and (.classic_menu_names == ["Main"])' "${run_dir}/scan-a.json"
  [ "$status" -eq 0 ]
}

@test "phase_scan's own belt-and-suspenders guard rejects a missing SITEGRAFT_STATE_DIR even if profile_load's check were ever bypassed (BLOCKER)" {
  # profile_load's required-key check is the primary defense (see
  # test_profile.bats) — this exercises phase_scan's independent second
  # layer directly, by stubbing profile_load itself to simulate that first
  # layer having been bypassed or regressed.
  profile_load() { unset SITEGRAFT_STATE_DIR; SITE_A_WP_PATH=/tmp/a; SITE_B_WP_PATH=/tmp/b; return 0; }
  run phase_scan --profile demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"SITEGRAFT_STATE_DIR"* ]]
}

@test "phase_scan treats a failed classic-menu query as unverified, not as clean (NIT-1, fail closed like M3)" {
  wp_remote() {
    local alias_lc="$1"; shift
    local args="$*"
    case "$args" in
      "post-type list --format=json") echo '[]' ;;
      "option list --format=json") echo '[]' ;;
      "db tables --format=list --all-tables-with-prefix") echo 'wp_options' ;;
      "plugin list --format=json") echo '[]' ;;
      "theme list --status=active --format=json") echo '[{"stylesheet":"t","version":"1"}]' ;;
      "theme list --status=active --field=name") echo "t" ;;
      "theme get t --field=template") echo "t" ;;
      "menu list --format=json") return 1 ;;
      eval*) echo 'null' ;;
      *) echo '[]' ;;
    esac
  }
  run phase_scan --profile demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not verify whether site A has classic nav menu"* ]] || false
  local run_dir
  run_dir=$(ls -dt "$BATS_TEST_TMPDIR"/runs/demo-* | head -1)
  run jq -e '.classic_menus_unknown == true and .classic_menus_detected == true' "${run_dir}/scan-a.json"
  [ "$status" -eq 0 ]
}
