# tests/unit/test_graft_options.bats — graft_migrate_options (design doc
# §6.4 step 8 / review finding A1): fetches every migrate.*.option_keys from
# A, writes each to disk (for core_wp_post_import, §9.3), and pushes every
# key EXCEPT page_on_front/page_for_posts straight to B.
setup() {
  load '../../lib/core.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

@test "graft_migrate_options writes an option file per key and skips page_on_front for direct push" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["show_on_front","page_on_front"]}}}'
  SITE_A_WP_PATH="/site-a"; SITE_A_WP_CMD="wp"; SITEGRAFT_DRY_RUN=1
  wp_remote() { # stub: pretend A always returns a fixed JSON value for any option
    if [ "$1" = "a" ]; then echo '"stub-value"'; fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [ -f "${run_dir}/option-show_on_front.value" ]
  [ -f "${run_dir}/option-page_on_front.value" ]
}

@test "graft_migrate_options pushes a non-front-page key directly to B" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["show_on_front"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      echo '"page"'
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [[ "$output" == *"option update show_on_front"* ]] || false
}

@test "graft_migrate_options never pushes page_on_front/page_for_posts directly (remapped by core_wp_post_import instead)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["page_on_front","page_for_posts"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      echo '"5"'
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [[ "$output" != *"option update page_on_front"* ]] || false
  [[ "$output" != *"option update page_for_posts"* ]] || false
  [ "$(cat "${run_dir}/option-page_on_front.value")" = '"5"' ]
}

# MAJOR-2 (review, Viktor): rebuilt from a whole-content-tables
# `wp search-replace` (which put a protected plugin's own wp_options/
# wp_postmeta rows in scope) to a post_content/post_excerpt-only rewrite of
# exactly the posts THIS run migrated, via a pushed JSON payload + a single
# `wp eval` — same restructuring as graft_remap_attachment_ids
# (tests/unit/test_graft_remap.bats has the fuller comment on why).

@test "graft_search_replace_domain is a no-op when domain_from is empty or id-map.tsv has no rows" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_search_replace_domain "" "https://b.example.com" "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false

  : > "$tsv"
  run graft_search_replace_domain "https://a.example.com" "https://b.example.com" "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# --- issue #73: "unknown" and from==to are NOT the same as an empty from —
# both are non-empty, both used to slip past the guard above, and both used
# to run a REAL search-replace pass (rewriting "unknown" to "unknown", or a
# domain to itself) that changed nothing on B while reporting success.
# manifest_validate (lib/manifest.sh) is meant to catch both before a
# manifest is ever frozen; this is the second guard, for a manifest that
# reaches graft without passing through that gate.

@test "graft_search_replace_domain refuses (fails loud, never a silent no-op success) when from is the literal placeholder 'unknown' (#73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_search_replace_domain "unknown" "unknown" "$tsv" "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"unknown"* ]] || false
}

@test "graft_search_replace_domain refuses (fails loud) when from equals to — a real domain that could never rewrite anything (#73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_search_replace_domain "https://same.example.com" "https://same.example.com" "$tsv" "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# --- BLOCKER-1 (second review round): `from` real, `to` broken — A's scan
# succeeded, B's failed. Neither "from is empty" nor "from is unknown" nor
# "from equals to" catches this: `from` is a genuine domain and `to` is
# independently broken. Before this fix, this ran a REAL search-replace
# pass that rewrote A's domain to the literal text "unknown" (or to an
# empty string) across every migrated page — corrupting content instead of
# leaving it untouched, and still reporting success.

@test "graft_search_replace_domain refuses when from is real but to is empty (BLOCKER-1, #73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_search_replace_domain "https://a.example.com" "" "$tsv" "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"to is empty"* ]] || false
}

@test "graft_search_replace_domain refuses when from is real but to is 'unknown' (BLOCKER-1, #73 — the actual reproduction: A's scan succeeded, B's failed)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_search_replace_domain "https://a.example.com" "unknown" "$tsv" "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"unknown"* ]] || false
}

@test "graft_migrate_options refuses when domain_from is real but domain_to is 'unknown' — no in-function guard existed at all before this fix (MAJOR-1/BLOCKER-1, #73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["etch_settings"]}}}'
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "unknown"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
  [[ "$output" == *"unknown"* ]] || false
}

