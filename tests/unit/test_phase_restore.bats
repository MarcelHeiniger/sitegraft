bats_require_minimum_version 1.5.0

# tests/unit/test_phase_restore.bats — phase_restore's control flow: guard
# clauses, the pre-restore safety snapshot (design doc §6.7, "even a restore
# has to stay reversible"), and --yes bypassing confirmation. Stubs
# backup_db_export/backup_wp_content (the two functions that actually talk to
# B) the same way test_phase_backup.bats does — restore.sh itself is a real,
# generated, executed script (a harmless stand-in here), so the actual
# run_or_echo/exec path is exercised for real.
setup() {
  load '../../lib/core.sh'
  load '../../lib/profile.sh'
  # inventory.sh for sq(), which every path baked into a generated restore.sh
  # goes through; bin/sitegraft sources it before backup.sh for this phase too.
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'

  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  export SITEGRAFT_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$SITEGRAFT_PROFILES_DIR" "$SITEGRAFT_STATE_DIR"

  # A real directory for B: the pre-restore snapshot's wp-content manifest is
  # read from B's own filesystem and cross-checked against the pulled archive by
  # entry count, so B has to hold exactly what the backup_wp_content stub below
  # pulls.
  B_ROOT="$BATS_TEST_TMPDIR/site-b"
  mkdir -p "${B_ROOT}/wp-content/themes"
  touch "${B_ROOT}/wp-content/themes/dummy.txt"

  cat > "${SITEGRAFT_PROFILES_DIR}/t.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="${B_ROOT}"
SITE_B_WP_CMD="wp"
SITEGRAFT_STATE_DIR="${SITEGRAFT_STATE_DIR}"
EOF

  RUN_DIR="${SITEGRAFT_STATE_DIR}/t-20260101T000000"
  mkdir -p "$RUN_DIR"

  # A harmless stand-in restore.sh — exercises the real run_or_echo/exec
  # path in phase_restore without needing a live wp-cli/rsync target.
  cat > "${RUN_DIR}/restore.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAKE RESTORE RAN"
EOF
  chmod +x "${RUN_DIR}/restore.sh"

  # Bug found by review (Viktor): these stubs previously wrote their fake
  # artifact unconditionally, even under dry-run, so a dry-run test never
  # actually exercised phase_restore's real dry-run code path — same class
  # of gap as test_phase_backup.bats's own stubs (see that file's comment).
  # Honoring is_dry_run here closes it.
  backup_db_export() {
    local dest_dir="$1"
    is_dry_run && { echo "[dry-run] would export B database to ${dest_dir}/b-db.sql.gz"; return 0; }
    mkdir -p "$dest_dir"
    printf 'fake pre-restore db snapshot' | gzip > "${dest_dir}/b-db.sql.gz"
  }
  backup_wp_content() {
    local dest_dir="$1"
    is_dry_run && { echo "[dry-run] would archive B wp-content to ${dest_dir}"; return 0; }
    mkdir -p "${dest_dir}/themes"
    touch "${dest_dir}/themes/dummy.txt"
  }
}

@test "phase_restore requires both --profile and --run" {
  run phase_restore --profile t
  [ "$status" -eq 1 ]
  [[ "$output" == *"--profile"* ]]
}

@test "phase_restore fails clearly when the run has no restore.sh" {
  rm -f "${RUN_DIR}/restore.sh"
  run phase_restore --profile t --run "$RUN_DIR" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"restore.sh"* ]]
}

@test "phase_restore declines without confirmation when --yes is not passed, BY THE TTY GUARD and not by a read that happened to see EOF" {
  run --separate-stderr phase_restore --profile t --run "$RUN_DIR"
  [ "$status" -eq 1 ]

  # The status assertion alone does NOT discriminate: before the [ -t 0 ]
  # guard existed, this same test passed because the bare `read` hit EOF on
  # a /dev/null stdin and returned non-zero, which also declined. Both worlds
  # exit 1, so a status-only test ratifies neither -- measured in review by
  # deleting the guard entirely and watching all 13 tests in this file stay
  # green.
  #
  # The message is what tells the two apart. It only exists on the guard's
  # path, so this assertion goes red the moment the guard is removed -- and
  # it is also the thing an operator scripting `sitegraft restore` actually
  # needs, since without the guard that run does not decline at all on a
  # stdin that never reaches EOF: it hangs forever (issue #46).
  [[ "$stderr" == *"needs --yes"* ]] || false
}

@test "phase_restore --yes runs restore.sh and takes a pre-restore snapshot of B's db AND wp-content" {
  run phase_restore --profile t --run "$RUN_DIR" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAKE RESTORE RAN"* ]] || false
  [[ "$output" == *"restore complete"* ]] || [[ "$output" == *"Restore complete"* ]] || [[ "$output" == *"restore complete."* ]] || false
  local snap_dir
  snap_dir=$(ls -dt "${RUN_DIR}"/pre-restore-* | head -1)
  [ -n "$snap_dir" ]
  [ -f "${snap_dir}/backup/b-db.sql.gz" ]
  [ -d "${snap_dir}/backup/b-wp-content" ]
  [ -n "$(ls -A "${snap_dir}/backup/b-wp-content")" ]
}

# MINOR review recommendation taken (Viktor): the pre-restore snapshot is now
# turnkey-reversible, not just data-only — design doc §6.7 ("even a restore
# has to stay reversible") should mean an operator can actually run
# something, not hand-reconstruct the right commands under pressure.
@test "phase_restore's pre-restore snapshot gets its own turnkey restore.sh" {
  run phase_restore --profile t --run "$RUN_DIR" --yes
  [ "$status" -eq 0 ]
  local snap_dir
  snap_dir=$(ls -dt "${RUN_DIR}"/pre-restore-* | head -1)
  [ -x "${snap_dir}/restore.sh" ]
  run grep -Ei 'wp_remote|sitegraft_|backup_checksum|backup_db_export|backup_wp_content|phase_backup|phase_restore' "${snap_dir}/restore.sh"
  [ "$status" -ne 0 ]
}

