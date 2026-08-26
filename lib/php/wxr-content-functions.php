<?php
/**
 * lib/php/wxr-content-functions.php — parses a WordPress WXR export file
 * into its <item> entries (issue #52, lib/verify.sh's content-equality
 * guards). Pure PHP, no WordPress bootstrap: XMLReader — the same
 * "directly testable with a bare `php` CLI" property lib/php/content-remap-
 * functions.php's own pure functions have (see that file's own header for
 * why that property matters here). Two production callers as of issue #72:
 * lib/php/verify-content-remap-cli.php (`require`s it alongside content-
 * remap-functions.php) and lib/php/wxr-item-ids-cli.php (behind
 * lib/graft.sh's graft_integrity_gate and graft_verify_import_completeness
 * — the security/completeness gates a hand-edited or malicious WXR file
 * must not be able to quietly defeat).
 *
 * Streamed with XMLReader, NOT DOMDocument::loadXML() on the whole
 * document (issue #52 fix-pack, review finding M1 — measured, not assumed):
 * building a full in-memory DOM tree costs roughly 3-8x the source file's
 * bytes in peak RSS. An 18.7MB real export peaked at 161MB RSS; a 62MB
 * export was FATAL at both 128M and 256M memory_limit — and still fatal
 * when split into wp-cli's own default ~12MB-per-file chunks, because the
 * DOM cost is per NODE, not per FILE, and the driver accumulated every
 * file's parsed items into one array before ever calling json_encode.
 * XMLReader walks the document node by node without ever materializing
 * more than the CURRENT <item>'s own subtree (XMLReader::expand() builds a
 * DOM fragment for exactly one node, discarded the moment the reader
 * advances past it) — peak memory becomes roughly one item's size, not the
 * whole file's, regardless of how many items or how large the file is.
 *
 * Two entry points, same underlying streamer:
 *   - sitegraft_parse_wxr_items( string $xml_string ): the string-based
 *     form kept for exactly the callers/tests that already have the bytes
 *     in memory (still avoids DOMDocument's per-node multiplier — only the
 *     one string itself is held, not a parsed tree of it).
 *   - sitegraft_parse_wxr_items_from_file( string $file_path ): reads
 *     directly off disk via XMLReader::open(), never holding the whole
 *     file's bytes as a PHP string at all. This is what
 *     lib/php/verify-content-remap-cli.php actually calls in production —
 *     see that file's own comment.
 * Both return an array of items on success, or `false` (review finding
 * m1) — NEVER `[]` — when the input could not be parsed as XML at all
 * (unreadable file, malformed document, or a document with no nodes
 * whatsoever). `[]` is reserved for a document that DID parse and
 * genuinely contains zero <item> elements (a real, valid WXR shape — e.g.
 * an export whose selected post_types produced nothing). Before this fix
 * both cases returned `[]`, indistinguishable from each other; a caller
 * (lib/php/verify-content-remap-cli.php) that treated `[]` as "nothing to
 * verify, carry on" could not tell "this file is corrupt" from "this file
 * legitimately has nothing in it".
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
 * `<!\[CDATA\[(.*?)\]\]>` regex truncates on. DOM ->textContent (built for
 * one <item> at a time via XMLReader::expand(), never for the whole
 * document) merges sibling CDATA sections into one logical value, which is
 * why this file uses DOM node traversal rather than a regex (see this
 * file's own test, tests/unit/test_wxr_content_functions.bats, for the
 * exact byte sequence this reassembles).
 *
 * The three namespace URIs this file matches against (one each for
 * wp:post_id/wp:post_type, content:encoded, excerpt:encoded) are three
 * DIFFERENT URIs — not "the same" in any sense — but each one
 * individually is WordPress's own and has not changed across any WXR
 * version that has ever shipped (1.0 through 1.2). They are hardcoded
 * here, not read from the document's own xmlns declarations, and that is
 * safe: this file never registers a namespace PREFIX and queries against
 * it (which would only match that literal prefix string) — it compares
 * each child node's own resolved namespaceURI directly
 * (_sitegraft_wxr_child_text, below), which DOM computes for us from
 * whatever prefix binding the document actually declared. A document
 * that declares these three URIs under different prefixes than
 * wp:/content:/excerpt: still parses correctly here for exactly that
 * reason.
 *
 * Entity safety (issue #52 fix-pack, execution-verified, not assumed):
 * `LIBXML_NONET` blocks network-based external entity/DTD fetches;
 * `LIBXML_NOENT` is never passed, so entities are never substituted in the
 * first place — an XXE payload referencing a local file
 * (`<!ENTITY xxe SYSTEM "file:///etc/passwd">` and `&xxe;` in a text node)
 * comes back as the LITERAL, unexpanded entity reference text, never the
 * file's contents, and an entity-expansion ("billion laughs") payload
 * never actually expands, so it costs nothing to walk. Both are covered by
 * this file's own tests, not merely asserted in this comment.
 */

