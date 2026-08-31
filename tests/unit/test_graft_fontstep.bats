bats_require_minimum_version 1.5.0

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

# --- Review fix-pack (nit 1): graft_font_dir is the one place every
# caller (graft_fonts_sync's graft_pull_dir/graft_push_dir calls) goes
# through, so a value that is not a genuine absolute path is refused HERE,
# before it ever reaches a shell string built elsewhere.
@test "graft_font_dir refuses (non-zero) a non-empty result that is not an absolute path" {
  wp_remote() { echo "relative/not/absolute"; }
  run graft_font_dir a
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-absolute path"* ]] || false
}

@test "graft_font_dir refuses a result that looks like a shell command substitution rather than a path" {
  wp_remote() { echo '$(rm -rf /)'; }
  run graft_font_dir a
  [ "$status" -ne 0 ]
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

@test "graft_fonts_sync routes the pull through ssh, never graft_pull_dir, when A is remote and the directory exists" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else echo "/site-b/wp-content/fonts"; fi
  }
  graft_pull_dir() { echo "SHOULD NOT BE CALLED FOR A REMOTE"; return 1; }
  graft_push_dir() { echo "PUSHED"; return 0; }
  graft_ssh_path_exists() { echo "CHECKED: $1 $2"; return 0; }
  SITE_A_SSH_HOST="host-a.example.com"
  run_or_echo() { echo "RAN: $*"; return 0; }
  run graft_fonts_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  # Called with the ALIAS ("a"), not the raw host -- graft_ssh_path_exists
  # resolves both SITE_A_SSH_HOST and SITE_A_SSH_KEY internally now
  # (review fix-pack, BLOCKER: a raw-host signature is exactly what let the
  # first draft lose SITE_*_SSH_KEY when it built its own ssh call instead
  # of reusing the shared probe -- see graft_ssh_path_exists' own header).
  [[ "$output" == *"CHECKED: a /site-a/wp-content/fonts"* ]] || false
  # issues #75/#94: routed through rsync_pull_remote now -- --no-old-args
  # forces default arg-escaping (ADR 0010), and no `-i`/`-e` appears here
  # because SITE_A_SSH_KEY is unset in this test (see the dedicated
  # ssh-key test below for the case where it is set).
  [[ "$output" == *"RAN: rsync -avz --no-old-args host-a.example.com:/site-a/wp-content/fonts/"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "graft_fonts_sync's ssh pull carries SITE_A_SSH_KEY via rsync -e, and never contacts A without it, when the key is set (issue #75)" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else echo "/site-b/wp-content/fonts"; fi
  }
  graft_pull_dir() { echo "SHOULD NOT BE CALLED FOR A REMOTE"; return 1; }
  graft_push_dir() { echo "PUSHED"; return 0; }
  graft_ssh_path_exists() { return 0; }
  SITE_A_SSH_HOST="host-a.example.com"
  SITE_A_SSH_KEY="/home/op/.ssh/site-a-deploy-key"
  run_or_echo() { echo "RAN: $*"; return 0; }
  run graft_fonts_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [[ "$output" == *'RAN: rsync -avz --no-old-args -e ssh -i "/home/op/.ssh/site-a-deploy-key" host-a.example.com:/site-a/wp-content/fonts/'* ]] || false
}

