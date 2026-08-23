<?php
/**
 * lib/php/media-import-functions.php — the batched media-import logic
 * behind `sitegraft graft`'s attachment step (issue #11).
 *
 * Before this file existed, `graft_import_attachments` (lib/graft.sh) ran
 * FOUR wp-cli container invocations per attachment: `post meta get
 * _wp_attached_file` and `post get --field=post_title` against A, then
 * `media import --skip-copy` and `post meta update _sitegraft_source_id`
 * against B. Measured on a 518-attachment reference pair, that was 6.4
 * imports/min then 3.3 remaps/min — close to three hours for this step
 * alone, almost entirely container-startup overhead, not real work.
 *
 * The fix mirrors the existing content-remap mechanism (see
 * content-remap-functions.php in this same directory): one `wp eval` on A
 * dumps every attachment's metadata as JSON in a single bootstrap, and one
 * `wp eval` on B (this file, `require_once`'d) does every insert and every
 * meta write in a single bootstrap, replacing roughly 2000 container starts
 * with two.
 *
 * Two of the four functions below are pure array/string logic with zero
 * WordPress calls, and are unit-tested directly via a bare `php` CLI, same
 * as content-remap-functions.php's own functions
 * (tests/unit/test_media_import_functions.bats):
 *   - sitegraft_media_diff_missing
 *   - sitegraft_media_build_report
 * These two are exactly the logic this rewrite is riskiest on: the
 * idempotent-resume guarantee (never re-import something already on B,
 * never silently skip something that IS missing) and the fail-closed
 * accounting invariant (a batch that only got through part of the list
 * must say so, never report a false global success).
 *
 * The other two (sitegraft_media_import_one, sitegraft_media_import_batch)
 * call WordPress core APIs (wp_insert_attachment, get_posts, ...). They
 * were once described here as testable only against a real WP bootstrap.
 * That was measurably wrong, and it hid four live guards: the whole suite
 * stayed green with `update_post_meta( ..., '_sitegraft_source_id', ... )`
 * — the single write the entire idempotent-resume design rests on, and
 * the only thing graft_prune_previous_run can find a previous run's posts
 * by — deleted outright, and likewise with the file_exists guard, the
 * no_local_file bucket, and the is_wp_error check after the insert. Both
 * functions now run under tests/unit/fixtures/wpstub.php, an in-memory
 * stand-in for the handful of core functions this file calls, driven by
 * tests/unit/test_media_import_batch.bats through the same bare `php` CLI.
 * The DDEV harness still covers what a stub cannot: real WordPress, real
 * files, real wp-cli.
 */

/**
 * sitegraft_media_diff_missing( array $requested_old_ids, array $existing_map ): array
 *
 * Pure. $requested_old_ids is a plain list of attachment IDs from A.
 * $existing_map is [ (string) old_id => new_id ] for whatever is ALREADY
 * on B, tagged with _sitegraft_source_id (design doc §11's "idempotent
 * reimport" marker) — that includes attachments a PREVIOUS, INTERRUPTED
 * call of this same batch already created, since a batch that dies
 * partway through (a PHP fatal, an OOM, a killed container) leaves
 * whatever it had already inserted sitting on B when the step is retried.
 *
 * Returns exactly the old_ids in $requested_old_ids that are NOT already
 * keys of $existing_map — i.e. the ones this call still needs to import.
 * This is the entire resumability contract for the batch: re-running it
 * against the same run must neither re-import an old_id already present
 * (duplicate attachments) nor drop one that's genuinely still missing.
 *
 * The (string) cast on the request side is defensive, not load-bearing —
 * PHP itself already normalizes a numeric-string array key to int, so
 * array_key_exists(1, ["1" => 42]) is true with or without it. Cast
 * anyway, so this comparison isn't relying on that coercion as an
 * implicit contract if either side's key shape ever changes (e.g.
 * $existing_map keyed by a non-numeric string in some future caller).
 */
function sitegraft_media_diff_missing( array $requested_old_ids, array $existing_map ) {
	$missing = array();
	foreach ( $requested_old_ids as $old_id ) {
		if ( ! array_key_exists( (string) $old_id, $existing_map ) ) {
			$missing[] = $old_id;
		}
	}
	return $missing;
}

