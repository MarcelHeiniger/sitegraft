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

# Nit 2 (third review round, second reviewer). If id-map.tsv's column 2 is
# not an integer, `jq --argjson n` fails, `$fixed` comes back EMPTY, and the
# push writes that empty value to B — the exact "BLANK B's own theme_mods"
# this module warns about elsewhere, arrived at from the other side.
#
# Unreachable today: column 2 is written by the mapping mu-plugin from a
# WordPress post ID, always an integer. Guarded anyway, for the same reason a
# fail-closed default matters on a branch nothing takes — a guard missing on
# an unreachable path is the one a future change makes reachable without
# anything saying so.
#
# Two guards sit on this failure and they are NOT redundant, which is why this
# test asserts the good outcome rather than merely "nothing bad was pushed":
#   - a malformed id never reaches `jq --argjson` at all, so it is treated
#     like a missing one (key dropped, out loud) and the REST of the rewrite
#     still happens — that is what this test pins;
#   - `[ -n "$fixed" ]` before the write is the last-resort backstop for any
#     other jq failure, which with the first guard in place is unreachable by
#     construction (see the mutation notes in the PR).
@test "core_wp_post_import treats a malformed id-map entry like a missing one, and still rewrites the rest (nit 2)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '%s' '{"custom_logo":42,"nav_menu_locations":{"primary":9},"other_setting":"keep-me"}' \
    > "${run_dir}/option-theme_mods_etch-child.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  # Column 2 is not an integer — a corrupt or hand-edited map.
  printf '42\tnot-a-number\tattachment\n' > "$tsv"
  wp_cmd_b_stub() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  run --separate-stderr core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  # A push DID happen — the malformed logo must not abort the whole rewrite,
  # which would leave nav_menu_locations (A's term ids) sitting on B.
  [ -f "$BATS_TEST_TMPDIR/calls.log" ]
  local pushed
  pushed=$(grep -F 'option update theme_mods_etch-child' "$BATS_TEST_TMPDIR/calls.log" \
    | sed 's/^option update theme_mods_etch-child //; s/ --format=json$//')
  # ...and it is a real object, never the empty string.
  [ -n "$pushed" ]
  run jq -e 'has("custom_logo") == false and has("nav_menu_locations") == false and .other_setting == "keep-me"' <<< "$pushed"
  [ "$status" -eq 0 ]
}

# Nit 3 / mutant C2 (third review round, second reviewer): the behaviour is
# already correct — `custom_logo: 0` is WordPress's "no logo", not attachment
# zero — but nothing asserted it, so removing `0` from the skip list left the
# suite green.
@test "core_wp_post_import treats custom_logo 0 as 'no logo', not as attachment id 0 (nit 3)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '%s' '{"custom_logo":0,"other_setting":"keep-me"}' > "${run_dir}/option-theme_mods_etch-child.value"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  # A row that WOULD match if 0 were treated as a real id.
  printf '0\t907\tattachment\n' > "$tsv"
  wp_cmd_b_stub() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  run --separate-stderr core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  # Nothing to fix, so nothing is pushed and nothing is warned about.
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
  [[ "$stderr" != *"custom_logo"* ]] || false
}

# --- core_wp_post_types_dynamic: issue #17. `wp_navigation` — the block
# themes' navigation post type — was declared by no module at all, so it
# fell into protect._unclaimed and never travelled, even from a block-theme
# A whose header component referenced one. See modules/core-wp.sh's own
# header comment on core_wp_post_types_dynamic for why this is dynamic
# rather than a third name in core_wp_post_types above, and why it is gated
# on nav_uses_dynamic_page_list specifically rather than on the post type
# being registered (verified against WordPress core: wp_navigation is
# registered unconditionally, so its mere presence in scan.post_types proves
# nothing about whether A has any actual navigation content).
@test "core_wp_post_types_dynamic claims wp_navigation when the scan proves A has dynamic navigation content (#17)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"page"},{"name":"wp_navigation"}],"nav_uses_dynamic_page_list":true}
EOF
  run core_wp_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ "$output" = "wp_navigation" ]
}

@test "core_wp_post_types_dynamic claims nothing when nav_uses_dynamic_page_list is false (#17)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"page"},{"name":"wp_navigation"}],"nav_uses_dynamic_page_list":false}
EOF
  run core_wp_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "core_wp_post_types_dynamic claims nothing when nav_uses_dynamic_page_list is null, i.e. the A-side query failed (#17)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"page"}],"nav_uses_dynamic_page_list":null}
