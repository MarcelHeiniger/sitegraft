# tests/unit/test_no_fatal_parameter_expansion.bats
#
# Tests for tests/lint/no-fatal-parameter-expansion.sh — the repo guard
# against bash's `:?` required-parameter expansion, which on bash 3.2 kills
# the process while reporting $?=0 (that script's header carries the live
# reproduction).
#
# CLAUDE.md: "Prove the check can fail. A test that only asserts 'it ran'
# ratifies a check that always passes." So most of this file is planted
# violations that MUST be caught — including a verbatim copy of the real
# historical defect — plus the false-positive cases that must NOT be, since a
# guard noisy enough to get disabled protects nothing.

setup() {
  GUARD="${BATS_TEST_DIRNAME}/../lint/no-fatal-parameter-expansion.sh"
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE"
}

# Emits the fatal expansion for <name> while keeping the literal text out of
# THIS file — the `?` is spliced in at runtime. Without that, the suite plants
# its own violations in the tree the guard scans and fails itself on the last
# test below. Not a workaround for a guard blind spot: it is what lets the
# guard stay exclusion-free, so no file in the repo is exempt (including this
# one).
fatal() { printf '${%s:%snope}' "$1" '?'; }

# --- the guard must fail on the thing it exists for -------------------------

@test "guard catches the REAL historical defect: the pre-fix plan doc, verbatim" {
  # Not a synthetic stand-in — fixtures/pre-fix-plan-excerpt.md.fixture is the
  # actual block that sat in docs/plans/ until it was fixed. Had this guard
  # existed, this is the run that would have failed.
  cp "${BATS_TEST_DIRNAME}/fixtures/pre-fix-plan-excerpt.md.fixture" "$TREE/plan.md"
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"plan.md:28"* ]] || false
  [[ "$output" == *"path_var"* ]] || false
}

@test "guard catches an indirect required-parameter expansion in a shell source" {
  printf 'f() {\n  local p="%s"\n}\n' "$(fatal '!path_var')" > "$TREE/lib.sh"
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lib.sh:2"* ]] || false
}

@test "guard catches a direct required-parameter expansion in a shell source" {
  printf 'f() {\n  local p="%s"\n}\n' "$(fatal 'SITE_B_WP_PATH')" > "$TREE/lib.sh"
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lib.sh:2"* ]] || false
}

@test "guard catches the positional form on \$1" {
  printf 'f() {\n  local a="%s"\n}\n' "$(fatal 1)" > "$TREE/lib.sh"
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lib.sh:2"* ]] || false
}

@test "guard catches it in a .bats file and in a .sh.example module" {
  printf '@test "x" {\n  p="%s"\n}\n' "$(fatal v)" > "$TREE/t.bats"
  printf 'mod_detect() {\n  p="%s"\n}\n' "$(fatal v)" > "$TREE/m.sh.example"
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"t.bats:2"* ]] || false
  [[ "$output" == *"m.sh.example:2"* ]] || false
}

@test "guard catches it on a line carrying a trailing comment" {
  # Only WHOLE-line comments are documentation; code with a comment after it
  # still executes.
  printf 'f() {\n  local p="%s"  # looks harmless\n}\n' "$(fatal v)" > "$TREE/lib.sh"
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 1 ]
}

@test "guard sees a brand-new file that has not been git added yet" {
  # Regression: an early draft of the guard listed only `git ls-files`
  # (tracked files), so an untracked file was invisible — it would have
  # reported "clean" to the one contributor who most needed to hear otherwise.
  git -C "$TREE" init -q
  printf 'f() {\n  local p="%s"\n}\n' "$(fatal v)" > "$TREE/brand-new.sh"
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"brand-new.sh:2"* ]] || false
}

# --- the guard must NOT fire on discussion of the pattern -------------------

@test "guard ignores a whole-line comment describing the trap" {
  # Exactly what lib/inventory.sh, lib/backup.sh and lib/profile.sh do. If
  # this failed, the guard would force those hard-won warnings to be deleted.
  printf '# Deliberately NOT `%s` — it exits 0 on bash 3.2.\nf() { :; }\n' \
    "$(fatal '!path_var')" > "$TREE/lib.sh"
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 0 ]
}

@test "guard ignores Markdown prose and non-shell fences" {
  {
    printf 'Never use `%s` in this repo; it exits 0 under bash 3.2.\n\n' "$(fatal '!v')"
    printf '```text\n%s\n```\n' "$(fatal '!v')"
  } > "$TREE/notes.md"
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 0 ]
}

@test "guard fires inside a Markdown bash fence where identical prose does not" {
  # The pair that defines the whole rule: same text, different context. A
  # fenced block is what a contributor copies; prose is where the trap gets
  # explained.
  printf 'Prose about `%s` is fine.\n\n```bash\np="%s"\n```\n' \
    "$(fatal v)" "$(fatal v)" > "$TREE/doc.md"
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"doc.md:4"* ]] || false
}

@test "guard accepts the shipped safe form" {
  cat > "$TREE/lib.sh" <<'EOF'
f() {
  local p="${!path_var:-}"
  if [ -z "$p" ]; then
    log_error "missing ${path_var}"
    return 1
  fi
}
EOF
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 0 ]
}

# --- the guard must not report a pass it did not earn -----------------------

@test "guard exits 2, not 0, when it scans no files at all" {
  # CLAUDE.md: a check must distinguish "verified true" from "could not
  # verify". An empty tree is the latter, so it must not read as a pass.
  run bash "$GUARD" "$TREE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"scanned 0 files"* ]] || false
}

@test "guard exits 2 on a root that does not exist" {
  run bash "$GUARD" "$TREE/nope"
  [ "$status" -eq 2 ]
}

# --- and the repo itself stays clean ----------------------------------------

@test "the sitegraft repo contains no fatal required-parameter expansion" {
  run bash "$GUARD" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}
