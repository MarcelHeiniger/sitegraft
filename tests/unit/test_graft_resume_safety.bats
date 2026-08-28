# tests/unit/test_graft_resume_safety.bats — issue #54: a resume must not
# skip the marker-gated step (`prune`) that made the WXR import safe merely
# because that step's OWN marker is present. Covers:
#   1. graft_reset_id_map_log (the companion cleanup prune now does, so a
#      rerun never leaves a stale row in id-map.tsv for a post it just
#      deleted — see lib/graft.sh's own header comment on both functions).
#   2. graft_prune_previous_run calling it.
#   3. The real, end-to-end acceptance criterion: interrupt phase_graft
#      between `prune` and `import` (as a genuine subprocess, so `set -e`
#      behaves exactly as it does for a real operator), resume against the
#      SAME run directory, and prove prune's own wp-cli call ran again —
#      then prove the fix is load-bearing by reverting it and watching the
#      same test go red (done by hand for the PR, not asserted here).
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/backup.sh'
  load '../../lib/graft.sh'
}

# --- graft_reset_id_map_log --------------------------------------------------

@test "graft_reset_id_map_log removes B's mapping log on a bare-local site" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  mkdir -p "$wp_content"
  printf '101\t5001\tpage\n' > "${wp_content}/sitegraft-id-map.log"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  graft_reset_id_map_log
  [ ! -e "${wp_content}/sitegraft-id-map.log" ]
}

@test "graft_reset_id_map_log is a harmless no-op when there is nothing to remove yet (first-ever run)" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  mkdir -p "$wp_content"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  run graft_reset_id_map_log
  [ "$status" -eq 0 ]
}

@test "graft_reset_id_map_log routes through ssh (not a local rm) when SITE_B_SSH_HOST is set" {
  SITE_B_WP_PATH="/remote/site-b"
  SITE_B_SSH_HOST="b.example.com"
  ssh() { echo "ssh called with: $*"; }
  run graft_reset_id_map_log
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh called with: -- b.example.com"* ]] || false
  [[ "$output" == *"rm -f"* ]] || false
  [[ "$output" == *"sitegraft-id-map.log"* ]] || false
}

@test "graft_reset_id_map_log does not touch anything under --dry-run" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  mkdir -p "$wp_content"
  printf '101\t5001\tpage\n' > "${wp_content}/sitegraft-id-map.log"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  SITEGRAFT_DRY_RUN=1 graft_reset_id_map_log
  [ -f "${wp_content}/sitegraft-id-map.log" ]
}

# --- graft_prune_previous_run calls the reset -------------------------------

@test "graft_prune_previous_run resets B's mapping log before querying/deleting anything" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  mkdir -p "$wp_content"
  printf '101\t5001\tpage\n' > "${wp_content}/sitegraft-id-map.log"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  wp_remote() { :; } # no leftover posts to prune
  graft_prune_previous_run "page,post"
  [ ! -e "${wp_content}/sitegraft-id-map.log" ]
}

@test "graft_prune_previous_run resets the log even when it goes on to find and delete leftover posts" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  mkdir -p "$wp_content"
  printf '101\t5001\tpage\n' > "${wp_content}/sitegraft-id-map.log"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  SITEGRAFT_DRY_RUN=1
  wp_remote() {
    local alias_lc="$1"; shift
    if [ "$1" = "post" ] && [ "$2" = "list" ]; then
      printf '5001\n'
    else
      echo "[dry-run] wp_remote $alias_lc $*"
    fi
  }
  run graft_prune_previous_run "page,post"
  [[ "$output" == *"post delete 5001"* ]] || false
  # dry-run: the real log file (written outside run_or_echo) is untouched,
  # since the reset itself is wrapped in run_or_echo the same way.
  [ -f "${wp_content}/sitegraft-id-map.log" ]
}

@test "graft_prune_previous_run still no-ops entirely (log included) when post_types_csv is empty" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  mkdir -p "$wp_content"
  printf '101\t5001\tpage\n' > "${wp_content}/sitegraft-id-map.log"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  wp_remote() { echo "SHOULD NOT BE CALLED"; }
  run graft_prune_previous_run ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Unclaimed by this call (post_types_csv empty means "nothing migrated,
  # nothing to prune" — the log reset is part of prune's own job, not a
  # separate unconditional side effect).
  [ -f "${wp_content}/sitegraft-id-map.log" ]
}

# --- graft_prune_previous_run also strips run_dir/id-map.tsv (MAJOR-2) -----
#
# graft_reset_id_map_log (above) only ever clears B's own cumulative log —
# it never touched ${run_dir}/id-map.tsv, the file graft_fetch_id_map has
# already appended INTO on any earlier pass through this run_dir. Without
# this, a prune rerun deletes the posts a stale row points at, on B, while
# the row itself survives in id-map.tsv — graft_verify_import_completeness
# would then read that stale row back as "already landed" for an old_id B
# no longer has anything for, passing a gate it exists to fail.

