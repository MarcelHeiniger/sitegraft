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
# on nav_post_count specifically rather than on the post type being
# registered (verified against WordPress core: wp_navigation is registered
# unconditionally, so its mere presence in scan.post_types proves nothing
# about whether A has any actual navigation content).
#
# FIX-PACK (Nat's review, second pass): the first version of this function
# gated on nav_uses_dynamic_page_list == true instead. That is backwards for
# #17's own acceptance criterion ("a block-theme source's navigation arrives
# on the target and points at the target's own page IDs"): a dynamic
# wp:page-list navigation carries NO ids at all, so it is precisely the case
# that needs no id-remap -- while a STATIC navigation (real navigation-link
# blocks with real page ids, the exact case _core_wp_remap_nav_page_ids
# exists for) reads nav_uses_dynamic_page_list == false, IDENTICALLY to a
# source with no navigation at all, and was never claimed. The old gate
# would only ever have exercised the remap machinery on content that never
# needed remapping in the first place. inventory_nav_post_count
# (lib/inventory.sh) supplies the actually-missing fact -- does A have ANY
# wp_navigation post at all, regardless of its content's shape -- and the
# tests below are the two Nat asked for explicitly: claims when A has one,
# does not claim when A has none.
@test "core_wp_post_types_dynamic claims wp_navigation when the scan shows A has at least one wp_navigation post (#17)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"page"},{"name":"wp_navigation"}],"nav_post_count":1}
EOF
  run core_wp_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ "$output" = "wp_navigation" ]
}

# The regression test that actually matters: a STATIC navigation (real
# navigation-link blocks with real page ids -- exactly what needs the
# id-remap this PR ships) reads nav_uses_dynamic_page_list == false. Under
# the OLD gate (nav_uses_dynamic_page_list == true) this scan would have
# claimed NOTHING -- the id-remap machinery would have shipped with no
# module-driven path that ever exercises it. This is #17's own acceptance
# criterion, word for word.
@test "core_wp_post_types_dynamic claims wp_navigation for a STATIC navigation too -- nav_post_count > 0 regardless of nav_uses_dynamic_page_list (#17)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"page"},{"name":"wp_navigation"}],"nav_post_count":1,"nav_uses_dynamic_page_list":false}
EOF
  run core_wp_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ "$output" = "wp_navigation" ]
}

@test "core_wp_post_types_dynamic claims nothing when A genuinely has zero wp_navigation posts -- the false-positive guard (#17)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"page"},{"name":"wp_navigation"}],"nav_post_count":0}
EOF
  run core_wp_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# B4 (Viktor's review, mutation-proven): absent, null and 0 all end at
# "claim nothing" -- but they are not the same answer, and only ONE of
# them (null: the scan record exists and says the query failed) deserves
# an operator-visible warning. Proved by mutation before this fix that
# nothing distinguished them: changing core_wp_post_types_dynamic's
# `// "unknown"` fallback to `// 0` survived the entire suite untouched.
@test "core_wp_post_types_dynamic warns when nav_post_count is explicitly null -- the A-side query genuinely failed (B4)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"page"}],"nav_post_count":null}
EOF
  run --separate-stderr core_wp_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"nav_post_count"* ]] || false
  [[ "$stderr" == *"failed"* ]] || false
}

@test "core_wp_post_types_dynamic does NOT warn when nav_post_count is a genuine 0 -- a real classic-theme answer, not a failure (B4)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  cat > "$scan" <<'EOF'
{"post_types":[{"name":"page"}],"nav_post_count":0}
EOF
  run --separate-stderr core_wp_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "core_wp_post_types_dynamic claims nothing when the scan predates nav_post_count entirely -- missing key, not malformed (#17)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"post_types":[{"name":"page"}]}' > "$scan"
  run --separate-stderr core_wp_post_types_dynamic "$scan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Absent key deserves tolerance, not a warning -- an old scan taken
  # before nav_post_count existed is not the same failure as a scan that
  # tried to record it and couldn't (B4).
  [ -z "$stderr" ]
}

