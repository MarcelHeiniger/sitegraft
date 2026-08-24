# tests/unit/test_media_import_functions.bats — the pure, WordPress-free
# half of the batched media-import logic behind `sitegraft graft`'s
# attachment step (issue #11), tested in real isolation via a bare `php`
# CLI invocation. No WordPress bootstrap, no DDEV, no wp-cli.
#
# sitegraft_media_diff_missing and sitegraft_media_build_report are the two
# functions in lib/php/media-import-functions.php that carry this
# rewrite's two hard requirements: resumability at the same (or better)
# granularity than the old per-attachment loop had, and failing closed
# when a batch doesn't account for every requested attachment. The other
# two functions in that file (sitegraft_media_import_one,
# sitegraft_media_import_batch) call WordPress core APIs directly; they
# live in tests/unit/test_media_import_batch.bats, which runs them under
# tests/unit/fixtures/wpstub.php — same bare `php` CLI, an in-memory
# stand-in for the core functions instead of a real bootstrap.
setup() {
  PHP_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/lib/php/media-import-functions.php"
  [ -f "$PHP_LIB" ] || skip "lib/php/media-import-functions.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
}

# php_run <script> — same convention as test_content_remap_functions.bats:
# runs <script> with the library already required, via `php -r`, so the
# test script can use quotes freely without bash escaping headaches.
php_run() {
  php -r "require '${PHP_LIB}'; $1"
}

# --- sitegraft_media_diff_missing ------------------------------------------

@test "sitegraft_media_diff_missing returns every requested id when nothing exists yet (first run of the batch)" {
  run php_run '
    $missing = sitegraft_media_diff_missing([1, 2, 3], []);
    echo json_encode($missing);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "[1,2,3]" ]]
}

@test "sitegraft_media_diff_missing skips ids already present on B (the idempotent-resume case)" {
  # This is the core resumability guarantee: a batch resumed after
  # importing 400 of 518 must not re-import those 400.
  run php_run '
    $missing = sitegraft_media_diff_missing([1, 2, 3], ["1" => 42, "2" => 43]);
    echo json_encode($missing);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "[3]" ]]
}

@test "sitegraft_media_diff_missing returns nothing missing once every id is already present" {
  run php_run '
    $missing = sitegraft_media_diff_missing([1, 2], ["1" => 42, "2" => 43]);
    echo json_encode($missing);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "[]" ]]
}

# Mutation check (proven live: flipping the `!` below from
# `! array_key_exists(...)` to a bare `array_key_exists(...)` makes tests 2
# and 3 above fail immediately -- test 2 would report [1,2] instead of [3]
# and test 3 would report [1,2] instead of []) -- the negation is what
# turns "present" into "missing" and vice versa, i.e. the entire
# resumability contract this function exists for.
@test "sitegraft_media_diff_missing preserves request order and never invents an id that wasn't requested" {
  run php_run '
    $missing = sitegraft_media_diff_missing([3, 1, 2], ["1" => 42]);
    echo json_encode($missing);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "[3,2]" ]]
}

# --- sitegraft_media_build_report ------------------------------------------

@test "sitegraft_media_build_report reports ok=true and a complete map when every id is accounted for" {
  run php_run '
    $report = sitegraft_media_build_report(
      [1, 2, 3, 4],
      ["1" => 101, "2" => 102],   // imported
      ["3" => 103],                // already present
      [4],                          // no local file
      []                             // failed
    );
    echo json_encode($report);
  '
  [ "$status" -eq 0 ]
  local json="$output"
  run jq -e '.ok == true' <<< "$json"
  [ "$status" -eq 0 ]
  run jq -e '.requested == 4 and .accounted_for == 4' <<< "$json"
  [ "$status" -eq 0 ]
  run jq -e '.map == {"1": 101, "2": 102, "3": 103}' <<< "$json"
  [ "$status" -eq 0 ]
}

# This is the exact "fail closed on partial" contract issue #11 asks for:
# a batch that only accounted for 2 of 4 requested attachments must report
# ok=false, not a false global success.
@test "sitegraft_media_build_report reports ok=false when fewer attachments were accounted for than requested" {
  run php_run '
    $report = sitegraft_media_build_report(
      [1, 2, 3, 4],
      ["1" => 101],   // only one imported
      [],               // nothing already present
      [],               // nothing flagged no-local-file
      []                 // nothing flagged failed -- 2, 3, 4 vanished silently
    );
    echo json_encode($report);
  '
  [ "$status" -eq 0 ]
  local json="$output"
  run jq -e '.ok == false' <<< "$json"
  [ "$status" -eq 0 ]
  run jq -e '.requested == 4 and .accounted_for == 1' <<< "$json"
  [ "$status" -eq 0 ]
}

@test "sitegraft_media_build_report reports ok=true with failed entries recorded when every id is accounted for, including legitimate per-item failures" {
  # A corrupt/missing file on one attachment is an accounted-for failure,
  # not a silent gap -- distinct from the unaccounted-for case above.
  run php_run '
    $report = sitegraft_media_build_report(
      [1, 2],
      ["1" => 101],
      [],
      [],
      [["old" => 2, "error" => "file not found on B"]]
    );
    echo json_encode($report);
  '
  [ "$status" -eq 0 ]
  local json="$output"
  run jq -e '.ok == true' <<< "$json"
  [ "$status" -eq 0 ]
  run jq -e '.failed == [{"old": 2, "error": "file not found on B"}]' <<< "$json"
  [ "$status" -eq 0 ]
}

@test "sitegraft_media_build_report's map never lets an already-present entry clobber an imported one or vice versa" {
  run php_run '
    $report = sitegraft_media_build_report(
      [1, 2],
      ["1" => 101],   // imported
      ["2" => 202],   // already present
      [],
      []
    );
    echo json_encode($report);
  '
  [ "$status" -eq 0 ]
  run jq -e '.map == {"1": 101, "2": 202}' <<< "$output"
  [ "$status" -eq 0 ]
}

# PHP's own json_encode ambiguity: an EMPTY PHP array always encodes as the
# JSON array "[]", never "{}", regardless of whether the array was ever
# meant to be an associative map. graft_import_attachments (lib/graft.sh)
# reads .map with jq's `to_entries[]`, which errors out on a JSON array
# ("Cannot use to_entries on an array") -- an unhandled jq failure there
# would abort id-map.tsv's rewrite under `set -e` on exactly the run where
# a batch imported and found nothing (every requested attachment failed or
# had no local file), the one case this guard exists for.
@test "sitegraft_media_build_report's map is a JSON object, never a bare array, even when completely empty" {
  run php_run '
    $report = sitegraft_media_build_report(
      [1, 2],
      [],
      [],
      [1],
      [["old" => 2, "error" => "file not found on B"]]
    );
    echo json_encode($report);
  '
  [ "$status" -eq 0 ]
  local json="$output"
  run jq -e '.map == {}' <<< "$json"
  [ "$status" -eq 0 ]
  run jq -e '.map | type == "object"' <<< "$json"
  [ "$status" -eq 0 ]
}
