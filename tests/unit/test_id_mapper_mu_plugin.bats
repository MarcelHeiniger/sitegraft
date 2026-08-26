# tests/unit/test_id_mapper_mu_plugin.bats — locks in the decision behind
# fix/id-mapper-drop-dead-term-hook: mu-plugins/sitegraft-id-mapper.php
# registers a hook on wp_import_insert_post and, deliberately, NOTHING on
# wp_import_insert_term OR wp_import_term_meta any more.
#
# That wp_import_insert_term handler used to exist, but it could never
# have worked: wordpress-importer 0.9.5 fires wp_import_insert_term only
# from process_post_term() (class-wp-import.php:1186), whose $term comes
# from the WXR parser's inline <item><category> handling
# (class-wxr-parser-simplexml.php:183-187) -- name/slug/domain only, no
# original term_id. The handler logged the literal string "Array" into
# every row it wrote (see mu-plugins/sitegraft-id-mapper.php's own
# comment for the full account) and has been removed as dead code.
# wp_import_term_meta (a FILTER, added via add_filter -- see that same
# comment) DOES carry a real old->new term pair, for newly-created terms
# only, and is still deliberately not used: it silently omits every term
# that already existed on B, so a map built from it would look
# authoritative while being quietly incomplete.
#
# What this test actually proves: the mu-plugin's add_action()/
# add_filter() call graph, nothing about a real WordPress import. It loads
# the mu-plugin file under a bare `php` CLI with
# tests/unit/fixtures/action-recorder-stub.php's recording
# add_action()/add_filter() instead of a WordPress bootstrap -- same
# fixture-file convention tests/unit/fixtures/wpstub.php already uses for
# WordPress-adjacent PHP in this repo, and for the same reason: keeping
# the stub in its own file (see php_run()'s own comment below for why a
# stub embedded inline in a bash `-r` string is a real, reproduced hazard,
# not just a style choice). It is a guard against a future contributor
# naively re-adding a wp_import_insert_term handler OR a
# wp_import_term_meta filter (both "obvious" fixes look correct at a
# glance -- see the mu-plugin's own comment for why neither is), not a
# test of import behavior. Without the stub's add_filter() alias (Viktor's
# review, tour 2), an add_filter() re-add would have died on "Call to
# undefined function add_filter()" instead of failing this test's own,
# readable assertion.
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  MU_PLUGIN="${REPO_ROOT}/mu-plugins/sitegraft-id-mapper.php"
  ACTION_STUB="${REPO_ROOT}/tests/unit/fixtures/action-recorder-stub.php"
  [ -f "$MU_PLUGIN" ] || skip "mu-plugins/sitegraft-id-mapper.php not found"
  [ -f "$ACTION_STUB" ] || skip "tests/unit/fixtures/action-recorder-stub.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

# php_run <script> — runs <script> with the recording add_action() stub
# and the real mu-plugin both already required, in that order. Same
# convention as tests/unit/test_media_import_batch.bats' own php_run():
# the required paths are SINGLE-quoted inside a double-quoted `-r`
# argument, so $1 can use quotes freely without bash escaping headaches.
#
# The single quotes around the require paths are load-bearing, not
# style: an earlier version of this function wrapped the whole `-r`
# script in single quotes and hand-spliced ${MU_PLUGIN} in via
# `require "'"${MU_PLUGIN}"'";` -- putting the path inside PHP DOUBLE
# quotes. PHP's own double-quoted strings interpolate `$name`, so a
# checkout path containing a literal `$` (a macOS username with one, an
# oddly named directory) silently truncated the path there: "Undefined
# variable" warnings for each `$word` PHP tried to interpolate, followed
# by "Failed to open stream" on the now-mangled path. Reproduced live
# with a fabricated `$`-containing path (Viktor's review) -- fails loud,
# never a false green, but worth not diverging from the convention that
# avoids it for free by keeping the require path in PHP single quotes,
# where `$` is never special.
php_run() {
  php -r "require '${ACTION_STUB}'; require '${MU_PLUGIN}'; $1"
}

@test "sitegraft-id-mapper.php registers exactly one hook, on wp_import_insert_post, priority 10, 4 args" {
  run php_run '
    $post_hooks = array_values( array_filter( $GLOBALS["registered"], function ( $r ) {
        return $r["hook"] === "wp_import_insert_post";
    } ) );
    echo json_encode( array(
        "total"      => count( $GLOBALS["registered"] ),
        "post_hooks" => $post_hooks,
    ) );
  '
  [ "$status" -eq 0 ]
  run jq -e '.total == 1
    and (.post_hooks | length) == 1
    and .post_hooks[0].priority == 10
    and .post_hooks[0].accepted_args == 4' <<< "$output"
  [ "$status" -eq 0 ]
}

# The verification this whole file exists for: no re-introduction of a
# wp_import_insert_term handler, naive or otherwise.
@test "sitegraft-id-mapper.php registers NO hook on wp_import_insert_term" {
  run php_run '
    $term_hooks = array_filter( $GLOBALS["registered"], function ( $r ) {
        return $r["hook"] === "wp_import_insert_term";
    } );
    echo count( $term_hooks );
  '
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# Viktor's review, tour 2: the mu-plugin's own comment names
# `wp_import_term_meta` (a FILTER) as the one route that DOES carry a real
# old->new term pair, and explains why it's still not wired up. This test
# is the second half of the lock the file above claims: not just "no
# wp_import_insert_term action", but "no wp_import_term_meta filter"
# either -- the specific route a future contributor persuaded by that
# comment's own analysis might reach for next.
@test "sitegraft-id-mapper.php registers NO filter on wp_import_term_meta" {
  run php_run '
    $term_meta_filters = array_filter( $GLOBALS["registered"], function ( $r ) {
        return $r["hook"] === "wp_import_term_meta";
    } );
    echo count( $term_meta_filters );
  '
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# Belt-and-suspenders on the "exactly one hook" test above: confirms the
# single registration is of TYPE action (add_action), not merely that its
# hook name is right -- distinguishing the two only matters now that the
# stub records both kinds into the same array.
@test "sitegraft-id-mapper.php's one registration is an action, not a filter" {
  run php_run '
    echo $GLOBALS["registered"][0]["type"];
  '
  [ "$status" -eq 0 ]
  [ "$output" = "action" ]
}
