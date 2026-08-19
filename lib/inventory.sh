#!/usr/bin/env bash
# lib/inventory.sh — read-only site introspection (phase: scan).

# wp_remote <alias: a|b> <wp-cli args...>
# Dispatches to SSH+wp-cli if SITE_<ALIAS>_SSH_HOST is set, else runs the local
# wp command (plain `wp`, or a wrapper like `ddev wp`) directly against
# SITE_<ALIAS>_WP_PATH.
wp_remote() {
  local alias_lc="$1"; shift
  local alias_uc; alias_uc=$(printf '%s' "$alias_lc" | tr '[:lower:]' '[:upper:]')
  local host_var="SITE_${alias_uc}_SSH_HOST"
  local path_var="SITE_${alias_uc}_WP_PATH"
  local cmd_var="SITE_${alias_uc}_WP_CMD"
  local host="${!host_var:-}"
  local path="${!path_var:?missing ${path_var}}"
  local wp_cmd="${!cmd_var:-wp}"

  if [ -n "$host" ]; then
    run_or_echo ssh "$host" "$wp_cmd --path='$path' $*"
  else
    # $wp_cmd is deliberately unquoted here so it word-splits into separate
    # argv elements (e.g. "ddev exec -p my-site -- wp" -> 6 words). A quoted
    # "$wp_cmd" would try to exec a single binary literally named
    # "ddev exec -p my-site -- wp", which does not exist — dry-run mode never
    # exercises this branch (it only ever echoes "$*"), so this only surfaces
    # on real execution. None of sitegraft's own wp_cmd values contain spaces
    # within a single word, so plain word-splitting is safe here.
    run_or_echo $wp_cmd --path="$path" "$@"
  fi
}

# graft/verify also need B's live table prefix (design doc §9.1/§9.4, finding A6) —
# defined here since it's a read-only wp-cli query, alongside the rest of scan.
inventory_table_prefix() {
  local alias_lc="$1"
  wp_remote "$alias_lc" eval 'global $wpdb; echo $wpdb->prefix;'
}

inventory_scan_site() {
  local alias_lc="$1" out_json="$2"
  log_info "scanning site '${alias_lc}' -> ${out_json}"
  local post_types options tables plugins active_theme menus
  post_types=$(wp_remote "$alias_lc" post-type list --format=json)
  options=$(wp_remote "$alias_lc" option list --format=json)
  # `wp db tables` has no --format=json (only "list" or "csv", verified against
  # a real wp-cli install) — request the default newline-separated list and
  # build the JSON array ourselves.
  tables=$(wp_remote "$alias_lc" db tables --format=list --all-tables-with-prefix \
    | jq -R -s -c 'split("\n") | map(select(length > 0))')
  plugins=$(wp_remote "$alias_lc" plugin list --format=json)
  active_theme=$(wp_remote "$alias_lc" theme list --status=active --format=json | jq '.[0] // {}')
  menus=$(wp_remote "$alias_lc" menu list --format=json 2>/dev/null || echo '[]')

  local custom_code_signals='{}' custom_code_detected=false
  if [ "$alias_lc" = "b" ]; then
    custom_code_signals=$(inventory_custom_code_signals "$alias_lc")
    inventory_custom_code_detected "$custom_code_signals" && custom_code_detected=true
  fi

  jq -n \
    --argjson post_types "$post_types" \
    --argjson options "$options" \
    --argjson tables "$tables" \
    --argjson plugins "$plugins" \
    --argjson active_theme "$active_theme" \
    --argjson menus "$menus" \
    --argjson custom_code_signals "$custom_code_signals" \
    --argjson custom_code_detected "$custom_code_detected" \
    '{
      post_types: $post_types,
      options: $options,
      tables: $tables,
      plugins: $plugins,
      active_theme: $active_theme,
      classic_menus_detected: ($menus | length > 0),
      classic_menu_names: [$menus[]?.name],
      custom_code_signals: $custom_code_signals,
      custom_code_detected: $custom_code_detected
    }' \
    > "$out_json"
}

# design doc §3.2's rule: the ONLY function allowed to turn a module's
# candidate-slug list into a "this is the real slug" answer, by checking which
# candidate the site's own `plugin list` actually contains. Preference order
# from the module's list is respected — first match wins.
inventory_resolve_slug() {
  local scan_json="$1" candidates="$2"
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if jq -e --arg c "$c" '.plugins[]? | select(.name == $c)' "$scan_json" >/dev/null 2>&1; then
      echo "$c"
      return 0
    fi
  done <<< "$candidates"
}

