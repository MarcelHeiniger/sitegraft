#!/usr/bin/env bash
# tests/integration/ddev-harness.sh — the real safety proof of sitegraft.
# Grows incrementally as each phase lands (design doc §10, review finding C1).
# Spins up two disposable DDEV sites, seeds fixtures, and tears down unconditionally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_A="sitegraft-test-a"
PROJECT_B="sitegraft-test-b"

cleanup() {
  ddev delete -Oy "$PROJECT_A" >/dev/null 2>&1 || true
  ddev delete -Oy "$PROJECT_B" >/dev/null 2>&1 || true
  # Found live while iterating on Step 4 (not present before): `ddev delete`
  # only tears down the DDEV project registration/containers, never the host
  # directory it was configured from — a re-run of this harness against a
  # leftover /tmp/sitegraft-test-a/b (still containing a full WordPress
  # install) fails immediately at `wp core download` with "WordPress files
  # seem to already be present here." Nothing here depends on these
  # directories surviving a run, so wiping them is safe and keeps the
  # harness genuinely idempotent/rerunnable.
  rm -rf "/tmp/${PROJECT_A}" "/tmp/${PROJECT_B}"
  # m7: this harness-generated profile (real project names, gitignored) was
  # never removed — left behind after every run instead of being test-only
  # scratch state.
  rm -f "${ROOT}/profiles/ddev-test.conf"
  # Same tidiness for the bare-local deletion-semantics check's own scratch
  # dir (unset until that block runs, hence the guard).
  [ -n "${BARE_TEST_DIR:-}" ] && rm -rf "${BARE_TEST_DIR}"
  true
}
trap cleanup EXIT

echo "==> starting disposable DDEV sites"
( mkdir -p "/tmp/${PROJECT_A}" && cd "/tmp/${PROJECT_A}" && ddev config --project-name="$PROJECT_A" --project-type=wordpress --docroot=. && ddev start && ddev wp core download && ddev wp core install --url=https://a.example.com --title=A --admin_user=admin --admin_password=admin --admin_email=admin@example.com )
( mkdir -p "/tmp/${PROJECT_B}" && cd "/tmp/${PROJECT_B}" && ddev config --project-name="$PROJECT_B" --project-type=wordpress --docroot=. && ddev start && ddev wp core download && ddev wp core install --url=https://b.example.com --title=B --admin_user=admin --admin_password=admin --admin_email=admin@example.com )

echo "==> seeding fixtures"
mkdir -p "/tmp/${PROJECT_A}/wp-content/mu-plugins"
cp "${ROOT}/tests/integration/fixtures/site-a-fake-etch/fake-etch-cpts.php" "/tmp/${PROJECT_A}/wp-content/mu-plugins/fake-etch-cpts.php"
"${ROOT}/tests/integration/fixtures/site-a-seed.sh" "$PROJECT_A"
mkdir -p "/tmp/${PROJECT_B}/wp-content/mu-plugins"
cp "${ROOT}/tests/integration/fixtures/site-b-fake-plugin/fake-plugin.php" "/tmp/${PROJECT_B}/wp-content/mu-plugins/fake-plugin.php"
# Step 4 fixture: B also gets the SAME CPT-registering mu-plugin as A — this
# simulates the CPT-registration effect a real `graft_sync_stack` would have
# already had on B (copying the actual Etch plugin, which registers
# etch_cfs) BEFORE the WXR import runs. graft_sync_stack itself is exercised
# separately (tests/unit/test_graft_stack_sync.bats) — this harness has no
# real Etch plugin fixture to stack-sync, so this is the pragmatic
# equivalent for the one thing the WXR import actually needs: the target
# post_type must be a REGISTERED post_type on B, or wp-cli's importer
# rejects every post of that type outright ("Invalid post type") — found
# live, not anticipated by the plan's pseudocode.
cp "${ROOT}/tests/integration/fixtures/site-a-fake-etch/fake-etch-cpts.php" "/tmp/${PROJECT_B}/wp-content/mu-plugins/fake-etch-cpts.php"
ddev exec --raw -p "$PROJECT_B" -- wp eval 'do_action("activate_fake-plugin.php");' # dbDelta + seed via activation hook logic, invoked directly since it's an mu-plugin (no real activation event)

echo "==> asserting the site-b-fake-plugin fixture actually created its table+row"
# m8: without this, later "protected data untouched" assertions (Task
# 3.2/5.2) would be vacuously true if the fixture's activation hook ever
# silently failed to run — checked directly against B's DB, independent of
# sitegraft's own scan.
FAKE_ROW_COUNT=$(ddev exec --raw -p "$PROJECT_B" -- wp eval 'global $wpdb; echo (int) $wpdb->get_var("SELECT COUNT(*) FROM ".$wpdb->prefix."fakebooking_reservations");')
if [ "$FAKE_ROW_COUNT" -lt 1 ]; then
  echo "fake-plugin fixture did not create its row (harness bug, not a sitegraft bug) — aborting"
  exit 1
fi

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "seed" ]; then
  echo "SEED OK (SITEGRAFT_HARNESS_STOP_AFTER=seed)"
  exit 0
fi

echo "==> writing a local sitegraft profile for this harness run"
# SITE_*_WP_CMD uses "ddev exec --raw -p <project> -- wp", which runs INSIDE
# the web container regardless of the orchestrator's current directory
# (verified against a real DDEV install — "ddev --project <name> wp ..." is
# not a valid invocation in this DDEV version at all: "ddev" has no such flag
# on "wp", since "wp" only exists as a project-scoped custom command).
# --raw is required: without it, "ddev exec" re-parses the command through an
# inner shell before running it in the container, which silently mangles any
# PHP snippet containing a "$variable" (bash treats it as its own variable
# reference and expands it to empty, rather than passing it through to PHP
# literally) — verified against a real install, this is exactly what breaks
# `wp eval` calls containing PHP variables (used by inventory_custom_code_signals,
# Task 1.6). Because this command executes inside the container,
# SITE_*_WP_PATH must be the CONTAINER-internal docroot ("/var/www/html",
# DDEV's default for --docroot=.), never the orchestrator's host path —
# passing the host path here fails wp-cli's "is this a WordPress install?"
# check, since that path does not exist inside the container.
cat > "${ROOT}/profiles/ddev-test.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/html"
SITE_A_WP_CMD="ddev exec --raw -p ${PROJECT_A} -- wp"
SITE_A_URL="https://a.example.com"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/var/www/html"
SITE_B_WP_CMD="ddev exec --raw -p ${PROJECT_B} -- wp"
SITE_B_URL="https://b.example.com"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-ddev-test-runs"
EOF

echo "==> running scan"
"${ROOT}/bin/sitegraft" scan --profile ddev-test
RUN_DIR=$(ls -dt /tmp/sitegraft-ddev-test-runs/ddev-test-* | head -1)

echo "==> asserting fixtures are visible in the scan output"
jq -e '.post_types[] | select(.name=="etch_cfs")' "${RUN_DIR}/scan-a.json" >/dev/null
jq -e '.post_types[] | select(.name=="fake_reservation")' "${RUN_DIR}/scan-b.json" >/dev/null
jq -e '.classic_menus_detected == false' "${RUN_DIR}/scan-a.json" >/dev/null

echo "==> asserting m8's extra one-line coverage"
# nav_uses_dynamic_page_list (M5): the wp:page-list post seeded on A above.
jq -e '.nav_uses_dynamic_page_list == true' "${RUN_DIR}/scan-a.json" >/dev/null
# tables (design doc §12/§6.1): B's fake plugin's real table, prefix and all.
jq -e '.tables[] | select(endswith("fakebooking_reservations"))' "${RUN_DIR}/scan-b.json" >/dev/null
# custom_code_detected (§14): B's mu-plugin alone is a signal — must fire.
jq -e '.custom_code_detected == true' "${RUN_DIR}/scan-b.json" >/dev/null
# options (site-a-seed.sh): the Etch/ACSS-shaped options actually landed.
jq -e '.options[] | select(.option_name=="etch_settings")' "${RUN_DIR}/scan-a.json" >/dev/null
jq -e '.options[] | select(.option_name=="automatic_css_settings")' "${RUN_DIR}/scan-a.json" >/dev/null
# active_theme.stylesheet: both sites resolved a real active theme.
jq -e '.active_theme.stylesheet | length > 0' "${RUN_DIR}/scan-a.json" >/dev/null
jq -e '.active_theme.stylesheet | length > 0' "${RUN_DIR}/scan-b.json" >/dev/null

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "scan" ]; then
  echo "SCAN OK (SITEGRAFT_HARNESS_STOP_AFTER=scan)"
  exit 0
