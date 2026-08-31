bats_require_minimum_version 1.5.0

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

# --- issue #97: backup_compute_protected_checksums (lib/backup.sh) now
# records a table it could not export as the literal string "unreadable",
# never a valid "sha256:..." value (see that function's own header
# comment). Compared straight through the plain string-diff above,
# "unreadable" would either silently MATCH itself (the exact defect this
# issue exists to close, one level below where #33 already closed it for a
# total recompute failure) or read as a content CHANGE it never actually
# observed. Neither is right: it must come out as its own third outcome —
# not verified — reported via the UNREADABLE_COUNT: line on stdout, which
# phase_verify (below) turns into the report's own INCOMPLETE bucket.
@test "verify_compare_checksums treats an 'unreadable' table as NOT VERIFIED — neither a match nor a hard/soft change (issue #97)" {
  local manifest='{"checksums_protected_pre_graft":{"_unclaimed:wp_actionscheduler_actions":"unreadable"}}'
  local recomputed='{"_unclaimed:wp_actionscheduler_actions":"sha256:abc"}'
  run verify_compare_checksums "$manifest" "$recomputed"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNREADABLE_COUNT:1"* ]] || false
  # must not be reported as a confirmed "changed" table -- it was never read
  [[ "$output" != *"unclaimed table(s) on B changed"* ]] || false
}

@test "verify_compare_checksums's UNREADABLE_COUNT catches the issue's own worst case: unreadable BOTH before and after graft (sha256(\"\") would have matched itself)" {
  local manifest='{"checksums_protected_pre_graft":{"_unclaimed:wp_actionscheduler_actions":"unreadable"}}'
  local recomputed='{"_unclaimed:wp_actionscheduler_actions":"unreadable"}'
  run verify_compare_checksums "$manifest" "$recomputed"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNREADABLE_COUNT:1"* ]] || false
}

@test "verify_compare_checksums's UNREADABLE_COUNT is 0 when every protected table was read on both sides" {
  local manifest='{"checksums_protected_pre_graft":{"plugin-x":"sha256:abc"}}'
  local recomputed='{"plugin-x":"sha256:abc"}'
  run verify_compare_checksums "$manifest" "$recomputed"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNREADABLE_COUNT:0"* ]] || false
}

# --- issue #97 review fix-pack (PR #105, mineur 4): an unread table and a
# genuinely CHANGED unclaimed table are two different tables, both possible
# in the same run. verify_compare_checksums must say so distinctly (the
# soft-changed warning is separate from the unread one) — and phase_verify's
# report line must not claim "the rest matched" when part of "the rest"
# actually didn't.
@test "verify_compare_checksums reports a changed unclaimed table AND an unread one as two separate findings in the same run" {
  local manifest='{"checksums_protected_pre_graft":{"_unclaimed:wp_actionscheduler_actions":"unreadable","_unclaimed:wp_usermeta":"sha256:before"}}'
  local recomputed='{"_unclaimed:wp_actionscheduler_actions":"unreadable","_unclaimed:wp_usermeta":"sha256:AFTER"}'
  run verify_compare_checksums "$manifest" "$recomputed"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNREADABLE_COUNT:1:1"* ]] || false
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
  # `</dev/null` on the `run` invocation itself (not on the stub) -- this
  # test's whole point is a stub that drains WHATEVER stdin it inherits, so
  # redirecting inside the stub would defeat it. `run` runs the command in
  # a command substitution (bats-core's test_functions.bash), which has no
  # stdin of its own; without this it inherits bats' own stdin, i.e.
  # whatever the process that started bats happened to have open. In CI
  # that is already /dev/null, so this is a no-op there -- but from an
  # interactive shell, or any parent whose stdin is a pipe that never
  # reaches EOF, that inherited stdin is exactly what the drain-and-hang
  # stub reads, and `cat` blocks forever (issue #46: a real 47-minute hang
  # on a real machine, the whole suite along with it). Pinning it to
  # /dev/null here makes the test's own stdin behavior deterministic --
  # `cat` always sees an already-at-EOF fd 0 and returns immediately --
  # without touching what the stub drains or how many keys land on fd 3,
  # so the mismatch this test exists to catch (see the header comment
  # above) is exactly as catchable as before.
  run verify_options_match "$run_dir" "$manifest" </dev/null
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
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}},"options":{"search_replace":{"to":"https://b.example.com"}}}'
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
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}},"options":{"search_replace":{"to":"https://b.example.com"}}}'
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
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}},"options":{"search_replace":{"to":"https://b.example.com"}}}'
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
  local manifest='{"migrate":{"core-wp":{"option_keys":["etch_settings"]}},"options":{"search_replace":{"to":"https://b.example.com"}}}'
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
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}},"options":{"search_replace":{"to":"https://b.example.com"}}}'
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

# --- issue #73: "unknown" and domain==to are NOT the same as an empty
# domain — both are non-empty, so both used to pass straight through the
# `[ -n "$domain" ]` guard above and into a real wp eval search for a
# string that (by construction) is never going to be found in B's content,
# reporting the domain-absence check GREEN on a manifest whose remap could
# never have worked in the first place. This is the exact defect the issue
# names: "the guard that exists precisely to catch a failed domain remap
# is blinded by the same root cause".

@test "verify_domain_absent refuses (fails, never a false green) when domain is the literal placeholder 'unknown' (#73)" {
  # A non-empty scope (a real migrated post + a real option key) on
  # purpose: an EMPTY scope already returns 2 on its own (the #22/B1 guard
  # tested above), before ever reaching this one — that would make this
  # test pass for the wrong reason regardless of whether the #73 guard
  # exists at all. Proving THIS guard means proving it fires even when
  # there is real work the check would otherwise have gone on to do.
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  local manifest='{"migrate":{"core-wp":{"option_keys":["etch_settings"]}},"options":{"search_replace":{"from":"unknown","to":"unknown"}}}'
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "unknown"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"unknown"* ]] || false
}

@test "verify_domain_absent refuses (fails) when domain equals the manifest's own search_replace.to (#73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  local manifest='{"migrate":{"core-wp":{"option_keys":["etch_settings"]}},"options":{"search_replace":{"from":"https://same.example.com","to":"https://same.example.com"}}}'
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://same.example.com"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# --- BLOCKER-1 (second review round): `domain` (from) is real, and the
# manifest's own `to` is independently broken — A's scan succeeded, B's
# failed. Before this fix, only `domain == "unknown"` and `domain ==
# domain_to` were checked, so this exact case (a real `domain`, a broken
# `domain_to` that is NOT equal to `domain`) sailed through: verify would
# search B's content for A's real domain, correctly find it ABSENT
# (because graft just corrupted it into the broken `to` value instead),
# and report the domain-absence check GREEN on a run that actively
# destroyed A's URLs.
@test "verify_domain_absent refuses when domain (from) is real but the manifest's own to is broken (BLOCKER-1, #73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  local manifest='{"migrate":{"core-wp":{"option_keys":["etch_settings"]}},"options":{"search_replace":{"from":"https://a.example.com","to":"unknown"}}}'
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"to is"*"unknown"* ]] || false
}

@test "verify_domain_absent refuses when domain (from) is real but the manifest's own to is empty (BLOCKER-1, #73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  local manifest='{"migrate":{"core-wp":{"option_keys":["etch_settings"]}},"options":{"search_replace":{"from":"https://a.example.com","to":""}}}'
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "https://a.example.com"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"to is empty"* ]] || false
}

# Nat feedback (live DDEV run): same escape-hatch requirement as
# manifest_validate's/graft_search_replace_domain's own refusal messages --
# a proxied/tunneled site's scan records its own internal address, and
# re-scanning alone will not fix that.
@test "verify_domain_absent's refusal names the hand-edit escape hatch, not just 're-scan' (Nat feedback, #73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  local manifest='{"migrate":{"core-wp":{"option_keys":["etch_settings"]}},"options":{"search_replace":{"from":"unknown","to":"https://b.example.com"}}}'
  run verify_domain_absent "$run_dir" "$tsv" "$manifest" "unknown"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SITE_A_URL"* ]] || false
  [[ "$output" == *"hand-edit"* ]] || false
  [[ "$output" == *"ddev.site"* ]] || false
}

