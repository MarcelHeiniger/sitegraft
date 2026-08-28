# tests/unit/test_graft_mediastep.bats — the media step of `sitegraft graft`
# (design doc §6.4 step 1): the pure argv-inspection halves of the media
# file sync (graft_media_pull_cmd/graft_media_push_cmd), and the batched
# attachment-import orchestration (graft_import_attachments, issue #11)
# that replaced roughly 2000 per-attachment container invocations with two
# `wp eval` calls. The actual import/remap logic those two calls run lives
# in lib/php/media-import-functions.php — see
# tests/unit/test_media_import_functions.bats (the pure half) and
# tests/unit/test_media_import_batch.bats (the WordPress-calling half, run
# under tests/unit/fixtures/wpstub.php) for its own isolated `php`-CLI
# coverage. What's tested here is the bash glue: which calls happen in
# which order, how a batch result is turned into id-map.tsv rows, and that
# a bad or PARTIAL result is a hard failure, never a silent success.
#
# Two tests below go further and execute the actual PHP this file sends to
# A and to B, captured through the wp_remote stub and run against the same
# wpstub. Those eval strings are bash SINGLE-quoted PHP source, so running
# what was really sent is the only honest way to test them — and it is why
# the prose explaining them lives in bash comments above the functions
# rather than as PHP comments inside, where an apostrophe would end the
# string.
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WP_STUB="${REPO_ROOT}/tests/unit/fixtures/wpstub.php"
  PHP_LIB="${REPO_ROOT}/lib/php/media-import-functions.php"
}

# php_eval_captured <captured_eval_file> <preamble_php> — executes the PHP
# that graft_import_attachments really sent to a site, verbatim, against
# tests/unit/fixtures/wpstub.php. This is what makes the two eval strings
# in lib/graft.sh testable at all: they are bash single-quoted PHP source,
# so the only honest way to test them is to capture what was sent and run
# it. <preamble_php> seeds the stub before the captured code runs.
php_eval_captured() {
  local captured="$1" preamble="$2"
  local script="${BATS_TEST_TMPDIR}/eval-under-stub.php"
  {
    printf '<?php\n'
    printf "require '%s';\n" "$WP_STUB"
    printf '%s\n' "$preamble"
    cat "$captured"
  } > "$script"
  php "$script"
}

# --- graft_media_sync guards its own exit status (PR #90 review, BLOCKER)
#
# phase_graft calls this function on the LHS of a `||` so it can print an
# operator message about B's state when the sync fails. Bash disables `set
# -e` for a function invoked there, and that suppression covers the whole
# function body -- so without an explicit guard on each step, a mid-body
# failure kept going. Measured before the fix: the pull from A failing
# (rsync exit 23) fell through to the push, which shipped an EMPTY staging
# tree to B and returned 0. phase_graft then marked the step done and
# imported against a B whose media never arrived: a silent success, and
# issue #36's own failure mode re-entering by another door.
#
# This test runs the REAL graft_media_sync (the phase_wiring test that
# covers the operator message stubs it out entirely, so it cannot pin this).
#
# One test, not two: a companion asserting "the push is never reached" was
# written and then removed as REDUNDANT -- not as a false green, which is
# what an earlier version of this note wrongly claimed. Measured in review:
# with the pull's guard removed, the push IS reached in this very shape, so
# the assertion would have been true-and-discriminating in isolation; but
# `[ "$rc" -ne 0 ]` above it fails first and bats stops there, so it could
# never have added an independent signal.
#
# The shape matters and is fragile. An explicit `set -euo pipefail` inside a
# subshell on the LHS of a `||` does NOT re-enable errexit -- the
# suppression reaches all the way in (measured). Wrapping the call in
# `out=$( … )` instead DOES change the -e context, and made a draft of that
# companion pass with the guard removed. Keep the invocation below
# verbatim.
@test "graft_media_sync returns non-zero when the pull from A fails, even called on the LHS of a || (set -e is off there)" {
  local staging_parent="$BATS_TEST_TMPDIR/run"
  mkdir -p "$staging_parent"
  SITE_A_WP_PATH="/a"; SITE_B_WP_PATH="/b"
  unset SITE_A_SSH_HOST
  graft_pull_dir() { echo "PULL FAILED"; return 23; }
  graft_push_dir() { echo "PUSHED ANYWAY"; return 0; }

  # Exactly phase_graft's call shape: LHS of a ||, which is what disables -e.
  local rc=0
  ( set -euo pipefail; graft_media_sync "$staging_parent" ) || rc=$?

  [ "$rc" -ne 0 ]
}