@test "graft_prune_previous_run strips non-attachment rows from run_dir/id-map.tsv, keeping attachment rows" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$wp_content" "$run_dir"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  wp_remote() { :; }
  printf '101\t5001\tpage\n7\t42\tattachment\n200\t9\tterm:category\n' > "${run_dir}/id-map.tsv"
  graft_prune_previous_run "page" "$run_dir"
  [ "$(cat "${run_dir}/id-map.tsv")" = "7	42	attachment" ]
}

@test "graft_prune_previous_run leaves a run_dir id-map.tsv holding ONLY attachment rows genuinely empty, not one blank line" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$wp_content" "$run_dir"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  wp_remote() { :; }
  printf '101\t5001\tpage\n200\t9\tterm:category\n' > "${run_dir}/id-map.tsv"
  graft_prune_previous_run "page" "$run_dir"
  [ ! -s "${run_dir}/id-map.tsv" ]
}

@test "graft_prune_previous_run does not touch run_dir/id-map.tsv under --dry-run" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$wp_content" "$run_dir"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  SITEGRAFT_DRY_RUN=1
  wp_remote() { :; }
  printf '101\t5001\tpage\n' > "${run_dir}/id-map.tsv"
  graft_prune_previous_run "page" "$run_dir"
  [ "$(cat "${run_dir}/id-map.tsv")" = "101	5001	page" ]
}

@test "graft_prune_previous_run is unaffected by a run_dir with no id-map.tsv yet (first-ever run)" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$wp_content" "$run_dir"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  wp_remote() { :; }
  run graft_prune_previous_run "page" "$run_dir"
  [ "$status" -eq 0 ]
  [ ! -e "${run_dir}/id-map.tsv" ]
}

@test "graft_prune_previous_run called with no run_dir argument at all still works (every pre-existing caller/test)" {
  local wp_content="$BATS_TEST_TMPDIR/site-b/wp-content"
  mkdir -p "$wp_content"
  SITE_B_WP_PATH="$BATS_TEST_TMPDIR/site-b"
  unset SITE_B_SSH_HOST
  wp_remote() { :; }
  run graft_prune_previous_run "page"
  [ "$status" -eq 0 ]
}

# --- end-to-end acceptance criterion: real subprocess, real `set -e` -------
#
# A fake `wp` executable stands in for wp-cli end to end (both A and B are
# plain bare-local paths, no SSH, no DDEV-style wrapper — wp_remote's own
# non-ssh branch execs $SITE_*_WP_CMD directly, so pointing SITE_A_WP_CMD/
# SITE_B_WP_CMD at this script gives full, real control over every wp-cli
# call `bin/sitegraft graft` makes, without needing a real WordPress at
# all). It logs every invocation (so the test can count exactly how many
# times prune's own `post list` call ran) and ALWAYS fails the `import`
# subcommand — deliberately: this test only needs to prove that a SECOND
# `sitegraft graft` invocation against the SAME run directory re-attempts
# `prune` before re-attempting `import`, which is fully observable from the
# call log alone; it does not need a full successful graft (the general
# machinery well past `import` — remap/options/module hooks — has its own
# existing, separate test coverage elsewhere in this suite).
_write_fake_wp() {
  local path="$1"
  cat > "$path" <<'FAKEWP'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WP_FAKE_CALL_LOG"
sub=""
for a in "$@"; do
  case "$a" in
    plugin|post|export|import|eval) sub="$a" ;;
  esac
done
case "$sub" in
  plugin) exit 0 ;;   # is-installed / is-active -- always "yes"
  post) exit 0 ;;     # post list -- prints nothing (no leftovers); still logged above
  eval) echo '[]' ;;  # attachment-metadata collection (graft_import_attachments, BEFORE import): "A has no attachments" -- keeps that step a clean no-op so this test reaches the import step it actually cares about
  export)
    dir=""
    for a in "$@"; do
      case "$a" in --dir=*) dir="${a#--dir=}" ;; esac
    done
    mkdir -p "$dir"
    # issue #72: xmlns:wp declared (an earlier version of this fixture
    # omitted it, harmless against the awk/grep-based readers this
    # codebase used to have, but graft_integrity_gate now parses this
    # file through the same namespace-aware structural driver
    # graft_verify_import_completeness uses -- an undeclared "wp" prefix
    # resolves to no namespace at all, and neither post_id nor post_type
    # would be recognized).
    cat > "${dir}/export.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item>
</channel></rss>
XML
    exit 0
    ;;
  import)
    echo "simulated interruption mid-import" >&2
    exit 1
    ;;
  *) exit 0 ;;
