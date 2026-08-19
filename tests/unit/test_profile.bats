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