@test "graft_media_sync returns non-zero when the ssh pull from A fails (remote-A branch, same LHS-of-|| context)" {
  # The branch taken whenever A is remote -- the primary production shape.
  # Its guard is load-bearing and was unpinned when this fix-pack landed:
  # with it removed, the failed ssh pull fell through to the push, which
  # shipped an empty staging tree to B and returned 0. Same blocker, one
  # branch over.
  local staging_parent="$BATS_TEST_TMPDIR/run-ssh"
  mkdir -p "$staging_parent"
  SITE_A_WP_PATH="/a"; SITE_B_WP_PATH="/b"
  SITE_A_SSH_HOST="host-a"
  run_or_echo() { echo "SSH PULL FAILED"; return 23; }
  graft_push_dir() { echo "PUSHED ANYWAY"; return 0; }

  local rc=0
  ( set -euo pipefail; graft_media_sync "$staging_parent" ) || rc=$?

  [ "$rc" -ne 0 ]
}

@test "graft_media_pull_cmd routes A's uploads to a local staging dir via ssh when A is remote" {
  run graft_media_pull_cmd "user@host-a.example.com" "/site-a/wp-content/uploads/" "/run/media-staging/"
  [[ "$output" == *"rsync"* ]] || false
  [[ "$output" == *"user@host-a.example.com"* ]] || false
  [[ "$output" != *"scp"* ]]
}

@test "graft_media_pull_cmd has no ssh hop when A is local" {
  run graft_media_pull_cmd "" "/site-a/wp-content/uploads/" "/run/media-staging/"
  [[ "$output" != *"ssh"* ]] || [[ "$output" != *"@"* ]]
}

@test "graft_media_push_cmd never overwrites existing files on B" {
  run graft_media_push_cmd "user@host-b.example.com" "/run/media-staging/" "/site-b/wp-content/uploads/"
  [[ "$output" == *"--ignore-existing"* ]] || false
  [[ "$output" != *"scp"* ]]
}


# _capture_b_eval — drives graft_import_attachments once with everything
# stubbed, purely to capture the exact PHP it hands to B, and echoes the
# path of the file holding it. Those eval strings are bash single-quoted
# PHP source; capturing and running what was really sent is the only honest
# way to test them.
_capture_b_eval() {
  local run_dir="$BATS_TEST_TMPDIR/capture-run"; mkdir -p "$run_dir"
  local captured_eval="$BATS_TEST_TMPDIR/captured_b_eval.txt"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"a"}]'
    else
      shift; shift
      printf '%s' "$1" > "$captured_eval"
      echo '{"ok":true,"requested":1,"accounted_for":1,"imported":[10],"already_present":[],"no_local_file":[],"failed":[],"map":{"10":100}}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  graft_import_attachments "$run_dir" >/dev/null
  printf '%s' "$captured_eval"
}

# --- graft_import_attachments (issue #11 batching rewrite) -----------------
#
# graft_push_remap_payload/graft_push_media_import_lib/graft_remove_file are
# stubbed in every test below, same convention test_graft_remap.bats already
# uses for the sibling remap payload mechanism this was modeled on — real
# file transfer is the DDEV integration harness's job, not a unit test's.
# wp_remote is stubbed to distinguish the A-side collection call (alias "a")
# from the B-side batch eval (alias "b" + "eval"), which is all
# graft_collect_attachment_metadata_json/graft_import_attachments need to
# drive their own logic regardless of what real wp-cli would return.

