# tests/unit/test_inventory.bats
bats_require_minimum_version 1.5.0
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
  SITE_A_SSH_KEY="/home/user/.ssh/id_ed25519_site_a"
  SITEGRAFT_DRY_RUN=1
  run wp_remote a option get siteurl
  [ "$output" = "[dry-run] ssh -i /home/user/.ssh/id_ed25519_site_a -- user@host-a.example.com wp --path='/var/www/html' 'option' 'get' 'siteurl'" ]
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
      "option list --unserialize --format=json") echo '[]' ;;
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

# B1 (third review round). `wp option list --format=json` WITHOUT
# --unserialize hands back each option_value exactly as the database holds
# it, so a PHP array arrives as the serialized STRING `a:1:{...}`. Verified
# live against WP-CLI 2.12.0 on a real WordPress install rather than
# reasoned about:
#
#   stored bytes                    without --unserialize   with --unserialize
#   a:2:{i:0;s:5:"fotos";...}       "a:2:{i:0;s:5:\"fo..."  ["fotos","news"]
#   a:0:{}                          "a:0:{}"                []
#   a:1:{s:5:"fotos";a:1:{...}}     "a:1:{s:5:\"fotos\";..." {"fotos":{...}}
#   [{"slug":"fotos"}]  (a string)  "[{\"slug\":\"fotos\"}]" "[{\"slug\":\"fotos\"}]"
#   hello / 42                      "hello" / "42"          "hello" / "42"
#
# modules/etch.sh's etch_cpts reader is the ONLY consumer of .option_value in
# this codebase, and a serialized string is a shape it cannot read — which
# means `plan` used to stop on the storage form a WordPress array is MOST
# likely to have, including an empty one. Asking wp-cli to unserialize is
# what makes the scan record a structure rather than a string. The flag has
# been part of `wp option list` since 2018 (wp-cli/entity-command, "Add
# --unserialize flag to 'option list' command"), so it predates every wp-cli
# 2.x this tool can run against.
@test "inventory_scan_site asks wp-cli to unserialize option values, so an array option is scanned as a structure and not as a serialized string" {
  local calls="$BATS_TEST_TMPDIR/calls.log"
  : > "$calls"
  wp_remote() {
    local alias_lc="$1"; shift
    echo "$*" >> "$calls"
    case "$*" in
      *"option list"*) echo '[{"option_name":"etch_cpts","option_value":[{"slug":"fotos"}]}]' ;;
      "db tables --format=list --all-tables-with-prefix") echo 'wp_options' ;;
      "theme list --status=active --format=json") echo '[{"name":"t"}]' ;;
      *) echo '[]' ;;
    esac
  }
  local out="$BATS_TEST_TMPDIR/scan-unser.json"
  inventory_scan_site a "$out"
  run grep -F -- 'option list --unserialize --format=json' "$calls"
  [ "$status" -eq 0 ]
  # And the recorded value really is a structure, not a string.
  run jq -e '.options[0].option_value | type == "array"' "$out"
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

# A stub that ignores its arguments keeps passing after the function it
# stands in for changes how it is called, so the test quietly stops testing
# anything. These stubs assert the alias they were handed instead: if
# inventory_check_path_topology ever stops passing the alias first, the test
# says so loudly rather than staying green on a signature that no longer
# exists.
_assert_alias() {
  local want="$1"; shift
  [ "${1:-}" = "$want" ] || {
    echo "stub called with unexpected first argument: '${1:-}' (wanted '${want}')" >&2
    return 99
  }
}

@test "inventory_check_path_topology skips a site with no SSH_HOST (local+wrapper is supported)" {
  SITE_B_SSH_HOST=""
  SITE_B_WP_PATH="/var/www/html"
  SITE_B_WP_CMD="ddev wp"
  wp_remote() { _assert_alias b "$@"; return 1; }   # would fail if it were consulted at all
  ssh() { return 1; }
  run inventory_check_path_topology b
  [ "$status" -eq 0 ]
}

@test "inventory_check_path_topology refuses when wp-cli sees the path but the SSH host does not" {
  SITE_B_SSH_HOST="user@host"
  SITE_B_WP_PATH="/var/www/html"
  wp_remote() { _assert_alias b "$@"; return 0; }   # wp-cli answers: the container sees the path
  ssh() { return 1; }         # the host itself has no such directory
  run inventory_check_path_topology b
  [ "$status" -ne 0 ]
  [[ "$output" == *"running inside a container"* ]] || false
  # The actionable half of the message is the part an operator needs most,
  # and nothing else pins it: name the workaround and the issue that
  # documents it, so a rewrite cannot quietly drop them.
  [[ "$output" == *"SITE_B_SSH_HOST empty"* ]] || false
  [[ "$output" == *"issue #19"* ]] || false
}

