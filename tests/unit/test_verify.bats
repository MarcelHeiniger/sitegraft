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

# fd 3, not stdin, is not stylistic: in production wp_remote (lib/inventory.sh)
# shells out to `ssh` with no `-n` and no `</dev/null`, so `ssh` DRAINS stdin.
# A read loop fed on stdin (`while read -r key; do ... done <<< "$keys"`)
# would have the loop body's own `ssh` call swallow the rest of the piped-in
# keys on its first iteration -- reproduced: 4 keys in, `ssh` drains stdin on
# key 1, loop exits after 1 iteration, reports "1 of 1 compared" (a full
# PASS) having never looked at keys 2-4. Every wp_remote stub in this suite
# is a plain `echo` that never touches stdin, so no other test here would
# catch a regression back to a stdin-based loop -- this one stubs wp_remote
# the way the real one behaves (drains stdin) specifically to pin fd 3 down.
@test "verify_options_match reads keys on fd 3, so a loop-body command that drains stdin (ssh) cannot swallow the remaining keys" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  for k in k1 k2 k3 k4; do printf '"same"' > "${run_dir}/option-${k}.value"; done
  local manifest='{"migrate":{"m":{"option_keys":["k1","k2","k3","k4"]}}}'
  # production wp_remote shells out to `ssh` with no -n and no </dev/null
  # (lib/inventory.sh), so it DRAINS stdin. On a stdin-based loop this
  # reports 1 of 1 -- a full [x] PASS over three keys never looked at.
  wp_remote() { cat >/dev/null; echo '"same"'; }
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPTIONS_COMPARED:4:4"* ]] || false
}

# `IFS=` on the read itself (not just fd 3) is load-bearing too: `read`
# strips leading/trailing IFS whitespace from a single captured field even
# with `-r`, unless IFS is cleared first. A key with a boundary space is
# just as reachable as "hero image"'s internal space (phase_verify never
# re-validates a hand-edited manifest -- see this function's own header
# comment), and without `IFS=` it would silently become a DIFFERENT,
# trimmed key, missing its real "option-<key>.value" file the same way an
# internal-space split does.
@test "verify_options_match preserves a key's leading/trailing space, rather than trimming it (IFS= on the read, not just fd 3)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"same"' > "${run_dir}/option- padded.value"
  local manifest='{"migrate":{"m":{"option_keys":[" padded"]}}}'
  wp_remote() { echo '"same"'; }
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPTIONS_COMPARED:1:1"* ]] || false
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

# --- _verify_wxr_items_remapped (shared helper, issue #52) ------------------
# Real end-to-end tests: genuine WXR file(s) on disk, the genuine php CLI
# driver (lib/php/verify-content-remap-cli.php) — the one place in this
# suite that exercises the real PHP side of issue #52's content-equality
# guards, not a bash-level stub of it. verify_migrated_content_matches_source
# and verify_migrated_content_changed_from_pregraft (below) stub this helper
# directly and stay fast, pure-bash unit tests of their own comparison
# logic — see their own sections.

setup_wxr_fixture() {
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
  RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "${RUN_DIR}/export"
}

wxr_item_xml() {
  # $1=post_id $2=post_type $3=content $4=excerpt
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel>
<wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_id>${1}</wp:post_id><wp:post_type>${2}</wp:post_type><content:encoded><![CDATA[${3}]]></content:encoded><excerpt:encoded><![CDATA[${4}]]></excerpt:encoded></item>
</channel>
</rss>
EOF
}

@test "_verify_wxr_items_remapped parses and remaps A's exported WXR for real (end-to-end PHP call)" {
  setup_wxr_fixture
  wxr_item_xml 5 page "hello" "" > "${RUN_DIR}/export/one.xml"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"options":{"search_replace":{"from":"","to":""}}}'
  run _verify_wxr_items_remapped "$RUN_DIR" "${RUN_DIR}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  run jq -e '. == [{"post_id":5,"post_type":"page","post_content":"hello","post_excerpt":""}]' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "_verify_wxr_items_remapped applies the same domain remap graft's own search-replace step uses" {
  setup_wxr_fixture
  wxr_item_xml 5 page 'link https:\/\/a.example.com\/x' "" > "${RUN_DIR}/export/one.xml"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"options":{"search_replace":{"from":"https://a.example.com","to":"https://b.example.com"}}}'
  run _verify_wxr_items_remapped "$RUN_DIR" "${RUN_DIR}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  local want='link https:\/\/b.example.com\/x'
  run jq -e --arg want "$want" '.[0].post_content == $want' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "_verify_wxr_items_remapped feeds id-map.tsv's attachment rows into the payload as the attachment id-remap map" {
  setup_wxr_fixture
  wxr_item_xml 5 page '"id":7' "" > "${RUN_DIR}/export/one.xml"
  printf '7\t42\tattachment\n' > "${RUN_DIR}/id-map.tsv"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"options":{"search_replace":{"from":"","to":""}}}'
  run _verify_wxr_items_remapped "$RUN_DIR" "${RUN_DIR}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  run jq -e '.[0].post_content == "\"id\":42"' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "_verify_wxr_items_remapped returns [] and exit 0 when nothing (non-attachment) is selected for migration" {
  setup_wxr_fixture
  local manifest='{"migrate":{"media":{"post_types":["attachment"]}},"options":{"search_replace":{"from":"","to":""}}}'
  run _verify_wxr_items_remapped "$RUN_DIR" "${RUN_DIR}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_verify_wxr_items_remapped returns 2 (INCOMPLETE) when post_types are selected but no WXR export exists in run_dir" {
  setup_wxr_fixture
  rmdir "${RUN_DIR}/export"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"options":{"search_replace":{"from":"","to":""}}}'
  run _verify_wxr_items_remapped "$RUN_DIR" "${RUN_DIR}/id-map.tsv" "$manifest"
  [ "$status" -eq 2 ]
}

