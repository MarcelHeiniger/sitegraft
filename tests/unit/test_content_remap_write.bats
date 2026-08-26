# tests/unit/test_content_remap_write.bats — the WordPress-calling half of
# lib/php/content-remap-functions.php: sitegraft_write_remapped_post (issue
# #43), run under tests/unit/fixtures/wpstub.php's stand-ins for
# $wpdb->update()/clean_post_cache() by a bare `php` CLI. No WordPress
# bootstrap, no DDEV, no wp-cli — same convention
# tests/unit/test_media_import_batch.bats already uses for the
# WordPress-calling half of lib/php/media-import-functions.php.
#
# Split out of tests/unit/test_content_remap_functions.bats (review, Kimi,
# NIT), which is reserved for the two PURE remap functions
# (sitegraft_remap_attachment_refs/sitegraft_remap_domain) that need
# nothing but a bare `php` CLI — mixing an ad hoc inline stub into that
# file would have been exactly the kind of undisciplined, unfailable stub
# tests/unit/fixtures/wpstub.php's own header warns against building.
#
# Why sitegraft_write_remapped_post exists at all, and why it writes via
# $wpdb->update() rather than wp_update_post(): see its own docblock in
# lib/php/content-remap-functions.php. The short version: wp_update_post()
# only slashes an OBJECT $postarr, never an array, yet wp_insert_post()
# always unslashes before writing regardless — silently eating every
# backslash in content that (like sitegraft_remap_domain's own
# JSON-escaped `https:\/\/` output) carries one by construction.
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  PHP_LIB="${REPO_ROOT}/lib/php/content-remap-functions.php"
  WP_STUB="${REPO_ROOT}/tests/unit/fixtures/wpstub.php"
  [ -f "$PHP_LIB" ] || skip "lib/php/content-remap-functions.php not found"
  [ -f "$WP_STUB" ] || skip "tests/unit/fixtures/wpstub.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

# php_run <script> — runs <script> with the WordPress stub and the real
# production library both already required, in that order. Same
# convention test_media_import_batch.bats uses.
php_run() {
  php -r "require '${WP_STUB}'; require '${PHP_LIB}'; $1"
}