@test "verify_domain_absent is a no-op post_ids list (never calls graft_migrated_post_ids_json) when id-map.tsv is empty/missing" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv" # never created — no posts imported this run
  # An option key IS selected on purpose: this test is about the post_ids
  # half of the scope being empty, not about the whole scope being empty
  # (that case is its own test below, and is NOT a pass).
  local manifest='{"migrate":{"core-wp":{"option_keys":["etch_settings"]}},"options":{"search_replace":{"to":"https://b.example.com"}}}'
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
  local manifest='{"migrate":{"core-wp":{"option_keys":[]}},"options":{"search_replace":{"to":"https://b.example.com"}}}'
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
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}},"options":{"search_replace":{"to":"https://b.example.com"}}}'
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

# --- Issue #69 / #98: the id-map.tsv lookup used to have no `$3` type
# filter and no digit guard on column 2 — the identical unguarded shape
# closed on the WRITE side in modules/core-wp.sh (PR #61's fix-pack). #69
# added the digit guard here (kept below, now defense-in-depth); #98 added
# the actual fix, a `$3=="page"` type filter, so a `term:` row can no
# longer enter this lookup at all — never mind produce a false HARD FAIL.

@test "verify_page_on_front still refuses a non-numeric id-map.tsv entry when the row itself is type page (digit guard, defense in depth after #98's type filter)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value" # A's front page: page 5
  local tsv="${run_dir}/id-map.tsv"
  # Type is "page" so #98's filter lets this row through the lookup at all
  # -- this test is specifically about the digit guard that runs AFTER it.
  printf '5\tArray\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED — a non-numeric map entry must never reach a live comparison against B"; }
  run verify_page_on_front "$run_dir" "$tsv" '{"migrate":{"core-wp":{"option_keys":["page_on_front"]}}}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"non-numeric"* ]] || false
  [[ "$output" == *"PAGE_ON_FRONT:non-numeric-map-entry"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# Issue #98's own acceptance criterion, real row shape: the correct `page`
# row AND a colliding `term:` row sharing the same column-1 id, together in
# the same fixture. Mutation-tested: revert the `$3=="page"` filter on the
# lookup (back to `$1==old{print $2}`) and this goes RED -- awk then emits
# BOTH rows, expected_new_id becomes the two-line string "105\nArray", the
# digit guard's `*[!0-9]*` case matches (a newline is a non-digit), and the
# check returns INCOMPLETE ("non-numeric") instead of comparing 105 against
# B's live value -- exactly the noisy-not-silent state #69 left this in,
# for a result that CONTAINED the correct answer. With the filter, only the
# "page" line is ever produced and the comparison proceeds normally.
@test "verify_page_on_front's lookup ignores a colliding term: row of a different type sharing the same column-1 id (#98)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n5\tArray\tterm:category\n' > "$tsv"
  wp_remote() {
    shift # alias
    if [ "$1" = "option" ]; then echo "105";
    elif [ "$1" = "post" ]; then return 0; fi
  }
  run verify_page_on_front "$run_dir" "$tsv" '{"migrate":{"core-wp":{"option_keys":["page_on_front"]}}}'
  [ "$status" -eq 0 ]
}

# The other half of the same acceptance criterion: a term:-only match (no
# real page row at all sharing that column-1 id) must be treated as "not
# migrated" (a HARD FAIL, same as any other missing entry), never compared
# against B's live value -- #98's filter makes the term: row invisible to
# this lookup, so it is indistinguishable from an id-map.tsv with no row
# for old_front_id at all.
@test "verify_page_on_front treats a term:-only match on column 1 as 'no corresponding entry', not a value to compare (#98)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\tArray\tterm:category\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED — a term:-only match must never reach a live comparison against B"; }
  run verify_page_on_front "$run_dir" "$tsv" '{"migrate":{"core-wp":{"option_keys":["page_on_front"]}}}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no corresponding entry"* ]] || false
  [[ "$output" != *"non-numeric"* ]] || false
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

# --- verify_id_references_resolve (issue #84) --------------------------------
#
# Every known id-bearing block attribute (mediaId, ref, parentPageID) on
# every post THIS run imported must resolve to an existing post on B. Two
# wp_remote calls, each stubbed on its own distinguishing shape: call 1
# fetches migrated posts' live content ("--fields=ID,post_content" is
# present), call 2 confirms which of the ids found in that content
# actually exist on B via a `wp eval` (the "eval" subcommand, not a
# second "post list" -- fix-pack finding, see this repo's own header
# comment on the production function for why "post list --post_type=any"
# is not "every post type": it resolves to WordPress's own
# exclude_from_search filter and silently drops wp_block/wp_template/
# wp_navigation/wp_global_styles, measured directly against a real site).

@test "verify_id_references_resolve is a no-op (no wp_remote call at all) when id-map.tsv does not exist" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_id_references_resolve "$run_dir" "${run_dir}/id-map.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID_REFS:0:0"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_id_references_resolve is a no-op when id-map.tsv has only attachment rows (nothing migrated for a reference to live inside)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '900\t901\tattachment\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_id_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID_REFS:0:0"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_id_references_resolve scopes its content fetch with id-map.tsv's own post types, never --post_type=any (fix-pack, flag-aware stub, execution-proven)" {
  # The real, measured bug: --post_type=any resolves to WordPress's own
  # exclude_from_search filter, which drops wp_block on a real Etch site
  # (verified live: `wp post list --post__in=<a real published wp_block>
  # --post_type=any --post_status=any` returned nothing). This stub
  # returns the post ONLY when asked for the type id-map.tsv actually
  # names ("wp_block"), so a regression back to --post_type=any (which
  # this stub treats as "not wp_block") fails this test rather than
  # passing it by accident.
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '14468\t37496\twp_block\n' > "$tsv"
  wp_remote() {
    shift # alias
    local requested_type="" a
    for a in "$@"; do
      case "$a" in
        --post_type=*) requested_type="${a#--post_type=}" ;;
      esac
    done
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          if [ "$requested_type" = "wp_block" ]; then
            echo '[{"ID":37496,"post_content":"no references here"}]'
          else
            echo "UNEXPECTED post_type: ${requested_type}" >&2; return 1
          fi
          return 0
          ;;
      esac
    done
    echo "UNEXPECTED CALL: $*" >&2; return 1
  }
  run verify_id_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID_REFS:0:0"* ]] || false
}

@test "verify_id_references_resolve passes when every mediaId/ref/parentPageID found on B resolves to a real post" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_remote() {
    shift # alias
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          echo '[{"ID":105,"post_content":"<!-- wp:etch/dynamic-image {\"attributes\":{\"mediaId\":\"763\"}} --><!-- wp:etch/component {\"ref\":40000} --><!-- wp:core/page-list {\"parentPageID\":50} -->"}]'
          return 0
          ;;
        eval)
          # The real function's get_post()-per-id existence check --
          # modelled here as "everything asked about exists", the same
          # level of fidelity the sibling content-match tests use for
          # their own live-fetch stubs.
          printf '763\n40000\n50\n'
          return 0
          ;;
      esac
    done
    echo "UNEXPECTED CALL: $*" >&2; return 1
  }
  run verify_id_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID_REFS:3:0"* ]] || false
}

@test "verify_id_references_resolve detects a spaced mediaId/ref/parentPageID reference, not just the compact byte sequence (issue #88)" {
  # MUTATION-TESTED: reverting the three `grep -oE` patterns in
  # verify_id_references_resolve back to a literal `":` (no
  # `[[:space:]]*`) turns this red -- none of the three would even see
  # these references, let alone check they resolve, and the function would
  # wrongly report ID_REFS:0:0.
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_remote() {
    shift # alias
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          echo '[{"ID":105,"post_content":"<!-- wp:etch/dynamic-image {\"attributes\":{\"mediaId\" : \"763\"}} --><!-- wp:etch/component {\"ref\"  :  40000} --><!-- wp:core/page-list {\"parentPageID\":  50} -->"}]'
          return 0
          ;;
        eval)
          printf '763\n40000\n50\n'
          return 0
          ;;
      esac
    done
    echo "UNEXPECTED CALL: $*" >&2; return 1
  }
  run verify_id_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID_REFS:3:0"* ]] || false
}