@test "core_wp_post_types_dynamic fails closed on a scan with no post_types list at all (#17)" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"nav_post_count":1}' > "$scan"
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

# B1 (Viktor's review, execution-proven): mu-plugins/sitegraft-id-mapper.php's
# wp_import_insert_term handler ALSO writes rows to id-map.tsv, tagged
# `term:<taxonomy>` in column 3 -- these are real rows, not a hypothetical.
# Before this fix, the map_json awk filter only excluded "attachment" rows,
# so a term row survived into the substitution map -- and because the map is
# built via jq's `{(.[0]): .[1]} | add`, the LAST row for a given OLD id wins
# unconditionally. A term whose OLD id happens to numerically collide with a
# migrated PAGE's OLD id (both sequences start at 1 on a fresh WordPress
# install, so this is not a remote edge case on a small site) would silently
# overwrite the correct page mapping with the term's NEW id instead --
# exactly the "id":<old> ambiguity this whole function's header comment
# spends twelve lines warning about, self-inflicted by its own map
# construction. Proved live before this fix: a term row with old id 3
# (colliding with a real page's old id 3) made a "kind":"post-type" link's
# id come out as the TERM's new id, not the PAGE's.
# Nit (Viktor's review): a duplicated id-map.tsv row for the same
# wp_navigation post (a hand-edited or otherwise duplicated file) must not
# make the embedded post-id list carry that id twice -- modules/etch.sh's
# own equivalent already dedupes its list for the identical reason.
@test "core_wp_post_import's nav id-remap dedupes a wp_navigation post id that appears twice in id-map.tsv" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '77	177	wp_navigation
77	177	wp_navigation
' > "$tsv"
  wp_cmd_b_stub() { printf '%s
' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  run cat "$BATS_TEST_TMPDIR/calls.log"
  [[ "$output" == *'$nav_ids = json_decode('"'"'["177"]'"'"', true);'* ]] || false
}

@test "core_wp_post_import's nav id-remap map excludes term: rows -- a colliding term id must never overwrite a real page mapping (B1)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  # Page 3 -> 203 is the correct mapping. A term row for a DIFFERENT taxonomy
  # entity that happened to also carry old id 3 comes AFTER it in the file
  # (import order, not something this function controls) and must not win.
  printf '3	203	page
