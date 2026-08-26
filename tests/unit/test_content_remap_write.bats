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
#
# $fields is a KEYED array ("post_content"/"post_excerpt"), not two more
# positional strings (fix-pack round two, MAJOR-2 round two, Viktor,
# execution-proven twice): round one of this fix-pack replaced
# $post_id/$orig_content/$orig_excerpt with $post, which removed
# arguments 4/5 of the original five, but left $content/$excerpt as two
# adjacent, interchangeable strings -- and Viktor swapped them at
# graft_remap_attachment_ids' own call site a second time, against that
# exact form, with the full suite (41 tests across four files) staying
# green throughout, because every assertion matched the call's TEXT,
# never its arguments. See sitegraft_write_remapped_post's own docblock
# for the full account of why a keyed array closes this at the one place
# a swap is actually possible (the call site), not merely at this helper.
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
# "post_content" => $fields["post_content"], "post_excerpt" =>
# $fields["post_excerpt"] ) )` instead of $wpdb->update(...). Add, just for
# the experiment, a `wp_update_post()` stub that models the real
# array-vs-object slashing asymmetry (never slashes the array form, always
# unslashes before "writing" — see the production docblock for the exact
# mechanism), then rerun this file: the byte-for-byte assertion in the
# first test below fails, because the written value comes back with its
# "\/" eaten down to "/". Revert afterward — this is confirmation, not a
# permanent test path.
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

    $changed = sitegraft_write_remapped_post( $orig, [ "post_content" => $rewritten_content, "post_excerpt" => "excerpt-unchanged" ] );

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