@test "verify_id_references_resolve fails when a mediaId does not resolve to any post on B (issue #84's own defect, reproduced)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_remote() {
    shift
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          echo '[{"ID":105,"post_content":"<!-- wp:etch/dynamic-image {\"attributes\":{\"mediaId\":\"35199\"}} -->"}]'
          return 0
          ;;
        eval)
          printf '' # B has nothing carrying this id -- the never-remapped case
          return 0
          ;;
      esac
    done
    echo "UNEXPECTED CALL: $*" >&2; return 1
  }
  run verify_id_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ID_REFS:1:1"* ]] || false
}

@test "verify_id_references_resolve passes with 0 references when migrated content carries none of the three known attributes" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_remote() {
    shift
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          # A heading's "level":1 and similar plain numeric JSON fields must
          # never be mistaken for an id reference -- only the three known
          # attribute NAMES are matched, never a bare number.
          echo '[{"ID":105,"post_content":"<!-- wp:heading {\"level\":1} --><h1>Hi</h1><!-- /wp:heading -->"}]'
          return 0
          ;;
      esac
    done
    echo "UNEXPECTED CALL (an eval call means something was wrongly extracted): $*" >&2; return 1
  }
  run verify_id_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID_REFS:0:0"* ]] || false
}

@test "verify_id_references_resolve treats a failed live-content fetch as UNKNOWN, never as a silent pass" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { return 1; } # B unreachable / query error
  run verify_id_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 1 ]
}

@test "verify_id_references_resolve treats a failed existence check as UNKNOWN, never as a silent pass" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_remote() {
    shift
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          echo '[{"ID":105,"post_content":"<!-- wp:etch/dynamic-image {\"attributes\":{\"mediaId\":\"763\"}} -->"}]'
          return 0
          ;;
        eval) return 1 ;; # second call itself fails
      esac
    done
    return 1
  }
  run verify_id_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 1 ]
}

@test "verify_id_references_resolve excludes attachment and term: rows from scope, same as the content-equality guard" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n900\t901\tattachment\n3\t14\tterm:category\n' > "$tsv"
  wp_remote() {
    shift
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          # If 901 or 14 leaked into scope, they would appear in the
          # --post__in list the real function builds -- asserted on
          # indirectly here by simply not stubbing that behavior differently;
          # the direct, load-bearing assertion is that this stub is only
          # ever asked about 105.
          echo '[{"ID":105,"post_content":"no references here"}]'
          return 0
          ;;
      esac
    done
    echo "UNEXPECTED CALL: $*" >&2; return 1
  }
  run verify_id_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID_REFS:0:0"* ]] || false
}

# --- verify_component_prop_references_resolve (issue #86) --------------------
#
# An Etch component prop with an operator-chosen name (e.g. "bild") carries
# an id at a CALL site's own attribute
# (`wp:etch/component {"ref":R,"attributes":{"bild":"35253"}}`) whose
# meaning only the REFERENCED component's own body knows
# ("mediaId":"{props.bild}"). verify_id_references_resolve's fixed-key scan
# above can never find "bild" -- this is the guard that closes it, ONE
# `wp_remote` call (a single `wp eval`, not two), stubbed on that single
# distinguishing shape.

@test "verify_component_prop_references_resolve is a no-op (no wp_remote call at all) when id-map.tsv does not exist" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_component_prop_references_resolve "$run_dir" "${run_dir}/id-map.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPONENT_PROP_REFS:0:0"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_component_prop_references_resolve is a no-op when the run migrated no wp_block at all (no component could ever declare an id-bearing prop)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n900\t901\tattachment\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_component_prop_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPONENT_PROP_REFS:0:0"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_component_prop_references_resolve is a no-op when the run migrated wp_block components but nothing else could call them" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  # A wp_block row is present, but attachment/term rows only otherwise --
  # no post left for a call site to live inside.
  printf '37496\t40000\twp_block\n900\t901\tattachment\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run verify_component_prop_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPONENT_PROP_REFS:0:0"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "verify_component_prop_references_resolve passes when a component prop's id, discovered from the component's own body, resolves on B (bild -> mediaId, the shape issue #86 reports)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n' > "$tsv"
  wp_remote() {
    shift
    case "$1" in
      eval) printf 'CHK:888:1\nPAIR:105:888:bild\n' ;;
      *) echo "UNEXPECTED CALL: $*" >&2; return 1 ;;
    esac
  }
  run verify_component_prop_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPONENT_PROP_REFS:1:0"* ]] || false
}

@test "verify_component_prop_references_resolve fails when a component prop's id does not resolve to any post on B (issue #86's own defect, reproduced)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n' > "$tsv"
  wp_remote() {
    shift
    case "$1" in
      eval) printf 'CHK:888:0\nPAIR:105:888:bild\n' ;;
      *) echo "UNEXPECTED CALL: $*" >&2; return 1 ;;
    esac
  }
  run --separate-stderr verify_component_prop_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COMPONENT_PROP_REFS:1:1"* ]] || false
  [[ "$stderr" == *"888"* ]] || false
  [[ "$stderr" == *"105(bild)"* ]] || false
}

@test "verify_component_prop_references_resolve passes with 0 references when the eval reports NONE (no component declares an id-bearing prop, or no call site supplies a literal digit for one)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n' > "$tsv"
  wp_remote() {
    shift
    case "$1" in
      eval) echo "NONE" ;;
      *) echo "UNEXPECTED CALL: $*" >&2; return 1 ;;
    esac
  }
  run verify_component_prop_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPONENT_PROP_REFS:0:0"* ]] || false
}

@test "verify_component_prop_references_resolve treats a failed eval as UNKNOWN, never as a silent pass" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n' > "$tsv"
  wp_remote() { return 1; } # B unreachable / query error
  run verify_component_prop_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 1 ]
}

@test "verify_component_prop_references_resolve excludes attachment and term: rows from the citing scope, same as the fixed-key guard" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n900\t901\tattachment\n3\t14\tterm:category\n' > "$tsv"
  wp_remote() {
    shift
    case "$1" in
      eval)
        # Asserted indirectly, same convention as the fixed-key guard's own
        # equivalent test: the citing_ids passed to `wp eval` are embedded
        # in the PHP source captured on stdin by run_or_echo-free direct
        # invocation here, so a leaked 901/14 would show up in the source
        # text this stub can inspect via $2.
        if printf '%s' "$2" | grep -q '901\|"14"'; then
          echo "attachment or term id leaked into citing scope" >&2
          return 1
        fi
        echo "NONE"
        ;;
      *) echo "UNEXPECTED CALL: $*" >&2; return 1 ;;
    esac
  }
  run verify_component_prop_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPONENT_PROP_REFS:0:0"* ]] || false
}

