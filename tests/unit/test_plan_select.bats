# tests/unit/test_plan_select.bats — the testable half of interactive
# selection (Task 2.3): _plan_apply_selection, split out of
# plan_select_interactive specifically so the JSON-rewrite logic isn't
# shipped only "manually QA'd" the way the prompting half genuinely has to
# be (no TTY / no gum in CI).
bats_require_minimum_version 1.5.0

setup() {
  load '../../lib/core.sh'
  load '../../lib/manifest.sh'
  load '../../lib/plan.sh'
}

@test "_plan_apply_selection keeps only the selected post_types and option_keys" {
  local manifest='{"migrate":{"etch":{"post_types":["etch_cfs","etch_cpts"],"option_keys":["etch_settings","etch_styles"]}}}'
  local kept="etch: etch_cfs
etch: etch_settings"
  run _plan_apply_selection "$manifest" "$kept"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.etch.post_types == ["etch_cfs"]' >/dev/null
  echo "$output" | jq -e '.migrate.etch.option_keys == ["etch_settings"]' >/dev/null
}

@test "_plan_apply_selection empties a module's lists when nothing of its was kept" {
  local manifest='{"migrate":{"etch":{"post_types":["etch_cfs"],"option_keys":["etch_settings"]},"acss":{"post_types":[],"option_keys":["automatic_css_settings"]}}}'
  local kept="acss: automatic_css_settings"
  run _plan_apply_selection "$manifest" "$kept"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.etch.post_types == []' >/dev/null
  echo "$output" | jq -e '.migrate.etch.option_keys == []' >/dev/null
  echo "$output" | jq -e '.migrate.acss.option_keys == ["automatic_css_settings"]' >/dev/null
}

@test "_plan_apply_selection survives under set -euo pipefail when a module's kept list is empty (nit found live: grep-no-match + pipefail aborted the whole function before the || true guard)" {
  # bats does NOT itself run test bodies under pipefail, so the test above
  # alone would never have caught this — bin/sitegraft (the real caller)
  # DOES run under `set -euo pipefail`, and a `grep` that matches nothing
  # inside a pipeline used to make the pipeline's own exit status non-zero
  # (pipefail), aborting the assignment mid-loop for the very common case of
  # an operator fully deselecting one module in the plan prompt. Runs the
  # real function in a subshell with pipefail explicitly on to reproduce
  # that exact caller environment.
  local manifest='{"migrate":{"etch":{"post_types":["etch_cfs"],"option_keys":["etch_settings"]},"acss":{"post_types":[],"option_keys":["automatic_css_settings"]}}}'
  local kept="acss: automatic_css_settings"
  run --separate-stderr bash -c '
    set -euo pipefail
    source lib/core.sh; source lib/plan.sh
    _plan_apply_selection "$1" "$2"
  ' _ "$manifest" "$kept"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.migrate.etch.post_types == [] and .migrate.etch.option_keys == []' >/dev/null
}

@test "_plan_apply_selection leaves other modules' selections untouched by one module's kept list" {
  local manifest='{"migrate":{"etch":{"post_types":["etch_cfs"],"option_keys":[]},"core_wp":{"post_types":["page","post"],"option_keys":[]}}}'
  local kept="etch: etch_cfs
core_wp: page"
  run _plan_apply_selection "$manifest" "$kept"
  echo "$output" | jq -e '.migrate.etch.post_types == ["etch_cfs"]' >/dev/null
  echo "$output" | jq -e '.migrate.core_wp.post_types == ["page"]' >/dev/null
}

@test "_plan_apply_selection with an empty kept list empties every migrate module" {
  local manifest='{"migrate":{"etch":{"post_types":["etch_cfs"],"option_keys":["etch_settings"]}}}'
  run _plan_apply_selection "$manifest" ""
  echo "$output" | jq -e '.migrate.etch.post_types == []' >/dev/null
  echo "$output" | jq -e '.migrate.etch.option_keys == []' >/dev/null
}

