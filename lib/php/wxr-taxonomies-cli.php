<?php
/**
 * lib/php/wxr-taxonomies-cli.php — issue #82. Orchestrator-local CLI
 * driver, invoked as a subprocess from lib/verify.sh's
 * verify_taxonomy_terms_present, the sibling of lib/php/wxr-item-ids-
 * cli.php (issue #53/#54's own driver — see that file's header for why
 * XMLReader over the staged WXR is the discipline this codebase already
 * settled on for this exact document, and why a second, independently-
 * drifting parser is not built here).
 *
 * Reads the staged WXR export(s) the SAME structural way that driver
 * reads <item> elements, but for a different question: not "what did
 * this run migrate", but "which (taxonomy, slug) term pairs does this
 * export itself declare" — via sitegraft_parse_wxr_terms_from_file
 * (lib/php/wxr-content-functions.php), reading each <wp:term>'s own
 * wp:term_taxonomy/wp:term_slug children.
 *
 * WHY THIS EXISTS: issue #53's own completeness gate
 * (graft_verify_import_completeness, lib/graft.sh) counts POSTS. A post
 * whose taxonomy terms were silently dropped by wordpress-importer —
 * because the taxonomy that defines them was not yet registered on B
 * when `wp import` ran, the same ordering defect issue #16 closed for
 * POST TYPES one level up — still lands, still counts as expected ==
 * actual, and #53 reports PASS. This driver feeds a guard that asks the
 * TERM-level question #53 structurally cannot: for every term the export
 * declares, does a term with that exact taxonomy+slug now exist on B.
 *
 * Deliberately reads ONLY the WXR's own document structure, never a
 * plugin's option (Etch's etch_taxonomies or otherwise) — this is what
 * keeps the resulting guard module-agnostic: it closes the gap for ANY
 * future module with the identical shape, not just Etch's, and never
 * has to guess at, or trust, a plugin's own option-value shape to do it.
 *
 * Usage: `php wxr-taxonomies-cli.php <wxr-file> [<wxr-file> ...]`. Prints
 * NDJSON to stdout on success — one compact `{"taxonomy":"...","slug":
 * "...","name":"..."}` object per <wp:term> that carries a non-empty
 * wp:term_taxonomy, across every file given, in argv order. Not
 * deduplicated here — lib/verify.sh's own caller dedupes via `jq`, the
 * same division of labor wxr-item-ids-cli.php's own NDJSON output has
 * with its bash-side callers.
 *
 * Exits 1, with a message on STDERR, the moment ANY listed file is
 * unreadable OR fails to parse at all — same fail-closed contract as
 * wxr-item-ids-cli.php's own (see that file's header for the full
 * reasoning): a WXR this run staged that cannot be trusted must never
 * read as "declares no terms", which would silently defeat the very
 * guard this driver exists to feed.
 */

require_once __DIR__ . '/wxr-content-functions.php';

function wxr_taxonomies_cli_fail( $message ) {
	fwrite( STDERR, "wxr-taxonomies-cli: {$message}\n" );
	exit( 1 );
}

if ( $argc < 2 ) {
	wxr_taxonomies_cli_fail( 'usage: php wxr-taxonomies-cli.php <wxr-file> [<wxr-file> ...]' );
}

for ( $i = 1; $i < $argc; $i++ ) {
	$file = $argv[ $i ];
	if ( ! is_readable( $file ) ) {
		wxr_taxonomies_cli_fail( "WXR file not found or unreadable: {$file}" );
	}
	$terms = sitegraft_parse_wxr_terms_from_file( $file );
	if ( false === $terms ) {
		wxr_taxonomies_cli_fail( "WXR file did not parse as valid XML, or is empty: {$file}" );
	}
	foreach ( $terms as $term ) {
		echo json_encode( $term ) . "\n";
	}
}