# _verify_component_prop_run_captured_php <capture_var> -- runs the REAL PHP
# text verify_component_prop_references_resolve hands to `wp eval` (captured
# verbatim, never a hand-copied re-implementation of the discovery/scan
# logic) against a minimal WordPress stub. Mirrors modules/etch.sh's own
# test-harness discipline (tests/unit/test_etch_module.bats'
# _etch_run_captured_php_multi) for the identical reason: this mechanism
# must prove it discriminates for real, not merely that its bash half wires
# up the right ids.
_verify_component_prop_run_captured_php() {
  php -r '
    $capture_file = $argv[1];
    $store = array();
    for ( $i = 2; $i < count( $argv ); $i += 2 ) {
      $store[ (int) $argv[ $i ] ] = $argv[ $i + 1 ];
    }
    function get_post_field( $field, $id ) {
      global $store;
      return ( $field === "post_content" && array_key_exists( (int) $id, $store ) ) ? $store[ (int) $id ] : "";
    }
    function get_post( $id ) {
      global $store;
      return array_key_exists( (int) $id, $store ) ? (object) array( "ID" => (int) $id ) : null;
    }
    eval( file_get_contents( $capture_file ) );
  ' -- "$@"
}

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- discovers bild via mediaId, reports it, and never mentions a non-id-bearing prop on the same call" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  # 888 (the attachment "bild" resolves to) is registered with EMPTY
  # content, same as any real attachment post — get_post_field is never
  # asked about it (888 is never a citing id), only get_post's existence
  # check is, which this stub answers from the same $store by key
  # presence alone, content aside.
  run _verify_component_prop_run_captured_php "$capture" \
    105 '<!-- wp:etch/component {"ref":40000,"attributes":{"titre":"9","bild":"888"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} --><!-- wp:etch/text {"content":"{props.titre}"} /-->' \
    888 ''
  [[ "$output" == *"CHK:888:1"* ]] || false
  [[ "$output" == *"PAIR:105:888:bild"* ]] || false
  [[ "$output" != *":9:"* ]] || false
  [[ "$output" != *"titre"* ]] || false
}

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- a spaced component-body declaration (\"mediaId\" : \"{props.bild}\") is still discovered (issue #88)" {
  # MUTATION-TESTED: reverting this file's own discovery regex (the
  # preg_match_all a few lines above verify_component_prop_references_resolve)
  # back to a literal `":"` (no `\s*`) turns this red -- CHK:888:1 and
  # PAIR:105:888:bild would never appear, because "bild" would never be
  # discovered as id-bearing in the first place.
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  run _verify_component_prop_run_captured_php "$capture" \
    105 '<!-- wp:etch/component {"ref":40000,"attributes":{"bild":"888"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId"  :  "{props.bild}"}} -->' \
    888 ''
  [[ "$output" == *"CHK:888:1"* ]] || false
  [[ "$output" == *"PAIR:105:888:bild"* ]] || false
}

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- reports a component prop's id as missing when it does not resolve on B" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  run _verify_component_prop_run_captured_php "$capture" \
    105 '<!-- wp:etch/component {"ref":40000,"attributes":{"bild":"35253"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  [[ "$output" == *"CHK:35253:0"* ]] || false
  [[ "$output" == *"PAIR:105:35253:bild"* ]] || false
}

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- a pass-through value ({props.X}) at a call site is never mistaken for a literal id" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t200\tpage\n7\t40000\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  run _verify_component_prop_run_captured_php "$capture" \
    200 '<!-- wp:etch/component {"ref":40000,"attributes":{"bild":"{props.outerBild}"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  # "NONE" is the captured PHP's own explicit "nothing to check" marker
  # (the same one verify_component_prop_references_resolve's bash half
  # treats as COMPONENT_PROP_REFS:0:0) -- never a CHK/PAIR line, and
  # never the literal placeholder text either.
  [ "$output" = "NONE" ]
  [[ "$output" != *"outerBild"* ]] || false
}

# --- issue #86 fix-pack (Viktor's review of PR #87): the READ-side
# consequences of the same three blockers modules/etch.sh's own fix-pack
# closes on the write side (see that file's header comment for the full
# mechanism this duplicates), plus NIT 5 (INCOMPLETE on nested
# composition) and NIT 6 (the digit regex's trailing-newline gap).

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- BLOCKER 1/3, a call site whose JSON only LOOKS unbalanced (a literal brace inside a string) still parses and remaps correctly, scoped to attributes only" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n7\t40000\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  run _verify_component_prop_run_captured_php "$capture" \
    105 '<!-- wp:etch/component {"ref":40000,"attributes":{"t":"start { here","bild":"888"}},"metadata":{"bindings":{"bild":"999999"}}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->' \
    888 ''
  [[ "$output" == *"CHK:888:1"* ]] || false
  [[ "$output" == *"PAIR:105:888:bild"* ]] || false
  # the metadata.bindings mirror (999999) was never discovered as a
  # reference at all -- scoped strictly to the attributes span.
  [[ "$output" != *"999999"* ]] || false
}

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- BLOCKER 1, a genuinely malformed call site emits a MALFORMED marker rather than hanging or reading as zero references" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n7\t40000\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  run _verify_component_prop_run_captured_php "$capture" \
    105 '<!-- wp:etch/component {"ref":40000,"attributes":{"bild":"35253" -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  [[ "$output" == *"MALFORMED:105"* ]] || false
  [[ "$output" != *"NONE"* ]] || false
}

@test "verify_component_prop_references_resolve: MALFORMED from the eval hard-fails the guard (bash half), never reads as a silent pass" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n' > "$tsv"
  wp_remote() {
    shift
    case "$1" in
      eval) printf 'MALFORMED:105\n' ;;
      *) echo "UNEXPECTED CALL: $*" >&2; return 1 ;;
    esac
  }
  run --separate-stderr verify_component_prop_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"105"* ]] || false
  [[ "$stderr" == *"trustworthy component-prop reference map"* ]] || false
}

@test "verify_component_prop_references_resolve: NIT 5 -- NESTED from the eval reports INCOMPLETE (rc 2), never a silent pass, when component composition is detected" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n37496\t40000\twp_block\n' > "$tsv"
  wp_remote() {
    shift
    case "$1" in
      eval) printf 'NESTED:40000\n' ;;
      *) echo "UNEXPECTED CALL: $*" >&2; return 1 ;;
    esac
  }
  run --separate-stderr verify_component_prop_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"40000"* ]] || false
  [[ "$stderr" == *"composition"* ]] || false
}

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- NIT 5, a component whose own body calls another component emits NESTED during discovery, before any citing post is scanned" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t200\tpage\n8\t500\twp_block\n7\t40000\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  run _verify_component_prop_run_captured_php "$capture" \
    200 '<!-- wp:etch/component {"ref":500,"attributes":{"outerBild":"77"}} -->' \
    500 '<!-- wp:etch/component {"ref":40000,"attributes":{"bild":"{props.outerBild}"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  [[ "$output" == *"NESTED:500"* ]] || false
  [[ "$output" != *"CHK:"* ]] || false
  [[ "$output" != *"NONE"* ]] || false
}

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- NIT 6, a bare-digit value with a trailing newline is not read as a plain digit id" {
  # PCRE's dollar anchor matches before a final newline, not only at the
  # true end of string -- the old pattern would accept "35253" followed by
  # a trailing newline as a match, and that newline would then ride along
  # inside the recorded id, splitting CHK/PAIR onto two lines when echoed
  # and letting bash's own suffix-based parsing read the id back as
  # verified-present without ever having checked it. The \z anchor (this
  # fix) requires the TRUE end of string, so a value carrying a trailing
  # newline is correctly rejected as "not a plain digit id" -- same as any
  # other non-numeric string, left untouched.
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n7\t40000\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  run _verify_component_prop_run_captured_php "$capture" \
    105 '<!-- wp:etch/component {"ref":40000,"attributes":{"bild":"35253\n"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  [ "$output" = "NONE" ]
}

# --- issue #86 SECOND fix-pack (independent review round 2): the block
# finder's OWN failure modes on the READ side, matching modules/etch.sh's
# identical fix (the two scanner copies are kept byte-identical -- see
# this file's own header comment on why they are duplicated at all).

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- SECOND fix-pack BLOCKER A, a span that IS balanced but does not decode as JSON (an unpaired quote) emits MALFORMED, never NONE" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n7\t40000\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  run _verify_component_prop_run_captured_php "$capture" \
    105 '<!-- wp:etch/component {"ref":40000,"attributes":{"t":"a" b" c","bild":"888"}} -->' \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  [[ "$output" == *"MALFORMED:105"* ]] || false
  [[ "$output" != *"NONE"* ]] || false
}

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- SECOND fix-pack BLOCKER B, a newline between the block prefix and its JSON is accepted, and a JSON-less component occurrence is not treated as malformed" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t105\tpage\n7\t40000\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  local page="<!-- wp:etch/component --><!-- wp:etch/component 
{\"ref\":40000,\"attributes\":{\"bild\":\"888\"}} -->"
  run _verify_component_prop_run_captured_php "$capture" \
    105 "$page" \
    40000 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->' \
    888 ''
  [[ "$output" != *"MALFORMED"* ]] || false
  [[ "$output" == *"CHK:888:1"* ]] || false
  [[ "$output" == *"PAIR:105:888:bild"* ]] || false
}