# --- _plan_freeze_summary: recommended addition (Viktor's review of PR #2)
# — the freeze confirmation must show the ACTUAL items an operator selected,
# not just module names, so a broken selection doesn't sail through
# unnoticed.
@test "_plan_freeze_summary lists the actual post_types/option_keys/tables per module, not just module keys" {
  local manifest='{"migrate":{"etch":{"post_types":["etch_cfs","etch_cpts"],"option_keys":["etch_settings"]}},"protect":{"fakebooking":{"post_types":["fake_reservation"],"tables":["fakebooking_reservations"],"option_keys":["fakebooking_settings"]},"_unclaimed":{"post_types":["mystery_cpt"],"tables":[],"option_keys":[]}}}'
  run _plan_freeze_summary "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"etch: etch_cfs, etch_cpts, etch_settings"* ]] || false
  [[ "$output" == *"fakebooking: fake_reservation, fakebooking_reservations, fakebooking_settings"* ]] || false
  [[ "$output" == *"_unclaimed: mystery_cpt"* ]] || false
}

@test "_plan_freeze_summary shows a module with nothing selected explicitly, not silently" {
  local manifest='{"migrate":{"acss":{"post_types":[],"option_keys":[]}},"protect":{}}'
  run _plan_freeze_summary "$manifest"
  [[ "$output" == *"acss: (nothing selected)"* ]] || false
}

@test "_plan_freeze_summary truncates a long item list (e.g. a real-world _unclaimed.option_keys) instead of printing an unreadable wall of text" {
  local many; many=$(jq -n -c '[range(30) | "opt_\(.)"]')
  local manifest; manifest=$(jq -n --argjson opts "$many" '{migrate:{},protect:{_unclaimed:{post_types:[],tables:[],option_keys:$opts}}}')
  run _plan_freeze_summary "$manifest"
  [[ "$output" == *"opt_0"* ]] || false
  [[ "$output" == *"opt_14"* ]] || false
  [[ "$output" == *"... and 15 more"* ]] || false
  [[ "$output" != *"opt_29"* ]] || false
}

@test "plan_select_interactive is a no-op passthrough when migrate is empty" {
  local manifest='{"migrate":{},"protect":{}}'
  run plan_select_interactive "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "$manifest" ]
}

# --- _plan_confirm_plain / _plan_confirm_strong_plain: the bare-`read`
# logic split out of _plan_confirm/_plan_confirm_strong (issue #103) so it
# stays exercisable without a TTY. Feeds input via a heredoc <<< so `read`
# doesn't block. Called directly (not through _plan_confirm/
# _plan_confirm_strong) precisely so these tests bypass those functions'
# own [ -t 0 ] guard, which would otherwise refuse before any of this ever
# ran, since a heredoc is not a TTY either — see
# "_plan_confirm/_plan_confirm_strong/_plan_prompt_items refuse instead of
# blocking" below for what proves the GUARDED entry points themselves.
# PATH is pinned to /usr/bin:/bin (excludes /opt/homebrew/bin) purely to
# keep these deterministic regardless of what's installed locally — found
# live in this fix-pack: these tests silently started taking the gum
# branch instead, and failed, the moment `brew install gum` (done to verify
# the MINOR gum-flag finding below) put a real gum on PATH. Relying on "gum
# happens not to be installed" was never a safe test precondition (moot for
# _plan_confirm_plain/_plan_confirm_strong_plain themselves, which never
# look for gum at all, but kept for consistency with the rest of this
# file's invocations).
@test "_plan_confirm_plain returns success when answered y" {
  run env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm_plain "ok?" <<< "y"'
  [ "$status" -eq 0 ]
}

@test "_plan_confirm_plain returns failure (safe default) when answered n" {
  run env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm_plain "ok?" <<< "n"'
  [ "$status" -eq 1 ]
}

@test "_plan_confirm_strong_plain requires the literal typed YES, not y" {
  run env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm_strong_plain "ok?" <<< "y"'
  [ "$status" -eq 1 ]
  run env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm_strong_plain "ok?" <<< "YES"'
  [ "$status" -eq 0 ]
}

