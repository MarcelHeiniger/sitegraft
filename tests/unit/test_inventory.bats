# tests/unit/test_inventory.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  load '../../lib/inventory.sh'
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/acss.sh" <<'EOF'
acss_name() { echo "Automatic.css"; }
acss_detect() { jq -e '.plugins[] | select(.name == "automatic-css")' "$1" >/dev/null 2>&1; }
acss_option_keys() { printf 'automatic_css_settings\n'; }
acss_stack_candidates() { printf 'automatic-css\nacss-legacy-slug\n'; }
EOF
  modules_discover
}

@test "wp_remote builds an ssh command when SITE_A_SSH_HOST is set" {
  SITE_A_SSH_HOST="user@host-a.example.com"
  SITE_A_WP_PATH="/var/www/site-a"
  SITE_A_WP_CMD="wp"
  SITEGRAFT_DRY_RUN=1
  run wp_remote a post-type list --format=json
  [[ "$output" == *"ssh"* ]] || false
  [[ "$output" == *"user@host-a.example.com"* ]] || false
}

@test "sq single-quotes a plain string" {
  run sq "hello"
  [ "$output" = "'hello'" ]
}

@test "sq escapes an embedded single quote so the result is safe to re-parse by another shell (B1)" {
  run sq "it's a test"
  [ "$output" = "'it'\\''s a test'" ]
}

@test "sq preserves a trailing newline in its input instead of silently stripping it (MINOR-1)" {
  # bats' own "run" captures output via a mechanism that itself strips
  # trailing newlines (same as a plain command substitution would), so
  # this appends a sentinel character right after sq's own output — command
  # substitution only strips newlines at the true END of the captured
  # stream, so a newline sq embedded *before* the sentinel survives the
  # capture intact and can be checked with a plain bash string comparison.
  local val
  val=$'line with a trailing newline\n'
  local out
  out="$(sq "$val")X"
  local expected
  expected="'${val}'X"
  [ "$out" = "$expected" ]
}

@test "wp_remote builds the EXACT remote command string for a wp eval snippet with \$wpdb, ;, and -> (B1)" {
  # This is the literal case that was broken and unsafe: the old
  # "\$wp_cmd --path='\$path' \$*" construction let the remote shell
  # re-parse \$wpdb (expanded to empty before wp-cli ever saw it), ; (ends
  # the command early), and -> (harmless here, but the same unescaped-
  # interpolation problem) — silently corrupting exactly the queries §14's
  # custom-code-detection gate depends on. Asserts the exact resulting
  # string, not just a substring, since a substring match previously would
  # have let the injection-shaped bug through undetected.
  SITE_A_SSH_HOST="user@host-a.example.com"
  SITE_A_WP_PATH="/var/www/html"
  SITE_A_WP_CMD="wp"
  SITEGRAFT_DRY_RUN=1
  run wp_remote a eval 'global $wpdb; echo $wpdb->prefix;'
  [ "$output" = "[dry-run] ssh -- user@host-a.example.com wp --path='/var/www/html' 'eval' 'global \$wpdb; echo \$wpdb->prefix;'" ]
}

@test "wp_remote single-quotes an SSH_PATH containing an embedded single quote instead of injecting it (B1)" {
  SITE_A_SSH_HOST="user@host-a.example.com"
  SITE_A_WP_PATH="/var/www/o'brien-site"
  SITE_A_WP_CMD="wp"
  SITEGRAFT_DRY_RUN=1
  run wp_remote a option get siteurl
  [ "$output" = "[dry-run] ssh -- user@host-a.example.com wp --path='/var/www/o'\\''brien-site' 'option' 'get' 'siteurl'" ]
}

@test "wp_remote single-quotes a malicious argument instead of letting it inject a second command over ssh (B1)" {
  SITE_A_SSH_HOST="user@host-a.example.com"
  SITE_A_WP_PATH="/var/www/html"
  SITE_A_WP_CMD="wp"
  SITEGRAFT_DRY_RUN=1
  run wp_remote a eval "1; touch /tmp/PWNED"
  # The whole payload must appear as ONE single-quoted argv element to the
  # remote wp — never as an unquoted "; touch ..." that a remote shell
  # would execute as a second command.
  [[ "$output" == *"'1; touch /tmp/PWNED'"* ]] || false
  [[ "$output" != *"'1'; touch /tmp/PWNED"* ]] || false
}

@test "wp_remote passes -i <SSH_KEY> before -- when SITE_<ALIAS>_SSH_KEY is set (Step 6 self-review: design doc §5.2 vs. code drift, was parsed but never consumed)" {
  SITE_A_SSH_HOST="user@host-a.example.com"
  SITE_A_WP_PATH="/var/www/html"
  SITE_A_WP_CMD="wp"
  SITE_A_SSH_KEY="/home/marcel/.ssh/id_ed25519_site_a"
  SITEGRAFT_DRY_RUN=1
  run wp_remote a option get siteurl
  [ "$output" = "[dry-run] ssh -i /home/marcel/.ssh/id_ed25519_site_a -- user@host-a.example.com wp --path='/var/www/html' 'option' 'get' 'siteurl'" ]
}

