<?php
/**
 * lib/php/wxr-item-ids-cli.php — issue #53/#54 fix-pack, BLOCKER-1/BLOCKER-2.
 * Orchestrator-local CLI driver, invoked as a subprocess from TWO bash
 * functions in lib/graft.sh: graft_verify_import_completeness (this
 * driver's original caller) and graft_integrity_gate (issue #72). It is
 * itself the SECOND PHP-level `require`r of lib/php/wxr-content-
 * functions.php — verify-content-remap-cli.php (issue #52's own guards,
 * see that file's own header) is the first; the two never interact
 * directly with each other, only both with that one shared parser.
 *
 * graft_integrity_gate used to run its own separate, narrower
 * `grep -o ... | sed` scan of the same kind of file, for a different
 * check, until that scan's own greediness across two <item>s sharing one
 * physical line produced a garbled "leaked post_type" that aborted a
 * graft before graft_verify_import_completeness's own gate (the one THIS
 * driver was originally built for) ever got a chance to run — measured
 * live, not theoretical; see graft_integrity_gate's own comment for the
 * exact reproduction. Fixed by pointing it at THIS same file too. Two
 * review rounds of this fix-pack each claimed "one parser now" before
 * that was actually true (MAJOR-C, round 2, caught the FIRST such claim
 * as unverified/false; issue #72, filed after a REBASE onto a separate
 * fix for issue #70 made the second one measurably false in exactly the
 * way it warned about) — it is true as of issue #72's own fix: this
 * driver's two bash-level callers both go through it, and neither runs a
 * second, independently-drifting reimplementation of "what does this WXR
 * item's own post_type say" any more.
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
 *   BLOCKER-2 (fails FALSE): a single item's own <wp:post_id> and
 *   <wp:post_type> sharing ONE physical line (demonstrated live via this
 *   fix-pack's own test fixture) made the awk's four rules all match
 *   against `$0` (the whole line) and `gsub` it — every rule fired against
 *   both tags on that line, producing a garbled half-XML "id"/"type" pair
 *   instead of the real values. Whether wp-cli's REAL exporter routinely
 *   produces this specific layout is NOT independently verified here
 *   (review, MAJOR-C — an earlier draft of this comment claimed it does,
 *   "frequently", including two DIFFERENT items sharing one line, neither
 *   half checked against a real `wp export`); the fix does not depend on
 *   that claim being true, only on the shape being POSSIBLE for a
 *   line-oriented scanner to mishandle, which it demonstrably is.
 *
 * XMLReader (lib/php/wxr-content-functions.php) parses actual document
 * STRUCTURE — an <item>'s own direct children, resolved by namespace URI,
 * regardless of line layout or of what unrelated CDATA elsewhere in the
 * document happens to contain — so neither shape above is reachable here
 * by construction, not by a sharper regex. See that file's own header for
 * the streaming/memory and entity-safety properties this inherits for
 * free.
 *
 * A REAL, CONFIRMED gap this inherited parser still has (issue #70, found
 * while building this fix-pack's own test fixtures, NOT fixed in this
 * file or by this PR): _sitegraft_stream_wxr_reader's XMLReader::next() +
 * outer while(true){read();...} loop silently drops the SECOND of two
 * sibling <item> elements when there is NO intervening whitespace/text
 * node between them (`</item><item>` with literally nothing between —
 * real `wp export` output is always pretty-printed with a newline there,
 * so this has no practical effect against a genuine wp-cli export, but it
 * IS reachable via any other WXR producer, or a hand-edited/minified
 * file). Concretely: graft_verify_import_completeness would silently pass
 * a run where the SECOND of two such adjacent items was genuinely skipped
 * by wordpress-importer — the exact failure mode this whole fix-pack
 * exists to catch, reopened by the parser this fix-pack switched to. A
 * fix for #70 is expected to land on `main` separately; this file's own
 * tests include the case that will go green once it does, and stay red
 * (by design, not by mistake) until then.
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
 * Exits 1, with a message on STDERR, the moment ANY listed file is
 * unreadable OR fails to parse at all (sitegraft_stream_wxr_items_from_file
 * returning false — an empty/missing/malformed file, or one whose
 * <wp:wxr_version> isn't "1.2"; see that function's own header for the
 * full list) — never a silently-empty result standing in for "this file
 * could not be trusted". This is what closes BLOCKER-1's third
 * manifestation at the caller's level: a WXR file present but genuinely
 * unparseable used to read as "zero items found, nothing to check, pass"
 * one layer up; this driver now makes that a hard, loud failure instead
 * (graft_verify_import_completeness AND graft_integrity_gate, both
 * lib/graft.sh, each map this driver's single "1" into their own
 * distinct return-code contract — see each function's own header for
 * why a missing/unparseable file is NOT treated the same as their own
 * other failure modes there). NOT a guarantee of "nothing at
 * all on stdout" on that exit, though (review, MINOR-D — an earlier
 * draft of this comment claimed exactly that): given MULTIPLE files on
 * argv, a failure on the SECOND or later file leaves whatever NDJSON the
 * FIRST file(s) already streamed sitting on stdout, since each file is
 * fully processed and emitted before the next one is even opened. Harmless
 * to both of this driver's production callers, neither of which reads
 * stdout at all unless the exit code was 0 (checked first in both) — but
 * a future caller treating a nonzero exit as "stdout is guaranteed empty"
 * would be wrong.
 *
 * Also exits 1, per file, when the count of <item> ELEMENTS this run
 * structurally encountered does not equal the count of well-formed items
 * actually emitted (issue #73 — a real gate-bypass, measured against a
 * real DDEV harness run, not a theoretical hardening). Reproduced: a WXR
 * with one genuine, well-formed `<item>` (post_type "page") AND one
 * malformed `<item>` carrying ONLY `<wp:post_type>injected_evil_type</
 * wp:post_type>` (no wp:post_id at all — the exact shape a hand-crafted
 * attack, or simple corruption, would produce) made this driver emit
 * `{"post_id":101,"post_type":"page"}` and exit 0 — the forbidden type
 * was silently absent from the output rather than reported as a leak,
 * and graft_integrity_gate (lib/graft.sh), reading this driver's list as
 * "every post_type in the file", accepted a WXR it exists specifically to
 * reject. wxr-content-functions.php's own `_sitegraft_wxr_item_from_node`
 * skipping a malformed item is the right call for what it does (parsing
 * for content-remap/completeness purposes, where an item with no post_id
 * genuinely cannot be correlated to anything) — but "I never saw a
 * forbidden type" and "there is no forbidden type" are NOT the same
 * claim, and a SECURITY gate must never conflate them. Both this driver's
 * callers get this defense for free, uniformly, from this one file — see
 * lib/php/wxr-content-functions.php's own docblock for `$items_seen`,
 * the by-reference counter this comparison is built on, incremented in
 * the SAME branch that decides "this is an <item>", not by a second,
 * independently-drifting traversal that could in principle disagree with
 * the first.
 *
 * This driver's own fail-closed behavior is necessary but not sufficient
 * on its own (review — a second, independent finding, same underlying
 * root cause: trusting a subprocess's raw output without validating it):
 * both bash callers now ALSO validate that $ndjson is genuine, complete
 * NDJSON before consuming it (`jq -s -c '.'`, same pattern lib/verify.sh's
 * own _verify_wxr_items_remapped already used for the identical php-
 * driver-output-trust problem) and invoke `php` with `-d
 * display_errors=stderr`, since the orchestrator's own php.ini —
 * something this codebase does not control — can write a warning/notice/
 * deprecation straight to stdout ahead of this driver's real NDJSON by
 * default, and this driver's own exit code alone cannot detect THAT
 * (php itself still exits 0; the corruption happens one layer up, in the
 * bash variable capturing this process's stdout). See graft_integrity_
 * gate's and graft_verify_import_completeness's own comments (lib/
 * graft.sh) for the measured mechanism and the exact validation used.
 */