# --- _plan_prompt_items_plain: the plain-fallback logic split out of
# _plan_prompt_items (issue #103), same reason as _plan_confirm_plain
# above — _plan_prompt_items's own [ -t 0 ] guard would otherwise refuse
# before any of this ran, since none of the stdin shapes below are a real
# TTY. MAJOR bug found live by Viktor's review of PR #2 and reproduced
# before that fix — `done <<< "$items"` redirected fd0 for the whole while
# loop, so the inner `read -r -p "Keep..." ans` (also defaulting to fd0)
# silently consumed the NEXT item line as its own answer instead of
# prompting. Reproduced live with 3 items and answers y/n/y: every item
# came out "kept" regardless of the typed answers. Fixed by reading items
# from fd3 (`done 3<<< "$items"`), leaving fd0 free for the interactive
# prompt. Each scenario below runs in a fresh `bash -c` subprocess (like
# the _plan_confirm_plain tests above) — items are baked into the script
# text (fd3's here-string), answers arrive on stdin (fd0), exactly
# mirroring how a real terminal session would separate "what to ask" from
# "what was typed."
@test "_plan_prompt_items_plain respects each individual y/n/y answer, not the same one for everything (MAJOR, reproduced live before the fix)" {
  run --separate-stderr env PATH=/usr/bin:/bin bash -c '
    source lib/core.sh; source lib/plan.sh
    items=$(printf "a: one\na: two\na: three")
    _plan_prompt_items_plain "$items"
  ' <<< $'y\nn\ny'
  [ "$status" -eq 0 ]
  [ "$output" = "a: one
a: three" ]
}

@test "_plan_prompt_items_plain keeps nothing when every answer is n" {
  run --separate-stderr env PATH=/usr/bin:/bin bash -c '
    source lib/core.sh; source lib/plan.sh
    items=$(printf "a: one\na: two")
    _plan_prompt_items_plain "$items"
  ' <<< $'n\nn'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_plan_prompt_items_plain defaults each item to kept on an empty answer ([Y/n])" {
  run --separate-stderr env PATH=/usr/bin:/bin bash -c '
    source lib/core.sh; source lib/plan.sh
    items=$(printf "a: one\na: two")
    _plan_prompt_items_plain "$items"
  ' <<< $'\n\n'
  [ "$status" -eq 0 ]
  [ "$output" = "a: one
a: two" ]
}

# --- Durcissement (Step 6), tracked from Viktor's Step 2 review: EOF on
# stdin (no TTY / unattended invocation, stdin exhausted or /dev/null) is
# NOT the same signal as a real operator pressing Enter on the [Y/n]
# default — before this fix, `${ans:-y}` could not tell them apart and
# silently took the "kept" branch on EOF too, the least conservative
# possible default for a tool whose whole job is not moving data nobody
# approved. Fixed: `read`'s own non-zero exit status on EOF is checked
# explicitly, and the function aborts (returns 1, prints nothing further)
# instead of guessing.
@test "_plan_prompt_items_plain aborts (does not guess 'kept') when stdin hits genuine EOF, not answered" {
  run --separate-stderr env PATH=/usr/bin:/bin bash -c '
    source lib/core.sh; source lib/plan.sh
    items=$(printf "a: one\na: two")
    _plan_prompt_items_plain "$items"
  ' < /dev/null
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"selection interrupted"* ]] || false
}

@test "_plan_prompt_items_plain aborts mid-selection on EOF, discarding any already-answered items too (no partial guess)" {
  run --separate-stderr env PATH=/usr/bin:/bin bash -c '
    source lib/core.sh; source lib/plan.sh
    items=$(printf "a: one\na: two\na: three")
    _plan_prompt_items_plain "$items"
  ' <<< $'y'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"selection interrupted"* ]] || false
}

@test "_plan_prompt_items_plain still works normally when every item is genuinely answered (real Enter keystrokes, not EOF)" {
  run --separate-stderr env PATH=/usr/bin:/bin bash -c '
    source lib/core.sh; source lib/plan.sh
    items=$(printf "a: one\na: two")
    _plan_prompt_items_plain "$items"
  ' <<< $'y\ny\n'
  [ "$status" -eq 0 ]
  [ "$output" = "a: one
a: two" ]
}

@test "plan_select_interactive propagates an aborted selection instead of freezing a guessed manifest" {
  run --separate-stderr env PATH=/usr/bin:/bin bash -c '
    source lib/core.sh; source lib/manifest.sh; source lib/plan.sh
    manifest="{\"migrate\":{\"etch\":{\"post_types\":[\"etch_cfs\"],\"option_keys\":[]}}}"
    plan_select_interactive "$manifest"
  ' < /dev/null
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"manifest not frozen"* ]] || false
}

