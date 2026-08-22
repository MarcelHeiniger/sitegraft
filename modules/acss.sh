#!/usr/bin/env bash
# modules/acss.sh — graft module for Automatic.css (ACSS).
#
# docs/usage.md §5 shipped v1 WITHOUT this module, blocked on one thing: the
# plugin's folder name had never been verified against a real install, and
# guessing it would risk either failing to detect ACSS or mis-detecting it.
#
# Verified against a real site (Automatic.css 4.0.0-rc-1): the v4 plugin
# folder is `automaticcss-plugin`. That closes the blocker for v4.
#
# The pre-4.0 folder name is STILL unverified and is deliberately NOT guessed
# here — see acss_stack_candidates below. A site on ACSS 3.x will simply not
# be detected by this module, which is the safe failure: `plan` then leaves
# ACSS out of the stack diff and `graft`'s stack precondition can't vouch for
# it, exactly as it behaved before this module existed. That is strictly
# better than a wrong candidate silently matching the wrong folder.
#
# What a real ACSS install actually stores (verified, not assumed):
#   - NO custom post types
#   - NO custom database tables
#   - four wp_options, of which exactly ONE carries the configuration:
#       automatic_css_settings         <- the whole framework configuration
#       automatic_css_db_version       <- schema marker, never migrate
#       automatic_css_license_key      <- secret, never migrate
#       automatic_css_license_status   <- licensing state, never migrate
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
  jq -e '.plugins[]? | select(.name == "automaticcss-plugin")' "$1" >/dev/null 2>&1
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
# ONE candidate, most-preferred first, and only names that have actually been
# observed on a real install. The pre-4.0 folder name belongs on the line
# below this one as soon as somebody verifies it against a genuine ACSS 3.x
# site — until then, an unverified guess here is worse than a short list:
# inventory_resolve_slug returns the FIRST candidate present, so a wrong
# entry ordered ahead of the right one would resolve to a folder that is not
# ACSS, and graft would rsync that folder to B believing it had synced the
# stack.
acss_stack_candidates() {
  echo "automaticcss-plugin"
}