fi

echo "==> running plan (non-interactive: negative case first)"
# `plan` genuinely cannot be driven end-to-end with a real gum/fzf/read
# prompt here (no TTY, no gum/fzf installed on the orchestrator running this
# harness) — SITEGRAFT_MANIFEST_PREFILLED is the mechanism lib/plan.sh's
# phase_plan provides for exactly this (design doc §6.2, Task 2.3/2.4/2.5's
# commits). Negative case run first, against the same scan run, so a bug
# that made plan_custom_code_gate_check_prefilled a no-op couldn't be masked
# by the positive case's manifest.json already sitting there.
BAD_PREFILLED="${RUN_DIR}/manifest-prefilled-bad.json"
cat > "$BAD_PREFILLED" <<'EOF'
{"migrate":{},"protect":{},"clean":{"enabled":false,"post_types":[]},"options":{}}
EOF
if SITEGRAFT_MANIFEST_PREFILLED="$BAD_PREFILLED" "${ROOT}/bin/sitegraft" plan --profile ddev-test --run "$RUN_DIR"; then
  echo "plan should have REFUSED — B has a real custom-code signal (the mu-plugin fixture) and this manifest never acknowledged it — aborting"
  exit 1
fi
if [ -f "${RUN_DIR}/manifest.json" ]; then
  echo "plan wrote manifest.json despite refusing the custom-code gate — aborting"
  exit 1
fi
echo "==> confirmed: plan refuses to write a manifest when B's custom-code signal is unacknowledged (design doc §14)"

echo "==> running plan (non-interactive: positive case, real acknowledgment carried from scan-b.json)"
GOOD_PREFILLED="${RUN_DIR}/manifest-prefilled-good.json"
jq -n --argjson signals "$(jq -c '.custom_code_signals' "${RUN_DIR}/scan-b.json")" '{
  sitegraft_manifest_version: 1,
  frozen: false,
  migrate: {},
  protect: {},
  clean: {enabled: false, post_types: []},
  options: {},
  custom_code_review: {acknowledged: true, signals: $signals}
}' > "$GOOD_PREFILLED"
SITEGRAFT_MANIFEST_PREFILLED="$GOOD_PREFILLED" "${ROOT}/bin/sitegraft" plan --profile ddev-test --run "$RUN_DIR"

echo "==> asserting the frozen manifest is correct"
jq -e '.frozen == true' "${RUN_DIR}/manifest.json" >/dev/null
jq -e '.custom_code_review.acknowledged == true' "${RUN_DIR}/manifest.json" >/dev/null
# Default-deny (design doc §3.6), exercised against a REAL scan-b.json, not
# fabricated test JSON: migrate/protect were both left empty in the prefilled
# manifest above, so EVERY post_type scan found on B — including the fixture
# plugin's fake_reservation — must land in protect._unclaimed, protected by
# default, nothing silently dropped.
jq -e '.protect._unclaimed.post_types | index("fake_reservation") != null' "${RUN_DIR}/manifest.json" >/dev/null
jq -e '.protect._unclaimed.post_types | index("page") != null' "${RUN_DIR}/manifest.json" >/dev/null
MANIFEST_MODE=$(stat -c '%a' "${RUN_DIR}/manifest.json" 2>/dev/null || stat -f '%Lp' "${RUN_DIR}/manifest.json" 2>/dev/null)
[ "$MANIFEST_MODE" = "600" ] || { echo "manifest.json is not chmod 600 (got ${MANIFEST_MODE}) — aborting"; exit 1; }

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "plan" ]; then
  echo "PLAN OK (SITEGRAFT_HARNESS_STOP_AFTER=plan)"
  exit 0
fi

# MAJOR-1 regression setup (Viktor's review, confirmed live on a separate
# throwaway DDEV project before this fix): seed a known value BEFORE backup
# so the backup genuinely captures it, then mutate it AFTER backup but
# BEFORE restore (simulating drift a graft attempt could cause) — the only
# way to prove restore's db import actually re-imports data rather than
# silently succeeding on empty stdin (which is exactly what `ddev exec
# --raw` did to a piped `wp db import -` before this fix: "Success:
# Imported from 'STDIN'." on exit 0, with the DB completely untouched).
# Without a value that changes between backup and restore, checksum_after ==
# checksum_1 is true whether the import did anything or nothing — this is
# the only assertion that actually distinguishes the two.
echo "==> seeding a marker option on B for the mutate-and-revert restore proof (MAJOR-1)"
ddev exec --raw -p "$PROJECT_B" -- wp option update sitegraft_test_marker "PRE_BACKUP_VALUE" >/dev/null

echo "==> running backup"
"${ROOT}/bin/sitegraft" backup --profile ddev-test --run "$RUN_DIR"

echo "==> asserting the backup is complete and its artifacts are present"
[ -f "${RUN_DIR}/backup/b-db.sql.gz" ]
[ -d "${RUN_DIR}/backup/b-wp-content" ] && [ -n "$(ls -A "${RUN_DIR}/backup/b-wp-content")" ]
[ -x "${RUN_DIR}/restore.sh" ]
[ -f "${RUN_DIR}/backup.complete" ]
# issue #14: the manifest of what wp-content held at backup time. Without it
# the wrapped-local restore below refuses to remove anything at all, so its
# absence would turn the deletion assertions further down into a false red —
# assert it here, where the diagnosis is obvious.
[ -s "${RUN_DIR}/backup/b-wp-content.manifest" ]
jq -e 'has("checksums_protected_pre_graft")' "${RUN_DIR}/manifest.json" >/dev/null

echo "==> asserting restore.sh is genuinely self-contained (no sitegraft function/lib reference, review finding A2)"
# No module in modules/ claims the fixture's fakebooking table yet (that's
# Step 4's job — a modules/fakebooking.sh doesn't exist until then), so
# manifest.checksums_protected_pre_graft is legitimately {} for THIS run
# (manifest_compute_unclaimed always leaves _unclaimed.tables=[], by design,
# see lib/manifest.sh) — that's not a bug to assert against here, it's the
# documented, already-tracked v1 gap. The self-containment and checksum-
# stability properties below are tested independently of which modules
# happen to be registered.
if grep -Eqi 'wp_remote|sitegraft_|backup_checksum|phase_backup|phase_restore|^\s*\.\s+.*lib/|^\s*source\s+.*lib/' "${RUN_DIR}/restore.sh"; then
  echo "restore.sh references a sitegraft function or lib file — not self-contained (finding A2) — aborting"
  exit 1
fi

echo "==> asserting the protected-data checksum is stable across two immediate re-hashes (finding A5)"
# shellcheck source=../../lib/core.sh
. "${ROOT}/lib/core.sh"     # log_info/run_or_echo — backup_wp_content (used
                            # directly below, bare-local deletion check) needs
                            # these; backup_checksum alone didn't, which is why
                            # this was missing until that check was added.
# shellcheck source=../../lib/inventory.sh
. "${ROOT}/lib/inventory.sh" # sq() — backup_generate_restore_script (used
                            # directly below, bare-local deletion check) emits
                            # every interpolated path through it. Found live on
                            # this harness: without it the bare-local block
                            # died with "sq: command not found" AFTER the whole
                            # wrapped-local restore had already passed.
                            # bin/sitegraft sources inventory before backup for
                            # every phase that reaches that generator; this
                            # file has to do the same.
