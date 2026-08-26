<?php
/**
 * Plugin Name: sitegraft ID Mapper (temporary)
 * Description: Logs old->new post ID pairs during a sitegraft WXR import.
 * Installed and removed automatically by `sitegraft graft` — do not install by hand.
 */

add_action( 'wp_import_insert_post', function ( $post_id, $original_post_id, $postdata, $post ) {
    $log = WP_CONTENT_DIR . '/sitegraft-id-map.log';
    $post_type = isset( $postdata['post_type'] ) ? $postdata['post_type'] : 'unknown';
    file_put_contents( $log, "{$original_post_id}\t{$post_id}\t{$post_type}\n", FILE_APPEND | LOCK_EX );
    update_post_meta( $post_id, '_sitegraft_source_id', $original_post_id ); // for idempotence, see design doc §11
}, 10, 4 );

// No wp_import_insert_term handler here, deliberately -- do not re-add one.
// wordpress-importer 0.9.5 fires that action only from process_post_term()
// (class-wp-import.php:1186), whose $term argument comes straight from the
// WXR parser's inline <item><category> handling
// (class-wxr-parser-simplexml.php:183-187): just name/slug/domain, no
// original term_id anywhere in it. A handler bound there can log a new
// term_id but has no old one to pair it with -- there is no old->new term
// map to build from this hook, structurally, no matter how it's written.
// (The one WXR path that DOES carry an original term id -- standalone
// <wp:category>/<wp:tag>/<wp:term> nodes, read by process_categories() /
// process_tags() / process_terms() around class-wp-import.php:477/546/619
// -- fires no comparable action; only the conditional-on-termmeta
// wp_import_term_meta filter and import_term_meta action.) A prior version
// of this handler bound `( $term_id, $term, $original_id )` to the actual
// hook signature `( $t, $term, $post_id, $post )`, so $term_id held an
// array of term_taxonomy_ids and $original_id held the POST's id, not a
// term id. Every line it wrote came out as "<post_id>\tArray\tterm:Array"
// (PHP's array-to-string coercion of $t and $term) -- worked out directly
// from the hook's real parameter order above, not assumed. Nothing ever
// consumed those rows anyway: modules/core-wp.sh's map_json awk excludes
// `^term:` on principle, and its own numeric guard on column 2 would have
// excluded these specific garbage rows regardless.
