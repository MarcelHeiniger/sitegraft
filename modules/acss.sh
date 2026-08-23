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
# option names invite. That was originally forced: `<mod>_option_keys_exclude`
# was documented as the way to carve license keys back out of a prefix, and
# nothing ever called it, so a prefix here would have shipped
# automatic_css_license_key to B for real (issue #13).
#
# The exclusion is applied now (docs/decisions/0007-module-dynamic-selections.md),
# so a prefix would be safe — and this stays an allowlist anyway. Exactly ONE
# of this plugin's options carries configuration worth migrating; the rest are
# a license pair, a schema marker, and a cache ACSS rebuilds from the
# settings. A prefix would have to exclude everything except one name, which
# is an allowlist written backwards, with the worse failure mode: a future
# `automatic_css_<something-secret>` would migrate until someone noticed.
acss_option_keys() {
  cat <<'EOF'
automatic_css_settings
EOF
}

# Applied for real as of issue #13's fix — module_selection (lib/modules.sh)
# calls this and drops every match from acss_option_keys above. Redundant
# today, since that allowlist names only `automatic_css_settings` and nothing
# here can match it; kept as the second line of defence it was always meant
# to be, and as the thing that keeps the license pair and the schema marker
# out should the allowlist ever be widened.
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
# The rename happened at ACSS 4.0, announced by the plugin's author — this
# is the plugin's documented behaviour, not an inference drawn from these two
# installs. The sites above merely confirm both names occur in the wild, on
# versions that bracket the change.
#
# The part that matters here, and that is easy to get wrong: 4.0 is NOT
# backward compatible, and the author deliberately made the two packagings
# installable and ACTIVATABLE SIDE BY SIDE so that a site can transition at
# its own pace. Two ACSS directories on one site is therefore a supported,
# intentional configuration — NOT the leftovers of a botched upgrade.
#
# KNOWN GAP this module cannot close on its own. `_stack_candidates` feeds
# inventory_resolve_slug, which returns exactly ONE slug: the first candidate
# it finds. On a site running both packagings at once, graft would copy only
# that one to B, and anything on B that depended on the other would render
# unstyled — the failure this whole §12 stack precondition exists to prevent,
# reintroduced one level down. Expressing "both, when both are present" needs
# a change to the module contract, not another line in this file.
#
# Until then the order below is the least-bad default: `automatic-css` is
# what a current install runs, so a single-packaging site (every site seen so
# far) always resolves correctly, and a dual-packaging site resolves to the
# 4.x one rather than the legacy one. That is a choice, not a solution.
acss_stack_candidates() {
  cat <<'EOF'
automatic-css
automaticcss-plugin
EOF
}