esac
FAKEWP
  chmod +x "$path"
}

@test "issue #54 acceptance: a resume re-attempts prune before re-attempting import, instead of trusting prune's stale marker" {
  local sitegraft_bin="${BATS_TEST_DIRNAME}/../../bin/sitegraft"
  local fake_wp="$BATS_TEST_TMPDIR/fake-wp"
  _write_fake_wp "$fake_wp"

  export WP_FAKE_CALL_LOG="$BATS_TEST_TMPDIR/wp-calls.log"
  : > "$WP_FAKE_CALL_LOG"

  local site_a="$BATS_TEST_TMPDIR/site-a" site_b="$BATS_TEST_TMPDIR/site-b"
  mkdir -p "${site_a}/wp-content/uploads" "${site_b}/wp-content/uploads" "${site_b}/wp-content/mu-plugins"

  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  mkdir -p "$SITEGRAFT_PROFILES_DIR"
  cat > "${SITEGRAFT_PROFILES_DIR}/demo.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="${site_a}"
SITE_A_WP_CMD="${fake_wp}"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="${site_b}"
SITE_B_WP_CMD="${fake_wp}"
SITEGRAFT_STATE_DIR="${BATS_TEST_TMPDIR}/state"
EOF
  mkdir -p "${BATS_TEST_TMPDIR}/state"

  local run_dir="${BATS_TEST_TMPDIR}/state/demo-20260101T000000"
  mkdir -p "$run_dir"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "${run_dir}/scan-a.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "${run_dir}/scan-b.json"
  cat > "${run_dir}/manifest.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}
EOF
  touch "${run_dir}/backup.complete"

  # Isolate module discovery: real core-wp.sh/etch.sh modules are never
  # reached in this test (both invocations die at `import`, well before
  # module_hooks), but pointing at an empty dir keeps this test's fixture
  # self-contained rather than depending on this repo's real modules/.
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/empty-modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"

  # --- first invocation: prune runs (nothing to prune), import is attempted
  # and "interrupted" (the fake wp always fails it) -- a REAL subprocess,
  # so bin/sitegraft's own `set -e` aborts phase_graft right there, exactly
  # like a real operator's run. ---
  run "$sitegraft_bin" graft --profile demo --run "$run_dir"
  [ "$status" -ne 0 ]

  local prune_calls_pass1 import_calls_pass1
  prune_calls_pass1=$(grep -c -- '--meta_key=_sitegraft_source_id' "$WP_FAKE_CALL_LOG" || true)
  import_calls_pass1=$(grep -c -- '--skip=attachment' "$WP_FAKE_CALL_LOG" || true)
  [ "$prune_calls_pass1" -eq 1 ]
  [ "$import_calls_pass1" -eq 1 ]
  [ -f "${run_dir}/graft.prune.done" ]
  [ ! -f "${run_dir}/graft.import.done" ]

  # --- resume: SAME run_dir, prune's own marker is still sitting there
  # from pass 1. Before issue #54's fix, `graft_step_done "$run_dir" prune`
  # alone gated this step -- true here -- so prune would be skipped
  # entirely and only import would be re-attempted. ---
  run "$sitegraft_bin" graft --profile demo --run "$run_dir"
  [ "$status" -ne 0 ]

  local prune_calls_pass2 import_calls_pass2
  prune_calls_pass2=$(grep -c -- '--meta_key=_sitegraft_source_id' "$WP_FAKE_CALL_LOG" || true)
  import_calls_pass2=$(grep -c -- '--skip=attachment' "$WP_FAKE_CALL_LOG" || true)

  # The acceptance criterion itself: prune's own wp-cli call ran a SECOND
  # time. Under the pre-fix code this stays at 1 (only import_calls grows) --
  # reverting lib/graft.sh's graft_safety_step_done wiring for the prune
  # step (back to a plain `graft_step_done "$run_dir" prune || {...}`) and
  # re-running this exact test reproduces that failure, proving this
  # assertion is load-bearing rather than vacuously true.
  [ "$prune_calls_pass2" -eq 2 ]
  [ "$import_calls_pass2" -eq 2 ]

  # Ordering: prune's call must appear BEFORE the second import attempt in
  # the log, i.e. it genuinely ran again ahead of the re-attempt, not as
  # some unrelated leftover call.
  local prune_line_2 import_line_2
  prune_line_2=$(grep -n -- '--meta_key=_sitegraft_source_id' "$WP_FAKE_CALL_LOG" | sed -n '2p' | cut -d: -f1)
  import_line_2=$(grep -n -- '--skip=attachment' "$WP_FAKE_CALL_LOG" | sed -n '2p' | cut -d: -f1)
  [ "$prune_line_2" -lt "$import_line_2" ]
}

