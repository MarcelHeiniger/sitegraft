# tests/unit/test_graft_ssh_file_transfer.bats — issue #77: graft_push_file
# wrote to the ORCHESTRATOR instead of B whenever B was ssh-remote, because
# its own body only ever branched on the wrapped-local/bare-local split
# (graft_local_prefix) and never consulted SITE_<ALIAS>_SSH_HOST at all. The
# sibling function graft_push_dir had the identical gap in its OWN body —
# it never broke in production only because every one of its three call
# sites (graft_copy_wp_content_dir, graft_media_sync,
# graft_deploy_mu_plugin) happened to check SITE_*_SSH_HOST itself and
# route around graft_push_dir/graft_push_file entirely for the ssh-remote
# case. graft_push_media_import_lib/graft_push_remap_lib/
# graft_push_remap_payload did NOT re-implement that check — three
# omissions out of six call sites, not one — which is exactly what broke
# the first real migration onto a genuine remote B: media import, id remap
# and domain remap all tried to mkdir/rsync the remote path ON the
# orchestrator's own filesystem.
#
# The fix moves ssh-remote handling INTO graft_push_file/graft_push_dir/
# graft_remove_file themselves (checked first, before the wrapped-local
# prefix), so no future caller can omit it again — and the three
# previously-correct call sites' own inline ssh branches become dead code,
# removed here in favour of the shared implementation.
#
# The DDEV harness cannot cover any of this — both its fixture sites are
# local, so it only ever exercises the non-ssh branches (same structural
# blind spot as issue #75, SITE_*_SSH_KEY). Every test below pins the
# CONSTRUCTED command line for an ssh-remote alias by stubbing `ssh` and
# `rsync` as bash functions that record their argv, then runs the real
# (non-dry-run) code path against those stubs — the same technique
# tests/unit/test_graft_resume_safety.bats already established for
# graft_reset_id_map_log's own ssh branch.
bats_require_minimum_version 1.5.0
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

# --- graft_push_file ---------------------------------------------------

@test "graft_push_file routes through ssh (mkdir -p, then rsync to host:dest) when SITE_B_SSH_HOST is set" {
  SITE_B_SSH_HOST="b.example.com"
  unset SITE_B_WP_CMD
  ssh() { echo "ssh called with: $*"; }
  rsync() { echo "rsync called with: $*"; }
  run graft_push_file b "/local/src/lib.php" "/remote/site-b/wp-content" "sitegraft-lib.php"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -- b.example.com mkdir -p '/remote/site-b/wp-content'"* ]] || false
  [[ "$output" == *"rsync called with: -avz -s /local/src/lib.php b.example.com:/remote/site-b/wp-content/sitegraft-lib.php"* ]] || false
}

@test "graft_push_file prefers ssh-remote over a wrapped-local prefix when both SITE_*_SSH_HOST and a container SITE_*_WP_CMD happen to be set" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_CMD="ddev exec --raw -p sitegraft-test-b -- wp"
  ssh() { echo "ssh called with: $*"; }
  rsync() { echo "rsync called with: $*"; }
  run graft_push_file b "/local/src/lib.php" "/var/www/html/wp-content" "lib.php"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with:"* ]] || false
  [[ "$output" != *"tee"* ]] || false
}

@test "graft_push_file still uses the wrapped-local mkdir+tee-through-the-wrapper path when no SSH_HOST is set but a container wrapper is (regression, unchanged by this fix)" {
  unset SITE_B_SSH_HOST
  SITE_B_WP_CMD="ddev exec --raw -p sitegraft-test-b -- wp"
  SITEGRAFT_DRY_RUN=1
  run graft_push_file b "/local/src/lib.php" "/var/www/html/wp-content" "lib.php"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mkdir -p '/var/www/html/wp-content'"* ]] || false
  [[ "$output" == *"tee '/var/www/html/wp-content/lib.php'"* ]] || false
  [[ "$output" == *"ddev exec -p sitegraft-test-b --"* ]] || false
  [[ "$output" != *"ssh"* ]] || false
}

@test "graft_push_file carries SITE_B_SSH_KEY on both the mkdir ssh call and the rsync -e clause when it is set (issue #75)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_SSH_KEY="/home/op/.ssh/b-key"
  unset SITE_B_WP_CMD
  ssh() { echo "ssh called with: $*"; }
  rsync() { echo "rsync called with: $*"; }
  run graft_push_file b "/local/src/lib.php" "/remote/site-b/wp-content" "sitegraft-lib.php"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -i /home/op/.ssh/b-key -- b.example.com mkdir -p '/remote/site-b/wp-content'"* ]] || false
  [[ "$output" == *"rsync called with: -avz -s -e ssh -i \"/home/op/.ssh/b-key\" /local/src/lib.php b.example.com:/remote/site-b/wp-content/sitegraft-lib.php"* ]] || false
}