@test "graft_import_attachments does nothing on B when A reports zero attachments" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() {
    if [ "$1" = "a" ]; then echo "[]"; else echo "SHOULD NOT BE CALLED"; fi
  }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_media_import_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_import_attachments "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "graft_import_attachments under --dry-run never pushes anything or calls B, and reports the requested count" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  SITEGRAFT_DRY_RUN=1
  # wp_remote's OWN internal dry-run echo (lib/inventory.sh) is what a real
  # A-side call would produce under --dry-run -- not valid JSON, exactly
  # like this stub reproduces.
  wp_remote() {
    if [ "$1" = "a" ]; then echo "[dry-run] wp --path=/site-a eval '...'"; else echo "SHOULD NOT BE CALLED"; fi
  }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_media_import_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_import_attachments "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "graft_import_attachments fails closed (non-zero, logged) when A's attachment list cannot be read for real" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  # No SITEGRAFT_DRY_RUN set -- a real run where A's wp eval produced
  # garbage/empty output (a genuine wp-cli failure) must not be treated as
  # "nothing to import".
  wp_remote() {
    if [ "$1" = "a" ]; then echo ""; else echo "SHOULD NOT BE CALLED"; fi
  }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_media_import_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_import_attachments "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "graft_collect_attachment_metadata_json queries A (never B) via a single wp eval for every attachment's id, file path, and title" {
  local captured_eval="$BATS_TEST_TMPDIR/captured_eval.txt"
  wp_remote() {
    local alias_lc="$1"; shift
    [ "$1" = "eval" ] || { echo "UNEXPECTED: not an eval call"; return 1; }
    [ "$alias_lc" = "a" ] || { echo "UNEXPECTED: queried ${alias_lc}, not A"; return 1; }
    shift
    printf '%s' "$1" > "$captured_eval"
    echo '[]'
  }
  run graft_collect_attachment_metadata_json a
  [ "$status" -eq 0 ]
  [[ "$output" == "[]" ]]
  [[ "$(cat "$captured_eval")" == *"post_type"*"attachment"* ]] || false
  [[ "$(cat "$captured_eval")" == *"_wp_attached_file"* ]] || false
  [[ "$(cat "$captured_eval")" == *"post_title"* ]] || false
}

# N2, and the third stub-fidelity finding on top of it. Two different
# lossy reads have to be excluded here, and the stub models both with loud
# markers so this is a behavioural assertion on the real captured eval, not
# a grep for a function name:
#
#   FILTERED:         get_the_title(), which core runs through the
#                     `the_title` filter (wptexturize, convert_chars, trim,
#                     and a "Protected: " prefix on password-protected
#                     posts). Verified in wp-includes/default-filters.php.
#   DISPLAYFILTERED:  get_post_field( 'post_title', $id ) WITHOUT a third
#                     argument, whose $context defaults to "display" and
#                     therefore runs `apply_filters( "post_title", ... )`.
#                     Stock core hangs nothing there, so on a clean install
#                     this looks identical to raw -- but any plugin on A can
#                     hook it, and a graft must carry A's stored bytes, not
#                     what A's plugins render.
#
# Only get_post_field( ..., "raw" ) short-circuits sanitize_post_field
# before any filter. The stub used to ignore $context entirely, which is
# what made the imprecise two-argument call pass.
@test "graft_collect_attachment_metadata_json reads A's stored post_title raw, past both the the_title and post_title display filters" {
  [ -f "$WP_STUB" ] || skip "tests/unit/fixtures/wpstub.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
  local captured_eval="$BATS_TEST_TMPDIR/captured_eval.txt"
  wp_remote() { printf '%s' "$3" > "$captured_eval"; echo '[]'; }
  graft_collect_attachment_metadata_json a >/dev/null
  run php_eval_captured "$captured_eval" \
    'wpstub_add_attachment(10, "Sunset over the lake -- 2024", "2024/01/a.jpg");'
  [ "$status" -eq 0 ]
  run jq -r '.[0].title' <<<"$output"
  [ "$status" -eq 0 ]
  [ "$output" = "Sunset over the lake -- 2024" ]
}