# --- issue #103: _plan_confirm / _plan_confirm_strong / _plan_prompt_items
# refuse on a non-TTY stdin instead of blocking. Every test above proves
# these three functions decline correctly when stdin happens to hit EOF
# (a heredoc, /dev/null) -- that alone does not prove the fix, because a
# `read` against a stdin that EVENTUALLY reaches EOF was already returning
# non-zero before this fix too (same "both worlds exit 1" trap
# test_phase_restore.bats's own #46 guard test documents). What actually
# distinguishes the fix is a stdin that NEVER reaches EOF: before this
# fix, that hangs forever (confirmed live against lib/plan.sh before this
# PR, per tests/lint/no-blocking-stdin-reads.sh's own header); after it,
# these functions refuse immediately, without ever attempting a `read`.
#
# Reuses the same never-EOF FIFO technique as
# tests/lint/no-blocking-stdin-reads.sh: a FIFO this test opens
# read-write on its own fd (so the open never blocks -- this process is
# both ends), duplicated onto the child's stdin. Nothing ever writes to
# it or closes it, so a `read` against it blocks forever; `[ -t 0 ]`
# against it is false immediately, since a FIFO is never a TTY, so the
# guard fires without ever reaching a `read` at all. Wrapped in `timeout`
# (skipped, not failed, where the coreutil is absent -- e.g. a bare macOS
# dev machine -- matching test_no_blocking_stdin_reads.bats's own
# fallback) purely as a safety net for THIS test file, in case the guard
# itself ever regresses: without it, a broken guard would hang this test
# rather than fail it.
setup_never_eof_fifo() {
  local fifo="$BATS_TEST_TMPDIR/never-eof-$$"
  mkfifo "$fifo"
  exec 9<>"$fifo"
  rm -f "$fifo"
}

@test "_plan_confirm refuses immediately (TTY guard) instead of blocking on a stdin that never reaches EOF" {
  setup_never_eof_fifo
  if command -v timeout >/dev/null 2>&1; then
    run --separate-stderr timeout 10 env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm "ok?"' 0<&9
  else
    run --separate-stderr env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm "ok?"' 0<&9
  fi
  exec 9<&-
  [ "$status" -eq 1 ]
  [ "$status" -ne 124 ]
  [[ "$stderr" == *"needs a real interactive terminal"* ]] || false
}

@test "_plan_confirm_strong refuses immediately (TTY guard) instead of blocking on a stdin that never reaches EOF" {
  setup_never_eof_fifo
  if command -v timeout >/dev/null 2>&1; then
    run --separate-stderr timeout 10 env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm_strong "ok?"' 0<&9
  else
    run --separate-stderr env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm_strong "ok?"' 0<&9
  fi
  exec 9<&-
  [ "$status" -eq 1 ]
  [ "$status" -ne 124 ]
  [[ "$stderr" == *"needs a real interactive terminal"* ]] || false
}

@test "_plan_prompt_items refuses immediately (TTY guard) instead of blocking on a stdin that never reaches EOF" {
  setup_never_eof_fifo
  if command -v timeout >/dev/null 2>&1; then
    run --separate-stderr timeout 10 env PATH=/usr/bin:/bin bash -c '
      source lib/core.sh; source lib/plan.sh
      items=$(printf "a: one\na: two")
      _plan_prompt_items "$items"
    ' 0<&9
  else
    run --separate-stderr env PATH=/usr/bin:/bin bash -c '
      source lib/core.sh; source lib/plan.sh
      items=$(printf "a: one\na: two")
      _plan_prompt_items "$items"
    ' 0<&9
  fi
  exec 9<&-
  [ "$status" -eq 1 ]
  [ "$status" -ne 124 ]
  [ -z "$output" ]
  [[ "$stderr" == *"needs a real interactive terminal"* ]] || false
}
