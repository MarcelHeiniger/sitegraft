#!/usr/bin/env bash
# tests/lint/no-blocking-stdin-reads.sh — repo guard against the "blocks on
# stdin instead of failing" class of bug (issue #102). Runs tests/unit/ the
# normal way, under the one condition CI's own stdin can never exercise:
# a stdin that stays open and never reaches EOF.
#
# THE BUG CLASS, AND WHY CI IS STRUCTURALLY BLIND TO IT
# -------------------------------------------------------
# This has hit the repo four times: lib/plan.sh's fzf/gum fallback prompt
# (found live), a bats stub `cat` with no argument (issue #46, a 47-minute
# hang), a `wp` stub's unconditional `cat` in tests/unit/test_backup.bats
# (found live, intermittent), and lib/backup.sh's phase_restore
# confirmation `read` (found reviewing the PR that closed #46 — and it
# also blocked a scripted `sitegraft restore` in the field, not just the
# suite). Every one was a one-off fix; nothing closed the class.
#
# GitHub Actions already runs this repo's CI with stdin at /dev/null. A
# bare `read`/`cat` with no guard hits instant EOF there and returns
# non-zero — CI reads that as "declined correctly," green. Wherever stdin
# is instead a real terminal, or a pipe that never closes (a parent shell,
# a supervised process, systemd, cron), the identical code blocks forever.
# That is the worst failure mode available: green in CI, hung for whoever
# actually hits it — and the symptom (the suite frozen at the same spot)
# reads as "the suite is broken," not "this one read is waiting on stdin."
# One real instance of this took two hours to diagnose, misdiagnosing
# cleanup processes as the cause before finding the real one.
#
# WHY THIS IS DYNAMIC, NOT A TEXT-PATTERN LINT LIKE ITS SIBLING
# -----------------------------------------------------------------
# tests/lint/no-fatal-parameter-expansion.sh is the precedent this follows
# in spirit: a class guard the CI applies on every PR. But that one is a
# single-line regex, and this bug class does not reduce to one. A grep for
# "a `read` not immediately guarded by `[ -t 0 ]`" cannot tell a dangerous
# bare `read -r -p ... ans` (fd 0, the thing this guards against) from the
# ~15 perfectly safe `while IFS= read -r x <&3; do ... done` loops already
# in lib/ (an explicit different fd, never at risk) without modeling
# control flow — which guard covers which read, whether they're even in
# the same function. Loose enough to skip that distinction and it is noise
# on real code the day it ships (CLAUDE.md: a check noisy enough to get
# disabled protects nothing); tight enough to avoid that and it is exactly
# the proximity heuristic that would have missed lib/backup.sh's
# phase_restore — which was found by running the suite under a stdin that
# never reaches EOF, not by reading the source for it. Executing the real
# interpreter under the real adversarial condition catches a blocking read
# regardless of its shape (`read`, `cat`, `mapfile`, an external tool) and
# regardless of how indirectly it's reached, which is exactly the case a
# text scan is weakest on. That is what this script does instead of a
# grep.
#
# HOW: bats' OWN per-test timeout, not an external wrapper
# -----------------------------------------------------------
# bats-core supports BATS_TEST_TIMEOUT (env var; see `bats --help`): a
# per-TEST watchdog that, on expiry, walks and kills the test's entire
# process tree (bats-exec-test's bats_kill_processes_of, via `ps`) and
# reports that one test as "not ok ... # timeout after Ns" / "failed due
# to timeout" — a message distinct from an ordinary assertion failure —
# then continues on to the rest of the suite. That is a direct answer to
# the "per file or for the whole suite?" question this guard's issue
# raises: per-file was valued for naming the culprit rather than just
# reporting "it hangs" (that is literally how phase_restore's regression
# was found — a manual sweep, file by file). Per-TEST naming does the same
# job strictly better, in ONE bats invocation covering all of tests/unit/
# rather than 44 separate process startups — it names the exact test, not
# just the file it lives in, at lower cost than either option the issue
# posed. So: this script does not loop over files or wrap `bats` in an
# external `timeout` at all. It sets BATS_TEST_TIMEOUT and runs
# `bats tests/unit/` exactly as tests/unit/'s own canonical invocation
# (CLAUDE.md) does, under a stdin engineered to never deliver EOF.
#
# The stdin itself is a FIFO this script opens read-write on its own fd:
# the open succeeds immediately (this process is both ends, so there's no
# separate writer to wait for), and any read against it blocks forever,
# because nothing ever writes to it or closes it. One fd; no helper
# process to manage or clean up.
#
# WHY BATS_TIMEOUT_SECS IS WHAT IT IS
# --------------------------------------
# Measured locally (Apple Silicon) with `bats -T` (per-test timing) across
# a 7-file, 442-test sample that includes the suite's two heaviest files —
# tests/unit/test_backup.bats (112 tests; real gzip/checksum/file-tree
# I/O) and tests/unit/test_verify.bats (163 tests) — the single slowest
# test anywhere in that sample took 888ms. BATS_TIMEOUT_SECS=30 is a >30x
# margin over that measurement: room for a GitHub-hosted runner being
# slower than this machine for fork-heavy bash (each bats test forks
# several subprocesses — jq, gzip, rsync, wp stubs) and for a shared,
# noisy-neighbor runner, while still capping a genuine hang at 30 seconds
# instead of the 47-minute and 2-hour real incidents issue #102 cites.
# Deliberately generous rather than tight, on purpose: a cap so tight it
# trips on a legitimately slow test gets disabled, and the class comes
# back with everyone's blessing (CLAUDE.md's own warning, and this
# guard's issue repeats it explicitly).
#
# This script's own exit status is bats' exit status, unmodified: it does
# not try to tell a timed-out test apart from an ordinary assertion
# failure and suppress the latter — bats' output already does that
# distinction (the " # timeout after Ns" / "failed due to timeout" text
# above), and either kind of failure is real and should fail CI.
#
# Usage: no-blocking-stdin-reads.sh [root]   (default: the repo root)
# Runs tests/unit/ under $root. Exits whatever `bats` exits: 0 clean,
# non-zero on any failing or timed-out test. Exits 2 if tests/unit/ is
# missing, or if bats itself isn't on PATH — a broken setup, not a pass.