@test "graft_push_file refuses BEFORE creating the remote directory when SITE_B_SSH_KEY contains a literal double-quote (review round 3, same ordering fix as graft_push_dir)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_SSH_KEY='/home/op/.ssh/my "quoted" key'
  ssh() { echo "SHOULD NOT BE CALLED -- refuse before ever touching B"; return 1; }
  rsync() { echo "SHOULD NOT BE CALLED"; return 1; }
  run graft_push_file b "/local/src/lib.php" "/remote/site-b/wp-content" "sitegraft-lib.php"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"literal double-quote"* ]] || false
}

@test "graft_push_file falls back to plain mkdir+rsync for a genuinely bare-local site (no SSH_HOST, no wrapper) — regression, unchanged by this fix" {
  unset SITE_B_SSH_HOST SITE_B_WP_CMD
  local dest="$BATS_TEST_TMPDIR/site-b/wp-content"
  local src="$BATS_TEST_TMPDIR/src.php"
  printf 'payload' > "$src"
  run graft_push_file b "$src" "$dest" "lib.php"
  [ "$status" -eq 0 ]
  [ -f "${dest}/lib.php" ]
  [ "$(cat "${dest}/lib.php")" = "payload" ]
}

# --- graft_push_dir (same gap, found while fixing graft_push_file — see PR) --

@test "graft_push_dir routes through ssh (mkdir -p, then rsync -avz) when SITE_B_SSH_HOST is set" {
  SITE_B_SSH_HOST="b.example.com"
  ssh() { echo "ssh called with: $*"; }
  rsync() { echo "rsync called with: $*"; }
  run graft_push_dir b "/local/staging" "/remote/site-b/wp-content/plugins/foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -- b.example.com mkdir -p '/remote/site-b/wp-content/plugins/foo'"* ]] || false
  [[ "$output" == *"rsync called with: -avz -s /local/staging/ b.example.com:/remote/site-b/wp-content/plugins/foo/"* ]] || false
}

@test "graft_push_dir --keep-existing adds --ignore-existing to the ssh-remote rsync, never overwriting a file already on B" {
  SITE_B_SSH_HOST="b.example.com"
  ssh() { :; }
  rsync() { echo "rsync called with: $*"; }
  run graft_push_dir b "/local/staging" "/remote/site-b/wp-content/uploads" --keep-existing
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsync called with: -avz -s --ignore-existing /local/staging/ b.example.com:/remote/site-b/wp-content/uploads/"* ]] || false
}

@test "graft_push_dir carries SITE_B_SSH_KEY on both the mkdir ssh call and the rsync -e clause when it is set (issue #75)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_SSH_KEY="/home/op/.ssh/b-key"
  ssh() { echo "ssh called with: $*"; }
  rsync() { echo "rsync called with: $*"; }
  run graft_push_dir b "/local/staging" "/remote/site-b/wp-content/plugins/foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -i /home/op/.ssh/b-key -- b.example.com mkdir -p '/remote/site-b/wp-content/plugins/foo'"* ]] || false
  [[ "$output" == *"rsync called with: -avz -s -e ssh -i \"/home/op/.ssh/b-key\" /local/staging/ b.example.com:/remote/site-b/wp-content/plugins/foo/"* ]] || false
}

@test "graft_push_dir refuses BEFORE creating the remote directory when SITE_B_SSH_KEY contains a literal double-quote (review round 3: mkdir used to run first, leaving a pointless mkdir on B before the refusal)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_SSH_KEY='/home/op/.ssh/my "quoted" key'
  ssh() { echo "SHOULD NOT BE CALLED -- refuse before ever touching B"; return 1; }
  rsync() { echo "SHOULD NOT BE CALLED"; return 1; }
  run graft_push_dir b "/local/staging" "/remote/site-b/wp-content/plugins/foo"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"literal double-quote"* ]] || false
}

@test "graft_push_dir --keep-existing also carries SITE_B_SSH_KEY (issue #75)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_SSH_KEY="/home/op/.ssh/b-key"
  ssh() { :; }
  rsync() { echo "rsync called with: $*"; }
  run graft_push_dir b "/local/staging" "/remote/site-b/wp-content/uploads" --keep-existing
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsync called with: -avz -s --ignore-existing -e ssh -i \"/home/op/.ssh/b-key\" /local/staging/ b.example.com:/remote/site-b/wp-content/uploads/"* ]] || false
}

