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
# a bare `php` CLI with a stub add_action() that records registrations
# instead of a WordPress bootstrap -- same convention
# tests/unit/test_media_import_functions.bats and
# tests/unit/fixtures/wpstub.php already use for WordPress-adjacent PHP in
# this repo. It is a guard against a future contributor naively re-adding
# a wp_import_insert_term handler (the "obvious" fix looks correct at a
# glance -- see the mu-plugin's own comment for why it isn't), not a test
# of import behavior.
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  MU_PLUGIN="${REPO_ROOT}/mu-plugins/sitegraft-id-mapper.php"
  [ -f "$MU_PLUGIN" ] || skip "mu-plugins/sitegraft-id-mapper.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

# php_run <script> — defines a recording add_action() stub, requires the
# real mu-plugin (which only calls add_action() at load time, never
# invokes the closures), then runs <script> to inspect what was recorded.
php_run() {
  php -r '
    $GLOBALS["registered"] = array();
    function add_action( $hook, $callback, $priority = 10, $accepted_args = 1 ) {
        $GLOBALS["registered"][] = array(
            "hook"           => $hook,
            "priority"       => $priority,
            "accepted_args"  => $accepted_args,
        );
    }
    require "'"${MU_PLUGIN}"'";
    '"$1"'
  '
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
