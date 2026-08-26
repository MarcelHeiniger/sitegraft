<?php
/**
 * tests/unit/fixtures/action-recorder-stub.php — a minimal add_action() /
 * add_filter() stand-in for tests/unit/test_id_mapper_mu_plugin.bats,
 * which loads mu-plugins/sitegraft-id-mapper.php under a bare `php` CLI
 * (no WordPress bootstrap) and needs to inspect what that file registers,
 * not run it.
 *
 * Both hooks are stubbed, not just add_action(): the mu-plugin's own
 * comment names `wp_import_term_meta` -- a FILTER, added via add_filter()
 * -- as the one route that would carry a real old->new term pair, and
 * explains why it still isn't used. A future contributor persuaded by
 * that comment to try wiring it up anyway would call add_filter(), not
 * add_action() -- and without this stub, this test would die on
 * "Call to undefined function add_filter()" instead of failing with a
 * readable assertion. The test this stub serves locks out that route too
 * (Viktor's review, tour 2).
 *
 * A real mu-plugin file only calls add_action()/add_filter() at load
 * time -- the closures registered are never invoked unless something
 * later fires the actual hook/filter, which nothing here does. So all
 * this needs to model is the REGISTRATION call, recorded into
 * $GLOBALS['registered'] for the test to inspect afterward: which
 * hook/filter, of which kind, at what priority, with how many accepted
 * args. The callback itself is intentionally not stored -- nothing in
 * this test needs to invoke it, and a closure isn't usefully comparable
 * via bats' string assertions anyway.
 *
 * Kept as its OWN file (same convention tests/unit/fixtures/wpstub.php
 * already uses) rather than defined inline in the bats file's php_run().
 * That matters for a specific, reproduced reason, not just tidiness: an
 * earlier version of this stub was spliced directly into php_run()'s `-r`
 * argument, with the required file's path written inside PHP DOUBLE
 * quotes (`require "$path";`). PHP's own double-quoted strings
 * interpolate `$name`, so a checkout path containing a literal `$`
 * silently mangled the path there -- reproduced live with a fabricated
 * `$`-containing path. Keeping this stub in its own file, required with a
 * PHP SINGLE-quoted path, sidesteps that entirely: `$` is never special
 * inside a PHP single-quoted string.
 */

$GLOBALS['registered'] = array();

function add_action( $hook, $callback, $priority = 10, $accepted_args = 1 ) {
	$GLOBALS['registered'][] = array(
		'type'          => 'action',
		'hook'          => $hook,
		'priority'      => $priority,
		'accepted_args' => $accepted_args,
	);
}

function add_filter( $hook, $callback, $priority = 10, $accepted_args = 1 ) {
	$GLOBALS['registered'][] = array(
		'type'          => 'filter',
		'hook'          => $hook,
		'priority'      => $priority,
		'accepted_args' => $accepted_args,
	);
}