# design doc §12 (Marcel's revision of review finding B1, amended for the ACSS
# v4 plugin-folder-rename case, §3.4): per-component diff between A's and B's
# rendering stack. `theme` is compared directly (a site has exactly one active
# theme, no candidate-slug ambiguity). Every other component comes from a
# module declaring <mod>_stack_candidates (§3.2) — never a slug hardcoded here.
# A component's real slug can legitimately differ between A and B (that's
# exactly what "absent on B" and "renamed folder on B" both look like); this
# function resolves each site's own real slug independently via
# inventory_resolve_slug before comparing, so it correctly flags a mismatch
# even when both sites DO have the plugin, just under different real names.
inventory_stack_diff() {
  local scan_a="$1" scan_b="$2"
  local diff='{}'

  local theme_a theme_b theme_ver_a theme_ver_b
  theme_a=$(jq -r '.active_theme.stylesheet // ""' "$scan_a")
  theme_b=$(jq -r '.active_theme.stylesheet // ""' "$scan_b")
  theme_ver_a=$(jq -r '.active_theme.version // ""' "$scan_a")
  theme_ver_b=$(jq -r '.active_theme.version // ""' "$scan_b")
  if [ "$theme_a" != "$theme_b" ] || [ "$theme_ver_a" != "$theme_ver_b" ]; then
    diff=$(echo "$diff" | jq \
      --arg sa "$theme_a" --arg sb "$theme_b" --arg va "$theme_ver_a" --arg vb "$theme_ver_b" \
      '.theme = {
        slug_a: ($sa | if length > 0 then . else null end),
        slug_b: ($sb | if length > 0 then . else null end),
        version_a: $va, version_b: $vb
      }')
  fi

  local mod
  for mod in $SITEGRAFT_MODULES; do
    module_has_fn "$mod" stack_candidates || continue
    local candidates slug_a slug_b ver_a ver_b
    candidates=$(module_call "$mod" stack_candidates)
    slug_a=$(inventory_resolve_slug "$scan_a" "$candidates")
    slug_b=$(inventory_resolve_slug "$scan_b" "$candidates")
    ver_a=""; [ -n "$slug_a" ] && ver_a=$(jq -r --arg s "$slug_a" '.plugins[]? | select(.name==$s) | .version // ""' "$scan_a")
    ver_b=""; [ -n "$slug_b" ] && ver_b=$(jq -r --arg s "$slug_b" '.plugins[]? | select(.name==$s) | .version // ""' "$scan_b")
    if [ "$slug_a" = "$slug_b" ] && [ "$ver_a" = "$ver_b" ]; then
      continue
    fi
    diff=$(echo "$diff" | jq \
      --arg m "$mod" --arg sa "$slug_a" --arg sb "$slug_b" --arg va "$ver_a" --arg vb "$ver_b" \
      '.[$m] = {
        slug_a: ($sa | if length > 0 then . else null end),
        slug_b: ($sb | if length > 0 then . else null end),
        version_a: $va, version_b: $vb
      }')
  done

  echo "$diff"
}

# Convenience wrapper for call sites that only need a yes/no answer.
inventory_stack_matches() {
  local scan_a="$1" scan_b="$2"
  [ "$(inventory_stack_diff "$scan_a" "$scan_b" | jq 'length')" = "0" ]
}

# design doc §6.1/§14: shallow, B-only signals — no code parsing, no static
# analysis. The extensible slug list lives here, in one place, so adding a
# newly-encountered snippet plugin later is a one-line change.
inventory_custom_code_signals() {
  local alias_lc="$1"
  local name template child_theme fn_php mu_plugins plugins_json snippet_plugins

  name=$(wp_remote "$alias_lc" theme list --status=active --field=name)
  template=$(wp_remote "$alias_lc" theme get "$name" --field=template 2>/dev/null || echo "$name")
  if [ "$template" != "$name" ]; then child_theme=true; else child_theme=false; fi

  fn_php=$(wp_remote "$alias_lc" eval 'if (file_exists($f = get_stylesheet_directory()."/functions.php")) { echo json_encode(["exists"=>true,"bytes"=>filesize($f),"lines"=>count(file($f))]); } else { echo json_encode(["exists"=>false]); }')
  mu_plugins=$(wp_remote "$alias_lc" eval 'echo json_encode(array_map("basename", glob(WP_CONTENT_DIR."/mu-plugins/*.php") ?: []));')

  plugins_json=$(wp_remote "$alias_lc" plugin list --format=json)
  snippet_plugins=$(echo "$plugins_json" | jq -c \
    '[.[] | select(.name as $n | ["code-snippets","wpcode","insert-headers-and-footers"] | index($n)) | .name]')

  jq -n \
    --argjson child_theme "$child_theme" \
    --argjson fn_php "$fn_php" \
    --argjson mu_plugins "$mu_plugins" \
    --argjson snippet_plugins "$snippet_plugins" \
    '{child_theme: $child_theme, functions_php: $fn_php, mu_plugins: $mu_plugins, snippet_plugins_detected: $snippet_plugins}'
}

# Pure: given a custom_code_signals object (live or fabricated), is any signal
# raised? This is the half of the feature that's actually unit-testable.
inventory_custom_code_detected() {
  local signals="$1"
  [ "$(echo "$signals" | jq '
    (.child_theme == true)
    or (.functions_php.exists == true)
    or ((.mu_plugins // []) | length > 0)
    or ((.snippet_plugins_detected // []) | length > 0)
  ')" = "true" ]
}

phase_scan() {
  local profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      *) log_error "unknown flag for scan: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "scan requires --profile <name>"; return 1; }

  profile_load "$profile"
  local run_dir="${SITEGRAFT_STATE_DIR}/${profile}-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$run_dir"
  inventory_scan_site a "${run_dir}/scan-a.json"
  inventory_scan_site b "${run_dir}/scan-b.json"

  if jq -e '.classic_menus_detected == true' "${run_dir}/scan-a.json" >/dev/null 2>&1; then
    log_warn "site A has classic nav menu(s) with items: $(jq -r '.classic_menu_names | join(", ")' "${run_dir}/scan-a.json") — sitegraft v1 does not migrate classic menu assignments (design doc §13)"
  fi

  log_info "scan complete: ${run_dir}"
}
