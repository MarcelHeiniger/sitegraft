#!/usr/bin/env bash
# lib/inventory.sh — read-only site introspection (phase: scan).

# Known "snippet" plugins whose mere active presence is itself a custom-code
# signal on B (§14) — a named constant rather than an array literal inline
# inside a jq program string, which is fragile to quote from the shell side
# (Kimi's review note) and harder to extend (adding one is a one-line change
# here instead of hunting for the jq filter that embeds it).
SITEGRAFT_SNIPPET_PLUGIN_SLUGS='["code-snippets","wpcode","insert-headers-and-footers"]'

# sq <string> — single-quote a string safely for embedding in a shell command
# line that will be re-parsed by another shell (e.g. the far end of an ssh
# connection). Replaces each ' with '\'' and wraps the whole thing in outer
# single quotes — the standard, correct way to shell-quote arbitrary content
# in POSIX sh/bash, including content that itself contains single quotes.
sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# wp_remote <alias: a|b> <wp-cli args...>
# Dispatches to SSH+wp-cli if SITE_<ALIAS>_SSH_HOST is set, else runs the local
# wp command (plain `wp`, or a wrapper like `ddev exec --raw -p <project> --
# wp`) directly against SITE_<ALIAS>_WP_PATH.
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
    require_cmd ssh || return 1
    # TODO(Task 2.3): SITE_<ALIAS>_SSH_KEY is parsed and whitelisted by
    # lib/profile.sh (design doc §5.2) but not consumed here yet — ssh is
    # invoked with no -i, relying entirely on the caller's own ssh-agent/
    # default-key setup. Wire it in as `ssh -i "$ssh_key" ...` once
    # interactive credential handling (Task 2.3) lands.
    # Every argument that will reach the REMOTE shell must be single-quoted
    # individually via sq() — building the remote command line by hand with
    # "$wp_cmd --path='$path' $*" (the previous version) was both an
    # injection risk and functionally broken: `wp eval` snippets containing
    # `;`, `$wpdb`, `->` etc. get re-parsed by the remote shell before wp-cli
    # ever sees them (a `;` ends the command early, `$wpdb` is expanded to
    # empty by the remote shell), silently corrupting exactly the
    # custom-code-signal detection queries §14's blocking gate depends on —
    # a bad query there fails open. Passing "$@" as separate argv elements
    # to ssh does NOT fix this on its own (ssh re-joins them into a single
    # string for the remote shell regardless), so each one is explicitly
    # single-quoted here before being joined.
    #
    # $wp_cmd itself is deliberately left UNQUOTED in the built string, same
    # as the local branch below: it may be a multi-word wrapper, and this is
    # meant to word-split remotely too.
    local remote_cmd="${wp_cmd} --path=$(sq "$path")"
    local arg
    for arg in "$@"; do
      remote_cmd="${remote_cmd} $(sq "$arg")"
    done
    run_or_echo ssh "$host" "$remote_cmd"
  else
    # $wp_cmd is deliberately unquoted here so it word-splits into separate
    # argv elements (e.g. "ddev exec -p my-site -- wp" -> 6 words). A quoted
    # "$wp_cmd" would try to exec a single binary literally named
    # "ddev exec -p my-site -- wp", which does not exist — dry-run mode never
    # exercises this branch (it only ever echoes "$*"), so this only surfaces
    # on real execution. None of sitegraft's own wp_cmd values contain spaces
    # within a single word, so plain word-splitting is safe here. Unlike the
    # ssh branch, "$@" is passed as real, separate argv elements straight to
    # exec — no re-quoting needed, there is no second shell in between.
    run_or_echo $wp_cmd --path="$path" "$@"
  fi
}

# graft/verify also need B's live table prefix (design doc §9.1/§9.4, finding A6) —
# defined here since it's a read-only wp-cli query, alongside the rest of scan.
inventory_table_prefix() {
  local alias_lc="$1"
  wp_remote "$alias_lc" eval 'global $wpdb; echo $wpdb->prefix;'
}

