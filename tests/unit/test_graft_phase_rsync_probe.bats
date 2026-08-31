# tests/unit/test_graft_phase_rsync_probe.bats — issue #94 / ADR 0010:
# phase_graft's own phase-start rsync arg-escaping check
# (sitegraft_require_rsync_arg_escaping, lib/inventory.sh). Runs once,
# right after profile_load, before ANY other guard clause (run_dir
# resolution, backup.complete, modules_discover, manifest parsing).
#
# A dedicated file, not folded into tests/unit/test_graft_phase_wiring.bats
# or tests/unit/test_graft_resume_safety.bats: both of those always STUB
# profile_load rather than load lib/profile.sh for real, since their own
# subjects don't need a genuinely profile-driven SSH host. This check's
# whole point is profile-driven (SITE_A_SSH_HOST/SITE_B_SSH_HOST as read
# from a real profile file), so this file loads the real profile/inventory
# stack instead — same convention as tests/unit/test_phase_backup.bats.
#
# Each test below relies on the check's ORDERING, not just its presence:
# an incapable rsync must abort with THIS check's own message before the
# later "no scan/plan run found" error a missing/absent --run would
# otherwise produce (no --run is given, and no run dir exists, in every
# test here) — proving the check runs first, and the reverse (no message
# leaking through when it should have been skipped/not-applicable) proves
# it doesn't fire when it shouldn't.
bats_require_minimum_version 1.5.0
setup() {
  load '../../lib/core.sh'
  load '../../lib/profile.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

_incapable_rsync_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/rsync" <<'EOS'
#!/usr/bin/env bash
case " $* " in
  *" --old-args "*) exit 1 ;;
esac
exit 0
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/rsync"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

_write_demo_profile() {
  # $1: extra profile lines (e.g. SITE_A_SSH_HOST=...)
  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  mkdir -p "$SITEGRAFT_PROFILES_DIR"
  cat > "${SITEGRAFT_PROFILES_DIR}/demo.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/var/www/b"
SITE_B_WP_CMD="wp"
SITEGRAFT_STATE_DIR="$BATS_TEST_TMPDIR/state"
$1
EOF
  mkdir -p "$BATS_TEST_TMPDIR/state"
}

@test "phase_graft refuses right after profile_load when SITE_A_SSH_HOST is ssh-remote and the local rsync cannot do --no-old-args (issue #94)" {
  _incapable_rsync_stub
  _write_demo_profile 'SITE_A_SSH_HOST="a.example.com"'
  run phase_graft --profile demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"openrsync"* || "$output" == *"3.2.4"* ]] || false
  [[ "$output" != *"no scan/plan run found"* ]] || false
}

@test "phase_graft refuses right after profile_load when SITE_B_SSH_HOST (not A) is ssh-remote and the local rsync cannot do --no-old-args (issue #94)" {
  _incapable_rsync_stub
  _write_demo_profile 'SITE_B_SSH_HOST="b.example.com"'
  run phase_graft --profile demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"openrsync"* || "$output" == *"3.2.4"* ]] || false
  [[ "$output" != *"no scan/plan run found"* ]] || false
}

@test "phase_graft's --dry-run does NOT run the rsync arg-escaping check (falls through to the next guard instead)" {
  _incapable_rsync_stub
  _write_demo_profile 'SITE_A_SSH_HOST="a.example.com"'
  run phase_graft --profile demo --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"no scan/plan run found"* ]] || false
  [[ "$output" != *"openrsync"* ]] || false
}

@test "phase_graft does not require the rsync arg-escaping check at all when neither SITE_A_SSH_HOST nor SITE_B_SSH_HOST is set" {
  _incapable_rsync_stub
  _write_demo_profile ''
  run phase_graft --profile demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"no scan/plan run found"* ]] || false
  [[ "$output" != *"openrsync"* ]] || false
}

@test "phase_graft proceeds past the rsync arg-escaping check when the local rsync IS capable (regression, prove it can pass too)" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/rsync" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/rsync"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  _write_demo_profile 'SITE_A_SSH_HOST="a.example.com"'
  run phase_graft --profile demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"no scan/plan run found"* ]] || false
  [[ "$output" != *"openrsync"* ]] || false
}
