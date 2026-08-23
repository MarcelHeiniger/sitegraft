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

# Issue #34: the loop used to be `for key in $(jq ...)` — UNQUOTED command
# substitution, so the shell word-split the result on IFS. A manifest edited
# by hand after a graft (manifest_validate only rejects a comma/space name
# while the manifest is still frozen — see lib/graft.sh's own comma/space
# check for the identical story on graft_migrate_options) can still carry an
# option key containing a space, and that key would silently turn into two
# lookups for a file that was never written (`option-<fragment>.value`),
# both hit the `[ -f ... ] || continue` guard, and the key was never
# genuinely compared — while `total` was inflated by one PER FRAGMENT, not
# per real key, corrupting the very "N of M compared" count issue #23/#26
# added specifically so a shortened comparison could never pass unnoticed.

@test "verify_options_match compares a key containing a space as ONE key, not two word-split fragments (issue #34)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"same"' > "${run_dir}/option-hero image.value"
  local manifest='{"migrate":{"m":{"option_keys":["hero image"]}}}'
  wp_remote() { echo '"same"'; }
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  # The real bug: today's word-split loop reports 0 of 2 (two fragments,
  # "hero" and "image", neither of which has a value file) instead of the
  # true 1 of 1 — inflating the denominator with fragments that were never
  # actually requested.
  [[ "$output" == *"OPTIONS_COMPARED:1:1"* ]] || false
}

@test "verify_options_match does not silently pass a genuine mismatch on a key containing a space (issue #34)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"a"' > "${run_dir}/option-hero image.value"
  local manifest='{"migrate":{"m":{"option_keys":["hero image"]}}}'
  wp_remote() { echo '"DIFFERENT"'; } # B's live value genuinely differs
  run verify_options_match "$run_dir" "$manifest"
  # Today's word-split loop never finds "option-hero.value" or
  # "option-image.value" (the file is "option-hero image.value"), so the
  # comparison never runs at all -- a REAL mismatch reported as though
  # nothing was wrong (status 0, mismatched empty), instead of either
  # comparing it correctly (status 1, naming the key) or at minimum
  # reporting it as not compared with an honest 1-key total.
  [ "$status" -eq 1 ]
  [[ "$output" == *"hero image"* ]] || false
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
  # An option key IS selected on purpose: this test is about the post_ids
  # half of the scope being empty, not about the whole scope being empty
  # (that case is its own test below, and is NOT a pass).
  local manifest='{"migrate":{"core-wp":{"option_keys":["etch_settings"]}}}'
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

# --- Viktor's re-review of PR #26, BLOCKING (B1): the same fail-open class
# this whole PR exists to close, still live inside the check that closes
# #22. With no id-map.tsv AND no selected option keys, the payload is
# `{"post_ids": [], "option_keys": [], "domain": "..."}` — the PHP body
# loops over two empty arrays, `$hits` stays empty, and the function
# returned 0 having examined literally nothing, while the report line
# CLAIMS "migrated posts + migrated options" were examined. That state is
# reachable in exactly the run this PR is about: lib/graft.sh warns and
# leaves id-map.tsv untouched when the mu-plugin didn't run, making every
# later remap a no-op.
@test "verify_domain_absent returns 2 (INCOMPLETE, never a pass) when nothing at all is in scope — 0 migrated posts AND 0 migrated options" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv" # never created — the mu-plugin didn't run
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}}}'
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  graft_remove_file() { :; }
  wp_remote() { echo "OK"; } # a wp eval over two empty arrays says "OK" — that is the trap
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ "$status" -eq 2 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# The counterpart requirement: a run that DID examine something must say how
# much it examined, on the same "(N of M compared)" principle issue #23
# established for the options line — a bare tick is what let the defect
# above hide in the first place.
@test "verify_domain_absent reports the size of the scope it actually examined" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}}}'
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() { echo "OK"; }
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOMAIN_SCOPE:2:1"* ]] || false
}

# --- verify_page_on_front ----------------------------------------------------
# Issue #12: verify_page_on_front now also takes the manifest, so it can tell
# apart "page_on_front wasn't part of this run's migrate selection" (no
# opinion to have) from "it WAS selected and A had one configured, but
# id-map.tsv has no entry for it" (the remap did not happen — a hard
# failure, not the exemption the old trailing clause granted it).

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
  run verify_page_on_front "$run_dir" "$tsv" '{"migrate":{"core-wp":{"option_keys":["page_on_front"]}}}'
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
  run verify_page_on_front "$run_dir" "$tsv" '{"migrate":{"core-wp":{"option_keys":["page_on_front"]}}}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"999"* ]] || false
  [[ "$output" == *"105"* ]] || false
}