@test "wp_remote never passes -i when SITE_<ALIAS>_SSH_KEY is unset — falls back to ssh's own default identity resolution" {
  SITE_A_SSH_HOST="user@host-a.example.com"
  SITE_A_WP_PATH="/var/www/html"
  SITE_A_WP_CMD="wp"
  unset SITE_A_SSH_KEY
  SITEGRAFT_DRY_RUN=1
  run wp_remote a option get siteurl
  [[ "$output" != *"-i "* ]] || false
}

@test "wp_remote's -i value is a plain positional argument to -i, so a hostile-looking SITE_*_SSH_KEY can't be read as a SEPARATE ssh option" {
  # "-i" consumes exactly the next argv element as its own value (ssh's own
  # option-parsing contract, same reasoning as the SSH_HOST MINOR-4 test
  # below for "--"/positionals) — a key value that itself looks like an
  # option (e.g. starting with "-") lands as -i's argument, never as a
  # second, independent flag ssh would parse on its own.
  SITE_A_SSH_HOST="user@host-a.example.com"
  SITE_A_WP_PATH="/var/www/html"
  SITE_A_WP_CMD="wp"
  SITE_A_SSH_KEY="-oProxyCommand=touch /tmp/PWNED"
  SITEGRAFT_DRY_RUN=1
  run wp_remote a option get siteurl
  [[ "$output" == "[dry-run] ssh -i -oProxyCommand=touch /tmp/PWNED -- user@host-a.example.com "* ]] || false
}

@test "wp_remote passes -- before the host to ssh so a hostile-looking SITE_*_SSH_HOST can't be read as an option (MINOR-4)" {
  # Verified live: "ssh -oProxyCommand=..." is only rejected today because
  # profile-sourced hosts happen to contain characters ssh's own option
  # parser dislikes — that is not a real barrier. `ssh -- "$host" ...`
  # makes ssh treat everything after -- as positional, so this can never
  # be read as an ssh option regardless of its shape.
  SITE_A_SSH_HOST="-oProxyCommand=touch /tmp/PWNED"
  SITE_A_WP_PATH="/var/www/html"
  SITE_A_WP_CMD="wp"
  SITEGRAFT_DRY_RUN=1
  run wp_remote a option get siteurl
  [[ "$output" == "[dry-run] ssh -- "* ]] || false
}

@test "wp_remote runs the local wp command when no SSH host is set" {
  unset SITE_B_SSH_HOST
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="ddev wp"
  SITEGRAFT_DRY_RUN=1
  run wp_remote b post-type list --format=json
  [[ "$output" != *"ssh"* ]] || false
  [[ "$output" == *"ddev wp"* ]] || false
}

@test "wp_remote actually splits a multi-word local WP_CMD into separate argv words on real execution (not just dry-run echo)" {
  # Caught against the real DDEV harness: a quoted "$wp_cmd" tries to exec a
  # single binary literally named e.g. "ddev exec -p x -- wp", which doesn't
  # exist. Dry-run mode never exercises this (it only ever echoes "$*"), so a
  # dry-run-only test can't catch it — this one runs wp_remote for real.
  unset SITE_B_SSH_HOST
  SITE_B_WP_PATH="/var/www/html"
  SITE_B_WP_CMD="echo CALLED"
  unset SITEGRAFT_DRY_RUN
  run wp_remote b option get siteurl
  [ "$status" -eq 0 ]
  [ "$output" = "CALLED --path=/var/www/html option get siteurl" ]
}

@test "inventory_resolve_slug returns the first candidate actually present, never an absent one" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"plugins":[{"name":"acss-legacy-slug","version":"3.9"}]}' > "$scan"
  run inventory_resolve_slug "$scan" "$(printf 'automatic-css\nacss-legacy-slug\n')"
  [ "$output" = "acss-legacy-slug" ]
}

@test "inventory_resolve_slug returns empty when no candidate is present" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"plugins":[]}' > "$scan"
  run inventory_resolve_slug "$scan" "$(printf 'automatic-css\nacss-legacy-slug\n')"
  [ -z "$output" ]
}

@test "inventory_stack_diff is empty when everything resolves the same on both sites" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"etch-theme","version":"1.0"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"etch-theme","version":"1.0"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$b"
  run inventory_stack_diff "$a" "$b"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "0" ]
}

@test "inventory_stack_diff reports theme as a mismatch with both resolved values when they differ" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"etch-theme","version":"1.0"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"divi","version":"4.2"},"plugins":[]}' > "$b"
  run inventory_stack_diff "$a" "$b"
  echo "$output" | jq -e '.theme.slug_a == "etch-theme" and .theme.slug_b == "divi"' >/dev/null
}

