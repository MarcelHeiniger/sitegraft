<?php
/**
 * lib/php/content-remap-functions.php — the actual content-rewriting logic
 * behind `sitegraft graft`'s two remap steps (design doc §9.1/§9.4), plus
 * (issue #43) the write-back that saves what they produce.
 *
 * Extracted into its own plain-PHP file (review, Viktor, NIT-1) specifically
 * so it can be unit-tested in real isolation via `php` directly. Before this
 * fix, the exact same logic lived inline inside a bash single-quoted string
 * passed to `wp_remote b eval '...'` in lib/graft.sh: syntactically
 * impossible to unit test on its own, so the two bash helper functions that
 * USED to build this (graft_build_sentinel_commands, graft_content_tables_csv)
 * kept their green unit tests years after phase_graft stopped calling either
 * of them — a false coverage signal on exactly the logic (the remap that
 * must never contaminate protected data) where a coverage gap matters most.
 *
 * At runtime, this file is pushed onto B (graft_push_remap_payload's sibling
 * transfer, see lib/graft.sh's graft_push_remap_lib) and `require_once`'d by
 * the `wp eval` snippets in graft_remap_attachment_ids/graft_search_replace_domain
 * — production and the unit tests below run the exact same file, not a
 * hand-kept-in-sync copy.
 *
 * NOT every function below is WordPress-free (review, Kimi, NIT — this
 * header used to claim "zero WordPress bootstrap" for the whole file, which
 * stopped being true the moment sitegraft_write_remapped_post was added).
 * sitegraft_remap_attachment_refs and sitegraft_remap_domain ARE pure
 * string transforms — no WordPress function calls, no database access, no
 * side effects — and that purity is what makes THEM directly testable with
 * a bare `php` CLI invocation with nothing else required; their tests live
 * in tests/unit/test_content_remap_functions.bats. sitegraft_write_remapped_post
 * calls $wpdb->update() and clean_post_cache() and is tested the same way
 * lib/php/media-import-functions.php's own WordPress-calling functions
 * are: under tests/unit/fixtures/wpstub.php's in-memory stand-in for those
 * calls, still via a bare `php` CLI and still with no real WordPress
 * bootstrap — see tests/unit/test_content_remap_write.bats.
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
 * `\s*` around the colon in the `"id":` pattern (issue #88): the ORIGINAL
 * version of this pattern matched only the exact compact byte sequence
 * `"id":7`, never `"id": 7` or `"id" : 7`. Never observed from WordPress's
 * own json_encode() (which emits no whitespace by default) or from Etch's
 * own stored block JSON — but a hand-edited or differently-serialized call
 * site is not ruled out, and the cost of tolerating it is one `\s*` on
 * each side of the colon. `wp-image-<old_id>` (the CSS class form, no
 * colon involved) is not a JSON key/value pair at all, so it has no
 * whitespace-variant to tolerate and is unchanged.
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
		$content  = preg_replace( '/"id"\s*:\s*' . $old_id . '(?!\d)/', '"id":' . $sentinel, $content );
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

/**
 * sitegraft_write_remapped_post( object $post, array $fields ): bool
 *
 * The write-back step shared by graft_remap_attachment_ids and
 * graft_search_replace_domain (lib/graft.sh): both call one of the two
 * pure remap functions above, then need to save the result and invalidate
 * the object cache. Extracted here (issue #43) for the same reason the
 * remap functions themselves were extracted — the previous inline form
 * could only be exercised end-to-end via the DDEV harness, so a regression
 * in the WRITE (as opposed to the rewrite) went uncovered by any unit test.
 *
 * $post is the SAME get_post() object both callers already fetched to
 * build $fields in the first place. $fields is a KEYED array —
 * `array( "post_content" => $content, "post_excerpt" => $excerpt )` at
 * both call sites — matched against a fixed, hard-coded list of required
 * keys below and RE-PACKAGED into a fresh array before it ever reaches
 * $wpdb->update(). It is NOT passed through as-is (review, Viktor, third
 * round, execution-proven): an earlier version of this function handed
 * $fields to $wpdb->update() directly and defended that as necessary —
 * "the keys ARE the column names, not merely documentation of intent" —
 * which was a false choice. Viktor's probe called this function with
 * `["post_content"=>..., "post_excerpt"=>..., "post_status"=>"draft",
 * "post_title"=>"OVERWRITTEN", "post_author"=>999]` and every one of
 * those five columns reached $wpdb->update(). No live vulnerability today
 * — the two call sites' array keys are string literals inside a
 * single-quoted bash string, and nothing from A's content or the JSON
 * payload can become a KEY, only a value — but it silently repealed the
 * exact invariant this PR itself put in CLAUDE.md one commit earlier:
 * "ONLY those two plain-TEXT columns, NEVER an arbitrary/serialized
 * value." The "never serialized" half is load-bearing, not decorative:
 * lib/graft.sh's own scope comment (graft_remap_attachment_ids' header)
 * argues a direct fetch/modify/write-back is safe specifically BECAUSE
 * post_content/post_excerpt are plain TEXT and never PHP-serialized —
 * an argument that stops holding the moment this function can be handed
 * an arbitrary column set. Re-packaging with the same two literal keys
 * costs nothing against MAJOR-2: the call site still writes
 * `array( "post_content" => $content, "post_excerpt" => $excerpt )`, so
 * the keys stay attached to their values at the one place a swap can
 * happen — this function bounding what it accepts is an orthogonal
 * property, not a trade-off against that one.
 *
 * A caller missing either required key gets a visible, immediate refusal
 * (review, Viktor, third round, execution-proven) rather than silent
 * corruption: `$fields['post_content']` on a $fields missing that key
 * used to (a) emit a PHP "Undefined array key" warning into the run's own
 * output, (b) compare `null === $post->post_content`, which is never
 * true, so the "nothing changed" short-circuit never fired, and (c) still
 * report `true` and still call $wpdb->update() — with post_excerpt alone,
 * a REAL but pointless UPDATE; with $fields entirely empty, an UPDATE
 * whose SET clause has nothing in it, a straight SQL syntax error against
 * a real $wpdb that the wpstub_wpdb test double could not model (it
 * always returns int 1, a permissive divergence exactly of the kind
 * tests/unit/fixtures/wpstub.php's own header warns against). Worse, the
 * failure mode was ASYMMETRIC: omitting post_excerpt while post_content
 * genuinely changed produced NO warning at all, because the `&&` in the
 * unchanged-check short-circuits before the missing key is ever read — so
 * this only misbehaved on some inputs, not others. The required-key guard
 * below runs FIRST, before the unchanged-check, specifically so a missing
 * key is caught before anything reads it (verified both orders; guard-
 * after-compare still hits the undefined-index warning on its way to the
 * guard).
 *
 * This is the third round of MAJOR-2 (review, Viktor, execution-proven
 * three times now). Round one replaced $post_id/$orig_content/
 * $orig_excerpt with $post, which really did remove arguments 4/5 of the
 * original five — but the danger was never in 4/5. It was in 2/3: the
 * resulting `sitegraft_write_remapped_post( $post, $content, $excerpt )`
 * still took two adjacent, interchangeable strings, and this docblock
 * used to claim that reading $post's own fields "closes that off
 * structurally" — a claim the code did not back up. Round two replaced
 * that pair with the keyed `array $fields` at the call site — real
 * progress, mutation-verified (a swap there now fails
 * tests/unit/test_graft_remap.bats and test_graft_options.bats) — but
 * round two ALSO handed $fields to $wpdb->update() unbounded, opening the
 * two defects this round closes.
 *
 * On defense priority: the keyed array at the call site is a READABILITY
 * defense, not an enforced one — nothing stops a future edit from writing
 * `array( "post_content" => $excerpt, "post_excerpt" => $content )`, it
 * just makes that edit look wrong to a human reading it. The literal-
 * string assertions in tests/unit/test_graft_remap.bats and
 * test_graft_options.bats are the only EXECUTABLE defense against that —
 * they are what actually failed, twice, when Viktor replayed the swap
 * against rounds one and two — and they remain the primary defense for
 * that specific failure mode. (An earlier version of this docblock had
 * this backwards, calling the assertions "belt-and-suspenders... not the
 * primary defense" — the opposite of what the mutation record shows.)
 * The keyed array's real, separate value is upstream of that: it is what
 * makes the swap visible to a reviewer in the first place, at any call
 * site, present or future, not just the two the current text assertions
 * happen to cover.
 *
 * Writes via $wpdb->update(), never wp_update_post() — the actual bug
 * behind issue #43. wp_update_post() only calls wp_slash() on its
 * $postarr when $postarr is an OBJECT (wp-includes/post.php's
 * `is_object( $postarr )` branch); called with a plain array, as both
 * call sites here used to, $postarr is never slashed, yet
 * wp_insert_post() — which wp_update_post() delegates to for an existing
 * ID — unconditionally runs `$data = wp_unslash( $data )` immediately
 * before the actual write. One unslash pass with no matching slash pass
 * silently eats every literal backslash in $fields' values.
 *
 * That is not a corner case for what these two callers rewrite:
 * sitegraft_remap_domain (above) explicitly matches and rewrites the
 * JSON-escaped `https:\/\/` form, which is exactly how a domain shows up
 * inside an Etch block's JSON attribute comment. Losing that escaping
 * breaks parse_blocks()'s JSON decode SILENTLY — no error, no crash, a
 * block that renders without its attributes.
 *
 * $wpdb->update() performs no slash/unslash pass at all — the raw bytes
 * given are the raw bytes written — the same choice, for the same reason,
 * modules/etch.sh's own Etch-component-reference remap already makes.
 * clean_post_cache() replaces the object-cache invalidation
 * wp_update_post() would otherwise have done as a side effect — but only
 * on an actual, successful write; see the failure handling below.
 *
 * Skipping wp_update_post() also means skipping everything else it would
 * have done, on purpose, in every case below except the last:
 *
 *   - post_modified/post_modified_gmt are NOT bumped (wp-includes/
 *     post.php:4043-4045 sets these before the save in the code path this
 *     replaces). Desired for a migration tool: it preserves each post's
 *     timestamp as it existed on A rather than stamping it with the
 *     moment `graft` happened to run.
 *   - save_post, post_updated, edit_post and wp_after_insert_post do NOT
 *     fire. Desired — but not free: a plugin hooked on save_post to
 *     maintain a search index (Relevanssi, ElasticPress) will NOT
 *     reindex a post this function rewrites. If B runs one of those, its
 *     index needs a manual rebuild after `graft`.
 *   - No revision is created (wp_save_post_revision never runs). Desired:
 *     a remap is not an edit an operator needs a revision history entry
 *     for.
 *   - content_save_pre and the kses filters do NOT run on $content before
 *     the write. Desired, and the strongest argument for skipping them
 *     specifically for Etch's own block JSON: `wp eval` runs with no
 *     current user set, so `current_user_can( 'unfiltered_html' )` is
 *     false, and kses's default filters WOULD have been active on the
 *     code path this replaces — a real risk of mangling a block's raw
 *     JSON attributes, on every post this function ever touched, not a
 *     newly introduced one.
 *   - wp_transition_post_status does NOT fire — but this is not something
 *     being traded away: this function never changes post_status, so no
 *     transition would have fired under the old wp_update_post() code
 *     either. Named here only so a reader doesn't have to wonder.
 *
 * Returns true iff a write actually happened: content or excerpt differed
 * from $post's own AND $wpdb->update() reported success. A no-op (nothing
 * differed) and a FAILED write both return false, and a failed write does
 * NOT call clean_post_cache() — there is nothing to invalidate for a row
 * that was never actually changed. Callers use this return value to keep
 * their own "rewrote N post(s)" count accurate, and a post $wpdb->update()
 * failed on was never actually rewritten, so it must not be counted
 * (review, Viktor and Kimi independently, MAJOR-1).
 *
 * $wpdb->update()'s return value is NOT merely a formality to check:
 * real WordPress core relies on it being meaningful. wp_insert_post()
 * itself (wp-includes/post.php:5003, in the exact write-path this
 * function replaces) does `false === $wpdb->update( ... )` and raises a
 * WP_Error( 'db_update_error' ) on it — the identical failure this
 * function now also checks for, explicitly rather than by delegation.
 * $wpdb->update() returns false on a real DB error (a full disk, a
 * charset/`strip_invalid_text_for_column()` rejection of some byte
 * sequence in $fields) — never merely on "zero rows matched", which
 * returns int 0, not false; the `false === ` comparison below is strict
 * for exactly that reason, matching wp_insert_post()'s own check byte for
 * byte.
 *
 * A failed write is no longer silent (fix-pack round two — CLAUDE.md's
 * "fail closed" rule: "a step that could not do its job returns non-zero
 * and says why"): round one detected the failure and returned false, but
 * the caller's only reaction is to skip incrementing its own counter —
 * nothing is printed, nothing exits non-zero. `graft` would report
 * "rewrote 3 post(s)" out of 5 in scope with no indication 2 were
 * REJECTED rather than simply unchanged. This function now echoes one
 * line naming the post and $wpdb->last_error on a failed write, so that
 * at least shows up in the run's own output. Whether `graft` as a whole
 * should exit non-zero when this happens is a separate, larger question
 * — these two `wp eval` snippets don't propagate their own exit status
 * today, a pre-existing gap and out of scope for issue #43.
 */
function sitegraft_write_remapped_post( $post, array $fields ) {
	foreach ( array( 'post_content', 'post_excerpt' ) as $required ) {
		if ( ! array_key_exists( $required, $fields ) ) {
			echo "sitegraft: WARNING post {$post->ID} write SKIPPED: no {$required} in \$fields\n";
			return false;
		}
	}
	if ( $fields['post_content'] === $post->post_content && $fields['post_excerpt'] === $post->post_excerpt ) {
		return false;
	}
	$data = array(
		'post_content' => $fields['post_content'],
		'post_excerpt' => $fields['post_excerpt'],
	);
	global $wpdb;
	$result = $wpdb->update( $wpdb->posts, $data, array( 'ID' => (int) $post->ID ) );
	if ( false === $result ) {
		echo "sitegraft: WARNING post {$post->ID} write FAILED: {$wpdb->last_error}\n";
		return false;
	}
	clean_post_cache( (int) $post->ID );
	return true;
}