@test "_verify_wxr_items_remapped returns 1 (HARD FAIL, fails closed) when the php driver itself cannot run" {
  setup_wxr_fixture
  wxr_item_xml 5 page "hello" "" > "${RUN_DIR}/export/one.xml"
  SITEGRAFT_ROOT="$BATS_TEST_TMPDIR/nonexistent-root" # points the driver path at nothing
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"options":{"search_replace":{"from":"","to":""}}}'
  run _verify_wxr_items_remapped "$RUN_DIR" "${RUN_DIR}/id-map.tsv" "$manifest"
  [ "$status" -eq 1 ]
}

# --- verify_migrated_content_matches_source (guard 1, issue #52) ------------
# _verify_wxr_items_remapped is stubbed throughout this section — its own
# real-PHP correctness is covered above; these tests are pure-bash and
# focus on this function's own join/compare/report logic.

@test "verify_migrated_content_matches_source passes when B's live content equals the remapped WXR content for every id-map row" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  printf '5\t105\tpage\n' > "${run_dir}/id-map.tsv"
  # review round 3 (MAJOR): graft_run_module_post_import now creates this
  # file unconditionally, even when nothing gets rewritten -- present and
  # empty means "hooks ran, recorded nothing", a real, trustworthy signal.
  : > "${run_dir}/module-content-rewrites.tsv"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { echo '[{"post_id":5,"post_type":"page","post_content":"hello","post_excerpt":""}]'; }
  wp_remote() { echo '[{"ID":105,"post_content":"hello","post_excerpt":""}]'; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTENT_MATCH:1:1"* ]] || false
}

@test "verify_migrated_content_matches_source hard-fails when B's live content does not equal the remapped WXR content" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  printf '5\t105\tpage\n' > "${run_dir}/id-map.tsv"
  : > "${run_dir}/module-content-rewrites.tsv"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { echo '[{"post_id":5,"post_type":"page","post_content":"hello","post_excerpt":""}]'; }
  wp_remote() { echo '[{"ID":105,"post_content":"DIFFERENT","post_excerpt":""}]'; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"105"* ]] || false
}

@test "verify_migrated_content_matches_source is a no-op when no non-attachment post_type is selected" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local manifest='{"migrate":{"media":{"post_types":["attachment"]}}}'
  _verify_wxr_items_remapped() { echo "SHOULD NOT BE CALLED"; }
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTENT_MATCH:not-selected"* ]] || false
}

@test "verify_migrated_content_matches_source reports 0 of 0 compared, not a failure, when id-map.tsv has no rows to check" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { echo '[]'; }
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTENT_MATCH:0:0"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_migrated_content_matches_source propagates INCOMPLETE (2) from the shared WXR helper" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { return 2; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 2 ]
}

@test "verify_migrated_content_matches_source propagates a HARD FAIL (1) from the shared WXR helper's own execution failure" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { return 1; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 1 ]
}

# --- verify_migrated_content_changed_from_pregraft (guard 2, issue #52) -----
# The mutation-target guard: ADR 0008 says this guard, ALONE, must catch the
# observed defect (a colliding item wordpress-importer silently skipped —
# B's row is never touched, so its content-graft checksum never moves). The
# test below ("hard-fails when a paired row's content is IDENTICAL to its
# pre-graft checksum") is that acceptance criterion, reproduced directly.

@test "verify_migrated_content_changed_from_pregraft HARD-FAILS on a skipped item whose B row is byte-identical to its pre-graft checksum (the observed defect)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  # id-map.tsv is EMPTY: nothing imported (post 16 -- A's front page -- was
  # skipped by wordpress-importer's post_exists() collision, exactly ADR
  # 0008's Context section).
  : > "${run_dir}/id-map.tsv"
  local manifest
  manifest=$(jq -n '{migrate: {"core-wp": {post_types: ["page"]}}, content_checksums_pre_graft: {"16": "sha256:UNCHANGED"}}')
  _verify_wxr_items_remapped() { echo '[{"post_id":16,"post_type":"page","post_content":"whatever A has","post_excerpt":""}]'; }
  # B's CURRENT content checksums to the exact same value recorded before
  # the graft -- the row was never touched.
  wp_remote() { echo '[{"ID":16,"post_content":"B'"'"'s own old front page","post_excerpt":""}]'; }
  backup_content_checksum_of_row() { echo "UNCHANGED"; } # stub: current == pre-graft
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"16"* ]] || false
}

