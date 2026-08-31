# tests/unit/test_graft_pull_ssh_transfer.bats — issues #75/#94: every
# ssh-remote PULL in lib/graft.sh (from A: graft_copy_wp_content_dir,
# graft_media_sync, graft_export_wxr; from B: graft_fetch_id_map) built its
# own bare `rsync -avz host:path dst` with no SITE_<ALIAS>_SSH_KEY (issue
# #75 — SITE_*_SSH_KEY only ever reached wp_remote, lib/inventory.sh) and no
# arg-escaping for the remote path rsync itself hands to a SECOND, remote
# shell (issue #94 — the same class of gap #44 closed for the generated
# restore.sh, left open here). All four now route through
# rsync_pull_remote/ssh_remote_run (lib/inventory.sh) — this file pins the
# constructed command line for each, the same technique
# tests/unit/test_graft_ssh_file_transfer.bats already established for the
# push side.
#
# graft_import_wxr's own push-side ssh calls (mkdir/rm on B) are covered
# here too (key only — issue #94 is pull-side only, see that issue and ADR
# 0010; this file's own header comment on graft_import_wxr documents the
# pre-existing, unchanged, `-s`-less asymmetry on its rsync push).
bats_require_minimum_version 1.5.0
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

# --- graft_copy_wp_content_dir ---------------------------------------------

@test "graft_copy_wp_content_dir pulls from A over ssh with --no-old-args and no -e when SITE_A_SSH_KEY is unset" {
  SITE_A_SSH_HOST="a.example.com"
  SITE_A_WP_PATH="/site-a"
  unset SITE_A_SSH_KEY
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/site-b"
  ssh() { echo "ssh called with: $*"; }
  rsync() {
    if [[ "$*" == *"a.example.com"* ]]; then echo "PULL rsync: $*"; else echo "PUSH rsync: $*"; fi
  }
  run graft_copy_wp_content_dir "wp-content/plugins/foo" "$BATS_TEST_TMPDIR/staging"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PULL rsync: -avz --no-old-args a.example.com:/site-a/wp-content/plugins/foo/ ${BATS_TEST_TMPDIR}/staging/"* ]] || false
  [[ "$output" != *"-e ssh"* ]] || false
}

@test "graft_copy_wp_content_dir carries SITE_A_SSH_KEY via rsync -e when it is set (issue #75)" {
  SITE_A_SSH_HOST="a.example.com"
  SITE_A_WP_PATH="/site-a"
  SITE_A_SSH_KEY="/home/op/.ssh/a-key"
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/site-b"
  ssh() { echo "ssh called with: $*"; }
  rsync() {
    if [[ "$*" == *"a.example.com"* ]]; then echo "PULL rsync: $*"; else echo "PUSH rsync: $*"; fi
  }
  run graft_copy_wp_content_dir "wp-content/plugins/foo" "$BATS_TEST_TMPDIR/staging"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PULL rsync: -avz --no-old-args -e ssh -i \"/home/op/.ssh/a-key\" a.example.com:/site-a/wp-content/plugins/foo/"* ]] || false
}

# --- graft_media_sync (pull half — the push half is already covered in
# tests/unit/test_graft_ssh_file_transfer.bats) ------------------------

@test "graft_media_sync pulls A's uploads over ssh with --no-old-args and carries SITE_A_SSH_KEY when set (issues #75/#94)" {
  SITE_A_SSH_HOST="a.example.com"
  SITE_A_WP_PATH="/site-a"
  SITE_A_SSH_KEY="/home/op/.ssh/a-key"
  unset SITE_B_SSH_HOST
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  mkdir -p "$SITE_B_WP_PATH"
  ssh() { :; }
  rsync() { echo "PULL rsync: $*"; }
  graft_push_dir() { echo "PUSHED"; return 0; }
  run graft_media_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PULL rsync: -avz --no-old-args -e ssh -i \"/home/op/.ssh/a-key\" a.example.com:/site-a/wp-content/uploads/ ${BATS_TEST_TMPDIR}/run/media-staging/"* ]] || false
}

# --- graft_export_wxr --------------------------------------------------

@test "graft_export_wxr's mkdir/rsync-pull/rm ssh trio all carry SITE_A_SSH_KEY when it is set (issue #75)" {
  SITE_A_SSH_HOST="a.example.com"
  SITE_A_SSH_KEY="/home/op/.ssh/a-key"
  local calls="$BATS_TEST_TMPDIR/calls"
  : > "$calls"
  ssh() { echo "ssh called with: $*" >> "$calls"; }
  rsync() { echo "rsync called with: $*" >> "$calls"; }
  wp_remote() { echo "wp_remote called with: $*" >> "$calls"; return 0; }
  run graft_export_wxr "post,page" "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  run cat "$calls"
  [[ "$output" == *"ssh called with: -i /home/op/.ssh/a-key -- a.example.com mkdir -p"* ]] || false
  # issue #94: --no-old-args, since remote_dir is a `host:path` SOURCE.
  [[ "$output" == *"rsync called with: -avz --no-old-args -e ssh -i \"/home/op/.ssh/a-key\" a.example.com:"* ]] || false
  [[ "$output" == *"ssh called with: -i /home/op/.ssh/a-key -- a.example.com rm -rf"* ]] || false
}

