#!/usr/bin/env bash
# tests/integration/fixtures/site-a-seed.sh — seed fake Etch-shaped content on
# site A for the DDEV harness. No real Etch license required — only the shape of
# the data (CPTs + options) matters for testing sitegraft's mechanics.
#
# The etch_cfs/etch_cpts post types must already be registered by the time
# this runs (see fixtures/site-a-fake-etch/fake-etch-cpts.php, dropped into
# site A's mu-plugins/ by the harness before calling this script) — a one-off
# `wp eval register_post_type(...)` only registers a post type for that single
# process; it is invisible to every later wp-cli invocation, including the
# `wp post create --post_type=etch_cfs` call below and sitegraft's own `scan`
# (verified against a real install).
set -euo pipefail
DDEV_PROJECT="$1" # e.g. sitegraft-test-a

HOME_ID=$(ddev exec --raw -p "$DDEV_PROJECT" -- wp post create --post_type=page --post_title="Home" --post_status=publish --porcelain)
ddev exec --raw -p "$DDEV_PROJECT" -- wp post create --post_type=etch_cfs --post_title="Hero CFS" --post_status=publish
ddev exec --raw -p "$DDEV_PROJECT" -- wp option update show_on_front page
ddev exec --raw -p "$DDEV_PROJECT" -- wp option update page_on_front "$HOME_ID"
ddev exec --raw -p "$DDEV_PROJECT" -- wp option update etch_settings '{"theme_mode":"dark"}' --format=json
ddev exec --raw -p "$DDEV_PROJECT" -- wp option update etch_styles '{"primary_color":"#111"}' --format=json
ddev exec --raw -p "$DDEV_PROJECT" -- wp option update automatic_css_settings '{"spacing_scale":"1.25"}' --format=json