# shellcheck source=../../lib/backup.sh
. "${ROOT}/lib/backup.sh"   # reuse the exact same normalized checksum
b_table() { ddev exec --raw -p "$PROJECT_B" -- wp eval "global \$wpdb; echo \$wpdb->prefix.'$1';"; }
# MAJOR-2 (review, Viktor): the dedicated fakebooking_reservations table
# alone is structurally OUTSIDE every remap graft ever runs (never a
# search-replace target, never a copy-path target) — checksumming only
# that table made the non-contamination assertion trivially, vacuously
# true. Real, REACHABLE protected data lives in fakebooking_settings
# (wp_options, inside every domain/ID remap's old table-wide scope) and in
# the fake_reservation post's own row (wp_posts, same table every migrated
# post lands in) — both now included, so this checksum actually covers
# what the tool's non-contamination promise is supposed to cover.
b_protected_checksum() {
  local table_dump options_dump post_id post_dump
  table_dump=$(ddev exec --raw -p "$PROJECT_B" -- wp db export - --tables="$(b_table fakebooking_reservations)")
  options_dump=$(ddev exec --raw -p "$PROJECT_B" -- wp option get fakebooking_settings --format=json)
  post_id=$(ddev exec --raw -p "$PROJECT_B" -- wp post list --post_type=fake_reservation --field=ID | head -1)
  post_dump=""
  [ -n "$post_id" ] && post_dump=$(ddev exec --raw -p "$PROJECT_B" -- wp post get "$post_id" --field=post_content)
  # Real bug found live while proving MAJOR-2's exposure: `$(...)` strips
  # ALL trailing newlines from each captured piece, so plain
  # "${a}${b}${c}" concatenation glues table_dump's LAST line (a real
  # `wp db export`'s trailing "-- Dump completed on ..." mysqldump comment)
  # directly onto options_dump's first character, with no newline between
  # them — merging them into ONE line that starts with "-- ". backup_checksum's
  # own comment-stripping filter (`grep -v '^-- '`, there specifically to
  # normalize mysqldump's own timestamp comments) then discarded that WHOLE
  # merged line, options_dump's entire content included — silently checksumming
  # only table_dump's untouched middle lines while options_dump/post_dump
  # (exactly the two surfaces this harness fix-pack added to make the
  # non-contamination check real) never affected the hash at all. Reproduced
  # live: PRE_GRAFT_CHECKSUM and POST_GRAFT_CHECKSUM matched byte-for-byte
  # even though `wp option get fakebooking_settings` printed visibly
  # different content before and after. Explicit `\n` separators keep each
  # piece on its own line, so none of them can be swallowed by the other's
  # trailing comment.
  backup_checksum "$(printf '%s\n%s\n%s\n' "$table_dump" "$options_dump" "$post_dump")"
}

CHECKSUM_1=$(b_protected_checksum)
CHECKSUM_2=$(b_protected_checksum)
[ -n "$CHECKSUM_1" ]
[ "$CHECKSUM_1" = "$CHECKSUM_2" ]  # same data, re-hashed immediately: must be stable

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "backup" ]; then
  echo "BACKUP OK (SITEGRAFT_HARNESS_STOP_AFTER=backup)"
  exit 0
fi

# MAJOR-1 regression (Viktor's review): mutate the marker AFTER backup,
# BEFORE restore. If db import is silently a no-op (the bug this fix
# addresses), the marker would still read MUTATED after restore — the
# checksum-stability assertion alone can't catch this, since nothing else
# mutates B's DB between backup and restore in this harness (graft is
# Step 4, not wired yet), so checksum_after == checksum_1 regardless of
# whether the import did anything.
echo "==> mutating the marker on B after backup, before restore (MAJOR-1 regression setup)"
ddev exec --raw -p "$PROJECT_B" -- wp option update sitegraft_test_marker "POST_BACKUP_MUTATED_VALUE" >/dev/null
MARKER_BEFORE_RESTORE=$(ddev exec --raw -p "$PROJECT_B" -- wp option get sitegraft_test_marker)
[ "$MARKER_BEFORE_RESTORE" = "POST_BACKUP_MUTATED_VALUE" ]

# issue #14, on the target shape the issue was actually about. B here IS a
# wrapped-local site (SITE_B_WP_CMD is a ddev wrapper), so the run's own
# restore.sh takes the manifest-based prune path — the one that used to be
# overwrite-only and left every file a graft added behind. Files added to
# wp-content after the backup stand in for exactly that: the copied theme, the
# copied plugins, the new uploads.
#
# Created through the container, not on the host directory: DDEV's Mutagen
# sync is asynchronous, so a host-side touch is not necessarily visible to the
# container (nor a container-side removal immediately visible to the host) at
# the moment the assertion runs. Everything about this check therefore happens
# on the container's side of the sync.
echo "==> adding a file and a directory to B's wp-content after the backup (issue #14 regression setup)"
ddev exec --raw -p "$PROJECT_B" -- touch /var/www/html/wp-content/sitegraft-added-after-backup.txt
ddev exec --raw -p "$PROJECT_B" -- mkdir -p /var/www/html/wp-content/plugins/sitegraft-added-plugin
ddev exec --raw -p "$PROJECT_B" -- touch /var/www/html/wp-content/plugins/sitegraft-added-plugin/main.php
ddev exec --raw -p "$PROJECT_B" -- test -f /var/www/html/wp-content/sitegraft-added-after-backup.txt

# --dry-run on the phase that deletes: it must report what it would remove and
# remove nothing. Asserted against a real container, because "lists it" and
# "leaves it alone" are two different claims and only one of them is provable
# by reading the script.
echo "==> asserting 'sitegraft restore --dry-run' previews the removal and touches nothing"
"${ROOT}/bin/sitegraft" restore --profile ddev-test --run "$RUN_DIR" --yes --dry-run 2>&1 | tee "${RUN_DIR}/restore-dryrun.log"
if ! grep -q 'sitegraft-added-after-backup.txt' "${RUN_DIR}/restore-dryrun.log"; then
  echo "'restore --dry-run' did not report the file added since the backup — the preview does not actually preview (issue #14) — aborting"
  exit 1
fi
ddev exec --raw -p "$PROJECT_B" -- test -f /var/www/html/wp-content/sitegraft-added-after-backup.txt
# Captured, not piped into `grep -q`: under `set -o pipefail` an early-exiting
# grep can SIGPIPE the still-writing producer and make the whole pipeline
# report failure — the size-dependent trap already documented at length in
# lib/backup.sh's backup_verify_db_export.
MARKER_AFTER_DRY_RUN=$(ddev exec --raw -p "$PROJECT_B" -- wp option get sitegraft_test_marker)
[ "$MARKER_AFTER_DRY_RUN" = "POST_BACKUP_MUTATED_VALUE" ]
echo "==> confirmed: --dry-run listed the removal and wrote nothing to B"

# Recommended addition beyond Task 3.2's literal scope (nightshift mandate:
# prefer the safer/more-thorough option): a live restore round-trip is the
# strongest available proof that restore.sh's self-containment claim is
# real, not just structurally grep-clean — it actually runs, standalone,
# against a real WordPress install, and B's protected data must come back
# byte-identical (same normalized checksum) afterward.
echo "==> running restore (--yes, non-interactive) and asserting it succeeds"
"${ROOT}/bin/sitegraft" restore --profile ddev-test --run "$RUN_DIR" --yes 2>&1 | tee "${RUN_DIR}/restore.log"

# issue #14 acceptance: "restoring a wrapped-local target after a graft leaves
# no file that the backup did not contain."
echo "==> asserting the restore removed what was added to wp-content after the backup (issue #14 acceptance, wrapped-local target)"
if ddev exec --raw -p "$PROJECT_B" -- test -e /var/www/html/wp-content/sitegraft-added-after-backup.txt; then
  echo "restore left behind a file added to B's wp-content after the backup — the wrapped-local restore is not exact-state (issue #14) — aborting"
  exit 1
fi
if ddev exec --raw -p "$PROJECT_B" -- test -e /var/www/html/wp-content/plugins/sitegraft-added-plugin; then
  echo "restore left behind a DIRECTORY added to B's wp-content after the backup (what a grafted plugin/theme looks like) — aborting"
  exit 1
