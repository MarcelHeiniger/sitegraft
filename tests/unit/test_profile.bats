# tests/unit/test_profile.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/profile.sh'
  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  mkdir -p "$SITEGRAFT_PROFILES_DIR"
  cat > "$SITEGRAFT_PROFILES_DIR/demo.conf" <<'EOF'
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/site-a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/site-b"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-runs"
EOF
}

@test "profile_load exports SITE_A_ALIAS from a valid profile file" {
  profile_load demo
  [ "$SITE_A_ALIAS" = "a" ]
}

@test "profile_load rejects a profile file containing anything but assignments" {
  cat > "$SITEGRAFT_PROFILES_DIR/evil.conf" <<'EOF'
SITE_A_ALIAS="a"
$(echo "this should never execute")
EOF
  run profile_load evil
  [ "$status" -eq 1 ]
}

@test "profile_load fails clearly when the profile file does not exist" {
  run profile_load does-not-exist
  [ "$status" -eq 1 ]
  [[ "$output" == *"does-not-exist"* ]]
}

@test "profile_load rejects trailing shell code after a valid-looking assignment (B2, Viktor's live payload 1)" {
  # The previous grep-based check had no end anchor: 'SITE_A_ALIAS="a"; touch
  # /tmp/PWNED' matched as a PREFIX of the allowed pattern and was accepted,
  # then the whole file was `source`d, executing the trailing command.
  local marker="$BATS_TEST_TMPDIR/PWNED"
  rm -f "$marker"
  cat > "$SITEGRAFT_PROFILES_DIR/evil2.conf" <<EOF
SITE_A_ALIAS="a"; touch "${marker}"
EOF
  run profile_load evil2
  [ "$status" -eq 1 ]
  [ ! -e "$marker" ]
}

@test "profile_load never executes a command substitution embedded in a value (B2, Viktor's live payload 2)" {
  # The previous implementation sourced the file after only a shape check;
  # a double-quoted value containing \$(...) matched that shape fine and
  # was then executed by `source`, not treated as literal text.
  #
  # Called directly rather than via bats' `run` — `run` executes in a
  # subshell, so exported-variable side effects (what this test needs to
  # inspect) never make it back to this shell regardless of correctness;
  # `run` is for capturing output/exit status, not variable state.
  local marker="$BATS_TEST_TMPDIR/PWNED2"
  rm -f "$marker"
  cat > "$SITEGRAFT_PROFILES_DIR/evil3.conf" <<EOF
SITE_A_ALIAS="\$(touch ${marker})"
SITE_A_WP_PATH="/tmp/site-a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/site-b"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-runs"
EOF
  profile_load evil3
  local load_status=$?
  [ ! -e "$marker" ]
  # The value is stored verbatim as literal text, not executed — accepted,
  # not rejected (there is nothing structurally wrong with the assignment
  # shape itself, only with the old code's decision to source it).
  [ "$load_status" -eq 0 ]
  [ "$SITE_A_ALIAS" = '$(touch '"${marker}"')' ]
}

@test "profile_load rejects a key that is not on the known SITE_*/SITEGRAFT_* whitelist" {
  cat > "$SITEGRAFT_PROFILES_DIR/unknownkey.conf" <<'EOF'
SITE_A_ALIAS="a"
RANDOM_UNRELATED_VAR="whatever"
EOF
  run profile_load unknownkey
  [ "$status" -eq 1 ]
}

@test "profile_load expands a leading \${HOME} token in a value but nothing else" {
  cat > "$SITEGRAFT_PROFILES_DIR/homeexp.conf" <<'EOF'
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/site-a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/site-b"
SITEGRAFT_STATE_DIR="${HOME}/.sitegraft/runs"
EOF
  profile_load homeexp
  [ "$SITEGRAFT_STATE_DIR" = "${HOME}/.sitegraft/runs" ]
}