@test "graft_migrate_options is unaffected (no guard fires) when domain_from is empty — no domain configured is still a legitimate no-op (#73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["show_on_front"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() { local alias_lc="$1"; if [ "$alias_lc" = "a" ]; then echo '"page"'; fi; }
  run graft_migrate_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
}

# --- MAJOR-1 (second review round): the in-function guards above are not
# enough by themselves — graft_verify_domain_remap_usable is what
# phase_graft now calls UNCONDITIONALLY, before either consumer, so no
# resume marker can skip it (see lib/graft.sh's own comment on that
# function for the full reproduction). Tested directly here since it's now
# its own named function.

@test "graft_verify_domain_remap_usable passes (no-op) when domain_from is empty" {
  run graft_verify_domain_remap_usable "" "unknown"
  [ "$status" -eq 0 ]
}

@test "graft_verify_domain_remap_usable refuses when from is real but to is broken (MAJOR-1/BLOCKER-1, #73)" {
  run graft_verify_domain_remap_usable "https://a.example.com" "unknown"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]] || false
}

@test "graft_verify_domain_remap_usable passes when both from and to are real and distinct" {
  run graft_verify_domain_remap_usable "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
}

@test "graft_search_replace_domain's payload carries from/to and every migrated post id, never a table name" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  local captured="$BATS_TEST_TMPDIR/captured.json"
  graft_push_remap_payload() { printf '%s' "$2" > "$captured"; echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  wp_remote() { echo "sitegraft: domain-remap rewrote 0 post(s)"; }
  graft_remove_file() { :; }
  run graft_search_replace_domain "https://a.example.com" "https://b.example.com" "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  run jq -e '.from == "https://a.example.com" and .to == "https://b.example.com"' "$captured"
  [ "$status" -eq 0 ]
  run jq -e '.post_ids == ["42","105"]' "$captured"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--tables"* ]] || false
}

# Issue #98: graft_migrated_post_ids_json (shared with graft_remap_
# attachment_ids) excludes `term:` rows -- their column 2 is a TERM id, not
# a post id (independent, both-start-at-1 sequences), so an unexcluded term
# row could put a coincidentally-matching, unrelated real post's id into
# this function's post_ids scope, and `wp search-replace` would then touch
# that out-of-scope post's content -- exactly what MAJOR-2's rebuild (this
# file's own header comment) says is structurally unreachable. wp_navigation
# rows stay included (unlike graft_remap_attachment_ids' own, differently-
# scoped post_ids_json): a domain leak inside a navigation-link's custom URL
# genuinely needs the same search-replace every other migrated post gets.
# Mutation-tested: drop the `$3 !~ /^term:/` filter from
# graft_migrated_post_ids_json and this goes RED -- "14" reappears in
# .post_ids alongside the three real rows.
@test "graft_search_replace_domain's payload excludes term: rows from post_ids, but keeps wp_navigation rows (#98)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n3\t14\tterm:category\n77\t177\twp_navigation\n5\t105\tpage\n' > "$tsv"
  local captured="$BATS_TEST_TMPDIR/captured.json"
  graft_push_remap_payload() { printf '%s' "$2" > "$captured"; echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  wp_remote() { echo "sitegraft: domain-remap rewrote 0 post(s)"; }
  graft_remove_file() { :; }
  run graft_search_replace_domain "https://a.example.com" "https://b.example.com" "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  run jq -e '.post_ids == ["42","177","105"]' "$captured"
  [ "$status" -eq 0 ]
}