@test "verify_migrated_content_changed_from_pregraft passes when a paired row's content genuinely differs from its pre-graft checksum" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  : > "${run_dir}/id-map.tsv"
  local manifest
  manifest=$(jq -n '{migrate: {"core-wp": {post_types: ["page"]}}, content_checksums_pre_graft: {"16": "sha256:OLD"}}')
  _verify_wxr_items_remapped() { echo '[{"post_id":16,"post_type":"page","post_content":"x","post_excerpt":""}]'; }
  wp_remote() { echo '[{"ID":16,"post_content":"new content","post_excerpt":""}]'; }
  backup_content_checksum_of_row() { echo "NEW"; } # stub: differs from pre-graft's "OLD"
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
}

# review finding B5 (issue #52 fix-pack): this used to be a PASS. It is
# not one -- an item WAS skipped (999), and this guard could not confirm
# ANYTHING about it (no pre-graft record for its id) -- so it must report
# INCOMPLETE, not silently tick "0 of 1 confirmed changed" as if that were
# equivalent to "nothing was skipped at all".
@test "verify_migrated_content_changed_from_pregraft is INCOMPLETE (not a pass) when a skipped item exists but none of its ids has a pre-graft record" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  : > "${run_dir}/id-map.tsv"
  local manifest
  manifest=$(jq -n '{migrate: {"core-wp": {post_types: ["page"]}}, content_checksums_pre_graft: {}}')
  _verify_wxr_items_remapped() { echo '[{"post_id":999,"post_type":"page","post_content":"x","post_excerpt":""}]'; }
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 2 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# The genuine pass case B5 leaves untouched: nothing was skipped AT ALL
# (every WXR item is already accounted for in id-map.tsv), so there is
# truly nothing for this guard to examine -- distinct from the test above,
# where something WAS skipped but could not be paired.
@test "verify_migrated_content_changed_from_pregraft passes when nothing was skipped at all" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  printf '999	105	page
' > "${run_dir}/id-map.tsv"
  local manifest
  manifest=$(jq -n '{migrate: {"core-wp": {post_types: ["page"]}}, content_checksums_pre_graft: {}}')
  _verify_wxr_items_remapped() { echo '[{"post_id":999,"post_type":"page","post_content":"x","post_excerpt":""}]'; }
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_migrated_content_changed_from_pregraft treats an id-map.tsv entry as NOT skipped (no false positive on a genuinely-imported post)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  printf '16\t105\tpage\n' > "${run_dir}/id-map.tsv" # 16 WAS imported, as new post 105
  local manifest
  manifest=$(jq -n '{migrate: {"core-wp": {post_types: ["page"]}}, content_checksums_pre_graft: {"16": "sha256:OLD"}}')
  _verify_wxr_items_remapped() { echo '[{"post_id":16,"post_type":"page","post_content":"x","post_excerpt":""}]'; }
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_migrated_content_changed_from_pregraft returns 2 (INCOMPLETE) when the manifest has no content_checksums_pre_graft key at all (a run from before this feature)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  : > "${run_dir}/id-map.tsv"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { echo '[{"post_id":16,"post_type":"page","post_content":"x","post_excerpt":""}]'; }
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 2 ]
}

@test "verify_migrated_content_changed_from_pregraft is a no-op when no non-attachment post_type is selected" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local manifest='{"migrate":{"media":{"post_types":["attachment"]}},"content_checksums_pre_graft":{}}'
  _verify_wxr_items_remapped() { echo "SHOULD NOT BE CALLED"; }
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTENT_UNCHANGED:not-selected"* ]] || false
}

