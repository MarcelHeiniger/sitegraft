# tests/unit/test_graft_remap.bats — the two-pass sentinel ID remap (design
# doc §9.1). lib/backup.sh is loaded because graft_push_remap_payload (used
# by the real, non-stubbed graft_remap_attachment_ids/graft_search_replace_domain)
# calls graft_local_prefix, which reuses _backup_local_exec_prefix.
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

# graft_build_sentinel_commands's own tests used to live here — removed
# (review, Viktor, NIT-1) along with the function itself: it went orphaned
# the moment graft_remap_attachment_ids stopped calling it (MAJOR-2
# fix-pack, below). The two-pass sentinel logic itself moved to
# lib/php/content-remap-functions.php — see
# tests/unit/test_content_remap_functions.bats for its real, isolated test
# coverage (including a mutation-tested negative-lookahead check), which the
# old bash-string-building tests here never actually exercised (they only
# ever asserted the printf'd COMMAND text, never ran a real substitution).

# MAJOR-2 (review, Viktor): `wp search-replace` has no row-level scoping —
# scoping to content TABLES (posts/postmeta/options) still put every row of
# those tables in scope, including a protected plugin's own settings.
# graft_remap_attachment_ids/graft_search_replace_domain are now rebuilt to
# push a small JSON payload (attachment map + the list of THIS run's
# migrated post IDs) and rewrite exactly those posts' post_content/
# post_excerpt via a single `wp eval`. graft_push_remap_payload is stubbed
# below purely to intercept and inspect the payload's SHAPE without needing
# a real file transfer — the DDEV harness (tests/integration/ddev-harness.sh)
# is what proves the real transfer + eval round-trip end-to-end.

@test "graft_remap_attachment_ids is a no-op when id-map.tsv has no attachment rows" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '5\t99\tpage\n' > "$tsv"
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_remap_attachment_ids "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# Fix-pack bug found live (DDEV harness, MAJOR-B's new dry-run assertion,
# running graft --dry-run against a genuinely fresh run directory):
# graft_fetch_id_map deliberately never creates id-map.tsv under --dry-run
# (its writes are correctly run_or_echo-wrapped), so on a first-time dry
# run the file doesn't exist at all — not merely empty. `[ -s ... ]`
# already covers this for graft_remap_attachment_ids (both "missing" and
# "empty" read as false), but it's worth a dedicated test asserting the
# genuinely-missing-file case specifically, since that's the exact
# real-world shape of the bug (not just "empty file", which behaves
# identically under -s but wasn't what actually happened live).
@test "graft_remap_attachment_ids is a no-op when id-map.tsv does not exist at all yet (not just empty) — first-time --dry-run case" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  [ ! -e "$tsv" ]
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_payload() { echo "SHOULD NOT BE CALLED"; }
  graft_push_remap_lib() { echo "SHOULD NOT BE CALLED"; }
  run graft_remap_attachment_ids "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "graft_remap_attachment_ids's payload contains exactly the attachment old->new pairs and every migrated post id, never a table name" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local captured="$BATS_TEST_TMPDIR/captured.json"
  graft_push_remap_payload() { printf '%s' "$2" > "$captured"; echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  wp_remote() { echo "sitegraft: id-remap rewrote 0 post(s)"; }
  graft_remove_file() { :; }
  run graft_remap_attachment_ids "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  run jq -e '.attachments == [{"old":"10","new":"42"}]' "$captured"
  [ "$status" -eq 0 ]
  run jq -e '.post_ids == ["42","105"]' "$captured"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--tables"* ]] || false
}

