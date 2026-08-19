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
MANIFEST_MODE=$(stat -f '%Lp' "${RUN_DIR}/manifest.json" 2>/dev/null || stat -c '%a' "${RUN_DIR}/manifest.json")
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
# shellcheck source=../../lib/backup.sh
. "${ROOT}/lib/backup.sh"   # reuse the exact same normalized checksum
b_table() { ddev exec --raw -p "$PROJECT_B" -- wp eval "global \$wpdb; echo \$wpdb->prefix.'$1';"; }
b_protected_checksum() { backup_checksum "$(ddev exec --raw -p "$PROJECT_B" -- wp db export - --tables="$(b_table fakebooking_reservations)")"; }

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

# Recommended addition beyond Task 3.2's literal scope (nightshift mandate:
# prefer the safer/more-thorough option): a live restore round-trip is the
# strongest available proof that restore.sh's self-containment claim is
# real, not just structurally grep-clean — it actually runs, standalone,
# against a real WordPress install, and B's protected data must come back
# byte-identical (same normalized checksum) afterward.
echo "==> running restore (--yes, non-interactive) and asserting it succeeds"
"${ROOT}/bin/sitegraft" restore --profile ddev-test --run "$RUN_DIR" --yes

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
# tested. This block genuinely exercises deletion — on the ONE path that's
# supposed to guarantee it (design doc §6.7 / docs/definition-of-done.md,
# amended in this same PR to scope "exact pre-graft state" to ssh-remote and
# bare-local targets only).
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
  SITE_B_WP_PATH="/tmp/${PROJECT_B}"
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

echo "no later phase wired yet — see Task 5.2 (graft/verify)"
