# tests/unit/test_graft_mediastep.bats — the media step of `sitegraft graft`
# (design doc §6.4 step 1): the pure argv-inspection halves of the media
# file sync (graft_media_pull_cmd/graft_media_push_cmd), and the batched
# attachment-import orchestration (graft_import_attachments, issue #11)
# that replaced roughly 2000 per-attachment container invocations with two
# `wp eval` calls. The actual import/remap logic those two calls run lives
# in lib/php/media-import-functions.php — see
# tests/unit/test_media_import_functions.bats for its own, isolated
# `php`-CLI test coverage. What's tested here is the bash glue: which calls
# happen in which order, how a batch result is turned into id-map.tsv rows,
# and that a bad/partial result is a hard failure, never a silent success.
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
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
  [[ "$(cat "$captured_eval")" == *"get_the_title"* ]] || false
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

@test "graft_import_attachments reports per-item skips and failures without treating them as a hard failure when every attachment was still accounted for" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() {
    if [ "$1" = "a" ]; then
      echo '[{"old":10,"rel_path":"","title":"external"},{"old":11,"rel_path":"2024/01/b.jpg","title":"B"}]'
    else
      echo '{"ok":true,"requested":2,"accounted_for":2,"imported":[],"already_present":[],"no_local_file":[10],"failed":[{"old":11,"error":"file not found on B"}],"map":{}}'
    fi
  }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  run graft_import_attachments "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 skipped (no local file)"* ]] || false
  [[ "$output" == *"1 failed"* ]] || false
}