# --- issue #86 THIRD fix-pack (independent review, round 3): NIT F -- the
# MALFORMED-before-NESTED priority the bash half already implemented was
# unreachable, because the PHP used to return on NESTED before the
# citing-post loop that builds $malformed ever ran. Citing posts are now
# always scanned first; NESTED is only echoed (and only after MALFORMED)
# once that scan is done -- so a site that is BOTH composed AND carrying
# unparseable content now correctly fails CLOSED instead of settling for
# the softer INCOMPLETE.

@test "verify_component_prop_references_resolve: captured PHP execution-proof -- NIT F, a site both composed AND carrying a malformed block reports MALFORMED, never NESTED" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t400\tpage\n8\t500\twp_block\n7\t600\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  # post 400: a truncated (malformed) call site. Component 500's own body
  # calls component 600 (composition, depth > 1) -- the reviewer's own
  # exact reproduction shape.
  run _verify_component_prop_run_captured_php "$capture" \
    400 '<!-- wp:etch/component {"ref":500,"attributes":{"bild":"888" -->' \
    500 '<!-- wp:etch/component {"ref":600,"attributes":{}} -->' \
    600 '<!-- wp:etch/dynamic-image {"attributes":{"mediaId":"{props.bild}"}} -->'
  [[ "$output" == *"MALFORMED:400"* ]] || false
  [[ "$output" != *"NESTED"* ]] || false
}

@test "verify_component_prop_references_resolve: NIT F -- a MALFORMED marker alongside a NESTED one hard-fails (rc 1), never settles for INCOMPLETE (rc 2)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t400\tpage\n8\t500\twp_block\n' > "$tsv"
  wp_remote() {
    shift
    case "$1" in
      # A stub standing in for PHP output that includes BOTH markers --
      # the exact shape the fixed PHP can now actually produce, and the
      # exact shape the bash half's own priority claim needs to be real.
      eval) printf 'MALFORMED:400\nNESTED:500\n' ;;
      *) echo "UNEXPECTED CALL: $*" >&2; return 1 ;;
    esac
  }
  run --separate-stderr verify_component_prop_references_resolve "$run_dir" "$tsv"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"400"* ]] || false
  [[ "$stderr" == *"trustworthy component-prop reference map"* ]] || false
}
@test "verify_component_prop_references_resolve: captured PHP execution-proof -- NIT G, a malformed call site is reported even when NO migrated component declares an id-bearing prop (the components may simply not have landed on B)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="${run_dir}/id-map.tsv"
  printf '9\t400\tpage\n8\t500\twp_block\n' > "$tsv"
  local capture="$BATS_TEST_TMPDIR/php.txt"
  wp_remote() { shift; case "$1" in eval) printf '%s' "$2" > "$capture" ;; esac; }
  verify_component_prop_references_resolve "$run_dir" "$tsv" >/dev/null 2>&1 || true
  [ -s "$capture" ]
  # Component 500 comes back EMPTY -- on a real site that is what a
  # component which never landed on B looks like, so $component_prop_map
  # ends up empty. Post 400 carries a truncated call site. Before the NIT F
  # reordering the empty-map short-circuit sat ABOVE the citing loop and
  # printed a green "0 found to check" over exactly that failure.
  run _verify_component_prop_run_captured_php "$capture" \
    400 '<!-- wp:etch/component {"ref":500,"attributes":{"bild":"888" -->' \
    500 ''
  [[ "$output" == *"MALFORMED:400"* ]] || false
  [[ "$output" != *"NONE"* ]] || false
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

# --- Issue #32 fix-pack, NIT 1: curl is never `require_cmd`'d anywhere in
# this codebase, so "curl not found" is a live path today, not provisioning
# for later — it must report its own distinct outcome (HTTP_SMOKE:no-curl),
# never bare success with no marker at all (which phase_verify now reads as
# UNVERIFIED, the wrong claim for a case that is actually a known fact).
# `command` is shadowed here to fake ONLY curl's absence (`builtin command`
# falls through to the real builtin for everything else bats itself needs).
@test "verify_http_smoke reports HTTP_SMOKE:no-curl distinctly when curl itself is unavailable (issue #32 fix-pack, NIT 1)" {
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "curl" ]; then return 1; fi
    builtin command "$@"
  }
  run verify_http_smoke "https://b.example.com" "Home"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HTTP_SMOKE:no-curl"* ]] || false
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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

# --- Issue #33: a total failure of the checksum recompute must be reported
# as a failure, never substituted with an empty map. The shared fixture's
# manifest already has checksums_protected_pre_graft: {} — the exact
# reproduction shape the issue describes: empty pre-graft compared against
# the {} the old `|| recomputed='{}'` fallback produced matches trivially,
# so the OLD code printed "protected data unchanged" / PASS on a run where
# the recompute never ran at all. Failing `eval` here fails
# inventory_table_prefix, which is what makes backup_compute_protected_
# checksums itself return non-zero (its own `|| return 1`) — a real failure
# of the recompute machinery, not a stubbing accident.
@test "phase_verify HARD FAILs when the checksum recompute itself fails, rather than substituting an empty map (issue #33)" {
  setup_phase_verify_fixture
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) return 1 ;; # inventory_table_prefix fails -- wp-cli unreachable
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "HARD FAIL: could not recompute protected data checksums" "${RUN_DIR}/verify-report.md"
  ! grep -q "protected data unchanged" "${RUN_DIR}/verify-report.md"
}

# --- Issue #33, second half of the acceptance criteria: a protect-set that
# is LEGITIMATELY empty (this run's manifest genuinely declared nothing to
# protect -- the shared fixture's own case) must be reported AS a known
# fact, distinctly from a real verified match, not folded into the same
# "protected data unchanged" tick a genuine comparison earns.
@test "phase_verify's checksum line says NOT APPLICABLE, distinctly, when nothing was declared protected in the manifest" {
  setup_phase_verify_fixture # checksums_protected_pre_graft: {}, protect: {_unclaimed: {tables: []}}
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;; # inventory_table_prefix succeeds this time
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -qF -- "- [x] protected data unchanged (not applicable — this run's manifest declared 0 protected table(s) to snapshot, so there was nothing to compare)" "${RUN_DIR}/verify-report.md"
}

# --- Issue #33 fix-pack round 2 (review finding, BLOCKER): the first round
# of this fix collapsed "the manifest genuinely declared nothing to
# protect" and "no pre-graft snapshot exists at all" onto the same PASS.
# Reproduced exactly as measured: a manifest whose protect module DOES
# declare a table, but whose checksums_protected_pre_graft key is entirely
# ABSENT -- the real shape `backup --dry-run` produces (asserted by
# tests/unit/test_phase_backup.bats' own "writes no completion marker or
# checksums" test), reachable by running a genuine graft/verify against a
# dry-run backup's manifest. This must never print a PASS: protected data
# was never snapshotted, so nothing here was verified either way.
@test "phase_verify's checksum check is INCOMPLETE, never a PASS, when the manifest has no pre-graft snapshot at all (issue #33 fix-pack round 2)" {
  setup_phase_verify_fixture
  jq 'del(.checksums_protected_pre_graft) | .protect = {"fakebooking": {"tables": ["fakebooking_reservations"]}}' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;; # inventory_table_prefix succeeds -- the recompute itself is fine
      db) echo "SOME CONTENT" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  grep -qF -- "no pre-graft protected-data snapshot exists in this manifest" "${RUN_DIR}/verify-report.md"
  ! grep -qF -- "protected data unchanged (not applicable" "${RUN_DIR}/verify-report.md"
  ! grep -qF -- "protected set(s) compared" "${RUN_DIR}/verify-report.md"
}