# B2 (Viktor's review of PR #38/#17, execution-proven): wp_navigation posts
# entered id-map.tsv for the first time once #17 started migrating them, and
# graft_migrated_post_ids_json (used by graft_search_replace_domain too, and
# correctly unfiltered THERE — a domain leak inside a navigation-link's
# custom-URL is exactly the kind of thing that DOES need remapping) takes
# EVERY row regardless of post_type. sitegraft_remap_attachment_refs
# (lib/php/content-remap-functions.php) substitutes `"id":<old>` for every
# ATTACHMENT old id, with zero awareness of a navigation-link's own "kind"
# attribute -- so a "kind":"taxonomy" link whose id happens to numerically
# collide with a migrated ATTACHMENT's old id gets its TERM id silently
# replaced with the attachment's NEW id. Proved live: a "kind":"taxonomy"
# navigation-link with id 5, and an attachment also carrying old id 5
# (term ids and attachment/post ids are two independent sequences that both
# start at 1 on a fresh WordPress site, so this is a real, not remote,
# collision), comes out with the attachment's NEW id instead of its own
# untouched term id. modules/core-wp.sh's own _core_wp_remap_nav_page_ids
# (which runs AFTER this function, in the module post_import step) cannot
# repair this: it only ever touches "kind":"post-type" entries by design
# (the same ambiguity-safety reasoning), so a taxonomy-kind corruption
# introduced here survives untouched. wp_navigation posts are excluded from
# THIS function's post_ids scope specifically -- not from
# graft_migrated_post_ids_json itself, which graft_search_replace_domain
# still needs unfiltered.
@test "graft_remap_attachment_ids excludes wp_navigation posts from its post_ids scope -- a navigation-link's taxonomy-kind id must never be corrupted by an unrelated attachment remap (B2)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10	42	attachment
77	177	wp_navigation
5	105	page
' > "$tsv"
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local captured="$BATS_TEST_TMPDIR/captured.json"
  graft_push_remap_payload() { printf '%s' "$2" > "$captured"; echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  wp_remote() { echo "sitegraft: id-remap rewrote 0 post(s)"; }
  graft_remove_file() { :; }
  run graft_remap_attachment_ids "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  # Attachment rows' OWN new ids legitimately stay in post_ids (unchanged,
  # pre-existing behavior -- an attachment's own post_content/post_excerpt
  # can reference OTHER attachments, e.g. a media description). Only the
  # wp_navigation row's new id (177) is excluded.
  run jq -e '.post_ids == ["42","105"]' "$captured"
  [ "$status" -eq 0 ]
}

@test "graft_remap_attachment_ids's wp eval call requires the shared content-remap library and calls its function, never a table-wide search-replace" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n' > "$tsv"
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  graft_push_remap_payload() { echo "/fake/remote/path.json"; }
  graft_push_remap_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
  SITEGRAFT_DRY_RUN=1
  run graft_remap_attachment_ids "$tsv" "$run_dir"
  [[ "$output" == *"wp_remote b eval"* ]] || false
  [[ "$output" == *"require_once"* ]] || false
  [[ "$output" == *"sitegraft-content-remap-functions.php"* ]] || false
  [[ "$output" == *"sitegraft_remap_attachment_refs("* ]] || false
  # issue #43: writes via the shared sitegraft_write_remapped_post()
  # ($wpdb->update, never wp_update_post()) — wp_update_post( array(...) )
  # never slashes the array form it's called with here, yet
  # wp_insert_post() unconditionally unslashes before writing, silently
  # eating every backslash the domain/id remap wrote. See
  # tests/unit/test_content_remap_write.bats for the execution-level
  # proof this call site's actual generated PHP preserves them.
  #
  # The KEYED form (fix-pack round two, MAJOR-2 round two, Viktor): asserted
  # as the complete literal, not just the bare function name. A bare
  # `sitegraft_write_remapped_post(` match is blind to arguments -- Viktor
  # swapped $content/$excerpt at this exact call site TWICE (once against
  # the original 5-positional-argument form, once against the first
  # fix-pack's ($post, $content, $excerpt) form) and both times every test
  # in this suite that only matched the function name stayed green. This is
  # belt-and-suspenders on top of the real, structural fix (the keyed array
  # itself, in lib/php/content-remap-functions.php's own
  # sitegraft_write_remapped_post -- see its docblock for why that closes
  # the swap off at the one place it's actually possible): this assertion
  # re-reds if a future edit reverts to two bare positional strings here.
  [[ "$output" == *'sitegraft_write_remapped_post( $post, array( "post_content" => $content, "post_excerpt" => $excerpt ) )'* ]] || false
  [[ "$output" != *"wp_update_post"* ]] || false
  # the substitution itself must live in the required file, not inline here
  [[ "$output" != *"preg_replace"* ]] || false
  [[ "$output" != *"search-replace"* ]] || false
}