# --- BLOCKER-1/BLOCKER-2 acceptance: a real `sitegraft graft` run, real
# `wp import` SUCCESS, one item silently skipped ---------------------------
#
# The two review blockers in this fix-pack were both about
# graft_verify_import_completeness misreading the WXR it parses -- neither
# is reachable through a fixture where `import` always fails (the existing
# issue #54 acceptance test above never reaches this gate at all). This
# fixture instead lets `import` SUCCEED while simulating exactly what
# wordpress-importer 0.9.5 really does on a title/date/type collision
# (issue #53's own defect): only ONE of two staged items gets a
# wp_import_insert_post-sourced row in B's mapping log. The staged WXR
# itself uses the BLOCKER-2 shape (an item's own wp:post_id/wp:post_type
# sharing one physical line) so this is also the real end-to-end proof that
# the gate reports the correct "1 of 2" / "page#102", by real post_id and
# post_type, never a garbled XML fragment -- the previous awk-based scan's
# exact failure mode on this shape.
_write_fake_wp_success_with_skip() {
  local path="$1"
  cat > "$path" <<'FAKEWP'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WP_FAKE_CALL_LOG"
wp_path=""
for a in "$@"; do
  case "$a" in --path=*) wp_path="${a#--path=}" ;; esac
done
sub=""
for a in "$@"; do
  case "$a" in
    plugin|post|export|import|eval) sub="$a" ;;
  esac
done
case "$sub" in
  plugin) exit 0 ;;   # is-installed / is-active -- always "yes"
  post) exit 0 ;;     # post list -- prints nothing (no leftovers)
  eval) echo '[]' ;;  # attachment-metadata collection: "A has no attachments"
  export)
    dir=""
    for a in "$@"; do
      case "$a" in --dir=*) dir="${a#--dir=}" ;; esac
    done
    mkdir -p "$dir"
    # BLOCKER-2 shape: each item's own wp:post_id/wp:post_type share one
    # physical line. Two items: 101 and 102.
    cat > "${dir}/export.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version>
<item>
<wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type>
</item>
<item>
<wp:post_id>102</wp:post_id><wp:post_type>page</wp:post_type>
</item>
</channel></rss>
XML
    exit 0
    ;;
  import)
    # SUCCEEDS overall (exit 0, matching a real wordpress-importer run that
    # completes without a fatal error) but simulates issue #53's real
    # defect directly: only 101 fires wp_import_insert_post and gets a
    # mu-plugin log row -- 102 is silently "already exists". There is no
    # real WP/mu-plugin in this fixture, so the row is written here,
    # exactly what mu-plugins/sitegraft-id-mapper.php's own hook would have
    # written for a real insert.
    mkdir -p "${wp_path}/wp-content"
    printf '101\t5001\tpage\n' >> "${wp_path}/wp-content/sitegraft-id-map.log"
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKEWP
  chmod +x "$path"
}