set -uo pipefail

BATS_TIMEOUT_SECS="${BATS_TIMEOUT_SECS:-30}"

root="${1:-}"
if [ -z "$root" ]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

unit_dir="$root/tests/unit"
if [ ! -d "$unit_dir" ]; then
  printf 'no-blocking-stdin-reads: not a directory: %s\n' "$unit_dir" >&2
  exit 2
fi

if ! command -v bats >/dev/null 2>&1; then
  printf 'no-blocking-stdin-reads: bats not found on PATH\n' >&2
  exit 2
fi

# BATS_TEST_TIMEOUT (this guard's whole mechanism) was added in bats-core
# 1.8.0. Silently running without it would not fail loudly -- it would
# just apply no timeout at all, so a real hang would sail past this job
# and only get caught (uninformatively) by the job's own 20-minute
# ceiling. CI's own bats comes from `apt-get install bats` on ubuntu-latest
# (Ubuntu 24.04 as of this writing: bats 1.10.0-1, well past 1.8.0), but a
# contributor could be running this locally on an older box -- refuse
# outright rather than report a pass this version cannot back up.
bats_version="$(bats --version 2>/dev/null | awk '{print $2}')"
bats_major="${bats_version%%.*}"
bats_minor="${bats_version#*.}"
bats_minor="${bats_minor%%.*}"
if [ -z "$bats_major" ] || [ -z "$bats_minor" ]; then
  printf 'no-blocking-stdin-reads: could not parse `bats --version` output (%s)\n' "$(bats --version 2>&1)" >&2
  exit 2
fi
if [ "$bats_major" -lt 1 ] || { [ "$bats_major" -eq 1 ] && [ "$bats_minor" -lt 8 ]; }; then
  printf 'no-blocking-stdin-reads: bats %s.%s predates 1.8.0 -- BATS_TEST_TIMEOUT is not supported, so this guard would provide no real protection\n' \
    "$bats_major" "$bats_minor" >&2
  exit 2
fi

# A FIFO this process opens read-write on its own fd 9: the open succeeds
# immediately (no writer to wait for — we are the writer, via the same
# fd), and every read against it blocks forever, since nothing, ever,
# writes to it or closes it. Unlinked right after opening — the fd stays
# valid, nothing else needs the path.
fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/no-blocking-stdin-reads.XXXXXX")"
fifo="$fifo_dir/never-eof"
mkfifo "$fifo"
exec 9<>"$fifo"
rm -rf "$fifo_dir"
trap 'exec 9<&- 2>/dev/null || true' EXIT

printf 'no-blocking-stdin-reads: running %s under a stdin that never reaches EOF (BATS_TEST_TIMEOUT=%ss)\n' \
  "$unit_dir" "$BATS_TIMEOUT_SECS" >&2

BATS_TEST_TIMEOUT="$BATS_TIMEOUT_SECS" bats "$unit_dir" 0<&9