EOF
  run core_wp_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "core_wp_post_types_dynamic claims nothing when the scan predates nav_uses_dynamic_page_list entirely -- missing key, not malformed (#17)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"post_types":[{"name":"page"}]}' > "$scan"
  run core_wp_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "core_wp_post_types_dynamic fails closed on a scan with no post_types list at all (#17)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"nav_uses_dynamic_page_list":true}' > "$scan"
  run core_wp_post_types_dynamic "$scan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"post_types"* ]] || false
}

# --- Issue #17's id-remap. A wp_navigation post's navigation-link blocks
# carry POST ids for the pages/posts they point at
# (`{"id":5,"kind":"post-type"}`). MEASURED, not assumed, that this needed a
# new hook rather than being covered already: graft_remap_attachment_ids
# (lib/graft.sh) calls sitegraft_remap_attachment_refs
# (lib/php/content-remap-functions.php) with an `$attachments` map built
# exclusively from id-map.tsv rows tagged "attachment" (read directly,
# `awk -F'\t' '$3=="attachment"'` in graft_remap_attachment_ids) -- a page or
# post id is never in that set, so it travels to B unrewritten. This
# module's own post_import hook is where it happens instead, the same
# division of labour design doc §11 already draws for module-specific
# references, and the one etch_post_import already uses for Etch's own
# component "ref" ids.
@test "core_wp_post_import remaps a static navigation-link's page id through id-map.tsv (#17)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t205\tpage\n77\t177\twp_navigation\n' > "$tsv"
  wp_cmd_b_stub() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  run cat "$BATS_TEST_TMPDIR/calls.log"
  [[ "$output" == *"eval"* ]] || false
  [[ "$output" == *"sitegraft_core_wp_remap_nav_link_ids"* ]] || false
  [[ "$output" == *'"5":"205"'* ]] || false
}

@test "core_wp_post_import's nav id-remap is a no-op when id-map.tsv has no wp_navigation row (#17)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t205\tpage\n' > "$tsv"
  wp_cmd_b_stub() { printf 'SHOULD NOT RUN NAV REMAP %s\n' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  if [ -f "$BATS_TEST_TMPDIR/calls.log" ]; then
    run grep -c "eval" "$BATS_TEST_TMPDIR/calls.log"
    [ "$output" = "0" ]
  fi
}

@test "core_wp_post_import's nav id-remap is a no-op when id-map.tsv does not exist at all yet -- first-time --dry-run (#17)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  [ ! -e "$tsv" ]
  wp_cmd_b_stub() { echo "SHOULD NOT BE CALLED" >> "$BATS_TEST_TMPDIR/calls.log"; }
  run core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
}

@test "core_wp_post_import's nav id-remap does NOT call wp_cmd_b for real under SITEGRAFT_DRY_RUN=1 (#17)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t205\tpage\n77\t177\twp_navigation\n' > "$tsv"
  wp_cmd_b_stub() { echo "SHOULD NOT BE CALLED FOR REAL UNDER DRY-RUN" >> "$BATS_TEST_TMPDIR/calls.log"; }
  SITEGRAFT_DRY_RUN=1 run core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/calls.log" ]
  [[ "$output" == *"[dry-run]"* ]] || false
  [[ "$output" == *"eval"* ]] || false
}

@test "core_wp_post_import's nav id-remap map excludes attachment rows -- the taxonomy/post-type kind check needs a clean post-id map (#17)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t905\tattachment\n77\t177\twp_navigation\n' > "$tsv"
  wp_cmd_b_stub() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  run cat "$BATS_TEST_TMPDIR/calls.log"
  [[ "$output" != *'"5":"905"'* ]] || false
}

@test "core_wp_post_import's nav id-remap treats a wp_navigation row with a malformed new id as unimportable, not as something to remap toward (#17)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  # A corrupt or hand-edited map: column 2 is not an integer.
  printf '5\t205\tpage\n77\tnot-a-number\twp_navigation\n' > "$tsv"
  wp_cmd_b_stub() { printf 'SHOULD NOT RUN NAV REMAP %s\n' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  if [ -f "$BATS_TEST_TMPDIR/calls.log" ]; then
    run grep -c "eval" "$BATS_TEST_TMPDIR/calls.log"
    [ "$output" = "0" ]
  fi
}

