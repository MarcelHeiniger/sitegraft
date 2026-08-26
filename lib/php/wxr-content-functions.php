<?php
/**
 * lib/php/wxr-content-functions.php — parses a WordPress WXR export file
 * into its <item> entries (issue #52, lib/verify.sh's content-equality
 * guards). Pure PHP, no WordPress bootstrap: DOMDocument + XPath — the same
 * "directly testable with a bare `php` CLI" property
 * lib/php/content-remap-functions.php's own pure functions have (see that
 * file's own header for why that property matters here), and `require`d
 * alongside it by lib/php/verify-content-remap-cli.php, this file's only
 * production caller.
 *
 * Deliberately NOT a regex/grep-based extraction like graft_integrity_gate's
 * own <wp:post_type> scan (lib/graft.sh) — that shortcut is safe there
 * because post_type is never CDATA-wrapped by wp-cli's own exporter
 * (verified against WP_Export_WXR_Formatter.php, see that function's own
 * comment). content:encoded/excerpt:encoded ARE CDATA-wrapped, and
 * WordPress's own exporter escapes a literal "]]>" inside CDATA content by
 * splitting it into two adjacent CDATA sections
 * ("before]]" . "]]><![CDATA[" . ">after") — a real, documented WXR export
 * behavior, not a hypothetical edge case, and exactly the shape a naive
 * `<!\[CDATA\[(.*?)\]\]>` regex truncates on. DOMDocument merges sibling
 * CDATA sections into one logical value via ->textContent, which is why
 * this file uses it instead of a regex (see this file's own test,
 * tests/unit/test_wxr_content_functions.bats, for the exact byte sequence
 * this reassembles).
 *
 * Namespace URIs below (wp/content/excerpt) are WordPress's own, stable
 * across WXR 1.0/1.1/1.2 — not read from the document's own xmlns
 * declarations, on purpose: XPath's registerNamespace binds a PREFIX to a
 * URI for use in the query string, and this file's own queries are written
 * against the URIs it knows content:encoded/excerpt:encoded/wp:post_id
 * actually live at, not against whatever prefix a given export happened to
 * choose (WXR always uses these fixed URIs regardless of which prefix
 * string a producer picks for them).
 */

/**
 * sitegraft_parse_wxr_items( string $xml_string ): array
 *
 * Returns an array of ['post_id' => int, 'post_type' => string,
 * 'post_content' => string, 'post_excerpt' => string], one per <item> in
 * document order. An <item> missing wp:post_id or wp:post_type is skipped
 * outright — not guessed at (a malformed item is not this function's job to
 * repair); content:encoded/excerpt:encoded default to '' when the item
 * genuinely has none (e.g. an attachment item with no excerpt), which is a
 * real, valid WXR shape, not an error.
 *
 * Fails CLOSED on unparsable input: libxml errors are captured (never
 * printed/fatal) and an empty array is returned rather than a PHP warning
 * or exception reaching the caller — the caller (lib/verify.sh, via
 * lib/php/verify-content-remap-cli.php) is responsible for treating "found
 * zero items in a file that was supposed to have some" as its own
 * INCOMPLETE/HARD-FAIL signal; this function's contract is just "never
 * crash, never fabricate an item that wasn't really there."
 */
function sitegraft_parse_wxr_items( $xml_string ) {
	$doc = new DOMDocument();
	$previous = libxml_use_internal_errors( true );
	$ok = $doc->loadXML( (string) $xml_string, LIBXML_NONET );
	libxml_clear_errors();
	libxml_use_internal_errors( $previous );
	if ( ! $ok ) {
		return array();
	}

	$xpath = new DOMXPath( $doc );
	$xpath->registerNamespace( 'wp', 'http://wordpress.org/export/1.2/' );
	$xpath->registerNamespace( 'content', 'http://purl.org/rss/1.0/modules/content/' );
	$xpath->registerNamespace( 'excerpt', 'http://wordpress.org/export/1.2/excerpt/' );

	$items = array();
	$item_nodes = $xpath->query( '//item' );
	if ( ! $item_nodes ) {
		return array();
	}
	foreach ( $item_nodes as $item_node ) {
		$post_id_node   = $xpath->query( 'wp:post_id', $item_node )->item( 0 );
		$post_type_node = $xpath->query( 'wp:post_type', $item_node )->item( 0 );
		if ( ! $post_id_node || ! $post_type_node ) {
			continue; // not a well-formed WXR <item> — skip rather than guess.
		}
		$content_node = $xpath->query( 'content:encoded', $item_node )->item( 0 );
		$excerpt_node = $xpath->query( 'excerpt:encoded', $item_node )->item( 0 );

		$items[] = array(
			'post_id'      => (int) trim( $post_id_node->textContent ),
			'post_type'    => trim( $post_type_node->textContent ),
			'post_content' => $content_node ? $content_node->textContent : '',
			'post_excerpt' => $excerpt_node ? $excerpt_node->textContent : '',
		);
	}
	return $items;
}
