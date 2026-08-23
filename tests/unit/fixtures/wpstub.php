<?php
/**
 * tests/unit/fixtures/wpstub.php — a minimal, in-memory stand-in for the
 * handful of WordPress core functions lib/php/media-import-functions.php
 * calls, so that sitegraft_media_import_batch and
 * sitegraft_media_import_one can be tested by a bare `php` CLI, with no
 * WordPress bootstrap, no DDEV and no wp-cli — exactly the convention
 * tests/unit/test_content_remap_functions.bats already runs the remap
 * library under.
 *
 * Why this file exists: those two functions were previously described as
 * "can only be exercised against a real WP bootstrap", so they had no unit
 * coverage at all — about 120 lines, four guards, and the single
 * `update_post_meta( ..., '_sitegraft_source_id', ... )` write that the
 * whole idempotent-resume design rests on. That write could be deleted
 * outright and the entire suite stayed green. It can't any more:
 * tests/unit/test_media_import_batch.bats asserts it directly.
 *
 * Deliberately NOT a WordPress emulator. Each function reproduces only the
 * contract media-import-functions.php actually depends on, and each one
 * that a test needs to steer (a failing insert, a filtered title) is
 * steerable through $GLOBALS['wpstub'] rather than through a mock
 * framework.
 *
 * The `the_title` divergence is load-bearing, not decoration: real
 * WordPress runs get_the_title() through the `the_title` filter (core
 * hangs wptexturize, convert_chars and trim on it, and prefixes
 * "Protected: " for a password-protected post), while
 * get_post_field( 'post_title', $id ) returns the stored bytes untouched.
 * The stub models that divergence with a loud, deterministic marker so a
 * test can prove which of the two the production code reads.
 */

// --- state -----------------------------------------------------------------

$GLOBALS['wpstub'] = array(
	// id => array( 'post_title' => string, 'post_type' => string, 'post_status' => string )
	'posts'        => array(),
	// id => array( meta_key => meta_value )
	'meta'         => array(),
	'next_id'      => 1000,
	'uploads_dir'  => '',
	// When non-empty, wp_insert_attachment returns a WP_Error carrying it.
	'insert_error' => '',
	// When true, wp_insert_attachment returns 0 (the "no id" branch).
	'insert_zero'  => false,
	// Every wp_insert_attachment call, in order: array( $postarr, $file ).
	'inserted'     => array(),
	// Every wp_update_attachment_metadata call, in order.
	'metadata_written' => array(),
);

function wpstub_set_uploads( $dir ) {
	$GLOBALS['wpstub']['uploads_dir'] = rtrim( $dir, '/' );
}

/**
 * wpstub_add_attachment( int $id, string $title, string $rel_path ): void
 * An attachment as it exists on A — the shape graft_collect_attachment_metadata_json reads.
 */
function wpstub_add_attachment( $id, $title, $rel_path ) {
	$GLOBALS['wpstub']['posts'][ (int) $id ] = array(
		'post_title'  => $title,
		'post_type'   => 'attachment',
		'post_status' => 'inherit',
	);
	$GLOBALS['wpstub']['meta'][ (int) $id ]['_wp_attached_file'] = $rel_path;
}

/**
 * wpstub_add_existing( int $new_id, int $old_id ): void
 * An attachment already on B carrying _sitegraft_source_id — i.e. what an
 * earlier, interrupted call of the same batch left behind.
 */
function wpstub_add_existing( $new_id, $old_id ) {
	$GLOBALS['wpstub']['posts'][ (int) $new_id ] = array(
		'post_title'  => 'already there',
		'post_type'   => 'attachment',
		'post_status' => 'inherit',
	);
	$GLOBALS['wpstub']['meta'][ (int) $new_id ]['_sitegraft_source_id'] = (int) $old_id;
}

function wpstub_meta( $id, $key ) {
	return isset( $GLOBALS['wpstub']['meta'][ (int) $id ][ $key ] )
		? $GLOBALS['wpstub']['meta'][ (int) $id ][ $key ]
		: '';
}

function wpstub_insert_count() {
	return count( $GLOBALS['wpstub']['inserted'] );
}

// --- WordPress surface -----------------------------------------------------

class WP_Error {
	private $message;
	public function __construct( $message ) {
		$this->message = $message;
	}
	public function get_error_message() {
		return $this->message;
	}
}

function is_wp_error( $thing ) {
	return ( $thing instanceof WP_Error );
}

