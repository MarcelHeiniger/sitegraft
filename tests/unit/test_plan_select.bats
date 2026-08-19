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
  [[ "$output" == *"etch: etch_cfs, etch_cpts, etch_settings"* ]]
  [[ "$output" == *"fakebooking: fake_reservation, fakebooking_reservations, fakebooking_settings"* ]]
  [[ "$output" == *"_unclaimed: mystery_cpt"* ]]
}

@test "_plan_freeze_summary shows a module with nothing selected explicitly, not silently" {
  local manifest='{"migrate":{"acss":{"post_types":[],"option_keys":[]}},"protect":{}}'
  run _plan_freeze_summary "$manifest"
  [[ "$output" == *"acss: (nothing selected)"* ]]
}

@test "_plan_freeze_summary truncates a long item list (e.g. a real-world _unclaimed.option_keys) instead of printing an unreadable wall of text" {
  local many; many=$(jq -n -c '[range(30) | "opt_\(.)"]')
  local manifest; manifest=$(jq -n --argjson opts "$many" '{migrate:{},protect:{_unclaimed:{post_types:[],tables:[],option_keys:$opts}}}')
  run _plan_freeze_summary "$manifest"
  [[ "$output" == *"opt_0"* ]]
  [[ "$output" == *"opt_14"* ]]
  [[ "$output" == *"... and 15 more"* ]]
  [[ "$output" != *"opt_29"* ]]
}

@test "plan_select_interactive is a no-op passthrough when migrate is empty" {
  local manifest='{"migrate":{},"protect":{}}'
  run plan_select_interactive "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "$manifest" ]
}

# --- _plan_confirm / _plan_confirm_strong: only the non-gum plain-`read`
# fallback is exercisable without a TTY. Feeds input via a heredoc <<< so
# `read` doesn't block. PATH is pinned to /usr/bin:/bin (excludes
# /opt/homebrew/bin) so this test exercises the fallback deterministically —
# found live in this fix-pack: these tests silently started taking the gum
# branch instead, and failed, the moment `brew install gum` (done to verify
# the MINOR gum-flag finding below) put a real gum on PATH. Relying on "gum
# happens not to be installed" was never a safe test precondition.
@test "_plan_confirm returns success when the plain fallback is answered y" {
  run env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm "ok?" <<< "y"'
  [ "$status" -eq 0 ]
}

@test "_plan_confirm returns failure (safe default) when the plain fallback is answered n" {
  run env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm "ok?" <<< "n"'
  [ "$status" -eq 1 ]
}

@test "_plan_confirm_strong requires the literal typed YES, not y" {
  run env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm_strong "ok?" <<< "y"'
  [ "$status" -eq 1 ]
  run env PATH=/usr/bin:/bin bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm_strong "ok?" <<< "YES"'
  [ "$status" -eq 0 ]
}

# --- _plan_prompt_items' plain fallback (no gum, no fzf): MAJOR bug found
# live by Viktor's review of PR #2 and reproduced before this fix — `done <<<
# "$items"` redirected fd0 for the whole while loop, so the inner `read -r -p
# "Keep..." ans` (also defaulting to fd0) silently consumed the NEXT item
# line as its own answer instead of prompting. Reproduced live with 3 items
# and answers y/n/y: every item came out "kept" regardless of the typed
# answers. Fixed by reading items from fd3 (`done 3<<< "$items"`), leaving
# fd0 free for the interactive prompt. Each scenario below runs in a fresh
# `bash -c` subprocess (like the _plan_confirm tests above) — items are
# baked into the script text (fd3's here-string), answers arrive on stdin
# (fd0), exactly mirroring how a real terminal session would separate "what
# to ask" from "what was typed."
@test "_plan_prompt_items plain fallback respects each individual y/n/y answer, not the same one for everything (MAJOR, reproduced live before the fix)" {
  run --separate-stderr env PATH=/usr/bin:/bin bash -c '
    source lib/core.sh; source lib/plan.sh
    items=$(printf "a: one\na: two\na: three")
    _plan_prompt_items "$items"
  ' <<< $'y\nn\ny'
  [ "$status" -eq 0 ]
  [ "$output" = "a: one
a: three" ]
}

@test "_plan_prompt_items plain fallback keeps nothing when every answer is n" {
  run --separate-stderr env PATH=/usr/bin:/bin bash -c '
    source lib/core.sh; source lib/plan.sh
    items=$(printf "a: one\na: two")
    _plan_prompt_items "$items"
  ' <<< $'n\nn'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_plan_prompt_items plain fallback defaults each item to kept on an empty answer ([Y/n])" {
  run --separate-stderr env PATH=/usr/bin:/bin bash -c '
    source lib/core.sh; source lib/plan.sh
    items=$(printf "a: one\na: two")
    _plan_prompt_items "$items"
  ' <<< $'\n\n'
  [ "$status" -eq 0 ]
  [ "$output" = "a: one
a: two" ]
}
