<?php
/**
 * lib/php/wxr-item-ids-cli.php — issue #53/#54 fix-pack, BLOCKER-1/BLOCKER-2.
 * Orchestrator-local CLI driver behind lib/graft.sh's
 * graft_verify_import_completeness, the same "pure parse, run entirely
 * locally, no WordPress bootstrap, no round-trip to A or B" shape
 * lib/php/verify-content-remap-cli.php already has for issue #52's guards
 * (see that file's own header) — this is the second production caller of
 * lib/php/wxr-content-functions.php, not a third parser.
 *
 * Replaces graft_verify_import_completeness's own former awk-based, line-
 * oriented scan of the staged WXR — that scan was BOTH review blockers in
 * this fix-pack at once:
 *
 *   BLOCKER-1 (fails OPEN): the awk assigned id/type unconditionally on
 *   every line matching `/<wp:post_id>/` or `/<wp:post_type>/`, last
 *   write wins, with no notion of "this line is inside a DIFFERENT
 *   element's own CDATA body". A `<content:encoded>` value that happens to
 *   contain the literal text `<wp:post_type>attachment</wp:post_type>`
 *   (a real, reachable case — content copy-pasted from another WXR export,
 *   or just describing one) overwrote that item's real type with
 *   "attachment" and silently exempted it. It also could not see a tag
 *   whose open/close were split across lines, or a value it just never
 *   recognized — with the previous code's own "found nothing, so treat it
 *   as nothing to check" default, either one passed silently.
 *
 *   BLOCKER-2 (fails FALSE): wp-cli's own real exporter frequently puts an
 *   item's <wp:post_id> and <wp:post_type> on the SAME physical line as
 *   each OTHER item's, or as unrelated markup. The awk's four rules all
 *   matched against `$0` (the whole line) and `gsub`'d it — two items
 *   sharing one line fired every rule against both, producing a garbled
 *   half-XML "id"/"type" pair for one of them instead of the real values.
 *
 * XMLReader (lib/php/wxr-content-functions.php) parses actual document
 * STRUCTURE — an <item>'s own direct children, resolved by namespace URI,
 * regardless of line layout or of what unrelated CDATA elsewhere in the
 * document happens to contain — so neither shape above is reachable here
 * by construction, not by a sharper regex. See that file's own header for
 * the streaming/memory and entity-safety properties this inherits for
 * free.
 *
 * Usage: `php wxr-item-ids-cli.php <wxr-file> [<wxr-file> ...]`. Prints
 * NDJSON to stdout on success — one compact `{"post_id":N,"post_type":
 * "..."}` object per well-formed <item> (one carrying both wp:post_id and
 * wp:post_type — see wxr-content-functions.php's own
 * _sitegraft_wxr_item_from_node for what "well-formed" means here),
 * WRITTEN AS SOON as each item streams in, across every file given, in
 * argv order — same NDJSON-not-array-of-everything shape verify-content-
 * remap-cli.php uses and for the identical reason (a single json_encode()
 * over the whole result was a real, measured memory blowup on a large
 * export — see that file's own comment).
 *
 * Exits 1, with a message on STDERR and NOTHING on stdout, the moment ANY
 * listed file is unreadable OR fails to parse at all
 * (sitegraft_stream_wxr_items_from_file returning false — an empty/
 * missing/malformed file, or one whose <wp:wxr_version> isn't "1.2"; see
 * that function's own header for the full list) — never a partial or
 * silently-empty result standing in for "this file could not be trusted".
 * This is what closes BLOCKER-1's third manifestation at the caller's
 * level: a WXR file present but genuinely unparseable used to read as
 * "zero items found, nothing to check, pass" one layer up; this driver
 * now makes that a hard, loud failure instead, and
 * graft_verify_import_completeness (lib/graft.sh) propagates it as one.
 */

require_once __DIR__ . '/wxr-content-functions.php';

function wxr_item_ids_cli_fail( $message ) {
	fwrite( STDERR, "wxr-item-ids-cli: {$message}\n" );
	exit( 1 );
}

if ( $argc < 2 ) {
	wxr_item_ids_cli_fail( 'usage: php wxr-item-ids-cli.php <wxr-file> [<wxr-file> ...]' );
}

$emit_item = function ( $item ) {
	echo json_encode(
		array(
			'post_id'   => $item['post_id'],
			'post_type' => $item['post_type'],
		)
	) . "\n";
};

for ( $i = 1; $i < $argc; $i++ ) {
	$file = $argv[ $i ];
	if ( ! is_readable( $file ) ) {
		wxr_item_ids_cli_fail( "WXR file not found or unreadable: {$file}" );
	}
	$ok = sitegraft_stream_wxr_items_from_file( $file, $emit_item );
	if ( ! $ok ) {
		wxr_item_ids_cli_fail( "WXR file did not parse as valid XML, or is empty: {$file}" );
	}
}