fi
# ... while everything the backup DID contain is still there: this restore
# removes known additions, it does not wipe and rebuild.
ddev exec --raw -p "$PROJECT_B" -- test -d /var/www/html/wp-content/plugins
ddev exec --raw -p "$PROJECT_B" -- test -f /var/www/html/wp-content/mu-plugins/fake-plugin.php
# ... and the script said so itself, rather than the harness inferring it.
if ! grep -q 'Restore semantics:' "${RUN_DIR}/restore.log"; then
  echo "restore.sh did not state its own restore semantics when it ran (issue #14) — aborting"
  exit 1
fi
if ! grep -q 'wp-content now holds exactly what this backup holds' "${RUN_DIR}/restore.log"; then
  echo "restore.sh did not confirm, by re-listing B, that the removal actually happened — aborting"
  exit 1
fi
echo "==> confirmed: the wrapped-local restore is exact-state (issue #14)"

echo "==> asserting restore took a pre-restore safety snapshot of B's CURRENT state (db AND wp-content) before touching anything, and that the snapshot itself is turnkey-reversible"
PRE_RESTORE_DIR=$(ls -dt "${RUN_DIR}"/pre-restore-* 2>/dev/null | head -1)
[ -n "$PRE_RESTORE_DIR" ]
[ -s "${PRE_RESTORE_DIR}/backup/b-db.sql.gz" ]
[ -d "${PRE_RESTORE_DIR}/backup/b-wp-content" ] && [ -n "$(ls -A "${PRE_RESTORE_DIR}/backup/b-wp-content")" ]
[ -x "${PRE_RESTORE_DIR}/restore.sh" ]

echo "==> asserting B's protected data survived the backup+restore round-trip unchanged"
CHECKSUM_AFTER_RESTORE=$(b_protected_checksum)
[ "$CHECKSUM_AFTER_RESTORE" = "$CHECKSUM_1" ]

# MAJOR-1: the assertion that actually distinguishes "db import genuinely
# ran" from "db import silently did nothing" — see the mutation step above.
echo "==> asserting the marker reverted to its PRE-backup value (proves db import genuinely re-imported data, not a silent no-op — MAJOR-1)"
MARKER_AFTER_RESTORE=$(ddev exec --raw -p "$PROJECT_B" -- wp option get sitegraft_test_marker)
if [ "$MARKER_AFTER_RESTORE" != "PRE_BACKUP_VALUE" ]; then
  echo "restore did NOT revert B's database to the backed-up state (got '${MARKER_AFTER_RESTORE}', expected 'PRE_BACKUP_VALUE') — db import silently did nothing (MAJOR-1) — aborting"
  exit 1
fi
echo "==> confirmed: restore's db import genuinely re-imported B's database (mutate-and-revert proof, MAJOR-1)"

# DoD reconciliation (both reviewers flagged this): docs/definition-of-done.md
# promised "restore B to the EXACT pre-graft state" without scoping WHICH
# target that's guaranteed for — the wrapped-local (DDEV) branch above is
# documented as overwrite-only, not delete-capable (see
# backup_generate_restore_script's own comment: DDEV's Mutagen sync makes
# `rm -rf wp-content` fail with "Device or resource busy"). The round-trip
# checksum assertion above never exercises deletion at all (nothing removes
# a file from B's wp-content before restore runs), so a harness that stopped
# there would report a DoD item "green" on a property it never actually
# tested. This block genuinely exercises deletion on the BARE-LOCAL path —
# which is also the ssh-remote path's mechanism (`rsync --delete`), so it is
# the live evidence for both (design doc §6.7 /
# docs/definition-of-done.md). The WRAPPED-LOCAL path has a different
# mechanism and its own live assertion further down: since issue #14 it prunes
# by difference against the backup's archive, and the DoD's earlier wording
# here — scoping "exact pre-graft state" to ssh-remote and bare-local only —
# no longer holds.
#
# DDEV's docroot is a REAL host-filesystem directory (the container serves
# the SAME files this harness script can already see at /tmp/${PROJECT_B} —
# not a copy), which lets this exercise backup_wp_content's/
# backup_generate_restore_script's BARE-LOCAL (unwrapped) branch directly
# against real files, without adding a wp-cli-on-the-host dependency this
# harness doesn't otherwise need. The deletion guarantee is a pure
# filesystem property, independent of the DB import step, so this never
# touches B's database.
echo "==> asserting deletion semantics on the bare-local restore path (DoD reconciliation — the path 'exact pre-graft state' is actually guaranteed for)"
# NIT hardening (Viktor, taken in this same PR per house rule — fix now, not
# as a follow-up): the previous version of this check hand-typed an
# `rsync -avz --delete ...` line inline, matching what
# backup_generate_restore_script is BELIEVED to emit for the bare-local
# branch — that proves rsync's own --delete semantics work, but would NOT
# catch the generator itself drifting (e.g. losing --delete, or restoring
# to the wrong path) the way the db-import command's own generation is
# already covered by tests/unit/test_backup.bats. This version generates a
# real restore.sh via backup_generate_restore_script and extracts + runs
# the ACTUAL wp-content-restore command baked into it — so this check fails
# if the generator ever regresses, not just if rsync itself misbehaves.
BARE_TEST_DIR=$(mktemp -d)
(
  unset SITE_B_SSH_HOST
  # shellcheck disable=SC2034 # read via lib/backup.sh's backup_wp_content, sourced separately below, not in this file
  SITE_B_WP_PATH="/tmp/${PROJECT_B}"
  # shellcheck disable=SC2034 # same as above: read via lib/backup.sh's backup_wp_content, not in this file
  SITE_B_WP_CMD="wp"
  mkdir -p "${BARE_TEST_DIR}/backup"
  backup_wp_content "${BARE_TEST_DIR}/backup/b-wp-content" >/dev/null
  backup_generate_restore_script "${BARE_TEST_DIR}" >/dev/null
)
[ -d "${BARE_TEST_DIR}/backup/b-wp-content/themes" ]
[ -x "${BARE_TEST_DIR}/restore.sh" ]

# Simulate graft adding a file to B's wp-content AFTER this bare-local backup.
touch "/tmp/${PROJECT_B}/wp-content/SITEGRAFT_TEST_MARKER_TO_BE_DELETED.txt"
[ -f "/tmp/${PROJECT_B}/wp-content/SITEGRAFT_TEST_MARKER_TO_BE_DELETED.txt" ]

# Extract the exact command backup_generate_restore_script baked into
# restore.sh's `if ! { <cmd>; }; then` guard for the wp-content step (see
# lib/backup.sh's own heredoc) — never hand-retyped.
WP_CONTENT_RESTORE_LINE=$(grep -E '^if ! \{ rsync .*--delete ' "${BARE_TEST_DIR}/restore.sh" | head -1)
if [ -z "$WP_CONTENT_RESTORE_LINE" ]; then
  echo "generated restore.sh has no 'rsync ... --delete' wp-content-restore command on the bare-local branch — generator drift, the deletion guarantee would silently break — aborting"
  exit 1
fi
WP_CONTENT_RESTORE_CMD=$(printf '%s\n' "$WP_CONTENT_RESTORE_LINE" | sed -E 's/^if ! \{ (.*); \}; then$/\1/')
eval "$WP_CONTENT_RESTORE_CMD" >/dev/null

if [ -f "/tmp/${PROJECT_B}/wp-content/SITEGRAFT_TEST_MARKER_TO_BE_DELETED.txt" ]; then
  echo "the GENERATED restore.sh's bare-local wp-content command did NOT delete a file added since backup — the one path that's supposed to guarantee exact-state restore is broken — aborting"
  exit 1
fi
echo "==> confirmed: the GENERATED restore.sh's bare-local wp-content command deletes a file added to wp-content since the backup (rsync --delete, design doc §6.7)"
rm -rf "$BARE_TEST_DIR"

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "restore" ]; then
  echo "RESTORE OK (SITEGRAFT_HARNESS_STOP_AFTER=restore)"
  exit 0
