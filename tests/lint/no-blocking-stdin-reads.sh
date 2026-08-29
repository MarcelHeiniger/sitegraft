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
# in spirit: a class guard the CI applies on every PR. This is not a
# rejection of a static check in general — a targeted one turns out to work
# here too; see SCOPE below — but that regex is not a substitute for
# actually executing the suite: a static check only sees a call site's
# TEXT, never whether it is actually reachable with real stdin behind it,
# and this bug class is precisely about a code path that no test happened
# to exercise under the right condition (lib/backup.sh's phase_restore was
# found this way: by running the suite under a stdin that never reaches
# EOF, not by reading the source for it). Executing the real interpreter
# under the real adversarial condition catches a blocking read regardless
# of its shape (`read`, `cat`, `mapfile`, an external tool) PROVIDED some
# test actually drives that code path with the process's own inherited
# stdin — which is also this guard's real limit; see SCOPE.
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
# process to manage or clean up. `mkfifo` and the fd it produces are both
# checked below (not assumed) — see the setup code's own comment for why.
#
# SCOPE — what this guard does NOT see, and a live 5th occurrence
# -----------------------------------------------------------------
# BATS_TEST_TIMEOUT protects a TEST, not a code path. Two real gaps follow
# directly from that, neither one this guard can close by itself:
#
#   1. A test that supplies its OWN stdin (a heredoc, a here-string, an
#      explicit redirect) never touches this script's never-EOF FIFO —
#      it's immunized by construction. A well-written test of a
#      confirmation prompt does exactly this (feeds `<<< "y"` or similar)
#      precisely so the test is deterministic, which is correct test
#      hygiene and simultaneously means this guard cannot see whether the
#      PRODUCTION code underneath has a `[ -t 0 ]` guard or not.
#   2. tests/integration/ does not run in CI at all (see the unit-tests
#      job's own comment in .github/workflows/ci.yml) — anything only
#      reachable through that harness is invisible to every job here,
#      this one included.
#
# Both gaps are real today, not hypothetical: lib/plan.sh's _plan_confirm
# (line ~457), _plan_confirm_strong (line ~473), and the plain-prompt
# fallback in _plan_prompt_items (line ~550) are three bare `read -r -p`
# calls with NO `[ -t 0 ]` guard anywhere in the file — the exact shape of
# issue #102's occurrence #4 (phase_restore), in the SAME FILE as
# occurrence #1 the issue names (lib/plan.sh's fd0-contention bug at
# line ~507, already fixed, comment in place: "MAJOR bug fixed here,
# found live"). These three are a distinct, residual defect in that file,
# not occurrence #1 itself — occurrence #1 is fixed. They are reachable
# in production via plan_resolve_stack: a `sitegraft plan` invoked from a
# pipe or a supervisor, without gum on PATH, blocks forever the same way
# phase_restore used to. This job is GREEN on that code today, because
# every test that reaches these functions feeds them an answer on a
# private stdin. Confirmed by direct execution against this guard's own
# never-EOF FIFO, outside any test: _plan_confirm blocks indefinitely.
#
# This PR does not fix those three call sites — tracked separately as
# issue #103. Do not read this guard, or issue #102, as closed by this
# script alone: it closes the CI-blindness half of the problem (a fixed
# occurrence now has a regression test that actually proves something),
# it does not retroactively prove the four historical occurrences are
# ALL covered by a passing run today, and #103's occurrences are a
# concrete, live counterexample to that stronger claim.
#
# A discriminant that WOULD have caught #103's occurrences statically,
# for the record (and a possible future complement to this dynamic guard,
# not a replacement for it — see above): `read ... -p ...` is always a
# prompt to a human, never a data read — none of the ~15 legitimate
# `while IFS= read -r x <&3; do ... done` loops in lib/ use `-p`, because
# they're not prompting anyone. Across this repo, `grep -rn 'read -r\? -p'
# lib/*.sh bin/sitegraft modules/*.sh` returns 7 raw hits — run it and
# check, rather than trust this comment — 2 of which are comment lines
# that quote the pattern while discussing it (lib/backup.sh:1915,
# lib/plan.sh:514), not call sites. The other 5 ARE the call sites: 2
# already `[ -t 0 ]`-guarded (lib/backup.sh's phase_restore, lib/graft.sh's
# graft_check_stack_mismatch) and the 3 unguarded ones above — zero false
# positives among actual code, unlike a bare-`read` scan, which would also
# flag the fd3 loops. "Not *this* static lint" (a `[ -t 0 ]`-proximity scan, too
# context-sensitive to do reliably) is not the same claim as "no static
# lint could ever help here" — a `grep -c 'read -r\? -p' | grep -v
# '\[ -t 0 \]'`-style check on `-p` specifically is narrow enough to be
# close to a one-line rule, and a further structural option exists: route
# every operator prompt through one shared helper (this file already has
# _plan_confirm/_plan_confirm_strong as a start) and lint "no `read -p`
# outside that helper." Not built here — left for #103 or a follow-up,
# since this PR's job is the dynamic guard, not that helper's design.
#
# WHY BATS_TIMEOUT_SECS IS WHAT IT IS
# --------------------------------------
# This was originally set from a 442-test PARTIAL sample (7 of 44 files,
# picked by test COUNT, not by measurement) that put the slowest single
# test at 888ms and set the cap at 30s. That was wrong: measuring the
# FULL 988-test suite with `bats -T` under this exact never-EOF harness
# found tests nowhere in that sample running far longer —
# tests/unit/test_verify_content_remap_cli.bats:172 (a 62MB WXR-generation
# scenario: PHP streaming the XML, ~1000 lines through jq — I/O- and
# fork-heavy, so exactly the kind of test whose wall-clock time swings
# hardest with the runner) measured 20.67s, reproduced at 20.51s / 20.64s
# / 20.70s across three more runs; tests/unit/test_bin_sitegraft.bats:158
# and :166 measured 7.16s and 6.76s. Against a 30s cap, the slowest real
# test was already within ~1.45x of tripping the guard on an unlucky
# runner — CI's own runs of this exact suite recorded a 25% difference
# between two concurrent jobs (129s vs. 161s for the same commit, same
# workflow run). A cap that close to a real, legitimate test is exactly
# the failure mode this file's own header warns about elsewhere: tight
# enough to trip on a slow-but-not-hung test gets the whole guard
# disabled, and the class comes back with everyone's blessing.
#
# BATS_TIMEOUT_SECS=120 is a ~6x margin over the measured 20.7s worst
# case, while still capping a genuine hang at 2 minutes rather than the
# 47-minute and 2-hour real incidents issue #102 cites. Worth noting for
# anyone tempted to explain the variance away as "GitHub's runners are
# slower than a real machine": they measurably are not, here — 129s on
# the runner against 173s measured locally for the same never-EOF run.
# The margin is deliberately generous anyway, because the thing that
# actually swings this suite's wall-clock time is I/O and fork load on a
# shared runner, not raw CPU — and that is exactly the axis a single local
# measurement, however careful, cannot fully see in advance.
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
# missing, if bats itself isn't on PATH or is too old, or if the FIFO
# setup fails — a broken setup, not a pass.

