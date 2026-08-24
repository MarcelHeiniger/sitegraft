# tests/unit/test_media_import_batch.bats — the WordPress-calling half of
# lib/php/media-import-functions.php: sitegraft_media_import_batch and
# sitegraft_media_import_one, run under tests/unit/fixtures/wpstub.php by a
# bare `php` CLI. No WordPress bootstrap, no DDEV, no wp-cli — same
# convention as tests/unit/test_content_remap_functions.bats.
#
# Why this file exists: these two functions were left uncovered on the
# grounds that they "can only be exercised against a real WP bootstrap".
# That was measurably wrong, and it was hiding four live guards. Deleting
# `update_post_meta( $result['new_id'], '_sitegraft_source_id', $old_id )`
# — the single write the entire idempotent-resume design rests on, and the
# only thing graft_prune_previous_run can find a previous run's posts by —
# left the whole suite green. So did dropping the file_exists guard, the
# no_local_file bucket, and the is_wp_error check after the insert. Each of
# those four now has a test that fails without it (see the per-test
# mutation notes).
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  PHP_LIB="${REPO_ROOT}/lib/php/media-import-functions.php"
  WP_STUB="${REPO_ROOT}/tests/unit/fixtures/wpstub.php"
  [ -f "$PHP_LIB" ] || skip "lib/php/media-import-functions.php not found"
  [ -f "$WP_STUB" ] || skip "tests/unit/fixtures/wpstub.php not found"
  command -v php >/dev/null 2>&1 || skip "php CLI not available in this environment"
  UPLOADS="${BATS_TEST_TMPDIR}/uploads"
  mkdir -p "${UPLOADS}/2024/01"
  printf 'not really a jpeg' > "${UPLOADS}/2024/01/a.jpg"
  printf 'not really a jpeg either' > "${UPLOADS}/2024/01/b.jpg"
}

# php_run <script> — runs <script> with the WordPress stub and the real
# production library both already required, in that order.
php_run() {
  php -r "require '${WP_STUB}'; require '${PHP_LIB}'; wpstub_set_uploads('${UPLOADS}'); $1"
}

# --- the resume marker (the guard the whole PR's thesis rests on) ----------