# --- issue #88: the cheap interim "decided but text unchanged" guard ------
#
# graft_remap_attachment_ids's own eval script already knows, for every
# (post, old attachment id) pair, that it decided that id might need
# remapping -- it is iterating payload["attachments"], built from exactly
# the ids this run migrated. If that old id is still textually present,
# digit-bounded, in the post's own content/excerpt AFTER
# sitegraft_remap_attachment_refs ran on it, that is a case this pass tried
# to fix and apparently did not (an unrecognized JSON formatting) --
# reported as a named WARNING rather than nothing at all.
#
# Run via a REAL `php` execution of the CAPTURED eval text (never a
# hand-copied reimplementation of it) against a tiny stub WordPress, same
# discipline as tests/unit/test_content_remap_write.bats and
# modules/etch.sh's own _etch_run_captured_php[_multi].

# _graft_run_captured_remap_eval <wp_content_dir> <post_id> <content> <excerpt>
# -- executes the REAL PHP text captured at "$BATS_TEST_TMPDIR/eval.php" by
# a `wp_remote` stub (set up by the caller), against a stub get_post()/
# $wpdb, with WP_CONTENT_DIR pointed at a temp dir already carrying a copy
# of the real lib/php/content-remap-functions.php (named the same way
# graft_push_remap_lib's real transfer names it on B) and the real payload
# JSON graft_push_remap_payload was asked to push. Prints "WRITTEN:<content
# $wpdb->update() was actually called with, or NO-WRITE>" followed by
# whatever else the eval script itself echoed (the UNMATCHED-guard's
# WARNING line, or the final "rewrote N post(s)" line).
_graft_run_captured_remap_eval() {
  local wp_content="$1" post_id="$2" content="$3" excerpt="$4"
  php -r '
    define("WP_CONTENT_DIR", $argv[1]);
    $test_post_id = (int) $argv[2];
    $test_content = $argv[3];
    $test_excerpt = $argv[4];
    function get_post( $id ) {
      global $test_post_id, $test_content, $test_excerpt;
      if ( (int) $id !== $test_post_id ) { return null; }
      return (object) [ "ID" => $test_post_id, "post_content" => $test_content, "post_excerpt" => $test_excerpt ];
    }
    function clean_post_cache( $id ) {}
    class _GraftTestWpdb {
      public $posts = "wp_posts";
      public $last_update = null;
      public function update( $table, $data, $where ) {
        $this->last_update = $data;
        return 1;
      }
    }
    $GLOBALS["wpdb"] = new _GraftTestWpdb();
    ob_start();
    eval( file_get_contents( $argv[5] ) );
    $echoed = ob_get_clean();
    $written = ( $GLOBALS["wpdb"]->last_update !== null ) ? $GLOBALS["wpdb"]->last_update["post_content"] : "NO-WRITE";
    echo "WRITTEN:" . $written . "\n";
    echo $echoed;
  ' -- "$wp_content" "$post_id" "$content" "$excerpt" "$BATS_TEST_TMPDIR/eval.php"
}

