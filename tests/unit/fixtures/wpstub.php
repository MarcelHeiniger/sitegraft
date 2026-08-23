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
 * THE RULE THIS FILE LIVES BY: a stub that is more PERMISSIVE than real
 * WordPress produces green tests about a reality that does not exist. This
 * is not hypothetical — it already happened here. get_posts() originally
 * ignored 'posts_per_page', so deleting `'posts_per_page' => -1` from
 * sitegraft_media_import_batch left the whole suite green at 471/471,
 * while on a real site it would have capped the resume query at FIVE
 * attachments (get_posts defaults numberposts to 5) and re-imported every
 * media item past the fifth as a duplicate on every re-run — precisely the
 * bug this library exists to fix. Anything modelled loosely here must be
 * modelled loosely in the SAFE direction, or written down below.
 *
 * KNOWN DIVERGENCES, deliberate and NOT fixed — each one makes a test
 * STRONGER than reality, which is safe, but must not be mistaken for proof
 * about production:
 *
 *   1. wp_insert_attachment() here can return a WP_Error, steered via
 *      $GLOBALS['wpstub']['insert_error']. Real core CANNOT: called with
 *      two arguments it leaves $wp_error at its false default and returns
 *      0 on failure, never a WP_Error. sitegraft_media_import_one's
 *      `is_wp_error( $new_id )` check is therefore purely defensive, and
 *      the test covering it exercises a branch production cannot currently
 *      reach. The `! $new_id` half of that same condition IS reachable and
 *      is covered separately.
 *
 *   2. Titles are stored as given. Real WordPress runs an inserted post
 *      through sanitize_post() and then through
 *      $wpdb->strip_invalid_text_for_column(), which can alter or drop
 *      bytes that do not fit the column's charset. The "uses A's title
 *      verbatim, including non-ASCII bytes" test therefore asserts
 *      something stricter than a real site guarantees; what it really
 *      pins is that sitegraft itself does not mangle the title.
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
	// Stands in for post_date. Monotonically increasing, so "newest first"
	// (get_posts' default orderby=date/order=DESC) is exactly reverse
	// insertion order — deterministic, and it makes a truncated query drop
	// the OLDEST entries, which is how the real cap manifests.
	'next_seq'     => 1,
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
		'post_date'   => $GLOBALS['wpstub']['next_seq']++,
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
		'post_date'   => $GLOBALS['wpstub']['next_seq']++,
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
 * Models real get_posts() closely enough to be USED AS EVIDENCE, which
 * means modelling the parts a caller can get wrong — above all the
 * default result cap.
 *
 * Real wp-includes/post.php defaults 'numberposts' to 5, 'orderby' to
 * 'date' and 'order' to 'DESC', then copies numberposts into
 * posts_per_page whenever posts_per_page is empty. A caller that forgets
 * `'posts_per_page' => -1` therefore silently gets the FIVE most recent
 * rows, not everything — which for sitegraft's resume query means
 * re-importing every attachment past the fifth as a duplicate on each
 * re-run. Ignoring the cap here (the original version of this stub did)
 * made that mistake invisible to the entire suite.
 *
 * Only the two query shapes media-import-functions.php and
 * graft_collect_attachment_metadata_json actually issue are honoured:
 * "every attachment" and "every post carrying meta_key". Anything else is
 * a hard error rather than a silently-empty result, so a future caller
 * that changes the query can't quietly pass against a stub that ignored it.
 */
function get_posts( $args ) {
	if ( ! isset( $args['fields'] ) || $args['fields'] !== 'ids' ) {
		throw new RuntimeException( 'wpstub get_posts: only fields=ids is modelled' );
	}

	// Real defaults, in the same order core applies them.
	$post_type = isset( $args['post_type'] ) ? $args['post_type'] : 'post';
	$orderby   = isset( $args['orderby'] ) ? $args['orderby'] : 'date';
	$order     = isset( $args['order'] ) ? strtoupper( $args['order'] ) : 'DESC';
	$post_status = ( isset( $args['post_status'] ) && $args['post_status'] !== '' )
		? $args['post_status']
		: ( 'attachment' === $post_type ? 'inherit' : 'publish' );

	$numberposts = isset( $args['numberposts'] ) ? $args['numberposts'] : 5;
	$per_page    = ( isset( $args['posts_per_page'] ) && $args['posts_per_page'] !== '' && $args['posts_per_page'] !== 0 )
		? (int) $args['posts_per_page']
		: (int) $numberposts;

	$rows = array();
	foreach ( $GLOBALS['wpstub']['posts'] as $id => $post ) {
		if ( $post['post_type'] !== $post_type ) {
			continue;
		}
		if ( $post['post_status'] !== $post_status ) {
			continue;
		}
		if ( isset( $args['meta_key'] ) && wpstub_meta( $id, $args['meta_key'] ) === '' ) {
			continue;
		}
		$rows[] = array(
			'id'   => (int) $id,
			'date' => isset( $post['post_date'] ) ? $post['post_date'] : 0,
		);
	}

	$key = ( 'ID' === $orderby || 'id' === $orderby ) ? 'id' : 'date';
	usort(
		$rows,
		function ( $a, $b ) use ( $key ) {
			if ( $a[ $key ] === $b[ $key ] ) {
				return 0;
			}
			return ( $a[ $key ] < $b[ $key ] ) ? -1 : 1;
		}
	);
	if ( 'DESC' === $order ) {
		$rows = array_reverse( $rows );
	}

	$ids = array();
	foreach ( $rows as $row ) {
		$ids[] = $row['id'];
	}
	// -1 (and any negative) means "no limit", exactly as core treats it.
	if ( $per_page > 0 ) {
		$ids = array_slice( $ids, 0, $per_page );
	}
	return $ids;
}