@test "verify_page_on_front is a no-op when A never had a front page configured (page_on_front selected, but A's own value is 0)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"0"' > "${run_dir}/option-page_on_front.value"
  local tsv="${run_dir}/id-map.tsv"
  : > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_page_on_front "$run_dir" "$tsv" '{"migrate":{"core-wp":{"option_keys":["page_on_front"]}}}'
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_page_on_front is a no-op when page_on_front was not part of this run's migrate selection" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  # A stale option-page_on_front.value + id-map.tsv from a PRIOR run that DID
  # select it, still sitting in run_dir — this run's manifest does not select
  # it. Must not be treated as a failed remap of THIS run.
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="${run_dir}/id-map.tsv"
  : > "$tsv" # no mapping — would be a hard fail if this run had selected page_on_front
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  local manifest='{"migrate":{"core-wp":{"option_keys":["page"]}}}'
  run verify_page_on_front "$run_dir" "$tsv" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# --- Issue #12: the core defect — the remap not happening was treated as an
# exemption ("A never configured one") instead of a failure. A configured
# front page IS on disk (a real page ID, not 0/null/empty) and page_on_front
# WAS part of this run's migrate selection, but id-map.tsv has no entry for
# that page ID — core_wp_post_import's remap did not happen (or the ID
# mapper was missing, or the imported post silently failed). This must be a
# hard failure, not a pass.
@test "verify_page_on_front fails when A had a front page configured and selected, but id-map.tsv has no entry for it (the remap did not happen)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"16"' > "${run_dir}/option-page_on_front.value" # A's front page: page 16
  local tsv="${run_dir}/id-map.tsv"
  printf '99\t199\tpage\n' > "$tsv" # some OTHER page's mapping — nothing for 16
  wp_remote() { echo "SHOULD NOT BE CALLED — no live lookup should happen once the remap itself is known to have failed"; }
  run verify_page_on_front "$run_dir" "$tsv" '{"migrate":{"core-wp":{"option_keys":["page_on_front"]}}}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"16"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# --- Nat's review of PR #26: the same "0 of N" shape #23 fixed for
# migrated-options exists here too. page_on_front IS selected, so
# graft_migrate_options unconditionally writes option-page_on_front.value —
# its absence means the migrate_options step itself never reached this key
# (an interrupted run, not yet resumed). The OLD code read the missing file
# via `tr -d '"' < missing_file`, got an empty string back, and the
# ''|null|false|0 case below silently folded that into "A never configured
# one" — a PASS on data that was simply never produced. This must return a
# THIRD, distinct exit code (2) so phase_verify can report it as INCOMPLETE,
# never as a plain pass.
@test "verify_page_on_front returns exit code 2 (INCOMPLETE, not a pass) when page_on_front is selected but its value file was never written" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  # option-page_on_front.value deliberately NOT created — selected, but
  # graft's migrate_options step never reached it.
  local tsv="${run_dir}/id-map.tsv"
  : > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_page_on_front "$run_dir" "$tsv" '{"migrate":{"core-wp":{"option_keys":["page_on_front"]}}}'
  [ "$status" -eq 2 ]
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

# --- Issue #22: the domain check vanishes from the report when no domain is
# configured ------------------------------------------------------------------
#
# phase_verify used to wrap the domain check in `if [ -n "$domain" ]`. With no
# domain configured the check was skipped AND NOTHING WAS WRITTEN TO THE
# REPORT — no [x], no [ ], no warning. The reader could not tell a check was
# skipped, and "Result: PASS" printed regardless.
#
# The page_on_front check at least prints a line carrying its own caveat.
# This one left no trace at all. Note the shared fixture's manifest already
# sets "from": "" — so the existing suite has been exercising the skipped
# path all along, green, without ever asserting the report says anything
# about it.
@test "phase_verify records the domain check even when no domain is configured" {
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
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  # Whatever the outcome, the report must account for the domain check —
  # not silently drop it while still printing Result: PASS.
  grep -qi "domain" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify's domain line explicitly marks the check not applicable when no domain is configured (not indistinguishable from a real pass)" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  local domain_line
  domain_line=$(grep -i "domain" "${RUN_DIR}/verify-report.md")
  [[ "$domain_line" == *"not applicable"* ]] || false
}