@test "verify_migrated_content_changed_from_pregraft propagates INCOMPLETE (2) from the shared WXR helper" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local manifest
  manifest=$(jq -n '{migrate: {"core-wp": {post_types: ["page"]}}, content_checksums_pre_graft: {}}')
  _verify_wxr_items_remapped() { return 2; }
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 2 ]
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
  # post_types is deliberately empty here (issue #52): this shared base
  # fixture is reused by ~50 phase_verify tests that exercise every OTHER
  # check (options, domain, page_on_front, orphans, navigation, HTTP
  # smoke) and were never about content equality — an empty post_types
  # keeps both of issue #52's new content guards a clean, WXR-free
  # "not-selected" pass for all of them, exactly like an unrelated real
  # run that never selected post content for migration. The handful of
  # tests that DO need to exercise the content guards set up their own
  # dedicated fixture instead (see the "phase_verify + content guards"
  # section below) rather than overloading this one.
  cat > "${RUN_DIR}/manifest.json" <<'EOF'
{
  "frozen": true,
  "checksums_protected_pre_graft": {},
  "migrate": {"core-wp": {"post_types": [], "option_keys": ["page_on_front"]}},
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
  "migrate": {"core-wp": {"post_types": [], "option_keys": []}},
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
  # issue #52: the base fixture's id-map.tsv row (post 5 -> 105, page) is
  # irrelevant to this test and not accounted for by an empty WXR export —
  # cleared so the new content guards see nothing to compare (0 id-map
  # rows in scope) rather than flagging it as unexplained.
  : > "${RUN_DIR}/id-map.tsv"
  mkdir -p "${RUN_DIR}/export"
  printf '<?xml version="1.0"?><rss xmlns:wp="http://wordpress.org/export/1.2/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"><channel><wp:wxr_version>1.2</wp:wxr_version></channel></rss>' > "${RUN_DIR}/export/empty.xml"
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
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
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

# --- phase_verify + content guards (issue #52, end-to-end) ------------------
# Real WXR parsing, real php driver (lib/php/verify-content-remap-cli.php),
# real backup_content_checksum_of_row — the highest-fidelity proof available
# short of the DDEV harness. The first test below is ADR 0008's own
# acceptance criterion, reproduced directly: "the test must prove the check
# can fail: assert it hard-fails against a run whose import was skipped."

@test "phase_verify HARD FAILS when the import silently skipped an item (ADR 0008 / issue #52 acceptance criterion)" {
  setup_phase_verify_fixture
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"

  # Nothing imported this run (id-map.tsv empty) -- exactly the observed
  # defect: A's front page (id 16) collided with B's own and
  # wordpress-importer silently skipped it.
  : > "${RUN_DIR}/id-map.tsv"
  mkdir -p "${RUN_DIR}/export"
  cat > "${RUN_DIR}/export/one.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel>
<wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_id>16</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[<p>New design from A</p>]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>
</channel>
</rss>
XML

  local b_row='{"ID":16,"post_content":"B old front page","post_excerpt":""}'
  local pre_sum; pre_sum="sha256:$(backup_content_checksum_of_row "$b_row")"

  jq -n --arg sum "$pre_sum" '{
    frozen: true,
    checksums_protected_pre_graft: {},
    migrate: {"core-wp": {post_types: ["page"], option_keys: []}},
    protect: {"_unclaimed": {tables: []}},
    stack: {},
    options: {search_replace: {from: "", to: ""}},
    content_checksums_pre_graft: {"16": $sum}
  }' > "${RUN_DIR}/manifest.json"

  wp_remote() {
    local alias_lc="$1"; shift
    case "$1 $2" in
      "post list") echo '[{"ID":16,"post_content":"B old front page","post_excerpt":""}]' ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }

  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "Result: HARD FAIL" "${RUN_DIR}/verify-report.md"
  grep -q "byte-identical to its pre-graft state" "${RUN_DIR}/verify-report.md"
}

# MUTATION PROOF (do this by hand, not part of the suite — same convention
# tests/unit/test_content_remap_write.bats' own docblock uses): comment out
# the two lines in lib/verify.sh's phase_verify that call
# verify_migrated_content_changed_from_pregraft and set hard_fail=1 on its
# failure, then rerun this file: the test above goes from PASS to FAIL,
# because nothing in the rest of phase_verify's six pre-existing checks
# would have caught this run at all — exactly ADR 0008's point. Revert
# afterward.