fi

# --------------------------------------------------------------------------
# Step 4: graft — the real safety proof of this whole tool. Only
# graft_integrity_gate (a pure function needing nothing but core.sh) is
# called directly from the harness below, for the negative/positive gate
# assertion (e) — the real graft run itself goes through the normal
# bin/sitegraft subprocess, which sources everything it needs on its own.
# shellcheck source=../../lib/graft.sh
. "${ROOT}/lib/graft.sh"

echo "==> writing a real migrate/protect manifest for the graft run (the earlier manifest.json only tested default-deny, with empty migrate/protect)"
# manifest key names are arbitrary strings from graft's own perspective (it
# iterates .migrate[]/.protect[] values, never keys) — module post_import
# hooks are dispatched by SITEGRAFT_MODULES (the real discovered module
# prefix), not by manifest key, so "core-wp" here does not need to match
# modules/core-wp.sh's own prefix "core_wp" for its hook to run.
#
# options.search_replace.from/to: NOT "https://a.example.com"/"...b..." —
# found live: DDEV's own wp-config-ddev.php unconditionally defines
# WP_HOME/WP_SITEURL from DDEV_PRIMARY_URL, which overrides whatever
# `wp core install --url=` wrote to the DB (get_option('siteurl') applies
# that constant via WordPress core's own _config_wp_siteurl() filter) — so
# every URL this install actually generates at runtime (attachment guids,
# home_url() calls) uses the real "*.ddev.site" domain regardless of the
# --url flag. Using the real, live-resolved domain here is what makes
# assertion (c) below a genuine test of graft_search_replace_domain against
# real embedded content, not a check that happens to vacuously pass because
# the fixture domain was never actually present anywhere.
DOMAIN_A="https://${PROJECT_A}.ddev.site"
DOMAIN_B="https://${PROJECT_B}.ddev.site"
jq -n --arg da "$DOMAIN_A" --arg db "$DOMAIN_B" '{
  sitegraft_manifest_version: 1,
  frozen: true,
  migrate: {
    # wp_navigation included here (beyond page/post) specifically so Step 5
    # verify_nav_present gets exercised against a REAL migrated navigation
    # post, not merely its own no-op skip path (site-a-seed.sh already seeds
    # a wp_navigation post on A using the dynamic wp:page-list block).
    "core-wp": {post_types: ["page","post","wp_navigation"], option_keys: ["show_on_front","page_on_front","page_for_posts"]},
    media: {post_types: ["attachment"], option_keys: []},
    etch: {post_types: ["etch_cfs"], option_keys: ["etch_settings","etch_styles"]}
  },
  protect: {
    fakebooking: {post_types: ["fake_reservation"], tables: ["fakebooking_reservations"], option_keys: ["fakebooking_settings"]}
  },
  stack: {},
  clean: {enabled: false, post_types: []},
  options: {search_replace: {from: $da, to: $db}}
}' > "${RUN_DIR}/manifest.json"
chmod 600 "${RUN_DIR}/manifest.json"

echo "==> capturing A's pre-graft state for the residual-ID/domain assertions (design doc §9.1/§9.4)"
OLD_ATTACH_ID=$(ddev exec --raw -p "$PROJECT_A" -- wp post list --post_type=attachment --field=ID)
[ -n "$OLD_ATTACH_ID" ]

echo "==> MAJOR-2 (review, Viktor): injecting a real collision into B's protected data — a domain string AND an \"id\":<A's-attachment-id> payload inside BOTH fakebooking_settings (wp_options) and the protected fake_reservation post's own content (wp_posts) — the two REACHABLE surfaces the previous checksum never covered"
ddev exec --raw -p "$PROJECT_B" -- wp option update fakebooking_settings \
  "{\"currency\":\"CHF\",\"tax_rate\":3.7,\"note\":\"see ${DOMAIN_A}/booking for details\",\"decoy\":\"\\\"id\\\":${OLD_ATTACH_ID}\"}" --format=json
FAKEBOOKING_POST_ID=$(ddev exec --raw -p "$PROJECT_B" -- wp post list --post_type=fake_reservation --field=ID | head -1)
[ -n "$FAKEBOOKING_POST_ID" ]
ddev exec --raw -p "$PROJECT_B" -- wp post update "$FAKEBOOKING_POST_ID" \
  --post_content="Booking details at ${DOMAIN_A}/room — internal ref \"id\":${OLD_ATTACH_ID}"

# Recomputed fresh, AFTER the injection above — CHECKSUM_1 (much earlier in
# this script) predates it and would make this comparison vacuous.
PRE_GRAFT_CHECKSUM=$(b_protected_checksum)

# Step 5 addition, found live (a real bug the earlier graft-only harness
# pass never surfaced, since (b)/(h) above compare against this script's OWN
# b_protected_checksum, never against manifest.checksums_protected_pre_graft
# at all): re-running `sitegraft backup` here, against the REAL migrate/
# protect manifest just written above (not the empty-protect placeholder
# manifest.json used earlier for the plan/custom-code-gate demo), is what
# actually POPULATES manifest.checksums_protected_pre_graft for the
# "fakebooking" protect module — verify's own checksum comparison (Step 5)
# reads that key, and without this, it stays entirely absent (jq sees
# `null`), which crashed verify_compare_checksums outright the first time
# this harness reached it. This mirrors the REAL production flow (scan ->
# plan -> backup -> graft -> verify) exactly: backup always runs against the
# manifest that's about to be grafted, not a stale earlier one — the
# harness's own two-manifest test structure (an empty one to demo the
# custom-code gate, then this real one for graft) was the thing papering
# over the gap, not sitegraft itself.
echo "==> re-running backup against the REAL graft manifest, so checksums_protected_pre_graft reflects the actual protect selection (and the injected MAJOR-2 collision payload) verify will check against"
"${ROOT}/bin/sitegraft" backup --profile ddev-test --run "$RUN_DIR"
jq -e '.checksums_protected_pre_graft.fakebooking | startswith("sha256:")' "${RUN_DIR}/manifest.json" >/dev/null

echo "==> MAJOR-B (review fix-pack, reproduced live by Viktor): running graft --dry-run FIRST against this exact run directory, then asserting the REAL graft right after still does the work rather than silently skipping it"
# graft_mark_step (lib/graft.sh) used to `touch` its graft.<step>.done
# marker unconditionally, dry-run or not — a --dry-run graft against a run
# directory wrote every marker for real, so a REAL graft against that SAME
# run directory afterward saw every step as already done and skipped the
# entire pipeline, silently. This is the realistic sequence that triggers
# it: scan -> plan -> backup -> graft --dry-run -> graft, exactly what a
# cautious operator previewing before the real run would do. Fixed by
# guarding graft_mark_step itself so no marker is ever written under
# SITEGRAFT_DRY_RUN=1 — asserted here first (no marker files exist right
# after the dry run), then proven for real by every assertion (a)-(h) below,
# which only pass if the REAL graft that follows actually migrated content
# rather than a no-op skip.
"${ROOT}/bin/sitegraft" graft --profile ddev-test --run "$RUN_DIR" --allow-stack-mismatch --dry-run
DONE_MARKERS_AFTER_DRY_RUN=$(find "$RUN_DIR" -maxdepth 1 -name 'graft.*.done' 2>/dev/null)
if [ -n "$DONE_MARKERS_AFTER_DRY_RUN" ]; then
  echo "FAIL: graft --dry-run left marker file(s) behind — a real graft against this run directory would silently skip these steps (MAJOR-B regression):" >&2
  echo "$DONE_MARKERS_AFTER_DRY_RUN" >&2
  exit 1
fi
echo "==> confirmed: graft --dry-run left no graft.*.done marker in the run directory"