# MUTATION (run live): deleting the
# `update_post_meta( $result['new_id'], '_sitegraft_source_id', $old_id );`
# line in sitegraft_media_import_batch fails THIS test and this test alone
# in the whole suite. Without it B carries no record of where an
# attachment came from, so the next call re-imports everything (the exact
# duplicate-attachment bug this batching rewrite claims to fix) and
# graft_prune_previous_run has nothing to prune.
@test "sitegraft_media_import_batch tags every attachment it imports with _sitegraft_source_id pointing back at A's id" {
  run php_run '
    wpstub_add_attachment(10, "A", "2024/01/a.jpg");
    $r = sitegraft_media_import_batch([["old" => 10, "rel_path" => "2024/01/a.jpg", "title" => "A"]]);
    $new_id = $r["map"]["10"];
    echo json_encode([
      "imported"  => $r["imported"],
      "source_id" => wpstub_meta($new_id, "_sitegraft_source_id"),
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"imported":[10]'* ]] || false
  [[ "$output" == *'"source_id":10'* ]] || false
}

@test "sitegraft_media_import_batch re-reads that marker from B and never re-imports an attachment a previous interrupted call already created" {
  run php_run '
    wpstub_add_attachment(10, "A", "2024/01/a.jpg");
    wpstub_add_attachment(11, "B", "2024/01/b.jpg");
    wpstub_add_existing(900, 10);   // left behind by an earlier, killed call
    $r = sitegraft_media_import_batch([
      ["old" => 10, "rel_path" => "2024/01/a.jpg", "title" => "A"],
      ["old" => 11, "rel_path" => "2024/01/b.jpg", "title" => "B"],
    ]);
    echo json_encode([
      "imported"        => $r["imported"],
      "already_present" => $r["already_present"],
      "map"             => $r["map"],
      "inserts"         => wpstub_insert_count(),
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"imported":[11]'* ]] || false
  [[ "$output" == *'"already_present":[10]'* ]] || false
  [[ "$output" == *'"10":900'* ]] || false
  # Exactly one insert: attachment 11. Attachment 10 was never touched.
  [[ "$output" == *'"inserts":1'* ]] || false
}

@test "sitegraft_media_import_batch run twice over the same request imports nothing the second time and returns the identical map" {
  run php_run '
    wpstub_add_attachment(10, "A", "2024/01/a.jpg");
    $req = [["old" => 10, "rel_path" => "2024/01/a.jpg", "title" => "A"]];
    $first  = sitegraft_media_import_batch($req);
    $after_first = wpstub_insert_count();
    $second = sitegraft_media_import_batch($req);
    echo json_encode([
      "same_map"      => ($first["map"] == $second["map"]),
      "second_import" => $second["imported"],
      "second_resume" => $second["already_present"],
      "new_inserts"   => wpstub_insert_count() - $after_first,
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"same_map":true'* ]] || false
  [[ "$output" == *'"second_import":[]'* ]] || false
  [[ "$output" == *'"second_resume":[10]'* ]] || false
  [[ "$output" == *'"new_inserts":0'* ]] || false
}

# --- the three other guards that survived every mutation before this file --

# MUTATION (M14, run live): removing the `if ( $rel_path === '' )` branch
# sends an external/offloaded attachment into sitegraft_media_import_one,
# which reports it as a hard per-item failure instead of a legitimate skip
# — and, after the fix-pack in this same PR, a per-item failure is now a
# non-zero exit for the whole step. Conflating the two would turn every
# offloaded-media site into an unrunnable graft.
@test "sitegraft_media_import_batch buckets an attachment with no _wp_attached_file as no_local_file, not as a failure, and never inserts it" {
  run php_run '
    $r = sitegraft_media_import_batch([["old" => 10, "rel_path" => "", "title" => "external"]]);
    echo json_encode([
      "no_local_file" => $r["no_local_file"],
      "failed"        => $r["failed"],
      "inserts"       => wpstub_insert_count(),
      "ok"            => $r["ok"],
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"no_local_file":[10]'* ]] || false
  [[ "$output" == *'"failed":[]'* ]] || false
  [[ "$output" == *'"inserts":0'* ]] || false
  [[ "$output" == *'"ok":true'* ]] || false
}

# MUTATION (M12, run live): dropping the `! file_exists( $abs_path )` guard
# in sitegraft_media_import_one lets wp_insert_attachment register a post
# pointing at a path that holds nothing — a broken attachment on B that
# every later step (remap, verify) treats as a successful import.
@test "sitegraft_media_import_one reports a file the media sync never placed as a per-item failure, and inserts nothing" {
  run php_run '
    $r = sitegraft_media_import_batch([["old" => 10, "rel_path" => "2024/01/never-synced.jpg", "title" => "X"]]);
    echo json_encode([
      "failed"  => $r["failed"],
      "inserts" => wpstub_insert_count(),
      "map"     => $r["map"],
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"old":10'* ]] || false
  [[ "$output" == *"file not found on B"* ]] || false
  [[ "$output" == *'"inserts":0'* ]] || false
}

# MUTATION (M26, run live): dropping the `is_wp_error( $new_id ) || ! $new_id`
# check makes the batch write _sitegraft_source_id against a WP_Error object
# (or against id 0) and report the item as imported — a fabricated map row
# that graft_remap_attachment_ids would then apply to real content.
@test "sitegraft_media_import_one surfaces a WP_Error from wp_insert_attachment as a per-item failure carrying its message, and writes no resume marker" {
  run php_run '
    $GLOBALS["wpstub"]["insert_error"] = "invalid post type";
    $r = sitegraft_media_import_batch([["old" => 10, "rel_path" => "2024/01/a.jpg", "title" => "A"]]);
    echo json_encode([
      "failed"    => $r["failed"],
      "imported"  => $r["imported"],
      "map"       => $r["map"],
      "meta_on_0" => wpstub_meta(0, "_sitegraft_source_id"),
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid post type"* ]] || false
  [[ "$output" == *'"imported":[]'* ]] || false
  [[ "$output" == *'"map":{}'* ]] || false
  [[ "$output" == *'"meta_on_0":""'* ]] || false
}

@test "sitegraft_media_import_one treats a falsy id from wp_insert_attachment as a failure too, with its own distinct message" {
  run php_run '
    $GLOBALS["wpstub"]["insert_zero"] = true;
    $r = sitegraft_media_import_batch([["old" => 10, "rel_path" => "2024/01/a.jpg", "title" => "A"]]);
    echo json_encode($r["failed"]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp_insert_attachment returned no id"* ]] || false
}

# --- path confinement (N1, both reviewers) ---------------------------------

# Before the fix this returned {"ok":true,"imported":[66]} and registered a
# file from OUTSIDE the uploads tree as an attachment on B. That is not
# only a read-out-of-bounds: graft_prune_previous_run deletes every
# _sitegraft_source_id-tagged post with `wp post delete --force`, which
# removes the attached file from disk — so the NEXT run of a graft would
# delete that out-of-tree file for real.
@test "sitegraft_media_import_batch refuses a rel_path that resolves outside B's uploads directory, and imports nothing" {
  local outside="${BATS_TEST_TMPDIR}/outside"
  mkdir -p "$outside"
  printf 'pretend this is wp-config' > "${outside}/secret.php"
  run php_run '
    $r = sitegraft_media_import_batch([["old" => 66, "rel_path" => "../outside/secret.php", "title" => "X"]]);
    echo json_encode([
      "failed"   => $r["failed"],
      "imported" => $r["imported"],
      "inserts"  => wpstub_insert_count(),
      "ok"       => $r["ok"],
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolves outside B's uploads directory"* ]] || false
  [[ "$output" == *'"imported":[]'* ]] || false
  [[ "$output" == *'"inserts":0'* ]] || false
  # Still accounted for -- refused, never dropped on the floor.
  [[ "$output" == *'"ok":true'* ]] || false
  [ -f "${outside}/secret.php" ]
}

@test "sitegraft_media_import_batch refuses a symlink inside uploads that resolves outside it" {
  local outside="${BATS_TEST_TMPDIR}/outside"
  mkdir -p "$outside"
  printf 'pretend this is wp-config' > "${outside}/secret.php"
  ln -s "${outside}/secret.php" "${UPLOADS}/2024/01/link.php"
  run php_run '
    $r = sitegraft_media_import_batch([["old" => 66, "rel_path" => "2024/01/link.php", "title" => "X"]]);
    echo json_encode(["failed" => $r["failed"], "inserts" => wpstub_insert_count()]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolves outside B's uploads directory"* ]] || false
  [[ "$output" == *'"inserts":0'* ]] || false
}

# "The file isn't there" and "that path points outside the uploads tree"
# are two different facts about two different problems, and realpath()
# returns false for BOTH -- so a single message covering both would tell an
# operator chasing a failed graft the wrong thing. Kept distinct on purpose.
@test "sitegraft_media_import_batch distinguishes an absent file from a path outside the uploads tree" {
  run php_run '
    $r = sitegraft_media_import_batch([
      ["old" => 10, "rel_path" => "2024/01/never-synced.jpg", "title" => "X"],
      ["old" => 11, "rel_path" => "../outside/also-absent.php", "title" => "Y"],
    ]);
    $by_old = [];
    foreach ($r["failed"] as $f) { $by_old[$f["old"]] = $f["error"]; }
    echo json_encode($by_old);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"file not found on B"* ]] || false
  # An escaping path that does not exist either is reported as absent, not
  # as an escape: nothing outside the tree was reachable, so nothing was
  # confined-out. That message is reserved for a path that really
  # does resolve to an existing file outside uploads.
  [[ "$output" != *"resolves outside B's uploads directory"* ]] || false
}

# --- title handling --------------------------------------------------------

@test "sitegraft_media_import_one uses A's title verbatim, including non-ASCII bytes" {
  run php_run '
    $r = sitegraft_media_import_batch([["old" => 10, "rel_path" => "2024/01/a.jpg", "title" => "Café «déjà vu»"]]);
    echo $GLOBALS["wpstub"]["inserted"][0]["postarr"]["post_title"];
  '
  [ "$status" -eq 0 ]
  [ "$output" = "Café «déjà vu»" ]
}

@test "sitegraft_media_import_one falls back to the filename without its extension when A had no title" {
  run php_run '
    sitegraft_media_import_batch([["old" => 10, "rel_path" => "2024/01/a.jpg", "title" => ""]]);
    echo $GLOBALS["wpstub"]["inserted"][0]["postarr"]["post_title"];
  '
  [ "$status" -eq 0 ]
  [ "$output" = "a" ]
}

@test "sitegraft_media_import_one points the attachment at the synced file and stores generated metadata" {
  run php_run '
    $r = sitegraft_media_import_batch([["old" => 10, "rel_path" => "2024/01/a.jpg", "title" => "A"]]);
    $new_id = $r["map"]["10"];
    echo json_encode([
      "file"      => $GLOBALS["wpstub"]["inserted"][0]["file"],
      "mime"      => $GLOBALS["wpstub"]["inserted"][0]["postarr"]["post_mime_type"],
      "status"    => $GLOBALS["wpstub"]["inserted"][0]["postarr"]["post_status"],
      "meta_for"  => $GLOBALS["wpstub"]["metadata_written"][0]["id"],
      "same_id"   => ($GLOBALS["wpstub"]["metadata_written"][0]["id"] === (int) $new_id),
    ], JSON_UNESCAPED_SLASHES);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"2024/01/a.jpg"* ]] || false
  [[ "$output" == *'"mime":"image/jpeg"'* ]] || false
  [[ "$output" == *'"status":"inherit"'* ]] || false
  [[ "$output" == *'"same_id":true'* ]] || false
}

# --- accounting across a genuinely mixed batch -----------------------------

@test "sitegraft_media_import_batch accounts for every requested attachment across all four buckets at once" {
  run php_run '
    wpstub_add_existing(900, 12);
    $r = sitegraft_media_import_batch([
      ["old" => 10, "rel_path" => "2024/01/a.jpg",          "title" => "A"],  // imported
      ["old" => 11, "rel_path" => "2024/01/missing.jpg",    "title" => "B"],  // failed
      ["old" => 12, "rel_path" => "2024/01/b.jpg",          "title" => "C"],  // already present
      ["old" => 13, "rel_path" => "",                       "title" => "D"],  // no local file
    ]);
    echo json_encode([
      "ok" => $r["ok"], "requested" => $r["requested"], "accounted_for" => $r["accounted_for"],
      "imported" => $r["imported"], "already_present" => $r["already_present"],
      "no_local_file" => $r["no_local_file"], "failed_count" => count($r["failed"]),
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || false
  [[ "$output" == *'"requested":4'* ]] || false
  [[ "$output" == *'"accounted_for":4'* ]] || false
  [[ "$output" == *'"imported":[10]'* ]] || false
  [[ "$output" == *'"already_present":[12]'* ]] || false
  [[ "$output" == *'"no_local_file":[13]'* ]] || false
  [[ "$output" == *'"failed_count":1'* ]] || false
}

# --- F1: the confinement guard's own trailing slash --------------------------

# The guard compares against $uploads_base . '/', not against $uploads_base.
# That single character is the whole guard: without it a SIBLING directory
# whose name merely starts with the uploads path passes the prefix test.
# Measured with the slash removed:
#   uploads = .../probe/uploads , rel_path = "../uploads-evil/secret.php"
#   real code -> failed "resolves outside", inserts 0
#   mutant    -> {"imported":[1],"map":{"1":1000}}
# A file from a sibling directory registered as an attachment on B — and
# graft_prune_previous_run's `wp post delete --force` would delete it from
# disk on the NEXT graft. Nothing pinned this before.
@test "sitegraft_media_import_batch refuses a sibling directory whose name merely starts with the uploads path" {
  local evil="${UPLOADS}-evil"
  mkdir -p "$evil"
  printf 'pretend this is wp-config' > "${evil}/secret.php"
  run php_run '
    $r = sitegraft_media_import_batch([["old" => 77, "rel_path" => "../'"$(basename "$evil")"'/secret.php", "title" => "X"]]);
    echo json_encode([
      "failed"   => $r["failed"],
      "imported" => $r["imported"],
      "inserts"  => wpstub_insert_count(),
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolves outside B's uploads directory"* ]] || false
  [[ "$output" == *'"imported":[]'* ]] || false
  [[ "$output" == *'"inserts":0'* ]] || false
  [ -f "${evil}/secret.php" ]
}

# --- F2: the resume query's own result cap -----------------------------------

# get_posts() defaults numberposts to 5 and copies it into posts_per_page
# whenever posts_per_page is empty, so `'posts_per_page' => -1` is what makes
# the resume query see the WHOLE of B rather than its five most recent
# attachments. Delete it and a re-run on any site with more than five media
# items re-imports everything past the fifth as a DUPLICATE — word for word
# the bug the resumability design exists to prevent.
#
# This went undetected because the stub used to ignore posts_per_page
# entirely: the mutant stayed green at 471/471. Six attachments, one past
# the default cap, is the smallest case that bites.
@test "sitegraft_media_import_batch sees every already-present attachment on resume, past get_posts' default five-row cap" {
  run php_run '
    $req = [];
    for ($old = 1; $old <= 6; $old++) {
      wpstub_add_existing(900 + $old, $old);
      $req[] = ["old" => $old, "rel_path" => "2024/01/a.jpg", "title" => "A"];
    }
    $r = sitegraft_media_import_batch($req);
    echo json_encode([
      "imported"     => $r["imported"],
      "already"      => count($r["already_present"]),
      "map_size"     => count((array) $r["map"]),
      "inserts"      => wpstub_insert_count(),
      "ok"           => $r["ok"],
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"imported":[]'* ]] || false
  [[ "$output" == *'"already":6'* ]] || false
  [[ "$output" == *'"map_size":6'* ]] || false
  # The one that matters: nothing was re-imported as a duplicate.
  [[ "$output" == *'"inserts":0'* ]] || false
  [[ "$output" == *'"ok":true'* ]] || false
}

# --- B1: the confinement guard's own ANCHOR ---------------------------------

# The sibling test above pins the trailing '/'. This one pins the `!== 0`.
# Relaxed to `=== false`, the guard stops asking "does this path START in
# uploads?" and starts asking "does the uploads path appear ANYWHERE in it?"
# — and a full-path mirror satisfies that. rsnapshot, borg, a bind-mount:
# any backup that files things under their absolute path produces one.
#
#   uploads   = /srv/site/wp-content/uploads
#   real_path = /mnt/backup/srv/site/wp-content/uploads/x.jpg   <- strpos 11, not 0
#
# Measured: real code refuses; with the anchor relaxed,
# {"imported":[42],"inserts":1}. And the next graft's
# graft_prune_previous_run would then `wp post delete --force` that
# out-of-tree file off the disk.
#
# pwd -P is load-bearing, not decoration: BATS_TEST_TMPDIR can be an
# unresolved path (/tmp -> /private/tmp on macOS), while $real_path is always
# resolved. A mirror built from the UNresolved path would not contain the
# resolved uploads path at all, so the test would pass for the wrong reason
# and keep passing under the mutant.
@test "sitegraft_media_import_batch refuses a full-path mirror that contains the uploads path without starting with it" {
  local real_tmp real_uploads mirror_file rel
  real_tmp=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  real_uploads="${real_tmp}/uploads"
  # .../mirror/<the whole resolved uploads path>/x.jpg
  mirror_file="${real_tmp}/mirror${real_uploads}/x.jpg"
  mkdir -p "$(dirname "$mirror_file")"
  printf 'a backup copy, not the live file' > "$mirror_file"
  # One level up out of uploads, then down into the mirror. Constructed, not
  # guessed, so it stays correct whatever the tmpdir happens to be.
  rel="../mirror${real_uploads}/x.jpg"

  # The premise itself is asserted: the resolved path must CONTAIN the
  # uploads path somewhere other than position 0, or this test proves nothing.
  [[ "$mirror_file" == *"${real_uploads}/"* ]] || false
  [[ "$mirror_file" != "${real_uploads}/"* ]] || false

  run php_run "
    \$r = sitegraft_media_import_batch([['old' => 42, 'rel_path' => '${rel}', 'title' => 'X']]);
    echo json_encode([
      'failed'   => \$r['failed'],
      'imported' => \$r['imported'],
      'inserts'  => wpstub_insert_count(),
    ]);
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolves outside B's uploads directory"* ]] || false
  [[ "$output" == *'"imported":[]'* ]] || false
  [[ "$output" == *'"inserts":0'* ]] || false
  [ -f "$mirror_file" ]
}

# --- B2: the resume marker's write was never checked -------------------------

# update_post_meta's return value used to be dropped on the floor, and the
# stub used to return true unconditionally, so the two hid each other. A B
# that cannot write the marker — a DB error, or a plugin short-circuiting the
# `update_post_metadata` filter — produced this, measured:
#   run1: {"ok":true,"imported":[7],"failed":[],"inserts":1}
#   run2: {"ok":true,"imported":[7],"already":[],"inserts":2}
# Full success reported, no marker on B, and the re-run imported a DUPLICATE
# — word for word the bug the resumability design exists to prevent. And
# graft_prune_previous_run could never find that attachment again.
@test "sitegraft_media_import_batch refuses to call an attachment imported when its resume marker could not be written" {
  run php_run '
    $GLOBALS["wpstub"]["meta_write_fail"] = ["_sitegraft_source_id"];
    wpstub_add_attachment(7, "A", "2024/01/a.jpg");
    $r = sitegraft_media_import_batch([["old" => 7, "rel_path" => "2024/01/a.jpg", "title" => "A"]]);
    echo json_encode([
      "imported" => $r["imported"],
      "map"      => $r["map"],
      "failed"   => $r["failed"],
      "ok"       => $r["ok"],
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"imported":[]'* ]] || false
  [[ "$output" == *'"map":{}'* ]] || false
  [[ "$output" == *"_sitegraft_source_id marker could not be written"* ]] || false
  # The orphan is NAMED, so an operator can remove it deliberately. It is not
  # auto-deleted: wp_delete_attachment reaches wp_delete_attachment_files,
  # which would destroy the file graft_media_sync just placed on B.
  [[ "$output" == *"post 1000"* ]] || false
  [[ "$output" == *"will import a second copy"* ]] || false
  # Still accounted for -- refused, never dropped on the floor.
  [[ "$output" == *'"ok":true'* ]] || false
}

# The other half of that fix, and the reason it reads the value back instead
# of checking the boolean. Verified against wp-includes/meta.php:
# update_metadata returns FALSE when the stored value is already identical
# ($old_value[0] === $meta_value) — nothing failed, there was simply nothing
# to write. A boolean check would call that an error and fail a perfectly
# good import; the read-back sees the marker is present and correct.
@test "sitegraft_media_import_batch accepts a resume marker that was already correct, which core reports as a false return" {
  run php_run '
    // Marker already sitting on the id the insert will hand back, with no
    // post row -- so the batch does not see it as already_present and really
    // does go through the import path, where update_post_meta returns false
    // for "unchanged".
    $GLOBALS["wpstub"]["meta"][1000]["_sitegraft_source_id"] = 7;
    wpstub_add_attachment(7, "A", "2024/01/a.jpg");
    $r = sitegraft_media_import_batch([["old" => 7, "rel_path" => "2024/01/a.jpg", "title" => "A"]]);
    echo json_encode(["imported" => $r["imported"], "failed" => $r["failed"], "map" => $r["map"]]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"imported":[7]'* ]] || false
  [[ "$output" == *'"failed":[]'* ]] || false
  [[ "$output" == *'"7":1000'* ]] || false
}

# Same dropped-return-value class, smaller stake: an attachment on B with no
# _wp_attachment_metadata has no image sizes, so every thumbnail and srcset
# on the grafted site silently falls back to the full-size file.
@test "sitegraft_media_import_one reports a failure when the generated attachment metadata could not be stored" {
  run php_run '
    $GLOBALS["wpstub"]["meta_write_fail"] = ["_wp_attachment_metadata"];
    wpstub_add_attachment(7, "A", "2024/01/a.jpg");
    $r = sitegraft_media_import_batch([["old" => 7, "rel_path" => "2024/01/a.jpg", "title" => "A"]]);
    echo json_encode(["imported" => $r["imported"], "failed" => $r["failed"], "ok" => $r["ok"]]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"imported":[]'* ]] || false
  [[ "$output" == *"attachment metadata could not be stored"* ]] || false
  [[ "$output" == *'"ok":true'* ]] || false
}

# --- the metadata guard's other half: an EMPTY result is normal ------------

# wp_generate_attachment_metadata legitimately returns an EMPTY array for
# anything WordPress generates nothing for. Verified in
# wp-admin/includes/image.php: it opens with `$metadata = array();` and only
# fills it for a displayable image (or HEIC), a video, or an audio file. A
# .zip/.doc/.csv/.txt hits none of those branches — and neither does an
# ordinary JPEG when file_is_displayable_image() says no, which is what
# happens when GD and Imagick are both missing, routine on the elderly
# hosting this tool exists to migrate.
#
# So `! empty( $metadata )` is what stops an empty-but-correct result from
# being read as a storage failure. Without it, ONE non-image anywhere in a
# media library fails the entire step. Measured side by side:
#   prod + faithful stub, .zip : {"ok":true,"imported":[9],"failed":[]}
#   mutant + faithful stub     : imported:[] failed:["metadata could not be stored"]
#   mutant + the OLD stub      : {"ok":true,"imported":[9],"failed":[]}  <- suite blind
# The old stub returned a non-empty array for everything, so the guard had
# no test at all and the mutant survived a full green suite.
@test "sitegraft_media_import_batch imports a non-image attachment whose generated metadata is legitimately empty" {
  printf 'PK\003\004 not really a zip' > "${UPLOADS}/2024/01/docs.zip"
  run php_run '
    $r = sitegraft_media_import_batch([["old" => 9, "rel_path" => "2024/01/docs.zip", "title" => "Docs"]]);
    $new_id = $r["map"]["9"];
    echo json_encode([
      "ok"        => $r["ok"],
      "imported"  => $r["imported"],
      "failed"    => $r["failed"],
      "source_id" => wpstub_meta($new_id, "_sitegraft_source_id"),
    ]);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"imported":[9]'* ]] || false
  [[ "$output" == *'"failed":[]'* ]] || false
  [[ "$output" == *'"ok":true'* ]] || false
  # It is a fully tracked import, not a grudging pass: the resume marker is
  # written, so a re-run will not duplicate it.
  [[ "$output" == *'"source_id":9'* ]] || false
}