/**
 * Only the two query shapes media-import-functions.php and
 * graft_collect_attachment_metadata_json actually issue are honoured:
 * "every attachment" and "every post carrying meta_key". Anything else is
 * a hard error rather than a silently-empty result, so a future caller
 * that changes the query can't quietly pass against a stub that ignored it.
 */
function get_posts( $args ) {
	$ids = array();
	foreach ( $GLOBALS['wpstub']['posts'] as $id => $post ) {
		if ( isset( $args['post_type'] ) && $post['post_type'] !== $args['post_type'] ) {
			continue;
		}
		if ( isset( $args['post_status'] ) && $post['post_status'] !== $args['post_status'] ) {
			continue;
		}
		if ( isset( $args['meta_key'] ) && wpstub_meta( $id, $args['meta_key'] ) === '' ) {
			continue;
		}
		$ids[] = (int) $id;
	}
	if ( ! isset( $args['fields'] ) || $args['fields'] !== 'ids' ) {
		throw new RuntimeException( 'wpstub get_posts: only fields=ids is modelled' );
	}
	sort( $ids );
	return $ids;
}

function get_post_meta( $id, $key, $single = false ) {
	return wpstub_meta( $id, $key );
}

function update_post_meta( $id, $key, $value ) {
	$GLOBALS['wpstub']['meta'][ (int) $id ][ $key ] = $value;
	return true;
}

/** Raw stored bytes — no filters. This is what production must read. */
function get_post_field( $field, $id ) {
	return isset( $GLOBALS['wpstub']['posts'][ (int) $id ][ $field ] )
		? $GLOBALS['wpstub']['posts'][ (int) $id ][ $field ]
		: '';
}

/** Stands in for the `the_title` filter chain — deliberately lossy. */
function get_the_title( $id ) {
	return 'FILTERED:' . get_post_field( 'post_title', $id );
}

function wp_upload_dir() {
	return array( 'basedir' => $GLOBALS['wpstub']['uploads_dir'] );
}

function wp_basename( $path ) {
	return basename( $path );
}

function wp_check_filetype( $filename, $mimes = null ) {
	$ext = strtolower( (string) pathinfo( $filename, PATHINFO_EXTENSION ) );
	$map = array( 'jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg', 'png' => 'image/png', 'php' => false );
	return array(
		'ext'  => $ext === '' ? false : $ext,
		'type' => isset( $map[ $ext ] ) ? $map[ $ext ] : 'application/octet-stream',
	);
}

function wp_insert_attachment( $postarr, $file = false ) {
	$GLOBALS['wpstub']['inserted'][] = array( 'postarr' => $postarr, 'file' => $file );
	if ( $GLOBALS['wpstub']['insert_error'] !== '' ) {
		return new WP_Error( $GLOBALS['wpstub']['insert_error'] );
	}
	if ( $GLOBALS['wpstub']['insert_zero'] ) {
		return 0;
	}
	$new_id = $GLOBALS['wpstub']['next_id']++;
	$GLOBALS['wpstub']['posts'][ $new_id ] = array(
		'post_title'  => isset( $postarr['post_title'] ) ? $postarr['post_title'] : '',
		'post_type'   => 'attachment',
		'post_status' => 'inherit',
	);
	return $new_id;
}

function wp_generate_attachment_metadata( $id, $file ) {
	return array( 'file' => $file );
}

function wp_update_attachment_metadata( $id, $metadata ) {
	$GLOBALS['wpstub']['metadata_written'][] = array( 'id' => (int) $id, 'metadata' => $metadata );
	return true;
}

// sitegraft_media_import_one does `require_once ABSPATH .
// 'wp-admin/includes/image.php'` (as wp-cli's own media commands do),
// so ABSPATH has to point at a tree where that file really exists.
if ( ! defined( 'ABSPATH' ) ) {
	$wpstub_abspath = sys_get_temp_dir() . '/wpstub-abspath-' . getmypid() . '/';
	if ( ! is_dir( $wpstub_abspath . 'wp-admin/includes' ) ) {
		mkdir( $wpstub_abspath . 'wp-admin/includes', 0700, true );
	}
	file_put_contents( $wpstub_abspath . 'wp-admin/includes/image.php', "<?php\n// wpstub: wp_generate_attachment_metadata is defined above.\n" );
	define( 'ABSPATH', $wpstub_abspath );
}