echo "==> running graft"
# --allow-stack-mismatch: both A/B get a fresh default WP theme from
# `ddev wp core install`, normally identical — passed defensively anyway so
# a real-world theme-version drift between the two disposable installs can
# never turn into unrelated harness flakiness; no other stack component
# (acss) is registered as a module in this repo yet (etch now is — see
# modules/etch.sh — but never matches this harness's fixtures, which
# simulate Etch via a mu-plugin, not a real "etch" plugin list entry), so
# graft_check_stack_precondition has nothing else to resolve either way.
"${ROOT}/bin/sitegraft" graft --profile ddev-test --run "$RUN_DIR" --allow-stack-mismatch

echo "==> (a) asserting migrated post_types exist and are visible on B"
ddev exec --raw -p "$PROJECT_B" -- wp post list --post_type=page --field=post_title | grep -q '^Home$'
ddev exec --raw -p "$PROJECT_B" -- wp post list --post_type=etch_cfs --field=post_title | grep -q 'Hero CFS'
ddev exec --raw -p "$PROJECT_B" -- wp post list --post_type=etch_cfs --field=post_title | grep -q 'Image Block CFS'
B_ATTACH_COUNT=$(ddev exec --raw -p "$PROJECT_B" -- wp post list --post_type=attachment --format=count)
[ "$B_ATTACH_COUNT" -ge 1 ]
# Step 5 fixture addition: wp_navigation was added to core-wp's migrate
# post_types above specifically to exercise verify_nav_present against real
# migrated data (site-a-seed.sh's "Main" wp_navigation post).
ddev exec --raw -p "$PROJECT_B" -- wp post list --post_type=wp_navigation --field=post_title | grep -q '^Main$'

echo "==> (b) asserting B's protected fake-plugin data is BYTE-IDENTICAL before/after graft (the central non-contamination proof)"
POST_GRAFT_CHECKSUM=$(b_protected_checksum)
if [ "$PRE_GRAFT_CHECKSUM" != "$POST_GRAFT_CHECKSUM" ]; then
  echo "FAIL: protected fake-plugin data changed during graft — contamination of B's live business data" >&2
  exit 1
fi
FAKE_ROW_COUNT_AFTER=$(ddev exec --raw -p "$PROJECT_B" -- wp eval 'global $wpdb; echo (int) $wpdb->get_var("SELECT COUNT(*) FROM ".$wpdb->prefix."fakebooking_reservations");')
[ "$FAKE_ROW_COUNT_AFTER" = "$FAKE_ROW_COUNT" ]

echo "==> (c) asserting no residual A ID/domain survived the two-pass sentinel remap + domain search-replace (design doc §9.1/§9.4)"
NEW_ATTACH_ID=$(awk -F'\t' -v old="$OLD_ATTACH_ID" '$1==old && $3=="attachment"{print $2}' "${RUN_DIR}/id-map.tsv")
[ -n "$NEW_ATTACH_ID" ]
[ "$NEW_ATTACH_ID" != "$OLD_ATTACH_ID" ]  # a real DDEV/WP install never reuses A's own ID space on a distinct B install
IMAGE_BLOCK_ID=$(ddev exec --raw -p "$PROJECT_B" -- wp post list --post_type=etch_cfs --title="Image Block CFS" --field=ID)
IMAGE_BLOCK_CONTENT=$(ddev exec --raw -p "$PROJECT_B" -- wp post get "$IMAGE_BLOCK_ID" --field=post_content)
case "$IMAGE_BLOCK_CONTENT" in
  *"\"id\":${OLD_ATTACH_ID}"*|*"wp-image-${OLD_ATTACH_ID}"*)
    echo "FAIL: B's imported content still references A's OLD attachment id (${OLD_ATTACH_ID}) — the sentinel ID remap did not fully rewrite it" >&2
    exit 1
    ;;
esac
case "$IMAGE_BLOCK_CONTENT" in
  *"\"id\":${NEW_ATTACH_ID}"*) : ;;
  *) echo "FAIL: B's imported content does not reference the correctly remapped NEW attachment id (${NEW_ATTACH_ID}) — the remap dropped the reference instead of rewriting it" >&2; exit 1 ;;
esac
# NIT-1 (review, Viktor): symmetry with the "id":NEW check above — the
# wp-image-X CSS-class pattern is the SECOND of the two shapes the sentinel
# remap has to rewrite (design doc §9.1); asserting only "id":NEW passed
# left that half of the remap's own output completely unverified.
case "$IMAGE_BLOCK_CONTENT" in
  *"wp-image-${NEW_ATTACH_ID}"*) : ;;
  *) echo "FAIL: B's imported content does not reference the correctly remapped NEW attachment id via the wp-image-X class either (expected wp-image-${NEW_ATTACH_ID})" >&2; exit 1 ;;
esac
case "$IMAGE_BLOCK_CONTENT" in
  *"${PROJECT_A}.ddev.site"*)
    echo "FAIL: B's imported content still contains A's domain string (${PROJECT_A}.ddev.site) — the domain search-replace did not fully rewrite it" >&2
    exit 1
    ;;
esac
echo "$IMAGE_BLOCK_CONTENT" | grep -q "${PROJECT_B}.ddev.site"

echo "==> (d) asserting page_on_front resolves to the correctly remapped page on B (design doc §9.3)"
B_FRONT_ID=$(ddev exec --raw -p "$PROJECT_B" -- wp option get page_on_front)
[ -n "$B_FRONT_ID" ] && [ "$B_FRONT_ID" != "0" ]
ddev exec --raw -p "$PROJECT_B" -- wp post get "$B_FRONT_ID" --field=post_title | grep -q '^Home$'
NEW_HOME_ID_FROM_MAP=$(awk -F'\t' -v old="$(ddev exec --raw -p "$PROJECT_A" -- wp option get page_on_front)" '$1==old && $3=="page"{print $2}' "${RUN_DIR}/id-map.tsv")
[ "$B_FRONT_ID" = "$NEW_HOME_ID_FROM_MAP" ]

echo "==> (g) MAJOR-1: asserting a migrated post's featured image (_thumbnail_id) was remapped to the correctly migrated NEW attachment id, not left pointing at A's old one"
FEATURED_PAGE_ID_B=$(ddev exec --raw -p "$PROJECT_B" -- wp post list --post_type=page --title="Featured Image Test Page" --field=ID)
[ -n "$FEATURED_PAGE_ID_B" ]
FEATURED_THUMB_ID=$(ddev exec --raw -p "$PROJECT_B" -- wp post meta get "$FEATURED_PAGE_ID_B" _thumbnail_id)
if [ "$FEATURED_THUMB_ID" = "$OLD_ATTACH_ID" ]; then
  echo "FAIL: featured image _thumbnail_id on B still points at A's OLD attachment id (${OLD_ATTACH_ID}) — wordpress-importer's native remap never ran (attachments bypass wp import entirely) and graft_remap_featured_images did not fix it" >&2
  exit 1
fi
[ "$FEATURED_THUMB_ID" = "$NEW_ATTACH_ID" ]

echo "==> (h) MAJOR-2: content-level confirmation that B's protected data (already proven byte-identical by (b)'s checksum, now carrying a real domain-string + colliding-attachment-ID payload) genuinely was not touched — not just that its checksum happens to match"
FAKEBOOKING_SETTINGS_AFTER=$(ddev exec --raw -p "$PROJECT_B" -- wp option get fakebooking_settings --format=json)
case "$FAKEBOOKING_SETTINGS_AFTER" in
  *"${PROJECT_B}.ddev.site"*|*"${NEW_ATTACH_ID}"*)
    echo "FAIL: fakebooking_settings was rewritten (contains B's domain or the NEW attachment id) even though the checksum matched — investigate immediately, this should never happen" >&2
    exit 1
    ;;
esac
case "$FAKEBOOKING_SETTINGS_AFTER" in
  *"${PROJECT_A}.ddev.site"*) : ;;
  *) echo "FAIL: fakebooking_settings no longer contains A's domain string at all — the fixture injection itself didn't survive, this assertion would be meaningless" >&2; exit 1 ;;
esac
echo "==> confirmed: protected data (wp_options AND wp_posts) carrying a real domain-string + colliding-ID payload is untouched by graft"