@test "phase_restore's pre-restore snapshot is owner-only" {
  phase_restore --profile t --run "$RUN_DIR" --yes
  local snap_dir dir_mode db_mode
  snap_dir=$(ls -dt "${RUN_DIR}"/pre-restore-* | head -1)
  dir_mode=$(stat -c '%a' "$snap_dir" 2>/dev/null || stat -f '%Lp' "$snap_dir" 2>/dev/null)
  db_mode=$(stat -c '%a' "${snap_dir}/backup/b-db.sql.gz" 2>/dev/null || stat -f '%Lp' "${snap_dir}/backup/b-db.sql.gz" 2>/dev/null)
  [ "$dir_mode" = "700" ]
  [ "$db_mode" = "600" ]
}

@test "phase_restore takes the pre-restore snapshot BEFORE running restore.sh, not after" {
  # If restore.sh ran first and only then failed, this proves the snapshot
  # still exists and is real — a snapshot taken after a bad restore already
  # ran would be useless as a safety net.
  cat > "${RUN_DIR}/restore.sh" <<'EOF'
#!/usr/bin/env bash
echo "restore.sh started"
exit 1
EOF
  chmod +x "${RUN_DIR}/restore.sh"
  run phase_restore --profile t --run "$RUN_DIR" --yes
  [ "$status" -ne 0 ]
  local snap_dir
  snap_dir=$(ls -dt "${RUN_DIR}"/pre-restore-* | head -1)
  [ -n "$snap_dir" ]
  [ -s "${snap_dir}/backup/b-db.sql.gz" ]
}

# MINOR review recommendation taken (Viktor): --dry-run was missing from
# phase_restore even though the DoD lists it for every phase that writes.
@test "phase_restore accepts --dry-run as a flag" {
  run phase_restore --profile t --run "$RUN_DIR" --yes --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"FAKE RESTORE RAN"* ]]
}

# MAJOR bug regression (Viktor), same root cause as phase_backup's own
# subshell: under a real dry-run, backup_db_export writes nothing, so a
# `[ -f ... ] && chmod ...` as the pre-restore snapshot subshell's LAST
# statement used to make the whole subshell's exit status that of the false
# test — read as a hard failure by `) || return 1`, even though nothing
# actually went wrong. Fixed the same way as phase_backup: an `if` guard
# instead of `&&`, so a false test never becomes the subshell's own exit
# status.
@test "phase_restore --dry-run does not falsely report failure (MAJOR regression, same bug as phase_backup)" {
  SITEGRAFT_DRY_RUN=1 run phase_restore --profile t --run "$RUN_DIR" --yes
  [ "$status" -eq 0 ]
}

# "Even a restore has to stay reversible" is not satisfied by a snapshot whose
# own restore.sh could not be generated. The generator refuses to leave behind
# a script bash cannot parse, and phase_restore must stop there rather than run
# the real restore with no way back.
@test "phase_restore refuses to run when the pre-restore snapshot's restore.sh cannot be generated" {
  backup_generate_restore_script() { return 1; }
  run phase_restore --profile t --run "$RUN_DIR" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"without a usable way back"* ]] || false
  [[ "$output" != *"FAKE RESTORE RAN"* ]] || false
}

# --- the safety net has to be real before the destructive half runs ---
# phase_restore's snapshot subshell is the same `( ... ) || return 1` shape as
# phase_backup's, so bash suppresses errexit inside it and an explicit `set -e`
# does not bring it back. Each artifact call therefore carries `|| exit 1`.
#
# The asymmetry matters more here than in phase_backup: this branch has NO
# downstream artifact verification at all. If a snapshot call fails and its
# guard is gone, the subshell still returns 0, the snapshot's own restore.sh is
# generated over an empty or partial directory, and the real restore proceeds
# with a safety net that cannot restore anything. Each of these asserts that
# the restore never ran — not merely that phase_restore returned non-zero.

@test "phase_restore FAILS, and never runs the restore, when the snapshot's wp-content pull fails while leaving a partial copy" {
  backup_wp_content() {
    local dest_dir="$1"
    mkdir -p "${dest_dir}/themes"
    touch "${dest_dir}/themes/dummy.txt"   # non-empty: nothing downstream would notice
    return 1                               # ... but the pull FAILED
  }
  run phase_restore --profile t --run "$RUN_DIR" --yes
  [ "$status" -ne 0 ]
  [[ "$output" != *"FAKE RESTORE RAN"* ]] || false
}

@test "phase_restore FAILS, and never runs the restore, when the snapshot's database export fails while leaving a plausible dump" {
  backup_db_export() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    printf 'fake pre-restore db snapshot' | gzip > "${dest_dir}/b-db.sql.gz"
    return 1
  }
  run phase_restore --profile t --run "$RUN_DIR" --yes
  [ "$status" -ne 0 ]
  [[ "$output" != *"FAKE RESTORE RAN"* ]] || false
}

@test "phase_restore FAILS, and never runs the restore, when the snapshot's wp-content manifest cannot be recorded" {
  backup_write_wp_content_manifest() { return 1; }
  run phase_restore --profile t --run "$RUN_DIR" --yes
  [ "$status" -ne 0 ]
  [[ "$output" != *"FAKE RESTORE RAN"* ]] || false
}
