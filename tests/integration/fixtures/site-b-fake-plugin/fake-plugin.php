<?php
/**
 * Plugin Name: sitegraft Test Fixture — Fake Booking Plugin
 * Description: Simulates a live business plugin for the sitegraft DDEV integration
 * harness. Not a real plugin — do not use outside tests/integration/.
 */

add_action( 'init', function () {
    // Post type slugs are capped at 20 characters by WordPress core
    // (register_post_type() triggers a _doing_it_wrong() notice past that,
    // which floods wp-cli's output on every request — verified against a
    // real install). "fakebooking_reservation" (23 chars) was too long;
    // "fake_reservation" (16 chars) stays under the limit.
    register_post_type( 'fake_reservation', [
        'label' => 'Fake Reservations',
        'public' => false,
        'show_ui' => true,
        'supports' => [ 'title' ],
    ] );
} );

register_activation_hook( __FILE__, function () {
    global $wpdb;
    require_once ABSPATH . 'wp-admin/includes/upgrade.php';
    $table = $wpdb->prefix . 'fakebooking_reservations';
    $charset_collate = $wpdb->get_charset_collate();
    dbDelta( "CREATE TABLE {$table} (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        guest_name VARCHAR(191) NOT NULL,
        room_number INT NOT NULL,
        PRIMARY KEY (id)
    ) {$charset_collate};" );

    $wpdb->insert( $table, [ 'guest_name' => 'Example Guest', 'room_number' => 12 ] );

    // MAJOR-2 fix-pack fixture (review, Viktor): the dedicated
    // fakebooking_reservations table is structurally OUTSIDE any
    // search-replace/copy path graft ever touches — checksumming only
    // that table made the harness's non-contamination assertion trivially
    // true, never actually exercising the real exposure. fake_reservation
    // (a post_type sharing wp_posts with every migrated post) is protected
    // content that WAS previously seeded with zero rows — nothing to
    // contaminate. Seeded here with real content; the harness script
    // itself injects a domain-string + colliding-attachment-ID payload
    // into both this post AND fakebooking_settings once it knows A's real
    // attachment ID and domain (ddev-harness.sh, after seeding both sites).
    wp_insert_post( [
        'post_type'   => 'fake_reservation',
        'post_title'  => 'Fake Reservation #1',
        'post_status' => 'publish',
        'post_content' => 'placeholder — overwritten by ddev-harness.sh once A\'s real attachment id/domain are known',
    ] );
    update_option( 'fakebooking_settings', [ 'currency' => 'CHF', 'tax_rate' => 3.7 ] );
} );