# --- Issue #97: a per-table export failure one level below #33's own fix
# (see backup_compute_protected_checksums' and verify_compare_checksums'
# own header comments). A DECLARED module's table failing to export makes
# the recompute itself fail (backup_compute_protected_checksums now returns
# non-zero for that case) -- inherited for free by the ALREADY-EXISTING #33
# hard-fail path below, proving the issue's own worst case (the same table
# unreadable before AND after the graft, sha256("") matching itself) can no
# longer happen for a declared table: no empty checksum is ever computed
# for it to match against, on either side.
@test "phase_verify HARD FAILs when a DECLARED protected table's export itself fails, both pre- and post-graft (issue #97's own worst case, closed for declared tables)" {
  setup_phase_verify_fixture
  jq '.protect = {"fakebooking": {"tables": ["fakebooking_reservations"]}}' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;;       # inventory_table_prefix succeeds
      db) return 1 ;;           # THIS table's export fails on the recompute
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "HARD FAIL: could not recompute protected data checksums" "${RUN_DIR}/verify-report.md"
  ! grep -q "protected data unchanged" "${RUN_DIR}/verify-report.md"
}

# --- issue #97 review fix-pack (PR #105): phase_verify wires scan-b.json's
# own `.tables` list through to the recompute's optional third argument, the
# same way phase_backup does (lib/backup.sh) — an actionable module/site-
# mismatch message in the verify report, not just a generic one.
@test "phase_verify names a module/site mismatch in its report when scan-b.json is present and never saw the declared table" {
  setup_phase_verify_fixture
  jq '.protect = {"fakebooking": {"tables": ["fakebooking_reservations"]}}' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  printf '{"tables":["wp_options","wp_posts","wp_users"]}' > "${RUN_DIR}/scan-b.json"
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;;
      db) return 1 ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "module/site mismatch" "${RUN_DIR}/verify-report.md"
  grep -q "fakebooking" "${RUN_DIR}/verify-report.md"
}

# --- Issue #97, the `_unclaimed` (out-of-scope) half: unlike a declared
# table, this one does NOT abort the recompute (see
# backup_compute_protected_checksums' header comment on why) -- it must
# still never be silently folded into "protected data unchanged", and must
# never read as confirmed either way just because it was equally unreadable
# pre- and post-graft. Reported via the report's existing three-valued
# INCOMPLETE bucket, never a plain PASS tick.
@test "phase_verify reports INCOMPLETE, not PASS, when an unclaimed table could not be read on either side of the run (issue #97, worst case for an out-of-scope table)" {
  setup_phase_verify_fixture
  jq '.checksums_protected_pre_graft = {"_unclaimed:wp_actionscheduler_actions": "unreadable"} | .protect = {"_unclaimed": {"tables": ["wp_actionscheduler_actions"]}}' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;;
      db) return 1 ;;   # the recompute cannot read this table either -- pre AND post both unreadable
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  grep -qF -- "UNVERIFIED for 1 of 1 protected set(s)" "${RUN_DIR}/verify-report.md"
  ! grep -q "HARD FAIL" "${RUN_DIR}/verify-report.md"
  ! grep -qF -- "protected data unchanged (1 protected set(s) compared)" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify still ticks a plain PASS for protected data when every table reads cleanly (no unreadable tables, no false INCOMPLETE)" {
  setup_phase_verify_fixture
  local pre_sum; pre_sum=$(backup_checksum "IDENTICAL PROTECTED CONTENT")
  jq --arg s "sha256:${pre_sum}" '.checksums_protected_pre_graft = {"fakebooking": $s} | .protect = {"fakebooking": {"tables": ["fakebooking_reservations"]}}' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  [ "$status" -eq 0 ]
  grep -qF -- "protected data unchanged (1 protected set(s) compared)" "${RUN_DIR}/verify-report.md"
}

# --- issue #97 review fix-pack (PR #105, mineur 4): measured, one unread
# table and one genuinely CHANGED unclaimed table in the SAME run — the
# report must not claim "the rest matched" when part of "the rest" (the
# other unclaimed table) actually reported changed just above it.
@test "phase_verify's report does not claim 'the rest matched' when an unread table coexists with a real unclaimed change" {
  setup_phase_verify_fixture
  local usermeta_before_sum; usermeta_before_sum=$(backup_checksum "OLD USERMETA CONTENT")
  jq --arg s "sha256:${usermeta_before_sum}" '
    .checksums_protected_pre_graft = {
      "_unclaimed:wp_actionscheduler_actions": "unreadable",
      "_unclaimed:wp_usermeta": $s
    }
    | .protect = {"_unclaimed": {"tables": ["wp_actionscheduler_actions", "wp_usermeta"]}}
  ' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;;
      db)
        for a in "$@"; do
          case "$a" in
            --tables=wp_actionscheduler_actions) return 1 ;;
            --tables=wp_usermeta) echo "NEW USERMETA CONTENT"; return 0 ;;
          esac
        done
        ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -qF -- "UNVERIFIED for 1 of 2 protected set(s)" "${RUN_DIR}/verify-report.md"
  ! grep -qF -- "; the rest matched" "${RUN_DIR}/verify-report.md"
}