set -uo pipefail

# BATS_TIMEOUT_SECS is the public override knob (env var of this exact
# name). Captured into a plain, non-BATS_-prefixed variable immediately;
# used as $timeout_secs from here on.
BATS_TIMEOUT_SECS="${BATS_TIMEOUT_SECS:-120}"
timeout_secs="$BATS_TIMEOUT_SECS"

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
# and only get caught (uninformatively) by the job's own timeout-minutes
# ceiling. CI's own bats comes from `apt-get install bats` on ubuntu-latest
# (Ubuntu 24.04 as of this writing: bats 1.10.0-1, well past 1.8.0), but a
# contributor could be running this locally on an older box -- refuse
# outright rather than report a pass this version cannot back up.
#
# The version regex check matters: `${var%%.*}`/`${var#*.}` on a
# non-numeric or malformed string (a `v` prefix, a missing minor
# component, a completely unparseable `--version` line from some future
# bats fork) does NOT fail -- it just produces a non-numeric string, which
# would make the `-lt`/`-eq` integer comparisons below either error out
# past this check (uncaught) or, worse, silently mis-evaluate. Fail
# closed on anything that doesn't look like two non-negative integers,
# rather than let a bad parse fall through as an unproven pass.
bats_version="$(bats --version 2>/dev/null | awk '{print $2}')"
bats_major="${bats_version%%.*}"
bats_minor="${bats_version#*.}"
bats_minor="${bats_minor%%.*}"
if ! [[ "$bats_major" =~ ^[0-9]+$ ]] || ! [[ "$bats_minor" =~ ^[0-9]+$ ]]; then
  printf 'no-blocking-stdin-reads: could not parse `bats --version` output (%s) as major.minor\n' "$(bats --version 2>&1)" >&2
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
#
# Both `mkfifo` and the resulting node are checked, not assumed. Without
# this, a failed `mkfifo` (permissions, a restrictive /tmp, some sandboxed
# CI runner) leaves $fifo simply not existing; `exec 9<>"$fifo"` under
# `set -uo pipefail` (no `-e`) does NOT stop the script for that -- bash's
# `<>` on a nonexistent path CREATES a plain regular file instead of
# failing, silently swapping this guard's entire mechanism for a stdin
# that reaches instant EOF, i.e. exactly CI's normal /dev/null-like
# condition this script exists to get away from. The suite would then run
# green under a stdin indistinguishable from the condition that let all
# four historical occurrences ship. This file's own version check above
# says, in comments, "refuse outright rather than report a pass this
# version cannot back up" -- the same standard applies to its own FIFO.
fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/no-blocking-stdin-reads.XXXXXX")" || {
  printf 'no-blocking-stdin-reads: mktemp -d failed\n' >&2
  exit 2
}
fifo="$fifo_dir/never-eof"
if ! mkfifo "$fifo"; then
  printf 'no-blocking-stdin-reads: mkfifo failed for %s -- refusing to fall back to a plain file, which would silently give instant-EOF stdin instead of never-EOF\n' "$fifo" >&2
  rm -rf "$fifo_dir"
  exit 2