# --- Issue #23: "migrated options match" is ticked having compared nothing --
#
# verify_options_match skips any key with no "option-<key>.value" file
# (lib/verify.sh) — deliberate, and correct: a key graft never reached is not
# this function's job to have an opinion about. But the REPORT did not carry
# that nuance: it printed a plain
#   - [x] migrated options match A's values on B
# even when zero options were actually compared — exactly what a run
# interrupted before the options step and then resumed produces. A green
# tick for a check that checked nothing is the same defect PR #9 already
# fixed for "protected data unchanged".
@test "phase_verify does not claim migrated options match when none could be compared" {
  setup_phase_verify_fixture
  local pre_sum; pre_sum=$(backup_checksum "IDENTICAL PROTECTED CONTENT")
  cat > "${RUN_DIR}/manifest.json" <<EOF
{
  "frozen": true,
  "checksums_protected_pre_graft": {"fakebooking": "sha256:${pre_sum}"},
  "migrate": {"etch": {"option_keys": ["etch_settings", "etch_styles"]}},
  "protect": {"fakebooking": {"tables": ["fakebooking_reservations"]}},
  "stack": {},
  "options": {"search_replace": {"from": "https://a.example.com", "to": "https://b.example.com"}}
}
EOF
  # No option-*.value files exist in RUN_DIR: graft never reached that step
  # (a run interrupted before migrate_options and then resumed past it).
  rm -f "${RUN_DIR}"/option-*.value
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;;
      db) echo "IDENTICAL PROTECTED CONTENT" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  verify_domain_absent() { return 0; }
  run phase_verify --profile t --run "$RUN_DIR"
  ! grep -qx -- "- \[x\] migrated options match A's values on B" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify reports the exact compared-vs-selected count when migrated options genuinely all match" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"etch": {"option_keys": ["etch_settings", "etch_styles"]}},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  printf '{"a":1}' > "${RUN_DIR}/option-etch_settings.value"
  printf '{"b":2}' > "${RUN_DIR}/option-etch_styles.value"
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option)
        # $1=option $2=get $3=<key> $4=--format=json — differentiate by key.
        if [ "$3" = "etch_settings" ]; then echo '{"a":1}';
        elif [ "$3" = "etch_styles" ]; then echo '{"b":2}';
        else echo "105"; fi ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -q "migrated options match A's values on B (2 of 2 compared)" "${RUN_DIR}/verify-report.md"
}

# --- Nat's blocking review of PR #26: an UNVERIFIED line must not let
# Result: PASS print, and the overall exit code must be non-zero ---------
#
# The first pass of the #23 fix wrote "UNVERIFIED" into the report body but
# never told phase_verify's own hard_fail bookkeeping about it — the report
# contradicted itself (a line saying "not a pass" under a footer saying
# "Result: PASS"), and CLAUDE.md's first rule is exactly "a check must
# distinguish verified true from could not verify... report unknown, NEVER
# OK". PASS is OK. This introduces a genuine third result state —
# INCOMPLETE — distinct from both PASS (0) and HARD FAIL (1), with its own
# exit code (2), so a caller testing $? cannot mistake "some check could not
# run" for "everything passed" OR for "something is confirmed wrong".
@test "phase_verify's overall Result is INCOMPLETE (not PASS) and exit status is non-zero when migrated options could not be compared" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"etch": {"option_keys": ["etch_settings", "etch_styles"]}},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  rm -f "${RUN_DIR}"/option-*.value # nothing written this run — interrupted before migrate_options
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  ! grep -q "Result: PASS" "${RUN_DIR}/verify-report.md"
  ! grep -q "Result: HARD FAIL" "${RUN_DIR}/verify-report.md"
  # the INCOMPLETE result must name which check(s) it covers, not just say
  # "something, somewhere" — this is the same "list the affected checks"
  # requirement as the HARD FAIL summary line already has.
  grep "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md" | grep -qi "migrated-options"
}

@test "phase_verify's Result stays PASS with exit status 0 when nothing at all was selected for option migration (0 of 0 is not incomplete)" {
  setup_phase_verify_fixture # shared fixture only selects page_on_front (excluded from the options count) -> 0 of 0
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -q "Result: PASS" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify's Result stays PASS with exit status 0 when no domain was configured (not applicable is a known fact, not an uncertainty)" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -q "Result: PASS" "${RUN_DIR}/verify-report.md"
}