# F3, A side, same defect class as the batch's resume query. get_posts()
# defaults numberposts to 5 and copies it into posts_per_page whenever
# posts_per_page is empty, so `"posts_per_page" => -1` is the only thing
# making this eval return EVERY attachment on A rather than its five most
# recent. Lose it and the collection silently truncates — the graft would
# then migrate five media items off a site with hundreds and report
# complete success, because every one of the five it asked about did land.
# Six attachments is the smallest case past the default cap.
@test "graft_collect_attachment_metadata_json collects every attachment on A, past get_posts' default five-row cap" {
  [ -f "$WP_STUB" ] || skip "tests/unit/fixtures/wpstub.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
  local captured_eval="$BATS_TEST_TMPDIR/captured_eval.txt"
  wp_remote() { printf '%s' "$3" > "$captured_eval"; echo '[]'; }
  graft_collect_attachment_metadata_json a >/dev/null
  run php_eval_captured "$captured_eval" \
    'for ($i = 1; $i <= 6; $i++) { wpstub_add_attachment(10 + $i, "title " . $i, "2024/01/" . $i . ".jpg"); }'
  [ "$status" -eq 0 ]
  run jq -e 'length == 6' <<<"$output"
  [ "$status" -eq 0 ]
}

# BLOCKER 2, A side. A latin1 byte in a post title is routine on the
# elderly WordPress installs a graft tool exists to migrate, and plain
# json_encode() returns false on one ("Malformed UTF-8 characters"), which
# means this eval prints NOTHING and the step dies on "could not read A's
# attachment list" -- fail-closed, but undiagnosable, and with no way
# forward short of hand-editing A's database.
@test "graft_collect_attachment_metadata_json still emits parseable JSON when a title on A is not valid UTF-8" {
  [ -f "$WP_STUB" ] || skip "tests/unit/fixtures/wpstub.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
  local captured_eval="$BATS_TEST_TMPDIR/captured_eval.txt"
  wp_remote() { printf '%s' "$3" > "$captured_eval"; echo '[]'; }
  graft_collect_attachment_metadata_json a >/dev/null
  # A raw 0xE9 byte -- "cafe" with a latin1 e-acute, not UTF-8. Built with
  # chr() so this test file stays valid UTF-8 itself.
  run php_eval_captured "$captured_eval" \
    'wpstub_add_attachment(10, "caf" . chr(0xE9) . " latin1", "2024/01/a.jpg"); wpstub_add_attachment(11, "plain ascii", "2024/01/b.jpg");'
  [ "$status" -eq 0 ]
  run jq -e 'type == "array" and length == 2 and .[1].title == "plain ascii"' <<<"$output"
  [ "$status" -eq 0 ]
}

# N-a. JSON_INVALID_UTF8_SUBSTITUTE landed in PHP 7.2 and NOTHING in this
# repo declares a PHP floor -- README states no PHP requirement at all. The
# sites this substitution exists for (old, latin1-titled WordPress) are the
# ones most likely to predate 7.2, where naming the bare constant is a
# fatal error: it would turn a step that merely handled non-UTF-8 badly
# into one that cannot run at all, i.e. a regression on the exact
# population the fix targets. Behind defined() it falls back to 0, which is
# byte-for-byte the pre-fix call.
#
# This is a SHAPE assertion, deliberately: the fallback branch cannot be
# executed on a PHP 7.2+ CLI (a constant cannot be undefined), so what is
# pinned is that neither eval names the constant outside a defined() guard.
# Removing either guard turns this red.
@test "neither eval names JSON_INVALID_UTF8_SUBSTITUTE without a defined() guard, so a pre-7.2 PHP on A or B still runs" {
  local captured_a="$BATS_TEST_TMPDIR/captured_a.txt"
  wp_remote() { printf '%s' "$3" > "$captured_a"; echo '[]'; }
  graft_collect_attachment_metadata_json a >/dev/null
  local captured_b; captured_b=$(_capture_b_eval)
  local f code_mentions
  for f in "$captured_a" "$captured_b"; do
    # The guarded expression is present...
    grep -q 'defined( "JSON_INVALID_UTF8_SUBSTITUTE" ) ? JSON_INVALID_UTF8_SUBSTITUTE : 0' "$f"
    # ...and no CODE line mentions the constant outside a defined() test.
    # PHP comment lines inside the eval are excluded, since naming the
    # constant in prose is not what would fatal on PHP 7.1.
    code_mentions=$(grep 'JSON_INVALID_UTF8_SUBSTITUTE' "$f" | grep -v '^[[:space:]]*//' | grep -cv 'defined(' || true)
    [ "$code_mentions" -eq 0 ]
  done
}