require_once __DIR__ . '/wxr-content-functions.php';

function wxr_item_ids_cli_fail( $message ) {
	fwrite( STDERR, "wxr-item-ids-cli: {$message}\n" );
	exit( 1 );
}

if ( $argc < 2 ) {
	wxr_item_ids_cli_fail( 'usage: php wxr-item-ids-cli.php <wxr-file> [<wxr-file> ...]' );
}

for ( $i = 1; $i < $argc; $i++ ) {
	$file = $argv[ $i ];
	if ( ! is_readable( $file ) ) {
		wxr_item_ids_cli_fail( "WXR file not found or unreadable: {$file}" );
	}
	// $items_emitted counted separately per file, alongside $items_seen
	// (populated by reference below) -- issue #73/harness blocker: a
	// mismatch means at least one <item> in THIS file was seen by the
	// reader but dropped as not well-formed (missing wp:post_id or
	// wp:post_type -- see wxr-content-functions.php's own
	// _sitegraft_wxr_item_from_node). See this file's own header for why
	// that is a security-relevant condition this driver refuses to pass
	// through silently, for EITHER of its callers.
	$items_emitted = 0;
	$emit_item = function ( $item ) use ( &$items_emitted ) {
		$items_emitted++;
		echo json_encode(
			array(
				'post_id'   => $item['post_id'],
				'post_type' => $item['post_type'],
			)
		) . "\n";
	};
	$items_seen = 0;
	$ok = sitegraft_stream_wxr_items_from_file( $file, $emit_item, $items_seen );
	if ( ! $ok ) {
		wxr_item_ids_cli_fail( "WXR file did not parse as valid XML, or is empty: {$file}" );
	}
	if ( $items_seen !== $items_emitted ) {
		wxr_item_ids_cli_fail( "{$file} has {$items_seen} <item> element(s) but only {$items_emitted} could be parsed as well-formed (each needs BOTH wp:post_id and wp:post_type) -- refusing to silently drop a structurally-present <item> from a security-relevant check; a caller relying on this driver's output to enforce or verify post_type(s) must never trust it when some items were dropped without explanation" );
	}
}