77	177	wp_navigation
3	14	term:category
' > "$tsv"
  wp_cmd_b_stub() { printf '%s
' "$*" >> "$BATS_TEST_TMPDIR/calls.log"; }
  core_wp_post_import "$run_dir" "$tsv" "wp_cmd_b_stub"
  run cat "$BATS_TEST_TMPDIR/calls.log"
  [[ "$output" == *'"3":"203"'* ]] || false
  [[ "$output" != *'"3":"14"'* ]] || false
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

# Nit (Viktor's review): the taxonomy case above documents ITS OWN reason
# for staying untouched at length; a navigation-link carrying "id" and
# "type" but no "kind" at all was equally untouched before this PR, but
# nothing said why -- pinned here as its own, deliberately named case
# (a block predating "kind" being written is a real possibility, not
# known to be a post reference, so it is not guessed at).
@test "_core_wp_nav_remap_php leaves a navigation-link's id untouched when 'kind' is absent entirely -- not known to be a post reference, so not guessed at (#17)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$out = sitegraft_core_wp_remap_nav_link_ids(
      ['5' => '205'],
      '<!-- wp:navigation-link {\"label\":\"Home\",\"type\":\"page\",\"id\":5} /-->'
    );
    if (strpos(\$out, '\"id\":5}') === false) { fwrite(STDERR, \"kind-less link's id was wrongly rewritten: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "_core_wp_nav_remap_php leaves an UNSCOPED wp:page-list block untouched -- no parentPageID attribute at all means nothing to remap (#17)" {
  # B5 (Viktor's review): this test's ORIGINAL name claimed a general "a
  # dynamic wp:page-list block" truth, but only ever exercised the
  # no-attrs-at-all shape ('<!-- wp:page-list /-->', WordPress's own
  # serialization when parentPageID is 0/unset) -- it never proved a
  # SCOPED page-list ({"parentPageID":N}, which DOES carry a real page id)
  # was handled at all. Renamed to say precisely what it covers; the scoped
  # case gets its own test right below.
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

# B5 (Viktor's review, execution-proven gap): a wp:page-list block SCOPED to
# a parent page ({"parentPageID":12}) DOES carry a real page id -- design
# doc §6.1's own note that a source's navigation "may be a dynamic
# wp:page-list block" does not mean ids never appear in one; a
# parent-scoped list is still dynamic (no hardcoded CHILD ids) but names
# its scope BY id. parentPageID needs no "kind" disambiguation at all --
# unlike navigation-link's id, this attribute can only ever mean a page,
# by the block's own definition (core/page-list has no other id-bearing
# attribute) -- so it is always safe to remap when present and non-zero.
@test "_core_wp_nav_remap_php remaps a SCOPED page-list block's parentPageID through the map (B5)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$in = '<!-- wp:page-list {\"parentPageID\":12} /-->';
    \$out = sitegraft_core_wp_remap_nav_link_ids(['12' => '212'], \$in);
    if (strpos(\$out, '\"parentPageID\":212') === false) { fwrite(STDERR, \"parentPageID was not remapped: \$out\n\"); exit(1); }
    if (strpos(\$out, '\"parentPageID\":12,') !== false || strpos(\$out, '\"parentPageID\":12}') !== false) { fwrite(STDERR, \"old parentPageID survived: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "_core_wp_nav_remap_php leaves parentPageID untouched when it is 0 (unscoped, WordPress's own default) -- 0 is not a real page id (B5)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$in = '<!-- wp:page-list {\"parentPageID\":0} /-->';
    \$out = sitegraft_core_wp_remap_nav_link_ids(['0' => '999'], \$in);
    if (\$out !== \$in) { fwrite(STDERR, \"parentPageID 0 was wrongly treated as a real page id: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# B5 (Viktor's review, execution-proven gap): a bare wp:navigation block
# with a "ref" attribute embeds ANOTHER wp_navigation post BY ID -- this is
# how a shared/reusable navigation gets referenced from a page or template.
# Before this fix, only modules/etch.sh's OWN component-ref remap happened
# to catch this (its blind "ref":<old> substitution has zero awareness of
# what block it's inside) -- on a block-theme source without Etch, nothing
# remapped it at all. ref needs no "kind" disambiguation either: it can
# only ever mean a wp_navigation post, by the block's own definition.
@test "_core_wp_nav_remap_php remaps a wp:navigation block's ref through the map (B5)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$in = '<!-- wp:navigation {\"ref\":77} /-->';
    \$out = sitegraft_core_wp_remap_nav_link_ids(['77' => '177'], \$in);
    if (strpos(\$out, '\"ref\":177') === false) { fwrite(STDERR, \"ref was not remapped: \$out\n\"); exit(1); }
    if (strpos(\$out, '\"ref\":77}') !== false) { fwrite(STDERR, \"old ref survived: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "_core_wp_nav_remap_php leaves ref untouched when it is 0 -- not a real wp_navigation post reference (B5)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$in = '<!-- wp:navigation {\"ref\":0} /-->';
    \$out = sitegraft_core_wp_remap_nav_link_ids(['0' => '999'], \$in);
    if (\$out !== \$in) { fwrite(STDERR, \"ref 0 was wrongly treated as a real wp_navigation reference: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "_core_wp_nav_remap_php's block-name match is EXACT -- a navigation-link block does not fall through to the ref rule via a substring match on its own name (B5)" {
  # Contrived but structurally reachable: a taxonomy-kind navigation-link
  # (correctly excluded from the id/kind rule above) that ALSO happens to
  # carry an unrelated "ref" field. If the block-name check for the "ref"
  # rule were ever loosened from an exact match to a substring test (both
  # "navigation-link" and "navigation" contain "navigation"), this exact
  # shape would fall through into it and get its "ref" wrongly rewritten.
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$in = '<!-- wp:navigation-link {\"label\":\"News\",\"type\":\"category\",\"id\":5,\"kind\":\"taxonomy\",\"ref\":77} /-->';
    \$out = sitegraft_core_wp_remap_nav_link_ids(['77' => '999'], \$in);
    if (strpos(\$out, '\"ref\":77') === false) { fwrite(STDERR, \"a stray ref on a taxonomy-kind navigation-link was wrongly remapped: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "_core_wp_nav_remap_php never confuses a bare wp:navigation block's ref with a wp:navigation-link's id -- the block-name match must be exact (B5)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    \$in = '<!-- wp:navigation-link {\"label\":\"Home\",\"type\":\"page\",\"ref\":77,\"id\":5,\"kind\":\"post-type\"} /-->';
    \$out = sitegraft_core_wp_remap_nav_link_ids(['5' => '205', '77' => '999'], \$in);
    if (strpos(\$out, '\"id\":205') === false) { fwrite(STDERR, \"id was not remapped: \$out\n\"); exit(1); }
    if (strpos(\$out, '\"ref\":77') === false) { fwrite(STDERR, \"a stray ref field on a navigation-link block was wrongly remapped: \$out\n\"); exit(1); }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# V14 (Viktor's review, mutation-proven): the original version of this test
# only asserted the id COUNT and that the old id was gone -- it never
# checked that the submenu's OPENING tag stayed an opening tag. A mutant
# that hardcodes $close = '/' unconditionally survived the entire suite:
# under that mutant, the submenu's opening `-->` becomes a self-closing
# `/-->`, its child navigation-link falls OUTSIDE the (now empty) submenu,
# and the real `<!-- /wp:navigation-submenu -->` further down becomes an
# orphaned, unmatched closing tag -- a structurally broken submenu that
# both of the original assertions still read as a pass (both ids were
# still 209, the old id was still gone). Fixed by asserting the exact,
# byte-precise structure: the submenu's own tag must still be a real
# OPENING tag (ends in a bare "-->" it shares with nothing else, never
# "/-->"), and it must appear BEFORE the child link, which must appear
# BEFORE the literal closing tag -- the actual nesting the mutant breaks.
@test "_core_wp_nav_remap_php remaps navigation-submenu ids too, and its nested navigation-link children, WITHOUT corrupting the submenu's open/close nesting (#17)" {
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
    // The decisive structural check: the submenu's OWN opening tag must
    // still end in a bare '} -->', never a self-closing '} /-->'.
    \$submenu_open_pos = strpos(\$out, '\"kind\":\"post-type\"} -->');
    if (\$submenu_open_pos === false) { fwrite(STDERR, \"the submenu's opening tag is no longer a real (non-self-closing) opener: \$out\n\"); exit(1); }
    \$child_pos = strpos(\$out, '\"label\":\"Child\"');
    \$close_pos = strpos(\$out, '<!-- /wp:navigation-submenu -->');
    if (\$close_pos === false) { fwrite(STDERR, \"the literal closing tag is missing: \$out\n\"); exit(1); }
    if (! (\$submenu_open_pos < \$child_pos && \$child_pos < \$close_pos)) { fwrite(STDERR, \"nesting order is broken (open=\$submenu_open_pos child=\$child_pos close=\$close_pos): \$out\n\"); exit(1); }
    // And the whole thing round-trips byte-identically to the input with
    // only the two ids changed -- the strongest form of this check.
    \$expected = str_replace('\"id\":9', '\"id\":209', \$in);
    if (\$out !== \$expected) { fwrite(STDERR, \"output diverges from input beyond the id substitution
expected: \$expected
actual:   \$out\n\"); exit(1); }
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

# B3 (Viktor's review, execution-proven): WordPress's OWN serializer
# (serialize_block_attributes(), wp-includes/blocks.php) does NOT hand a
# block's attrs to a bare json_encode() and call it done -- verified
# directly against wp-includes/blocks.php's real source: it calls
# wp_json_encode($attrs, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)
# (wp_json_encode falls through to plain json_encode with the same flags
# whenever encoding succeeds -- checked against wp-includes/functions.php),
# THEN runs the result through strtr() replacing a literal backslash,
# "--", "<", ">", "&" and an escaped quote with their \uXXXX forms. That
# second pass exists specifically so none of those characters can ever
# collide with the HTML-comment grammar (`<!-- ... -->`) a block is
# embedded in. Our own PHP function's original `json_encode( $attrs )` did
# none of this -- so a label containing literal "-->" survived the
# round-trip as a literal "-->", landing INSIDE the rewritten block's own
# JSON attrs, ahead of the block's real closing delimiter. Reproduced live
# before this fix: fed realistic WP-escaped input (a label WordPress itself
# would have written as -->), remapped the id, and the
# output no longer matched WHAT WORDPRESS'S OWN PARSER NEEDS TO SEE -- a
# subsequent parse_blocks() call (Site Editor, front-end render, anything)
# would read the first literal "-->" it finds as the block's real end,
# truncating the JSON attrs mid-string and leaking the rest of the intended
# attrs (and whatever followed) into the rendered page as plain text.
#
# This test builds its "expected" output using the SAME algorithm WordPress
# itself uses (copied verbatim from wp-includes/blocks.php, not
# reverse-engineered from our own code), so it is a genuine oracle, not a
# tautology against our own implementation.
_wp_serialize_block_attributes_oracle() {
  cat <<'PHP'
function wp_serialize_block_attributes_oracle( $attrs ) {
	$encoded = json_encode( $attrs, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE );
	return strtr(
		$encoded,
		array(
			'\\\\' => '\\u005c',
			'--'   => '\\u002d\\u002d',
			'<'    => '\\u003c',
			'>'    => '\\u003e',
			'&'    => '\\u0026',
			'\\"'  => '\\u0022',
		)
	);
}
PHP
}

@test "_core_wp_nav_remap_php escapes its rewritten attrs exactly the way WordPress's own serialize_block_attributes() does -- '&', '<', '>', '-->' must never leak into the block comment raw (B3)" {
  _php_available || skip "php CLI not available in this environment"
  local phpfile="$BATS_TEST_TMPDIR/remap.php"
  { echo '<?php'; _core_wp_nav_remap_php; _wp_serialize_block_attributes_oracle; } > "$phpfile"
  run php -r "
    require '${phpfile}';
    // The label WordPress itself would have written for this exact
    // attrs array, escaped by the real algorithm above -- this is what a
    // genuine wp:navigation-link block on a real site looks like on disk.
    \$attrs_before = ['label' => 'Über uns & Team --> <script>', 'type' => 'page', 'id' => 5, 'kind' => 'post-type'];
    \$attrs_json_before = wp_serialize_block_attributes_oracle(\$attrs_before);
    \$in = '<!-- wp:navigation-link ' . \$attrs_json_before . ' /-->';

    \$out = sitegraft_core_wp_remap_nav_link_ids(['5' => '205'], \$in);

    // What WordPress itself would have written for the SAME attrs, id
    // remapped -- the true oracle for this test.
    \$attrs_after = \$attrs_before; \$attrs_after['id'] = 205;
    \$attrs_json_after = wp_serialize_block_attributes_oracle(\$attrs_after);
    \$expected = '<!-- wp:navigation-link ' . \$attrs_json_after . ' /-->';

    if (\$out !== \$expected) {
      fwrite(STDERR, \"MISMATCH\nexpected: \$expected\nactual:   \$out\n\");
      exit(1);
    }
    // The decisive check B3 is actually about: no literal '-->' may
    // appear anywhere before the block's REAL closing delimiter -- a
    // corrupted comment truncates right there regardless of what the
    // rest of this test asserts.
    \$first_close = strpos(\$out, '-->');
    \$real_close = strlen(\$out) - 3;
    if (\$first_close !== \$real_close) {
      fwrite(STDERR, \"a '-->' leaked INSIDE the block comment at offset \$first_close (real close is at \$real_close): \$out\n\");
      exit(1);
    }
    echo 'OK';
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