# --- Same defect, sibling function: page_on_front selected but its value
# file was never written (graft interrupted before migrate_options reached
# it) used to silently fold into "A never configured one" via the missing
# file -> empty string -> ''|null|false|0 case. Now returns exit code 2
# (verify_page_on_front's own test above), and phase_verify must turn that
# into INCOMPLETE, never a pass.
@test "phase_verify's overall Result is INCOMPLETE when page_on_front was selected but its value file was never written" {
  setup_phase_verify_fixture
  rm -f "${RUN_DIR}/option-page_on_front.value" # selected (see fixture manifest) but never written this run
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  grep "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md" | grep -qi "page_on_front"
}

# --- HARD FAIL must outrank INCOMPLETE when a run has both: a confirmed
# defect is a stronger, more actionable signal than "some other check
# lacked data", and the exit code must reflect the worse of the two.
@test "phase_verify's Result is HARD FAIL, not INCOMPLETE, when a run has both a hard failure and an incomplete check (exit code stays 1)" {
  setup_phase_verify_fixture
  local pre_sum; pre_sum=$(backup_checksum "PRE-GRAFT PROTECTED CONTENT")
  cat > "${RUN_DIR}/manifest.json" <<EOF
{
  "frozen": true,
  "checksums_protected_pre_graft": {"fakebooking": "sha256:${pre_sum}"},
  "migrate": {"etch": {"option_keys": ["etch_settings"]}, "core-wp": {"option_keys": ["page_on_front"]}},
  "protect": {"fakebooking": {"tables": ["fakebooking_reservations"]}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  rm -f "${RUN_DIR}/option-etch_settings.value" # etch_settings selected but never written -> incomplete
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;;
      db) echo "POST-GRAFT CONTAMINATED CONTENT" ;; # deliberately different -> HARD FAIL
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "Result: HARD FAIL" "${RUN_DIR}/verify-report.md"
  ! grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
}

# --- Viktor's re-review of PR #26, BLOCKING (B1), wiring half. The unit
# tests above prove verify_domain_absent's own three-valued contract; these
# prove phase_verify actually HONORS it. `elif verify_domain_absent ...` (the
# shape this file used) folds 2 into "non-zero" and mislabels an empty scope
# as a HARD FAIL — the identical pitfall the page_on_front wiring already
# documents at its own `|| front_rc=$?`.
@test "phase_verify's domain line names how many posts and options were actually scanned" {
  setup_phase_verify_fixture
  jq '.options.search_replace.from = "https://a.example.com"' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/m.tmp" && mv "${RUN_DIR}/m.tmp" "${RUN_DIR}/manifest.json"
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
  grep -qF "1 migrated post(s) + 1 migrated option(s) scanned" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify's Result is INCOMPLETE (not PASS, not HARD FAIL) when the domain check had nothing in scope to examine" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"core-wp": {"post_types": ["page"], "option_keys": []}},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {},
  "options": {"search_replace": {"from": "https://a.example.com", "to": "https://b.example.com"}}
}
EOF
  : > "${RUN_DIR}/id-map.tsv" # graft warned the mu-plugin never ran: every remap after it was a no-op
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
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
  [ "$status" -eq 2 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  ! grep -q "Result: PASS" "${RUN_DIR}/verify-report.md"
  ! grep -q "Result: HARD FAIL" "${RUN_DIR}/verify-report.md"
  grep "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md" | grep -qi "domain-absence"
  # and it must NOT still claim, on the check's own line, to have looked at
  # the migrated posts and options — that claim is the whole defect.
  ! grep -qF -- "- [x] A's domain string is absent" "${RUN_DIR}/verify-report.md"
}

# --- Viktor's re-review of PR #26, BLOCKING (B2): three `hard_fail=1`
# assignments could each be deleted outright and the entire suite stayed
# green — the report said HARD FAIL while `verify` exited 0. Issue #12's
# acceptance criterion is "a run where the front-page remap did not happen
# FAILS verify", and verify is the phase plus its exit code, not a line of
# prose in a file. Each test below asserts BOTH the exit status and the
# report footer; asserting only the text is what let the mutation survive.
@test "phase_verify exits 1 with Result: HARD FAIL when page_on_front on B is not the remapped page (issue #12's actual acceptance criterion)" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "999" ;; # some other page entirely — the remap did not land
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "Result: HARD FAIL" "${RUN_DIR}/verify-report.md"
  grep -q "HARD FAIL: page_on_front does not resolve" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify exits 1 with Result: HARD FAIL when a migrated option's live value on B does not match what graft wrote" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"etch": {"option_keys": ["etch_settings"]}},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  printf '"dark"' > "${RUN_DIR}/option-etch_settings.value" # what graft migrated from A
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo '"light"' ;; # B drifted
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "Result: HARD FAIL" "${RUN_DIR}/verify-report.md"
  grep -q "HARD FAIL: migrated option value mismatch" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify exits 1 with Result: HARD FAIL when wp_navigation was migrated but B has no navigation post" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"core-wp": {"post_types": ["wp_navigation"], "option_keys": []}},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post)
        if [ "$2" = "list" ]; then echo ""; else return 0; fi # no wp_navigation posts on B
        ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "Result: HARD FAIL" "${RUN_DIR}/verify-report.md"
  grep -q "HARD FAIL: wp_navigation was migrated but B has no navigation post" "${RUN_DIR}/verify-report.md"
}