@test "graft_push_dir still uses the wrapped-local tar-through-the-wrapper path when no SSH_HOST is set but a container wrapper is (regression)" {
  unset SITE_B_SSH_HOST
  SITE_B_WP_CMD="ddev exec --raw -p sitegraft-test-b -- wp"
  SITEGRAFT_DRY_RUN=1
  run graft_push_dir b "/local/staging" "/var/www/html/wp-content/uploads"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ddev exec -p sitegraft-test-b --"* ]] || false
  [[ "$output" != *"ssh"* ]] || false
}

# --- graft_remove_file (same architectural gap; its unguarded call sites --
# --- are graft_import_attachments' and graft_remap_attachment_ids'/       --
# --- graft_search_replace_domain's own cleanup of the lib+payload files    --
# --- graft_push_file just pushed) ------------------------------------------

@test "graft_remove_file routes through ssh (not a local rm) when SITE_B_SSH_HOST is set" {
  SITE_B_SSH_HOST="b.example.com"
  ssh() { echo "ssh called with: $*"; }
  run graft_remove_file b "/remote/site-b/wp-content/sitegraft-content-remap-functions.php"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -- b.example.com rm -f '/remote/site-b/wp-content/sitegraft-content-remap-functions.php'"* ]] || false
}

@test "graft_remove_file carries SITE_B_SSH_KEY when it is set (issue #75)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_SSH_KEY="/home/op/.ssh/b-key"
  ssh() { echo "ssh called with: $*"; }
  run graft_remove_file b "/remote/site-b/wp-content/sitegraft-content-remap-functions.php"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -i /home/op/.ssh/b-key -- b.example.com rm -f '/remote/site-b/wp-content/sitegraft-content-remap-functions.php'"* ]] || false
}

@test "graft_remove_file falls back to a local rm for a bare-local site (regression, unchanged by this fix)" {
  unset SITE_B_SSH_HOST SITE_B_WP_CMD
  local target="$BATS_TEST_TMPDIR/site-b/wp-content/lib.php"
  mkdir -p "$(dirname "$target")"
  printf 'x' > "$target"
  run graft_remove_file b "$target"
  [ "$status" -eq 0 ]
  [ ! -e "$target" ]
}

# --- The actual production failure: the three push_file callers that had --
# --- no ssh guard of their own at all (blast radius: media import,        --
# --- id remap, domain remap) ------------------------------------------------

@test "graft_push_media_import_lib pushes to B over ssh instead of writing to the orchestrator's own filesystem (issue #77 — the exact failure observed live)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/remote/site-b"
  SITEGRAFT_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "${SITEGRAFT_ROOT}/lib/php"
  printf '<?php // media import lib' > "${SITEGRAFT_ROOT}/lib/php/media-import-functions.php"
  local calls="$BATS_TEST_TMPDIR/calls"
  : > "$calls"
  ssh() { echo "ssh called with: $*" >> "$calls"; }
  rsync() { echo "rsync called with: $*" >> "$calls"; }
  run graft_push_media_import_lib "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [ "$output" = "/remote/site-b/wp-content/sitegraft-media-import-functions.php" ]
  run cat "$calls"
  [[ "$output" == *"ssh called with: -- b.example.com mkdir -p '/remote/site-b/wp-content'"* ]] || false
  [[ "$output" == *"rsync called with: -avz -s"* ]] || false
  [[ "$output" == *"b.example.com:/remote/site-b/wp-content/sitegraft-media-import-functions.php"* ]] || false
  # never wrote to the orchestrator's own filesystem
  [ ! -e "/remote/site-b" ]
}

@test "graft_push_remap_lib pushes to B over ssh instead of writing to the orchestrator's own filesystem (issue #77)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/remote/site-b"
  SITEGRAFT_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "${SITEGRAFT_ROOT}/lib/php"
  printf '<?php // content remap lib' > "${SITEGRAFT_ROOT}/lib/php/content-remap-functions.php"
  local calls="$BATS_TEST_TMPDIR/calls"
  : > "$calls"
  ssh() { echo "ssh called with: $*" >> "$calls"; }
  rsync() { echo "rsync called with: $*" >> "$calls"; }
  run graft_push_remap_lib "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [ "$output" = "/remote/site-b/wp-content/sitegraft-content-remap-functions.php" ]
  run cat "$calls"
  [[ "$output" == *"ssh called with: -- b.example.com mkdir -p '/remote/site-b/wp-content'"* ]] || false
  [[ "$output" == *"rsync called with: -avz -s"* ]] || false
  [[ "$output" == *"b.example.com:/remote/site-b/wp-content/sitegraft-content-remap-functions.php"* ]] || false
}

