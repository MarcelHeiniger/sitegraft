#!/usr/bin/env bash
# modules/acss.sh — graft module for Automatic.css (ACSS).
#
# docs/usage.md §5 shipped v1 WITHOUT this module, blocked on one thing: the
# plugin's folder name had never been verified against a real install, and
# guessing it would risk either failing to detect ACSS or mis-detecting it.
#
# Both folder names have now been observed on real installs, on versions that
# bracket the rename — see acss_stack_candidates below for the evidence and
# for why the current name is ordered first. That closes the blocker.
#
# What a real ACSS install actually stores (verified, not assumed):
#   - NO custom post types
#   - NO custom database tables
#   - a handful of wp_options, of which exactly ONE carries the configuration:
#       automatic_css_settings              <- the whole framework configuration
#       automatic_css_db_version            <- schema marker, never migrate
#       automatic_css_license_key           <- secret, never migrate
#       automatic_css_license_status        <- licensing state, never migrate
#       automatic_css_generated_inventory   <- present on 4.0.1, absent on
#           4.0.0-rc-1. Derived state (an inventory ACSS builds from the
#           settings), deliberately NOT migrated: copying a cache computed
#           from A's settings onto B is at best redundant and at worst stale,
#           and ACSS rebuilds it from automatic_css_settings anyway.
#   - its compiled stylesheets on disk under
#       wp-content/uploads/automatic-css/   (automatic.css,
#       automatic-variables.css, the block-editor variants, ...)
#     These ride along with graft_media_sync, which syncs the whole uploads
#     tree rather than only files attached to a media-library item. Note the
#     push side uses --ignore-existing, so on a SECOND graft against the same
#     B those compiled files are NOT refreshed while automatic_css_settings
#     is — remove wp-content/uploads/automatic-css/ on B between runs, or
#     regenerate from ACSS's own UI afterward.

acss_name() { echo "Automatic.css"; }

acss_detect() {
  # $1 = path to a scan-*.json produced by `sitegraft scan`
  # Either packaging (see acss_stack_candidates for the evidence) counts as
  # "ACSS is installed here".
  jq -e '.plugins[]? | select(.name == "automatic-css" or .name == "automaticcss-plugin")' "$1" >/dev/null 2>&1
}

# EXPLICIT ALLOWLIST, deliberately not the broad `automatic_css_*` prefix the
# option names invite. `<mod>_option_keys_exclude` is documented in
# docs/usage.md §5 as the way to carve license keys back out of a broad
# prefix — but that function is inert: nothing in lib/ or bin/ ever reads it
# (see the note in modules/etch.sh). A prefix here would therefore ship
# automatic_css_license_key to B for real. One name, listed on purpose.
acss_option_keys() {
  cat <<'EOF'
automatic_css_settings
EOF
}

# Declared for contract completeness and to document intent, even though the
# core never calls it today (same inert-function caveat as above). If that
# gets wired, this must keep excluding both the licence pair and the schema
# marker — and acss_option_keys above must STILL stay an explicit allowlist,
# not be widened to a prefix on the strength of it.
acss_option_keys_exclude() {
  cat <<'EOF'
automatic_css_license_*
automatic_css_db_version
EOF
}

# design doc §12: ACSS is one of the three rendering-stack components whose
# absence or mismatch on B must block `graft` — Etch content styled by ACSS
# renders as unstyled markup without it, which "succeeds" by every
# content-level measure while producing a visibly broken site.
#
# BOTH packagings, current first — inventory_resolve_slug returns the first
# candidate actually present on the site being scanned.
#
# docs/usage.md §5 recorded this list as the reason the module could not
# ship: the folder name used before v4 had never been seen on a real
# install, and guessing it would risk resolving to a folder that is not
# ACSS at all. Both names have now been observed side by side, on two real
# sites, on versions that bracket the change:
#
#   automaticcss-plugin/automaticcss-plugin.php   Version: 4.0.0-rc-1
#   automatic-css/automatic-css.php               Version: 4.0.1
#
# Same plugin in both: "Plugin Name: Automatic.css", same Plugin URI, and the
# SAME "Text Domain: automatic-css" in both headers — the directory and main
# file were renamed onto the text domain the plugin already used.
#
# The rename happened at ACSS 4.0: that is the documented behaviour of the
# plugin, not an inference drawn from these two installs. The two sites above
# are simply the confirmation that both names occur in the wild, and they
# bracket the change (a 4.0 release candidate still carrying the old
# directory, a 4.0.1 carrying the new one).
#
# Consequence for ordering: `automatic-css` is what every current install
# has, so it goes first; `automaticcss-plugin` is the legacy name and stays
# as the fallback. A site running an older ACSS still resolves correctly,
# and a site with both folders present (an upgrade that left the old
# directory behind) resolves to the current one rather than the stale copy.
acss_stack_candidates() {
  cat <<'EOF'
automatic-css
automaticcss-plugin
EOF
}
