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
  load '../../lib/inventory.sh'
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
  [[ "$output" == *"plugin-x"* ]] || false
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
  [[ "$output" == *"etch_settings"* ]] || false
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
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
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

# Security-review fix-pack (Kimi, MAJOR, missed by the first review pass —
# CRITICAL for DACH/FR sites, this tool's primary use case): jq's own text
# output and PHP's json_encode (what `wp option get --format=json` actually
# uses) disagree on escaping `/` and non-ASCII. Any migrated option holding
# a URL or an accented character must compare EQUAL after both sides are
# canonicalized, even though the raw TEXT differs.

@test "verify_options_match does not false-hard-fail on a URL value whose slashes are escaped differently (jq vs PHP json_encode)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  # File on disk: jq's own re-serialization (graft_migrate_options' domain
  # rewrite path) — jq does NOT escape "/".
  printf '{"logo_url":"https://b.example.com/x"}' > "${run_dir}/option-etch_styles.value"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_styles"]}}}'
  # B's live re-fetch: always PHP json_encode (`wp option get --format=json`),
  # which DOES escape "/" by default — the exact same decoded value, spelled
  # differently.
  wp_remote() { printf '{"logo_url":"https:\\/\\/b.example.com\\/x"}'; }
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
}

@test "verify_options_match does not false-hard-fail on a value with an accented character (jq raw UTF-8 vs PHP \\uXXXX escaping)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '{"label":"Über uns"}' > "${run_dir}/option-blogdescription.value"
  local manifest='{"migrate":{"core-wp":{"option_keys":["blogdescription"]}}}'
  wp_remote() { printf '{"label":"\\u00dcber uns"}'; }
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
}

@test "verify_options_match still correctly fails when the DECODED values genuinely differ, not just their escaping" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '{"logo_url":"https://b.example.com/x"}' > "${run_dir}/option-etch_styles.value"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_styles"]}}}'
  wp_remote() { printf '{"logo_url":"https:\\/\\/b.example.com\\/DIFFERENT-PATH"}'; }
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"etch_styles"* ]] || false
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
  [[ "$output" == *"key_one"* ]] || false
  [[ "$output" == *"key_two"* ]] || false
}

# --- verify_domain_absent ----------------------------------------------------
# Rewritten in the security-review fix-pack (Viktor + Kimi): the previous SQL
# `UNION ... LIMIT` version was a DEAD check (invalid MySQL/MariaDB syntax on
# every single invocation, swallowed by `2>/dev/null || echo ""`, so it
# always reported "absent" regardless of B's real content — confirmed live
# by Marcel reading a real verify-report.md against a B that provably still
# carried A's domain). Rebuilt as a single `wp eval`, PHP-side strpos() on
# raw fetched bytes, scoped to graft's own write surface (migrated post_ids
# + migrated option_keys — never a table-wide scan, which would hard-fail on
# B's own legitimate, out-of-scope data), and fail-CLOSED on any error.

@test "verify_domain_absent's payload is scoped to migrated post_ids and option_keys only, never a table name" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}}}'
  local captured="$BATS_TEST_TMPDIR/captured.json"
  graft_push_remap_payload() { printf '%s' "$2" > "$captured"; echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() { echo "OK"; }
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ "$status" -eq 0 ]
  run jq -e '.post_ids == ["42","105"] and .option_keys == ["etch_settings"] and .domain == "https://a.example.com"' "$captured"
  [ "$status" -eq 0 ]
}

@test "verify_domain_absent passes (OK) when wp eval reports the domain absent from every scoped surface" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() { echo "OK"; }
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ "$status" -eq 0 ]
}

@test "verify_domain_absent fails when wp eval reports a hit, and names it" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() { echo "HIT:post:105"; }
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ "$status" -eq 1 ]
  [[ "$output" == *"post:105"* ]] || false
}