@test "graft_search_replace_domain's wp eval call requires the shared content-remap library and calls its function, never a table-wide search-replace" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t105\tpage\n' > "$tsv"
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  SITEGRAFT_DRY_RUN=1
  run graft_search_replace_domain "https://a.example.com" "https://b.example.com" "$tsv" "$run_dir"
  [[ "$output" == *"wp_remote b eval"* ]] || false
  [[ "$output" == *"require_once"* ]] || false
  [[ "$output" == *"sitegraft-content-remap-functions.php"* ]] || false
  [[ "$output" == *"sitegraft_remap_domain("* ]] || false
  # issue #43: writes via the shared sitegraft_write_remapped_post()
  # ($wpdb->update, never wp_update_post()) — this is the call site issue
  # #43 actually reproduces on: sitegraft_remap_domain writes the
  # JSON-escaped "https:\/\/" form, and wp_update_post( array(...) )
  # silently ate that backslash (never slashes the array form it's called
  # with, yet wp_insert_post() unconditionally unslashes before writing).
  # See tests/unit/test_content_remap_write.bats for the execution-level
  # proof this call site's actual generated PHP preserves them.
  #
  # The KEYED form (fix-pack round two, MAJOR-2 round two, Viktor): asserted
  # as the complete literal, not just the bare function name. A bare
  # `sitegraft_write_remapped_post(` match is blind to arguments -- Viktor
  # swapped $content/$excerpt at graft_remap_attachment_ids' call site
  # TWICE (once against the original 5-positional-argument form, once
  # against the first fix-pack's ($post, $content, $excerpt) form) and both
  # times every test in this suite that only matched the function name
  # stayed green. This is belt-and-suspenders on top of the real,
  # structural fix (the keyed array itself, in
  # lib/php/content-remap-functions.php's own sitegraft_write_remapped_post
  # -- see its docblock for why that closes the swap off at the one place
  # it's actually possible): this assertion re-reds if a future edit
  # reverts to two bare positional strings here.
  [[ "$output" == *'sitegraft_write_remapped_post( $post, array( "post_content" => $content, "post_excerpt" => $excerpt ) )'* ]] || false
  [[ "$output" != *"wp_update_post"* ]] || false
  # the substitution itself must live in the required file, not inline here
  [[ "$output" != *'str_replace( "/", "\\/", $from )'* ]] || false
  [[ "$output" != *"search-replace"* ]] || false
}

@test "graft_migrate_options also rewrites the domain string inside a migrated option's own value, scoped only to that explicitly-listed key" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_styles"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      echo '{"logo_url":"https://a.example.com/logo.png","escaped":"https:\/\/a.example.com\/x"}'
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  local stored; stored=$(cat "${run_dir}/option-etch_styles.value")
  [[ "$stored" == *"https://b.example.com/logo.png"* ]] || false
  # Test-quality fix-pack bug found live (this assertion was silently never
  # enforced before the fix-pack's `[[ ]] || false` pass — see the file's
  # own note on the bash 3.2 [[ ]]-under-set-e quirk): the ORIGINAL
  # assertion here checked for the literal escaped-slash text
  # 'https:\/\/b.example.com\/x' — but graft_migrate_options' domain rewrite
  # always re-serializes via jq (`jq -c ... walk(replace_domain)`), and jq
  # does NOT escape "/" on output by default (same documented fact
  # verify_options_match's own tests rely on) — REGARDLESS of whether the
  # INPUT JSON had it escaped. The stored value was always going to come
  # out with a plain, unescaped slash; asserting otherwise was asserting an
  # implementation detail that can never be true, not a real requirement.
  # What actually matters (and is what a downstream `wp option update
  # --format=json` correctly parses either way, since escaping "/" is
  # OPTIONAL in JSON, not required) is that the DECODED value is right —
  # checked here via jq, the same "compare decoded, not raw text"
  # discipline verify_options_match's own tests already established.
  run jq -e '.escaped == "https://b.example.com/x"' <<< "$stored"
  [ "$status" -eq 0 ]
  [[ "$stored" != *"a.example.com"* ]] || false
}