# Review finding B2: with the REAL SITEGRAFT_ROOT (needed so the real php
# driver can be invoked), modules/etch.sh genuinely exists on disk, so a
# migrated `page` is EXCLUDED from guard 1's strict equality claim (etch's
# own post_import hook may also rewrite its content) -- this is the
# correct, honest behavior, not a bug: guard 1 reports it as excluded
# rather than falsely claiming byte-equality, and the run still passes
# overall because guard 2 (which does not depend on B2's exclusion at all)
# independently confirms nothing was skipped.
@test "phase_verify's Result stays PASS when a post module-content-rewrites.tsv names is excluded from guard 1's strict equality, alongside a real comparison (review finding B2, round 2)" {
  setup_phase_verify_fixture
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"

  # Two migrated pages: 105 is the one a module hook actually rewrote
  # (excluded); 106 is an ordinary page nothing touched (compared for
  # real) -- the floor (B2 part b) would make an ALL-excluded scope
  # INCOMPLETE, so a genuine PASS needs at least one checkable row too.
  printf '16\t105\tpage\n17\t106\tpage\n' > "${RUN_DIR}/id-map.tsv"
  # graft_record_module_content_rewrite (lib/graft.sh) writes this file --
  # simulating a module's post_import hook having ACTUALLY rewritten post
  # 105's content (an Etch component-ref remap, say), never a blanket
  # exclusion by post_type.
  printf '105\n' > "${RUN_DIR}/module-content-rewrites.tsv"
  mkdir -p "${RUN_DIR}/export"
  cat > "${RUN_DIR}/export/one.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel>
<wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_id>16</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[<p>New design from A</p>]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>
<item><wp:post_id>17</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[<p>An ordinary page</p>]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>
</channel>
</rss>
XML

  jq -n '{
    frozen: true,
    checksums_protected_pre_graft: {},
    migrate: {"core-wp": {post_types: ["page"], option_keys: []}},
    protect: {"_unclaimed": {tables: []}},
    stack: {},
    options: {search_replace: {from: "", to: ""}},
    content_checksums_pre_graft: {}
  }' > "${RUN_DIR}/manifest.json"

  wp_remote() {
    local alias_lc="$1"; shift
    local a
    for a in "$@"; do
      case "$a" in
        --post__in=*)
          case "$a" in
            *105*) echo "105 WAS FETCHED -- B2's exclusion did not hold" >&2; return 1 ;;
          esac
          ;;
      esac
    done
    case "$1 $2" in
      "post list") echo '[{"ID":106,"post_content":"<p>An ordinary page</p>","post_excerpt":""}]' ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }

  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -q "Result: PASS" "${RUN_DIR}/verify-report.md"
  grep -q "migrated content matches A's on B (1 of 1 compared; 1 post(s) excluded" "${RUN_DIR}/verify-report.md"
  [[ "$(cat "${RUN_DIR}/verify-report.md")" != *"105 WAS FETCHED"* ]] || false
}
# The genuine strict-equality pass: no module-content-rewrites.tsv exists
# for this run (review round 2's B2 fix means SITEGRAFT_ROOT/module-file
# presence is irrelevant to this guard now -- the REAL SITEGRAFT_ROOT is
# used here, unlike round 1's now-removed scratch-root workaround), so
# post 105 is genuinely checkable and guard 1 performs a REAL
# byte-for-byte comparison end to end.
@test "phase_verify's Result stays PASS with a real (non-excluded) content-equality comparison, when nothing was recorded as module-rewritten" {
  setup_phase_verify_fixture
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"

  printf '16\t105\tpage\n' > "${RUN_DIR}/id-map.tsv"
  # review round 3 (MAJOR): present-and-empty is what graft_run_module_
  # post_import (lib/graft.sh) actually produces when nothing was
  # module-rewritten -- an absent file is now INCOMPLETE, a different
  # state this test is not about.
  : > "${RUN_DIR}/module-content-rewrites.tsv"
  mkdir -p "${RUN_DIR}/export"
  cat > "${RUN_DIR}/export/one.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel>
<wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_id>16</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[<p>New design from A</p>]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>
</channel>
</rss>
XML

  jq -n '{
    frozen: true,
    checksums_protected_pre_graft: {},
    migrate: {"core-wp": {post_types: ["page"], option_keys: []}},
    protect: {"_unclaimed": {tables: []}},
    stack: {},
    options: {search_replace: {from: "", to: ""}},
    content_checksums_pre_graft: {}
  }' > "${RUN_DIR}/manifest.json"

  wp_remote() {
    local alias_lc="$1"; shift
    case "$1 $2" in
      "post list") echo '[{"ID":105,"post_content":"<p>New design from A</p>","post_excerpt":""}]' ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }

  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -q "Result: PASS" "${RUN_DIR}/verify-report.md"
  grep -q "migrated content matches A's on B (1 of 1 compared)" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify reports the content guards as UNVERIFIED (INCOMPLETE) when post_types are selected but no WXR export exists" {
  setup_phase_verify_fixture
  jq '.migrate = {"core-wp": {"post_types": ["page"], "option_keys": []}}' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
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
  grep "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md" | grep -qi "migrated-content"
}

@test "phase_verify --dry-run still runs the content guards for real (MAJOR-A's own trap, reproduced for issue #52's checks)" {
  # The exact pitfall lib/verify.sh's own phase_verify header warns about:
  # every read in this file goes through wp_remote, whose real command is
  # wrapped in run_or_echo (lib/core.sh) -- under SITEGRAFT_DRY_RUN=1 that
  # returns the literal text "[dry-run] wp_remote ..." instead of B's
  # actual data. A content guard that failed to notice would parse that
  # text as JSON, get nothing usable, and report a false HARD FAIL on a
  # graft that actually succeeded -- phase_verify's own is_dry_run reset at
  # the top of the function is what is supposed to prevent that; this test
  # proves it actually covers the two NEW checks too, not just the six that
  # existed before issue #52.
  setup_phase_verify_fixture
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"

  printf '16\t105\tpage\n' > "${RUN_DIR}/id-map.tsv"
  # review round 3 (MAJOR): present-and-empty, not absent -- see the
  # sibling PASS test above for why. This still genuinely exercises guard
  # 1's wp_remote read (and therefore the dry-run echo path this test is
  # about) rather than short-circuiting on an exclusion, since the file
  # being empty means nothing is excluded.
  : > "${RUN_DIR}/module-content-rewrites.tsv"
  mkdir -p "${RUN_DIR}/export"
  cat > "${RUN_DIR}/export/one.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel>
<wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_id>16</wp:post_id><wp:post_type>page</wp:post_type><content:encoded><![CDATA[<p>New design from A</p>]]></content:encoded><excerpt:encoded><![CDATA[]]></excerpt:encoded></item>
</channel>
</rss>
XML

  jq -n '{
    frozen: true,
    checksums_protected_pre_graft: {},
    migrate: {"core-wp": {post_types: ["page"], option_keys: []}},
    protect: {"_unclaimed": {tables: []}},
    stack: {},
    options: {search_replace: {from: "", to: ""}},
    content_checksums_pre_graft: {}
  }' > "${RUN_DIR}/manifest.json"

  wp_remote() {
    local alias_lc="$1"; shift
    if is_dry_run; then
      echo "[dry-run] wp_remote ${alias_lc} $*"
      return 0
    fi
    case "$1 $2" in
      "post list") echo '[{"ID":105,"post_content":"<p>New design from A</p>","post_excerpt":""}]' ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }

  run phase_verify --profile t --run "$RUN_DIR" --dry-run
  [ "$status" -eq 0 ]
  if grep -q "HARD FAIL" "${RUN_DIR}/verify-report.md"; then
    echo "verify-report.md contains a HARD FAIL line on a graft that should have passed cleanly:" >&2
    cat "${RUN_DIR}/verify-report.md" >&2
    return 1
  fi
  grep -q "migrated content matches A's on B (1 of 1 compared)" "${RUN_DIR}/verify-report.md"
}