@test "inventory_stack_diff reports slug_b as null when the component is absent on B (the common case, §13)" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$b"
  run inventory_stack_diff "$a" "$b"
  echo "$output" | jq -e '.acss.slug_a == "automatic-css" and .acss.slug_b == null' >/dev/null
}

@test "inventory_stack_diff resolves each site's own real slug — the ACSS v4 plugin-folder-rename case (design doc §3.4)" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"acss-legacy-slug","version":"3.9"}]}' > "$b"
  run inventory_stack_diff "$a" "$b"
  echo "$output" | jq -e \
    '.acss.slug_a == "automatic-css" and .acss.slug_b == "acss-legacy-slug" and .acss.version_a == "4.1" and .acss.version_b == "3.9"' \
    >/dev/null
}

@test "inventory_stack_matches wraps inventory_stack_diff (true iff it's empty)" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"etch-theme"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"some-other-theme"},"plugins":[]}' > "$b"
  run inventory_stack_matches "$a" "$b"
  [ "$status" -eq 1 ]
}

@test "inventory_scan_site aliases wp-cli's real 'name' field to 'stylesheet' for active_theme (found via live DDEV harness run)" {
  # wp-cli's real `theme list --format=json` field is "name", never
  # "stylesheet" (verified against a real install) — but the design doc's
  # documented scan schema (§6.1/§12) and inventory_stack_diff both read
  # active_theme.stylesheet. Without this alias, inventory_stack_diff always
  # compared "" == "" and never actually detected a real theme mismatch —
  # this stayed undetected through every unit test (which only ever
  # fabricated scan-*.json directly) until checked against a real scan.
  wp_remote() {
    local alias_lc="$1"; shift
    case "$*" in
      "post-type list --format=json") echo '[]' ;;
      "option list --format=json") echo '[]' ;;
      "db tables --format=list --all-tables-with-prefix") echo 'wp_options' ;;
      "plugin list --format=json") echo '[]' ;;
      "theme list --status=active --format=json") echo '[{"name":"twentytwentyfive","status":"active","version":"1.5"}]' ;;
      "menu list --format=json") echo '[]' ;;
      *) echo '[]' ;;
    esac
  }
  local out="$BATS_TEST_TMPDIR/scan-a.json"
  inventory_scan_site a "$out"
  run jq -e '.active_theme.name == "twentytwentyfive" and .active_theme.stylesheet == "twentytwentyfive"' "$out"
  [ "$status" -eq 0 ]
}

# --- inventory_check_path_topology -----------------------------------------
#
# The one site shape sitegraft cannot drive: reachable over SSH, with wp-cli
# running inside a container on the far end. Left undetected it does not fail
# usefully — `wp export --dir=/tmp/...` writes inside the container while the
# pull reads the SSH host's /tmp, so the export comes back empty and the graft
# reports success having moved nothing.
#
# The guard tests the invariant (is WP_PATH visible to BOTH wp-cli and the SSH
# host's filesystem?) rather than the shape of the profile, and the last test
# below is what pins that difference: `sudo -u www-data wp` behind SSH is a
# wrapper whose paths match, and must be accepted.

@test "inventory_check_path_topology skips a site with no SSH_HOST (local+wrapper is supported)" {
  SITE_B_SSH_HOST=""
  SITE_B_WP_PATH="/var/www/html"
  wp_remote() { return 1; }   # would fail if it were consulted at all
  ssh() { return 1; }
  run inventory_check_path_topology b
  [ "$status" -eq 0 ]
}

@test "inventory_check_path_topology refuses when wp-cli sees the path but the SSH host does not" {
  SITE_B_SSH_HOST="user@host"
  SITE_B_WP_PATH="/var/www/html"
  wp_remote() { return 0; }   # wp-cli answers: the container sees the path
  ssh() { return 1; }         # the host itself has no such directory
  run inventory_check_path_topology b
  [ "$status" -ne 0 ]
  [[ "$output" == *"running inside a container"* ]] || false
}

@test "inventory_check_path_topology refuses when wp-cli does not answer at all" {
  SITE_B_SSH_HOST="user@host"
  SITE_B_WP_PATH="/wrong/path"
  wp_remote() { return 1; }
  ssh() { return 0; }
  run inventory_check_path_topology b
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not answer"* ]] || false
}

@test "inventory_check_path_topology accepts a wrapper behind SSH whose paths agree (sudo -u www-data wp)" {
  SITE_B_SSH_HOST="user@host"
  SITE_B_WP_PATH="/var/www/site/htdocs"
  wp_remote() { return 0; }
  ssh() { return 0; }
  run inventory_check_path_topology b
  [ "$status" -eq 0 ]
}
