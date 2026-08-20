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

# At least one of post_types / option_keys / tables below must exist (a
# module must claim at least one thing it protects — enforced at discovery
# time, see lib/modules.sh :: module_validate_contract). option_keys_exclude
# is an optional modifier of option_keys, not a standalone requirement.
# my_plugin_post_types() { printf 'my_cpt\n'; }
# my_plugin_option_keys() { printf 'my_plugin_settings\n'; }
# my_plugin_option_keys_exclude() { printf 'my_plugin_license_*\n'; }
# my_plugin_tables() { printf 'my_plugin_data\n'; }

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
