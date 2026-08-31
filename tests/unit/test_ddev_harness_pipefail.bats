# tests/unit/test_ddev_harness_pipefail.bats — regression coverage for
# PR #49's fix (issue #42's underlying defect, already eliminated in
# tests/integration/ddev-harness.sh before this test existed -- see #42's
# closing comment). Proves the capture-first-match-after shape #49 put in
# place for every assertion against `wp`/`ddev exec` output actually avoids
# the SIGPIPE-under-pipefail trap the old `producer | grep -q` shape falls
# into, and that the fixed form still fails correctly on a genuine
# non-match. #49 shipped with only manual, anecdotal measurement (25/25
# failures for the old form, by hand against a disposable DDEV project) --
# this gives that fix a permanent, automated guard against regressing back
# to the old shape.
#
# ddev-harness.sh itself has no functions to load and unit-test — it is a
# top-level script that spins up real DDEV projects, out of reach here — so
# this reproduces the exact bash construct in isolation instead: a producer
# that writes a matching line and then, after a short delay, more output
# (standing in for `wp post list`'s own post-match writes/teardown), piped
# under a top-level `set -o pipefail`, exactly like bin/sitegraft's own
# `set -euo pipefail` that the harness runs under. `grep -q` exits the
# instant it matches, well before the delayed write — the same race PR #49
# measured at 25/25 failures for the old form and 0/25 for the new one.
# NOTE: this test's `printf '%s' "$out" | grep -q` is representative of,
# not byte-identical to, every one of #49's actual call sites -- some of
# those use a here-string (`grep -q PATTERN <<< "$var"`) instead. Both
# consume an already-fully-materialized string with no live producer left
# to SIGPIPE, so the mechanism proven here applies identically to either
# syntax; this test exercises the general shape, not a specific line.
setup() {
  PRODUCER="$BATS_TEST_TMPDIR/producer.sh"
  cat > "$PRODUCER" <<'STUB'
#!/usr/bin/env bash
printf 'Hero CFS\n'
sleep 0.3
printf 'more output written after the match, standing in for a still-writing wp/ddev exec\n'
STUB
  chmod +x "$PRODUCER"
}

@test "OLD form (producer | grep -q) reports failure under pipefail even though the pattern matched" {
  run bash -c 'set -o pipefail; "$1" | grep -q "Hero CFS"' _ "$PRODUCER"
  [ "$status" -ne 0 ]
}

@test "NEW form (capture first, match after) succeeds on the same producer/pattern that breaks the old form" {
  run bash -c 'set -o pipefail; out=$("$1"); printf "%s" "$out" | grep -q "Hero CFS"' _ "$PRODUCER"
  [ "$status" -eq 0 ]
}

@test "NEW form still fails when the pattern is genuinely absent — no assertion was weakened by the fix" {
  run bash -c 'set -o pipefail; out=$("$1"); printf "%s" "$out" | grep -q "NOT PRESENT IN OUTPUT"' _ "$PRODUCER"
  [ "$status" -ne 0 ]
}

@test "NEW form's captured output is available to a failing assertion's message, unlike the old form" {
  run bash -c 'set -o pipefail; out=$("$1"); printf "%s" "$out"' _ "$PRODUCER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hero CFS"* ]]
}