fi
if [ ! -p "$fifo" ]; then
  printf 'no-blocking-stdin-reads: %s exists but is not a FIFO -- refusing to trust it as a never-EOF stdin\n' "$fifo" >&2
  rm -rf "$fifo_dir"
  exit 2
fi
exec 9<>"$fifo"
rm -rf "$fifo_dir"
trap 'exec 9<&- 2>/dev/null || true' EXIT

printf 'no-blocking-stdin-reads: running %s under a stdin that never reaches EOF (BATS_TEST_TIMEOUT=%ss)\n' \
  "$unit_dir" "$timeout_secs" >&2

# A previous revision of this script blanket-cleared every BATS_*-named
# variable here (`unset "${!BATS_@}"`), on the theory that inherited
# per-test bookkeeping from an outer bats process (this script IS invoked
# from inside one: tests/unit/test_no_blocking_stdin_reads.bats, to test
# THIS script) could corrupt a nested `bats` invocation. Measured, that
# theory was both wrong about the real corruption's cause (the actual
# cause -- bats 1.10.0's heredoc-blind preprocessor -- is documented in
# that test file's own header) AND actively broke this exact nested
# invocation on Homebrew's bats (1.14.0, this repo's other dev machine):
# a bats test's PATH has bats' own libexec dir prepended ahead of the
# installed shim, so a bare `bats` lookup from inside a test resolves
# DIRECTLY to the internal, non-self-locating
# .../libexec/bats-core/bats script -- which does not compute BATS_ROOT/
# BATS_LIBDIR itself (only the shim at e.g. /opt/homebrew/bin/bats does,
# via its own `${BASH_SOURCE[0]}` resolution, on every invocation) and
# simply trusts them to already be set. Confirmed live: with the blanket
# unset in place, that produces `//bats-core/validator.bash: No such
# file or directory` and the nested run fails outright; without it, the
# outer bats process's own correctly-computed BATS_ROOT/BATS_LIBDIR are
# already present in the inherited environment and the internal script
# uses them correctly. No unset here at all, on either platform: not
# needed (proven on ubuntu-latest/bats 1.10.0 -- the real corruption
# there was fixed elsewhere, not by this), and actively wrong on
# Homebrew/bats 1.14.0. This paragraph exists so a future "let's harden
# this by clearing the environment" instinct checks this measurement
# first rather than reintroducing the same breakage.

# `9<&-` after `0<&9`: fd 9 has done its job once duplicated onto fd 0 for
# bats' own stdin; leaving it open past that point would leak it into bats
# and every test process it forks. Harmless in practice (nothing reads fd
# 9 by that number), but free to close and more honest about what this
# process actually needs.
BATS_TEST_TIMEOUT="$timeout_secs" bats "$unit_dir" 0<&9 9<&-