@test "BLOCKER-1/BLOCKER-2 acceptance: a real graft run reports the true '1 of 2'/page#102, and a resume actually retries" {
  local sitegraft_bin="${BATS_TEST_DIRNAME}/../../bin/sitegraft"
  local fake_wp="$BATS_TEST_TMPDIR/fake-wp"
  _write_fake_wp_success_with_skip "$fake_wp"

  export WP_FAKE_CALL_LOG="$BATS_TEST_TMPDIR/wp-calls.log"
  : > "$WP_FAKE_CALL_LOG"

  local site_a="$BATS_TEST_TMPDIR/site-a" site_b="$BATS_TEST_TMPDIR/site-b"
  mkdir -p "${site_a}/wp-content/uploads" "${site_b}/wp-content/uploads" "${site_b}/wp-content/mu-plugins"

  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  mkdir -p "$SITEGRAFT_PROFILES_DIR"
  cat > "${SITEGRAFT_PROFILES_DIR}/demo.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="${site_a}"
SITE_A_WP_CMD="${fake_wp}"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="${site_b}"
SITE_B_WP_CMD="${fake_wp}"
SITEGRAFT_STATE_DIR="${BATS_TEST_TMPDIR}/state"
EOF
  mkdir -p "${BATS_TEST_TMPDIR}/state"

  local run_dir="${BATS_TEST_TMPDIR}/state/demo-20260101T000000"
  mkdir -p "$run_dir"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "${run_dir}/scan-a.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "${run_dir}/scan-b.json"
  cat > "${run_dir}/manifest.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}
EOF
  touch "${run_dir}/backup.complete"

  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/empty-modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"

  # --- pass 1: a REAL import that succeeds, silently skipping 102. ---
  run "$sitegraft_bin" graft --profile demo --run "$run_dir"
  [ "$status" -eq 1 ]

  # The acceptance criterion itself: the real, structurally-parsed count
  # and name, not a garbled XML fragment (BLOCKER-1/BLOCKER-2).
  [[ "$output" == *"1 of 2"* ]] || false
  [[ "$output" == *"page#102"* ]] || false
  [[ "$output" != *"<item>"* ]] || false
  [[ "$output" != *"<wp:"* ]] || false

  # MAJOR-3: the failure names B's real state and says a repeat WILL retry.
  [[ "$output" == *"partially migrated"* ]] || false
  [[ "$output" == *"WILL retry"* ]] || false

  # MAJOR-2/MAJOR-3: the markers a retry depends on are cleared...
  [ ! -f "${run_dir}/graft.import_attachments.done" ]
  [ ! -f "${run_dir}/graft.import.done" ]
  [ ! -f "${run_dir}/graft.fetch_id_map.done" ]
  # Issue #36: graft.media_sync.done is cleared here too now, alongside the
  # three above -- prune's own `wp post delete --force` deletes an
  # attachment's underlying FILE, and a retry from this exact point reruns
  # prune first (see the reasoning below), which can delete files an
  # earlier media_sync pass already placed. media_sync must rerun after it
  # to put them back before import_attachments retries -- see
  # phase_graft's own comment on this rm -f (lib/graft.sh) for the full
  # mechanism. This fixture's A never has any attachments (`echo '[]'`), so
  # media_sync's rerun is a harmless no-op here either way; the marker
  # itself is still the right thing to assert on, since a future fixture
  # WITH real attachments depends on exactly this clearing.
  [ ! -f "${run_dir}/graft.media_sync.done" ]
  # ...but the steps that already ran correctly and don't need to redo
  # their (expensive) work are left alone.
  [ -f "${run_dir}/graft.stack_sync.done" ]
  [ -f "${run_dir}/graft.prune.done" ]
  [ -f "${run_dir}/graft.importer_setup.done" ]
  [ -f "${run_dir}/graft.export.done" ]

  # Only 101's row is on record after pass 1 -- 102 was never inserted.
  [ "$(cat "${run_dir}/id-map.tsv")" = "101	5001	page" ]

  local prune_calls_pass1 import_calls_pass1
  prune_calls_pass1=$(grep -c -- '--meta_key=_sitegraft_source_id' "$WP_FAKE_CALL_LOG" || true)
  import_calls_pass1=$(grep -c -- '--skip=attachment' "$WP_FAKE_CALL_LOG" || true)
  [ "$prune_calls_pass1" -eq 1 ]
  [ "$import_calls_pass1" -eq 1 ]

  # --- pass 2: a resume against the SAME run directory. The message
  # promised this WOULD retry -- prove it does, not merely that the
  # markers changed. ---
  run "$sitegraft_bin" graft --profile demo --run "$run_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2"* ]] || false
  [[ "$output" == *"page#102"* ]] || false

  local prune_calls_pass2 import_calls_pass2
  prune_calls_pass2=$(grep -c -- '--meta_key=_sitegraft_source_id' "$WP_FAKE_CALL_LOG" || true)
  import_calls_pass2=$(grep -c -- '--skip=attachment' "$WP_FAKE_CALL_LOG" || true)
  [ "$prune_calls_pass2" -eq 2 ]
  [ "$import_calls_pass2" -eq 2 ]

  # MAJOR-2: id-map.tsv holds exactly ONE fresh "101" row after pass 2, not
  # two (which a stale, un-stripped row from pass 1 would have produced,
  # or which would have masked prune's own log reset on B never having run
  # again).
  [ "$(cat "${run_dir}/id-map.tsv")" = "101	5001	page" ]
  [ "$(grep -c '^101' "${run_dir}/id-map.tsv")" -eq 1 ]
}

# --- BLOCKER-A acceptance (review, issue #70 -- FIXED on a separate branch,
# PR #71, merged and rebased onto here). Same real-subprocess shape as the
# BLOCKER-1/BLOCKER-2 acceptance test above, changing ONLY the staged
# WXR's own layout: the two items are direct siblings with NO whitespace/
# text node between `</item>` and the next `<item>` -- the exact shape
# lib/php/wxr-content-functions.php's streaming reader used to silently
# drop the second of (see lib/php/wxr-item-ids-cli.php's own header for
# the fuller history). This test went green on its own the moment #71
# landed -- kept exactly as originally written, as its own regression
# guard. It was also, briefly, red for an UNRELATED reason after that
# rebase: graft_integrity_gate (lib/graft.sh) ran its own separate,
# greedy `grep -o | sed` scan of the same WXR and mis-parsed this exact
# adjacent-<item> shape as a leaked post_type, aborting the graft before
# this test's own completeness gate ever ran -- issue #72, fixed by
# pointing that function at the same shared driver this file's own
# fixture already exercises; see graft_integrity_gate's own comment and
# tests/unit/test_graft_integrity_gate.bats for that fix's own coverage.
_write_fake_wp_success_with_skip_no_whitespace() {
  local path="$1"
  cat > "$path" <<'FAKEWP'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WP_FAKE_CALL_LOG"
wp_path=""
for a in "$@"; do
  case "$a" in --path=*) wp_path="${a#--path=}" ;; esac
