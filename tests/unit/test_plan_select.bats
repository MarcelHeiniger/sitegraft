# tests/unit/test_plan_select.bats — the testable half of interactive
# selection (Task 2.3): _plan_apply_selection, split out of
# plan_select_interactive specifically so the JSON-rewrite logic isn't
# shipped only "manually QA'd" the way the prompting half genuinely has to
# be (no TTY / no gum in CI).
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

@test "plan_select_interactive is a no-op passthrough when migrate is empty" {
  local manifest='{"migrate":{},"protect":{}}'
  run plan_select_interactive "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "$manifest" ]
}

# --- _plan_confirm / _plan_confirm_strong: only the non-gum plain-`read`
# fallback is exercisable without a TTY. Feeds input via a heredoc <<< so
# `read` doesn't block.
@test "_plan_confirm returns success when the plain fallback is answered y" {
  run bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm "ok?" <<< "y"'
  [ "$status" -eq 0 ]
}

@test "_plan_confirm returns failure (safe default) when the plain fallback is answered n" {
  run bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm "ok?" <<< "n"'
  [ "$status" -eq 1 ]
}

@test "_plan_confirm_strong requires the literal typed YES, not y" {
  run bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm_strong "ok?" <<< "y"'
  [ "$status" -eq 1 ]
  run bash -c 'source lib/core.sh; source lib/plan.sh; _plan_confirm_strong "ok?" <<< "YES"'
  [ "$status" -eq 0 ]
}
