#!/usr/bin/env bash
# lib/inventory.sh — read-only site introspection (phase: scan).

# Known "snippet" plugins whose mere active presence is itself a custom-code
# signal on B (§14) — a named constant rather than an array literal inline
# inside a jq program string, which is fragile to quote from the shell side
# (Kimi's review note) and harder to extend (adding one is a one-line change
# here instead of hunting for the jq filter that embeds it).
# `wpcodebox2` added after a real target site was found running WPCodeBox 2
# with this list not matching it: scan recorded snippet_plugins_detected as
# [] on a site where a snippet manager was active. §14's gate still fired
# there, but only because that site independently had mu-plugins — on a B
# whose sole custom-code signal is WPCodeBox, plan would have frozen a
# manifest with no warning at all.
SITEGRAFT_SNIPPET_PLUGIN_SLUGS='["code-snippets","wpcode","insert-headers-and-footers","wpcodebox2"]'

# sq <string> — single-quote a string safely for embedding in a shell command
# line that will be re-parsed by another shell (e.g. the far end of an ssh
# connection). Replaces each ' with '\'' and wraps the whole thing in outer
# single quotes — the standard, correct way to shell-quote arbitrary content
# in POSIX sh/bash, including content that itself contains single quotes.
#
# MINOR-1 (Viktor, second review round): pure bash parameter-substitution,
# no subshell/pipe. The earlier `printf ... | sed ...` version ran the
# input through a $(...) command substitution, which unconditionally
# strips ALL trailing newlines from its output — a fidelity bug in a
# security-relevant quoting helper (not exploitable today, since nothing
# currently single-quotes a value with a meaningful trailing newline, but
# a trap for whatever calls this next). $q/$bq hold the quote/backslash
# characters as data so this reads clearly without a wall of backslashes.
sq() {
  local s="$1"
  local q="'"
  # shellcheck disable=SC1003 # not an unfinished escape: bq deliberately holds one literal backslash character as data (see the comment above sq() for why)
  local bq='\'
  s="${s//$q/${q}${bq}${q}${q}}"
  printf "'%s'" "$s"
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
  local key_var="SITE_${alias_uc}_SSH_KEY"
  local host="${!host_var:-}"
  # `${!path_var:?msg}` looks like a safe guard but is NOT one on this bash
  # version (verified live, second review round): that fatal parameter-
  # expansion error reports $?=0 to any EXIT trap regardless of what the
  # trap does — same bash 3.2 quirk documented in lib/core.sh — so a
  # profile missing this key used to make the whole process exit 0 as if
  # nothing were wrong. profile_load's required-key check (lib/profile.sh)
  # is the primary defense; this is the belt-and-suspenders fallback for a
  # future caller that reaches wp_remote without going through it, using an
  # explicit check + return 1 instead, since that failure class propagates
  # correctly (verified — see lib/core.sh's M1 fix and its tests).
  local path="${!path_var:-}"
  if [ -z "$path" ]; then
    log_error "missing ${path_var}"
    return 1
  fi
  local wp_cmd="${!cmd_var:-wp}"

  if [ -n "$host" ]; then
    require_cmd ssh || return 1
    local ssh_key="${!key_var:-}"
    # Step 6 self-review (design doc §5.2 vs. code): SITE_<ALIAS>_SSH_KEY was
    # parsed and whitelisted by lib/profile.sh, and documented in §5.2 as a
    # real credential an operator can set — but this function silently
    # ignored it, always relying on the caller's own ssh-agent/default-key
    # setup regardless. Not a cosmetic gap: an operator who deliberately set
    # SITE_A_SSH_KEY (e.g. a per-host deploy key, distinct from their normal
    # default identity) would have that choice silently discarded, with
    # `ssh` falling back to whatever key it picks by default instead —
    # wrong, or simply failing to authenticate, with no indication why.
    # Fixed here rather than left for the still-undone interactive-prompt
    # half of §5.2 (part (b), file-based-only for now — see docs/status.md
    # for that documented, deliberately deferred gap): this is the file-path
    # (a) case, already fully wired everywhere else, just never reaching
    # ssh's own argv.
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
    local remote_cmd
    remote_cmd="${wp_cmd} --path=$(sq "$path")"
    local arg
    for arg in "$@"; do
      remote_cmd="${remote_cmd} $(sq "$arg")"
    done
    # `--` before the positional args (MINOR-4, verified live): without it,
    # a SITE_*_SSH_HOST value starting with "-" (e.g.
    # "-oProxyCommand=...") was only accidentally rejected today, because
    # profile-sourced hosts happen to contain characters ssh's own option
    # parser doesn't like — that is not a real barrier. `ssh -- "$host"
    # ...` makes ssh treat everything after `--` as positional, so a
    # hostile-looking host string is parsed as a (rejected) literal
    # hostname instead of as an option, while legitimate hosts are
    # completely unaffected.
    #
    # `-i "$ssh_key"` BEFORE `--` (an option, not a positional) only when
    # SITE_<ALIAS>_SSH_KEY was actually set — an empty/unset key means "use
    # ssh's own default identity resolution", not "pass -i with an empty
    # argument" (ssh would reject that outright). No array needed for this
    # one optional flag (this codebase avoids bash arrays entirely so far,
    # bash 3.2 target or not) — a plain if/else with the flag inlined is
    # just as clear here.
    if [ -n "$ssh_key" ]; then
      run_or_echo ssh -i "$ssh_key" -- "$host" "$remote_cmd"
    else
      run_or_echo ssh -- "$host" "$remote_cmd"
    fi
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
    # shellcheck disable=SC2086 # intentionally unquoted: wp_cmd may be a multi-word wrapper and must word-split (see comment above)
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

# inventory_check_path_topology <alias: a|b> — refuse, at scan time, the one
# site shape sitegraft cannot drive: reachable over SSH, but with wp-cli
# running inside a container on the far end.
#
# wp_remote supports exactly two shapes — SSH (wp-cli on the SSH host, same
# paths rsync uses) and local-with-wrapper (container path indirection handled
# explicitly). A remote containerized site is neither, and it does not fail
# usefully: `wp export --dir=/tmp/...` writes inside the container while the
# pull reads the SSH host's /tmp, so the export comes back EMPTY and the graft
# reports success having moved nothing. For a tool people run against their
# clients' sites, that silent version is the real defect — worse than the
# missing topology itself.
#
# Detected by testing the INVARIANT rather than the shape of the profile: is
# SITE_<A>_WP_PATH visible both to wp-cli and to the SSH host's own
# filesystem? A profile-shape heuristic ("SSH plus a wrapper means refuse")
# would reject a perfectly valid setup — `sudo -u www-data wp` behind SSH is
# a wrapper whose paths match just fine.
#
#   wp-cli answers, host cannot see the path  -> containerized far end, refuse
#   wp-cli does not answer                    -> the path is wrong, refuse
#   both agree                                -> supported, proceed
#
# Sites with no SSH_HOST are the local-with-wrapper case, which IS supported,
# and are skipped.
inventory_check_path_topology() {
  local alias_lc="$1"
  local alias_uc; alias_uc=$(printf '%s' "$alias_lc" | tr '[:lower:]' '[:upper:]')
  local host_var="SITE_${alias_uc}_SSH_HOST"
  local path_var="SITE_${alias_uc}_WP_PATH"
  local key_var="SITE_${alias_uc}_SSH_KEY"
  local host="${!host_var:-}" path="${!path_var:-}" ssh_key="${!key_var:-}"

  [ -n "$host" ] || return 0

  # Both probes are reads and must really run, including under --dry-run:
  # routed through run_or_echo they would return the literal "[dry-run] ..."
  # text and the check would pass on nothing. Same treatment, and the same
  # save/restore discipline, as graft_sync_theme_parent.
  local saved_dry_run="${SITEGRAFT_DRY_RUN:-0}"
  SITEGRAFT_DRY_RUN=0
  local wp_ok=0 host_ok=0
  wp_remote "$alias_lc" option get siteurl >/dev/null 2>&1 && wp_ok=1
  if [ -n "$ssh_key" ]; then
    ssh -i "$ssh_key" -- "$host" "test -d $(sq "$path")" >/dev/null 2>&1 && host_ok=1
  else
    ssh -- "$host" "test -d $(sq "$path")" >/dev/null 2>&1 && host_ok=1
  fi
  SITEGRAFT_DRY_RUN="$saved_dry_run"

  if [ "$wp_ok" = "0" ]; then
    log_error "site '${alias_lc}': wp-cli on ${host} did not answer with --path=${path}. Check SITE_${alias_uc}_WP_PATH and SITE_${alias_uc}_WP_CMD before going further — every later phase builds on this path."
    return 1
  fi

  if [ "$host_ok" = "0" ]; then
    log_error "site '${alias_lc}': wp-cli answers with --path=${path}, but ${host} has no such directory on its own filesystem. That means wp-cli is running inside a container on the far end, and sitegraft cannot drive that shape: it would copy files to paths the container cannot see, and 'wp export --dir=/tmp/...' would write inside the container while the pull read the host's /tmp — an EMPTY export, reported as a successful graft. Refusing here instead. Workaround: install and run sitegraft ON ${host} itself, leaving SITE_${alias_uc}_SSH_HOST empty so this site takes the supported local+wrapper path (note SITE_${alias_uc}_WP_PATH must then be the CONTAINER path, and SITE_${alias_uc}_WP_CMD must end in ' wp'). Tracked as issue #19."
    return 1
  fi
}

inventory_scan_site() {
  local alias_lc="$1" out_json="$2"
  log_info "scanning site '${alias_lc}' -> ${out_json}"
  local post_types options tables plugins active_theme menus
  post_types=$(wp_remote "$alias_lc" post-type list --format=json)
  # `--unserialize` (B1, third review round): WITHOUT it, wp-cli returns each
  # option_value exactly as the database holds it, so a PHP array arrives as
  # the serialized STRING `a:1:{...}` rather than as a structure. Verified
  # live against WP-CLI 2.12.0 on a real WordPress install, not assumed:
  #
  #   stored bytes                     without            with
  #   a:2:{i:0;s:5:"fotos";...}        "a:2:{i:0;s:5:..."  ["fotos","news"]
  #   a:0:{}                           "a:0:{}"            []
  #   a:1:{s:5:"fotos";a:1:{...}}      "a:1:{s:5:\"fot..."  {"fotos":{...}}
  #   [{"slug":"fotos"}]  (a string)   unchanged           unchanged
  #   hello / 42                       unchanged           unchanged
  #
  # modules/etch.sh's etch_cpts reader is the only consumer of this field and
  # cannot read a serialized string — so on the storage shape a WordPress
  # array is MOST likely to have, including the wholly benign empty `a:0:{}`,
  # `plan` used to stop dead. The flag has been part of `wp option list` since
  # 2018 (wp-cli/entity-command, "Add --unserialize flag to 'option list'
  # command"), so it predates every wp-cli 2.x this tool can run against.
  # One behavior worth knowing: a CORRUPT serialized value unserializes to
  # PHP `false` and is recorded as JSON `false` (observed live), where the
  # raw string used to come through — a module reading it still cannot make
  # sense of it, which is the same answer, reached one step earlier.
  options=$(wp_remote "$alias_lc" option list --unserialize --format=json)
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
  # NIT-1: fail CLOSED like M3, not open. The previous
  # `... 2>/dev/null || echo '[]'` turned any query error into "no classic
  # menus" — silently suppressing the §13 warning exactly when it is least
  # trustworthy (the query didn't actually run).
  # N2: stderr is kept OUT of the value that gets parsed as JSON below (via
  # --argjson) — a wp-cli deprecation notice or warning on stderr, even on
  # an otherwise-successful call (exit 0), would have silently corrupted
  # $menus with non-JSON text mixed in. Only re-captured, separately, on
  # the failure path below, purely for the diagnostic message.
  local menus_unknown=false
  if ! menus=$(wp_remote "$alias_lc" menu list --format=json 2>/dev/null); then
    local menus_err
    menus_err=$(wp_remote "$alias_lc" menu list --format=json 2>&1 >/dev/null)
    log_warn "could not list nav menus on site ${alias_lc} — classic-menu detection recorded as unknown, not clean (fail-safe, design doc §13): ${menus_err}"
    menus='[]'
    menus_unknown=true
  fi

  local custom_code_signals='{}' custom_code_detected=false
  if [ "$alias_lc" = "b" ]; then
    custom_code_signals=$(inventory_custom_code_signals "$alias_lc")
    inventory_custom_code_detected "$custom_code_signals" && custom_code_detected=true
  fi

  # A-only (§0 point 11) — null/unknown on B, and null on A if the query
  # itself fails (never silently assumed false).
  local nav_dynamic='null'
  if [ "$alias_lc" = "a" ]; then
    # N2: same stderr-out-of-the-parsed-value treatment as $menus above.
    if ! nav_dynamic=$(inventory_nav_uses_dynamic_page_list "$alias_lc" 2>/dev/null); then
      local nav_err
      nav_err=$(inventory_nav_uses_dynamic_page_list "$alias_lc" 2>&1 >/dev/null)
      log_warn "could not determine whether site A's navigation uses a dynamic page-list block — recording nav_uses_dynamic_page_list as unknown (null): ${nav_err}"
      nav_dynamic='null'
    fi
    # Guard against a non-boolean/garbled result being embedded as JSON.
    case "$nav_dynamic" in
      true|false) : ;;
      *) nav_dynamic='null' ;;
    esac
  fi

  # Every large payload below used to reach jq as a command-line argument via
  # --argjson. Found on the first real A/B pair: on a genuine site, `wp option
  # list --format=json` alone is megabytes — a WooCommerce + multilingual +
  # booking stack pushes the combined argv straight past ARG_MAX and jq dies
  # with "Argument list too long". The DDEV harness's two sites are orders of
  # magnitude too small to ever reach that limit, so this was invisible until
  # a real site was scanned.
  #
  # The silent-failure half was worse than the crash: jq's non-zero exit left
  # `> "$out_json"` holding a 0-BYTE file, inventory_scan_site returned that
  # status into a caller that ignored it, and the phase moved on to the next
  # site announcing it as if nothing had happened. Two empty scan files, exit
  # 0. `plan` would then read them as two empty sites rather than refusing to
  # run.
  #
  # Fixed on both counts: the large payloads go through FILES (--slurpfile
  # reads the file itself, bounded by disk rather than by argv), and every
  # step is now checked. Each --slurpfile binding is an ARRAY of the file's
  # JSON values, hence the [0] on each reference below. The three small
  # scalars stay on --argjson — they are two booleans and a boolean-or-null.
  # Recorded here so `plan` can match module-declared table SUFFIXES against
  # the prefixed table names in `.tables` without a live call. That missing
  # piece is half of why manifest_compute_unclaimed left its tables list
  # empty: the prefix was only obtainable from the site itself, and plan is
  # deliberately offline (it reads scanned JSON, never the sites). Putting it
  # in the scan keeps that property intact.
  local table_prefix
  table_prefix=$(inventory_table_prefix "$alias_lc" 2>/dev/null | tr -d '\r\n' || true)
  if [ -z "$table_prefix" ]; then
    log_warn "could not read site ${alias_lc}'s table prefix — recording it as empty; plan will not be able to identify unclaimed tables for this site"
  fi

  local payload_dir
  payload_dir=$(mktemp -d) || { log_error "could not create a temp dir for scan payloads"; return 1; }

  printf '%s' "$post_types"          > "${payload_dir}/post_types.json"
  printf '%s' "$options"             > "${payload_dir}/options.json"
  printf '%s' "$tables"              > "${payload_dir}/tables.json"
  printf '%s' "$plugins"             > "${payload_dir}/plugins.json"
  printf '%s' "$active_theme"        > "${payload_dir}/active_theme.json"
  printf '%s' "$menus"               > "${payload_dir}/menus.json"
  printf '%s' "$custom_code_signals" > "${payload_dir}/custom_code_signals.json"

  # Fail CLOSED on a query that came back empty or garbled, rather than
  # embedding a null for it and writing a scan file that looks complete.
  local pf
  for pf in post_types options tables plugins active_theme menus custom_code_signals; do
    if ! jq -e . "${payload_dir}/${pf}.json" >/dev/null 2>&1; then
      log_error "site '${alias_lc}': the '${pf}' query returned empty or invalid JSON — refusing to write a partial scan file"
      rm -rf "$payload_dir"
      return 1
    fi
  done

  if ! jq -n \
    --slurpfile post_types "${payload_dir}/post_types.json" \
    --slurpfile options "${payload_dir}/options.json" \
    --slurpfile tables "${payload_dir}/tables.json" \
    --slurpfile plugins "${payload_dir}/plugins.json" \
    --slurpfile active_theme "${payload_dir}/active_theme.json" \
    --slurpfile menus "${payload_dir}/menus.json" \
    --slurpfile custom_code_signals "${payload_dir}/custom_code_signals.json" \
    --argjson menus_unknown "$menus_unknown" \
    --argjson custom_code_detected "$custom_code_detected" \
    --argjson nav_uses_dynamic_page_list "$nav_dynamic" \
    --arg table_prefix "$table_prefix" \
    '{
      post_types: $post_types[0],
      options: $options[0],
      tables: $tables[0],
      table_prefix: $table_prefix,
      plugins: $plugins[0],
      active_theme: $active_theme[0],
      classic_menus_detected: (($menus_unknown == true) or ([$menus[0][]? | select((.count // 0) > 0)] | length > 0)),
      classic_menus_unknown: $menus_unknown,
      classic_menu_names: [$menus[0][]? | select((.count // 0) > 0) | .name],
      custom_code_signals: $custom_code_signals[0],
      custom_code_detected: $custom_code_detected,
      nav_uses_dynamic_page_list: $nav_uses_dynamic_page_list
    }' \
    > "$out_json"; then
    rm -rf "$payload_dir"
    log_error "could not assemble ${out_json} — the scan of site '${alias_lc}' did NOT succeed"
    return 1
  fi
  rm -rf "$payload_dir"

  # Never leave a 0-byte or malformed scan file behind while reporting
  # success — that is precisely what this function used to do.
  if ! jq -e . "$out_json" >/dev/null 2>&1; then
    log_error "the scan of site '${alias_lc}' produced empty or invalid JSON at ${out_json}"
    return 1
  fi
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

  # N2 applies to the three blocks below too: stderr is kept out of the
  # value read as JSON on the success path (2>/dev/null), even though the
  # `jq .` validity check right after already fails closed on corrupted
  # content — cleaner to avoid the corruption in the first place than to
  # rely on catching it downstream. Re-captured, separately, only on the
  # failure path, for the diagnostic message.
  local fn_php_eval='if (file_exists($f = get_stylesheet_directory()."/functions.php")) { echo json_encode(["exists"=>true,"bytes"=>filesize($f),"lines"=>count(file($f))]); } else { echo json_encode(["exists"=>false]); }'
  if fn_php_raw=$(wp_remote "$alias_lc" eval "$fn_php_eval" 2>/dev/null) \
    && echo "$fn_php_raw" | jq . >/dev/null 2>&1; then
    fn_php="$fn_php_raw"
  else
    local fn_php_err
    fn_php_err=$(wp_remote "$alias_lc" eval "$fn_php_eval" 2>&1 >/dev/null)
    log_warn "could not check functions.php on site ${alias_lc} — recording functions_php as unknown (fail-safe, design doc §14): ${fn_php_err}"
    unknown=$(echo "$unknown" | jq -c '. + ["functions_php"]')
  fi

  local mu_plugins_eval='echo json_encode(array_map("basename", glob(WP_CONTENT_DIR."/mu-plugins/*.php") ?: []));'
  if mu_plugins_raw=$(wp_remote "$alias_lc" eval "$mu_plugins_eval" 2>/dev/null) \
    && echo "$mu_plugins_raw" | jq . >/dev/null 2>&1; then
    mu_plugins="$mu_plugins_raw"
  else
    local mu_plugins_err
    mu_plugins_err=$(wp_remote "$alias_lc" eval "$mu_plugins_eval" 2>&1 >/dev/null)
    log_warn "could not list mu-plugins on site ${alias_lc} — recording mu_plugins as unknown (fail-safe, design doc §14): ${mu_plugins_err}"
    unknown=$(echo "$unknown" | jq -c '. + ["mu_plugins"]')
  fi

  if plugins_json=$(wp_remote "$alias_lc" plugin list --format=json 2>/dev/null) \
    && echo "$plugins_json" | jq . >/dev/null 2>&1; then
    # status=active: an installed-but-inactive snippet plugin is not
    # injecting anything at runtime, so it is not itself a signal.
    snippet_plugins=$(echo "$plugins_json" | jq -c \
      --argjson names "$SITEGRAFT_SNIPPET_PLUGIN_SLUGS" \
      '[.[] | select(.status == "active") | select(.name as $n | $names | index($n)) | .name]')
  else
    local plugins_err
    plugins_err=$(wp_remote "$alias_lc" plugin list --format=json 2>&1 >/dev/null)
    log_warn "could not list plugins on site ${alias_lc} — recording snippet_plugins as unknown (fail-safe, design doc §14): ${plugins_err}"
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

  # MINOR-2 (Viktor, second review round): fail CLOSED on anything that
  # isn't a well-formed signals object, not just on the four recognized
  # positive signals. Step 2 reads this back from scan-b.json on disk,
  # which could plausibly be truncated, hand-edited, or otherwise
  # corrupted by the time it's read — the previous version let malformed
  # JSON, a bare `null`/`""`, or any non-object value silently evaluate to
  # "no custom code found": jq errors on broken JSON, the `$(...)` capture
  # is then empty, and `[ "" = "true" ]` is false — the exact fail-open
  # shape §14's blocking gate must never have. Verified live against
  # broken JSON, {}, null, "", and a JSON array — all now correctly
  # treated as "detected" (gate fires) rather than "clean".
  local well_formed
  well_formed=$(printf '%s' "$signals" | jq -e '
    type == "object"
    and has("child_theme")
    and has("functions_php")
    and has("mu_plugins")
    and has("snippet_plugins_detected")
  ' 2>/dev/null)
  if [ "$well_formed" != "true" ]; then
    return 0
  fi

  [ "$(printf '%s' "$signals" | jq '
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
    # shellcheck disable=SC2034 # read via lib/core.sh's is_dry_run(), a different sourced file in the same bash process, not in this one
    SITEGRAFT_DRY_RUN=0
  fi

  profile_load "$profile" || return 1

  # BLOCKER (second review round, verified live): a profile omitting
  # SITEGRAFT_STATE_DIR used to make the dereference below a raw bash
  # "unbound variable" crash — and, for the exact reason documented in
  # lib/core.sh's M1 fix, that specific error class reports $?=0 to any
  # EXIT trap, so the process exited 0 having done nothing. This is
  # primarily caught earlier now, by profile_load's own required-key check
  # (lib/profile.sh) — this is the belt-and-suspenders check right at the
  # point of use, in case that ever changes. `${SITEGRAFT_STATE_DIR:-}` is
  # the safe form: it never touches the fatal unbound-variable path, it
  # just reads "" for unset.
  if [ -z "${SITEGRAFT_STATE_DIR:-}" ]; then
    log_error "profile '${profile}' does not set SITEGRAFT_STATE_DIR"
    return 1
  fi

  local run_dir
  run_dir="${SITEGRAFT_STATE_DIR}/${profile}-$(date +%Y%m%dT%H%M%S)"

  # M4: scan-*.json holds a full `wp option list` dump — this can include
  # license keys, SMTP tokens, or anything else a plugin stores as an
  # option. Neither the run directory nor the files in it may be
  # group/world-readable. umask first (belt) so mkdir/redirection default
  # to owner-only, then explicit chmod (suspenders) so this holds
  # regardless of the caller's ambient umask.
  #
  # NIT-3: run in a subshell so the umask change is automatically scoped —
  # it is restored on the parent shell whether this block succeeds or a
  # scan step fails partway through, without needing a manual save/restore
  # that a failure could skip over.
  # Every step needs its own `|| exit 1`. A subshell's exit status is simply
  # that of its LAST command — here the trailing chmod, which succeeds as
  # long as the files exist at all, even at 0 bytes. So both scans could fail
  # and `( ... ) || return 1` would still see a clean exit 0: that is exactly
  # how a run whose two scan files were empty went on to report success.
  (
    umask 077
    mkdir -p "$run_dir" || exit 1
    chmod 700 "$run_dir" || exit 1
    # Both topologies checked BEFORE either site is read: an unusable profile
    # should be rejected in seconds, not after a full scan of the other site.
    inventory_check_path_topology a || exit 1
    inventory_check_path_topology b || exit 1
    inventory_scan_site a "${run_dir}/scan-a.json" || exit 1
    inventory_scan_site b "${run_dir}/scan-b.json" || exit 1
    chmod 600 "${run_dir}/scan-a.json" "${run_dir}/scan-b.json" || exit 1
  ) || { log_error "scan failed (see the error above) — no usable run directory was produced at ${run_dir}"; return 1; }

  if jq -e '.classic_menus_unknown == true' "${run_dir}/scan-a.json" >/dev/null 2>&1; then
    log_warn "could not verify whether site A has classic nav menu(s) with items (the wp-cli query failed) — treat as unverified, not as clean (design doc §13)"
  elif jq -e '.classic_menus_detected == true' "${run_dir}/scan-a.json" >/dev/null 2>&1; then
    log_warn "site A has classic nav menu(s) with items: $(jq -r '.classic_menu_names | join(", ")' "${run_dir}/scan-a.json") — sitegraft v1 does not migrate classic menu assignments (design doc §13)"
  fi

  log_info "scan complete: ${run_dir}"
}
