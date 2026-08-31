# tests/unit/test_graft_stack_sync.bats — graft_sync_stack (design doc §6.4
# step 0a / §12): rsync's every manifest.stack.<component> marked
# resolution=copy from A to B using ONLY the manifest's resolved slug_a,
# never a hardcoded/re-derived name — the exact bug (ACSS v4 legacy-slug
# case) Marcel caught in an earlier draft.
#
# lib/backup.sh is loaded alongside lib/graft.sh because graft_sync_stack
# calls _backup_local_exec_prefix (via graft_local_prefix) to decide whether
# a non-ssh transfer needs the wrapped-local (DDEV-style) tar-through-the-
# wrapper path or a plain rsync — none of these tests set a SITE_*_WP_CMD
# wrapper, so they all exercise the plain-rsync (bare-local) branch, which
# is the exact command shape asserted below.
setup() {
  load '../../lib/core.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

@test "graft_sync_stack copies and activates every component marked resolution=copy, skipping resolution=skip" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"etch":{"slug_a":"etch","slug_b":null,"version_a":"2.0","version_b":null,"resolution":"copy"},"theme":{"slug_a":"etch-theme","slug_b":"divi","version_a":"1.0","version_b":"4.2","resolution":"skip"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp-content/plugins/etch"* ]] || false
  [[ "$output" == *"plugin activate etch"* ]] || false
  [[ "$output" != *"divi"* ]]  # resolution=skip must never be touched here
}

@test "graft_sync_stack uses slug_a from the manifest, never a hardcoded name — the ACSS v4 legacy-slug case" {
  # This is the exact bug Marcel caught: an earlier draft hardcoded "automatic-css"
  # for the acss component instead of reading the manifest's resolved slug_a. A
  # plugin under a legacy folder name on B must still be correctly synced FROM
  # A's real (possibly different) resolved path — never guessed from the
  # component's internal key name.
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"acss":{"slug_a":"automatic-css","slug_b":"acss-legacy-slug","version_a":"4.1","version_b":"3.9","resolution":"copy"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp-content/plugins/automatic-css/"* ]] || false  # pulled FROM A under A's resolved slug
  [[ "$output" == *"plugin activate automatic-css"* ]] || false      # activated under that same resolved slug
  [[ "$output" != *"wp-content/plugins/acss/"* ]] || false            # never the internal component key "acss"
  [[ "$output" != *"acss-legacy-slug"* ]]                    # never B's old slug either — A's is authoritative
}

@test "graft_sync_stack reads theme's slug_a the same way as any other component (no special-casing)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"theme":{"slug_a":"etch-theme","slug_b":null,"version_a":"1.0","version_b":null,"resolution":"copy"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  # graft_sync_theme_parent (called for the "theme" component) makes real,
  # non-dry-run reads regardless of SITEGRAFT_DRY_RUN — stub wp_get_theme()
  # returning etch-theme's own slug, i.e. "not a child theme", the same
  # convention test_graft_fontstep.bats uses for graft_font_dir.
  wp_remote() {
    local alias_lc="$1"; shift
    case "$alias_lc:$1" in
      a:eval) echo "etch-theme" ;;
      b:theme) echo "etch-theme" ;;
      *) echo "UNEXPECTED wp_remote CALL: $alias_lc $*" >&2; return 1 ;;
    esac
  }
  run graft_sync_stack "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp-content/themes/etch-theme"* ]] || false
  [[ "$output" == *"theme activate etch-theme"* ]]
}

# issue #20 audit: graft_sync_theme_parent used to swallow a real wp_remote
# failure (A unreachable, B's theme list erroring) with `|| true`, reading
# back as an empty string — identically to "this theme genuinely has no
# parent" (case ''|"$child_slug") return 0). Both facts used to reach the
# exact same silent success. Fixed to distinguish "could not determine" from
# "there is nothing to find", same family as the front-page check's "or A
# never configured one" (design doc / CLAUDE.md's first convention).
@test "graft_sync_theme_parent fails closed when it cannot determine A's parent theme, never silently skips the copy" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  wp_remote() {
    local alias_lc="$1"; shift
    [ "$alias_lc" = "a" ] || { echo "UNEXPECTED ALIAS: $alias_lc" >&2; return 1; }
    return 1  # simulates A unreachable / wp eval failing
  }
  run graft_sync_theme_parent "child-theme" "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not determine whether 'child-theme' is a child theme"* ]] || false
}

@test "graft_sync_theme_parent fails closed when it cannot read B's theme list, never silently skips the copy" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then echo "some-parent"; return 0; fi
    return 1  # simulates B's theme list query failing
  }
  run graft_sync_theme_parent "child-theme" "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not determine whether 'child-theme' is a child theme"* ]] || false
}

@test "graft_sync_stack propagates graft_sync_theme_parent's failure instead of activating the theme with no parent copied" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"theme":{"slug_a":"child-theme","slug_b":null,"version_a":"1.0","version_b":null,"resolution":"copy"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  wp_remote() { return 1; }  # every real read this needs fails
  run graft_sync_stack "$run_dir" "$manifest"
  [ "$status" -ne 0 ]
  [[ "$output" != *"theme activate child-theme"* ]] || false
}

@test "graft_sync_stack treats a component name containing a space as ONE component, not two word-split fragments (issue #40)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"my component":{"slug_a":"real-slug","slug_b":null,"version_a":"1.0","version_b":null,"resolution":"copy"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  # Issue #40: the loop used to be `for component in $(echo "$manifest" | jq
  # -r '.stack ... .key')` — UNQUOTED command substitution, so the shell
  # word-split "my component" into "my" and "component". Neither is a real
  # key of .stack, so both resolved slug_a to a literal "null" and would
  # have synced/activated a plugin folder named "null" from A onto B — while
  # "my component" itself, the one component actually marked resolution=copy,
  # was never synced at all.
  [[ "$output" == *"wp-content/plugins/real-slug"* ]] || false
  [[ "$output" == *"plugin activate real-slug"* ]] || false
  [[ "$output" != *"wp-content/plugins/null"* ]] || false
  [[ "$output" != *"plugin activate null"* ]] || false
}

@test "graft_sync_stack does nothing when the manifest has no stack key" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
