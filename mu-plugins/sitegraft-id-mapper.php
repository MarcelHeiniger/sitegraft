<?php
/**
 * Plugin Name: sitegraft ID Mapper (temporary)
 * Description: Logs old->new post/term ID pairs during a sitegraft WXR import.
 * Installed and removed automatically by `sitegraft graft` — do not install by hand.
 */

add_action( 'wp_import_insert_post', function ( $post_id, $original_post_id, $postdata, $post ) {
    $log = WP_CONTENT_DIR . '/sitegraft-id-map.log';
    $post_type = isset( $postdata['post_type'] ) ? $postdata['post_type'] : 'unknown';
    file_put_contents( $log, "{$original_post_id}\t{$post_id}\t{$post_type}\n", FILE_APPEND | LOCK_EX );
    update_post_meta( $post_id, '_sitegraft_source_id', $original_post_id ); // for idempotence, see design doc §11
}, 10, 4 );

add_action( 'wp_import_insert_term', function ( $term_id, $term, $original_id ) {
    $log = WP_CONTENT_DIR . '/sitegraft-id-map.log';
    file_put_contents( $log, "{$original_id}\t{$term_id}\tterm:{$term}\n", FILE_APPEND | LOCK_EX );
}, 10, 3 );
