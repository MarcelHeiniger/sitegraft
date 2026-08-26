<?php
/**
 * Plugin Name: sitegraft ID Mapper (temporary)
 * Description: Logs old->new post ID pairs during a sitegraft WXR import.
 * Installed and removed automatically by `sitegraft graft` — do not install by hand.
 */

add_action( 'wp_import_insert_post', function ( $post_id, $original_post_id, $postdata, $post ) {
    $log = WP_CONTENT_DIR . '/sitegraft-id-map.log';
    $post_type = isset( $postdata['post_type'] ) ? $postdata['post_type'] : 'unknown';
    file_put_contents( $log, "{$original_post_id}\t{$post_id}\t{$post_type}\n", FILE_APPEND | LOCK_EX );
    update_post_meta( $post_id, '_sitegraft_source_id', $original_post_id ); // for idempotence, see design doc §11
}, 10, 4 );

// No wp_import_insert_term handler here, deliberately -- do not re-add one.
//
// This hook fires only from process_post_term() (class-wp-import.php:
// 1166-1186), and only inside the `if ( ! $term_id )` branch -- i.e. only
// for a term that did NOT already exist on B; an existing term fires
// nothing here. $t (its first argument) is wp_insert_term()'s real return
// value, `[ 'term_id' => int, 'term_taxonomy_id' => int ]`
// (wp-includes/taxonomy.php) -- not, as an earlier version of this
// comment said, "an array of term_taxonomy_ids". $term (its second
// argument) comes from the WXR parser's inline <item><category> handling
// (class-wxr-parser-simplexml.php:183-187): name/slug/domain only, no
// original term_id anywhere in it. So even limited to newly-created
// terms, this hook has a real NEW id ($t['term_id'], read one line above
// the do_action at class-wp-import.php:1185) but no OLD one to pair it
// with -- there is no old->new term map to build from this hook,
// structurally, no matter how it's written.
//
// SECOND REVIEW ROUND (Viktor + Kimi, independent): a route that DOES
// carry a real old->new pair exists, and is still not used. The
// `wp_import_term_meta` filter (process_termmeta(), class-wp-import.php
// ~696-714) is NOT gated on termmeta being present -- an earlier version
// of this comment implied that; wrong. It normalizes a missing termmeta
// to `array()` and applies the filter regardless, only returning early on
// an empty result afterward. The real gate, checked at each of
// process_categories()/process_tags()/process_terms() (~490/~562/~635),
// is `created === true` -- process_termmeta() only ever runs for a term
// actually CREATED by this import. Fired from the standalone
// <wp:category>/<wp:tag>/<wp:term> path (not the inline path above),
// $term there DOES carry the original term_id, so this filter's
// ($term_id = new, $term['term_id'] = old) pair is real. But a map built
// from it would silently OMIT every term that already existed on B --
// indistinguishable from "never migrated" -- and a partial map that looks
// authoritative is worse than no map at all. (The one truly COMPLETE map,
// $this->processed_terms, class-wp-import.php:34, is populated
// unconditionally, including for pre-existing terms -- but unreachable
// from any hook: WP-CLI instantiates its own importer into a LOCAL
// variable, wp-cli/import-command's Import_Command.php:248, never into
// the $GLOBALS['wp_import'] that wordpress_importer_init() would
// otherwise populate on 'admin_init' -- a hook this command's bootstrap
// never fires.)
//
// The handler that used to sit here bound
// `function ( $term_id, $term, $original_id )` (3 params) to the real
// 4-arg signature above, so $term_id held $t and $original_id held
// $post_id -- the newly-INSERTED post's id ON B, not any pre-migration id
// at all. Every line it wrote came out as "<post_id>\tArray\tterm:Array"
// (PHP's array-to-string coercion of $t and $term) -- worked out directly
// from the real parameter order, not assumed. Those rows WERE consumed,
// not ignored.
//
// id-map.tsv has many readers spread across lib/ and modules/. Exactly
// ONE of them, modules/core-wp.sh's map_json (in
// _core_wp_remap_nav_page_ids), has ever filtered a `term:`-tagged row
// out explicitly -- see that function's own comment for the history of
// why. Every other reader never filtered by row type for this at all,
// while this handler existed or since. What made a garbage row harmless
// almost everywhere was never filtering: it was two properties of the
// row itself. Column 2 ("Array") is not a digit string, so any reader
// guarded by `$2 ~ /^[0-9]+$/` excluded it outright. And where nothing
// guards the column, `(int) "Array"` is 0, and every PHP-side consumer
// that resolves an id to a post (`get_post( (int) $post_id )`) gets null
// and skips it via `if ( ! $post ) { continue; }`.
//
// This is NOT an exhaustive list -- three separate review rounds each
// found one more reader the previous round's comment had missed (Viktor's
// citations verified line-for-line against origin/main; see PR #61 for
// the full account), which is itself the reason this paragraph states an
// invariant instead of an inventory. Notable examples only:
// lib/graft.sh's unfiltered graft_migrated_post_ids_json and its
// wp_navigation-only-filtered sibling both hit the (int)/get_post() case
// above. So does lib/verify.sh's DOMAIN_SCOPE count (a harmless
// off-by-one) and its page_on_front check (a false HARD FAIL on a
// numeric collision, not a corruption -- a read, never a write).
// modules/etch.sh's component-ref remap is saved by its own
// `$2 ~ /^[0-9]+$/` guard. lib/graft.sh's featured-image remap swallows
// the resulting wp-cli failure via `|| true`, not a cast -- a third
// mechanism, same harmless outcome. The one place this was NOT harmless
// -- modules/core-wp.sh's core_wp_post_import (its own comment, near the
// page_on_front/page_for_posts lookup) -- has neither property: no digit
// guard, and no PHP-side (int) cast, because the write goes straight from
// a bash string to `wp option update`.