done
sub=""
for a in "$@"; do
  case "$a" in
    plugin|post|export|import|eval) sub="$a" ;;
  esac
done
case "$sub" in
  plugin) exit 0 ;;
  post) exit 0 ;;
  eval) echo '[]' ;;
  export)
    dir=""
    for a in "$@"; do
      case "$a" in --dir=*) dir="${a#--dir=}" ;; esac
    done
    mkdir -p "$dir"
    # BLOCKER-A shape: two sibling <item>s with ZERO whitespace between
    # `</item>` and the next `<item>` -- issue #70.
    cat > "${dir}/export.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
  xmlns:content="http://purl.org/rss/1.0/modules/content/"
  xmlns:wp="http://wordpress.org/export/1.2/">
<channel><wp:wxr_version>1.2</wp:wxr_version><item><wp:post_id>101</wp:post_id><wp:post_type>page</wp:post_type></item><item><wp:post_id>102</wp:post_id><wp:post_type>page</wp:post_type></item></channel></rss>
XML
    exit 0
    ;;
  import)
    mkdir -p "${wp_path}/wp-content"
    printf '101\t5001\tpage\n' >> "${wp_path}/wp-content/sitegraft-id-map.log"
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKEWP
  chmod +x "$path"
}

@test "BLOCKER-A acceptance: a real graft run catches a skip on a whitespace-less sibling <item> (issue #70)" {
  local sitegraft_bin="${BATS_TEST_DIRNAME}/../../bin/sitegraft"
  local fake_wp="$BATS_TEST_TMPDIR/fake-wp"
  _write_fake_wp_success_with_skip_no_whitespace "$fake_wp"

  export WP_FAKE_CALL_LOG="$BATS_TEST_TMPDIR/wp-calls.log"
  : > "$WP_FAKE_CALL_LOG"

  local site_a="$BATS_TEST_TMPDIR/site-a" site_b="$BATS_TEST_TMPDIR/site-b"
  mkdir -p "${site_a}/wp-content/uploads" "${site_b}/wp-content/uploads" "${site_b}/wp-content/mu-plugins"

  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  mkdir -p "$SITEGRAFT_PROFILES_DIR"
  cat > "${SITEGRAFT_PROFILES_DIR}/demo.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="${site_a}"
SITE_A_WP_CMD="${fake_wp}"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="${site_b}"
SITE_B_WP_CMD="${fake_wp}"
SITEGRAFT_STATE_DIR="${BATS_TEST_TMPDIR}/state"
EOF
  mkdir -p "${BATS_TEST_TMPDIR}/state"

  local run_dir="${BATS_TEST_TMPDIR}/state/demo-20260101T000000"
  mkdir -p "$run_dir"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "${run_dir}/scan-a.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "${run_dir}/scan-b.json"
  cat > "${run_dir}/manifest.json" <<'EOF'
{"migrate":{"core-wp":{"post_types":["page"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}
EOF
  touch "${run_dir}/backup.complete"

  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/empty-modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"

  run "$sitegraft_bin" graft --profile demo --run "$run_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2"* ]] || false
  [[ "$output" == *"page#102"* ]] || false
}

# --- issue #36 acceptance: media_sync used to run before prune -------------
#
# graft_media_sync pushes A's uploads onto B with rsync --ignore-existing
# (never overwrite a file already there). graft_prune_previous_run's own
# `wp post delete --force` on a previously-migrated attachment deletes that
# attachment's underlying FILE as a side effect of deleting the post
# (verified live on a disposable site -- see the GitHub issue's own DDEV
# reproduction). With media_sync running BEFORE prune, a second graft
# against a target that already carries a first graft's attachments was
# silently destructive: media_sync saw the file already present and skipped
# it, prune then deleted it for real, and import_attachments found nothing
# left on disk to register. lib/graft.sh now runs prune, then media_sync,
# then import_attachments (see phase_graft's own comment on graft_media_sync's
# old and new call sites) -- proven at the wiring level by
# tests/unit/test_graft_phase_wiring.bats's own issue #36 test. This is the
# issue's own acceptance criterion instead: grafting TWICE onto the same
# target leaves B's media intact, covering the SECOND run, not just the
# first.
#
# phase_graft itself is exercised directly (not via bin/sitegraft), same
# convention as this file's other phase_graft-level tests and
# tests/unit/test_graft_phase_wiring.bats's MAJOR-4/issue #16 tests -- every
# step BUT graft_prune_previous_run, graft_media_sync and
# graft_import_attachments is stubbed out, so what runs for real is exactly
# the three functions issue #36 is about, driven by phase_graft's own
# production wiring, against a REAL uploads directory on a REAL filesystem
# (graft_media_sync's rsync is not mocked). wp_remote is stubbed at the two
# points that would otherwise need a real WordPress -- A's/B's attachment
# metadata, and B's post list/delete for pruning -- but the post-delete stub
# performs the one side effect this whole issue is about: deleting the
# underlying file, exactly like a live `wp post delete --force` on an
# attachment does. Everything downstream of "is the file present when
# import needs it" (rsync placing it, the batch's file_exists-shaped
# fail-closed report, graft_import_attachments' own accounting/refusal
# logic) is the real, unmodified code.
_issue36_stub_everything_but_prune_media_sync_import_attachments() {
  # profile_load is deliberately NOT stubbed here -- the caller defines its
  # own right after calling this helper, since it needs to close over
  # site_a/site_b (declared local in the @test body).
  modules_discover() { SITEGRAFT_MODULES=""; }
  graft_sync_stack() { :; }
  graft_check_stack_precondition() { return 0; }
  graft_deploy_mu_plugin() { :; }
  graft_migrate_post_type_defining_options() { :; }
  graft_ensure_importer() { :; }
  graft_export_wxr() { :; }
  graft_integrity_gate() { return 0; }
  graft_import_wxr() { :; }
  graft_fetch_id_map() { :; }
  graft_verify_import_completeness() { return 0; }
  graft_remove_mu_plugin() { :; }
  graft_restore_importer_state() { :; }
  graft_remap_attachment_ids() { :; }
  graft_remap_featured_images() { :; }
  graft_search_replace_domain() { :; }
  graft_migrate_options() { :; }
  graft_run_module_post_import() { :; }
  graft_push_remap_payload() { echo "/fake/remote/payload.json"; }
  graft_push_media_import_lib() { echo "/fake/remote/lib.php"; }
  graft_remove_file() { :; }
}

@test "issue #36 acceptance: grafting twice onto the same target leaves B's media intact (covers the SECOND run)" {
  local site_a="$BATS_TEST_TMPDIR/site-a" site_b="$BATS_TEST_TMPDIR/site-b"
  mkdir -p "${site_a}/wp-content/uploads" "${site_b}/wp-content/uploads"
  printf 'fixture bytes, not a real jpg' > "${site_a}/wp-content/uploads/probe.jpg"
  local probe_on_b="${site_b}/wp-content/uploads/probe.jpg"

  unset SITEGRAFT_DRY_RUN

  # B's own state, independent of any run_dir -- exactly what a real B's
  # post table would be queryable by _sitegraft_source_id for, across two
  # entirely separate `sitegraft graft` invocations against it. Starts
  # empty: B has never seen this attachment yet.
  local prune_ids_file="$BATS_TEST_TMPDIR/b-attachment-ids"
  : > "$prune_ids_file"

  _issue36_stub_everything_but_prune_media_sync_import_attachments
  profile_load() {
    SITE_A_ALIAS=a; SITE_B_ALIAS=b
    SITE_A_WP_PATH="$site_a"; SITE_B_WP_PATH="$site_b"
    unset SITE_A_SSH_HOST SITE_B_SSH_HOST SITE_A_WP_CMD SITE_B_WP_CMD
    return 0
  }

  # The one wp-cli surface graft_prune_previous_run/graft_import_attachments
  # need -- see this test's own header comment above for what each branch
  # reproduces and why.
  wp_remote() {
    local alias_lc="$1"; shift
    case "$1" in
      eval)
        if [ "$alias_lc" = "a" ]; then
          echo '[{"old":10,"rel_path":"probe.jpg","title":"Probe"}]'
        elif [ -f "$probe_on_b" ]; then
          echo '{"ok":true,"requested":1,"accounted_for":1,"imported":[10],"already_present":[],"no_local_file":[],"failed":[],"map":{"10":100}}'
        else
          echo '{"ok":true,"requested":1,"accounted_for":1,"imported":[],"already_present":[],"no_local_file":[],"failed":[{"old":10,"error":"file not found on B"}],"map":{}}'
        fi
        ;;
      post)
        case "$2" in
          list) cat "$prune_ids_file" 2>/dev/null || true ;;
          delete)
            local id="$3"
            grep -vxF "$id" "$prune_ids_file" > "${prune_ids_file}.tmp" 2>/dev/null || : > "${prune_ids_file}.tmp"
            mv "${prune_ids_file}.tmp" "$prune_ids_file"
            # The load-bearing side effect this whole issue is about: a
            # real `wp post delete --force` on an attachment deletes the
            # underlying file too.
            rm -f "$probe_on_b"
            echo "post delete ${id} --force"
            ;;
        esac
        ;;
    esac
  }

  local manifest='{"migrate":{"core-wp":{"post_types":["attachment"],"option_keys":[]}},"clean":{"enabled":false,"post_types":[]},"options":{"search_replace":{"from":"","to":""}}}'

  # --- first graft: B starts empty, prune has nothing to do, media lands,
  # attachment imports for the first time. ---
  local run_dir_1="$BATS_TEST_TMPDIR/run1"
  mkdir -p "$run_dir_1"
  touch "${run_dir_1}/backup.complete"
  printf '%s' "$manifest" > "${run_dir_1}/manifest.json"
  # export/import (WXR content, unrelated to this test) pre-marked done so
  # phase_graft's real "did export produce an .xml" check is never reached
  # -- graft_export_wxr/graft_import_wxr are stubbed no-ops above, and this
  # test needs a REAL (non-dry-run) pass for prune/media_sync/import_attachments'
  # own side effects, so --dry-run is not an option here the way the
  # sibling wiring test uses it.
  touch "${run_dir_1}/graft.export.done" "${run_dir_1}/graft.import.done"

  run phase_graft --profile demo --run "$run_dir_1"
  [ "$status" -eq 0 ]
  [ -f "$probe_on_b" ]
  [[ "$output" != *"post delete"* ]] || false
  [[ "$output" == *"1 newly imported"* ]] || false
  [ -s "${run_dir_1}/id-map.tsv" ]

  # B now "has" this attachment (old id 10 -> new id 100, exactly what pass
  # 1's own canned batch result reported) -- feed pass 2's prune query from
  # it, the same way a real B's post table would answer it.
  printf '100\n' > "$prune_ids_file"

  # --- second graft against the SAME target: the acceptance criterion.
  # A fresh run_dir (a real iterative regraft is scan -> plan -> backup ->
  # graft again, not a resume of run_dir_1), but the SAME site_a/site_b --
  # prune deletes B's post from pass 1 AND its file (reproducing the
  # issue's exact mechanism); with the fix, media_sync then re-places the
  # file before import_attachments needs it. ---
  local run_dir_2="$BATS_TEST_TMPDIR/run2"
  mkdir -p "$run_dir_2"
  touch "${run_dir_2}/backup.complete"
  printf '%s' "$manifest" > "${run_dir_2}/manifest.json"
  touch "${run_dir_2}/graft.export.done" "${run_dir_2}/graft.import.done"

  run phase_graft --profile demo --run "$run_dir_2"
  # NOT a discriminating assertion on its own (verified by hand for this
  # fix-pack, both directions): under the pre-fix ordering this still
  # reads 0. phase_graft is called directly here, not via bin/sitegraft,
  # and bats' `run` disables errexit for the command it captures -- so
  # even though graft_import_attachments' real `return 1` (on the
  # pre-fix ordering, once media_sync has skipped the file and prune has
  # deleted it) is a genuine, load-bearing fail-closed return in
  # production (bin/sitegraft's own `set -euo pipefail` aborts the whole
  # script right there -- confirmed separately with a standalone
  # `env bash -c 'set -euo pipefail; false || { f; echo marked; }'`,
  # which exits 1), THIS test's own `run phase_graft ...` swallows it:
  # execution continues past the point that would have aborted a real
  # `sitegraft graft` invocation, `graft_mark_step` still runs, and
  # phase_graft finishes and returns 0, logging "graft complete" right
  # after having logged "failed to import 1 of 1 attachment(s)". Kept as
  # a sanity check on the FIXED behavior (pass 2 really does succeed
  # cleanly), not as evidence of anything about the bug -- that's the two
  # assertions below.
  [ "$status" -eq 0 ]
  [[ "$output" == *"post delete 100 --force"* ]] || false

  # The acceptance criterion itself, and the ONLY two assertions in this
  # test actually verified (by hand, both directions) to discriminate the
  # fix: B still has the file after the SECOND graft, and the batch
  # genuinely imported it rather than reporting it failed. Under the
  # pre-fix ordering (media_sync before prune), prune's delete above is
  # the LAST thing that ever touches this file -- media_sync already ran
  # and skipped it (already existed on disk at that point) -- so it stays
  # gone and the batch reports "0 newly imported ... 1 failed" instead;
  # reverting lib/graft.sh's reordering and re-running this test
  # reproduces exactly that (mutation-tested for this fix-pack).
  [ -f "$probe_on_b" ]
  [[ "$output" == *"1 newly imported"* ]] || false
}
