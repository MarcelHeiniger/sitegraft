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
#
# Two things this file got wrong on its first pass, both caught by a real
# ubuntu-latest CI run and NOT by local runs on this repo's dev Mac -- the
# exact "validated where we test, broken where it runs" failure mode this
# whole guard exists to close, turned against its own test suite. Fixed
# here, and the mechanism kept:
#
#   1. The two fixtures below used to be heredocs, with their `@test`
#      line sitting at column 0 of THIS file. bats-core 1.10.0 (Ubuntu
#      24.04's `apt-get install bats`, i.e. CI's actual floor) mistakes
#      that for a real test declared in THIS file's own source and adds
#      it to this file's plan; bats-core 1.14.0 (Homebrew, this repo's
#      dev Mac) does not -- upstream fixed the preprocessor between the
#      two. Confirmed directly: `bats --count` on this file was 9 on
#      1.10.0 with heredocs (7 real + 2 phantom) and 7 on 1.14.0. The 2
#      phantom tests then failed to resolve ("bats: unknown test name"),
#      corrupting the TAP stream the two affected tests here parse via
#      $output, and the suite total came up short elsewhere in
#      tests/unit/ by exactly 2 ("Executed 995 instead of expected 997
#      tests"). Fixed by write_fixture_bats() below, which builds each
#      fixture via `printf` -- no line of THIS file's own source starts
#      with `@test` for any bats version to misparse. Verified on a real
#      ubuntu:24.04 container running bats 1.10.0: count back to 7, all
#      green.
#   2. "guard exits 2 when bats is not on PATH" assumed bats lives
#      somewhere under Homebrew, so excluding /opt/homebrew/bin (by using
#      only /usr/bin:/bin) proved absence -- true on this Mac, false on
#      ubuntu-latest, where `apt-get install bats` puts the real binary
#      at /usr/bin/bats, i.e. inside the very directory the test was
#      using to prove bats missing. Fixed by giving the child process an
#      EMPTY PATH instead of guessing which real directory to exclude,
#      while invoking bash by its own absolute path (not looked up
#      through that empty PATH, which would just fail the invocation
#      itself rather than testing the guard).

setup() {
  GUARD="${BATS_TEST_DIRNAME}/../lint/no-blocking-stdin-reads.sh"
  FAKES="$BATS_TEST_TMPDIR/fakes"
  mkdir -p "$FAKES"
}

# Writes a single-test .bats fixture at <path>, test description <name>,
# test body <body> -- via `printf`, deliberately not a heredoc. See this
# file's own header for why: a heredoc's `@test "..." {` line sits at
# column 0 of THIS SOURCE FILE, which bats-core 1.10.0 (CI's floor)
# mistakes for a real test of this file. `printf`'s format string has
# "@test" embedded mid-line inside a quoted argument, never as the start
# of a line in this file's actual source, so no bats version can misread
# it as a declaration here.
write_fixture_bats() {
  local path="$1" name="$2" body="$3"
  printf '@test "%s" {\n%s\n}\n' "$name" "$body" > "$path"
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
  # An EMPTY PATH, not a guess at which real directory to exclude -- see
  # this file's own header for why the previous version (excluding
  # /usr/bin:/bin, true only on a Homebrew Mac) was wrong on ubuntu-latest.
  # `env`'s own lookup of the command to run also consults PATH, so `bash`
  # must be given by absolute path here (`/bin/bash`, present on both
  # ubuntu-latest and macOS) -- otherwise `env` itself fails to find
  # `bash` (exit 127) before the guard script ever runs, which would look
  # like a pass for entirely the wrong reason.
  run env -i PATH="" /bin/bash "$GUARD" "$root"
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
  write_fixture_bats "$root/tests/unit/trivial.bats" "arithmetic still works" \
    '  [ $((1 + 1)) -eq 2 ]'
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
  write_fixture_bats "$root/tests/unit/hangs.bats" "a bare read blocks on inherited stdin" \
    '  local ans
  read -r ans
  echo "unreachable: got ${ans:-<empty>}"'

  # Outer bound on top of the guard's own BATS_TEST_TIMEOUT=3s: this test
  # exists specifically to prove the watchdog fires, so if the watchdog
  # ITSELF were ever broken (measured: removing bats-exec-test's countdown
  # entirely makes this exact test hang indefinitely instead of failing --
  # a near-unreachable trigger, since this guard's own version check
  # refuses to run at all without BATS_TEST_TIMEOUT support, but the test
  # OF the anti-hang guard hanging, inside tests/unit/, is exactly the
  # failure this repo can't afford to reintroduce anywhere). `timeout` is
  # GNU coreutils, present on ubuntu-latest (CI) unconditionally; skip the
  # extra bound where it's absent (e.g. a bare macOS dev machine) rather
  # than fail the test over a missing coreutil unrelated to what it
  # verifies -- the guard's own BATS_TEST_TIMEOUT is still the real
  # mechanism under test either way.
  if command -v timeout >/dev/null 2>&1; then
    run timeout 15 env BATS_TIMEOUT_SECS=3 bash "$GUARD" "$root"
  else
    run env BATS_TIMEOUT_SECS=3 bash "$GUARD" "$root"
  fi
  [ "$status" -ne 0 ]
  [ "$status" -ne 124 ]
  [[ "$output" == *"timeout after 3s"* ]] || false
  [[ "$output" == *"failed due to timeout"* ]] || false
}