echo "==> (f) asserting the mapping mu-plugin was removed from B after graft"
if ddev exec --raw -p "$PROJECT_B" -- test -f /var/www/html/wp-content/mu-plugins/sitegraft-id-mapper.php 2>/dev/null; then
  echo "FAIL: sitegraft-id-mapper.php is still present on B after graft completed — never left running unattended" >&2
  exit 1
fi
ddev exec --raw -p "$PROJECT_B" -- wp option get sitegraft_test_marker >/dev/null 2>&1 || true # (unrelated to mu-plugin; keeps eval parity with earlier assertions)

echo "==> (e) asserting the integrity gate ABORTS on a real WXR file carrying a post_type outside the manifest allowlist"
# Uses the REAL WXR file graft's own export step just produced (not a
# hand-fabricated fixture) — proves the gate works against genuine wp-cli
# export output, not only the synthetic XML in tests/unit/test_graft_integrity_gate.bats.
REAL_WXR=$(ls "${RUN_DIR}/export"/*.xml | head -1)
[ -n "$REAL_WXR" ]
ALLOWED_TYPES=$(jq -c '[.migrate[].post_types[]?]' "${RUN_DIR}/manifest.json")
# Sanity check first: the gate must PASS the real, untouched file — otherwise
# the negative assertion below would be meaningless (the gate might just be
# rejecting everything).
if ! graft_integrity_gate "$REAL_WXR" "$ALLOWED_TYPES"; then
  echo "FAIL: the integrity gate rejected graft's own real, unmutated WXR export — sanity check failed, negative test below would be meaningless" >&2
  exit 1
fi
MUTATED_WXR="${RUN_DIR}/export/mutated-with-injected-post-type.xml"
# `</channel>` and `</rss>` land on SEPARATE lines in a real wp-cli export
# (verified live — an earlier version of this sed matched them as one line,
# which never matches, silently making "mutated" an exact copy of the
# original and this whole negative assertion vacuous). Targeting the
# `</channel>` line alone is what actually lands the injected line.
sed 's#</channel>#<item><wp:post_type>injected_evil_type</wp:post_type></item>\
</channel>#' "$REAL_WXR" > "$MUTATED_WXR"
grep -q 'injected_evil_type' "$MUTATED_WXR" || { echo "FAIL: the mutation itself did not land in ${MUTATED_WXR} — the sed pattern didn't match this wp-cli export's actual line structure, the negative assertion below would be meaningless" >&2; exit 1; }
if graft_integrity_gate "$MUTATED_WXR" "$ALLOWED_TYPES"; then
  echo "FAIL: the integrity gate ACCEPTED a WXR file carrying a post_type outside the manifest allowlist — the leak gate is not working (this is a security control, design doc §6.4 step 4)" >&2
  exit 1
fi
echo "==> confirmed: the integrity gate aborts on a real WXR file leaking an out-of-allowlist post_type, and passes the same file before mutation"

echo "==> re-running graft is a no-op past the completed markers (marker-gated resumability, design doc §6.4)"
"${ROOT}/bin/sitegraft" graft --profile ddev-test --run "$RUN_DIR" --allow-stack-mismatch
POST_RERUN_CHECKSUM=$(b_protected_checksum)
[ "$POST_RERUN_CHECKSUM" = "$PRE_GRAFT_CHECKSUM" ]

echo "ALL GRAFT ASSERTIONS PASSED"

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "graft" ]; then
  echo "GRAFT OK (SITEGRAFT_HARNESS_STOP_AFTER=graft)"
  exit 0
fi

# --------------------------------------------------------------------------
# Step 5: verify + the full graft/verify/restore assertion set (review
# finding B3). verify is read-only against B — nothing below it mutates B
# except the deliberate negative-case injection/revert, which exists to
# prove verify actually detects a real regression rather than always
# reporting PASS.

echo "==> updating the harness profile with B's real, live-resolved URL (needed for verify's HTTP smoke check) — same DDEV_PRIMARY_URL override reasoning as the DOMAIN_A/DOMAIN_B comment above; the earlier SITE_B_URL='https://b.example.com' was never the URL DDEV actually serves"
cat > "${ROOT}/profiles/ddev-test.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/html"
SITE_A_WP_CMD="ddev exec --raw -p ${PROJECT_A} -- wp"
SITE_A_URL="${DOMAIN_A}"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/var/www/html"
SITE_B_WP_CMD="ddev exec --raw -p ${PROJECT_B} -- wp"
SITE_B_URL="${DOMAIN_B}"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-ddev-test-runs"
EOF

echo "==> running verify"
"${ROOT}/bin/sitegraft" verify --profile ddev-test --run "$RUN_DIR"

VERIFY_REPORT="${RUN_DIR}/verify-report.md"
echo "==> asserting the verify report exists and every check passed cleanly (no HARD FAIL) on a graft that should be entirely correct"
[ -f "$VERIFY_REPORT" ]
if grep -q "HARD FAIL" "$VERIFY_REPORT"; then
  echo "FAIL: verify-report.md contains a HARD FAIL line on a graft run that completed cleanly:" >&2
  cat "$VERIFY_REPORT" >&2
  exit 1
fi
grep -q "protected data unchanged" "$VERIFY_REPORT"
grep -q "migrated options match A's values on B" "$VERIFY_REPORT"
grep -q "page_on_front resolves to the correctly remapped page" "$VERIFY_REPORT"
grep -q "A's domain string is absent from the content graft imported" "$VERIFY_REPORT"
# ...and that it says HOW MUCH it examined, with a non-zero count on both
# surfaces. A tick alone is not proof: the check can loop over an empty
# post_ids/option_keys payload and report "absent" having read nothing at
# all (Viktor's re-review of PR #26, B1) — on a real graft with real
# migrated posts and options, both counts must be greater than zero.
DOMAIN_SCOPE_LINE=$(grep "A's domain string is absent from the content graft imported" "$VERIFY_REPORT")
DOMAIN_SCANNED_POSTS=$(printf '%s' "$DOMAIN_SCOPE_LINE" | sed -n 's/.*(\([0-9][0-9]*\) migrated post(s).*/\1/p')
DOMAIN_SCANNED_OPTIONS=$(printf '%s' "$DOMAIN_SCOPE_LINE" | sed -n 's/.* + \([0-9][0-9]*\) migrated option(s) scanned).*/\1/p')
if [ -z "$DOMAIN_SCANNED_POSTS" ] || [ -z "$DOMAIN_SCANNED_OPTIONS" ] || [ "$DOMAIN_SCANNED_POSTS" -lt 1 ] || [ "$DOMAIN_SCANNED_OPTIONS" -lt 1 ]; then
  echo "FAIL: the domain-absence line ticked its box without naming a non-zero scope on a real graft: ${DOMAIN_SCOPE_LINE}" >&2
  exit 1
fi
echo "==> confirmed: the domain-absence check reports the real scope it examined (${DOMAIN_SCANNED_POSTS} post(s) + ${DOMAIN_SCANNED_OPTIONS} option(s)), not a bare tick"
grep -q "no orphan post_parent references" "$VERIFY_REPORT"
grep -q "expected navigation is present" "$VERIFY_REPORT"
grep -q "Result: PASS" "$VERIFY_REPORT"
echo "==> confirmed: verify report shows every positive check passed, on real migrated WordPress data (not stubs)"

echo "==> NEGATIVE CASE: mutating a migrated option's value on B after graft, to prove verify actually detects a real B3-class regression rather than always reporting PASS (finding B3's whole reason to exist)"
ddev exec --raw -p "$PROJECT_B" -- wp option update etch_settings '{"theme_mode":"CORRUPTED_BY_HARNESS_NEGATIVE_CASE"}' --format=json
if "${ROOT}/bin/sitegraft" verify --profile ddev-test --run "$RUN_DIR"; then
  echo "FAIL: verify reported success even though etch_settings on B no longer matches the value graft migrated from A — verify is not actually checking what it claims to check (finding B3 regression)" >&2
  exit 1
fi
grep -q "HARD FAIL" "$VERIFY_REPORT"
grep -q "etch_settings" "$VERIFY_REPORT"
grep -q "Result: HARD FAIL" "$VERIFY_REPORT"
echo "==> confirmed: verify correctly HARD FAILS (non-zero exit, report says so explicitly) when a migrated option's value on B has drifted from what graft wrote — never an optimistic pass"

echo "==> reverting the injected corruption and re-confirming verify passes clean again"
ddev exec --raw -p "$PROJECT_B" -- wp option update etch_settings '{"theme_mode":"dark"}' --format=json
"${ROOT}/bin/sitegraft" verify --profile ddev-test --run "$RUN_DIR"
grep -q "Result: PASS" "$VERIFY_REPORT"

# Security-review fix-pack (post-merge-review by Marcel + Kimi, converging
# with Viktor's own independent finding): the FIRST version of this harness
# pass never actually exercised a domain leak, so it never caught that
# verify_domain_absent's original SQL-based implementation was structurally
# DEAD — a `UNION ... LIMIT` per branch is invalid MySQL/MariaDB syntax, so
# every real invocation errored, and that error was silently swallowed
# (`2>/dev/null || echo ""`) into an always-"absent" result. Marcel found
# this by reading a real verify-report.md that said "domain absent: PASS"
# against a B that still, provably, carried A's domain. This negative case
# is the fix's own proof: it did not exist before, and its whole point is
# proving the rewritten check (a) genuinely fires on a real leak in content
# graft imported, something the dead check could never do regardless of
# what was actually on B, and (b) stays correctly scoped to graft's own
# write surface (migrated posts + migrated option_keys) rather than
# hard-failing on B's own protected, out-of-scope data — B's fakebooking
# fixture has carried A's domain in its OWN settings since the MAJOR-2
# injection far above, and must NOT be reported here.
echo "==> NEGATIVE CASE 2 (the primary regression this fix-pack repairs): injecting A's domain string into a post graft ACTUALLY imported (in scope), while B's protected fakebooking_settings STILL carries A's domain from the earlier MAJOR-2 injection (out of scope) — proves verify_domain_absent both fires for real and stays correctly scoped"
HERO_ID=$(ddev exec --raw -p "$PROJECT_B" -- wp post list --post_type=etch_cfs --title="Hero CFS" --field=ID)
[ -n "$HERO_ID" ]
HERO_CONTENT_BEFORE=$(ddev exec --raw -p "$PROJECT_B" -- wp post get "$HERO_ID" --field=post_content)
ddev exec --raw -p "$PROJECT_B" -- wp post update "$HERO_ID" --post_content="${HERO_CONTENT_BEFORE} <!-- leaked reference to ${DOMAIN_A} -->"
if "${ROOT}/bin/sitegraft" verify --profile ddev-test --run "$RUN_DIR"; then
  echo "FAIL: verify reported success even though A's domain string was injected into a post graft actually imported — verify_domain_absent is not checking real content (the exact dead-check regression this fix-pack repairs)" >&2
  exit 1
fi
grep -q "HARD FAIL" "$VERIFY_REPORT"
# The actual log line interpolates the domain BETWEEN "domain string" and
# "is still present" (`A's domain string ('https://...') is still present in
# content graft imported: post:N`) — matching on the stable suffix only,
# never the interpolated domain text itself.
DOMAIN_HARD_FAIL_LINE=$(grep "is still present in content graft imported" "$VERIFY_REPORT")
[ -n "$DOMAIN_HARD_FAIL_LINE" ]
case "$DOMAIN_HARD_FAIL_LINE" in
  *"post:${HERO_ID}"*) : ;;
  *) echo "FAIL: the domain-absence hard fail did not name the actual leaking post (post:${HERO_ID})" >&2; exit 1 ;;