# Issue #83's own detection half, not just its sync half (docs/status.md's
# own record of the real pilot: `etch_global_stylesheets` had to be fixed
# BY HAND after a graft that reported success, because the jq rewrite pass
# above never reached it).
#
# Review fix-pack, decided together (not reopened here): this is now a
# WARNING (`log_warn`), never a refusal -- no flag in this CLI can skip a
# single option key, this function runs AFTER the WXR import, so a refusal
# abandons a half-migrated B with every resume replaying the same refusal,
# and the old message pointed an operator at hand-editing A's production
# database, which is not practicable mid-migration. In exchange the check
# is now WIDE: case-insensitive, scheme-agnostic (http/https/protocol-
# relative), and matched on raw bytes rather than decoded JSON structure,
# so it reaches a domain reference buried inside a JSON blob that is
# itself stored as a STRING value.
#
# This fixture is real `php json_encode()` output, not a hand-fabricated
# string `--format=json` never produces (the exact gap review flagged
# before this fix-pack): Etch stores `etch_global_stylesheets` as a JSON
# blob inside a STRING option value (not a native PHP array WordPress
# would decode on its own), so `wp option get --format=json` runs
# `json_encode()` TWICE — once implicitly already baked into the stored
# string, once again to transport the option's own string value. The
# result: every `/` the pilot's own CSS URL contains is escaped TWICE
# (`\\\/` in the raw wp-cli output), a shape the rewrite's `jq ...
# split($from)` — which only ever looks for the PLAIN, once-escaped
# `https://a.example.com` — genuinely cannot match. Verified directly
# (measured outside this test, not merely asserted): piping this exact
# fixture through the real rewrite pass leaves `a.example.com` in the
# pushed value and never introduces `b.example.com` at all -- the rewrite
# is a full no-op on this shape. `php` generates the fixture at test time
# so its exact escaping is never hand-transcribed (and cannot drift from
# what real `json_encode()` produces).
@test "graft_migrate_options WARNS (but still pushes to B) when Etch's own JSON-blob-stored-as-a-string shape survives the rewrite pass — issue #83 review fix-pack, realistic php json_encode fixture" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_global_stylesheets"]}}}'
  SITEGRAFT_DRY_RUN=1
  local fixture
  fixture=$(php -r 'echo json_encode(json_encode(["css" => "body{src:url(https://a.example.com/wp-content/fonts/heading-sans.woff2)}"]));')
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      printf '%s' "$fixture"
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"etch_global_stylesheets"* ]] || false
  [[ "$output" == *"WARNING, not a refusal"* ]] || false
  # Still pushed -- this is the whole point of the warning/refusal trade:
  # the write is NOT blocked, and the option's own cache file IS written
  # (core_wp_post_import's own --dry-run preview, §9.3, still needs it).
  [[ "$output" == *"[dry-run] wp_remote b option update etch_global_stylesheets"* ]] || false
  [ -f "${run_dir}/option-etch_global_stylesheets.value" ]
}

@test "graft_migrate_options WARNS on a protocol-relative reference to A's host that the rewrite's exact-scheme match cannot see (realistic php json_encode fixture)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["some_key"]}}}'
  SITEGRAFT_DRY_RUN=1
  local fixture
  fixture=$(php -r 'echo json_encode(["logo" => "//a.example.com/logo.png"]);')
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then printf '%s' "$fixture"; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING, not a refusal"* ]] || false
}

@test "graft_migrate_options WARNS on the other scheme (http when domain_from says https) that the rewrite's exact-scheme match cannot see (realistic php json_encode fixture)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["some_key"]}}}'
  SITEGRAFT_DRY_RUN=1
  local fixture
  fixture=$(php -r 'echo json_encode(["logo" => "http://a.example.com/logo.png"]);')
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then printf '%s' "$fixture"; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING, not a refusal"* ]] || false
}

@test "graft_migrate_options WARNS on a differently-cased host that the rewrite's case-sensitive match cannot see (realistic php json_encode fixture)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["some_key"]}}}'
  SITEGRAFT_DRY_RUN=1
  local fixture
  fixture=$(php -r 'echo json_encode(["logo" => "https://A.EXAMPLE.COM/logo.png"]);')
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then printf '%s' "$fixture"; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING, not a refusal"* ]] || false
}

# Companion to the four warnings above: the SAME check must stay quiet
# when nothing of A's is left -- proven by mutation (this repo's own
# CLAUDE.md convention), not merely asserted. Removing the widened check
# entirely leaves this test green and the four above red; keeping it
# leaves all five green -- together they show the check discriminates
# rather than always firing.
@test "graft_migrate_options does NOT warn on a value the rewrite pass fully corrected (residue check stays quiet on a clean rewrite)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_global_stylesheets"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      echo '"https://a.example.com/wp-content/fonts/heading-sans.woff2"'
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING, not a refusal"* ]] || false
  [ -f "${run_dir}/option-etch_global_stylesheets.value" ]
}

