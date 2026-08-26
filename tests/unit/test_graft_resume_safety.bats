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
    cat > "${dir}/export.xml" <<'XML'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
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