/**
 * sitegraft_media_build_report( array $requested_old_ids, array $imported_map,
 *   array $already_present_map, array $no_local_file, array $failed ): array
 *
 * Pure. Assembles the batch's final, honest accounting — this is the
 * function the "fail closed on partial" requirement (issue #11) rests on.
 *
 * $imported_map / $already_present_map: both [ (string) old_id => new_id ],
 * disjoint by construction (every old_id lands in exactly one bucket
 * upstream in sitegraft_media_import_batch). $no_local_file / $failed:
 * plain lists (old_ids, and [old, error] pairs respectively) — attachments
 * this call deliberately did NOT create on B, but DID account for.
 *
 * `ok` is true only when every requested old_id landed in exactly one of
 * the four buckets. This is the one check that catches a batch that
 * silently ate an error per item and would otherwise report a false
 * overall success (the exact failure mode issue #11 calls out as the
 * worst possible outcome here) — if a bug ever let an item fall through
 * all four buckets untouched (or land in two), `accounted_for` stops
 * matching `count($requested_old_ids)` and `ok` goes false, which
 * graft_import_attachments (lib/graft.sh) treats as a hard failure, not a
 * warning.
 *
 * `map` (the union of imported + already-present) is what
 * graft_import_attachments rewrites id-map.tsv's attachment rows from —
 * REPLACING them, not appending, on every call. That replace-not-append
 * behavior is what actually fixes the pre-batch implementation's latent
 * duplicate-row bug on a resumed, partially-completed step (the naive
 * per-attachment loop this replaced re-queried and re-appended
 * unconditionally, with no existing-on-B check at all).
 */
function sitegraft_media_build_report( array $requested_old_ids, array $imported_map, array $already_present_map, array $no_local_file, array $failed ) {
	$accounted_for = count( $imported_map ) + count( $already_present_map ) + count( $no_local_file ) + count( $failed );
	// + never overwrites a key: imported_map and already_present_map are
	// disjoint by construction (an old_id is only ever placed in one of
	// the two upstream), so this union can't silently drop or clobber
	// either side's mapping.
	$map = $imported_map + $already_present_map;
	return array(
		'ok'              => ( $accounted_for === count( $requested_old_ids ) ),
		'requested'       => count( $requested_old_ids ),
		'accounted_for'   => $accounted_for,
		'imported'        => array_values( array_map( 'intval', array_keys( $imported_map ) ) ),
		'already_present' => array_values( array_map( 'intval', array_keys( $already_present_map ) ) ),
		'no_local_file'   => array_values( $no_local_file ),
		'failed'          => array_values( $failed ),
		// json_encode(array()) always produces "[]", never "{}" -- PHP has
		// no way to tell an empty array was meant to be an associative map.
		// stdClass here keeps this field's TYPE stable (always a JSON
		// object) regardless of whether anything landed in it, which is the
		// whole point: the caller's guard (graft_import_attachments,
		// lib/graft.sh) is `(.map | type) == "object"`, and an empty batch --
		// every attachment failed, or had no local file -- is a legitimate,
		// non-error outcome that must not trip it.
		//
		// NOT because jq's `to_entries[]` errors on a JSON array. Measured, it
		// does not: `echo '[]' | jq -r 'to_entries[]'` exits 0 and prints
		// nothing. The jq error this shape really does avoid is one level up,
		// on the object guard: `echo '[]' | jq -r '.error // empty'` is
		// "Cannot index array with string \"error\"", exit 5.
		'map'             => empty( $map ) ? new stdClass() : $map,
	);
}

/**
 * sitegraft_media_import_one( int $old_id, string $abs_path, string $title ): array
 *
 * NOT pure — calls WordPress core media APIs directly; in production it
 * runs only inside a real `wp eval` bootstrap on B. Unit-tested against
 * tests/unit/fixtures/wpstub.php (tests/unit/test_media_import_batch.bats),
 * and exercised for real by the DDEV integration harness.
 *
 * Registers a file ALREADY PLACED on B's filesystem (by graft_media_sync,
 * which runs before this step) as an attachment, without copying it —
 * deliberately reimplemented with WordPress's own public media API
 * (wp_insert_attachment / wp_generate_attachment_metadata /
 * wp_update_attachment_metadata) rather than shelling out to wp-cli's
 * `media import --skip-copy` a second time from inside PHP, since that
 * command is a CLI-only wrapper, not something `wp eval` can call as a
 * function. This mirrors what wp-cli's own Media_Command::process_asset()
 * does for its `--skip-copy` path: build a minimal attachment post array
 * (mime type from the filename, title falling back to the filename with
 * its extension stripped when none was supplied), insert it pointing at
 * the existing file, then generate and store the standard attachment
 * metadata (image sizes etc.) exactly as a normal upload would.
 *
 * Returns array( 'ok' => bool, 'new_id' => int|null, 'error' => string|null ).
 * Never throws for an ordinary "file missing/unreadable" case — that's
 * reported as a normal ok=false result — so the batch loop's per-item
 * try/catch in sitegraft_media_import_batch only has to guard against a
 * genuine WordPress/PHP exception, not this function's expected failure
 * path.
 */