@test "graft_migrate_options does NOT warn when domain_from and this option's value are simply unrelated (no coincidental match)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["blogdescription"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then echo '"Just another WordPress site"'; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING, not a refusal"* ]] || false
}

# Review, second round: measured as a SYSTEMATIC false positive, not an
# occasional one -- domain_from's host being a literal substring of
# domain_to's host is the ordinary apex/www migration shape ("example.com"
# -> "www.example.com"), and before this fix the check fired on it for
# EVERY key, every time, regardless of whether the rewrite actually
# missed anything. A warning that always fires is a warning nobody reads
# -- the exact opposite of what widening the check (BLOCKER 2) was for.
@test "graft_migrate_options does NOT warn when A's host is a substring of B's own host and the value was correctly rewritten (apex -> www, review fix-pack)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_global_stylesheets"]}}}'
  SITEGRAFT_DRY_RUN=1
  local fixture
  fixture=$(php -r 'echo json_encode(["css" => "body{src:url(https://www.example.com/wp-content/fonts/heading-sans.woff2)}"]);')
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then printf '%s' "$fixture"; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://example.com" "https://www.example.com"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING, not a refusal"* ]] || false
}

# The other half of the same fix, verified in the same shape: stripping
# B's own host from the value before searching must not also hide a
# GENUINE leftover reference to A that happens to sit in that exact
# apex/www pair -- only an actual occurrence of B's host is removed, an
# unrelated bare reference to A's host survives and is still caught.
@test "graft_migrate_options still WARNS on a genuine leftover reference to A even when A's host is a substring of B's own host (apex -> www, review fix-pack)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_global_stylesheets"]}}}'
  SITEGRAFT_DRY_RUN=1
  local fixture
  fixture=$(php -r 'echo json_encode(["css" => "body{src:url(//example.com/wp-content/fonts/heading-sans.woff2)}"]);')
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then printf '%s' "$fixture"; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://example.com" "https://www.example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING, not a refusal"* ]] || false
}

# --- Review, third round: the REVERSE direction ---------------------------
#
# domain_from's host ("www.example.com") is the LONGER one here, and
# domain_to's host ("example.com") is a substring of it -- the www ->
# apex consolidation, at least as common a real migration shape as the
# apex -> www direction above. Round 2's original fix (unconditionally
# stripping domain_to's host from the value before searching) is UNSAFE
# in exactly this direction: stripping "example.com" out of a genuine,
# never-rewritten "www.example.com" residue also eats the "example.com"
# tail of that SAME residue, leaving "www." behind and hiding the
# evidence -- measured to genuinely happen, not a hypothetical. These
# three tests are the regression guards for that: a real residue must
# still be caught (including the pilot's own JSON-blob-in-a-string
# shape, the reason this whole check exists), and a value that was
# ACTUALLY rewritten cleanly to the (shorter) apex must not warn.
@test "graft_migrate_options still WARNS on a genuine leftover reference to A when A's host is LONGER than B's own (www -> apex, review third round)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_global_stylesheets"]}}}'
  SITEGRAFT_DRY_RUN=1
  # Protocol-relative, same technique the apex -> www direction's own
  # "genuine leftover" test above uses (and for the identical reason): a
  # fixture with the FULL scheme ("https://www.example.com") is exactly
  # what the jq rewrite pass's own exact-substring match DOES catch and
  # correct on its own -- it would never reach this function's detection
  # code as a residue at all, so it would not actually exercise what this
  # test is for. Protocol-relative is one of the forms the rewrite cannot
  # reach (its own header comment), so it survives to be checked here.
  local fixture
  fixture=$(php -r 'echo json_encode(["css" => "body{src:url(//www.example.com/wp-content/fonts/heading-sans.woff2)}"]);')
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then printf '%s' "$fixture"; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://www.example.com" "https://example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING, not a refusal"* ]] || false
}

@test "graft_migrate_options still WARNS on the pilot's own JSON-blob-stored-as-a-string shape when A's host is LONGER than B's own (www -> apex, review third round)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_global_stylesheets"]}}}'
  SITEGRAFT_DRY_RUN=1
  local fixture
  fixture=$(php -r 'echo json_encode(json_encode(["css" => "body{src:url(https://www.example.com/wp-content/fonts/heading-sans.woff2)}"]));')
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then printf '%s' "$fixture"; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://www.example.com" "https://example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING, not a refusal"* ]] || false
}