# --- review finding B1: --post_type/--post_status=any on the live fetch ----
# `wp post list --post__in=...` with NO --post_type silently defaults to
# post_type=post (WP_Query::get_posts()'s own final `else` branch,
# wp-includes/class-wp-query.php). Every OTHER wp_remote stub in this file
# ignores flags entirely (matches on the subcommand only), which is
# structurally incapable of catching this class of bug -- these two tests
# use a FLAG-AWARE stub that actually reproduces wp-cli's real
# post_type-defaulting behavior, specifically so they can rot if the
# --post_type argument is ever dropped again.

@test "verify_migrated_content_changed_from_pregraft scopes its live fetch with --post_type (review finding B1) — flag-aware stub, execution-proven" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  : > "${run_dir}/id-map.tsv" # nothing imported -- id 16 (a page) was skipped
  local manifest
  manifest=$(jq -n '{migrate: {"core-wp": {post_types: ["page"]}}, content_checksums_pre_graft: {"16": "sha256:UNCHANGED"}}')
  _verify_wxr_items_remapped() { echo '[{"post_id":16,"post_type":"page","post_content":"new from A","post_excerpt":""}]'; }
  backup_content_checksum_of_row() { echo "UNCHANGED"; }

  # A REALISTIC wp-cli emulation: B genuinely holds post ID 16 as a PAGE.
  # `wp post list --post__in=... --format=json` WITHOUT --post_type
  # defaults to post_type=post (WP_Query::get_posts()'s own final `else`
  # branch) and would find NOTHING for a page -- this stub reproduces
  # that real behavior instead of ignoring the flag the way most other
  # stubs in this file do.
  wp_remote() {
    local alias_lc="$1"; shift
    local requested_type="post" a
    for a in "$@"; do
      case "$a" in
        --post_type=*) requested_type="${a#--post_type=}" ;;
      esac
    done
    if [ "$requested_type" = "page" ]; then
      echo '[{"ID":16,"post_content":"B'"'"'s own old front page","post_excerpt":""}]'
    else
      echo '[]'
    fi
  }

  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 1 ]
  # Found id 16 and correctly confirmed it byte-identical to its pre-graft
  # state -- NOT "vanished" (the wrong diagnosis a post_type-blind, empty
  # response would produce instead of the real one).
  [[ "$output" == *" 16 "* || "$output" == *": 16 "* ]] || false
  [[ "$output" != *"no longer on B at all"* ]] || false
}

@test "verify_migrated_content_matches_source scopes its live fetch with --post_type (review finding B1) — flag-aware stub, execution-proven" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  printf '16\t105\tpage\n' > "${run_dir}/id-map.tsv" # genuinely imported, as new post 105
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { echo '[{"post_id":16,"post_type":"page","post_content":"B'"'"'s own old front page","post_excerpt":""}]'; }
  # Present and empty (review round 3, MAJOR): a genuinely absent file
  # now means INCOMPLETE, not "nothing excluded" -- see this file's own
  # comment on graft_run_module_post_import (lib/graft.sh) creating it
  # unconditionally. Empty here means "hooks ran, rewrote nothing", so
  # this row is genuinely checkable and this test exercises the real
  # comparison.
  : > "${run_dir}/module-content-rewrites.tsv"

  wp_remote() {
    local alias_lc="$1"; shift
    local requested_type="post" a
    for a in "$@"; do
      case "$a" in
        --post_type=*) requested_type="${a#--post_type=}" ;;
      esac
    done
    if [ "$requested_type" = "page" ]; then
      echo '[{"ID":105,"post_content":"B'"'"'s own old front page","post_excerpt":""}]'
    else
      echo '[]'
    fi
  }

  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTENT_MATCH:1:1:0"* ]] || false
}

# MUTATION PROOF (do this by hand, not part of the suite — same convention
# tests/unit/test_content_remap_write.bats' own docblock uses): remove
# `--post_type="$post_types_csv" --post_status=any` from EITHER guard's
# `wp_remote b post list --post__in=...` call in lib/verify.sh and rerun
# just these two tests:
#   - the guard-2 test above goes from "found id 16, confirmed unchanged"
#     to reporting it "no longer on B at all" instead — status stays 1
#     (review finding B4's fail-closed fix catches the empty response
#     too), but for the WRONG reason, which is exactly what the assertion
#     on that phrase being ABSENT is there to catch.
#   - the guard-1 test above flips from CONTENT_MATCH:1:1:0/exit 0 to a
#     HARD FAIL ("105(not-found-on-b)") — the exact false-positive the
#     review measured against the pre-fix code (`CONTENT_MATCH:0:1
#     "105(not-found-on-b)"`).
# Revert afterward.