@test "graft_export_wxr omits -i/-e entirely when SITE_A_SSH_KEY is unset (regression, unchanged by this fix)" {
  SITE_A_SSH_HOST="a.example.com"
  unset SITE_A_SSH_KEY
  ssh() { echo "ssh called with: $*"; }
  rsync() { echo "rsync called with: $*"; }
  wp_remote() { :; }
  run graft_export_wxr "post,page" "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [[ "$output" != *" -i "* ]] || false
  [[ "$output" != *"-e ssh"* ]] || false
  [[ "$output" == *"rsync called with: -avz --no-old-args a.example.com:"* ]] || false
}

# --- graft_import_wxr (push side: key only, issue #75 — issue #94 is
# pull-side only, see that issue and ADR 0010) --------------------------

@test "graft_import_wxr's mkdir/rsync-push/rm ssh trio all carry SITE_B_SSH_KEY when it is set (issue #75)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_SSH_KEY="/home/op/.ssh/b-key"
  mkdir -p "$BATS_TEST_TMPDIR/run/export"
  local calls="$BATS_TEST_TMPDIR/calls"
  : > "$calls"
  ssh() { echo "ssh called with: $*" >> "$calls"; }
  rsync() { echo "rsync called with: $*" >> "$calls"; }
  wp_remote() { echo "wp_remote called with: $*" >> "$calls"; return 0; }
  run graft_import_wxr "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  run cat "$calls"
  [[ "$output" == *"ssh called with: -i /home/op/.ssh/b-key -- b.example.com mkdir -p"* ]] || false
  # No --no-old-args here: this is the PUSH side, out of scope for #94 (and
  # pre-existing, unchanged: this call never carried -s either — see this
  # file's own header comment).
  [[ "$output" == *"rsync called with: -avz -e ssh -i \"/home/op/.ssh/b-key\" ${BATS_TEST_TMPDIR}/run/export/ b.example.com:"* ]] || false
  [[ "$output" == *"ssh called with: -i /home/op/.ssh/b-key -- b.example.com rm -rf"* ]] || false
}

@test "graft_import_wxr refuses BEFORE creating the remote directory when SITE_B_SSH_KEY contains a literal double-quote (review round 3, same ordering fix as graft_push_dir/graft_push_file)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_SSH_KEY='/home/op/.ssh/my "quoted" key'
  mkdir -p "$BATS_TEST_TMPDIR/run/export"
  ssh() { echo "SHOULD NOT BE CALLED -- refuse before ever touching B"; return 1; }
  rsync() { echo "SHOULD NOT BE CALLED"; return 1; }
  wp_remote() { echo "SHOULD NOT BE CALLED"; return 1; }
  run graft_import_wxr "$BATS_TEST_TMPDIR/run"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"literal double-quote"* ]] || false
}

# --- graft_fetch_id_map -------------------------------------------------

@test "graft_fetch_id_map pulls B's id-map.log over ssh with --no-old-args and carries SITE_B_SSH_KEY when set (issues #75/#94)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/site-b"
  SITE_B_SSH_KEY="/home/op/.ssh/b-key"
  mkdir -p "$BATS_TEST_TMPDIR/run"
  rsync() { echo "rsync called with: $*"; }
  run graft_fetch_id_map "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsync called with: -avz --no-old-args -e ssh -i \"/home/op/.ssh/b-key\" b.example.com:/site-b/wp-content/sitegraft-id-map.log ${BATS_TEST_TMPDIR}/run/.id-map-fetch.tmp"* ]] || false
}

@test "graft_fetch_id_map omits -i/-e entirely when SITE_B_SSH_KEY is unset (regression, unchanged by this fix)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/site-b"
  unset SITE_B_SSH_KEY
  mkdir -p "$BATS_TEST_TMPDIR/run"
  rsync() { echo "rsync called with: $*"; }
  run graft_fetch_id_map "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsync called with: -avz --no-old-args b.example.com:/site-b/wp-content/sitegraft-id-map.log"* ]] || false
  [[ "$output" != *" -i "* ]] || false
  [[ "$output" != *"-e ssh"* ]] || false
}