@test "sitegraft_write_remapped_post writes \$fields[\"post_content\"] to post_content and \$fields[\"post_excerpt\"] to post_excerpt -- correctly mapped, not swapped" {
  # This is a sanity check of the HELPER itself, not the swap-prevention
  # claim (review, Kimi/coordinator: a prior version of this test's name
  # overstated what it covers). The actual swap risk lives at the CALL
  # SITE in lib/graft.sh, where a keyed array literal is what makes a swap
  # self-evidently wrong to read -- guarded by the literal-string
  # assertions in tests/unit/test_graft_remap.bats and
  # test_graft_options.bats, not by anything this helper-level test can
  # see.
  run php_run '
    $post = (object) [ "ID" => 7, "post_content" => "old content", "post_excerpt" => "old excerpt" ];
    $fields = [ "post_content" => "CONTENT-VALUE", "post_excerpt" => "EXCERPT-VALUE" ];
    sitegraft_write_remapped_post( $post, $fields );
    $written = $GLOBALS["wpstub"]["posts_written"][0]["data"];
    if ( $written["post_content"] !== "CONTENT-VALUE" ) { fwrite(STDERR, "post_content got: " . $written["post_content"] . "\n"); exit(1); }
    if ( $written["post_excerpt"] !== "EXCERPT-VALUE" ) { fwrite(STDERR, "post_excerpt got: " . $written["post_excerpt"] . "\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# Fix-pack round three (coordinator, verified by Viktor via a live probe):
# $fields used to be handed to $wpdb->update() AS ITS OWN $data argument,
# unbounded. Viktor's probe called this function with
# ["post_content"=>..., "post_excerpt"=>..., "post_status"=>"draft",
# "post_title"=>"OVERWRITTEN", "post_author"=>999] and every one of those
# five columns reached $wpdb->update() -- silently repealing the exact
# invariant this PR put in CLAUDE.md one commit earlier: "ONLY those two
# plain-TEXT columns, NEVER an arbitrary/serialized value." No live
# exploit today (both call sites' keys are string literals in a
# single-quoted bash string -- nothing from A or the JSON payload can
# become a KEY, only a value) but a silent scope violation regardless.
# Fixed: the function now rebuilds its own $data with exactly the two
# literal keys before ever calling $wpdb->update() -- see
# sitegraft_write_remapped_post's own docblock for why this costs nothing
# against MAJOR-2 (the call site still writes the keyed array; the keys
# stay attached to their values at the one place a swap can happen).
@test "sitegraft_write_remapped_post never writes a column beyond post_content/post_excerpt, even if \$fields carries more (#43 fix-pack round three)" {
  run php_run '
    $post = (object) [ "ID" => 9, "post_content" => "old", "post_excerpt" => "old excerpt" ];
    $fields = [
      "post_content" => "new",
      "post_excerpt" => "new excerpt",
      "post_status"  => "draft",
      "post_title"   => "OVERWRITTEN",
      "post_author"  => 999,
    ];
    sitegraft_write_remapped_post( $post, $fields );
    $written = $GLOBALS["wpstub"]["posts_written"][0]["data"];
    $columns = array_keys( $written );
    sort( $columns );
    if ( $columns !== [ "post_content", "post_excerpt" ] ) {
      fwrite(STDERR, "columns handed to \$wpdb->update(): " . implode( ",", $columns ) . "\n" ); exit(1);
    }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# Fix-pack round three (coordinator, verified by Viktor via a live probe):
# a $fields missing post_content used to (a) emit a PHP "Undefined array
# key" warning into the run's own output, (b) compare `null ===
# $post->post_content`, which is never true, so the unchanged-check never
# short-circuited, and (c) still return true and still call
# $wpdb->update() -- a REAL but wrong write (with post_excerpt present
# alone) or an UPDATE with an empty SET clause (with $fields entirely
# empty) that a real $wpdb would reject as a SQL syntax error, which
# wpstub_wpdb could not model (it always returns int 1 -- a permissive
# divergence exactly of the kind tests/unit/fixtures/wpstub.php's own
# header warns against). The guard runs FIRST, before the unchanged-check,
# so the missing key is caught before anything reads it.
@test "sitegraft_write_remapped_post refuses and warns, without writing, when \$fields is missing post_content (#43 fix-pack round three)" {
  # $post->post_content ("body") really does differ from a $fields with no
  # post_content key -- exactly the scenario that must reach the guard
  # BEFORE the unchanged-check reads the missing key (see this function's
  # own docblock: guard-after-compare still triggers a PHP "Undefined
  # array key" warning on its way to the guard's own message). The
  # "!= *Undefined*" assertion below is what pins the ORDER, not merely
  # the guard's existence -- reordering the two checks reproduces the
  # PHP warning even though the final return value stays correct.
  run php_run '
    $post = (object) [ "ID" => 2, "post_content" => "body", "post_excerpt" => "same" ];
    $changed = sitegraft_write_remapped_post( $post, [ "post_excerpt" => "same" ] );
    if ( $changed ) { fwrite(STDERR, "reported success with post_content missing from \$fields\n"); exit(1); }
    if ( ! empty( $GLOBALS["wpstub"]["posts_written"] ) ) { fwrite(STDERR, "\$wpdb->update was called despite the missing key\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]] || false
  [[ "$output" == *"SKIPPED"* ]] || false
  [[ "$output" == *'no post_content in $fields'* ]] || false
  [[ "$output" != *"Undefined"* ]] || false
  [[ "$output" == *"OK"* ]] || false
}

@test "sitegraft_write_remapped_post refuses and warns, without writing, when \$fields is missing post_excerpt (#43 fix-pack round three)" {
  # The asymmetric half of the same bug: omitting post_excerpt while
  # post_content genuinely changed used to produce NO warning at all,
  # because the old unchanged-check\'s `&&` short-circuited on
  # post_content before the missing post_excerpt key was ever read -- the
  # defect only showed up on SOME inputs, not others. The guard-first order
  # closes that asymmetry: both keys are checked before either is read for
  # comparison.
  run php_run '
    $post = (object) [ "ID" => 3, "post_content" => "old body", "post_excerpt" => "same" ];
    $changed = sitegraft_write_remapped_post( $post, [ "post_content" => "new body" ] );
    if ( $changed ) { fwrite(STDERR, "reported success with post_excerpt missing from \$fields\n"); exit(1); }
    if ( ! empty( $GLOBALS["wpstub"]["posts_written"] ) ) { fwrite(STDERR, "\$wpdb->update was called despite the missing key\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]] || false
  [[ "$output" == *"SKIPPED"* ]] || false
  [[ "$output" == *"post_excerpt"* ]] || false
  [[ "$output" == *"OK"* ]] || false
}

@test "sitegraft_write_remapped_post refuses and warns, without writing, when \$fields is entirely empty (#43 fix-pack round three)" {
  # The worse half of the same bug: an entirely empty \$fields used to
  # still return true and still call \$wpdb->update() with an empty SET
  # clause -- a straight SQL syntax error against a real \$wpdb that
  # wpstub_wpdb\'s permissive always-succeeds update() could not surface.
  run php_run '
    $post = (object) [ "ID" => 4, "post_content" => "body", "post_excerpt" => "excerpt" ];
    $changed = sitegraft_write_remapped_post( $post, [] );
    if ( $changed ) { fwrite(STDERR, "reported success with \$fields entirely empty\n"); exit(1); }
    if ( ! empty( $GLOBALS["wpstub"]["posts_written"] ) ) { fwrite(STDERR, "\$wpdb->update was called despite \$fields being empty\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]] || false
  [[ "$output" == *"SKIPPED"* ]] || false
  [[ "$output" == *"OK"* ]] || false
}

@test "sitegraft_write_remapped_post reports no change and never touches \$wpdb or the cache when content and excerpt are unchanged" {
  run php_run '
    $post = (object) [ "ID" => 1, "post_content" => "same content", "post_excerpt" => "same excerpt" ];
    $changed = sitegraft_write_remapped_post( $post, [ "post_content" => "same content", "post_excerpt" => "same excerpt" ] );
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
  # $output also carries the WARNING line the function now prints on this
  # path (fix-pack round two, below) -- matched as a substring here rather
  # than an exact match so this test stays focused on the return
  # value/cache-clear contract; the warning text itself is pinned by its
  # own dedicated test further down.
  run php_run '
    $GLOBALS["wpstub"]["wpdb_update_fail"] = [105];
    $post = (object) [ "ID" => 105, "post_content" => "old", "post_excerpt" => "" ];
    $changed = sitegraft_write_remapped_post( $post, [ "post_content" => "new", "post_excerpt" => "" ] );
    if ( $changed ) { fwrite(STDERR, "reported success on a failed \$wpdb->update\n"); exit(1); }
    if ( ! empty( $GLOBALS["wpstub"]["cache_cleared"] ) ) { fwrite(STDERR, "clean_post_cache was called despite the write failing\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]] || false
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
    $changed = sitegraft_write_remapped_post( $post, [ "post_content" => "new", "post_excerpt" => "" ] );
    if ( ! $changed ) { fwrite(STDERR, "treated \$wpdb->update() returning 0 as a failure\n"); exit(1); }
    if ( $GLOBALS["wpstub"]["cache_cleared"] !== [42] ) { fwrite(STDERR, "clean_post_cache was not called on a successful (0-rows) write\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# Fix-pack round two (coordinator, verified against Viktor's own finding):
# CLAUDE.md's first rule, "fail closed" -- "a step that could not do its
# job returns non-zero and says why." Round one made the failure
# DETECTABLE (this function returns false), but the only thing either
# caller in lib/graft.sh does with that is skip incrementing its own
# counter: nothing is printed, nothing exits non-zero. Before the fix-pack
# the counter over-reported (a failed write still counted); after round
# one alone, it under-reports SILENTLY (a failed write is dropped with no
# trace at all) -- detecting and then swallowing is the worse half of
# "fail closed", not the whole of it. This pins the one piece actually in
# scope for #43: the warning line itself. Whether `graft` as a whole
# should exit non-zero on this is a separate, pre-existing gap (neither
# `wp eval` snippet propagates its own exit status today) and is out of
# scope here.
@test "sitegraft_write_remapped_post prints a visible warning naming the post and \$wpdb->last_error when the write fails (#43 fix-pack round two)" {
  run php_run '
    $GLOBALS["wpstub"]["wpdb_update_fail"] = [105];
    $post = (object) [ "ID" => 105, "post_content" => "old", "post_excerpt" => "" ];
    sitegraft_write_remapped_post( $post, [ "post_content" => "new", "post_excerpt" => "" ] );
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]] || false
  [[ "$output" == *"105"* ]] || false
  [[ "$output" == *"wpstub: simulated update failure for post 105"* ]] || false
}

@test "sitegraft_write_remapped_post prints nothing on a successful write" {
  run php_run '
    $post = (object) [ "ID" => 1, "post_content" => "old", "post_excerpt" => "" ];
    sitegraft_write_remapped_post( $post, [ "post_content" => "new", "post_excerpt" => "" ] );
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