# --- _core_wp_nav_remap_php: the actual substitution logic, tested via a
# real `php` CLI process -- no WordPress bootstrap needed (json_decode/
# json_encode/preg_replace_callback are plain PHP, not WordPress functions).
# Same reasoning lib/php/content-remap-functions.php's own header gives for
# why this matters (review, Viktor, NIT-1): an inline bash-string PHP
# payload is syntactically impossible to unit test on its own. Kept in its
# own bash function (rather than inlined directly into the eval heredoc in
# _core_wp_remap_nav_page_ids) specifically so this exact source can be
# captured and run standalone here.
_php_available() { command -v php >/dev/null 2>&1; }

@test "_core_wp_nav_remap_php remaps a post-type navigation-link's id through the map (#17)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$out = sitegraft_core_wp_remap_nav_link_ids(
      ['5' => '205'],
      '<!-- wp:navigation-link {\"label\":\"Home\",\"type\":\"page\",\"id\":5,\"kind\":\"post-type\"} /-->'
    );
    if (strpos(\$out, '\"id\":205') === false) { fwrite(STDERR, \"not remapped: \$out\n\"); exit(1); }
    if (strpos(\$out, '\"id\":5,') !== false) { fwrite(STDERR, \"old id survived: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "_core_wp_nav_remap_php leaves a taxonomy-kind navigation-link's id untouched even when it numerically collides with a page id in the map -- kind ambiguity safety (#17)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$out = sitegraft_core_wp_remap_nav_link_ids(
      ['5' => '205'],
      '<!-- wp:navigation-link {\"label\":\"News\",\"type\":\"category\",\"id\":5,\"kind\":\"taxonomy\"} /-->'
    );
    if (strpos(\$out, '\"id\":5,') === false) { fwrite(STDERR, \"taxonomy id was wrongly rewritten: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "_core_wp_nav_remap_php leaves a dynamic wp:page-list block untouched -- nothing to remap (#17)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$in = '<!-- wp:page-list /-->';
    \$out = sitegraft_core_wp_remap_nav_link_ids(['5' => '205'], \$in);
    if (\$out !== \$in) { fwrite(STDERR, \"page-list block was modified: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "_core_wp_nav_remap_php remaps navigation-submenu ids too, and its nested navigation-link children (#17)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$in = '<!-- wp:navigation-submenu {\"label\":\"More\",\"type\":\"page\",\"id\":9,\"kind\":\"post-type\"} -->' .
      '<!-- wp:navigation-link {\"label\":\"Child\",\"type\":\"page\",\"id\":9,\"kind\":\"post-type\"} /-->' .
      '<!-- /wp:navigation-submenu -->';
    \$out = sitegraft_core_wp_remap_nav_link_ids(['9' => '209'], \$in);
    if (substr_count(\$out, '\"id\":209') !== 2) { fwrite(STDERR, \"expected both ids remapped: \$out\n\"); exit(1); }
    if (strpos(\$out, '\"id\":9,') !== false) { fwrite(STDERR, \"an old id survived: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "_core_wp_nav_remap_php leaves a navigation-link id untouched when the map has no entry for it (#17)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  # The extra space after each ":" is deliberate, not incidental: it makes
  # this test distinguish "genuinely took the untouched-comment early
  # return" from "went through decode/re-encode and merely happened to
  # produce the same id" -- a mutant that always rewrites (dropping the
  # array_key_exists guard and falling back to the OLD id when unmapped)
  # would re-serialize via json_encode either way, which is compact and
  # would silently swallow this spacing -- caught live: without this
  # spacing, that exact mutant left every assertion in this file green,
  # because json_decode(42)/json_encode(42) round-trips to the byte-identical
  # "42" when the id happens to already match.
  run php -r "
    require '${phpfile}';
    \$in = '<!-- wp:navigation-link {\"label\": \"Orphan\", \"type\": \"page\", \"id\": 42, \"kind\": \"post-type\"} /-->';
    \$out = sitegraft_core_wp_remap_nav_link_ids([], \$in);
    if (\$out !== \$in) { fwrite(STDERR, \"unmapped id was modified: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
