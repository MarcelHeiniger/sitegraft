# tests/unit/test_id_mapper_mu_plugin.bats — locks in the decision behind
# fix/id-mapper-drop-dead-term-hook: mu-plugins/sitegraft-id-mapper.php
# registers a hook on wp_import_insert_post and, deliberately, NOTHING on
# wp_import_insert_term any more.
#
# That handler used to exist, but it could never have worked:
# wordpress-importer 0.9.5 fires wp_import_insert_term only from
# process_post_term() (class-wp-import.php:1186), whose $term comes from
# the WXR parser's inline <item><category> handling
# (class-wxr-parser-simplexml.php:183-187) -- name/slug/domain only, no
# original term_id. The handler logged the literal string "Array" into
# every row it wrote (see mu-plugins/sitegraft-id-mapper.php's own
# comment for the full account) and has been removed as dead code.
#
# What this test actually proves: the mu-plugin's add_action() call graph,
# nothing about a real WordPress import. It loads the mu-plugin file under
# a bare `php` CLI with tests/unit/fixtures/action-recorder-stub.php's
# recording add_action() instead of a WordPress bootstrap -- same
# fixture-file convention tests/unit/fixtures/wpstub.php already uses for
# WordPress-adjacent PHP in this repo, and for the same reason: keeping
# the stub in its own file (see php_run()'s own comment below for why a
# stub embedded inline in a bash `-r` string is a real, reproduced hazard,
# not just a style choice). It is a guard against a future
# contributor naively re-adding a wp_import_insert_term handler (the
# "obvious" fix looks correct at a glance -- see the mu-plugin's own
# comment for why it isn't), not a test of import behavior.
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