/**
 * sitegraft_parse_wxr_items( string $xml_string ): array|false
 *
 * See this file's own header for the full contract (array of items on
 * success, `false` — never `[]` — on anything that failed to parse).
 */
function sitegraft_parse_wxr_items( $xml_string ) {
	$items = array();
	$ok = sitegraft_stream_wxr_items_from_string(
		(string) $xml_string,
		function ( $item ) use ( &$items ) {
			$items[] = $item;
		}
	);
	return $ok ? $items : false;
}

/**
 * sitegraft_parse_wxr_items_from_file( string $file_path ): array|false
 *
 * Same contract as sitegraft_parse_wxr_items above, reading directly off
 * disk (XMLReader::open()) rather than requiring the caller to hold the
 * whole file's bytes as a PHP string first — the form
 * lib/php/verify-content-remap-cli.php actually calls in production.
 */
function sitegraft_parse_wxr_items_from_file( $file_path ) {
	$items = array();
	$ok = sitegraft_stream_wxr_items_from_file(
		$file_path,
		function ( $item ) use ( &$items ) {
			$items[] = $item;
		}
	);
	return $ok ? $items : false;
}

/**
 * sitegraft_stream_wxr_items_from_string( string $xml_string, callable $emit, &$items_seen = null ): bool
 * sitegraft_stream_wxr_items_from_file( string $file_path, callable $emit, &$items_seen = null ): bool
 *
 * The actual streaming entry points: $emit is called once per WELL-FORMED
 * <item> (one carrying both wp:post_id and wp:post_type — see
 * _sitegraft_wxr_item_from_node below), with that item's array, as soon as
 * it is read — never all items held in memory by THIS layer.
 * sitegraft_parse_wxr_items(_from_file) above are the array-collecting
 * convenience wrappers most callers actually want; a caller that itself
 * needs to stay memory-bounded across a very large export can call these
 * directly and process each item as it arrives instead of collecting them
 * all.
 *
 * $items_seen (issue #73 — a real gate-bypass measured against a real
 * harness, not a theoretical hardening): an optional by-reference OUT
 * parameter, set to the number of `<item>` ELEMENTS this call encountered
 * structurally, regardless of whether each one turned out well-formed
 * enough to reach $emit. A caller that only reads $emit's own items has no
 * way to tell "this document had 3 well-formed items and nothing else"
 * apart from "this document had 3 well-formed items AND one malformed one
 * that was silently dropped" — for a caller enforcing or verifying
 * something SECURITY-relevant about every <item> in the file (e.g.
 * lib/graft.sh's graft_integrity_gate, checking post_type against an
 * allowlist), that distinction is the whole point: a malformed item is
 * exactly where a value the allowlist was supposed to catch could be
 * hiding. Comparing this against a running count of $emit's own calls
 * lets such a caller fail closed on any mismatch, instead of only ever
 * seeing the items that happened to parse. Omitted by a caller that
 * doesn't pass a variable (the default, `null`) — every existing call
 * site before this parameter existed keeps working unchanged; the
 * driver internally always initializes it to `0` regardless, so a
 * caller that DOES pass one never reads an uninitialized value even on a
 * document with zero items or an early failure.
 */
function sitegraft_stream_wxr_items_from_string( $xml_string, callable $emit, &$items_seen = null ) {
	// PHP 8's XMLReader::XML() throws a ValueError (a real fatal, not
	// something `@` silences) on an empty string rather than simply
	// failing to open -- guarded explicitly so "empty input" fails closed
	// the same way every other unparsable input does, never a crash.
	$items_seen = 0;
	if ( '' === $xml_string ) {
		return false;
	}
	$reader = new XMLReader();
	$previous = libxml_use_internal_errors( true );
	$opened = @$reader->XML( $xml_string, null, LIBXML_NONET );
	return _sitegraft_stream_wxr_reader( $reader, $opened, $previous, $emit, $items_seen );
}