esac
case "$DOMAIN_HARD_FAIL_LINE" in
  *"fakebooking"*)
    echo "FAIL: verify_domain_absent flagged B's PROTECTED fakebooking_settings (out of graft's write scope) — the scoping fix regressed to a table-wide scan" >&2
    exit 1
    ;;
esac
echo "==> confirmed: verify_domain_absent fires on a real domain leak in imported content (post:${HERO_ID}) and correctly ignores B's protected fakebooking_settings, which has carried A's domain since the MAJOR-2 injection — proves both the fix and the scoping"

echo "==> reverting the injected domain leak and re-confirming verify passes clean again"
ddev exec --raw -p "$PROJECT_B" -- wp post update "$HERO_ID" --post_content="$HERO_CONTENT_BEFORE"
"${ROOT}/bin/sitegraft" verify --profile ddev-test --run "$RUN_DIR"
grep -q "Result: PASS" "$VERIFY_REPORT"

# Security-review fix-pack (Kimi): same fail-open class as the domain check
# above — a query ERROR was previously indistinguishable from "confirmed
# zero orphans". This proves the check can genuinely detect a real orphan
# (a non-blocking WARNING per design doc §9.2/§11 — a found orphan signals a
# manifest selection mistake to fix by hand, not something verify
# auto-corrects or hard-fails on), not merely that it can fail closed on an
# error (already covered by tests/unit/test_verify.bats).
echo "==> NEGATIVE CASE 3 (orphan post_parent check): setting a migrated page's post_parent to an ID that does not exist on B"
ddev exec --raw -p "$PROJECT_B" -- wp post update "$FEATURED_PAGE_ID_B" --post_parent=999999
"${ROOT}/bin/sitegraft" verify --profile ddev-test --run "$RUN_DIR"
ORPHAN_LINE=$(grep "orphan post_parent references found" "$VERIFY_REPORT")
[ -n "$ORPHAN_LINE" ]
case "$ORPHAN_LINE" in
  *"${FEATURED_PAGE_ID_B}"*) : ;;
  *) echo "FAIL: the orphan-found line did not name the actual orphaned page (${FEATURED_PAGE_ID_B})" >&2; exit 1 ;;
esac
if grep -q "Result: HARD FAIL" "$VERIFY_REPORT"; then
  echo "FAIL: a found orphan must be a non-blocking WARNING (design doc §9.2/§11), not a HARD FAIL" >&2
  exit 1
fi
echo "==> confirmed: the orphan post_parent check genuinely detects a real orphan (post ${FEATURED_PAGE_ID_B}) as a non-blocking warning"

echo "==> reverting the injected orphan and re-confirming verify passes clean again"
ddev exec --raw -p "$PROJECT_B" -- wp post update "$FEATURED_PAGE_ID_B" --post_parent=0
"${ROOT}/bin/sitegraft" verify --profile ddev-test --run "$RUN_DIR"
grep -q "Result: PASS" "$VERIFY_REPORT"

echo "ALL VERIFY ASSERTIONS PASSED"

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "verify" ]; then
  echo "VERIFY OK (SITEGRAFT_HARNESS_STOP_AFTER=verify)"
  exit 0
fi

echo "==> running restore (--yes, non-interactive) and re-checking protected state after the full graft->verify->restore round-trip"
"${ROOT}/bin/sitegraft" restore --profile ddev-test --run "$RUN_DIR" --yes

echo "==> asserting B's protected fake-plugin data is byte-identical to its pre-graft state after restore (same PRE_GRAFT_CHECKSUM baseline as the marker-gated-resumability check above)"
RESTORE_CHECKSUM=$(b_protected_checksum)
if [ "$PRE_GRAFT_CHECKSUM" != "$RESTORE_CHECKSUM" ]; then
  echo "FAIL: protected fake-plugin data differs after restore (Step 5 graft->verify->restore round-trip)" >&2
  exit 1
fi

echo "==> asserting the mapping mu-plugin is still absent from B after restore (it was already removed by graft itself, and restore never re-adds it)"
if ddev exec --raw -p "$PROJECT_B" -- test -f /var/www/html/wp-content/mu-plugins/sitegraft-id-mapper.php 2>/dev/null; then
  echo "FAIL: sitegraft-id-mapper.php is present on B after restore" >&2
  exit 1
fi

echo "ALL VERIFY+RESTORE ASSERTIONS PASSED (Step 5 — full graft/verify/restore pipeline proven end-to-end)"