@test "profile_load does not leak SITEGRAFT_CREDS_FILE from a previously loaded profile in the same shell (m10)" {
  mkdir -p "$SITEGRAFT_PROFILES_DIR"
  cat > "$SITEGRAFT_PROFILES_DIR/first.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/site-a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/site-b"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-runs"
SITEGRAFT_CREDS_FILE="$BATS_TEST_TMPDIR/first.creds"
EOF
  cat > "$SITEGRAFT_PROFILES_DIR/second.conf" <<'EOF'
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/site-a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/site-b"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-runs"
EOF
  profile_load first
  [ "$SITEGRAFT_CREDS_FILE" = "$BATS_TEST_TMPDIR/first.creds" ]
  profile_load second
  # second.conf never mentions SITEGRAFT_CREDS_FILE — it must NOT still
  # hold first's value (the leak this test guards against), it must fall
  # back to the default derived from the profile's own name.
  [ "$SITEGRAFT_CREDS_FILE" != "$BATS_TEST_TMPDIR/first.creds" ]
}

@test "profile_load refuses a group/world-readable .creds file (M4, design doc §5.2)" {
  cat > "$SITEGRAFT_PROFILES_DIR/withcreds.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/site-a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/site-b"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-runs"
SITEGRAFT_CREDS_FILE="$BATS_TEST_TMPDIR/loose.creds"
EOF
  cat > "$BATS_TEST_TMPDIR/loose.creds" <<'EOF'
SITE_A_SSH_KEY="/tmp/key"
EOF
  chmod 644 "$BATS_TEST_TMPDIR/loose.creds"
  run profile_load withcreds
  [ "$status" -eq 1 ]
}

@test "profile_load fails clearly when SITEGRAFT_STATE_DIR is missing (BLOCKER, second review round)" {
  # Verified live before this fix: a profile omitting SITEGRAFT_STATE_DIR
  # made a later "${SITEGRAFT_STATE_DIR}" dereference in phase_scan a raw
  # bash "unbound variable" crash — and because that specific error class
  # reports $?=0 to any EXIT trap on this bash version (see lib/core.sh),
  # the whole process exited 0 as if scan had succeeded, having done
  # nothing at all. profile_load must reject this itself, before any code
  # downstream ever gets a chance to dereference the missing key.
  cat > "$SITEGRAFT_PROFILES_DIR/nostatedir.conf" <<'EOF'
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/site-a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/site-b"
EOF
  run profile_load nostatedir
  [ "$status" -eq 1 ]
  [[ "$output" == *"SITEGRAFT_STATE_DIR"* ]]
}

@test "profile_load fails clearly when any other required key is missing (BLOCKER, required-keys validation)" {
  cat > "$SITEGRAFT_PROFILES_DIR/nobwppath.conf" <<'EOF'
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/site-a"
SITE_B_ALIAS="b"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-runs"
EOF
  run profile_load nobwppath
  [ "$status" -eq 1 ]
  [[ "$output" == *"SITE_B_WP_PATH"* ]]
}

@test "profile_load ignores an ambient SITEGRAFT_STATE_DIR env var not set by the profile file itself (documented decision)" {
  # Deliberate: the profile file is the sole source of truth for these
  # keys — see the comment in lib/profile.sh. An env var override is not
  # supported, on purpose, since honoring one would reopen exactly the
  # cross-profile leak risk the m10 fix (unset-before-parse) closes.
  export SITEGRAFT_STATE_DIR="/should/not/survive"
  profile_load demo
  [ "$SITEGRAFT_STATE_DIR" = "/tmp/sitegraft-runs" ]
}

@test "profile_load accepts a mode-600 .creds file" {
  cat > "$SITEGRAFT_PROFILES_DIR/goodcreds.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/site-a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/site-b"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-runs"
SITEGRAFT_CREDS_FILE="$BATS_TEST_TMPDIR/tight.creds"
EOF
  cat > "$BATS_TEST_TMPDIR/tight.creds" <<'EOF'
SITE_A_SSH_KEY="/tmp/key"
EOF
  chmod 600 "$BATS_TEST_TMPDIR/tight.creds"
  profile_load goodcreds
  [ "$SITE_A_SSH_KEY" = "/tmp/key" ]
}