function sitegraft_stream_wxr_items_from_file( $file_path, callable $emit, &$items_seen = null ) {
	$items_seen = 0;
	$reader = new XMLReader();
	$previous = libxml_use_internal_errors( true );
	$opened = @$reader->open( (string) $file_path, null, LIBXML_NONET );
	return _sitegraft_stream_wxr_reader( $reader, $opened, $previous, $emit, $items_seen );
}

/**
 * _sitegraft_stream_wxr_reader( XMLReader $reader, bool $opened, bool
 * $previous_error_setting, callable $emit, &$items_seen = null ): bool —
 * shared driver loop for both entry points above (see their own docblock
 * for what $items_seen is and why). Fails CLOSED: any of "could not open/parse at
 * all", "libxml recorded a FATAL parse error along the way", or "the
 * document had no nodes whatsoever" (an empty file — not the same as a
 * well-formed-but-itemless one, which DOES have root/channel nodes before
 * ever reaching an <item>) return false, never a partially-collected
 * result presented as complete.
 *
 * "FATAL" specifically (review round 2 finding, execution-verified): an
 * earlier version failed the WHOLE file on ANY recorded libxml error,
 * including a RECOVERABLE warning (LIBXML_ERR_WARNING, level 1) or a
 * non-fatal error (LIBXML_ERR_ERROR, level 2) — e.g. a single <item>
 * carrying an undeclared namespace prefix on one unrelated element. XML
 * parsers, and libxml specifically, routinely keep parsing past those and
 * still produce a usable document; "the parser logged a warning about one
 * thing" is not the same claim as "this file did not parse", and treating
 * them the same made both content guards HARD FAIL a WXR export that
 * genuinely parsed fine except for one cosmetic issue. Only
 * LIBXML_ERR_FATAL (level 3 — the document is genuinely unusable past
 * this point) fails the parse now.
 */
function _sitegraft_stream_wxr_reader( XMLReader $reader, $opened, $previous_error_setting, callable $emit, &$items_seen = null ) {
	if ( null === $items_seen ) {
		$items_seen = 0;
	}
	if ( ! $opened ) {
		libxml_clear_errors();
		libxml_use_internal_errors( $previous_error_setting );
		return false;
	}

	$saw_any_node = false;
	$wxr_version = null;
	// issue #70: this loop's condition variable is ALSO what advances the
	// reader for the item branch below (next(), not read() -- see that
	// branch's own comment) so that branch's `continue` re-checks this
	// same $advanced instead of the top of the loop calling read() again.
	// An earlier version called read() unconditionally at the top of a
	// `while (true)` loop, INCLUDING on the iteration right after the item
	// branch had already advanced the reader with next() -- a double
	// advance. Sibling whitespace (wp-cli's own `wp export` always
	// indents) or any other node between two <item>s absorbed that extra
	// step harmlessly; a minified/re-serialized/hand-edited WXR with two
	// <item>s directly adjacent (no node between them at all) had nothing
	// for the extra step to land on, so it stepped straight over the
	// second <item> and silently dropped it -- no error, just a short
	// result (tests/unit/test_wxr_content_functions.bats, issue #70).
	$advanced = @$reader->read();
	while ( $advanced ) {
		$saw_any_node = true;
		// Review round 2 minor finding: this file's own namespace URIs are
		// hardcoded to WXR 1.2's (see this file's own header) -- a 1.0 or
		// 1.1 document declares wp:/content:/excerpt: under DIFFERENT URIs
		// (WordPress has never kept these stable across major WXR
		// revisions, unlike this file's own earlier claim), so its <item>
		// elements silently match NOTHING and this function used to
		// return a real, empty `[]` for them -- indistinguishable from a
		// genuinely itemless 1.2 export. wp:wxr_version's own text is
		// checked by localName alone (not by namespace, for the same
		// reason its <item> children aren't found under the 1.2 URI in an
		// older document) so a non-1.2 document fails closed explicitly
		// instead of silently reporting zero items. wp-cli's own `wp
		// export` has only ever emitted 1.2 (see graft_integrity_gate's
		// own comment, lib/graft.sh), so this has no practical
		// consequence for a real graft -- it only prevents THIS class of
		// silent-zero from resurfacing for a hand-supplied or third-party
		// WXR file.
		if ( $reader->nodeType === XMLReader::ELEMENT && $reader->localName === 'wxr_version' && null === $wxr_version ) {
			$wxr_version = trim( (string) @$reader->readString() );
		}
		if ( $reader->nodeType === XMLReader::ELEMENT
			&& $reader->localName === 'item'
			&& $reader->namespaceURI === '' ) {
			// Counted for EVERY <item> element matched here, regardless of
			// whether it turns out well-formed enough to $emit() below
			// (review, issue #73 -- see this function's own header for why
			// this exists and what it closed). Incremented in the exact
			// branch that decides "this is an <item>", not by a second,
			// independent traversal -- guaranteed to move in lockstep with
			// $emit, never able to drift from it the way a separate
			// item-counting pass could.
			$items_seen++;
			// @-suppressed like read()/next() above -- a truncated/unclosed
			// document can make expand() emit a PHP-level warning on top of
			// libxml's own recorded error; the explicit instanceof check right
			// below (and the fatal-error scan at the end of this function) is
			// what this file actually acts on, not PHP's own runtime notice.
			$node = @$reader->expand();
			if ( $node instanceof DOMNode ) {
				$item = _sitegraft_wxr_item_from_node( $node );
				if ( null !== $item ) {
					$emit( $item );
				}
			}
			// Move past this element's subtree without re-walking it node
			// by node — next() advances to the element's next sibling,
			// which is also what releases the DOM fragment expand() built
			// for it. Its return value IS this loop's advance for the next
			// iteration (see this function's own comment above the loop) —
			// the top of the loop must NOT also call read() here, or a
			// tightly adjacent next <item> (no node between the two) gets
			// stepped over and silently dropped (issue #70).
			$advanced = @$reader->next();
			continue;
		}
		$advanced = @$reader->read();
	}
	$fatal_errors = array_filter(
		libxml_get_errors(),
		function ( $error ) {
			return $error->level >= LIBXML_ERR_FATAL;
		}
	);
	$had_errors = count( $fatal_errors ) > 0;
	libxml_clear_errors();
	libxml_use_internal_errors( $previous_error_setting );
	$reader->close();

	if ( $had_errors || ! $saw_any_node ) {
		return false;
	}
	if ( null !== $wxr_version && '1.2' !== $wxr_version ) {
		return false;
	}
	return true;
}