# --- review finding B2 (round 2, the real fix): module post_import hooks --
# exclude a post from guard 1's strict equality claim only when a hook
# ACTUALLY rewrote THAT post (module-content-rewrites.tsv, written by
# graft_record_module_content_rewrite, lib/graft.sh) — never by post_type
# or by whether a module's FILE exists on disk, which excluded everything,
# unconditionally, on any real checkout (round 1's defect, reported by
# review round 2).

@test "verify_migrated_content_matches_source excludes ONLY the posts named in module-content-rewrites.tsv, comparing every other post for real (review finding B2, round 2)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  # Two migrated posts: 105 is the one a module hook actually rewrote
  # (etch's component-ref remap, say); 106 is an ordinary page a hook
  # never touched.
  printf '5\t105\tpage\n6\t106\tpage\n' > "${run_dir}/id-map.tsv"
  printf '105\n' > "${run_dir}/module-content-rewrites.tsv"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  # A's un-remapped WXR content for 105 still carries the OLD Etch
  # component ref (14468) -- graft's own id/domain remap never rewrites
  # "ref":N (only a module's post_import hook does that, AFTER this
  # function's own remap step). 106's content is a plain, unrelated page.
  _verify_wxr_items_remapped() {
    printf '%s' '[{"post_id":5,"post_type":"page","post_content":"ref-14468","post_excerpt":""},{"post_id":6,"post_type":"page","post_content":"hello","post_excerpt":""}]'
  }
  wp_remote() {
    # 105 must NEVER be fetched (it is excluded before any live read) --
    # only 106 should appear in the --post__in list.
    local a
    for a in "$@"; do
      case "$a" in
        --post__in=*)
          case "$a" in
            *105*) echo "105 WAS FETCHED -- B2's exclusion did not hold" >&2; return 1 ;;
          esac
          ;;
      esac
    done
    printf '%s' '[{"ID":106,"post_content":"hello","post_excerpt":""}]'
  }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  # 1 of 1 CHECKABLE compared (106), 1 excluded (105) -- not "0 of 0".
  [[ "$output" == *"CONTENT_MATCH:1:1:1"* ]] || false
}

@test "verify_migrated_content_matches_source returns INCOMPLETE (floor, review finding B2 part b) when EVERY row in scope was excluded" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  printf '5\t105\tpage\n' > "${run_dir}/id-map.tsv"
  printf '105\n' > "${run_dir}/module-content-rewrites.tsv"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { printf '%s' '[{"post_id":5,"post_type":"page","post_content":"x","post_excerpt":""}]'; }
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CONTENT_MATCH:0:0:1"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# MUTATION PROOF for B2, round 2 (executed and reverted below, not left in
# the suite): if the exclusion in verify_migrated_content_matches_source
# (lib/verify.sh) is made unconditional again (e.g. reverting to "does
# modules/etch.sh exist on disk", round 1's defect), the FIRST test above
# fails -- 106 would ALSO be excluded (CONTENT_MATCH:0:0:2, not 1:1:1),
# and the wp_remote stub's own "105 WAS FETCHED" guard would never even
# get a chance to fire because nothing would be fetched at all. Conversely,
# if the exclusion is removed ENTIRELY, the same test fails the other way:
# 105 gets fetched for real, wp_remote's guard clause catches it and
# returns 1, and the live fetch mismatches against A's un-module-remapped
# bytes. Proven by hand, then reverted.

# --- review finding B3: id-map.tsv's `term:`-tagged rows are excluded ------
# --- review finding B3: id-map.tsv's `term:`-tagged rows are excluded ------

@test "verify_migrated_content_matches_source does not false-hard-fail on a term row in id-map.tsv (review finding B3)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  # A term row (mu-plugins/sitegraft-id-mapper.php's wp_import_insert_term
  # handler writes exactly this shape) alongside a real, matched page row.
  printf '5\t105\tpage\n9\t44\tterm:category\n' > "${run_dir}/id-map.tsv"
  : > "${run_dir}/module-content-rewrites.tsv"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { echo '[{"post_id":5,"post_type":"page","post_content":"hello","post_excerpt":""}]'; }
  wp_remote() { echo '[{"ID":105,"post_content":"hello","post_excerpt":""}]'; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTENT_MATCH:1:1:0"* ]] || false
  [[ "$output" != *"44"* ]] || false
}

@test "verify_migrated_content_changed_from_pregraft does not let a colliding term id mask a genuinely skipped page (review finding B3)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  # Term id 16 (a category, say) imported this run -- but post id 16 (A's
  # front page) was SKIPPED. Without the term-row exclusion, this term row
  # would make old_id 16 look "already imported", hiding the skip.
  printf '16\t900\tterm:category\n' > "${run_dir}/id-map.tsv"
  local manifest
  manifest=$(jq -n '{migrate: {"core-wp": {post_types: ["page"]}}, content_checksums_pre_graft: {"16": "sha256:UNCHANGED"}}')
  _verify_wxr_items_remapped() { echo '[{"post_id":16,"post_type":"page","post_content":"new from A","post_excerpt":""}]'; }
  wp_remote() { echo '[{"ID":16,"post_content":"B'"'"'s own old front page","post_excerpt":""}]'; }
  backup_content_checksum_of_row() { echo "UNCHANGED"; }
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"16"* ]] || false
}

