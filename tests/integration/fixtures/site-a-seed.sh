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
# M5 fixture: a wp_navigation post using the dynamic wp:page-list block (no
# hardcoded post IDs) — the harness asserts inventory_nav_uses_dynamic_page_list
# picks this up as true (design doc §0 point 11 / §6.1).
ddev exec --raw -p "$DDEV_PROJECT" -- wp post create --post_type=wp_navigation --post_title="Main" --post_status=publish --post_content='<!-- wp:page-list /-->'

# Step 4 fixture (design doc §9.1): a real media attachment plus an
# etch_cfs post embedding it BOTH ways Etch actually does — the `"id":X`
# JSON block attribute AND an absolute-URL <img> tag carrying A's own
# domain (wp-image-X class included too, since graft's sentinel remap
# matches that form as well) — this is the only way to exercise the
# two-pass sentinel ID remap and the domain search-replace against real,
# wp-cli-produced content instead of hand-fabricated test JSON. A 1x1
# transparent GIF (the classic 43-byte "spacer.gif") is the smallest file
# `wp media import` reliably accepts as a real image without any external
# network fetch.
IMG_HOST_PATH="/tmp/${DDEV_PROJECT}/sitegraft-test-fixture.gif"
printf 'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==' | { base64 -d 2>/dev/null || base64 -D; } > "$IMG_HOST_PATH"
ATTACH_ID=$(ddev exec --raw -p "$DDEV_PROJECT" -- wp media import /var/www/html/sitegraft-test-fixture.gif --porcelain)
ATTACH_URL=$(ddev exec --raw -p "$DDEV_PROJECT" -- wp post get "$ATTACH_ID" --field=guid)
ddev exec --raw -p "$DDEV_PROJECT" -- wp post create --post_type=etch_cfs --post_title="Image Block CFS" --post_status=publish \
  --post_content="<!-- wp:etch/image {\"id\":${ATTACH_ID}} --><img class=\"wp-image-${ATTACH_ID}\" src=\"${ATTACH_URL}\" /><!-- /wp:etch/image -->"

# MAJOR-1 fixture (review, Viktor): a migrated page carrying A's own
# attachment as its WordPress-core featured image (_thumbnail_id) — the
# reference wordpress-importer would normally remap natively during a WXR
# import, but never does here since attachments are migrated outside
# `wp import` entirely (see lib/graft.sh's graft_remap_featured_images own
# comment). Without this fixture, a featured-image regression is invisible
# to the harness.
FEATURED_PAGE_ID=$(ddev exec --raw -p "$DDEV_PROJECT" -- wp post create --post_type=page --post_title="Featured Image Test Page" --post_status=publish --porcelain)
ddev exec --raw -p "$DDEV_PROJECT" -- wp post meta update "$FEATURED_PAGE_ID" _thumbnail_id "$ATTACH_ID"