function sitegraft_media_import_one( $old_id, $abs_path, $title ) {
	if ( ! is_string( $abs_path ) || $abs_path === '' || ! file_exists( $abs_path ) ) {
		return array(
			'ok'     => false,
			'new_id' => null,
			'error'  => 'file not found on B (was it actually placed by the media sync step?): ' . $abs_path,
		);
	}
	// wp_generate_attachment_metadata lives in an admin-only file that a
	// `wp eval` bootstrap does not autoload — wp-cli's own media commands
	// require_once the exact same file for the exact same reason.
	require_once ABSPATH . 'wp-admin/includes/image.php';

	$filename   = wp_basename( $abs_path );
	$filetype   = wp_check_filetype( $filename, null );
	$post_title = ( $title !== '' ) ? $title : preg_replace( '/\.[^.]+$/', '', $filename );

	$new_id = wp_insert_attachment(
		array(
			'post_mime_type' => $filetype['type'],
			'post_title'     => $post_title,
			'post_content'   => '',
			'post_excerpt'   => '',
			'post_status'    => 'inherit',
		),
		$abs_path
	);
	if ( is_wp_error( $new_id ) || ! $new_id ) {
		return array(
			'ok'     => false,
			'new_id' => null,
			'error'  => is_wp_error( $new_id ) ? $new_id->get_error_message() : 'wp_insert_attachment returned no id',
		);
	}

	$metadata = wp_generate_attachment_metadata( $new_id, $abs_path );
	wp_update_attachment_metadata( $new_id, $metadata );

	return array( 'ok' => true, 'new_id' => (int) $new_id, 'error' => null );
}

/**
 * sitegraft_media_import_batch( array $requested ): array
 *
 * NOT pure — the WordPress-dependent orchestrator `wp eval` calls,
 * `require_once`'d exactly once per invocation (see this call's own glue
 * in graft_import_attachments, lib/graft.sh). $requested is the JSON
 * payload pushed from the orchestrator: a list of
 * [ 'old' => int, 'rel_path' => string, 'title' => string ], where
 * 'rel_path' is '' for an attachment A reported no _wp_attached_file for
 * (an external/offloaded media entry — never locally storable, same case
 * the pre-batch implementation logged and skipped per item).
 *
 * Ground truth for "already present" comes from B itself (every attachment
 * currently carrying _sitegraft_source_id), queried ONCE here, in-process —
 * not from anything the orchestrator remembers — so this is correct
 * whether this is the batch's first call for this run or a resumed one
 * after a previous partial call. graft_prune_previous_run (lib/graft.sh)
 * already clears any _sitegraft_source_id-tagged post left by a genuinely
 * PRIOR, completed run before this step ever starts, so anything found
 * here can only be this run's own earlier, incomplete progress.
 *
 * Every actual import (sitegraft_media_import_one) is wrapped in its own
 * try/catch: one attachment's WordPress-level exception is recorded as a
 * per-item failure and the loop continues, so a single bad file can never
 * silently truncate the whole batch's accounting (the exact "worst
 * outcome" issue #11 names). A true PHP fatal error (uncaught by design —
 * OOM, a core API misuse outside sitegraft's own control) still aborts the
 * whole `wp eval` process, which is not swallowed either: `wp eval` then
 * exits non-zero and graft_import_attachments treats that as a hard
 * failure via the same fail-closed path as an unparseable result.
 */