function get_post_meta( $id, $key, $single = false ) {
	// Real core returns an ARRAY of values when $single is false. Nothing in
	// media-import-functions.php or the collection eval calls it that way,
	// and silently handing back a scalar instead would be exactly the kind
	// of permissiveness that let the posts_per_page bug through. Fail loud.
	if ( ! $single ) {
		throw new RuntimeException( 'wpstub get_post_meta: only $single = true is modelled (real core returns an array otherwise)' );
	}
	return wpstub_meta( $id, $key );
}

function update_post_meta( $id, $key, $value ) {
	$GLOBALS['wpstub']['meta'][ (int) $id ][ $key ] = $value;
	return true;
}

/**
 * Models real get_post_field( $field, $post, $context = 'display' ).
 *
 * The third parameter is the point. Verified against wp-includes/post.php:
 * get_post_field defaults $context to 'display' and hands the value to
 * sanitize_post_field, which returns early ONLY for 'raw'; every other
 * context runs `apply_filters( "post_title", ... )`. Stock WordPress hangs
 * nothing on `post_title` (it hangs wptexturize/convert_chars/trim on
 * `the_title` instead), so on a clean install the two look identical — but
 * any plugin on A can hook `post_title`, and a graft has to carry A's
 * STORED bytes, not whatever A's plugins render.
 *
 * A stub that ignored $context (this one did) made
 * `get_post_field( 'post_title', $id )` and
 * `get_post_field( 'post_title', $id, 'raw' )` indistinguishable, so the
 * imprecise call passed. The marker below makes the difference visible.
 */
function get_post_field( $field, $id, $context = 'display' ) {
	$value = isset( $GLOBALS['wpstub']['posts'][ (int) $id ][ $field ] )
		? $GLOBALS['wpstub']['posts'][ (int) $id ][ $field ]
		: '';
	if ( 'raw' === $context ) {
		return $value;
	}
	// Stands in for a plugin hooked on the `post_title` display filter.
	return 'DISPLAYFILTERED:' . $value;
}

/** Stands in for the `the_title` filter chain — deliberately lossy. */
function get_the_title( $id ) {
	return 'FILTERED:' . get_post_field( 'post_title', $id, 'raw' );
}

function wp_upload_dir() {
	return array( 'basedir' => $GLOBALS['wpstub']['uploads_dir'] );
}

function wp_basename( $path ) {
	return basename( $path );
}

function wp_check_filetype( $filename, $mimes = null ) {
	// Verified against wp-includes/functions.php: core starts from
	// $ext = false / $type = false and only fills them in when the filename
	// matches an ALLOWED mime pattern — an unlisted extension comes back
	// false/false, it does not fall back to a generic type. The stub used to
	// return 'application/octet-stream' for anything unknown, i.e. it was
	// more permissive than core on exactly the extensions (.php and friends)
	// a graft tool must not wave through.
	$ext = strtolower( (string) pathinfo( $filename, PATHINFO_EXTENSION ) );
	$map = array( 'jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg', 'png' => 'image/png', 'gif' => 'image/gif' );
	if ( ! isset( $map[ $ext ] ) ) {
		return array( 'ext' => false, 'type' => false );
	}
	return array( 'ext' => $ext, 'type' => $map[ $ext ] );
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
		'post_date'   => $GLOBALS['wpstub']['next_seq']++,
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

	// Remove it again when this php process ends. Every test spawns its own
	// `php`, so without this the stub leaves one directory per invocation
	// behind in the system temp dir — hundreds over a full suite run.
	register_shutdown_function(
		function () use ( $wpstub_abspath ) {
			@unlink( $wpstub_abspath . 'wp-admin/includes/image.php' );
			@rmdir( $wpstub_abspath . 'wp-admin/includes' );
			@rmdir( $wpstub_abspath . 'wp-admin' );
			@rmdir( $wpstub_abspath );
		}
	);
}