# MUTATION PROOF (do this by hand, not part of the suite): temporarily
# change sitegraft_write_remapped_post's body (lib/php/content-remap-
# functions.php) to call `wp_update_post( array( "ID" => $post->ID,
# "post_content" => $content, "post_excerpt" => $excerpt ) )` instead of
# $wpdb->update(...). Add, just for the experiment, a `wp_update_post()`
# stub that models the real array-vs-object slashing asymmetry (never
# slashes the array form, always unslashes before "writing" — see the
# production docblock for the exact mechanism), then rerun this file: the
# byte-for-byte assertion in the first test below fails, because the
# written value comes back with its "\/" eaten down to "/". Revert
# afterward — this is confirmation, not a permanent test path.
@test "sitegraft_write_remapped_post writes via \$wpdb->update -- content and excerpt keep their backslashes byte-for-byte (#43)" {
  run php_run '
    // Exactly the shape sitegraft_remap_domain produces: the JSON-escaped
    // domain form inside an Etch block'\''s JSON attribute comment.
    $orig = (object) [
      "ID"           => 105,
      "post_content" => "<!-- wp:etch/image {\"src\":\"https:\/\/old.example.com\/x.jpg\"} -->",
      "post_excerpt" => "excerpt-unchanged",
    ];
    $rewritten_content = "<!-- wp:etch/image {\"src\":\"https:\/\/new.example.com\/x.jpg\"} -->";

    $changed = sitegraft_write_remapped_post( $orig, $rewritten_content, "excerpt-unchanged" );

    if ( ! $changed ) { fwrite(STDERR, "reported no change when content differed\n"); exit(1); }
    $written = $GLOBALS["wpstub"]["posts_written"];
    if ( count( $written ) !== 1 ) { fwrite(STDERR, "expected exactly one \$wpdb->update call, got " . count($written) . "\n"); exit(1); }
    if ( $written[0]["table"] !== "wp_posts" ) { fwrite(STDERR, "wrong table: " . $written[0]["table"] . "\n"); exit(1); }
    if ( $written[0]["where"] !== [ "ID" => 105 ] ) { fwrite(STDERR, "wrong WHERE clause\n"); exit(1); }

    $written_content = $written[0]["data"]["post_content"];
    if ( $written_content !== $rewritten_content ) { fwrite(STDERR, "content not written byte-for-byte: got [$written_content] want [$rewritten_content]\n"); exit(1); }
    if ( strpos( $written_content, "https:\/\/new.example.com" ) === false ) { fwrite(STDERR, "backslash was eaten: $written_content\n"); exit(1); }

    if ( $GLOBALS["wpstub"]["cache_cleared"] !== [105] ) { fwrite(STDERR, "clean_post_cache was not called exactly once for post 105\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_write_remapped_post writes \$content to post_content and \$excerpt to post_excerpt -- never swapped (Viktor, MAJOR-2)" {
  # The old 5-positional-argument form ($post_id, $content, $excerpt,
  # $orig_content, $orig_excerpt) let a caller swap arguments 2/3 (or 4/5)
  # without any test noticing, because every assertion checking the
  # generated PHP text matches the CALL SITE STRING, never its arguments.
  # Reading $post->post_content/post_excerpt internally, and taking $post
  # itself rather than four separate strings, is what closes that off.
  # Distinguishable content/excerpt values here are the point: a swap
  # would put "EXCERPT-VALUE" where "CONTENT-VALUE" belongs and vice versa.
  run php_run '
    $post = (object) [ "ID" => 7, "post_content" => "old content", "post_excerpt" => "old excerpt" ];
    sitegraft_write_remapped_post( $post, "CONTENT-VALUE", "EXCERPT-VALUE" );
    $written = $GLOBALS["wpstub"]["posts_written"][0]["data"];
    if ( $written["post_content"] !== "CONTENT-VALUE" ) { fwrite(STDERR, "post_content got: " . $written["post_content"] . "\n"); exit(1); }
    if ( $written["post_excerpt"] !== "EXCERPT-VALUE" ) { fwrite(STDERR, "post_excerpt got: " . $written["post_excerpt"] . "\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_write_remapped_post reports no change and never touches \$wpdb or the cache when content and excerpt are unchanged" {
  run php_run '
    $post = (object) [ "ID" => 1, "post_content" => "same content", "post_excerpt" => "same excerpt" ];
    $changed = sitegraft_write_remapped_post( $post, "same content", "same excerpt" );
    if ( $changed ) { fwrite(STDERR, "reported a change when nothing differed\n"); exit(1); }
    if ( ! empty( $GLOBALS["wpstub"]["posts_written"] ) ) { fwrite(STDERR, "\$wpdb->update was called despite no change\n"); exit(1); }
    if ( ! empty( $GLOBALS["wpstub"]["cache_cleared"] ) ) { fwrite(STDERR, "clean_post_cache was called despite no change\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# MAJOR-1 (review, Viktor and Kimi, independently): $wpdb->update()'s
# return value used to be discarded entirely. wp_insert_post() itself
# (wp-includes/post.php:5003, in the write-path this function replaces)
# treats `false === $wpdb->update(...)` as a real failure
# (WP_Error('db_update_error')) -- a full disk, or
# strip_invalid_text_for_column() rejecting a byte sequence in $content.
# Discarding it meant a post that was NEVER actually written still got
# counted into "rewrote N post(s)" and had its cache cleared as if the
# write had succeeded.
@test "sitegraft_write_remapped_post does not report success or clear the cache when \$wpdb->update fails (#43 fix-pack, MAJOR-1)" {
  run php_run '
    $GLOBALS["wpstub"]["wpdb_update_fail"] = [105];
    $post = (object) [ "ID" => 105, "post_content" => "old", "post_excerpt" => "" ];
    $changed = sitegraft_write_remapped_post( $post, "new", "" );
    if ( $changed ) { fwrite(STDERR, "reported success on a failed \$wpdb->update\n"); exit(1); }
    if ( ! empty( $GLOBALS["wpstub"]["cache_cleared"] ) ) { fwrite(STDERR, "clean_post_cache was called despite the write failing\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_write_remapped_post treats \$wpdb->update() returning int 0 (matched, nothing changed) as SUCCESS, not failure (strict false, not falsy 0)" {
  # Real $wpdb->update() returns int 0, never false, when the WHERE clause
  # matched but the values were already identical -- NOT an error. A loose
  # `! $result` check would wrongly treat this the same as a genuine DB
  # failure: never call clean_post_cache(), and never count the post as
  # rewritten, on a write that actually succeeded. wpstub_wpdb::update()
  # returns exactly this int 0 for an id steered via
  # $GLOBALS["wpstub"]["wpdb_update_zero"] (tests/unit/fixtures/wpstub.php),
  # separately from the real-failure steering (wpdb_update_fail) the
  # previous test uses -- so this test fails if production is ever loosened
  # from `false === $wpdb->update(...)` to a truthiness check.
  run php_run '
    $GLOBALS["wpstub"]["wpdb_update_zero"] = [42];
    $post = (object) [ "ID" => 42, "post_content" => "old", "post_excerpt" => "" ];
    $changed = sitegraft_write_remapped_post( $post, "new", "" );
    if ( ! $changed ) { fwrite(STDERR, "treated \$wpdb->update() returning 0 as a failure\n"); exit(1); }
    if ( $GLOBALS["wpstub"]["cache_cleared"] !== [42] ) { fwrite(STDERR, "clean_post_cache was not called on a successful (0-rows) write\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}
