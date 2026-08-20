#!/usr/bin/env bash
# modules/etch.sh — graft module for Etch (page builder).
#
# Step 6 self-review finding (design doc §3.3 vs. code): this file is
# specified in full, verbatim, in the design doc's §3.3 "Concrete example"
# section — but no plan Task ever actually created it under modules/ (Task
# 4.1 only wired the generic graft_sync_stack/graft_check_stack_precondition
# machinery, not any specific module file; see that task's own "Files"
# list). Without it, `modules_discover` never registers "etch" at all, so a
# real Etch site's content never gets auto-detected into `plan`'s migrate
# defaults — a real operator would have had to hand-write a manifest.json to
# get Etch content migrated, bypassing the entire scan/plan workflow this
# tool exists to provide. Content below is unchanged from the design doc
# (already reviewed there) — this is purely "make it a real file", not new
# design.
#
# Safe to add now, verified against the DDEV harness: etch_detect checks
# `.plugins[]` for a plugin literally named "etch" — the harness's site A
# simulates Etch content via a mu-plugin (fake-etch-cpts.php registering
# etch_cfs), never a real "etch" entry in `wp plugin list`, so this module
# registering does not change what plan_defaults picks up there. The
# harness's own graft run continues to use its hand-written manifest.json
# (its own documented convention — manifest keys are arbitrary strings from
# graft's perspective, see the harness's comment above that manifest).

etch_name() { echo "Etch"; }

etch_detect() {
  # $1 = path to a scan-*.json produced by `sitegraft scan`
  jq -e '.plugins[] | select(.name == "etch")' "$1" >/dev/null 2>&1
}

etch_post_types() {
  cat <<'EOF'
etch_cfs
etch_cpts
etch_loops
EOF
}

etch_option_keys() {
  cat <<'EOF'
etch_css_toolbar_values
etch_global_stylesheets
etch_settings
etch_styles
EOF
}

etch_option_keys_exclude() {
  cat <<'EOF'
etch_license_*
etch_db_version
EOF
}

# etch_stack_candidates: NOT present in the design doc's §3.3 code block
# (which shows only name/detect/post_types/option_keys/option_keys_exclude)
# — added here as a judgment call worth a second look (flagged in the PR
# report), not a verbatim copy like the rest of this file. Reasoning: §12 is
# explicit that Etch itself IS one of the three things a §12 stack-mismatch
# precondition should catch — "For each stack component (active theme, Etch,
# ACSS)..." — and without this function, `inventory_stack_diff` (lib/
# inventory.sh) never includes Etch in its per-component diff at all, so
# `graft` could migrate etch_cfs/etch_cpts content onto a B that doesn't
# even have the Etch plugin active, silently producing unrenderable content
# — exactly the failure §12 exists to prevent for the theme/ACSS case, just
# not wired for Etch itself. Unlike ACSS's legacy-slug placeholder (§3.4,
# deliberately left unresolved — a real unknown, guessing would be unsafe),
# Etch's plugin folder name is not ambiguous: it's the exact same literal
# "etch" string etch_detect above already hardcodes and searches
# `.plugins[]` for. Declaring it here is that same known-good string, not a
# guess at unverified real-world data. Verified against the DDEV harness:
# harness's site A only ever simulates Etch content via a mu-plugin
# (fake-etch-cpts.php), never a real "etch" entry in `wp plugin list`, so
# both sites resolve slug_a=slug_b="" here and inventory_stack_diff's own
# equal-and-empty check skips adding a diff entry — this addition changes
# nothing about the harness's existing behavior.
etch_stack_candidates() {
  echo "etch"
}