@test "graft_migrate_options does NOT warn on a clean www -> apex rewrite (A's host LONGER than B's own, review third round)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_global_stylesheets"]}}}'
  SITEGRAFT_DRY_RUN=1
  local fixture
  fixture=$(php -r 'echo json_encode(["css" => "body{src:url(https://example.com/wp-content/fonts/heading-sans.woff2)}"]);')
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then printf '%s' "$fixture"; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://www.example.com" "https://example.com"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING, not a refusal"* ]] || false
}

# Direct unit coverage for the two small helpers themselves
# (lib/graft.sh), not just the end-to-end graft_migrate_options behavior
# above -- pins the two nits closed together (case-insensitivity, and
# glob-safety) independently of the length-conditional wiring around them.
@test "graft_ci_glob builds a case-insensitive, glob-escaped pattern that removes an UPPERCASE occurrence via graft_ci_remove_all" {
  run graft_ci_remove_all "prefix WWW.EXAMPLE.COM suffix" "www.example.com"
  [ "$status" -eq 0 ]
  [ "$output" = "prefix  suffix" ]
}

@test "graft_ci_remove_all treats the needle as a LITERAL string, not a glob -- a needle containing '*' does not act as a wildcard" {
  # A needle designed so a real (un-escaped) glob '*' would greedily
  # consume everything between its two literal ends ("a" ... "z"),
  # including the text this test's own assertions require to survive --
  # not just "does the literal needle still get removed" (which an
  # unescaped '*' also happens to do, so would not discriminate the bug).
  run graft_ci_remove_all "start aXXXz end, and a*z end2" "a*z"
  [ "$status" -eq 0 ]
  [ "$output" = "start aXXXz end, and  end2" ]
}

@test "graft_ci_remove_all is a no-op (returns the value unchanged) for an empty needle" {
  run graft_ci_remove_all "unchanged value" ""
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged value" ]
}

# Fix-pack bug found live (DDEV harness, MAJOR-B's new graft --dry-run
# assertion, running end to end for the first time): every other test in
# this file stubs wp_remote WITHOUT checking is_dry_run at all, so it
# always returns real canned data for "a" reads regardless of dry-run mode
# — which meant none of them ever actually exercised what the REAL
# wp_remote (lib/inventory.sh) does under --dry-run: wrap EVERY call,
# reads included, in run_or_echo, returning "[dry-run] wp_remote a option
# get ..." text instead of a real value. That garbage then hit `jq` in the
# domain-rewrite pass a few lines below graft_migrate_options' own read —
# jq errored (not valid JSON), and under this codebase's `set -euo
# pipefail`, that aborted the WHOLE graft with a bare, unlogged exit 5.
# This test's stub is deliberately is_dry_run-AWARE (mimicking exactly the
# real wp_remote/run_or_echo relationship, same technique as
# test_verify.bats' MAJOR-A regression tests) so it actually reproduces the
# failure before the fix and proves the fix after it: the read from A must
# return real data even under --dry-run (SITEGRAFT_DRY_RUN=0 is prefixed
# onto just that one call), while the write to B stays correctly simulated.
@test "graft_migrate_options reads A's real value even under --dry-run, so the domain-rewrite jq pass never chokes on dry-run-echo text (fix-pack regression)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_styles"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if is_dry_run; then
      echo "[dry-run] wp_remote ${alias_lc} $*"
      return 0
    fi
    if [ "$alias_lc" = "a" ]; then
      echo '{"logo_url":"https://a.example.com/logo.png"}'
    else
      echo "SHOULD NOT BE CALLED FOR REAL — the write to B must stay simulated under --dry-run"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest" "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  local stored; stored=$(cat "${run_dir}/option-etch_styles.value")
  [[ "$stored" == *"https://b.example.com/logo.png"* ]] || false
  [[ "$output" == *"[dry-run] wp_remote b"* ]] || false
  [[ "$output" != *"SHOULD NOT BE CALLED FOR REAL"* ]] || false
}

