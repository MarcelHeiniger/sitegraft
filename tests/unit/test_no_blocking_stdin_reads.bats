# tests/unit/test_no_blocking_stdin_reads.bats
#
# Tests for tests/lint/no-blocking-stdin-reads.sh -- the dynamic CI guard
# against stdin-hang regressions (issue #102). That script's own header
# carries the reasoning for why it's a dynamic run rather than a text
# scan, and the SCOPE section of what it does not yet see. This file
# proves its own machinery -- the setup failures, and that the hang
# detection itself actually fires -- fails closed rather than silently
# reporting a pass it can't back up (CLAUDE.md: "Prove the check can
# fail. A test that only asserts 'it ran' ratifies a check that always
# passes.").
#
# The hang-detection test below uses a short BATS_TIMEOUT_SECS override,
# not the shipped 120s default -- this file needs to stay fast, like the
# rest of tests/unit/. The 120s default itself, and the proof against the
# real historical phase_restore regression at that timeout, are in the
# guard script's own header comment and this PR's description, not here
# (reproducing that would make this file itself the kind of multi-minute
# test this guard exists to keep out of the normal suite).

setup() {
  GUARD="${BATS_TEST_DIRNAME}/../lint/no-blocking-stdin-reads.sh"
  FAKES="$BATS_TEST_TMPDIR/fakes"
  mkdir -p "$FAKES"
}

# --- setup failures must fail closed (exit 2), never report a pass ---------

@test "guard exits 2 when tests/unit is missing under the given root" {
  local root="$BATS_TEST_TMPDIR/empty-root"
  mkdir -p "$root"
  run bash "$GUARD" "$root"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a directory"* ]] || false
}

@test "guard exits 2 when bats is not on PATH" {
  local root="$BATS_TEST_TMPDIR/root-no-bats"
  mkdir -p "$root/tests/unit"
  # A PATH with no bats on it (this repo's bats is homebrew-installed, not
  # in /usr/bin or /bin), but real enough for the script's own coreutils.
  run env PATH="/usr/bin:/bin" bash "$GUARD" "$root"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bats not found"* ]] || false
}

@test "guard exits 2 on an unparseable bats --version string, not a silent skip of the version check" {
  cat > "$FAKES/bats" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "Bats v1.7.0"; exit 0; }
exit 99
EOF
  chmod +x "$FAKES/bats"
  local root="$BATS_TEST_TMPDIR/root-bad-version"
  mkdir -p "$root/tests/unit"
  run env PATH="$FAKES:$PATH" bash "$GUARD" "$root"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not parse"* ]] || false
}

@test "guard exits 2 on a bats version older than 1.8.0 (BATS_TEST_TIMEOUT unsupported)" {
  cat > "$FAKES/bats" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "Bats 1.7.0"; exit 0; }
exit 99
EOF
  chmod +x "$FAKES/bats"
  local root="$BATS_TEST_TMPDIR/root-old-version"
  mkdir -p "$root/tests/unit"
  run env PATH="$FAKES:$PATH" bash "$GUARD" "$root"
  [ "$status" -eq 2 ]
  [[ "$output" == *"predates 1.8.0"* ]] || false
}

@test "guard exits 2, not a silent instant-EOF pass, when mkfifo fails" {
  # Regression this guards against: bash's `<>` on a path that doesn't
  # exist creates a PLAIN FILE instead of failing -- if mkfifo's own
  # failure were left unchecked, this guard would silently swap its
  # never-EOF stdin for one that hits instant EOF, i.e. CI's own
  # /dev/null-like condition, and report a clean pass on a suite it never
  # actually tested under the adversarial stdin.
  cat > "$FAKES/mkfifo" <<'EOF'
#!/usr/bin/env bash
echo "mkfifo: Operation not permitted (simulated)" >&2
exit 1
EOF
  chmod +x "$FAKES/mkfifo"
  local root="$BATS_TEST_TMPDIR/root-no-mkfifo"
  mkdir -p "$root/tests/unit"
  run env PATH="$FAKES:$PATH" bash "$GUARD" "$root"
  [ "$status" -eq 2 ]
  [[ "$output" == *"mkfifo failed"* ]] || false
}

# --- the guard's actual mechanism: fast, explicit-override checks ----------

@test "guard passes cleanly on a trivial suite that behaves" {
  local root="$BATS_TEST_TMPDIR/happy-root"
  mkdir -p "$root/tests/unit"
  cat > "$root/tests/unit/trivial.bats" <<'EOF'
@test "arithmetic still works" {
  [ $((1 + 1)) -eq 2 ]
}
EOF
  run env BATS_TIMEOUT_SECS=5 bash "$GUARD" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1"* ]] || false
}

@test "guard actually catches a hung test -- proves the check can fail, not just that it ran" {
  # A bare `read` against inherited stdin: the same shape as the real
  # historical regressions (phase_restore, and lib/plan.sh's still-open
  # ones under issue #103), planted in a throwaway fixture. Uses a short
  # BATS_TIMEOUT_SECS override, not the shipped 120s default, so this
  # file stays fast -- the 120s default is proven separately (this
  # script's own header, and this PR's description) against the real
  # phase_restore regression at full scale.
  local root="$BATS_TEST_TMPDIR/hang-root"
  mkdir -p "$root/tests/unit"
  cat > "$root/tests/unit/hangs.bats" <<'EOF'
@test "a bare read blocks on inherited stdin" {
  local ans
  read -r ans
  echo "unreachable: got ${ans:-<empty>}"
}
EOF
  run env BATS_TIMEOUT_SECS=3 bash "$GUARD" "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"timeout after 3s"* ]] || false
  [[ "$output" == *"failed due to timeout"* ]] || false
}