@test "inventory_check_path_topology refuses when wp-cli does not answer at all" {
  SITE_B_SSH_HOST="user@host"
  SITE_B_WP_PATH="/wrong/path"
  wp_remote() { _assert_alias b "$@"; return 1; }
  ssh() { return 0; }
  run inventory_check_path_topology b
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not answer"* ]] || false
  # This failure is a wrong path or a wrong wp command, not a container:
  # the message must send the reader to those two settings.
  [[ "$output" == *"WP_PATH"* ]] || false
  [[ "$output" == *"WP_CMD"* ]] || false
}

@test "inventory_check_path_topology accepts a wrapper behind SSH whose paths agree (sudo -u www-data wp)" {
  SITE_B_SSH_HOST="user@host"
  SITE_B_WP_PATH="/var/www/site/htdocs"
  SITE_B_WP_CMD="sudo -u www-data wp"
  wp_remote() { _assert_alias b "$@"; return 0; }
  ssh() { return 0; }
  run inventory_check_path_topology b
  [ "$status" -eq 0 ]
}

@test "inventory_check_path_topology passes -i <SSH_KEY> to its own direct ssh path-existence probe when SITE_<ALIAS>_SSH_KEY is set" {
  # The guard's own ssh probe (distinct from wp_remote's) has to carry the
  # key too, or a keyed site refuses every graft with a bogus "container"
  # verdict the moment SITE_<ALIAS>_SSH_KEY is set — wp-cli would answer via
  # wp_remote's own -i handling, but this guard's direct `ssh -- "$host" test
  # -d ...` probe would fall back to ssh's default identity and could fail
  # the host_ok half of the invariant for a reason that has nothing to do
  # with the topology being checked.
  SITE_B_SSH_HOST="user@host"
  SITE_B_WP_PATH="/var/www/site/htdocs"
  SITE_B_WP_CMD="wp"
  SITE_B_SSH_KEY="/home/user/.ssh/id_ed25519_b"
  wp_remote() { _assert_alias b "$@"; return 0; }
  ssh() {
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/ssh-calls.log"
    return 0
  }
  run inventory_check_path_topology b
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/ssh-calls.log"
  [[ "$output" == "-i /home/user/.ssh/id_ed25519_b --"* ]] || false
}

# --- inventory_nav_post_count -----------------------------------------------
#
# #17, fix-pack after review (Nat): the module claiming wp_navigation
# (modules/core-wp.sh's core_wp_post_types_dynamic) was gating on
# nav_uses_dynamic_page_list == true, which is exactly backwards for the
# issue's own acceptance criterion. A dynamic wp:page-list navigation
# carries no ids at all, so it is precisely the case that needs NO remap --
# and a STATIC navigation (real navigation-link blocks with real page ids,
# the case the id-remap in core_wp_post_import exists for) reads
# nav_uses_dynamic_page_list == false, IDENTICALLY to a source with no
# navigation at all. That gate could never claim the case #17 is about.
#
# This function is the missing fact: does A have ANY wp_navigation post at
# all, regardless of its content's shape. A-only, same reasoning as its
# sibling inventory_nav_uses_dynamic_page_list (§6.1: B's navigation,
# whatever form it takes, is either being replaced or none of sitegraft's
# business, §13) -- and the same post_status => "any" scope, so the two
# facts describe the exact same set of posts from two different angles
# (presence vs. shape) rather than silently disagreeing about which posts
# they're each counting.
@test "inventory_nav_post_count returns the number of wp_navigation posts on the given site" {
  wp_remote() {
    local alias_lc="$1"; shift
    case "$*" in
      eval*) echo 2 ;;
      *) echo "UNEXPECTED CALL: $*" >&2; return 1 ;;
    esac
  }
  run inventory_nav_post_count a
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# Nit (Viktor's review): nothing pinned "post_status => 'any'" specifically
# -- a scan that silently narrowed this to "publish" only would undercount
# a navigation still in draft/private status, collapsing right back into
# the exact "A has none" false negative B4/#17 exist to avoid, just from a
# different cause. This asserts the real query text, not merely its return
# value, the same way core_wp_post_import's own tests assert on captured
# call text rather than only outcomes.
@test "inventory_nav_post_count queries wp_navigation posts of ANY status, not published-only -- a draft/private navigation must still be counted" {
  local calls="$BATS_TEST_TMPDIR/calls.log"
  wp_remote() {
    local alias_lc="$1"; shift
    printf '%s
' "$*" >> "${BATS_TEST_TMPDIR}/calls.log"
    echo 1
  }
  inventory_nav_post_count a >/dev/null
  run cat "$calls"
  [[ "$output" == *'"post_status" => "any"'* ]] || false
}

