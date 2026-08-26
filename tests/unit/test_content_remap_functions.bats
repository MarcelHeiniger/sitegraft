# tests/unit/test_content_remap_functions.bats — the ACTUAL remap logic
# behind `sitegraft graft`'s two remap steps (design doc §9.1/§9.4), tested
# in real isolation via a bare `php` CLI invocation. No WordPress bootstrap,
# no DDEV, no wp-cli.
#
# Why this file exists (review, Viktor, NIT-1): after the MAJOR-2 fix-pack
# rebuilt graft_remap_attachment_ids/graft_search_replace_domain to stop
# scanning whole tables, the two-pass sentinel substitution moved from an
# inline bash-single-quoted PHP string (syntactically impossible to unit
# test on its own) into lib/php/content-remap-functions.php — a plain,
# WordPress-independent PHP file `require_once`'d by the real `wp eval`
# calls. Before this file existed, the bash helper functions that USED to
# build the substitution (graft_build_sentinel_commands,
# graft_content_tables_csv) kept their own green unit tests years after
# phase_graft stopped calling either of them — a false coverage signal on
# exactly the logic (a remap that must never contaminate protected data)
# where a coverage gap matters most. Both were removed; this file is where
# the real substitution's real test coverage lives now, running the exact
# same file production requires.
setup() {
  PHP_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/lib/php/content-remap-functions.php"
  [ -f "$PHP_LIB" ] || skip "lib/php/content-remap-functions.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

# php_run <script> — runs <script> (PHP code, no <?php tag) with the library
# already required, on stdin via `php -r` equivalent. Uses a heredoc-fed
# `php` invocation so the test script can freely use quotes without bash
# escaping headaches.
php_run() {
  php -r "require '${PHP_LIB}'; $1"
}

@test "sitegraft_remap_attachment_refs rewrites both the \"id\":X JSON attribute and the wp-image-X CSS class for a single attachment" {
  run php_run '
    $out = sitegraft_remap_attachment_refs(
      [["old" => "7", "new" => "42"]],
      "<!-- wp:etch/image {\"id\":7} --><img class=\"wp-image-7\" /><!-- /wp:etch/image -->"
    );
    if (strpos($out, "\"id\":42") === false) { fwrite(STDERR, "id attribute not remapped: $out\n"); exit(1); }
    if (strpos($out, "wp-image-42") === false) { fwrite(STDERR, "css class not remapped: $out\n"); exit(1); }
    if (strpos($out, "\"id\":7") !== false || strpos($out, "wp-image-7\"") !== false) { fwrite(STDERR, "old id survived: $out\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_remap_attachment_refs negative lookahead: remapping id 1 never touches id 12 (digit-boundary safety)" {
  # The exact property design doc §9.1's (?!\d) exists for: "id":1 is a
  # PREFIX of "id":12 as a plain string, and a naive (non-lookahead) match
  # would corrupt a reference to a completely different attachment.
  run php_run '
    $out = sitegraft_remap_attachment_refs(
      [["old" => "1", "new" => "999"]],
      "keep \"id\":12 untouched, only remap \"id\":1 here"
    );
    if (strpos($out, "\"id\":12") === false) { fwrite(STDERR, "id 12 was corrupted: $out\n"); exit(1); }
    if (strpos($out, "\"id\":999") === false) { fwrite(STDERR, "id 1 was not remapped: $out\n"); exit(1); }
    if (strpos($out, "\"id\":1 ") !== false) { fwrite(STDERR, "old id 1 survived: $out\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_remap_attachment_refs remaps multiple attachments in one pass without sentinel collision" {
  # Two-pass ordering (design doc §9.1) exists specifically so a pass-2
  # resolution for one attachment can never be re-matched by a pass-1
  # pattern still queued for a DIFFERENT attachment in the same batch —
  # exercised here by mapping old id 1 -> new id 12, while old id 12 is
  # ALSO being remapped (to 200) in the exact same call.
  run php_run '
    $out = sitegraft_remap_attachment_refs(
      [["old" => "1", "new" => "12"], ["old" => "12", "new" => "200"]],
      "\"id\":1 and \"id\":12"
    );
    if (strpos($out, "\"id\":12 and \"id\":200") === false) { fwrite(STDERR, "collision corrupted the result: $out\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_remap_attachment_refs leaves content with no matching attachment id completely untouched" {
  run php_run '
    $original = "protected content mentioning \"id\":999 which is not in the map";
    $out = sitegraft_remap_attachment_refs([["old" => "1", "new" => "2"]], $original);
    if ($out !== $original) { fwrite(STDERR, "unrelated content was modified: $out\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_remap_domain rewrites both the plain and JSON-escaped-slash forms of the domain string" {
  run php_run '
    $out = sitegraft_remap_domain(
      "see https://a.example.com/x and https:\/\/a.example.com\/y",
      "https://a.example.com", "https://b.example.com"
    );
    if (strpos($out, "https://b.example.com/x") === false) { fwrite(STDERR, "plain form not rewritten: $out\n"); exit(1); }
    if (strpos($out, "https:\/\/b.example.com\/y") === false) { fwrite(STDERR, "escaped form not rewritten: $out\n"); exit(1); }
    if (strpos($out, "a.example.com") !== false) { fwrite(STDERR, "old domain survived: $out\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_remap_domain leaves content with no matching domain string completely untouched" {
  run php_run '
    $original = "protected content, no domain reference here at all";
    $out = sitegraft_remap_domain($original, "https://a.example.com", "https://b.example.com");
    if ($out !== $original) { fwrite(STDERR, "unrelated content was modified: $out\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_remap_domain is a no-op (returns input unchanged) when \$from is empty" {
  run php_run '
    $original = "https://anything.example.com stays exactly as-is";
    $out = sitegraft_remap_domain($original, "", "https://b.example.com");
    if ($out !== $original) { fwrite(STDERR, "content changed despite empty \$from: $out\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# --- sitegraft_domain_present (lib/verify.sh's verify_domain_absent) -------
# Security-review fix-pack (Viktor, MINOR): an earlier draft of
# verify_domain_absent checked the JSON-escaped form ("https:\/\/...") for
# post_content/post_excerpt but only the PLAIN form for a migrated option's
# serialized value — an asymmetry that would miss a migrated option whose
# value is (or contains) a plain string carrying literal escaped-JSON bytes.
# sitegraft_domain_present() is the ONE function both surfaces in
# verify_domain_absent now call, so this exact asymmetry cannot recur
# silently. These tests run the REAL production function via a bare `php`
# CLI call (same convention as every other test in this file) — not a bash
# stub standing in for it — so a regression back to the old
# plain-form-only behavior on either call site would show up here.

@test "sitegraft_domain_present finds the PLAIN form of the domain" {
  run php_run '
    $found = sitegraft_domain_present("see https://a.example.com/booking for details", "https://a.example.com", "https:\/\/a.example.com");
    echo $found ? "OK" : "NOT-FOUND";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_domain_present finds the JSON-ESCAPED form of the domain (the exact case a plain-form-only check would miss)" {
  run php_run '
    // A migrated option whose live value is (or, for a plain string,
    // maybe_serialize()-passes-through-unchanged-as) literal escaped-JSON
    // bytes — e.g. a raw JSON blob a module stored as a string rather than
    // an array/object. NO plain-form occurrence anywhere in this haystack —
    // a plain-form-only check (the pre-fix behavior) would report this as
    // absent.
    $serialized_option_value = "{\"url\":\"https:\/\/a.example.com\"}";
    if (strpos($serialized_option_value, "https://a.example.com") !== false) { fwrite(STDERR, "test fixture is broken: the plain form is ALSO present, this would not distinguish the fix\n"); exit(1); }
    $found = sitegraft_domain_present($serialized_option_value, "https://a.example.com", "https:\/\/a.example.com");
    echo $found ? "OK" : "NOT-FOUND";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_domain_present returns false when neither form is present" {
  run php_run '
    $found = sitegraft_domain_present("nothing relevant here at all", "https://a.example.com", "https:\/\/a.example.com");
    echo $found ? "FOUND-BUT-SHOULD-NOT-BE" : "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# --- sitegraft_write_remapped_post: issue #43 -------------------------------
#
# lib/graft.sh's two remap steps (graft_remap_attachment_ids,
# graft_search_replace_domain) rewrite post_content/post_excerpt with
# sitegraft_remap_attachment_refs/sitegraft_remap_domain (above), then used
# to save the result with `wp_update_post( array( "ID" => ..., ... ) )`.
#
# wp_update_post() only calls wp_slash() on its $postarr when $postarr is
# an OBJECT (wp-includes/post.php's `is_object( $postarr )` branch) — the
# array form never gets slashed. wp_insert_post(), which wp_update_post()
# delegates to for an existing ID, unconditionally runs
# `$data = wp_unslash( $data )` immediately before the write regardless.
# One unslash pass with no matching slash pass silently eats every literal
# backslash in $content/$excerpt.
#
# That is exactly the shape sitegraft_remap_domain's own output takes: it
# explicitly matches and rewrites the JSON-escaped `https:\/\/` form,
# which is how a domain appears inside an Etch block's JSON attribute
# comment — losing that escaping breaks parse_blocks()'s JSON decode
# SILENTLY (no error, no crash, a block that renders without its
# attributes).
#
# sitegraft_write_remapped_post fixes this by writing via $wpdb->update()
# instead — no slash/unslash pass at all — the same choice, for the same
# reason, modules/etch.sh's own Etch-component-reference remap already
# makes (and calling clean_post_cache() afterward, replacing the
# object-cache invalidation wp_update_post() would otherwise have done).
#
# MUTATION PROOF (do this by hand, not part of the suite): temporarily
# change sitegraft_write_remapped_post's body (lib/php/content-remap-
# functions.php) to call `wp_update_post( array( "ID" => $post_id,
# "post_content" => $content, "post_excerpt" => $excerpt ) )` instead of
# $wpdb->update(...), then rerun this file. The `wp_update_post` stub
# defined below models the real array-vs-object slashing asymmetry
# precisely (never slashes the array form, always unslashes before
# "writing"), so that mutation reproduces issue #43 exactly: the
# byte-for-byte assertion in the first test below fails, because the
# written value comes back with its "\/" eaten down to "/". Revert
# afterward — this is confirmation, not a permanent test path.
@test "sitegraft_write_remapped_post writes via \$wpdb->update (not wp_update_post) -- content and excerpt keep their backslashes byte-for-byte (#43)" {
  run php_run '
    class FakeWpdb {
      public $posts = "wp_posts";
      public $last_update = null;
      public function update( $table, $data, $where ) {
        $this->last_update = array( "table" => $table, "data" => $data, "where" => $where );
        return 1;
      }
    }
    $GLOBALS["wpdb"] = new FakeWpdb();
    $GLOBALS["cache_cleared"] = array();
    function clean_post_cache( $id ) { $GLOBALS["cache_cleared"][] = $id; }

    // Present only so the MUTATION PROOF above (see this test'\''s own
    // docblock) can swap the production call back to the old form without
    // also having to edit this test file: models real wp_update_post()'\''s
    // array-vs-object slashing asymmetry -- the array form is never
    // slashed, yet the write always unslashes, exactly the bug in #43.
    function wp_unslash( $value ) { return is_string( $value ) ? stripslashes( $value ) : $value; }
    function wp_update_post( $postarr ) {
      global $wpdb;
      $wpdb->last_update = array(
        "table" => $wpdb->posts,
        "data"  => array(
          "post_content" => wp_unslash( $postarr["post_content"] ),
          "post_excerpt" => wp_unslash( $postarr["post_excerpt"] ),
        ),
        "where" => array( "ID" => $postarr["ID"] ),
      );
      return $postarr["ID"];
    }

    // Exactly the shape sitegraft_remap_domain produces: the JSON-escaped
    // domain form inside an Etch block'\''s JSON attribute comment.
    $orig      = "<!-- wp:etch/image {\"src\":\"https:\/\/old.example.com\/x.jpg\"} -->";
    $rewritten = "<!-- wp:etch/image {\"src\":\"https:\/\/new.example.com\/x.jpg\"} -->";

    global $wpdb;
    $changed = sitegraft_write_remapped_post( 105, $rewritten, "excerpt-unchanged", $orig, "excerpt-unchanged" );

    if ( ! $changed ) { fwrite(STDERR, "reported no change when content differed\n"); exit(1); }
    if ( $wpdb->last_update === null ) { fwrite(STDERR, "no write happened at all\n"); exit(1); }
    if ( $wpdb->last_update["table"] !== "wp_posts" ) { fwrite(STDERR, "wrong table: " . $wpdb->last_update["table"] . "\n"); exit(1); }
    if ( $wpdb->last_update["where"] !== array( "ID" => 105 ) ) { fwrite(STDERR, "wrong WHERE clause\n"); exit(1); }

    $written = $wpdb->last_update["data"]["post_content"];
    if ( $written !== $rewritten ) { fwrite(STDERR, "content not written byte-for-byte: got [$written] want [$rewritten]\n"); exit(1); }
    if ( strpos( $written, "https:\/\/new.example.com" ) === false ) { fwrite(STDERR, "backslash was eaten: $written\n"); exit(1); }
    if ( empty( $GLOBALS["cache_cleared"] ) || $GLOBALS["cache_cleared"][0] !== 105 ) {
      fwrite(STDERR, "clean_post_cache was not called for post 105\n"); exit(1);
    }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "sitegraft_write_remapped_post reports no change and never touches the DB or cache when content and excerpt are unchanged" {
  run php_run '
    class FakeWpdb {
      public $update_called = false;
      public function update( $table, $data, $where ) { $this->update_called = true; return 1; }
    }
    $GLOBALS["wpdb"] = new FakeWpdb();
    function clean_post_cache( $id ) { fwrite(STDERR, "clean_post_cache should not have been called\n"); exit(1); }

    global $wpdb;
    $changed = sitegraft_write_remapped_post( 1, "same content", "same excerpt", "same content", "same excerpt" );

    if ( $changed ) { fwrite(STDERR, "reported a change when nothing differed\n"); exit(1); }
    if ( $wpdb->update_called ) { fwrite(STDERR, "\$wpdb->update was called despite no change\n"); exit(1); }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}