@test "verify_domain_absent's wp eval requires the shared content-remap library and calls sitegraft_domain_present for both surfaces" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  local manifest='{"migrate":{"core-wp":{"option_keys":["etch_settings"]}}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  # Test-quality fix-pack bug found live (also masked until now by the same
  # bash 3.2 [[ ]]-under-set-e quirk this fix-pack's `|| false` pass
  # addresses): this was the ONE verify_domain_absent test in this file
  # that never stubbed wp_remote — every sibling test above does
  # (`wp_remote() { echo "OK"; }` etc.). Setting SITEGRAFT_DRY_RUN=1 alone
  # does NOT substitute for a stub here: unlike lib/graft.sh's remap
  # functions (which wrap their call as `run_or_echo wp_remote b eval ...`
  # AT THE CALL SITE, so the literal string "wp_remote" is what run_or_echo
  # itself echoes under dry-run, before wp_remote's own body ever runs),
  # verify_domain_absent calls `wp_remote b eval ...` bare — dry-run
  # handling happens INSIDE the real wp_remote (lib/inventory.sh), which
  # first requires SITE_B_WP_PATH to be set at all, unset here, so the real
  # wp_remote failed immediately with "missing SITE_B_WP_PATH" (to stderr,
  # swallowed by this function's own `2>/dev/null` on that call) — an empty
  # $result, which verify_domain_absent's own fail-closed design correctly
  # reports as "could not run", not the PHP body this test actually wants
  # to inspect. A plain stub that echoes its own invocation (matching the
  # literal-"wp_remote"-prefix convention the graft.sh sibling tests get
  # for free via run_or_echo) is what's actually needed.
  wp_remote() { echo "wp_remote $*"; }
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [[ "$output" == *"wp_remote b eval"* ]] || false
  [[ "$output" == *"require_once"* ]] || false
  [[ "$output" == *"sitegraft-content-remap-functions.php"* ]] || false
  # sitegraft_domain_present() must be called for the post-content surface
  # AND the options surface — a regression back to two independently
  # hand-written strpos pairs (review fix-pack, Viktor, MINOR) would still
  # pass every OTHER test in this file (they only stub wp_remote's RESULT,
  # never inspect what PHP was actually sent), so this is the one test that
  # actually looks at the eval body itself.
  [[ "$(echo "$output" | grep -c 'sitegraft_domain_present(')" -ge 3 ]] || false
  [[ "$output" != *"strpos( \$post->post_content"* ]] || false # the old inline duplication must be gone, not just supplemented
}

# Security-review fix-pack (Kimi, BLOCKER, root cause): fails CLOSED, not
# open — a query that ERRORS must never be silently read as "absent". This
# is the exact class of bug that made the old SQL version a dead check that
# always reported PASS.
@test "verify_domain_absent fails CLOSED (never a silent pass) when the wp eval call itself errors" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() { return 1; } # simulates a real wp-cli/connectivity failure
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ "$status" -eq 1 ]
}

@test "verify_domain_absent fails CLOSED when wp eval returns an unrecognized result instead of OK/HIT" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() { echo "some garbage that is neither OK nor HIT:"; }
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ "$status" -eq 1 ]
}

@test "verify_domain_absent always removes both the pushed payload file and the pushed lib file, pass or fail" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}}}'
  local removed="$BATS_TEST_TMPDIR/removed-marker"
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { echo "$2" >> "$removed"; }
  wp_remote() { echo "HIT:post:105"; } # a FAILING check
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ -f "$removed" ]
  grep -qx "/fake/remote/path.json" "$removed"
  grep -qx "/fake/remote/lib.php" "$removed"
}

@test "verify_domain_absent is a no-op (passes) when domain is empty" {
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  run verify_domain_absent "$BATS_TEST_TMPDIR/run" "$BATS_TEST_TMPDIR/id-map.tsv" '{"migrate":{}}' ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_domain_absent is a no-op post_ids list (never calls graft_migrated_post_ids_json) when id-map.tsv is empty/missing" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv" # never created — no posts imported this run
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}}}'
  local captured="$BATS_TEST_TMPDIR/captured.json"
  graft_push_remap_payload() { printf '%s' "$2" > "$captured"; echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() { echo "OK"; }
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ "$status" -eq 0 ]
  run jq -e '.post_ids == []' "$captured"
  [ "$status" -eq 0 ]
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
  [[ "$output" == *"999"* ]] || false
  [[ "$output" == *"105"* ]] || false
}

@test "verify_page_on_front is a no-op when A never had a front page configured" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  : > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_page_on_front "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
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
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
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
  [[ "$output" == *"--profile"* ]] || false
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

# --- MAJOR-A (review fix-pack): phase_verify used to set
# SITEGRAFT_DRY_RUN=1 for --dry-run and never reset it, unlike phase_scan's
# own M6 fix for the identical situation (lib/inventory.sh). Every check in
# this file reads B through wp_remote, whose REAL implementation wraps its
# command in run_or_echo (lib/core.sh) — under dry-run that returns the
# literal text "[dry-run] wp_remote ..." instead of B's actual value, which
# every check here (being written fail-closed) then reports as a HARD FAIL
# on a graft that actually succeeded. This test's wp_remote stub is
# deliberately made is_dry_run-AWARE (mimicking exactly the one aspect of
# the real wp_remote/run_or_echo relevant to this bug) specifically so it
# reproduces the failure before the fix: with SITEGRAFT_DRY_RUN left at 1
# throughout (the pre-fix behavior), every call below would hit the
# `is_dry_run` branch and return dry-run-echo text instead of the same
# canned-good data the base passing test above uses, and the report would
# show a false HARD FAIL. After the fix (phase_verify resets
# SITEGRAFT_DRY_RUN=0 before any wp_remote call, same as scan), is_dry_run
# is false by the time this stub runs, so it returns the real canned data
# and the report passes clean — proving verify's OWN dry-run neutralization
# actually ran, not merely that this stub ignores dry-run.
@test "phase_verify --dry-run still runs the real checks and passes on a correct graft (MAJOR-A: dry-run must never fake a HARD FAIL)" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    if is_dry_run; then
      echo "[dry-run] wp_remote ${alias_lc} $*"
      return 0
    fi
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      eval) echo "" ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR" --dry-run
  [ "$status" -eq 0 ]
  [ -f "${RUN_DIR}/verify-report.md" ]
  if grep -q "HARD FAIL" "${RUN_DIR}/verify-report.md"; then
    echo "verify-report.md contains a HARD FAIL line on a graft that should have passed cleanly:" >&2
    cat "${RUN_DIR}/verify-report.md" >&2
    return 1
  fi
  grep -q "protected data unchanged" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify also honors SITEGRAFT_DRY_RUN=1 as an env var the same way --dry-run does (MAJOR-A, env-var path)" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    if is_dry_run; then
      echo "[dry-run] wp_remote ${alias_lc} $*"
      return 0
    fi
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      eval) echo "" ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  SITEGRAFT_DRY_RUN=1 run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  ! grep -q "HARD FAIL" "${RUN_DIR}/verify-report.md"
}

