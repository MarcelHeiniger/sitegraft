# tests/unit/test_graft_fontstep.bats — issue #83: WordPress 6.5+'s Font
# Library writes uploaded font files to a directory that is a SIBLING of
# `wp-content/uploads/` (not a subdirectory of it), so graft_media_sync
# (tests/unit/test_graft_mediastep.bats) never reaches it. Covers
# graft_font_dir (the `font_dir` filter read, never hardcoded) and
# graft_fonts_sync (the actual pull/push, same `--keep-existing` safety
# property as media_sync).
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

# --- graft_font_dir --------------------------------------------------------

@test "graft_font_dir returns the path wp_get_font_dir() reports" {
  wp_remote() {
    local alias_lc="$1"; shift
    [ "$alias_lc" = "a" ] || { echo "UNEXPECTED ALIAS: $alias_lc"; return 1; }
    [ "$1" = "eval" ] || { echo "UNEXPECTED SUBCOMMAND: $1"; return 1; }
    echo "/site-a/wp-content/fonts"
  }
  run graft_font_dir a
  [ "$status" -eq 0 ]
  [ "$output" = "/site-a/wp-content/fonts" ]
}

@test "graft_font_dir returns empty (not an error) when wp_get_font_dir() is unavailable — pre-6.5 core is the ordinary case" {
  # The eval itself guards with function_exists() and echoes nothing when
  # it's false — this stub mirrors that real PHP behavior directly rather
  # than special-casing it in bash.
  wp_remote() { :; }
  run graft_font_dir a
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "graft_font_dir fails closed (non-zero) when the wp eval itself fails, never silently returns empty for a real error" {
  wp_remote() { return 1; }
  run graft_font_dir a
  [ "$status" -ne 0 ]
}

@test "graft_font_dir reads the real path even under --dry-run, so a preview does not choke on run_or_echo's own '[dry-run] ...' text" {
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    if is_dry_run; then
      echo "[dry-run] wp_remote $*"
      return 0
    fi
    echo "/site-a/wp-content/fonts"
  }
  run graft_font_dir a
  [ "$status" -eq 0 ]
  [ "$output" = "/site-a/wp-content/fonts" ]
}

# --- graft_fonts_sync -------------------------------------------------------

@test "graft_fonts_sync is a no-op when A has no font directory (pre-6.5 core, or the Font Library was never used)" {
  graft_font_dir() { [ "$1" = "a" ] && return 0; echo "SHOULD NOT BE CALLED FOR B" >&2; return 1; }
  graft_pull_dir() { echo "PULL SHOULD NOT HAPPEN"; return 1; }
  graft_push_dir() { echo "PUSH SHOULD NOT HAPPEN"; return 1; }
  run graft_fonts_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT HAPPEN"* ]] || false
}

@test "graft_fonts_sync refuses (non-zero) when A has fonts but B's font directory cannot be resolved — never silently drops A's fonts a second time" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else return 0; fi
  }
  graft_pull_dir() { echo "PULL SHOULD NOT HAPPEN"; return 1; }
  graft_push_dir() { echo "PUSH SHOULD NOT HAPPEN"; return 1; }
  run graft_fonts_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT HAPPEN"* ]] || false
}

@test "graft_fonts_sync pulls from A's real font_dir and pushes to B's real font_dir with --keep-existing" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else echo "/site-b/wp-content/fonts"; fi
  }
  graft_pull_dir() { echo "PULLED alias=$1 src=$2 dst=$3"; return 0; }
  graft_push_dir() { echo "PUSHED alias=$1 src=$2 dst=$3 mode=$4"; return 0; }
  unset SITE_A_SSH_HOST
  run graft_fonts_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PULLED alias=a src=/site-a/wp-content/fonts"* ]] || false
  [[ "$output" == *"PUSHED alias=b"*"dst=/site-b/wp-content/fonts mode=--keep-existing"* ]] || false
}

@test "graft_fonts_sync routes the pull through ssh, never graft_pull_dir, when A is remote" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else echo "/site-b/wp-content/fonts"; fi
  }
  graft_pull_dir() { echo "SHOULD NOT BE CALLED FOR A REMOTE"; return 1; }
  graft_push_dir() { echo "PUSHED"; return 0; }
  SITE_A_SSH_HOST="host-a.example.com"
  run_or_echo() { echo "RAN: $*"; return 0; }
  run graft_fonts_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN: rsync -avz host-a.example.com:/site-a/wp-content/fonts/"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# --- graft_fonts_sync guards its own exit status (same shape as
# graft_media_sync's own PR #90 guard, and same reason: phase_graft calls
# this function on the LHS of a `||`, which disables `set -e` for the
# whole function body, so a mid-body failure must be guarded explicitly or
# it silently falls through to the push).
@test "graft_fonts_sync returns non-zero when the pull from A fails, even called on the LHS of a || (set -e is off there)" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else echo "/site-b/wp-content/fonts"; fi
  }
  graft_pull_dir() { echo "PULL FAILED"; return 23; }
  graft_push_dir() { echo "PUSHED ANYWAY"; return 0; }
  unset SITE_A_SSH_HOST

  local rc=0
  ( set -euo pipefail; graft_fonts_sync "$BATS_TEST_TMPDIR/run" ) || rc=$?

  [ "$rc" -ne 0 ]
}

@test "graft_fonts_sync returns non-zero when B's push fails, even called on the LHS of a || (set -e is off there)" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else echo "/site-b/wp-content/fonts"; fi
  }
  graft_pull_dir() { return 0; }
  graft_push_dir() { echo "PUSH FAILED"; return 11; }
  unset SITE_A_SSH_HOST

  local rc=0
  ( set -euo pipefail; graft_fonts_sync "$BATS_TEST_TMPDIR/run" ) || rc=$?

  [ "$rc" -ne 0 ]
}
