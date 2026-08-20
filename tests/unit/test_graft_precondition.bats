# tests/unit/test_graft_precondition.bats — graft_check_stack_precondition
# (design doc §6.4 step 0b / §12): refuses to graft on any stack mismatch
# graft_sync_stack did NOT already resolve, unless --allow-stack-mismatch.
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/graft.sh'
}

@test "graft_check_stack_precondition passes when the stack matches" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$b"
  run graft_check_stack_precondition "$a" "$b" '{}' 0
  [ "$status" -eq 0 ]
}

@test "graft_check_stack_precondition refuses an unresolved mismatch without the override" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"theme-a"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"theme-b"},"plugins":[]}' > "$b"
  local manifest='{"stack":{"theme":{"slug_a":"theme-a","slug_b":"theme-b","version_a":"1.0","version_b":"4.2","resolution":"skip"}}}'
  run graft_check_stack_precondition "$a" "$b" "$manifest" 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"--allow-stack-mismatch"* ]]
}

@test "graft_check_stack_precondition passes a mismatch the manifest already resolved via copy (graft_sync_stack already ran)" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"theme-a"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"theme-b"},"plugins":[]}' > "$b"
  local manifest='{"stack":{"theme":{"slug_a":"theme-a","slug_b":"theme-b","version_a":"1.0","version_b":"4.2","resolution":"copy"}}}'
  run graft_check_stack_precondition "$a" "$b" "$manifest" 0
  [ "$status" -eq 0 ]
}

@test "graft_check_stack_precondition allows a remaining mismatch with the override flag" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"theme-a"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"theme-b"},"plugins":[]}' > "$b"
  local manifest='{"stack":{"theme":{"slug_a":"theme-a","slug_b":"theme-b","version_a":"1.0","version_b":"4.2","resolution":"skip"}}}'
  run graft_check_stack_precondition "$a" "$b" "$manifest" 1
  [ "$status" -eq 0 ]
}
