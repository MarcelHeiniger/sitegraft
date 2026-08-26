<?php
/**
 * lib/php/verify-content-remap-cli.php — issue #52. Orchestrator-local CLI
 * driver behind lib/verify.sh's content-equality guard
 * (verify_migrated_content_matches_source / the shared
 * _verify_wxr_items_remapped helper).
 *
 * ADR 0008's "Required regardless" list says the guard must compare B's
 * post_content to "A's after the same domain and ID remaps the graft
 * applies... applied to A's copy on the orchestrator" — this file is
 * exactly that application, run entirely LOCALLY (no wp-cli, no SSH, no
 * WordPress bootstrap, no round-trip to A or B): it reads the WXR file(s)
 * `sitegraft graft` already exported into the run dir (lib/graft.sh's
 * graft_export_wxr, still on disk after the run), parses them with
 * lib/php/wxr-content-functions.php's sitegraft_parse_wxr_items, and
 * rewrites each item's content/excerpt with the EXACT SAME two pure
 * functions graft's own remap steps call — lib/php/content-remap-
 * functions.php's sitegraft_remap_attachment_refs and
 * sitegraft_remap_domain — never a third, independently-drifting
 * reimplementation of "what graft was supposed to produce".
 *
 * Applied in the SAME order and the SAME per-post-type scope
 * graft_remap_attachment_ids/graft_search_replace_domain (lib/graft.sh) use
 * against B: attachment-id remap first, and — the one place this mirrors a
 * real asymmetry in graft's own scope, not an oversight — skipped entirely
 * for a wp_navigation item (graft_remap_attachment_ids' own header
 * explains why: a wp_navigation post's `"id":N` can be a TERM id or a POST
 * id under the identical JSON key, and blindly substituting would risk
 * corrupting a taxonomy-kind reference that was never about an attachment).
 * The domain remap runs second, and is NOT scoped that way — it applies to
 * every item, wp_navigation included, exactly like
 * graft_search_replace_domain's own real write does.
 *
 * "wp_navigation" is hardcoded below, not a payload option (review finding
 * n3): this driver has exactly one production caller
 * (_verify_wxr_items_remapped, lib/verify.sh), which always wants graft's
 * own real exclusion rule — a payload-configurable value here would be
 * configurability nothing in the codebase actually uses, and the kind of
 * unused generality that invites drift between "what the payload can say"
 * and "what graft itself actually does".
 *
 * Usage: `php verify-content-remap-cli.php <payload.json>`, payload shape:
 *   {
 *     "wxr_files": ["/abs/path/export/one.xml", ...],
 *     "attachments": [{"old": "7", "new": "42"}, ...],
 *     "domain": {"from": "https://a.example.com", "to": "https://b.example.com"}
 *   }
 * "domain" is optional (defaults to {"from":"","to":""} — an empty "from"
 * is graft's own documented "no domain configured" no-op, see
 * sitegraft_remap_domain's own header). Prints a JSON array of
 * {post_id, post_type, post_content, post_excerpt} — one per WXR item
 * found, across every listed file, in
 * document order — to stdout on success. lib/verify.sh's own caller is
 * responsible for filtering this down to whichever post_ids it actually
 * needs (id-map.tsv's migrated rows for the equality guard, or the full set
 * for the pre-graft-unchanged guard); this driver does not know about
 * id-map.tsv at all, on purpose, so it stays a pure "parse + remap"
 * function of its payload with no other run_dir file as a hidden input.
 *
 * Exits non-zero with a message on STDERR — never a silent empty result —
 * for every failure mode a caller must not confuse with "genuinely zero
 * items": a missing/unreadable payload or WXR file, a WXR file that fails
 * to parse at all (review finding m1 — lib/php/wxr-content-functions.php's
 * streaming parser returns `false`, distinct from a real empty `[]`, for
 * exactly this), or a payload that is not valid JSON. A WXR file that
 * parses fine and genuinely has zero <item>s (e.g. the export selected
 * nothing) is NOT one of those — that reaches stdout as `[]` with exit 0.
 *
 * Reads each WXR file directly off disk via sitegraft_parse_wxr_items_
 * from_file / sitegraft_stream_wxr_items_from_file (issue #52 fix-pack,
 * review finding M1) — never file_get_contents() into a PHP string first,
 * and remaps each item as it streams in rather than collecting a whole
 * unremapped copy before a second pass: peak memory here tracks one
 * item's size, not the export's total size, the same property
 * wxr-content-functions.php's own streaming gives per file — see that
 * file's own header comment for the measurements (a 62MB export was fatal
 * under DOMDocument at 256M memory_limit; this driver's own test stays
 * under 32M on a comparable synthetic export).
 */

require_once __DIR__ . '/wxr-content-functions.php';
require_once __DIR__ . '/content-remap-functions.php';

function verify_content_remap_cli_fail( $message ) {
	fwrite( STDERR, "verify-content-remap-cli: {$message}\n" );
	exit( 1 );
}

$payload_path = $argv[1] ?? null;
if ( ! $payload_path ) {
	verify_content_remap_cli_fail( 'usage: php verify-content-remap-cli.php <payload.json>' );
}
if ( ! is_readable( $payload_path ) ) {
	verify_content_remap_cli_fail( "payload file not found or unreadable: {$payload_path}" );
}

$payload_raw = file_get_contents( $payload_path );
$payload = json_decode( (string) $payload_raw, true );
if ( ! is_array( $payload ) ) {
	verify_content_remap_cli_fail( "payload is not valid JSON: {$payload_path}" );
}

$wxr_files     = $payload['wxr_files'] ?? array();
$attachments   = $payload['attachments'] ?? array();
$nav_post_type = 'wp_navigation'; // review finding n3 — see this file's own header
$domain_from   = $payload['domain']['from'] ?? '';
$domain_to     = $payload['domain']['to'] ?? '';

$has_attachments = ! empty( $attachments );
$has_domain      = $domain_from !== '';

// One pass per file, remapping each item the moment it streams in --
// never a first pass that collects every item unremapped, followed by a
// second pass that remaps and collects again (that shape was itself part
// of review finding M1: peak memory tracked TWO full copies of the
// export's items, not one).
$out = array();
$remap_and_collect = function ( $item ) use ( &$out, $attachments, $has_attachments, $has_domain, $nav_post_type, $domain_from, $domain_to ) {
	$content = $item['post_content'];
	$excerpt = $item['post_excerpt'];

	if ( $has_attachments && $item['post_type'] !== $nav_post_type ) {
		$content = sitegraft_remap_attachment_refs( $attachments, $content );
		$excerpt = sitegraft_remap_attachment_refs( $attachments, $excerpt );
	}
	if ( $has_domain ) {
		$content = sitegraft_remap_domain( $content, $domain_from, $domain_to );
		$excerpt = sitegraft_remap_domain( $excerpt, $domain_from, $domain_to );
	}

	$out[] = array(
		'post_id'      => $item['post_id'],
		'post_type'    => $item['post_type'],
		'post_content' => $content,
		'post_excerpt' => $excerpt,
	);
};

foreach ( $wxr_files as $file ) {
	if ( ! is_readable( $file ) ) {
		verify_content_remap_cli_fail( "WXR file not found or unreadable: {$file}" );
	}
	$ok = sitegraft_stream_wxr_items_from_file( $file, $remap_and_collect );
	if ( ! $ok ) {
		verify_content_remap_cli_fail( "WXR file did not parse as valid XML, or is empty: {$file}" );
	}
}

echo json_encode( $out );