# --- BLOCKER 1 (review fix-pack): wp_get_font_dir() COMPUTES/FILTERS a
# path, it does NOT create the directory -- that only happens on
# WordPress's own first real font upload. So a WP 6.5+ A that has simply
# never used the Font Library yet -- the ORDINARY case, not an edge case --
# has a non-empty font_dir_a with nothing on disk at that path. The local
# branch was always safe (graft_pull_dir's own "source directory does not
# exist yet" no-op, tests/unit/test_graft_mediastep.bats's sibling
# coverage for media). The ssh branch bypasses graft_pull_dir entirely
# (issue #77's own reasoning — graft_pull_dir never consults
# SITE_*_SSH_HOST) and, before this fix, had no equivalent check: it
# rsynced unconditionally, rsync exited 23 against the absent source, and
# graft_fonts_sync's own `|| return $?` propagated that all the way up
# through phase_graft, aborting the ENTIRE graft over a directory nobody
# ever expected to exist yet.
@test "graft_fonts_sync's ssh pull is a no-op (not a hard failure) when A's font directory does not exist yet on disk (BLOCKER 1, issue #83 review fix-pack)" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else echo "/site-b/wp-content/fonts"; fi
  }
  graft_pull_dir() { echo "SHOULD NOT BE CALLED FOR A REMOTE"; return 1; }
  graft_push_dir() { echo "PUSHED alias=$1 src=$2 dst=$3 mode=$4"; return 0; }
  graft_ssh_path_exists() { return 1; }
  SITE_A_SSH_HOST="host-a.example.com"
  run_or_echo() { echo "RAN: $*"; return 0; }
  run graft_fonts_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist"* ]] || false
  [[ "$output" != *"RAN: rsync"* ]] || false
  # The rest of the step still runs -- an absent source is "nothing to
  # sync", never a reason to abandon a step that could otherwise succeed.
  [[ "$output" == *"PUSHED"* ]] || false
}

# --- BLOCKER (second review round): the case above (rc 1, confirmed
# absent) and THIS case (rc 2, could not determine — ssh itself failed:
# unreachable host, refused auth, wrong/missing SITE_A_SSH_KEY) must not
# collapse into the same outcome. The first fix-pack draft's
# `graft_ssh_path_exists` returned a plain boolean, so `! graft_ssh_path_
# exists ...` read BOTH as "absent, nothing to pull" — on a real ssh
# failure this silently skipped the sync, marked graft.fonts_sync.done,
# and reported the whole graft a SUCCESS, having synced nothing and never
# retrying on resume. Before issue #83's fix-pack existed at all, that
# same profile failed LOUDLY at rsync instead — the bug turned a noisy
# failure into a silent false success, exactly backwards.
@test "graft_fonts_sync's ssh pull is a HARD FAILURE (never a silent skip) when the ssh probe itself cannot determine existence (rc 2 -- unreachable host, refused auth, or a wrong SSH key) (BLOCKER, issue #83 second review round)" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else echo "/site-b/wp-content/fonts"; fi
  }
  graft_pull_dir() { echo "SHOULD NOT BE CALLED FOR A REMOTE"; return 1; }
  graft_push_dir() { echo "SHOULD NOT BE CALLED -- the step must abort before ever reaching the push"; return 0; }
  graft_ssh_path_exists() { return 2; }
  SITE_A_SSH_HOST="host-a.example.com"
  run_or_echo() { echo "RAN: $*"; return 0; }
  run graft_fonts_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not determine"* ]] || false
  [[ "$output" != *"RAN: rsync"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  # Never takes the "confirmed absent" no-op path (its own distinct log
  # line, checked verbatim -- not a bare "does not exist" substring, which
  # this branch's OWN honest wording ("not the ordinary 'directory does
  # not exist yet' case") legitimately contains too) for a question that
  # was never actually answered.
  [[ "$output" != *"source directory does not exist on a yet"* ]] || false
}

@test "graft_fonts_sync's ssh pull skips the real existence check under --dry-run and previews the rsync anyway (mirrors graft_pull_dir's own non-ssh dry-run behavior)" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else echo "/site-b/wp-content/fonts"; fi
  }
  graft_pull_dir() { echo "SHOULD NOT BE CALLED FOR A REMOTE"; return 1; }
  graft_push_dir() { echo "[dry-run] PUSHED"; return 0; }
  graft_ssh_path_exists() { echo "SHOULD NOT BE CALLED UNDER DRY-RUN" >&2; return 1; }
  SITE_A_SSH_HOST="host-a.example.com"
  SITEGRAFT_DRY_RUN=1
  run_or_echo() { echo "[dry-run] $*"; return 0; }
  run --separate-stderr graft_fonts_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"[dry-run] rsync"* ]] || false
  # issue #94: this branch (is_dry_run, lib/graft.sh) is a SEPARATE call
  # site from the real (exists_rc==0) branch tested above -- it is its own
  # `rsync_pull_remote` call, not shared code, so it needs its own
  # assertion. Found missing in review: without it, reverting JUST this
  # branch back to a bare `rsync -avz` (dropping --no-old-args) left every
  # one of the 1121 other tests green.
  [[ "$output" == *"[dry-run] rsync -avz --no-old-args host-a.example.com:/site-a/wp-content/fonts/"* ]] || false
}

