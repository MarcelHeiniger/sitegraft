<?php
/**
 * lib/php/content-remap-functions.php — the actual content-rewriting logic
 * behind `sitegraft graft`'s two remap steps (design doc §9.1/§9.4).
 *
 * Extracted into its own plain-PHP file (review, Viktor, NIT-1) specifically
 * so it can be unit-tested in real isolation via `php` directly, with zero
 * WordPress bootstrap — no DDEV, no wp-cli. Before this fix, the exact same
 * logic lived inline inside a bash single-quoted string passed to
 * `wp_remote b eval '...'` in lib/graft.sh: syntactically impossible to unit
 * test on its own, so the two bash helper functions that USED to build this
 * (graft_build_sentinel_commands, graft_content_tables_csv) kept their green
 * unit tests years after phase_graft stopped calling either of them — a
 * false coverage signal on exactly the logic (the remap that must never
 * contaminate protected data) where a coverage gap matters most.
 *
 * At runtime, this file is pushed onto B (graft_push_remap_payload's sibling
 * transfer, see lib/graft.sh's graft_push_remap_lib) and `require_once`'d by
 * the `wp eval` snippets in graft_remap_attachment_ids/graft_search_replace_domain
 * — production and the unit tests below run the exact same file, not a
 * hand-kept-in-sync copy.
 *
 * Both functions are pure string transforms: no WordPress function calls, no
 * database access, no side effects. That purity is what makes them directly
 * testable with a bare `php` CLI invocation.
 */

/**
 * sitegraft_remap_attachment_refs( array $attachments, string $content ): string
 *
 * Two-pass sentinel technique (design doc §9.1): rewrites every Etch-style
 * `"id":<old>` JSON block attribute and `wp-image-<old>` CSS class reference
 * to an attachment's NEW id, for every {old, new} pair in $attachments.
 *
 * Pass 1 (ALL attachments) converts every old-id reference to a unique
 * sentinel token BEFORE pass 2 (ALL attachments) resolves any sentinel to
 * its real new id. This ordering is not cosmetic: it is what guarantees a
 * pass-2 substitution can never be re-matched by a pass-1 pattern still
 * waiting to run for a DIFFERENT attachment in the same batch (e.g. if
 * attachment 1's new id is 12, and attachment 12 is ALSO being remapped in
 * this same call, naively rewriting "id":1 -> "id":12 immediately would let
 * attachment 12's own pass 1 then wrongly re-match that freshly-written
 * "id":12 as if it were an original reference to old attachment 12).
 *
 * `(?!\d)` (negative lookahead) on both patterns is equally load-bearing on
 * its own: without it, "id":1 would match the leading digits of "id":12,
 * corrupting a reference to a COMPLETELY DIFFERENT attachment. This is
 * exactly why this logic needs PHP's own preg_replace (full PCRE) and can
 * never be done with sed/grep -E, neither of which implement lookahead —
 * and why a plain string replace (str_replace / bash's ${var//search/replace})
 * is unsafe here too (no digit-boundary awareness at all).
 *
 * `(int)` on $row['old'] (review, Viktor, NIT-2): id-map.tsv's own values
 * are always WordPress-internal integer post IDs, produced entirely by this
 * tool's own mu-plugin/graft_import_attachments — not attacker-controlled
 * input, so this was never an exploitable gap. Cast anyway, so the string
 * interpolated straight into a PCRE pattern is a plain integer by
 * construction, not merely by the happenstance of what id-map.tsv currently
 * contains — the same discipline already applied to $post_id in both
 * callers of this file.
 */
function sitegraft_remap_attachment_refs( array $attachments, $content ) {
	// Pass 1 fully before pass 2 — see this function's own docblock for why.
	foreach ( $attachments as $row ) {
		$old_id   = (int) $row['old'];
		$sentinel = '__SITEGRAFT_' . $old_id . '__';
		$content  = preg_replace( '/"id":' . $old_id . '(?!\d)/', '"id":' . $sentinel, $content );
		$content  = preg_replace( '/wp-image-' . $old_id . '(?!\d)/', 'wp-image-' . $sentinel, $content );
	}
	foreach ( $attachments as $row ) {
		$old_id   = (int) $row['old'];
		$sentinel = '__SITEGRAFT_' . $old_id . '__';
		$content  = str_replace( $sentinel, $row['new'], $content );
	}
	return $content;
}

/**
 * sitegraft_remap_domain( string $content, string $from, string $to ): string
 *
 * design doc §9.4: two passes (the plain domain string, and its
 * JSON-escaped form — Etch stores some data as JSON blobs inside
 * post_content, and PHP's own json_encode escapes "/" to "\/" by default).
 * A plain str_replace (not regex) on purpose: unlike the ID sentinel
 * technique above, there is no digit-boundary ambiguity to guard against
 * here — a literal domain string is either present or it isn't.
 */
function sitegraft_remap_domain( $content, $from, $to ) {
	if ( $from === '' ) {
		return $content;
	}
	$from_escaped = str_replace( '/', '\\/', $from );
	$to_escaped   = str_replace( '/', '\\/', $to );
	return str_replace( array( $from, $from_escaped ), array( $to, $to_escaped ), $content );
}

/**
 * sitegraft_domain_present( string $haystack, string $domain, string $escaped ): bool
 *
 * design doc §6.5/§9.4, verify's domain-absence check (lib/verify.sh,
 * verify_domain_absent): true if either the plain domain string or its
 * JSON-escaped form (`https:\/\/...`, produced the same way
 * sitegraft_remap_domain above computes it) appears anywhere in $haystack.
 *
 * Shared by BOTH surfaces verify_domain_absent scans — a migrated post's
 * post_content/post_excerpt (plain TEXT, may embed literal JSON-escaped
 * bytes the way Etch's own blocks do) and a migrated option's live value
 * (run through maybe_serialize() by the caller before reaching here, so a
 * plain-string option value that itself holds literal JSON text carries the
 * exact same escaped-byte-sequence possibility a post's content does).
 * Review fix-pack (Viktor, MINOR): the options side originally checked only
 * the plain form, asymmetric with the post-content side's own two-form
 * check — extracting ONE shared function is what makes it structurally
 * impossible for the two call sites to drift apart on this again.
 */
function sitegraft_domain_present( $haystack, $domain, $escaped ) {
	return strpos( $haystack, $domain ) !== false || strpos( $haystack, $escaped ) !== false;
}
