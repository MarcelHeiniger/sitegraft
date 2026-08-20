# tests/unit/test_verify.bats — phase: verify (design doc §6.5, review finding
# B3). Read-only smoke checks on B after a graft: recomputed protected-data
# checksums (same normalization as backup — finding A5), migrated-option
# values, page_on_front correctness, A's domain absence, orphan post_parent
# refs, expected navigation, a best-effort HTTP smoke check, and the
# stack-component re-licensing reminder. Stubs wp_remote/inventory_table_prefix/
# graft_check_orphan_parents so this stays a fast, real-execution unit test —
# same convention as tests/unit/test_phase_backup.bats. The DDEV integration
# harness (tests/integration/ddev-harness.sh) is the separate, real end-to-end
# proof.
setup() {
  load '../../lib/core.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
  load '../../lib/verify.sh'
}

# --- verify_compare_checksums (pure function) -------------------------------

@test "verify_compare_checksums passes when pre and post checksums match" {
  local manifest='{"checksums_protected_pre_graft":{"plugin-x":"sha256:abc"}}'
  local recomputed='{"plugin-x":"sha256:abc"}'
  run verify_compare_checksums "$manifest" "$recomputed"
  [ "$status" -eq 0 ]
}

@test "verify_compare_checksums hard-fails when a protected checksum changed" {
  local manifest='{"checksums_protected_pre_graft":{"plugin-x":"sha256:abc"}}'
  local recomputed='{"plugin-x":"sha256:DIFFERENT"}'
  run verify_compare_checksums "$manifest" "$recomputed"
  [ "$status" -eq 1 ]
  [[ "$output" == *"plugin-x"* ]]
}

@test "verify_compare_checksums passes when there is nothing protected to compare" {
  local manifest='{"checksums_protected_pre_graft":{}}'
  local recomputed='{}'
  run verify_compare_checksums "$manifest" "$recomputed"
  [ "$status" -eq 0 ]
}

# --- verify_options_match ----------------------------------------------------

@test "verify_options_match fails when B's live value differs from the file graft wrote" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '{"theme_mode":"dark"}' > "${run_dir}/option-etch_settings.value"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}}}'
  wp_remote() { echo '{"theme_mode":"light"}'; } # stub: B's live value differs
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"etch_settings"* ]]
}

@test "verify_options_match passes when B's live value matches" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '{"theme_mode":"dark"}' > "${run_dir}/option-etch_settings.value"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}}}'
  wp_remote() { echo '{"theme_mode":"dark"}'; }
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
}

@test "verify_options_match skips a key graft never wrote an option file for (e.g. page_on_front, remapped separately)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["page_on_front"]}}}'
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}

@test "verify_options_match never compares page_on_front/page_for_posts (remap-aware check lives in verify_page_on_front instead)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  # graft always writes these two files (graft_migrate_options), even though
  # it never blind-pushes their value to B — a bare "no file => skip" guard
  # would NOT catch this case, so this must be an explicit exclusion.
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  printf '"5"' > "${run_dir}/option-page_for_posts.value"
  local manifest='{"migrate":{"core-wp":{"option_keys":["page_on_front","page_for_posts"]}}}'
  wp_remote() { echo '"105"'; } # B's live value is the correctly-remapped ID, NOT "5" — must not be flagged as a mismatch
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
}

@test "verify_options_match reports every mismatched key, not just the first" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"a"' > "${run_dir}/option-key_one.value"
  printf '"b"' > "${run_dir}/option-key_two.value"
  local manifest='{"migrate":{"m":{"option_keys":["key_one","key_two"]}}}'
  wp_remote() { echo '"DIFFERENT"'; }
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"key_one"* ]]
  [[ "$output" == *"key_two"* ]]
}

# --- verify_domain_absent ----------------------------------------------------

@test "verify_domain_absent passes when neither the plain nor the escaped form of the domain is found" {
  wp_remote() { echo ""; } # stub: no query hit
  run verify_domain_absent "b" "a.example.com" "wp_"
  [ "$status" -eq 0 ]
}

@test "verify_domain_absent fails when the plain domain form is found" {
  wp_remote() {
    # stub: only the plain-form query (no backslash) hits
    if [[ "$*" == *'a.example.com'* ]] && [[ "$*" != *'a.example.com'*'\\'* ]]; then
      echo "1"
    fi
  }
  run verify_domain_absent "b" "a.example.com" "wp_"
  [ "$status" -eq 1 ]
}

@test "verify_domain_absent is a no-op (passes) when domain is empty" {
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_domain_absent "b" "" "wp_"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}

# --- verify_page_on_front ----------------------------------------------------

@test "verify_page_on_front passes when B's front page resolves to the correctly remapped page" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_remote() {
    shift # alias
    if [ "$1" = "option" ]; then echo "105";
    elif [ "$1" = "post" ]; then return 0; fi
  }
  run verify_page_on_front "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
}

