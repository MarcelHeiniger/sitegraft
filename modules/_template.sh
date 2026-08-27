#!/usr/bin/env bash
# modules/_template.sh — copy this file to modules/<your-plugin>.sh to add support
# for a new plugin. This file itself is never loaded (see lib/modules.sh guard).
#
# Function prefix = filename without .sh, hyphens replaced with underscores.
# modules/my-plugin.sh -> functions prefixed my_plugin_

# Required: human-readable name, shown in interactive prompts.
# my_plugin_name() { echo "My Plugin"; }

# Required: does $1 (a scan-*.json path) show this plugin/domain present?
# "name" matches wp-cli's own `plugin list` field (which is also the plugin's
# real folder name) — the same field inventory_stack_diff resolves against
# (design doc §3.2, §12).
# my_plugin_detect() { jq -e '.plugins[] | select(.name == "my-plugin")' "$1" >/dev/null 2>&1; }

# At least one of post_types / option_keys / tables below — or one of their
# _dynamic counterparts further down — must exist (a module must claim at
# least one thing it protects; enforced at discovery time, see
# lib/modules.sh :: module_validate_contract).
# my_plugin_post_types() { printf 'my_cpt\n'; }
# my_plugin_option_keys() { printf 'my_plugin_settings\n'; }
# my_plugin_tables() { printf 'my_plugin_data\n'; }

# Optional: the same three claims, computed from the scan instead of listed.
# Use these for names that are only knowable after `scan` — the active
# theme's `theme_mods_<slug>` (modules/core-wp.sh does exactly this), or post
# types a plugin declares in its own settings (modules/etch.sh, from
# `etch_cpts`). One argument: the path to a scan-*.json. Static and dynamic
# lists are merged, and every name lands in `plan`'s selection individually,
# so the operator can deselect any single one.
#
# Work from the scan file alone — `plan` never touches the live sites, so
# calling wp/ssh from here is not supported.
#
# EXIT STATUS IS PART OF THE ANSWER. Printing nothing and returning 0 means
# "this module claims nothing here", and is fine. Returning non-zero means
# "I could not tell", and stops the whole run with a message naming this
# function — never return an empty list to paper over a failure, since the
# two would then be indistinguishable and the run would quietly migrate less
# than it says. See docs/decisions/0007-module-dynamic-selections.md.
# my_plugin_post_types_dynamic() { local scan_json="$1"; jq -r '...' "$scan_json"; }
# my_plugin_option_keys_dynamic() { local scan_json="$1"; jq -r '...' "$scan_json"; }
# my_plugin_tables_dynamic() { local scan_json="$1"; jq -r '...' "$scan_json"; }

# Optional: shell globs, one per line, carved out of this module's option
# keys — static and dynamic alike — before anything reaches the manifest.
# The manifest is the only thing graft and verify ever read, so an excluded
# key is excluded everywhere.
#
# This makes "return the whole prefix, exclude the secrets" a safe way to
# write a module:
#
#   my_plugin_option_keys_dynamic() {
#     jq -r '.options[]?.option_name | select(startswith("my_plugin_"))' "$1"
#   }
#   my_plugin_option_keys_exclude() { printf 'my_plugin_license_*\nmy_plugin_*_api_key\n'; }
#
# If this function itself fails, `plan` refuses to continue rather than
# migrating the keys it was there to hold back.
# my_plugin_option_keys_exclude() { printf 'my_plugin_license_*\n'; }

# Optional: names, among this module's OWN option_keys (static or dynamic),
# that DEFINE a post type this module's plugin registers dynamically at
# runtime by reading that option — e.g. Etch's `etch_cpts`
# (modules/etch.sh). If your plugin's post types are registered the
# ordinary way (a `register_post_type()` call in the plugin's own PHP,
# never keyed off a wp_options value), you don't need this function at all.
#
# WHY THIS EXISTS: a module can already migrate both the post type's
# CONTENT (`_post_types`/`_post_types_dynamic`) and its DEFINITION (the
# option, via `_option_keys`), but `graft_migrate_options` — which carries
# every option, this one included — runs AFTER the WXR import. If that
# option is what makes B's WordPress boot register the type in the first
# place, B's importer sees it as unknown for the entire import and every
# post of it is skipped, with the type ending up registered and empty
# (issue #16). Naming the option here migrates it BEFORE the import
# instead, through the exact same guarded path graft_migrate_options
# itself uses (domain remap, the "A has no such key" skip) — see
# graft_migrate_post_type_defining_options (lib/graft.sh) for the
# mechanism, and modules/etch.sh's own etch_post_type_defining_option_keys
# for a real, live-site-verified example.
#
# Every name returned here MUST also be returned by `_option_keys` (or
# `_option_keys_dynamic`) — this narrows an existing claim (like
# `_option_keys_exclude`), it does not establish one of its own. No
# `_dynamic` counterpart: which option defines a type is fixed knowledge
# about the plugin's own code, not something that depends on any
# particular site's scan.
# my_plugin_post_type_defining_option_keys() { printf 'my_plugin_cpts\n'; }

# Optional: run after WXR import + generic remaps, for module-specific fixups.
# Called unconditionally, including under `--dry-run` (design doc §3.2) — wrap
# every write through $wp_cmd_b in lib/core.sh's run_or_echo (already sourced
# by the time this runs), never call $wp_cmd_b directly for a mutating
# subcommand. See modules/motopress.sh.example's post_import for a full
# worked example.
# my_plugin_post_import() { local state_dir="$1" id_map_tsv="$2" wp_cmd_b="$3"; }

# Optional: this module's plugin is also a §12 stack-sync component (like etch
# or acss) — one candidate slug per line, most-preferred/current first. A
# plugin's real folder name can change across versions (see the ACSS v4 case,
# design doc §3.4) — detection may match multiple candidate slugs; paths
# always come from scan resolution, never from the module. Omit this function
# entirely if the module isn't a stack-syncable plugin (most won't be).
# my_plugin_stack_candidates() { printf 'my-plugin\nmy-plugin-legacy-slug\n'; }