# --- issue #97 review fix-pack (PR #105, NIT 7): unreachable via the real
# verify_compare_checksums today (it always emits a well-formed
# UNREADABLE_COUNT:<n>:<m> marker on its success path) — exercised directly
# here by stubbing it to return success with a MALFORMED marker, to prove
# the fail-safe default actually is fail-safe. Before this fix-pack, a
# parse miss defaulted unread_count to 0, which would have routed straight
# into the plain "[x] ... compared" PASS tick below — the same direction of
# mistake this whole issue exists to close, just one layer further in.
@test "phase_verify treats a malformed/missing UNREADABLE_COUNT marker as INCOMPLETE, never as a silent PASS (fail-safe direction, not 0)" {
  setup_phase_verify_fixture
  local pre_sum; pre_sum=$(backup_checksum "IDENTICAL PROTECTED CONTENT")
  jq --arg s "sha256:${pre_sum}" '.checksums_protected_pre_graft = {"fakebooking": $s} | .protect = {"fakebooking": {"tables": ["fakebooking_reservations"]}}' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # verify_compare_checksums itself returns success but WITHOUT its own
  # contractual marker -- exactly the anomaly this fix-pack defends against.
  verify_compare_checksums() { return 0; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  ! grep -qF -- "protected data unchanged (1 protected set(s) compared)" "${RUN_DIR}/verify-report.md"
}

# --- phase_verify: domain check wiring (scoped, fail-closed) ----------------

@test "phase_verify hard-fails when the domain check finds a real hit" {
  setup_phase_verify_fixture
  jq '.options.search_replace.from = "https://a.example.com"' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() {
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  jq '.options.search_replace.from = "https://a.example.com" | .options.search_replace.to = "https://b.example.com"' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/manifest.json.tmp" && mv "${RUN_DIR}/manifest.json.tmp" "${RUN_DIR}/manifest.json"
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() {
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  jq '.options.search_replace.from = "https://a.example.com" | .options.search_replace.to = "https://b.example.com"' "${RUN_DIR}/manifest.json" > "${RUN_DIR}/m.tmp" && mv "${RUN_DIR}/m.tmp" "${RUN_DIR}/manifest.json"
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  wp_remote() {
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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

# --- Issue #69, phase_verify wiring level: a non-numeric id-map.tsv entry
# must land in the INCOMPLETE bucket under its OWN wording, distinct from
# "the value file was never written this run" -- that line is false here,
# the value WAS written; it is the id-map.tsv row that cannot be trusted.
# The stub below makes the live `wp_remote b option get page_on_front` call
# an immediate test failure if reached at all -- proving the guard stops the
# comparison before it ever gets there, not merely that the wording changed.
#
# Row type is "page" (not the original `term:category`) because issue #98
# added a `$3=="page"` filter to this lookup: a `term:` row no longer
# enters it at all, so it can no longer produce this INCOMPLETE branch --
# see tests/unit/test_verify.bats' own "#98" tests on verify_page_on_front
# for that. This test now exercises the digit guard as pure defense in
# depth, against a malformed row of the RIGHT type.
@test "phase_verify's page_on_front line says NON-NUMERIC MAP ENTRY, distinctly, when id-map.tsv's entry for A's front page is not a numeric id (issue #69)" {
  setup_phase_verify_fixture
  printf '5\tArray\tpage\n' > "${RUN_DIR}/id-map.tsv" # malformed page row, replaces the shared fixture's clean 5->105 mapping
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      db) echo "" ;;
      option) echo "SHOULD NOT BE CALLED" ;; # a non-numeric map entry must never reach a live comparison
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 2 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  grep -qF -- "id-map.tsv's entry for A's front page is not a numeric id" "${RUN_DIR}/verify-report.md"
  ! grep -qF -- "SHOULD NOT BE CALLED" "${RUN_DIR}/verify-report.md"
}

# The three branches above are selected by a marker the function itself
# prints. A fourth success path added later without a marker must not
# silently inherit one of the three claims — the default is UNVERIFIED, in
# keeping with this file's fail-closed rule.
@test "phase_verify reports page_on_front as UNVERIFIED when the check succeeds without saying which of its outcomes applied" {
  setup_phase_verify_fixture
  verify_page_on_front() { return 0; } # a future success path that forgot its marker
  wp_remote() {
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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

# --- Issue #32: the report line used to claim BOTH "returns 200" AND "with
# expected content" whenever B's front-page title came back empty -- the
# body comparison was skipped entirely, but the wording did not change.
# Reproduced directly here: SITE_B_URL is configured, but the `post`
# stub (matching phase_verify's own front-title lookup) returns nothing, the
# same shape as an empty/unreadable front-page title on a real site.
@test "phase_verify's HTTP smoke line says BODY NOT COMPARED, distinctly, when no front-page title is available to match against (issue #32)" {
  setup_phase_verify_fixture
  printf 'SITE_B_URL="https://b.example.com"\n' >> "${SITEGRAFT_PROFILES_DIR}/t.conf"
  curl() {
    for a in "$@"; do
      case "$a" in
        -o) echo "200"; return 0 ;;
      esac
    done
    printf '<html><body>irrelevant, must never be compared</body></html>'
  }
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;;
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;; # --field=post_title: empty title -- the exact shape this issue is about
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -qF -- "- [x] HTTP smoke check: https://b.example.com returns 200 (body not compared — no front-page title available to match against) (best-effort)" "${RUN_DIR}/verify-report.md"
  ! grep -qF -- "with expected content" "${RUN_DIR}/verify-report.md"
}

# --- Same wiring, opposite outcome: a genuine front-page title IS available
# and the body genuinely contains it -- the original, stronger wording must
# still appear for a check that was actually able to compare. Paired with
# the test above so together they prove the report line discriminates
# rather than always printing one or the other.
@test "phase_verify's HTTP smoke line says WITH EXPECTED CONTENT when B's front-page title is genuinely found in the response body (issue #32)" {
  setup_phase_verify_fixture
  printf 'SITE_B_URL="https://b.example.com"\n' >> "${SITEGRAFT_PROFILES_DIR}/t.conf"
  curl() {
    for a in "$@"; do
      case "$a" in
        -o) echo "200"; return 0 ;;
      esac
    done
    printf '<html><body>Welcome Home</body></html>'
  }
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;;
      db) echo "" ;;
      option) echo "105" ;;
      post)
        for a in "$@"; do [ "$a" = "--field=post_title" ] && { echo "Home"; return 0; }; done
        return 0
        ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -qF -- "- [x] HTTP smoke check: https://b.example.com returns 200 with expected content (best-effort)" "${RUN_DIR}/verify-report.md"
}

# --- Issue #32 fix-pack, NIT 1: curl genuinely unavailable is a KNOWN fact
# (curl is never `require_cmd`'d anywhere in this codebase, so this is live
# today), reported as a ticked not-applicable — same category as the
# no-SITE_B_URL case, not an uncertainty.
@test "phase_verify's HTTP smoke line says NOT APPLICABLE, distinctly, when curl itself is unavailable (issue #32 fix-pack, NIT 1)" {
  setup_phase_verify_fixture
  printf 'SITE_B_URL="https://b.example.com"
' >> "${SITEGRAFT_PROFILES_DIR}/t.conf"
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "curl" ]; then return 1; fi
    builtin command "$@"
  }
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "wp_" ;;
      db) echo "" ;;
      option) echo "105" ;;
      post) return 0 ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -qF -- "- [x] HTTP smoke check (not applicable — curl not found on this machine; best-effort check skipped)" "${RUN_DIR}/verify-report.md"
}

# --- Issue #32 fix-pack, NIT 1: a success with NO recognizable marker at
# all (a future success path added without one) is a different defect than
# "curl missing" or "body not compared" — the check's own bookkeeping went
# out of sync. Same fail-closed default every other marker-reading case in
# this file uses: UNVERIFIED, counted toward INCOMPLETE, never silently
# assumed to be the strongest claim. This default is UNREACHABLE as this
# file stands (every real success path echoes its own marker) — kept, and
# tested anyway, for the same reason the sibling defaults in this file are:
# an untested guard is the guard the next refactor deletes with nothing to
# say otherwise.
@test "phase_verify reports the HTTP smoke check as UNVERIFIED when it succeeds without saying which of its outcomes applied (issue #32 fix-pack, NIT 1)" {
  setup_phase_verify_fixture
  printf 'SITE_B_URL="https://b.example.com"
' >> "${SITEGRAFT_PROFILES_DIR}/t.conf"
  verify_http_smoke() { return 0; } # a future success path that forgot its marker
  wp_remote() {
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  grep "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md" | grep -qi "http-smoke"
  grep -qF -- "HTTP smoke check: **UNVERIFIED — the check reported success without saying which of its outcomes applied**" "${RUN_DIR}/verify-report.md"
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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

# --- phase_verify + verify_id_references_resolve wiring (issue #84) ---------
# The direct pass/fail logic of verify_id_references_resolve itself is
# already exercised in full, above ("verify_id_references_resolve" section)
# — these two tests are only about the WIRING: does phase_verify's report
# line and overall Result reflect what the check actually found.

@test "phase_verify's id-references line reports a real count and stays a PASS when every reference resolves" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          echo '[{"ID":105,"post_content":"<!-- wp:etch/dynamic-image {\"attributes\":{\"mediaId\":\"763\"}} -->"}]'
          return 0
          ;;
        eval) printf '763\n'; return 0 ;;
      esac
    done
    case "$1" in
      db) echo "" ;; option) echo "105" ;; post) return 0 ;; *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -qF -- "- [x] id references (mediaId/ref/parentPageID) in migrated content resolve on B (1 checked, 0 missing)" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify HARD FAILS when migrated content references a mediaId that does not resolve to any post on B (issue #84's own defect)" {
  setup_phase_verify_fixture
  wp_remote() {
    local alias_lc="$1"; shift
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          echo '[{"ID":105,"post_content":"<!-- wp:etch/dynamic-image {\"attributes\":{\"mediaId\":\"35199\"}} -->"}]'
          return 0
          ;;
        eval) printf ''; return 0 ;; # never remapped -- B has nothing carrying it
      esac
    done
    case "$1" in
      db) echo "" ;; option) echo "105" ;; post) return 0 ;; *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "Result: HARD FAIL" "${RUN_DIR}/verify-report.md"
  grep "HARD FAIL" "${RUN_DIR}/verify-report.md" | grep -qi "id"
  # fix-pack: counts must survive onto the HARD FAIL line itself, not just
  # the pass line -- an operator staring at a red report needs to see
  # HOW MANY references were checked and HOW MANY were missing without
  # scrolling up to the raw log_error line.
  grep "HARD FAIL" "${RUN_DIR}/verify-report.md" | grep -qi "1 checked, 1 missing"
}

