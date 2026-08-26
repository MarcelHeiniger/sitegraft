# tests/unit/test_content_remap_functions.bats — the ACTUAL remap logic
# behind `sitegraft graft`'s two remap steps (design doc §9.1/§9.4), tested
# in real isolation via a bare `php` CLI invocation. No WordPress bootstrap,
# no DDEV, no wp-cli.
#
# Why this file exists (review, Viktor, NIT-1): after the MAJOR-2 fix-pack
# rebuilt graft_remap_attachment_ids/graft_search_replace_domain to stop
# scanning whole tables, the two-pass sentinel substitution moved from an
# inline bash-single-quoted PHP string (syntactically impossible to unit
# test on its own) into lib/php/content-remap-functions.php, `require_once`'d
# by the real `wp eval` calls. Before this file existed, the bash helper
# functions that USED to build the substitution (graft_build_sentinel_commands,
# graft_content_tables_csv) kept their own green unit tests years after
# phase_graft stopped calling either of them — a false coverage signal on
# exactly the logic (a remap that must never contaminate protected data)
# where a coverage gap matters most. Both were removed; this file is where
# the real substitution's real test coverage lives now, running the exact
# same file production requires.
#
# ONLY the two pure remap functions (sitegraft_remap_attachment_refs,
# sitegraft_remap_domain) live here — that is what makes running them
# under a bare `php` CLI with nothing else required possible in the first
# place (review, Kimi, NIT: this header used to describe the whole file
# content-remap-functions.php lives in as "WordPress-independent", which
# stopped being true once sitegraft_write_remapped_post (issue #43) was
# added to it). That third function calls $wpdb->update() and
# clean_post_cache() and is tested separately, under
# tests/unit/fixtures/wpstub.php's stand-ins for those two calls — see
# tests/unit/test_content_remap_write.bats, same convention
# tests/unit/test_media_import_batch.bats already uses for the
# WordPress-calling half of lib/php/media-import-functions.php.
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
