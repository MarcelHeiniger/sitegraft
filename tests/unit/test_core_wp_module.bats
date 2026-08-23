# tests/unit/test_core_wp_module.bats — modules/core-wp.sh: the module that
# claims WordPress's own page/post content and the core options graft needs
# (design doc §9.3 names "the core-wp module's hook" explicitly, but no such
# module existed before this Step — see modules/core-wp.sh's own header
# comment). Loaded directly (not via modules_discover) so the module
# contract functions are exercised in isolation, same convention as
# tests/unit/test_modules.bats uses for its own fabricated modules.
bats_require_minimum_version 1.5.0

setup() {
  load '../../lib/core.sh'
  # shellcheck disable=SC1091
  load '../../modules/core-wp.sh'
  unset SITEGRAFT_DRY_RUN
}

@test "core_wp_name returns a human-readable label" {
  run core_wp_name
  [ "$output" = "WordPress Core" ]
}

@test "core_wp_detect matches a scan showing the page post_type" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"post_types":[{"name":"page"},{"name":"post"}]}' > "$scan"
  run core_wp_detect "$scan"
  [ "$status" -eq 0 ]
}

@test "core_wp_detect does not match a scan without the page post_type" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"post_types":[{"name":"some_cpt"}]}' > "$scan"
  run core_wp_detect "$scan"
  [ "$status" -ne 0 ]
}

@test "core_wp_post_types declares page and post" {
  run core_wp_post_types
  [[ "$output" == *"page"* ]] || false
  [[ "$output" == *"post"* ]] || false
}

@test "core_wp_option_keys declares the front-page trio plus site identity" {
  run core_wp_option_keys
  [[ "$output" == *"page_on_front"* ]] || false
  [[ "$output" == *"page_for_posts"* ]] || false
  [[ "$output" == *"show_on_front"* ]] || false
}

# --- core_wp_option_keys_dynamic: issue #15. `theme_mods_<stylesheet>` holds
# the active theme's customizer settings and belongs with a migrated design,
# but its KEY NAME depends on the site's active theme slug — unknowable until
# `scan` has run, so a static _option_keys list can never express it. See
# docs/decisions/0007-module-dynamic-selections.md.
@test "core_wp_option_keys_dynamic derives theme_mods_<slug> from the scanned active theme (#15)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"active_theme":{"stylesheet":"etch-theme-child"},
 "options":[{"option_name":"blogname"},{"option_name":"theme_mods_etch-theme-child"}]}
EOF
  run core_wp_option_keys_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ "$output" = "theme_mods_etch-theme-child" ]
}

@test "core_wp_option_keys_dynamic follows whatever slug the scan actually shows, never a hardcoded one (#15)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"active_theme":{"stylesheet":"twentytwentyfive"},
 "options":[{"option_name":"theme_mods_twentytwentyfive"}]}
EOF
  run core_wp_option_keys_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ "$output" = "theme_mods_twentytwentyfive" ]
}

# graft_migrate_options (lib/graft.sh) falls back to the literal `null` when
# `wp option get` finds nothing on A, and writes that to B. Offering a key A
# does not have would therefore BLANK B's own theme_mods — the opposite of
# what migrating a design is for.
@test "core_wp_option_keys_dynamic claims nothing when the site never stored theme_mods for its active theme" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"active_theme":{"stylesheet":"never-customized"},"options":[{"option_name":"blogname"}]}' > "$scan"
  run core_wp_option_keys_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "core_wp_option_keys_dynamic fails closed on a scan that records no active theme at all" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"active_theme":{},"options":[]}' > "$scan"
  run core_wp_option_keys_dynamic "$scan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"active theme"* ]] || false
}

@test "core_wp_option_keys_dynamic fails closed on a scan with no options list, rather than reporting 'nothing to migrate'" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"active_theme":{"stylesheet":"t"}}' > "$scan"
  run core_wp_option_keys_dynamic "$scan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"options"* ]] || false
}

@test "core_wp_post_import remaps page_on_front through id-map.tsv" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_cmd_b_stub() { echo "wp_cmd_b_stub $*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  run cat "$BATS_TEST_TMPDIR/calls.log"
  [[ "$output" == *"option update page_on_front 105"* ]] || false
}