# Test-quality fix-pack (Kimi): the previous version of this test passed
# because `inventory_table_prefix` was never stubbed/loaded at all (an
# undefined function under bats — "command not found"), which made
# backup_compute_protected_checksums fail and phase_verify's own `||
# recomputed='{}'` fallback force a mismatch, REGARDLESS of what the
# wp_remote "db" stub returned. The mismatch it caught was a plumbing
# accident, not the comparator doing its job. Loading lib/inventory.sh
# (setup(), above) plus a real "eval" stub branch makes
# inventory_table_prefix genuinely resolve, and both checksums below are
# REAL `backup_checksum` outputs of deliberately different content — this
# test now only passes if the comparator itself correctly detects a real
# content difference. Paired with the positive test right after it (same
# comparator, matching content, must NOT hard-fail) so together they'd
# catch a comparator broken in EITHER direction (always-mismatch or
# always-match).
@test "phase_verify exits non-zero when a protected checksum genuinely differs (real content, real comparator — not a stubbing accident)" {
  setup_phase_verify_fixture
  local pre_sum; pre_sum=$(backup_checksum "PRE-GRAFT PROTECTED CONTENT")
  cat > "${RUN_DIR}/manifest.json" <<EOF
{
  "frozen": true,
  "checksums_protected_pre_graft": {"fakebooking": "sha256:${pre_sum}"},
  "migrate": {},
  "protect": {"fakebooking": {"tables": ["fakebooking_reservations"]}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;; # inventory_table_prefix
      db) echo "POST-GRAFT CONTAMINATED CONTENT" ;; # deliberately different from the pre-graft content above
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  grep -q "HARD FAIL: protected data changed" "${RUN_DIR}/verify-report.md"
  grep -q "fakebooking" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify's checksum check PASSES when the recomputed content genuinely matches (same comparator, opposite outcome)" {
  setup_phase_verify_fixture
  local pre_sum; pre_sum=$(backup_checksum "IDENTICAL PROTECTED CONTENT")
  cat > "${RUN_DIR}/manifest.json" <<EOF
{
  "frozen": true,
  "checksums_protected_pre_graft": {"fakebooking": "sha256:${pre_sum}"},
  "migrate": {},
  "protect": {"fakebooking": {"tables": ["fakebooking_reservations"]}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;;
      db) echo "IDENTICAL PROTECTED CONTENT" ;;
      option) echo "105" ;; # page_on_front on B, remapped correctly (shared fixture's id-map.tsv: 5 -> 105)
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -q "protected data unchanged" "${RUN_DIR}/verify-report.md"
}

# --- phase_verify: domain check wiring (scoped, fail-closed) ----------------

@test "phase_verify hard-fails when the domain check finds a real hit" {
  setup_phase_verify_fixture
  jq '.options.search_replace.from = "https://a.example.com"' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "HIT:post:105" ;;
      option) echo "105" ;;
      post) return 0 ;;
      db) echo "" ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  grep -q "HARD FAIL: A's domain string is still present" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify's domain check PASSES when verify_domain_absent confirms absence" {
  setup_phase_verify_fixture
  jq '.options.search_replace.from = "https://a.example.com"' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "OK" ;;
      option) echo "105" ;;
      post) return 0 ;;
      db) echo "" ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -q "A's domain string is absent" "${RUN_DIR}/verify-report.md"
}

# --- phase_verify: orphan check wiring (fail-closed) ------------------------

@test "phase_verify hard-fails when the orphan post_parent check itself errors (fail closed, not open)" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      db) echo "" ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { return 1; } # simulates a real query failure
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  grep -q "HARD FAIL: the orphan post_parent check could not run" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify reports found orphans as a warning, not a hard fail" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      db) echo "" ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo "42"; } # a genuine orphan, query itself succeeded
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -q "orphan post_parent references found" "${RUN_DIR}/verify-report.md"
  ! grep -q "HARD FAIL.*orphan" "${RUN_DIR}/verify-report.md"
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