# --- Viktor's re-review of PR #26, N1: verify_page_on_front returns 0 for
# THREE different reasons and the report printed one byte-identical line for
# all three — the same ambiguous disjunction issue #12 was filed about,
# simply moved from the code into the report, and inconsistent with the
# domain line this PR just made explicit.
@test "phase_verify's page_on_front line says VERIFIED, and names the page, when the remap really was checked against B" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  # Asserted as the WHOLE line, not a substring: the point of N1 is that the
  # three success outcomes must not share wording, and a substring match
  # would still pass if the line kept its old "(or A never configured one)"
  # disjunction appended to it.
  local front_line; front_line=$(grep -F -- "] page_on_front" "${RUN_DIR}/verify-report.md")
  [ "$front_line" = "- [x] page_on_front resolves to the correctly remapped page on B (post 105)" ]
}

@test "phase_verify's page_on_front line says NOT SELECTED, distinctly, when page_on_front was not part of this run's migrate selection" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"core-wp": {"post_types": ["page"], "option_keys": []}},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  local front_line; front_line=$(grep -F -- "] page_on_front" "${RUN_DIR}/verify-report.md")
  [ "$front_line" = "- [x] page_on_front (not applicable — page_on_front was not part of this run's migrate selection)" ]
}

@test "phase_verify's page_on_front line says A NEVER CONFIGURED ONE, distinctly, when A's own recorded value is 0" {
  setup_phase_verify_fixture
  printf '"0"' > "${RUN_DIR}/option-page_on_front.value" # A's own value: A had no front page
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  local front_line; front_line=$(grep -F -- "] page_on_front" "${RUN_DIR}/verify-report.md")
  [ "$front_line" = "- [x] page_on_front (not applicable — A's own recorded value says A never configured a front page)" ]
}

# The three branches above are selected by a marker the function itself
# prints. A fourth success path added later without a marker must not
# silently inherit one of the three claims — the default is UNVERIFIED, in
# keeping with this file's fail-closed rule.
@test "phase_verify reports page_on_front as UNVERIFIED when the check succeeds without saying which of its outcomes applied" {
  setup_phase_verify_fixture
  verify_page_on_front() { return 0; } # a future success path that forgot its marker
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  grep "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md" | grep -qi "page_on_front"
}

# --- N2: `- [ ]` now means "not verified" everywhere else in this report,
# so the skipped HTTP smoke check must not keep an unticked box while the
# footer says PASS. It is a KNOWN not-applicable (no SITE_B_URL in the
# profile), exactly like the no-domain-configured case.
@test "phase_verify marks the skipped HTTP smoke check as a ticked not-applicable, never as an unchecked box" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -qF -- "- [x] HTTP smoke check (not applicable — no SITE_B_URL configured in this profile)" "${RUN_DIR}/verify-report.md"
  ! grep -qF -- "- [ ] HTTP smoke check skipped" "${RUN_DIR}/verify-report.md"
}

# --- N3: the manifest is read by `jq` in every check below, but was never
# validated as JSON. A malformed manifest.json made every `jq` call fail
# quietly, and the report came out with four misleading `[x]` ticks plus a
# HARD FAIL attributed to "protected data changed" — a wrong diagnosis
# pointing the operator at the wrong problem entirely.
@test "phase_verify refuses to run at all against a manifest.json that is not valid JSON" {
  setup_phase_verify_fixture
  printf '{ this is not json at all' > "${RUN_DIR}/manifest.json"
  wp_remote() { echo ""; }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid JSON"* ]] || false
  # and it must not have produced a report full of ticks about checks it
  # could not possibly have performed
  [ ! -f "${RUN_DIR}/verify-report.md" ]
}