@test "core_wp_post_import is a no-op when A never had a front page set" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf 'false' > "${run_dir}/option-page_on_front.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  : > "$tsv"
  wp_cmd_b_stub() { echo "SHOULD NOT BE CALLED" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
}

@test "core_wp_post_import warns instead of erroring when the old page has no id-map.tsv entry" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  : > "$tsv" # page 5 was never actually imported
  wp_cmd_b_stub() { echo "SHOULD NOT BE CALLED" >> "$BATS_TEST_TMPDIR/calls.log"; }
  run core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
}

# Fix-pack bug found live (DDEV harness, MAJOR-B's new graft --dry-run
# assertion, running end to end for the first time against a genuinely
# fresh run directory — same root cause and same fix as
# graft_remap_featured_images in lib/graft.sh): graft_fetch_id_map never
# creates id_map_tsv under --dry-run, so on a first-time dry run the file
# doesn't exist at all, not merely empty. `awk` on a genuinely missing file
# exits non-zero (2), and the bare `new_id=$(awk ...)` assignment aborted
# the whole graft under this codebase's `set -e` — reproduced live as a
# bare, unlogged "exit 2" from the DDEV harness, no error message anywhere
# (the awk call's own stderr is intentionally discarded via 2>/dev/null).
#
# Run via a real `bash -c 'set -euo pipefail; ...'` subprocess, not a plain
# bats function call — same convention test_plan_select.bats' own
# set-euo-pipefail regression test already established, for the identical
# reason: a bats @test body does NOT itself run under set -e, so calling
# core_wp_post_import directly here would never reproduce this bug at all
# (verified while writing this test: a plain `run core_wp_post_import ...`
# without set -e active masked the crash completely, awk's failure just
# left new_id empty and the function returned 0 either way — the exact
# opposite of what actually happens under bin/sitegraft's real `set -euo
# pipefail`, which is what the DDEV harness run — and a real operator —
# actually hits).
@test "core_wp_post_import is a no-op (not a crash) under set -euo pipefail when id-map.tsv does not exist at all yet — first-time --dry-run case" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  [ ! -e "$tsv" ]
  run --separate-stderr bash -c '
    set -euo pipefail
    source lib/core.sh
    source modules/core-wp.sh
    wp_cmd_b_stub() { echo "SHOULD NOT BE CALLED" >> "$3"; }
    core_wp_post_import "$1" "$2" wp_cmd_b_stub
  ' _ "$run_dir" "$tsv" "$BATS_TEST_TMPDIR/calls.log"
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
}

# --- Step 6 dry-run audit: core_wp_post_import was found writing to B
# unconditionally, ignoring --dry-run entirely (graft_run_module_post_import,
# lib/graft.sh, calls every module's post_import hook regardless of dry-run
# mode — there is no separate skip-hooks-in-dry-run branch). Concretely
# reachable via graft's own step-idempotency markers: a `--dry-run` re-run
# against a run directory whose id-map.tsv a prior REAL run already
# populated would have actually written to B's live option. Fixed by
# wrapping the write in lib/core.sh's run_or_echo — these two tests are the
# regression coverage for that fix.
@test "core_wp_post_import does NOT call wp_cmd_b for real under SITEGRAFT_DRY_RUN=1 (regression: used to write to B even in dry-run)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_cmd_b_stub() { echo "SHOULD NOT BE CALLED FOR REAL UNDER DRY-RUN" >> "$BATS_TEST_TMPDIR/calls.log"; }
  SITEGRAFT_DRY_RUN=1 core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
}

@test "core_wp_post_import prints a [dry-run] line instead of writing under SITEGRAFT_DRY_RUN=1" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '"5"' > "${run_dir}/option-page_on_front.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  wp_cmd_b_stub() { echo "SHOULD NOT BE CALLED FOR REAL UNDER DRY-RUN"; }
  SITEGRAFT_DRY_RUN=1 run core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] wp_cmd_b_stub option update page_on_front 105"* ]] || false
}