@test "graft_fonts_sync's ssh pull under --dry-run also carries SITE_A_SSH_KEY via rsync -e when it is set (issue #75, same gap as the --no-old-args test above)" {
  graft_font_dir() {
    if [ "$1" = "a" ]; then echo "/site-a/wp-content/fonts"; else echo "/site-b/wp-content/fonts"; fi
  }
  graft_pull_dir() { echo "SHOULD NOT BE CALLED FOR A REMOTE"; return 1; }
  graft_push_dir() { echo "[dry-run] PUSHED"; return 0; }
  graft_ssh_path_exists() { echo "SHOULD NOT BE CALLED UNDER DRY-RUN" >&2; return 1; }
  SITE_A_SSH_HOST="host-a.example.com"
  SITE_A_SSH_KEY="/home/op/.ssh/a-key"
  SITEGRAFT_DRY_RUN=1
  run_or_echo() { echo "[dry-run] $*"; return 0; }
  run --separate-stderr graft_fonts_sync "$BATS_TEST_TMPDIR/run"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *'[dry-run] rsync -avz --no-old-args -e ssh -i "/home/op/.ssh/a-key" host-a.example.com:/site-a/wp-content/fonts/'* ]] || false
}

# --- graft_ssh_path_exists ---------------------------------------------
#
# Signature is now <alias> <path>, not <host> <path> (second review round):
# resolving SITE_<ALIAS>_SSH_HOST *and* SITE_<ALIAS>_SSH_KEY internally,
# from the alias, is what makes losing the dedicated key structurally
# impossible for a future caller -- a raw-host parameter lets a caller
# forget to also pass/resolve the key (which is exactly how the first
# draft of this function lost it, and exactly what inventory.sh's own
# sibling probe, inventory_check_path_topology, never lost). Every test
# below sets SITE_A_SSH_HOST (and, where relevant, SITE_A_SSH_KEY) the way
# a real profile would, then calls with alias "a".

@test "graft_ssh_path_exists returns 0 when the remote test -d succeeds" {
  SITE_A_SSH_HOST="host-a.example.com"
  ssh() { echo "ssh called: $*" >&2; return 0; }
  run graft_ssh_path_exists a "/site-a/wp-content/fonts"
  [ "$status" -eq 0 ]
}

@test "graft_ssh_path_exists returns 1 (confirmed absent) when the remote test -d itself reports absence" {
  SITE_A_SSH_HOST="host-a.example.com"
  ssh() { return 1; }
  run graft_ssh_path_exists a "/site-a/wp-content/fonts"
  [ "$status" -eq 1 ]
}

# --- BLOCKER (second review round): the three-way distinction ------------
#
# 0 (exists), 1 (`test -d` itself says absent) and "ssh could not even ask
# the question" are three DIFFERENT facts, and only the first two used to
# be tested. rc 255 is ssh's own real connection/authentication failure
# code (measured against real OpenSSH) -- a wrong password, a host key
# mismatch, a firewalled port, or (below) a wrong/missing dedicated key
# ALL produce it, and none of them mean "the directory is absent". This is
# the mutation-tested regression guard for the fix: graft_ssh_path_exists
# must not return the SAME thing for "no" as for "I don't know".
@test "graft_ssh_path_exists returns 2 (could not determine -- NOT 'confirmed absent') when ssh itself fails to connect (BLOCKER, issue #83 second review round)" {
  SITE_A_SSH_HOST="host-a.example.com"
  ssh() { return 255; }
  run graft_ssh_path_exists a "/site-a/wp-content/fonts"
  [ "$status" -eq 2 ]
  [ "$status" -ne 1 ]
}

