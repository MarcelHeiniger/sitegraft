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

echo "no later phase wired yet — see Task 3.2 (backup), 5.2 (graft/verify/restore)"