# design doc §0 point 11 / §6.1: is A's navigation a dynamic wp:page-list
# block (no hardcoded post IDs)? Never assumed — always verified by
# inspecting the actual content of every wp_navigation post found. A-only by
# nature (§6.1: B's navigation, whatever form it takes, is either being
# replaced or is none of sitegraft's business — §13). Returns the literal
# text "true"/"false" (valid JSON on its own) so callers can --argjson it
# directly; on a query failure, callers treat that as null/unknown rather
# than silently assuming false.
inventory_nav_uses_dynamic_page_list() {
  local alias_lc="$1"
  wp_remote "$alias_lc" eval '
$navs = get_posts(array("post_type" => "wp_navigation", "numberposts" => -1, "post_status" => "any"));
$dynamic = false;
foreach ($navs as $n) {
  if (strpos($n->post_content, "wp:page-list") !== false) { $dynamic = true; break; }
}
echo json_encode($dynamic);
'
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
  # `wp theme list --format=json`'s real field for the theme slug is "name"
  # (verified live against a real install) — design doc §6.1/§12 documents
  # the scan schema as active_theme.stylesheet, and inventory_stack_diff
  # (below) reads that field, so it is added here as an alias alongside the
  # original "name" (kept, not overwritten — no information lost). Without
  # this, inventory_stack_diff always compared "" == "" and never detected
  # an actual theme mismatch — undetected until this was checked directly
  # against a real DDEV scan rather than only fabricated test JSON.
  active_theme=$(wp_remote "$alias_lc" theme list --status=active --format=json \
    | jq '(.[0] // {}) | if has("name") then . + {stylesheet: .name} else . end')
  menus=$(wp_remote "$alias_lc" menu list --format=json 2>/dev/null || echo '[]')

  local custom_code_signals='{}' custom_code_detected=false
  if [ "$alias_lc" = "b" ]; then
    custom_code_signals=$(inventory_custom_code_signals "$alias_lc")
    inventory_custom_code_detected "$custom_code_signals" && custom_code_detected=true
  fi

  # A-only (§0 point 11) — null/unknown on B, and null on A if the query
  # itself fails (never silently assumed false).
  local nav_dynamic='null'
  if [ "$alias_lc" = "a" ]; then
    nav_dynamic=$(inventory_nav_uses_dynamic_page_list "$alias_lc" 2>&1) || {
      log_warn "could not determine whether site A's navigation uses a dynamic page-list block — recording nav_uses_dynamic_page_list as unknown (null): ${nav_dynamic}"
      nav_dynamic='null'
    }
    # Guard against a non-boolean/garbled result being embedded as JSON.
    case "$nav_dynamic" in
      true|false) : ;;
      *) nav_dynamic='null' ;;
    esac
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
    --argjson nav_uses_dynamic_page_list "$nav_dynamic" \
    '{
      post_types: $post_types,
      options: $options,
      tables: $tables,
      plugins: $plugins,
      active_theme: $active_theme,
      classic_menus_detected: ([$menus[]? | select((.count // 0) > 0)] | length > 0),
      classic_menu_names: [$menus[]? | select((.count // 0) > 0) | .name],
      custom_code_signals: $custom_code_signals,
      custom_code_detected: $custom_code_detected,
      nav_uses_dynamic_page_list: $nav_uses_dynamic_page_list
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
# analysis. The extensible slug list lives in SITEGRAFT_SNIPPET_PLUGIN_SLUGS.
#
# M3, fail-CLOSED on error: §14 gates a blocking confirmation before `plan`
# writes a manifest — a wp-cli query that errors must never be silently read
# as "signal absent" (the previous version did exactly that: e.g.
# `wp_remote ... 2>/dev/null || echo "$name"` turned any error into "not a
# child theme"). Every query below is checked individually; a failure adds
# that signal's name to unknown_signals instead of guessing a default, and
# inventory_custom_code_detected treats any unknown signal as detected —
# the gate fires rather than silently passing through on a query it could
# not actually verify.
inventory_custom_code_signals() {
  local alias_lc="$1"
  local name template fn_php_raw mu_plugins_raw plugins_json
  local child_theme=false fn_php='{"exists":false}' mu_plugins='[]' snippet_plugins='[]'
  local unknown='[]'

  if ! name=$(wp_remote "$alias_lc" theme list --status=active --field=name 2>&1); then
    log_warn "could not determine the active theme on site ${alias_lc} — all custom-code signals recorded as unknown (fail-safe, design doc §14): ${name}"
    jq -n '{child_theme:false,functions_php:{exists:false},mu_plugins:[],snippet_plugins_detected:[],unknown_signals:["active_theme"]}'
    return 0
  fi

  if template=$(wp_remote "$alias_lc" theme get "$name" --field=template 2>&1); then
    [ "$template" != "$name" ] && child_theme=true
  else
    log_warn "could not read the theme/template relationship for '${name}' on site ${alias_lc} — recording child_theme as unknown (fail-safe, design doc §14): ${template}"
    unknown=$(echo "$unknown" | jq -c '. + ["child_theme"]')
  fi

  if fn_php_raw=$(wp_remote "$alias_lc" eval 'if (file_exists($f = get_stylesheet_directory()."/functions.php")) { echo json_encode(["exists"=>true,"bytes"=>filesize($f),"lines"=>count(file($f))]); } else { echo json_encode(["exists"=>false]); }' 2>&1) \
    && echo "$fn_php_raw" | jq . >/dev/null 2>&1; then
    fn_php="$fn_php_raw"
  else
    log_warn "could not check functions.php on site ${alias_lc} — recording functions_php as unknown (fail-safe, design doc §14): ${fn_php_raw}"
    unknown=$(echo "$unknown" | jq -c '. + ["functions_php"]')
  fi

  if mu_plugins_raw=$(wp_remote "$alias_lc" eval 'echo json_encode(array_map("basename", glob(WP_CONTENT_DIR."/mu-plugins/*.php") ?: []));' 2>&1) \
    && echo "$mu_plugins_raw" | jq . >/dev/null 2>&1; then
    mu_plugins="$mu_plugins_raw"
  else
    log_warn "could not list mu-plugins on site ${alias_lc} — recording mu_plugins as unknown (fail-safe, design doc §14): ${mu_plugins_raw}"
    unknown=$(echo "$unknown" | jq -c '. + ["mu_plugins"]')
  fi

  if plugins_json=$(wp_remote "$alias_lc" plugin list --format=json 2>&1) \
    && echo "$plugins_json" | jq . >/dev/null 2>&1; then
    # status=active: an installed-but-inactive snippet plugin is not
    # injecting anything at runtime, so it is not itself a signal.
    snippet_plugins=$(echo "$plugins_json" | jq -c \
      --argjson names "$SITEGRAFT_SNIPPET_PLUGIN_SLUGS" \
      '[.[] | select(.status == "active") | select(.name as $n | $names | index($n)) | .name]')
  else
    log_warn "could not list plugins on site ${alias_lc} — recording snippet_plugins as unknown (fail-safe, design doc §14): ${plugins_json}"
    unknown=$(echo "$unknown" | jq -c '. + ["snippet_plugins"]')
  fi

  jq -n \
    --argjson child_theme "$child_theme" \
    --argjson fn_php "$fn_php" \
    --argjson mu_plugins "$mu_plugins" \
    --argjson snippet_plugins "$snippet_plugins" \
    --argjson unknown_signals "$unknown" \
    '{child_theme: $child_theme, functions_php: $fn_php, mu_plugins: $mu_plugins, snippet_plugins_detected: $snippet_plugins, unknown_signals: $unknown_signals}'
}

# Pure: given a custom_code_signals object (live or fabricated), is any signal
# raised? This is the half of the feature that's actually unit-testable.
# Any unknown_signals entry counts as raised (M3: fail closed, never silently
# treat "we could not check" as "nothing was found").
inventory_custom_code_detected() {
  local signals="$1"
  [ "$(echo "$signals" | jq '
    (.child_theme == true)
    or (.functions_php.exists == true)
    or ((.mu_plugins // []) | length > 0)
    or ((.snippet_plugins_detected // []) | length > 0)
    or ((.unknown_signals // []) | length > 0)
  ')" = "true" ]
}

phase_scan() {
  local profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        # M2: without this arity check, "--profile" as the LAST argument
        # dereferences a missing $2 — under bin/sitegraft's `set -u` this is
        # a fatal "unbound variable" error (verified live), and that
        # specific bash 3.2 error class reports $?=0 to any EXIT trap
        # regardless of what it does (see the note in lib/core.sh), so the
        # process used to exit 0 despite never running. An explicit arity
        # check turns it into a normal, fully-propagated `return 1` instead.
        if [ $# -lt 2 ]; then
          log_error "--profile requires a value"
          return 1
        fi
        profile="$2"; shift 2 ;;
      --dry-run)
        # M2: the plan requires --dry-run to work as a flag everywhere, not
        # only via the SITEGRAFT_DRY_RUN env var.
        SITEGRAFT_DRY_RUN=1
        shift ;;
      *) log_error "unknown flag for scan: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "scan requires --profile <name>"; return 1; }

  if is_dry_run; then
    # M6: run_or_echo prints "[dry-run] ..." text instead of running the
    # command, which jq --argjson then fails to parse as JSON (verified
    # live: exit 5, "Invalid JSON text passed to --argjson"). scan is
    # strictly read-only (design doc §6.1: no writes to A or B, freely
    # re-runnable) — there is nothing on A or B for --dry-run to protect
    # here. Chosen fix: scan ignores --dry-run entirely and always runs its
    # real (harmless) read-only queries, rather than half-printing planned
    # commands and half-crashing on the jq step.
    log_info "scan is strictly read-only (design doc §6.1) — --dry-run has no writes to skip on A or B; running the real read-only queries as usual"
    SITEGRAFT_DRY_RUN=0
  fi

  profile_load "$profile" || return 1

  # M4: scan-*.json holds a full `wp option list` dump — this can include
  # license keys, SMTP tokens, or anything else a plugin stores as an
  # option. Neither the run directory nor the files in it may be
  # group/world-readable. umask first (belt) so mkdir/redirection default
  # to owner-only, then explicit chmod (suspenders) so this holds
  # regardless of the caller's ambient umask.
  local prev_umask
  prev_umask=$(umask)
  umask 077

  local run_dir="${SITEGRAFT_STATE_DIR}/${profile}-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$run_dir"
  chmod 700 "$run_dir"
  inventory_scan_site a "${run_dir}/scan-a.json"
  inventory_scan_site b "${run_dir}/scan-b.json"
  chmod 600 "${run_dir}/scan-a.json" "${run_dir}/scan-b.json"

  umask "$prev_umask"

  if jq -e '.classic_menus_detected == true' "${run_dir}/scan-a.json" >/dev/null 2>&1; then
    log_warn "site A has classic nav menu(s) with items: $(jq -r '.classic_menu_names | join(", ")' "${run_dir}/scan-a.json") — sitegraft v1 does not migrate classic menu assignments (design doc §13)"
  fi

  log_info "scan complete: ${run_dir}"
}