# --- N4: `jq -r '.options.search_replace.from // ""'` maps "the key is
# absent" onto "the key is empty", so a hand-written manifest with no
# `.options` at all printed "not applicable — no domain was configured" as
# though that were a fact read from the manifest. It is not a fact; it is
# the absence of one. (lib/graft.sh documents the same hand-written-manifest
# case at its own `.options.search_replace.from` read.)
@test "phase_verify reports the domain check as NOT VERIFIABLE, not as not-applicable, when the manifest has no options.search_replace.from" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"core-wp": {"post_types": ["page"], "option_keys": []}},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {}
}
EOF
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -qF "not verifiable — the manifest has no options.search_replace.from" "${RUN_DIR}/verify-report.md"
  ! grep -q "no domain was configured" "${RUN_DIR}/verify-report.md"
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
}

# --- N6: the INCOMPLETE footer joined its check names with a trailing space
# and then appended a period, printing "... migrated-options ." to every
# operator reading the report.
@test "phase_verify's INCOMPLETE footer has no stray space before its final period" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"etch": {"option_keys": ["etch_settings"]}},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  rm -f "${RUN_DIR}"/option-*.value
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -qF "could not be verified: migrated-options." "${RUN_DIR}/verify-report.md"
}

# --- Same N1 defect class as page_on_front, one check further down and not
# in Viktor's list: "expected navigation is present on B (or wp_navigation
# was not part of this run's migrate selection)" is the identical ambiguous
# disjunction, ticked identically for two different facts. Shipping the
# page_on_front fix while leaving its sibling reading the old way would make
# two adjacent lines in the same report use opposite conventions.
@test "phase_verify's navigation line says VERIFIED, and counts the posts, when wp_navigation really was migrated" {
  setup_phase_verify_fixture
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"core-wp": {"post_types": ["wp_navigation"], "option_keys": []}},
  "protect": {"_unclaimed": {"tables": []}},
  "stack": {},
  "options": {"search_replace": {"from": "", "to": ""}}
}
EOF
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post)
        if [ "$2" = "list" ]; then printf '77\n78\n'; else return 0; fi
        ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  local nav_line; nav_line=$(grep -F -- "] expected navigation" "${RUN_DIR}/verify-report.md")
  [ "$nav_line" = "- [x] expected navigation is present on B (2 wp_navigation post(s) found)" ]
}

@test "phase_verify's navigation line says NOT SELECTED, distinctly, when wp_navigation was not part of this run's migrate selection" {
  setup_phase_verify_fixture # fixture migrates post_types ["page"], never wp_navigation
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  local nav_line; nav_line=$(grep -F -- "] expected navigation" "${RUN_DIR}/verify-report.md")
  [ "$nav_line" = "- [x] expected navigation (not applicable — wp_navigation was not part of this run's migrate selection)" ]
}

# --- Re-review of the fix-pack (both reviewers, converging from two
# different angles on the same class): the marker `case` blocks for
# page_on_front and navigation each got a fail-closed default branch, but
# the DOMAIN_SCOPE one did not — and the nav one had no test. Both branches
# are UNREACHABLE today (every success path emits its marker as its last
# echo). That is exactly why they need tests: their whole reason to exist is
# the future success path that forgets its marker, and a guard nothing holds
# in place is the guard the next refactor deletes without anything saying so.
@test "phase_verify reports the domain check as UNVERIFIED when it succeeds without reporting the scope it examined" {
  setup_phase_verify_fixture
  jq '.options.search_replace.from = "https://a.example.com"' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/m.tmp" && mv "${RUN_DIR}/m.tmp" "${RUN_DIR}/manifest.json"
  verify_domain_absent() { return 0; } # a future success path that forgot its DOMAIN_SCOPE marker
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;; option) echo "105" ;; post) return 0 ;; *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  grep "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md" | grep -qi "domain-absence"
  # and above all it must NOT tick the box while announcing a zero scope —
  # that is finding B1 walking back in through a different door, on the very
  # line B1 was filed against.
  ! grep -qF -- "- [x] A's domain string is absent" "${RUN_DIR}/verify-report.md"
  ! grep -qF "0 migrated post(s) + 0 migrated option(s) scanned" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify reports the navigation check as UNVERIFIED when it succeeds without saying which of its outcomes applied" {
  setup_phase_verify_fixture
  verify_nav_present() { return 0; } # a future success path that forgot its marker
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;; option) echo "105" ;; post) return 0 ;; *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  grep "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md" | grep -qi "navigation"
}