# _graft_remap_setup_capture <run_dir> <wp_content_dir> <tsv> -- stubs
# graft_push_remap_payload/graft_push_remap_lib/graft_remove_file/wp_remote
# so that calling the REAL graft_remap_attachment_ids writes the REAL
# payload JSON it builds and a real copy of the remap library into
# <wp_content_dir> (exactly where the eval script it hands to `wp_remote`
# expects to find them via WP_CONTENT_DIR), and captures that eval script
# itself at "$BATS_TEST_TMPDIR/eval.php" for _graft_run_captured_remap_eval
# to execute afterward.
_graft_remap_setup_capture() {
  local wp_content="$1"
  mkdir -p "$wp_content"
  graft_push_remap_payload() { printf '%s' "$2" > "${wp_content}/sitegraft-id-remap-payload.json"; echo "${wp_content}/sitegraft-id-remap-payload.json"; }
  graft_push_remap_lib() { cp "${REPO_ROOT}/lib/php/content-remap-functions.php" "${wp_content}/sitegraft-content-remap-functions.php"; echo "${wp_content}/sitegraft-content-remap-functions.php"; }
  graft_remove_file() { :; }
  wp_remote() {
    if [ "$2" = "eval" ]; then printf '%s' "$3" > "$BATS_TEST_TMPDIR/eval.php"; fi
    echo "sitegraft: id-remap rewrote 0 post(s)"
  }
}

@test "graft_remap_attachment_ids rewrites a spaced \"id\" : X JSON attribute (issue #88) and the UNMATCHED-guard stays silent on success" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '35199\t763\tattachment\n5\t105\tpage\n' > "$tsv"
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local wp_content="$BATS_TEST_TMPDIR/wp-content"
  _graft_remap_setup_capture "$wp_content"
  run graft_remap_attachment_ids "$tsv" "$run_dir"
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/eval.php" ]

  run _graft_run_captured_remap_eval "$wp_content" 105 '<!-- wp:etch/image {"id" : 35199} -->' ''
  [[ "$output" == *'WRITTEN:<!-- wp:etch/image {"id":763} -->'* ]] || false
  [[ "$output" != *"WARNING"* ]] || false
}

@test "graft_remap_attachment_ids's UNMATCHED-guard: warns by post id and old attachment id when a reference survives in a form no pattern recognizes (issue #88 interim guard, mutation-tested)" {
  # MUTATION-TESTED: removing the UNMATCHED-guard foreach block added to
  # lib/graft.sh's graft_remap_attachment_ids turns this red -- with the
  # guard gone, this content (curly/smart quotes around the id, e.g.
  # pasted from a rich text editor -- a shape no \s*-tolerant pattern
  # matches either) produces only "WRITTEN:NO-WRITE" and no warning at all,
  # the exact silent #88 failure mode.
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '35199\t763\tattachment\n5\t105\tpage\n' > "$tsv"
  local run_dir="$BATS_TEST_TMPDIR/run"; mkdir -p "$run_dir"
  local wp_content="$BATS_TEST_TMPDIR/wp-content"
  _graft_remap_setup_capture "$wp_content"
  run graft_remap_attachment_ids "$tsv" "$run_dir"
  [ "$status" -eq 0 ]

  run _graft_run_captured_remap_eval "$wp_content" 105 '<!-- wp:etch/image {“id”:35199} -->' ''
  [[ "$output" == *'WRITTEN:NO-WRITE'* ]] || false
  [[ "$output" == *'WARNING post 105 still references old attachment id 35199'* ]] || false
}

# MAJOR-1 (review, Viktor): wordpress-importer's native _thumbnail_id remap
# (design doc §9.2) never fires for attachments, since graft_import_attachments
# migrates them entirely outside `wp import` — this is the generic,
# non-sentinel fix for that gap.
@test "graft_remap_featured_images rewrites a migrated post's _thumbnail_id from A's old attachment id to B's new one" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$1" = "post" ] && [ "$2" = "meta" ] && [ "$3" = "get" ]; then
      echo "10"  # B's post 105 currently carries A's OLD attachment id as its thumbnail
    else
      echo "[dry-run] wp_remote ${alias_lc} $*"
    fi
  }
  run graft_remap_featured_images "$tsv"
  [[ "$output" == *"post meta update 105 _thumbnail_id 42"* ]] || false
}

