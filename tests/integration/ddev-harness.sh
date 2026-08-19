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

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "scan" ]; then
  echo "SCAN OK (SITEGRAFT_HARNESS_STOP_AFTER=scan)"
  exit 0
fi

echo "no later phase wired yet — see Task 3.2 (backup), 5.2 (graft/verify/restore)"