function sitegraft_media_import_batch( array $requested ) {
	$existing_ids = get_posts(
		array(
			'post_type'      => 'attachment',
			'post_status'    => 'inherit',
			'posts_per_page' => -1,
			'fields'         => 'ids',
			'meta_key'       => '_sitegraft_source_id',
		)
	);
	$existing_map = array();
	foreach ( $existing_ids as $new_id ) {
		$old_id = get_post_meta( $new_id, '_sitegraft_source_id', true );
		if ( $old_id !== '' ) {
			$existing_map[ (string) $old_id ] = (int) $new_id;
		}
	}

	$requested_old_ids = array();
	$by_old_id         = array();
	foreach ( $requested as $row ) {
		$old_id                       = (int) $row['old'];
		$requested_old_ids[]          = $old_id;
		$by_old_id[ (string) $old_id ] = $row;
	}

	$missing = sitegraft_media_diff_missing( $requested_old_ids, $existing_map );

	$upload_dir = wp_upload_dir();
	// Resolved once. $uploads_base is the canonical uploads root every
	// rel_path below has to stay inside; $uploads_base_raw is the
	// unresolved form the attachment path is actually built from, so an
	// error message echoes back the path that was asked for rather than a
	// symlink-resolved one the operator never wrote. $uploads_base is
	// false when basedir itself does not exist, which is treated as
	// "cannot confine" -> refuse, never as "confinement passes".
	$uploads_base_raw = rtrim( $upload_dir['basedir'], '/' );
	$uploads_base     = realpath( $uploads_base_raw );
	
	$imported_map  = array();
	$no_local_file = array();
	$failed        = array();

	foreach ( $missing as $old_id ) {
		$row      = $by_old_id[ (string) $old_id ];
		$rel_path = isset( $row['rel_path'] ) ? (string) $row['rel_path'] : '';
		if ( $rel_path === '' ) {
			$no_local_file[] = $old_id;
			continue;
		}
		$abs_path = $uploads_base_raw . '/' . ltrim( $rel_path, '/' );
		
		// Path confinement (review N1, both reviewers). ltrim( $rel_path, '/' )
		// strips leading slashes and nothing else -- it does not stop a
		// rel_path of "../../wp-config.php". Measured before this guard:
		// rel_path "../secret/wp-config.php" returned
		// {"ok":true,"imported":[66]} and registered a file from outside the
		// uploads tree as an attachment on B. That is worse than an
		// out-of-bounds read: graft_prune_previous_run (lib/graft.sh) deletes
		// every _sitegraft_source_id-tagged post with `wp post delete
		// --force`, which removes the attached file from disk -- so the NEXT
		// graft would delete that out-of-tree file for real.
		//
		// realpath() resolves symlinks too, so a link planted inside uploads
		// that points outside it is caught here as well.
		//
		// "the file isn't there" and "that path points outside the uploads
		// tree" are two different facts about two different problems, and
		// realpath() returns false for BOTH -- so existence is tested
		// separately, and only a path that really does resolve OUTSIDE the
		// tree gets the escape message. A non-existent path (escaping or not)
		// falls through to sitegraft_media_import_one's own "file not found
		// on B" report -- nothing was reachable, so nothing was confined out.
		$real_path = realpath( $abs_path );
		if ( $real_path !== false && ( $uploads_base === false || strpos( $real_path, $uploads_base . '/' ) !== 0 ) ) {
			$failed[] = array(
				'old'   => $old_id,
				'error' => 'rel_path resolves outside B\'s uploads directory, refusing to import it: ' . $rel_path,
			);
			continue;
		}
		
		$title    = isset( $row['title'] ) ? (string) $row['title'] : '';
		try {
			$result = sitegraft_media_import_one( $old_id, $abs_path, $title );
		} catch ( Throwable $e ) {
			$result = array( 'ok' => false, 'new_id' => null, 'error' => $e->getMessage() );
		}
		if ( $result['ok'] ) {
			update_post_meta( $result['new_id'], '_sitegraft_source_id', $old_id );
			$imported_map[ (string) $old_id ] = (int) $result['new_id'];
		} else {
			$failed[] = array( 'old' => $old_id, 'error' => (string) $result['error'] );
		}
	}

	// The subset of $existing_map actually requested this call — scoped
	// deliberately (not the full B-wide $existing_map) so id-map.tsv is
	// only ever rewritten from entries this run actually asked about, even
	// if some unrelated _sitegraft_source_id-tagged post somehow survived
	// graft_prune_previous_run.
	$already_present_map = array();
	foreach ( array_diff( $requested_old_ids, $missing ) as $old_id ) {
		$already_present_map[ (string) $old_id ] = $existing_map[ (string) $old_id ];
	}

	return sitegraft_media_build_report( $requested_old_ids, $imported_map, $already_present_map, $no_local_file, $failed );
}
