<?php
/**
 * Plugin Name: sitegraft Test Fixture — Fake Etch CPTs
 * Description: Registers the CPTs the sitegraft DDEV integration harness seeds
 * on site A, so they persist across every wp-cli invocation (a one-off
 * `wp eval register_post_type(...)` only registers it for that single process —
 * verified against a real install: a later `wp post-type list` in a fresh
 * process never sees it). Mirrors how site B's fake-plugin.php works. No real
 * Etch license required — only the shape of the data (the CPT slugs) matters
 * for testing sitegraft's mechanics. Not a real plugin — do not use outside
 * tests/integration/.
 */

add_action( 'init', function () {
    register_post_type( 'etch_cfs', [
        'label' => 'Etch CFS',
        'public' => false,
        'show_ui' => true,
        'supports' => [ 'title', 'custom-fields' ],
    ] );
    register_post_type( 'etch_cpts', [
        'label' => 'Etch CPTs',
        'public' => false,
        'show_ui' => true,
        'supports' => [ 'title' ],
    ] );
} );