@test "verify_page_on_front fails when B's front page resolves to the WRONG page" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_remote() {
    shift
    if [ "$1" = "option" ]; then echo "999"; # some OTHER existing page, not the remap
    elif [ "$1" = "post" ]; then return 0; fi
  }
  run verify_page_on_front "$run_dir" "$tsv"
  [ "$status" -eq 1 ]
  [[ "$output" == *"999"* ]]
  [[ "$output" == *"105"* ]]
}

@test "verify_page_on_front is a no-op when A never had a front page configured" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  : > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_page_on_front "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}

# --- verify_nav_present ------------------------------------------------------

@test "verify_nav_present fails when wp_navigation was migrated but B has no navigation post" {
  local manifest='{"migrate":{"core-wp":{"post_types":["wp_navigation"]}}}'
  wp_remote() { echo ""; } # stub: no wp_navigation posts on B
  run verify_nav_present "$manifest"
  [ "$status" -eq 1 ]
}

@test "verify_nav_present passes when wp_navigation was migrated and B has a navigation post" {
  local manifest='{"migrate":{"core-wp":{"post_types":["wp_navigation"]}}}'
  wp_remote() { echo "12"; } # stub: one wp_navigation post ID on B
  run verify_nav_present "$manifest"
  [ "$status" -eq 0 ]
}

@test "verify_nav_present is a no-op when wp_navigation was never in the migrate selection" {
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_nav_present "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}

# --- verify_http_smoke --------------------------------------------------------

@test "verify_http_smoke is a no-op (passes) when no URL is configured" {
  run verify_http_smoke ""
  [ "$status" -eq 0 ]
}

@test "verify_http_smoke passes on 200 plus expected marker text" {
  curl() { printf '200'; } # stub: last invocation's stdout is the code
  # verify_http_smoke fetches the body separately; stub both call shapes
  curl() {
    for a in "$@"; do
      case "$a" in
        -o) echo "200"; return 0 ;;
      esac
    done
    printf '<html><body>Welcome Home</body></html>'
  }
  run verify_http_smoke "https://b.example.com" "Home"
  [ "$status" -eq 0 ]
}

@test "verify_http_smoke fails on a non-200 status" {
  curl() {
    for a in "$@"; do
      case "$a" in
        -o) echo "500"; return 0 ;;
      esac
    done
    printf 'Internal Server Error'
  }
  run verify_http_smoke "https://b.example.com" "Home"
  [ "$status" -eq 1 ]
}

@test "verify_http_smoke fails on 200 with a body missing the expected marker (build green != route OK)" {
  curl() {
    for a in "$@"; do
      case "$a" in
        -o) echo "200"; return 0 ;;
      esac
    done
    printf '<html><body>Something else entirely</body></html>'
  }
  run verify_http_smoke "https://b.example.com" "Home"
  [ "$status" -eq 1 ]
}

# --- phase_verify (wiring) ----------------------------------------------------

setup_phase_verify_fixture() {
  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  export SITEGRAFT_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$SITEGRAFT_PROFILES_DIR" "$SITEGRAFT_STATE_DIR"
  load '../../lib/profile.sh'
  cat > "${SITEGRAFT_PROFILES_DIR}/t.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/var/www/b"
SITE_B_WP_CMD="wp"
SITEGRAFT_STATE_DIR="${SITEGRAFT_STATE_DIR}"
EOF
  RUN_DIR="${SITEGRAFT_STATE_DIR}/t-20260101T000000"
  mkdir -p "$RUN_DIR"
  printf '5\t105\tpage\n' > "${RUN_DIR}/id-map.tsv"
  printf '"5"' > "${RUN_DIR}/option-page_on_front.value"
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"core-wp": {"post_types": ["page"], "option_keys": ["page_on_front"]}},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
}

@test "phase_verify requires --profile" {
  load '../../lib/profile.sh'
  run phase_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"--profile"* ]]
}

@test "phase_verify writes a report and exits 0 when every check passes" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;                 # db export (nothing protected to hash)
      option) echo "105" ;;          # page_on_front on B, remapped correctly
      post) return 0 ;;              # post get: exists
      eval) echo "" ;;               # orphan check: none
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ -f "${RUN_DIR}/verify-report.md" ]
  grep -q "protected data unchanged" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify exits non-zero when a protected checksum mismatches" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {"fakebooking": "sha256:abc"},
  "migrate": {},
  "protect": {"fakebooking": {"tables": ["wp_fakebooking"]}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "totally different content" ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  grep -q "HARD FAIL" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify lists copied stack components as a re-licensing reminder, not a pass/fail check" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {"etch": {"resolution": "copy"}},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;; # matches the shared fixture's id-map.tsv remap of page_on_front (5 -> 105)
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -q "REMINDER" "${RUN_DIR}/verify-report.md"
  grep -q "etch" "${RUN_DIR}/verify-report.md"
}