@test "graft_prune_previous_run deletes every post carrying _sitegraft_source_id from a prior run" {
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$1" = "post" ] && [ "$2" = "list" ]; then
      printf '5\n7\n'
    else
      echo "[dry-run] wp_remote $alias_lc $*"
    fi
  }
  run graft_prune_previous_run "page,post"
  [[ "$output" == *"post delete 5"* ]] || false
  [[ "$output" == *"post delete 7"* ]] || false
}

@test "graft_prune_previous_run is a no-op when the post_types list is empty" {
  SITEGRAFT_DRY_RUN=1
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run graft_prune_previous_run ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# N3 (third review round). `value=$(... option get ... || echo 'null')`
# wrote the LITERAL string `null` for any key A does not have — and then
# pushed it to B. Concretely: A has no Loop Manager, so A has no `etch_cfs`;
# the manifest still lists the key (etch_option_keys is a static allowlist);
# graft therefore ran `option update etch_cfs null` on B and ERASED B's own
# value. The same mechanism core_wp_option_keys_dynamic's own header comment
# already warns about ("claiming a key A does not have would BLANK B's own
# theme_mods") — documented there, unguarded here.
@test "graft_migrate_options skips a key A does not have instead of writing the literal null onto B (N3)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings","etch_cfs"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then
      case "$*" in
        "option get etch_cfs --format=json") return 1 ;;   # A simply has no such option
        *) echo '"real-value"' ;;
      esac
    else
      echo "[dry-run] wp_remote b $*"
    fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"option update etch_settings"* ]] || false
  [[ "$output" != *"option update etch_cfs"* ]] || false
  [[ "$output" == *"etch_cfs"* ]] || false            # said out loud, not dropped silently
  [ ! -f "${run_dir}/option-etch_cfs.value" ]         # and no `null` left on disk either
}

# B4 (third review round, second reviewer), graft-side half. manifest_validate now
# rejects such a name too, but a manifest hand-edited AFTER being frozen never
# passes through validation again — and this loop writes to B's live database.
# The test is written so BOTH halves of the fix are load-bearing: with the
# guard removed it exits 0, and with the fd-3 read loop reverted to
# `for key in $(...)` the name splits into "two"/"words" (neither of which
# trips the guard) and B gets two `option update` calls nobody planned.
@test "graft_migrate_options refuses a manifest option key carrying whitespace, and never word-splits it into two keys (B4)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"demo":{"option_keys":["two words"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then echo '"v"'; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [ "$status" -ne 0 ]
  [[ "$output" != *"option update two "* ]] || false
  [[ "$output" != *"option update words"* ]] || false
}

# Nit 3 / mutant G1 (third review round, second reviewer): a manifest whose
# migrate entries carry no option_keys at all — the ordinary case for a
# content-only module — makes `jq -r '[…] | unique[]'` print nothing, and the
# read loop then sees a single empty line. Removing `[ -n "$key" ] || continue`
# left the suite green, so nothing proved the empty case was handled: without
# it, `wp option get ''` runs and, on the fd-3 loop, an empty key would reach
# B as `option update ''`.
@test "graft_migrate_options does nothing at all for a manifest with no option keys (nit 3)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"post_types":["page"]}}}'
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$alias_lc" = "a" ]; then echo '"v"'; else echo "[dry-run] wp_remote b $*"; fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" != *"option update"* ]] || false
  [ -z "$(ls -A "$run_dir")" ]
}

# Nat feedback (live DDEV run): the message a refused domain remap prints
# must tell the operator HOW to fix it, not just that it's broken -- a
# proxied/tunneled site (DDEV, an SSH tunnel, a reverse proxy) has scan
# record its OWN internal address, not the public domain visitors use, and
# re-scanning just records the same wrong value again.
@test "graft_search_replace_domain's refusal names the hand-edit escape hatch, not just 're-scan' (Nat feedback, #73)" {
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"; printf '5\t105\tpage\n' > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_search_replace_domain "unknown" "https://b.example.com" "$tsv" "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SITE_A_URL"* ]] || false
  [[ "$output" == *"hand-edit"* ]] || false
  [[ "$output" == *"ddev.site"* ]] || false
}