/**
 * _sitegraft_wxr_item_from_node( DOMNode $item_node ): array|null
 *
 * Extracts one <item>'s fields. Returns null (skip, don't guess) for an
 * <item> missing wp:post_id or wp:post_type — the same "not a well-formed
 * WXR <item>" refusal the previous DOMXPath-based version had.
 * content:encoded/excerpt:encoded default to '' when genuinely absent
 * (e.g. an attachment item with no excerpt) — a real, valid WXR shape, not
 * an error.
 */
function _sitegraft_wxr_item_from_node( DOMNode $item_node ) {
	$post_id_text = _sitegraft_wxr_child_text( $item_node, 'http://wordpress.org/export/1.2/', 'post_id' );
	$post_type_text = _sitegraft_wxr_child_text( $item_node, 'http://wordpress.org/export/1.2/', 'post_type' );
	if ( null === $post_id_text || null === $post_type_text ) {
		return null;
	}
	$content = _sitegraft_wxr_child_text( $item_node, 'http://purl.org/rss/1.0/modules/content/', 'encoded' );
	$excerpt = _sitegraft_wxr_child_text( $item_node, 'http://wordpress.org/export/1.2/excerpt/', 'encoded' );

	return array(
		'post_id'      => (int) trim( $post_id_text ),
		'post_type'    => trim( $post_type_text ),
		'post_content' => null !== $content ? $content : '',
		'post_excerpt' => null !== $excerpt ? $excerpt : '',
	);
}

/**
 * _sitegraft_wxr_child_text( DOMNode $parent, string $namespace_uri,
 * string $local_name ): string|null — the first direct child element of
 * $parent matching ($namespace_uri, $local_name), or null if none exists.
 * Direct DOM traversal, not XPath: expand()'s subtree is small (one
 * <item>), so a plain childNodes walk is simpler than standing up a
 * DOMXPath (which needs its own namespace registration) for the same
 * result.
 */
function _sitegraft_wxr_child_text( DOMNode $parent, $namespace_uri, $local_name ) {
	foreach ( $parent->childNodes as $child ) {
		if ( XML_ELEMENT_NODE === $child->nodeType
			&& $child->localName === $local_name
			&& $child->namespaceURI === $namespace_uri ) {
			return $child->textContent;
		}
	}
	return null;
}