@test "graft_import_attachments pushes the full attachment list as the payload and requires the media-import library" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local captured="$BATS_TEST_TMPDIR/captured.json"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"},{"old":11,"rel_path":"2024/01/b.jpg","title":"B"}]'
    else
      echo '{"ok":true,"requested":2,"accounted_for":2,"imported":[10,11],"already_present":[],"no_local_file":[],"failed":[],"map":{"10":100,"11":101}}'
    fi
  }
  graft_push_remap_payload() { printf '%s' "$2" > "$captured"; echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -eq 0 ]
  run jq -e '. == [{"old":10,"rel_path":"2024/01/a.jpg","title":"A"},{"old":11,"rel_path":"2024/01/b.jpg","title":"B"}]' "$captured"
  [ "$status" -eq 0 ]
}

@test "graft_import_attachments's wp eval on B requires the shared media-import library and calls its batch function" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  # Captures the exact eval script sent to B, decoupled from whatever
  # graft_import_attachments does with the (here, fake) reply -- unlike
  # asserting against the function's own $output, this can't accidentally
  # pass via an unrelated error message that happens to echo the input back.
  local captured_eval="$BATS_TEST_TMPDIR/captured_eval.txt"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"}]'
    else
      shift # drop "b"
      shift # drop "eval"
      printf '%s' "$1" > "$captured_eval"
      echo '{"ok":true,"requested":1,"accounted_for":1,"imported":[10],"already_present":[],"no_local_file":[],"failed":[],"map":{"10":100}}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$(cat "$captured_eval")" == *"require_once"* ]] || false
  [[ "$(cat "$captured_eval")" == *"sitegraft-media-import-functions.php"* ]] || false
  [[ "$(cat "$captured_eval")" == *"sitegraft_media_import_batch("* ]] || false
}

@test "graft_import_attachments rewrites id-map.tsv's attachment rows from the batch's map, replacing (not appending to) whatever was there, and leaves non-attachment rows untouched" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local id_map_tsv="${run_dir}/id-map.tsv"
  # Simulates a resumed run: attachment 10 was already imported (new id
  # 100) by an EARLIER, interrupted call of this same step -- its stale row
  # must be replaced, not duplicated, and post 5's row (a different
  # post_type) must survive untouched.
  printf '10\t100\tattachment\n5\t105\tpage\n' > "$id_map_tsv"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"},{"old":11,"rel_path":"2024/01/b.jpg","title":"B"}]'
    else
      # 10 comes back as already_present (same id, ground truth from B) --
      # 11 is newly imported this call.
      echo '{"ok":true,"requested":2,"accounted_for":2,"imported":[11],"already_present":[10],"no_local_file":[],"failed":[],"map":{"10":100,"11":101}}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -eq 0 ]
  # Exactly one row per attachment old id -- no duplicate for 10.
  [ "$(grep -c $'\tattachment$' "$id_map_tsv")" -eq 2 ]
  grep -qx $'10\t100\tattachment' "$id_map_tsv"
  grep -qx $'11\t101\tattachment' "$id_map_tsv"
  grep -qx $'5\t105\tpage' "$id_map_tsv"
  [[ "$output" == *"1 newly imported"* ]] || false
  [[ "$output" == *"1 already present (resumed)"* ]] || false
}

@test "graft_import_attachments fails closed and does not touch id-map.tsv when the batch reports it could not account for every requested attachment" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local id_map_tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$id_map_tsv"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"},{"old":11,"rel_path":"2024/01/b.jpg","title":"B"}]'
    else
      # A batch that silently ate everything past the first item -- exactly
      # the "worst outcome" issue #11 names: 2 requested, only 1 accounted
      # for, ok is false.
      echo '{"ok":false,"requested":2,"accounted_for":1,"imported":[10],"already_present":[],"no_local_file":[],"failed":[],"map":{"10":100}}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -ne 0 ]
  # id-map.tsv is exactly what it was before this call -- never partially
  # rewritten from a result this function refused to trust.
  [ "$(cat "$id_map_tsv")" = "$(printf '5\t105\tpage')" ]
}