@test "graft_ssh_path_exists returns 2 for an ARBITRARY non-0/1 ssh exit status, not just 255 -- the check is 'not 0, not 1', never a fixed allowlist" {
  SITE_A_SSH_HOST="host-a.example.com"
  ssh() { return 42; }
  run graft_ssh_path_exists a "/site-a/wp-content/fonts"
  [ "$status" -eq 2 ]
}

# ssh_test_dir_rc (lib/inventory.sh) redirects the real ssh call's own
# stdout/stderr to /dev/null (it is a probe, not user-visible output), so
# a stub that merely echoes what it received is invisible to bats' own
# $output -- these two tests instead have the stub RECORD its argv to a
# file, read back after `run` returns.
@test "graft_ssh_path_exists passes SITE_A_SSH_KEY to ssh as -i, the same way inventory_check_path_topology already does (issue #75)" {
  SITE_A_SSH_HOST="host-a.example.com"
  SITE_A_SSH_KEY="/home/op/.ssh/deploy_key"
  local call_log="$BATS_TEST_TMPDIR/ssh-call.log"
  ssh() { printf '%s\n' "$*" > "$call_log"; return 0; }
  run graft_ssh_path_exists a "/site-a/wp-content/fonts"
  [ "$status" -eq 0 ]
  [[ "$(cat "$call_log")" == *"-i /home/op/.ssh/deploy_key -- host-a.example.com"* ]] || false
}

@test "graft_ssh_path_exists omits -i entirely when no dedicated SSH key is configured (the ordinary case)" {
  SITE_A_SSH_HOST="host-a.example.com"
  unset SITE_A_SSH_KEY
  local call_log="$BATS_TEST_TMPDIR/ssh-call.log"
  ssh() { printf '%s\n' "$*" > "$call_log"; return 0; }
  run graft_ssh_path_exists a "/site-a/wp-content/fonts"
  [[ "$(cat "$call_log")" != *" -i "* ]] || false
}

# Behavioral, not string-matching: the stub below actually EXECUTES the
# command graft_ssh_path_exists built for the remote shell (`ssh -- host
# cmd`'s own third positional argument is a single string a real ssh hands
# to the remote user's shell for interpretation — reproduced locally with
# `bash -c`) against a REAL directory whose name contains a single quote.
# A hand-written `'${path}'` wrap (the bug this function exists to avoid —
# see graft_pull_dir/graft_push_dir's own matching fix, this same review
# fix-pack) would close its quoting early on that embedded `'`, turning
# the rest of the path into unrelated shell syntax; `sq()` would not.
# Proves the round trip end to end instead of asserting on brittle,
# hand-computed escaped-string output.
@test "graft_ssh_path_exists's remote command survives a real directory whose name contains a single quote" {
  SITE_A_SSH_HOST="host-a.example.com"
  ssh() { shift 2; bash -c "$1"; }
  local d="$BATS_TEST_TMPDIR/it's-fonts"
  mkdir -p "$d"
  run graft_ssh_path_exists a "$d"
  [ "$status" -eq 0 ]
}

@test "graft_ssh_path_exists correctly reports absence too, for the same quoted-path shape" {
  SITE_A_SSH_HOST="host-a.example.com"
  ssh() { shift 2; bash -c "$1"; }
  run graft_ssh_path_exists a "$BATS_TEST_TMPDIR/it's-fonts-never-created"
  [ "$status" -eq 1 ]
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