@test "inventory_nav_post_count returns 0, not an error, when A genuinely has no wp_navigation posts" {
  wp_remote() { echo 0; }
  run inventory_nav_post_count a
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "inventory_scan_site records nav_post_count on A from a real count" {
  wp_remote() {
    local alias_lc="$1"; shift
    case "$*" in
      "post-type list --format=json") echo '[]' ;;
      "option list --unserialize --format=json") echo '[]' ;;
      "db tables --format=list --all-tables-with-prefix") echo 'wp_options' ;;
      "plugin list --format=json") echo '[]' ;;
      "theme list --status=active --format=json") echo '[{"name":"t"}]' ;;
      "menu list --format=json") echo '[]' ;;
      eval*)
        case "$*" in
          *"count(\$navs)"*) echo 3 ;;
          *"wp:page-list"*) echo 'false' ;;
          *) echo 'null' ;;
        esac
        ;;
      *) echo '[]' ;;
    esac
  }
  local out="$BATS_TEST_TMPDIR/scan-a.json"
  inventory_scan_site a "$out"
  run jq -e '.nav_post_count == 3' "$out"
  [ "$status" -eq 0 ]
}

@test "inventory_scan_site records nav_post_count as null on B -- A-only, same as nav_uses_dynamic_page_list" {
  wp_remote() {
    local alias_lc="$1"; shift
    case "$*" in
      "post-type list --format=json") echo '[]' ;;
      "option list --unserialize --format=json") echo '[]' ;;
      "db tables --format=list --all-tables-with-prefix") echo 'wp_options' ;;
      "plugin list --format=json") echo '[]' ;;
      "theme list --status=active --format=json") echo '[{"name":"t"}]' ;;
      "menu list --format=json") echo '[]' ;;
      eval*) echo 5 ;;
      *) echo '[]' ;;
    esac
  }
  local out="$BATS_TEST_TMPDIR/scan-b.json"
  inventory_scan_site b "$out"
  run jq -e '.nav_post_count == null' "$out"
  [ "$status" -eq 0 ]
}

@test "inventory_scan_site records nav_post_count as null (unknown, not zero) when the A-side query fails" {
  # Stdout deliberately looks like a plausible count ("2") even though the
  # command fails (non-zero exit, plus a stderr message) -- a flaky wp-cli
  # invocation can echo partial output before erroring. This is what makes
  # the test load-bearing for the exit-status check specifically: a stub
  # that only ever produced non-numeric/empty stdout on failure would pass
  # even with that check deleted, since the digit-only guard below it would
  # catch it anyway (verified live: this exact test caught a mutant that
  # removed the exit-status check, where a "return 1 with non-numeric
  # stdout" stub did not).
  wp_remote() {
    local alias_lc="$1"; shift
    case "$*" in
      "post-type list --format=json") echo '[]' ;;
      "option list --unserialize --format=json") echo '[]' ;;
      "db tables --format=list --all-tables-with-prefix") echo 'wp_options' ;;
      "plugin list --format=json") echo '[]' ;;
      "theme list --status=active --format=json") echo '[{"name":"t"}]' ;;
      "menu list --format=json") echo '[]' ;;
      eval*) echo "2"; echo "wp-cli error: could not connect" >&2; return 1 ;;
      *) echo '[]' ;;
    esac
  }
  local out="$BATS_TEST_TMPDIR/scan-a.json"
  run --separate-stderr inventory_scan_site a "$out"
  [ "$status" -eq 0 ]
  run jq -e '.nav_post_count == null' "$out"
  [ "$status" -eq 0 ]
}

@test "inventory_scan_site records nav_post_count as null when the A-side query returns something that is not a plain non-negative integer" {
  wp_remote() {
    local alias_lc="$1"; shift
    case "$*" in
      "post-type list --format=json") echo '[]' ;;
      "option list --unserialize --format=json") echo '[]' ;;
      "db tables --format=list --all-tables-with-prefix") echo 'wp_options' ;;
      "plugin list --format=json") echo '[]' ;;
      "theme list --status=active --format=json") echo '[{"name":"t"}]' ;;
      "menu list --format=json") echo '[]' ;;
      eval*) echo 'garbled <b>output</b>' ;;
      *) echo '[]' ;;
    esac
  }
  local out="$BATS_TEST_TMPDIR/scan-a.json"
  inventory_scan_site a "$out"
  run jq -e '.nav_post_count == null' "$out"
  [ "$status" -eq 0 ]
}