@test "graft_import_attachments fails closed when the batch eval produces no parseable JSON at all (a crashed/killed wp eval)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"}]'
    else
      echo ""
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -ne 0 ]
}

@test "graft_import_attachments fails closed with its own clear message when the batch result is valid JSON but not an object (e.g. a bare array)" {
  # Distinct from the empty-output case above: this is valid JSON, so
  # without its own explicit type check this function would instead hand
  # a non-object straight to jq's '.error'/'.ok' field access, which jq
  # itself treats as a hard runtime error ("Cannot index array with
  # string") -- under bin/sitegraft's real `set -e`, that aborts the whole
  # script on a raw jq crash instead of this function's own controlled,
  # readable log_error.
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"}]'
    else
      echo '[]'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no parseable result"* ]] || false
}

@test "graft_import_attachments fails closed when the batch itself reports an error (e.g. no payload found on B)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"}]'
    else
      echo '{"ok":false,"error":"no media-import payload found or unreadable"}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no media-import payload found"* ]] || false
}

# An attachment A holds no _wp_attached_file for (external/offloaded media)
# was never locally storable in the first place -- skipping it is the
# correct outcome, not a failure, and stays a warning plus a zero exit,
# exactly as the pre-batch per-attachment loop behaved.
@test "graft_import_attachments treats a no-local-file skip as a warning and still succeeds" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"","title":"external"},{"old":11,"rel_path":"2024/01/b.jpg","title":"B"}]'
    else
      echo '{"ok":true,"requested":2,"accounted_for":2,"imported":[11],"already_present":[],"no_local_file":[10],"failed":[],"map":{"11":101}}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 skipped (no local file)"* ]] || false
}

# BLOCKER 1. `ok` from the batch only means "every attachment landed in
# SOME bucket", and `failed` is one of those buckets -- so a batch that got
# 400 of 518 in and lost 118 to per-item errors came back ok=true and this
# function returned 0. phase_graft (lib/graft.sh) wires every step as
# `graft_step_done ... || { <step>; graft_mark_step ...; }`, so a zero exit
# writes graft.import_attachments.done, a resumed run skips the step
# FOREVER, the 118 are never retried, and graft_remap_attachment_ids /
# graft_remap_featured_images then hit `[ -s "$id_map_tsv" ] || return 0`
# and say nothing at all. The whole thing was witnessed only by a log_warn
# in a 3000-line log.
#
# Measured before the fix: 400 imported / 118 failed -> exit 0, id-map.tsv
# 400 lines; 0 imported / 518 failed -> exit 0, id-map.tsv 0 bytes.
@test "graft_import_attachments refuses to report success when the batch failed to import some attachments" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"},{"old":11,"rel_path":"2024/01/b.jpg","title":"B"}]'
    else
      echo '{"ok":true,"requested":2,"accounted_for":2,"imported":[10],"already_present":[],"no_local_file":[],"failed":[{"old":11,"error":"file not found on B"}],"map":{"10":100}}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -ne 0 ]
  # Names the attachments, not just a count -- docs/usage.md promises
  # "listing which attachments" and now that is actually true.
  [[ "$output" == *"failed to import 1 of 2 attachment(s)"* ]] || false
  [[ "$output" == *'"old":11'* ]] || false
  [[ "$output" == *"file not found on B"* ]] || false
  [[ "$output" == *"re-run to retry only the ones that failed"* ]] || false
}