# --- phase_verify + verify_component_prop_references_resolve (issue #86,
# end-to-end): the actual real-site defect report #86 is about -- a
# component prop with an operator-chosen name ("bild") carries an id that
# verify_id_references_resolve's own fixed-key scan cannot see, wired all
# the way into phase_verify's report and its exit status. Two DIFFERENT
# `eval` calls happen in this run (verify_id_references_resolve's own
# "ref":40000 existence check -- "ref" is one of ITS three known keys and
# the call site genuinely has a literal one -- and this guard's own
# component-prop eval), distinguished in the stub by inspecting the PHP
# payload for "component_ids", the marker unique to this guard's own
# generated source.

@test "phase_verify's component-prop line reports a real count and stays a PASS when the discovered prop's id resolves (issue #86)" {
  setup_phase_verify_fixture
  printf '5\t105\tpage\n9\t37468\tpage\n37496\t40000\twp_block\n' > "${RUN_DIR}/id-map.tsv"
  wp_remote() {
    local alias_lc="$1"; shift
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          echo '[{"ID":37468,"post_content":"<!-- wp:etch/component {\"ref\":40000,\"attributes\":{\"bild\":\"888\"}} --><!-- /wp:etch/component -->"},{"ID":40000,"post_content":"<!-- wp:etch/dynamic-image {\"attributes\":{\"mediaId\":\"{props.bild}\"}} -->"}]'
          return 0
          ;;
        eval)
          if printf '%s' "$2" | grep -q 'component_ids'; then
            printf 'CHK:888:1\nPAIR:37468:888:bild\n'
          else
            printf '40000\n' # verify_id_references_resolve's own "ref" existence check
          fi
          return 0
          ;;
      esac
    done
    case "$1" in
      db) echo "" ;; option) echo "105" ;; post) return 0 ;; *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 0 ]
  grep -qF -- "- [x] component-prop id references (issue #86) in migrated content resolve on B (1 checked, 0 missing)" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify HARD FAILS when a component prop's id (e.g. \"bild\") does not resolve to any post on B (issue #86's own defect, reproduced end-to-end)" {
  setup_phase_verify_fixture
  printf '5\t105\tpage\n9\t37468\tpage\n37496\t40000\twp_block\n' > "${RUN_DIR}/id-map.tsv"
  wp_remote() {
    local alias_lc="$1"; shift
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          echo '[{"ID":37468,"post_content":"<!-- wp:etch/component {\"ref\":40000,\"attributes\":{\"bild\":\"35253\"}} --><!-- /wp:etch/component -->"},{"ID":40000,"post_content":"<!-- wp:etch/dynamic-image {\"attributes\":{\"mediaId\":\"{props.bild}\"}} -->"}]'
          return 0
          ;;
        eval)
          if printf '%s' "$2" | grep -q 'component_ids'; then
            printf 'CHK:35253:0\nPAIR:37468:35253:bild\n' # never remapped -- A's raw attachment id, still on B
          else
            printf '40000\n'
          fi
          return 0
          ;;
      esac
    done
    case "$1" in
      db) echo "" ;; option) echo "105" ;; post) return 0 ;; *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "Result: HARD FAIL" "${RUN_DIR}/verify-report.md"
  grep "HARD FAIL" "${RUN_DIR}/verify-report.md" | grep -qi "component prop"
  grep "HARD FAIL" "${RUN_DIR}/verify-report.md" | grep -qi "1 checked, 1 missing"
}

@test "phase_verify's Result is INCOMPLETE, not a silent PASS, when a migrated component's own body calls another component (NIT 5, Viktor's review of PR #87)" {
  setup_phase_verify_fixture
  printf '5\t105\tpage\n9\t37468\tpage\n37496\t40000\twp_block\n' > "${RUN_DIR}/id-map.tsv"
  wp_remote() {
    local alias_lc="$1"; shift
    for a in "$@"; do
      case "$a" in
        --fields=ID,post_content)
          echo '[]'
          return 0
          ;;
        eval)
          if printf '%s' "$2" | grep -q 'component_ids'; then
            printf 'NESTED:40000\n'
          else
            printf ''
          fi
          return 0
          ;;
      esac
    done
    case "$1" in
      db) echo "" ;; option) echo "105" ;; post) return 0 ;; *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -ne 0 ]
  grep -q "Result: INCOMPLETE" "${RUN_DIR}/verify-report.md"
  grep -qi "component composition" "${RUN_DIR}/verify-report.md"
  # never claimed as a pass -- the exact regression NIT 5 closes.
  ! grep -qF -- "[x] component-prop id references" "${RUN_DIR}/verify-report.md"
}

# --- phase_verify + verify_taxonomy_terms_present (issue #82, end-to-end) --
# The base fixture's own "--fields=ID,post_content" pre-filter (every
# wp_remote stub in this file inherits the same first line) already
# short-circuits verify_id_references_resolve/verify_component_prop_
# references_resolve to "nothing to check" regardless of id-map.tsv's
# content -- so id-map.tsv is left untouched here (keeping the base
# fixture's own page_on_front mapping intact) and the ONLY "eval" dispatch
# either test's wp_remote stub needs to answer is this guard's own.

@test "phase_verify's taxonomy-terms line reports a real count and stays a PASS when every declared term resolves on B (issue #82)" {
  setup_phase_verify_fixture
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"

  mkdir -p "${RUN_DIR}/export"
  cat > "${RUN_DIR}/export/one.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel>
<wp:wxr_version>1.2</wp:wxr_version>
<wp:term><wp:term_id>1</wp:term_id><wp:term_taxonomy>etch_gallery</wp:term_taxonomy><wp:term_slug>landscapes</wp:term_slug><wp:term_name><![CDATA[Landscapes]]></wp:term_name></wp:term>
</channel>
</rss>
XML

  graft_push_remap_payload() { echo "/fake/remote/tax-payload.json"; }
  graft_remove_file() { :; }
  wp_remote() {
    for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  grep -qF -- "- [x] taxonomy terms (issue #82) declared by the staged WXR export exist on B (1 checked, 0 missing)" "${RUN_DIR}/verify-report.md"
}

@test "phase_verify HARD FAILS when the staged WXR export declares a taxonomy term that does not exist on B (issue #82's own defect)" {
  setup_phase_verify_fixture
  SITEGRAFT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SITEGRAFT_ROOT
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"

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
<wp:term><wp:term_id>1</wp:term_id><wp:term_taxonomy>etch_gallery</wp:term_taxonomy><wp:term_slug>landscapes</wp:term_slug><wp:term_name><![CDATA[Landscapes]]></wp:term_name></wp:term>
</channel>
</rss>
XML

  graft_push_remap_payload() { echo "/fake/remote/tax-payload.json"; }
  graft_remove_file() { :; }
  wp_remote() {
    for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
    local alias_lc="$1"; shift
    case "$1" in
      eval) echo "MISSING:etch_gallery:landscapes" ;;
      option) echo "105" ;;
      post) return 0 ;;
      db) echo "" ;;
      *) echo "" ;;
    esac
  }
  graft_check_orphan_parents() { echo ""; }
  run phase_verify --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q "Result: HARD FAIL" "${RUN_DIR}/verify-report.md"
  grep "HARD FAIL" "${RUN_DIR}/verify-report.md" | grep -qi "taxonomy term"
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
  # issue #84: phase_verify now also calls verify_id_references_resolve,
  # which issues a wp_remote post-list call carrying
  # "--fields=ID,post_content" that no pre-existing stub below anticipates.
  # Short-circuited to an empty result here, uniformly, BEFORE each
  # test's own dispatch logic runs: none of these tests are about
  # mediaId/ref/parentPageID content, so "nothing found, nothing to
  # verify" is the correct, harmless answer for all of them -- and
  # confirmed harmless by tests/unit/test_verify.bats' own dedicated
  # verify_id_references_resolve section, which exercises the real
  # pass/fail logic directly.
  for __idref_a in "$@"; do [ "$__idref_a" = "--fields=ID,post_content" ] && { echo "[]"; return 0; }; done
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