# --- B2 (third review round): theme_mods_<slug> is FULL of A's own
# local IDs, and this PR is what started migrating it.
#
# core_wp_option_keys_dynamic added `theme_mods_<active-theme>` to migrate.
# graft_migrate_options then pushes that option to B verbatim — and every
# theme_mods_ row carries `custom_logo` (an ATTACHMENT id), plus
# `nav_menu_locations` (TERM ids) and `custom_css_post_id` (a POST id).
# graft_remap_attachment_ids only ever rewrites post_content/post_excerpt,
# never an option value, so A's numbers land on B unchanged.
#
# The failure mode is the bad one: if B happens to own an attachment with
# that number, B's logo silently becomes a DIFFERENT, WRONG image — not a
# missing one. This hook is the existing answer for exactly this shape of
# problem (it is why page_on_front is remapped rather than copied), and it
# already runs after both the import and graft_migrate_options.
#
# nav_menu_locations and custom_css_post_id are REMOVED rather than remapped:
# sitegraft v1 migrates neither classic menus (design doc §13) nor
# `custom_css`, so there is nothing on B for those ids to point at, and a
# remap would have nothing to remap through.

@test "core_wp_post_import remaps theme_mods' custom_logo through id-map.tsv instead of carrying A's attachment id to B (B2)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '%s' '{"custom_logo":42,"other_setting":"keep-me"}' > "${run_dir}/option-theme_mods_etch-child.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '42\t907\tattachment\n' > "$tsv"
  wp_cmd_b_stub() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  run cat "$BATS_TEST_TMPDIR/calls.log"
  [[ "$output" == *"option update theme_mods_etch-child"* ]] || false
  local pushed
  pushed=$(grep -F 'option update theme_mods_etch-child' "$BATS_TEST_TMPDIR/calls.log" \
    | sed 's/^option update theme_mods_etch-child //; s/ --format=json$//')
  run jq -e '.custom_logo == 907 and .other_setting == "keep-me"' <<< "$pushed"
  [ "$status" -eq 0 ]
}

@test "core_wp_post_import drops theme_mods' custom_logo, out loud, when id-map.tsv has no entry for it (never guesses) (B2)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '%s' '{"custom_logo":42,"other_setting":"keep-me"}' > "${run_dir}/option-theme_mods_etch-child.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '7\t107\tpage\n' > "$tsv"
  wp_cmd_b_stub() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  run --separate-stderr core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"custom_logo"* ]] || false
  local pushed
  pushed=$(grep -F 'option update theme_mods_etch-child' "$BATS_TEST_TMPDIR/calls.log" \
    | sed 's/^option update theme_mods_etch-child //; s/ --format=json$//')
  run jq -e 'has("custom_logo") | not' <<< "$pushed"
  [ "$status" -eq 0 ]
}

@test "core_wp_post_import strips nav_menu_locations and custom_css_post_id from theme_mods, naming both (B2)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '%s' '{"nav_menu_locations":{"primary":9},"custom_css_post_id":31,"other_setting":"keep-me"}' \
    > "${run_dir}/option-theme_mods_etch-child.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '9\t109\tterm:nav_menu\n' > "$tsv"
  wp_cmd_b_stub() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  run --separate-stderr core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"nav_menu_locations"* ]] || false
  [[ "$stderr" == *"custom_css_post_id"* ]] || false
  local pushed
  pushed=$(grep -F 'option update theme_mods_etch-child' "$BATS_TEST_TMPDIR/calls.log" \
    | sed 's/^option update theme_mods_etch-child //; s/ --format=json$//')
  run jq -e 'has("nav_menu_locations") == false and has("custom_css_post_id") == false and .other_setting == "keep-me"' <<< "$pushed"
  [ "$status" -eq 0 ]
}

@test "core_wp_post_import leaves a theme_mods value alone when it holds none of the id-bearing keys (B2)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '%s' '{"other_setting":"keep-me"}' > "${run_dir}/option-theme_mods_etch-child.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '7\t107\tpage\n' > "$tsv"
  wp_cmd_b_stub() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  run core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
}

@test "core_wp_post_import does NOT write B's theme_mods for real under SITEGRAFT_DRY_RUN=1 (B2)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '%s' '{"custom_logo":42}' > "${run_dir}/option-theme_mods_etch-child.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '42\t907\tattachment\n' > "$tsv"
  wp_cmd_b_stub() { printf '%s\n' "REALLY-RAN $*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  SITEGRAFT_DRY_RUN=1 run core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
  [[ "$output" == *"[dry-run]"* ]] || false
}