# --- review finding B4: a failed live read is a HARD FAIL, never silent ----

@test "verify_migrated_content_changed_from_pregraft fails closed (HARD FAIL) when the live read of B itself fails, never a silent pass (review finding B4)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  : > "${run_dir}/id-map.tsv"
  local manifest
  manifest=$(jq -n '{migrate: {"core-wp": {post_types: ["page"]}}, content_checksums_pre_graft: {"16": "sha256:UNCHANGED"}}')
  _verify_wxr_items_remapped() { echo '[{"post_id":16,"post_type":"page","post_content":"x","post_excerpt":""}]'; }
  wp_remote() { echo "could not connect to B" >&2; return 1; }
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not read B"* ]] || false
}

@test "verify_migrated_content_changed_from_pregraft treats a paired id absent from a SUCCESSFUL response as a finding (vanished from B), not a silent skip (review finding B4)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  : > "${run_dir}/id-map.tsv"
  local manifest
  manifest=$(jq -n '{migrate: {"core-wp": {post_types: ["page"]}}, content_checksums_pre_graft: {"16": "sha256:UNCHANGED"}}')
  _verify_wxr_items_remapped() { echo '[{"post_id":16,"post_type":"page","post_content":"x","post_excerpt":""}]'; }
  wp_remote() { echo '[]'; } # succeeded, but id 16 is simply not in the result
  run verify_migrated_content_changed_from_pregraft "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no longer on B at all"* ]] || false
  [[ "$output" == *"16"* ]] || false
  # review finding B4 (minor): a vanished post gets its OWN message, never
  # reported under the byte-identical-unchanged phrasing (a real, distinct
  # bug from #52's "still byte-identical" one).
  [[ "$output" != *"still byte-identical to their pre-graft state — the migration for these silently did not happen"* ]] || false
}

# --- review finding B5: an unpairable/none-imported guard reports --------
# INCOMPLETE, never a silent PASS.

@test "verify_migrated_content_matches_source is INCOMPLETE, not a pass, when A's WXR had items but id-map.tsv matched none of them (review finding B5)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  : > "${run_dir}/id-map.tsv" # nothing imported at all
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { echo '[{"post_id":16,"post_type":"page","post_content":"x","post_excerpt":""}]'; }
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CONTENT_MATCH:none-imported:1"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# --- review round 3 (MAJOR): module-content-rewrites.tsv's ABSENCE must ---
# be INCOMPLETE, never "nothing excluded" (which used to false-hard-fail a
# genuinely correct graft — a post a module hook DID rewrite, compared
# against A's un-module-remapped bytes).

@test "verify_migrated_content_matches_source returns INCOMPLETE when module-content-rewrites.tsv is entirely ABSENT, never comparing anything (review round 3, MAJOR)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  printf '5\t105\tpage\n' > "${run_dir}/id-map.tsv"
  # No module-content-rewrites.tsv at all -- this run predates graft
  # creating it unconditionally (or a kill mid-hook lost it).
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  # A's un-remapped WXR content still carries the OLD Etch component ref
  # -- if this guard wrongly treated "absent" as "nothing excluded" (round
  # 2's behavior), it would compare this against B's correctly
  # module-remapped live content and false-hard-fail.
  _verify_wxr_items_remapped() { echo '[{"post_id":5,"post_type":"page","post_content":"<!-- wp:etch/component {\"ref\":14468} -->","post_excerpt":""}]'; }
  wp_remote() { echo "SHOULD NOT BE CALLED — an absent record file means INCOMPLETE, before any live fetch"; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CONTENT_MATCH:no-rewrite-record:1"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_migrated_content_matches_source compares for real when module-content-rewrites.tsv is present but genuinely empty (review round 3, MAJOR)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  printf '5\t105\tpage\n' > "${run_dir}/id-map.tsv"
  : > "${run_dir}/module-content-rewrites.tsv" # present, hooks ran, rewrote nothing
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  _verify_wxr_items_remapped() { echo '[{"post_id":5,"post_type":"page","post_content":"hello","post_excerpt":""}]'; }
  wp_remote() { echo '[{"ID":105,"post_content":"hello","post_excerpt":""}]'; }
  run verify_migrated_content_matches_source "$run_dir" "${run_dir}/id-map.tsv" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTENT_MATCH:1:1:0"* ]] || false
}

# MUTATION PROOF (executed by hand, restored below, not left in the suite):
# reverting the `[ ! -f "$rewrites_file" ]` guard in
# verify_migrated_content_matches_source (lib/verify.sh) back to treating
# an absent file the same as an empty one (round 2's behavior) makes the
# FIRST test above fail: status flips from 2 to 1 (a real HARD FAIL,
# "105" not matching "14468" post-remap), and the "SHOULD NOT BE CALLED"
# stub gets invoked for real. Proven by hand, then reverted.