# The second half of that fix: the id-map rewrite happens BEFORE the
# refusal, so whatever DID import is recorded and a re-run only retries
# what failed. Losing the good rows would turn a partial failure into a
# full re-import.
@test "graft_import_attachments still records what did import before refusing on the ones that failed" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local id_map_tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$id_map_tsv"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"},{"old":11,"rel_path":"2024/01/b.jpg","title":"B"}]'
    else
      echo '{"ok":true,"requested":2,"accounted_for":2,"imported":[10],"already_present":[],"no_local_file":[],"failed":[{"old":11,"error":"file not found on B"}],"map":{"10":100}}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -ne 0 ]
  grep -qx $'10\t100\tattachment' "$id_map_tsv"
  grep -qx $'5\t105\tpage' "$id_map_tsv"
  # The honest accounting is still printed -- the operator sees what landed
  # on B, not only that the step refused.
  [[ "$output" == *"1 newly imported"* ]] || false
}

# The worst case of all, and the one graft_prune_previous_run makes routine
# on a SECOND graft: prune runs `wp post delete --force` on every
# _sitegraft_source_id-tagged post, which deletes the attached file from
# disk, so the next import finds nothing to register and every single
# attachment fails. Before the fix that was exit 0, an empty id-map.tsv,
# and a graft that carried on to completion with zero media.
@test "graft_import_attachments refuses when every single attachment failed, and never leaves an empty id-map behind as a success" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local id_map_tsv="${run_dir}/id-map.tsv"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"},{"old":11,"rel_path":"2024/01/b.jpg","title":"B"}]'
    else
      echo '{"ok":true,"requested":2,"accounted_for":2,"imported":[],"already_present":[],"no_local_file":[],"failed":[{"old":10,"error":"file not found on B"},{"old":11,"error":"file not found on B"}],"map":{}}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to import 2 of 2 attachment(s)"* ]] || false
}

# N5: a batch result that is an object but carries no `.map` at all sent
# `jq -r '.map | to_entries[]'` into "null (null) has no keys" (jq exit 5)
# inside a `map_tsv=$(...)` assignment -- which under bin/sitegraft's real
# `set -euo pipefail` aborts the whole script on a raw jq error message
# instead of this function's own controlled log_error, the same class of
# thing the `type == "object"` guard above already exists to prevent.
@test "graft_import_attachments fails closed with its own message when the batch result carries no usable id map" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local id_map_tsv="${run_dir}/id-map.tsv"
  printf '5\t105\tpage\n' > "$id_map_tsv"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"2024/01/a.jpg","title":"A"}]'
    else
      echo '{"ok":true,"requested":1,"accounted_for":1,"imported":[10],"already_present":[],"no_local_file":[],"failed":[]}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no usable id map"* ]] || false
  [ "$(cat "$id_map_tsv")" = "$(printf '5\t105\tpage')" ]
}

# BLOCKER 2, B side, run for real: the exact PHP graft_import_attachments
# sends to B, captured and executed against tests/unit/fixtures/wpstub.php
# with the real lib/php/media-import-functions.php required through it.
#
# This is the nastier half of the encoding bug. The batch does ALL the work
# first -- posts inserted, every _sitegraft_source_id written -- and only
# then encodes its report. One non-UTF-8 byte anywhere in it made
# json_encode return false, which echoes as the empty string, so the eval
# printed nothing, so graft_import_attachments refused the result and
# id-map.tsv was never written. Re-running found everything already_present
# and failed to encode again: permanently stuck, with the work done and no
# map. The pre-batch loop never had this failure mode -- it passed titles
# through argv, never through JSON.
#
# The byte is injected where it can still realistically appear now that the
# A-side collection substitutes its own: in an error message WordPress
# builds on B (a WP_Error carrying a filesystem path with latin1 bytes),
# which lands in the report's `failed` bucket.
@test "graft_import_attachments's B-side eval still emits a parseable report when a WordPress error message on B is not valid UTF-8" {
  [ -f "$WP_STUB" ] || skip "tests/unit/fixtures/wpstub.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
  local captured_eval; captured_eval=$(_capture_b_eval)
  local wp_content="$BATS_TEST_TMPDIR/wp-content"
  local uploads="$BATS_TEST_TMPDIR/uploads"
  mkdir -p "$wp_content" "${uploads}/2024/01"
  printf 'not really a jpeg' > "${uploads}/2024/01/a.jpg"
  cp "$PHP_LIB" "${wp_content}/sitegraft-media-import-functions.php"
  printf '[{"old":10,"rel_path":"2024/01/a.jpg","title":"a"}]' \
    > "${wp_content}/sitegraft-media-import-payload.json"
  # A raw 0xE9 byte in the WP_Error message -- built with chr() so this
  # test file stays valid UTF-8 itself.
  run php_eval_captured "$captured_eval" \
    "define('WP_CONTENT_DIR', '${wp_content}'); wpstub_set_uploads('${uploads}'); wpstub_add_attachment(10, 'a', '2024/01/a.jpg'); \$GLOBALS['wpstub']['insert_error'] = 'could not write /var/www/upload/caf' . chr(0xE9) . '/a.jpg';"
  [ "$status" -eq 0 ]
  run jq -e 'type == "object" and .ok == true and (.map | type) == "object" and (.failed | length) == 1' <<<"$output"
  [ "$status" -eq 0 ]
}