@test "graft_remap_featured_images leaves a post's _thumbnail_id untouched when it doesn't match any migrated attachment" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$1" = "post" ] && [ "$2" = "meta" ] && [ "$3" = "get" ]; then
      echo "999"  # some unrelated id, not one of this run's migrated attachments
    else
      echo "[dry-run] wp_remote ${alias_lc} $*"
    fi
  }
  run graft_remap_featured_images "$tsv"
  [[ "$output" != *"post meta update"* ]] || false
}

@test "graft_remap_featured_images skips a post with no _thumbnail_id set at all" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n5\t105\tpage\n' > "$tsv"
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$1" = "post" ] && [ "$2" = "meta" ] && [ "$3" = "get" ]; then
      echo ""
    else
      echo "SHOULD NOT BE CALLED"
    fi
  }
  run graft_remap_featured_images "$tsv"
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# Fix-pack BLOCKER-adjacent bug found live (DDEV harness, running the new
# MAJOR-B dry-run assertion against a genuinely fresh run directory):
# graft_fetch_id_map never creates id-map.tsv under --dry-run (correctly
# run_or_echo-wrapped), so on a first-time dry run the file is missing
# entirely, not just empty. This function used to go straight into
# `done 3< "$id_map_tsv"` with no existence check at all (unlike its
# sibling graft_remap_attachment_ids, which already guards with `[ -s
# "$id_map_tsv" ] || return 0`) — a missing file made the redirect itself
# fail under this codebase's `set -e`, aborting the whole graft with a raw
# "No such file or directory", reproduced live via the DDEV harness.
@test "graft_remap_featured_images is a no-op (not a crash) when id-map.tsv does not exist at all yet — first-time --dry-run case" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  [ ! -e "$tsv" ]
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run graft_remap_featured_images "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

@test "graft_remap_featured_images is a no-op when id-map.tsv exists but is empty" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  : > "$tsv"
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run graft_remap_featured_images "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]] || false
}

# --- graft_check_orphan_parents --------------------------------------------
#
# The shared query behind verify's "no orphan post_parent references" check.
# Every test that touches it replaces it with a stub — they exercise how
# phase_verify reacts to its RESULT, never whether the function itself does
# what it claims. Neutralizing its body entirely (`return 0` as the first
# statement) left the whole unit suite green: no test in it would see the
# check silently become a no-op while verify ticks its box. The DDEV harness
# does catch it (tests/integration/ddev-harness.sh:754-767, NEGATIVE CASE 3,
# which injects a real orphan and asserts verify reports it) — but that is
# no substitute for a unit test that runs on every commit.
#
# The third test pins the query's shape rather than only its plumbing. A
# check whose SQL quietly stops matching — a typo, a schema change — returns
# an empty result, which is indistinguishable from "no orphans found".

@test "graft_check_orphan_parents returns the ids the query reports" {
  wp_remote() { printf '12\n13\n'; }
  run graft_check_orphan_parents
  [ "$status" -eq 0 ]
  [[ "$output" == *"12"* ]] || false
  [[ "$output" == *"13"* ]] || false
}

@test "graft_check_orphan_parents propagates a failed query rather than reporting no orphans" {
  wp_remote() { return 3; }
  run graft_check_orphan_parents
  [ "$status" -ne 0 ]
}

@test "graft_check_orphan_parents asks for posts whose post_parent points at nothing" {
  wp_remote() { shift 2; printf '%s' "$*" > "$BATS_TEST_TMPDIR/q.sql"; }
  run graft_check_orphan_parents
  grep -q "post_parent" "$BATS_TEST_TMPDIR/q.sql"
  grep -q "NOT EXISTS" "$BATS_TEST_TMPDIR/q.sql"
}