@test "graft_push_remap_payload pushes its JSON payload to B over ssh and cleans up the local temp file (issue #77)" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/remote/site-b"
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local calls="$BATS_TEST_TMPDIR/calls"
  : > "$calls"
  ssh() { echo "ssh called with: $*" >> "$calls"; }
  rsync() { echo "rsync called with: $*" >> "$calls"; }
  run graft_push_remap_payload "$run_dir" '{"from":1}' "sitegraft-id-remap-payload.json"
  [ "$status" -eq 0 ]
  [ "$output" = "/remote/site-b/wp-content/sitegraft-id-remap-payload.json" ]
  [ ! -e "${run_dir}/.sitegraft-id-remap-payload.json" ]
  run cat "$calls"
  [[ "$output" == *"rsync called with: -avz -s"* ]] || false
  [[ "$output" == *"b.example.com:/remote/site-b/wp-content/sitegraft-id-remap-payload.json"* ]] || false
}

# --- The three previously-correct call sites, now collapsed onto the      --
# --- shared functions above — proving the collapse is behavior-preserving --

@test "graft_deploy_mu_plugin (collapsed onto graft_push_file) still pushes the mapping mu-plugin to B over ssh" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/remote/site-b"
  SITEGRAFT_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "${SITEGRAFT_ROOT}/mu-plugins"
  printf '<?php // mapper' > "${SITEGRAFT_ROOT}/mu-plugins/sitegraft-id-mapper.php"
  ssh() { echo "ssh called with: $*"; }
  rsync() { echo "rsync called with: $*"; }
  run graft_deploy_mu_plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -- b.example.com mkdir -p '/remote/site-b/wp-content/mu-plugins'"* ]] || false
  [[ "$output" == *"rsync called with: -avz -s"* ]] || false
  [[ "$output" == *"b.example.com:/remote/site-b/wp-content/mu-plugins/sitegraft-id-mapper.php"* ]] || false
}

@test "graft_remove_mu_plugin (collapsed onto graft_remove_file) still removes the mapping mu-plugin from B over ssh" {
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/remote/site-b"
  ssh() { echo "ssh called with: $*"; }
  run graft_remove_mu_plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -- b.example.com rm -f '/remote/site-b/wp-content/mu-plugins/sitegraft-id-mapper.php'"* ]] || false
}

@test "graft_media_sync (collapsed onto graft_push_dir) still pushes media to B over ssh without overwriting existing files" {
  SITE_A_WP_PATH="$BATS_TEST_TMPDIR/site-a"
  unset SITE_A_SSH_HOST SITE_A_WP_CMD
  mkdir -p "${SITE_A_WP_PATH}/wp-content/uploads"
  printf 'x' > "${SITE_A_WP_PATH}/wp-content/uploads/photo.jpg"
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/remote/site-b"
  ssh() { echo "ssh called with: $*"; }
  rsync() {
    if [[ "$*" == *"${SITE_A_WP_PATH}"* ]]; then command rsync "$@"; else echo "rsync called with: $*"; fi
  }
  run graft_media_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -- b.example.com mkdir -p '/remote/site-b/wp-content/uploads'"* ]] || false
  [[ "$output" == *"rsync called with: -avz -s --ignore-existing"* ]] || false
  [[ "$output" == *"b.example.com:/remote/site-b/wp-content/uploads/"* ]] || false
}

@test "graft_copy_wp_content_dir (collapsed onto graft_push_dir) still pushes the stack component to B over ssh — MINOR-3, the step that already succeeded live before the media step failed" {
  SITE_A_WP_PATH="$BATS_TEST_TMPDIR/site-a"
  unset SITE_A_SSH_HOST SITE_A_WP_CMD
  mkdir -p "${SITE_A_WP_PATH}/wp-content/plugins/foo"
  printf 'x' > "${SITE_A_WP_PATH}/wp-content/plugins/foo/foo.php"
  SITE_B_SSH_HOST="b.example.com"
  SITE_B_WP_PATH="/remote/site-b"
  ssh() { echo "ssh called with: $*"; }
  rsync() {
    if [[ "$*" == *"${SITE_A_WP_PATH}"* ]]; then command rsync "$@"; else echo "rsync called with: $*"; fi
  }
  run graft_copy_wp_content_dir "wp-content/plugins/foo" "$BATS_TEST_TMPDIR/staging"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -- b.example.com mkdir -p '/remote/site-b/wp-content/plugins/foo'"* ]] || false
  [[ "$output" == *"rsync called with: -avz -s"* ]] || false
  [[ "$output" == *"b.example.com:/remote/site-b/wp-content/plugins/foo/"* ]] || false
}