# The A-side collection now substitutes invalid bytes before the payload is
# ever written, so B should never see one -- but if it somehow does,
# json_decode fails and the batch is not run at all. The refusal has to say
# WHY, not just "unreadable".
@test "graft_import_attachments's B-side eval names the decode error when the payload it was handed is not valid JSON" {
  [ -f "$WP_STUB" ] || skip "tests/unit/fixtures/wpstub.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
  local captured_eval; captured_eval=$(_capture_b_eval)
  local wp_content="$BATS_TEST_TMPDIR/wp-content"
  mkdir -p "$wp_content"
  cp "$PHP_LIB" "${wp_content}/sitegraft-media-import-functions.php"
  printf '[{"old":10,"rel_path":"2024/01/a.jpg","title":"caf\xe9 latin1"}]' \
    > "${wp_content}/sitegraft-media-import-payload.json"
  run php_eval_captured "$captured_eval" \
    "define('WP_CONTENT_DIR', '${wp_content}');"
  [ "$status" -eq 0 ]
  run jq -r '.error' <<<"$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no media-import payload found or unreadable"* ]] || false
  [[ "$output" == *"UTF-8"* ]] || false
}

# N4: under --dry-run wp_remote echoes instead of querying A, so the real
# attachment count is unknowable and no per-file preview is possible. What
# IS knowable is that this step drops TWO files into B's wp-content and
# removes them again -- real writes on B that a --dry-run reviewer needs to
# see named, rather than a single generic line implying the step touches
# nothing there.
@test "graft_import_attachments under --dry-run names the files it would write into B's wp-content" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  SITEGRAFT_DRY_RUN=1
  SITE_B_WP_PATH="/site-b"
  wp_remote() {
    if [ "$1" = "a" ]; then echo "[dry-run] wp --path=/site-a eval '...'"; else echo "SHOULD NOT BE CALLED"; fi
  }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_media_import_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_import_attachments "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"/site-b/wp-content/sitegraft-media-import-payload.json"* ]] || false
  [[ "$output" == *"/site-b/wp-content/sitegraft-media-import-functions.php"* ]] || false
  [[ "$output" == *"sitegraft_media_import_batch"* ]] || false
}

# On a total failure this list holds one object per attachment — 518 of them
# on the reference pair — and a single log line carrying all of them is not
# something a human reads at 3am, which is exactly when this message gets
# read. The count is always stated in full; only the dump is capped.
@test "graft_import_attachments caps the failed-attachment dump and says it capped it" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() {
    if [ "$1" = "a" ]; then
      jq -n -c '[range(1;26) | {old: ., rel_path: "2024/01/x.jpg", title: "T"}]'
    else
      jq -n -c '{ok: true, requested: 25, accounted_for: 25, imported: [], already_present: [],
                 no_local_file: [], map: {},
                 failed: [range(1;26) | {old: ., error: "file not found on B"}]}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -ne 0 ]
  # The full count is never hidden.
  [[ "$output" == *"failed to import 25 of 25 attachment(s)"* ]] || false
  [[ "$output" == *"(first 20 of 25 shown)"* ]] || false
  # Attachment 20 is inside the window, 21 is past it.
  [[ "$output" == *'{"old":20,'* ]] || false
  [[ "$output" != *'{"old":21,'* ]] || false
}
