#!/usr/bin/env bash
# lib/verify.sh — phase: verify (design doc §6.5, review finding B3). Read-only
# smoke checks on B after a graft: catches the class of bug that "protected
# data byte-identical" alone can never catch — a migration step that ran, or
# claimed to run, but silently did the wrong thing (a skipped options update,
# a broken domain search-replace, a page_on_front pointing at the wrong page).
# Nothing in this file ever writes to B — every wp_remote call here is a
# read (option get, post get/list, db export, eval that only inspects and
# echoes), never an update/import/delete/search-replace. That is the whole
# point of a *verify* phase: prove the graft worked without being able to
# change what it proved. (The one write-shaped-looking call, pushing a
# small JSON payload file for verify_domain_absent's `wp eval` to read, is
# to a throwaway file under wp-content — never a database write — and is
# removed again immediately after; see that function's own comment.)

# verify_compare_checksums <manifest_json> <recomputed_checksums_json> — pure
# function, no I/O. Same normalization as backup_checksum (design doc §6.3,
# review finding A5) is assumed to already be baked into both JSON arguments
# by the caller (phase_verify, below) — this function only ever compares two
# already-computed maps, so the three call sites (backup, verify, DDEV
# harness) can never drift on HOW a checksum is computed, only on WHEN.
verify_compare_checksums() {
  local manifest="$1" recomputed="$2"
  local diffs
  diffs=$(jq -n --argjson pre "$(echo "$manifest" | jq '.checksums_protected_pre_graft')" --argjson post "$recomputed" \
    '[$pre | keys[] as $k | select($pre[$k] != $post[$k]) | $k]')

  # Two regimes, on purpose.
  #
  # A key a MODULE declared is a hard failure: an operator named that data as
  # something graft must not touch, and it moved. Nothing else to discuss.
  #
  # A key under `_unclaimed:<table>` is reported, not failed. Those are B's
  # tables that no module covers — everything from a booking plugin's data to
  # WordPress's own action scheduler, which writes to itself continuously and
  # would turn every single run red. Failing on them would make the check
  # meaningless within a week; saying nothing about them is what made verify
  # able to print "protected data unchanged" while having compared nothing.
  # Naming them is the useful middle: the operator sees exactly which tables
  # moved and decides whether that was expected — and if a given plugin's
  # data must be guaranteed rather than observed, the answer is to write a
  # module for it, which promotes it to the hard regime above.
  local hard soft
  hard=$(echo "$diffs" | jq -c '[.[] | select(startswith("_unclaimed:") | not)]')
  soft=$(echo "$diffs" | jq -c '[.[] | select(startswith("_unclaimed:"))] | map(sub("^_unclaimed:"; ""))')

  if [ "$(echo "$soft" | jq 'length')" != "0" ]; then
    log_warn "unclaimed table(s) on B changed during this run: $(echo "$soft" | jq -r 'join(", ")') — no module declares them, so this is reported rather than failed. Expected for tables WordPress writes on its own (the action scheduler, sessions, usermeta after a login). If any of these hold data that must be guaranteed untouched, write a module declaring them."
  fi

  if [ "$(echo "$hard" | jq 'length')" != "0" ]; then
    log_error "protected data changed for: $(echo "$hard" | jq -r 'join(", ")')"
    echo "$hard"
    return 1
  fi
}

# verify_options_match <run_dir> <manifest_json> — design doc §6.5, review
# finding B3: spot-checks that every migrated option's LIVE value on B still
# matches the value `graft`'s own options step (graft_migrate_options,
# lib/graft.sh) wrote to "${run_dir}/option-<key>.value" at the time it ran.
# Catches a silently-skipped or partially-applied options migration — the
# checksum comparison above says nothing about migrated data (by definition:
# migrated data is expected to CHANGE on B, so it is never in
# checksums_protected_pre_graft).
#
# page_on_front/page_for_posts are excluded here — same skip-list as
# graft_migrate_options itself (lib/graft.sh): both ARE always written to
# "${run_dir}/option-<key>.value" (so a bare "file missing => skip" guard
# would NOT catch them), but their live value on B is deliberately never a
# blind copy of A's — core_wp_post_import remaps them through id-map.tsv
# instead (§9.3). Comparing them here against A's raw, un-remapped page ID
# would always spuriously mismatch. verify_page_on_front (below) is the
# correct, remap-aware check for page_on_front specifically.
#
# A key with no "${run_dir}/option-<key>.value" file at all is also skipped,
# not a failure: any key graft never actually reached (an interrupted run
# resumed past this step) is not this function's job to invent an opinion
# about. It IS this function's job to say how many it skipped, though
# (issue #23): a caller comparing 0 of 12 selected keys must be able to tell
# that apart from comparing 12 of 12 — this function alone knows both
# numbers, the loop already counts them for free, so it reports them on its
# last stdout line as "OPTIONS_COMPARED:<compared>:<total>" (machine-
# parseable, deliberately never mixed into the human-facing log_error text
# above it) regardless of whether it ultimately passes or hard-fails.
# phase_verify (below) is the one that turns that count into report wording
# — this function's own return code keeps meaning exactly what it always
# meant: 0 unless a KNOWN mismatch was found, since "nothing was available
# to compare" was never this function's failure to claim (see above).
#
# Security-review fix-pack (Kimi, MAJOR, missed by the first review pass —
# CRITICAL for any DACH/FR site, which is this tool's primary use case):
# comparing the two sides as raw TEXT is wrong whenever the value contains a
# `/` or a non-ASCII character. The file on disk can be written two
# different ways depending on whether graft_migrate_options' domain-rewrite
# ran (lib/graft.sh): untouched, it's A's own `wp option get --format=json`
# text (PHP json_encode — escapes `/` to `\/` and non-ASCII to `\uXXXX` by
# default); rewritten for a domain search-replace (true for virtually every
# REAL graft, since almost none skip a domain remap), it's jq's own
# re-serialization (jq does NOT escape `/` or non-ASCII by default). B's
# live re-fetch below is ALWAYS PHP json_encode (via `wp option get
# --format=json`). So a migrated option holding a URL or an accented
# character (ü, é — the everyday case for a German/French site, not an edge
# case) would compare two texts that decode to the IDENTICAL value but are
# spelled differently — a false HARD FAIL on every such graft. Piping BOTH
# sides through `jq -c .` before comparing decodes and re-serializes each
# with jq's own single, consistent convention, so the comparison is over
# the decoded value, not over which of two different serializers happened
# to write the text last. Falls back to the raw text if a side isn't valid
# JSON at all (shouldn't happen for a `--format=json` value, but comparing
# something is still better than aborting the whole check on one bad key).
verify_options_match() {
  local run_dir="$1" manifest="$2"
  local key mismatched="" compared=0 total=0
  for key in $(echo "$manifest" | jq -r '[.migrate[].option_keys[]?] | unique[]'); do
    case "$key" in
      page_on_front|page_for_posts) continue ;;
    esac
    total=$((total + 1))
    [ -f "${run_dir}/option-${key}.value" ] || continue
    compared=$((compared + 1))
    local expected actual expected_canon actual_canon
    expected=$(cat "${run_dir}/option-${key}.value")
    actual=$(wp_remote b option get "$key" --format=json 2>/dev/null || echo 'null')
    expected_canon=$(printf '%s' "$expected" | jq -c . 2>/dev/null) || expected_canon="$expected"
    actual_canon=$(printf '%s' "$actual" | jq -c . 2>/dev/null) || actual_canon="$actual"
    [ "$expected_canon" = "$actual_canon" ] || mismatched="${mismatched}${key} "
  done
  echo "OPTIONS_COMPARED:${compared}:${total}"
  if [ -n "$mismatched" ]; then
    log_error "migrated option value(s) do not match A's on B: ${mismatched}"
    return 1
  fi
}

# verify_domain_absent <run_dir> <id_map_tsv> <manifest_json> <domain> —
# design doc §9.4/§6.5. Rewritten in a security-review fix-pack (Viktor +
# Kimi, independently converging on the same root cause) after Marcel
# confirmed, reading a REAL verify-report.md, that the original SQL-based
# version was a DEAD check: it always reported "absent" (PASS) regardless
# of B's actual content.
#
# What was wrong with the original implementation, and why a PHP-side
# rewrite (not a smaller patch) was the only fix that closes all of it:
#  1. FATAL (Kimi, root cause): a `UNION ... LIMIT` per branch is invalid
#     MySQL/MariaDB syntax (error 1064) — EVERY invocation of the old query
#     errored. That error was swallowed by `2>/dev/null || echo ""`, so
#     `hit` was always empty and the function always returned 0 — a check
#     that structurally could never fail, because its query never once
#     executed successfully. This is a fail-OPEN bug, not a false-negative
#     edge case: the check was decorative from the day it shipped.
#  2. Even with valid SQL, the JSON-escaped-form branch (`LIKE
#     '%https:\/\/%'`) could never match real escaped bytes either — SQL
#     string-literal escaping mangles a literal backslash inside a LIKE
#     pattern, so the exact case this branch exists for (Etch's JSON blobs,
#     design doc §9.4) was unreachable even in a syntactically-valid
#     version.
#  3. Scanning B's WHOLE posts/postmeta/options tables conflates two
#     different questions: "did graft fully rewrite the content it
#     imported" (what verify should ask) vs. "does A's domain string exist
#     ANYWHERE on B" (not a graft defect when it doesn't — B legitimately
#     carrying a reference to A's domain, e.g. B is a clone of A, or a
#     protected plugin's own settings happen to mention it, is not
#     something graft's own search-replace was ever scoped to fix, exactly
#     the reasoning graft_search_replace_domain's own comment gives for
#     scoping ITS write the same way). A table-wide read wrongly hard-fails
#     on that, real for the harness's own MAJOR-2 protected-data injection
#     fixture and for any real B that predates the graft.
#
# The fix: a single `wp eval`, scoped IDENTICALLY to graft's own write
# surface (graft_search_replace_domain, lib/graft.sh) — the posts THIS run
# imported (id-map.tsv's new-ID column, via graft_migrated_post_ids_json)
# plus the migrated option_keys — never a table-wide scan. Uses PHP's own
# strpos() directly on the raw fetched bytes, not SQL LIKE and not a JSON
# round-trip:
#  - post_content/post_excerpt (plain TEXT columns, never PHP-serialized —
#    same reasoning as graft_search_replace_domain's own comment) are
#    searched for BOTH the plain domain string and its JSON-escaped form (a
#    real backslash-slash byte sequence, not a SQL escape of one) — strpos()
#    on raw bytes has no escaping-layer ambiguity at all.
#  - a migrated option's LIVE value is run through maybe_serialize() before
#    the same check: PHP's serialize() format never escapes `/` or any other
#    byte (unlike JSON) for a value PHP itself constructs. But an option can
#    also be, or contain, a plain STRING that itself holds literal JSON text
#    (a module storing a raw JSON blob as a string value, not an array/
#    object) — that string's own bytes can legitimately carry the escaped
#    `https:\/\/` form, exactly like post_content can (review fix-pack,
#    Viktor, MINOR: an earlier draft of this function checked only the plain
#    form on the options side, asymmetric with post_content/post_excerpt's
#    own two-form check). Both surfaces now call the SAME
#    sitegraft_domain_present() (lib/php/content-remap-functions.php,
#    required via graft_push_remap_lib — the identical require_once pattern
#    graft's own remap steps already use) instead of two independently
#    hand-written strpos pairs, so the two checks can never drift apart on
#    which forms they look for again.
# The domain travels to B inside a pushed JSON payload file (the same
# graft_push_remap_payload/graft_remove_file pattern every other B-bound
# transfer in this codebase already uses), decoded server-side by PHP's own
# json_decode — never interpolated into a SQL or shell string, which also
# closes the SQL-quote-injection surface the old implementation had.
#
# Fails CLOSED, not open: a `wp eval` that errors, or produces no
# recognizable result, is reported as UNKNOWN and treated as a failure by
# the caller — never silently folded into "absent". This is the single
# property the previous implementation most needed and didn't have.
#
# Known, documented scope limit (MINOR, review fix-pack): this checks for
# the domain string exactly as `manifest.options.search_replace.from`
# recorded it (mirroring graft's own scope) — a DIFFERENT scheme variant of
# the same host (e.g. A's content using `http://` when the manifest recorded
# `https://`, or a protocol-relative `//a.example.com`) is not detected,
# because graft's own search-replace never targeted it either. Not a gap
# this check introduces; it inherits graft's own documented scope exactly.
verify_domain_absent() {
  local run_dir="$1" id_map_tsv="$2" manifest="$3" domain="$4"
  [ -n "$domain" ] || return 0

  local post_ids_json option_keys_json payload_json remote_path lib_path
  post_ids_json='[]'
  [ -s "$id_map_tsv" ] && post_ids_json=$(graft_migrated_post_ids_json "$id_map_tsv")
  option_keys_json=$(echo "$manifest" | jq -c '[.migrate[]?.option_keys[]?] | unique')
  payload_json=$(jq -n --argjson post_ids "$post_ids_json" --argjson option_keys "$option_keys_json" --arg domain "$domain" \
    '{post_ids: $post_ids, option_keys: $option_keys, domain: $domain}')
  remote_path=$(graft_push_remap_payload "$run_dir" "$payload_json" "sitegraft-verify-domain-payload.json")
  # sitegraft_domain_present (lib/php/content-remap-functions.php) is the
  # exact same require_once/pattern graft's own remap steps already use
  # (see graft_remap_attachment_ids/graft_search_replace_domain) — the ONE
  # shared implementation of "does this string contain the plain OR
  # JSON-escaped domain form", used identically for both surfaces below, so
  # the two checks structurally cannot drift apart on which forms they look
  # for again (review fix-pack, Viktor, MINOR).
  lib_path=$(graft_push_remap_lib "$run_dir")

  # `&&`/`||` (not a bare assignment) so a failing wp_remote call is exempt
  # from bin/sitegraft's `set -e` (the same class of pitfall lib/core.sh's
  # own sitegraft_cleanup comment documents at length) and `rc` genuinely
  # reflects the call's real exit status instead of aborting the process
  # before `rc=$?` is ever reached.
  local result rc
  result=$(wp_remote b eval '
    require_once WP_CONTENT_DIR . "/sitegraft-content-remap-functions.php";
    $payload_path = WP_CONTENT_DIR . "/sitegraft-verify-domain-payload.json";
    $payload = json_decode( file_get_contents( $payload_path ), true );
    if ( ! $payload ) { echo "ERROR:unreadable-payload"; return; }
    $domain = $payload["domain"];
    $escaped = str_replace( "/", "\\/", $domain );
    $hits = array();
    foreach ( $payload["post_ids"] as $post_id ) {
      $post_id = (int) $post_id;
      $post = get_post( $post_id );
      if ( ! $post ) { continue; }
      if ( sitegraft_domain_present( $post->post_content, $domain, $escaped )
        || sitegraft_domain_present( $post->post_excerpt, $domain, $escaped ) ) {
        $hits[] = "post:{$post_id}";
      }
    }
    foreach ( $payload["option_keys"] as $key ) {
      $value = get_option( $key );
      if ( $value === false ) { continue; }
      if ( sitegraft_domain_present( maybe_serialize( $value ), $domain, $escaped ) ) {
        $hits[] = "option:{$key}";
      }
    }
    echo empty( $hits ) ? "OK" : ( "HIT:" . implode( ",", $hits ) );
  ' 2>/dev/null) && rc=0 || rc=$?
  graft_remove_file b "$remote_path" 2>/dev/null || true
  graft_remove_file b "$lib_path" 2>/dev/null || true

  if [ "$rc" -ne 0 ] || [ -z "$result" ]; then
    log_error "domain-absence check could not run (wp eval failed or returned nothing) — treated as UNKNOWN, never as a silent pass"
    return 1
  fi
  case "$result" in
    OK) return 0 ;;
    HIT:*)
      log_error "A's domain string ('${domain}') is still present in content graft imported: ${result#HIT:}"
      return 1
      ;;
    *)
      log_error "domain-absence check returned an unrecognized result ('${result}') — treated as UNKNOWN, never as a silent pass"
      return 1
      ;;
  esac
}

# verify_page_on_front <run_dir> <id_map_tsv> <manifest_json> — design doc
# §9.3/§6.5/review finding B3: NOT merely "does page_on_front resolve to SOME
# existing page" (a check that would pass even if it pointed at a random
# unrelated page) — resolves A's own recorded page_on_front value (the file
# core_wp_post_import, modules/core-wp.sh, reads from) through id-map.tsv the
# exact same way that hook does, and requires B's LIVE page_on_front to equal
# that specific remapped ID.
#
# Issue #12 fix: the ORIGINAL version of the "no id-map.tsv entry" branch
# below read `[ -n "$expected_new_id" ] || return 0` with the comment "A's
# front page wasn't part of this run's migrate selection" — but that was a
# GUESS, not something this function had verified. A missing id-map.tsv
# entry is ALSO exactly what a FAILED remap looks like (core_wp_post_import
# warns and leaves B's page_on_front unchanged when A's front page has no
# entry in id-map.tsv, modules/core-wp.sh) — and on the first real graft,
# that is exactly what happened: this check ticked its own box *because* the
# remap it exists to confirm had not happened.
# The manifest is what actually distinguishes the two cases: it says whether
# page_on_front was PART OF THIS RUN'S migrate selection at all (checked
# first, below — mirrors the same `.migrate[].option_keys[]?` selection test
# verify_options_match uses). If it was NOT selected, this run made no
# promise about page_on_front and there is genuinely nothing to check — a
# stale option-page_on_front.value/id-map.tsv pair left over in run_dir from
# an EARLIER run that DID select it must not be misread as this run's
# failure. If it WAS selected and A's own recorded value shows a real page
# (not the empty/null/false/0 "A never configured one" case just below), a
# missing id-map.tsv entry is no longer ambiguous — it can only mean the
# remap did not happen, and this now fails.
verify_page_on_front() {
  local run_dir="$1" id_map_tsv="$2" manifest="$3"
  echo "$manifest" | jq -e '[.migrate[].option_keys[]?] | index("page_on_front") != null' >/dev/null 2>&1 \
    || return 0 # page_on_front was not part of this run's migrate selection — nothing to check
  local old_front_id
  # A missing file here fails the `<` redirect itself (bash-level error, not
  # tr's), which would abort under `set -e` on its own — safe only because
  # every caller of this function (verify.sh:447) invokes it as the LHS of
  # `||`, which neutralizes `set -e` for the whole command per bash's rules.
  old_front_id=$(tr -d '"' 2>/dev/null < "${run_dir}/option-page_on_front.value")
  case "$old_front_id" in
    ''|null|false|0) return 0 ;; # A never had a front page configured — nothing to check
  esac
  local expected_new_id
  expected_new_id=$(awk -F'\t' -v old="$old_front_id" '$1==old{print $2}' "$id_map_tsv" 2>/dev/null)
  if [ -z "$expected_new_id" ]; then
    log_error "A's page_on_front (page ${old_front_id}) has no corresponding entry in id-map.tsv — the remap did not happen (or the ID mapper was missing, or the imported post silently failed), so B's page_on_front cannot be verified against it"
    return 1
  fi

  local live_front_id
  live_front_id=$(wp_remote b option get page_on_front 2>/dev/null || echo "")
  if [ "$live_front_id" != "$expected_new_id" ]; then
    log_error "page_on_front on B is '${live_front_id}', expected the remap of A's front page: '${expected_new_id}'"
    return 1
  fi
  wp_remote b post get "$live_front_id" --field=ID >/dev/null 2>&1 || {
    log_error "page_on_front on B ('${live_front_id}') does not resolve to an existing page"
    return 1
  }
}

# verify_nav_present <manifest_json> — design doc §6.5 ("verifies the
# expected navigation is present"). Only applicable when wp_navigation was
# actually part of this run's migrate selection (§13: nav scope is A-only,
# block-theme wp_navigation posts specifically) — a no-op otherwise, since B
# not having sitegraft-managed navigation is either not this run's job (nav
# wasn't selected) or B's own pre-existing navigation (§13: never sitegraft's
# business). When it WAS selected, requires at least one wp_navigation post
# to actually exist on B post-graft — distinct from the generic post_type
# recount (§6.5's first bullet), which only compares counts and would not by
# itself catch a wp_navigation post that imported empty of content.
verify_nav_present() {
  local manifest="$1"
  echo "$manifest" | jq -e '[.migrate[].post_types[]?] | index("wp_navigation") != null' >/dev/null 2>&1 || return 0
  local count
  count=$(wp_remote b post list --post_type=wp_navigation --field=ID 2>/dev/null | grep -c . || true)
  if [ "${count:-0}" -lt 1 ]; then
    log_error "wp_navigation was migrated but B has no navigation post after graft"
    return 1
  fi
}

# verify_http_smoke <url> [expected_marker] — design doc §6.5: best-effort
# (curl -sS -o /dev/null -w '%{http_code}') that B's root URL returns 200.
# Deliberately best-effort, not a hard-fail gate on its own absence: a URL is
# optional in a profile (lib/profile.sh — SITE_B_URL is not a required key),
# and this tool has no business making network reachability a precondition
# for verifying WordPress-data-level correctness.
#
# Extended beyond a bare 200 (feedback_runtime_smoke_test_new_routes.md — a
# build/route returning 200 is not proof it rendered anything real, "acme
# does not return 500" is a much weaker claim than "acme renders the expected
# page"): when a marker string is given, the response BODY must also contain
# it — a 200 serving a blank page, a caching layer's stale error page, or an
# unrelated default page all still return 200 and would pass a status-only
# check.
verify_http_smoke() {
  local url="$1" marker="${2:-}"
  [ -n "$url" ] || return 0
  command -v curl >/dev/null 2>&1 || { log_warn "curl not found — skipping the HTTP smoke check (best-effort only)"; return 0; }

  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
  if [ "$code" != "200" ]; then
    log_error "HTTP smoke check: ${url} returned ${code}, expected 200"
    return 1
  fi
  [ -n "$marker" ] || return 0

  local body
  body=$(curl -sS --max-time 10 "$url" 2>/dev/null || echo "")
  case "$body" in
    *"$marker"*) : ;;
    *)
      log_error "HTTP smoke check: ${url} returned 200 but its rendered body does not contain the expected marker ('${marker}') — a green status code is not proof the page actually rendered (build green != route OK)"
      return 1
      ;;
  esac
}

# phase_verify --profile <name> [--run <run-dir>] [--dry-run] — design doc
# §6.5. Read-only against B end-to-end: every check above either reads (get/
# list/query) or is a pure function over already-fetched data. Writes ONLY
# to the orchestrator's own run_dir (the report file) — B is never mutated by
# this phase, by construction (grep the function bodies above: no
# option update/post update/db import/search-replace anywhere in this file).
#
# --dry-run is accepted for CLI-contract consistency with every other phase
# (bin/sitegraft's global --dry-run parsing, Step 6) but MUST be neutralized
# immediately below, the same way phase_scan's own M6 fix (lib/inventory.sh)
# already does — this comment used to claim dry-run "has no real effect
# here beyond that", which was wrong and a real bug (MAJOR-A, review
# fix-pack): every check in this file reads B through wp_remote, and
# wp_remote's own real command is wrapped in run_or_echo (lib/core.sh) —
# under SITEGRAFT_DRY_RUN=1 that means EVERY read below returns the literal
# text "[dry-run] wp_remote b option get ..." instead of B's actual value.
# verify_options_match/verify_page_on_front/verify_nav_present/
# verify_domain_absent and the checksum recompute would all parse that
# garbage as real data and — being written fail-closed on purpose — report a
# false HARD FAIL on a graft that actually succeeded. Reachable for real via
# the plain `sitegraft verify --profile X --dry-run` CLI invocation now that
# bin/sitegraft strips --dry-run globally. verify is read-only against B
# already (see this function's own header comment above) — there is nothing
# for --dry-run to protect here, so the fix is identical in shape to scan's:
# accept the flag, then immediately run the real reads anyway.
phase_verify() {
  local profile="" run_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      --dry-run) SITEGRAFT_DRY_RUN=1; shift ;;
      *) log_error "unknown flag for verify: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "verify requires --profile <name>"; return 1; }

  if is_dry_run; then
    log_info "verify is read-only against B (design doc §6.5) — --dry-run has nothing to simulate; running the real checks as usual"
    # shellcheck disable=SC2034 # read via lib/core.sh's is_dry_run(), a different sourced file in the same bash process, not in this one
    SITEGRAFT_DRY_RUN=0
  fi

  profile_load "$profile" || return 1

  [ -n "$run_dir" ] || run_dir=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1 || true)
  [ -n "$run_dir" ] || {
    log_error "no scan/plan run found for profile ${profile} — run 'sitegraft scan' and 'sitegraft plan' first"
    return 1
  }
  [ -f "${run_dir}/manifest.json" ] || {
    log_error "no manifest found at ${run_dir}/manifest.json — nothing to verify against"
    return 1
  }
  local manifest; manifest=$(cat "${run_dir}/manifest.json")
  local id_map_tsv="${run_dir}/id-map.tsv"
  local report="${run_dir}/verify-report.md"
  local hard_fail=0

  {
    echo "# sitegraft verify report"
    echo
    echo "run: ${run_dir}"
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
    echo
  } > "$report"

  # --- protected-data checksums (finding A5's normalization AND the
  # table-suffix-to-live-prefix resolution, both reused verbatim from
  # backup_compute_protected_checksums, lib/backup.sh — never a second,
  # independently-drifting implementation) ----------------------------------
  local recomputed
  recomputed=$(backup_compute_protected_checksums b "$manifest" 2>>"$report") || recomputed='{}'
  local checksum_diff
  if checksum_diff=$(verify_compare_checksums "$manifest" "$recomputed" 2>>"$report"); then
    echo "- [x] protected data unchanged" >> "$report"
  else
    echo "- [ ] **HARD FAIL: protected data changed** — ${checksum_diff}" >> "$report"
    hard_fail=1
  fi

  # --- migrated option values (finding B3; count-vs-selected reporting is
  # issue #23 — "migrated options match" must never be ticked plain having
  # compared zero of N selected keys, the same defect PR #9 already fixed
  # for "protected data unchanged") -------------------------------------------
  local options_output options_result=0
  options_output=$(verify_options_match "$run_dir" "$manifest" 2>>"$report") || options_result=1
  local options_compared=0 options_total=0
  case "$options_output" in
    *OPTIONS_COMPARED:*)
      local options_summary="${options_output##*OPTIONS_COMPARED:}"
      options_compared="${options_summary%%:*}"
      options_total="${options_summary##*:}"
      ;;
  esac
  if [ "$options_result" -ne 0 ]; then
    echo "- [ ] **HARD FAIL: migrated option value mismatch** — see above" >> "$report"
    hard_fail=1
  elif [ "$options_total" -eq 0 ]; then
    echo "- [x] migrated options match A's values on B (0 of 0 compared — no options were selected for migration)" >> "$report"
  elif [ "$options_compared" -eq 0 ]; then
    # total > 0 but nothing was actually compared: the exact "0 of N" shape
    # issue #23 describes (an interrupted run resumed past migrate_options).
    # verify_options_match's own return code stays 0 here on purpose (see
    # its header comment — a key graft never reached is not ITS job to fail
    # on), but the report must not read as a plain pass either.
    echo "- [ ] migrated options match A's values on B: **UNVERIFIED — 0 of ${options_total} selected option(s) could be compared** (not written to disk this run — see lib/verify.sh's verify_options_match; not a hard fail on its own, but not a pass)" >> "$report"
  else
    echo "- [x] migrated options match A's values on B (${options_compared} of ${options_total} compared)" >> "$report"
  fi

  # --- A's domain absent from the content graft imported (finding B3,
  # rescoped and rebuilt in the security-review fix-pack — see
  # verify_domain_absent's own comment for why).
  #
  # Issue #22 fix: this used to be wrapped in `if [ -n "$domain" ]` with
  # NOTHING written to the report at all when it was false — no [x], no
  # [ ], no warning, and "Result: PASS" printed regardless. A reader could
  # not tell "A's domain is confirmed absent" from "that was never looked
  # at". The check must now be accounted for in every run: either genuinely
  # verified, or explicitly marked not applicable — never silently missing.
  # ---------------------------------------------------------------------------
  local domain; domain=$(echo "$manifest" | jq -r '.options.search_replace.from // ""')
  [ "$domain" = "null" ] && domain=""
  if [ -z "$domain" ]; then
    echo "- [x] A's domain string is absent from the content graft imported (not applicable — no domain was configured for this migration)" >> "$report"
  elif verify_domain_absent "$run_dir" "$id_map_tsv" "$manifest" "$domain" 2>>"$report"; then
    echo "- [x] A's domain string is absent from the content graft imported (migrated posts + migrated options)" >> "$report"
  else
    echo "- [ ] **HARD FAIL: A's domain string is still present in content graft imported, or the check could not be verified** — see above" >> "$report"
    hard_fail=1
  fi

  # --- page_on_front resolves to the CORRECT remapped page (finding B3;
  # issue #12 — the manifest is what lets verify_page_on_front tell "wasn't
  # part of this run" apart from "was selected but the remap didn't happen",
  # see that function's own header comment) ----------------------------------
  local front_result=0
  verify_page_on_front "$run_dir" "$id_map_tsv" "$manifest" 2>>"$report" || front_result=1
  if [ "$front_result" -eq 0 ]; then
    echo "- [x] page_on_front resolves to the correctly remapped page (or A never configured one)" >> "$report"
  else
    echo "- [ ] **HARD FAIL: page_on_front does not resolve to the correctly remapped page** — see above" >> "$report"
    hard_fail=1
  fi

  # --- orphan post_parent references (design doc §9.2/§11 — orphans FOUND
  # is a warning, not a hard failure: signals a manifest selection mistake,
  # fixed by hand via id-map.tsv, not something verify can safely
  # auto-correct). Security-review fix-pack (Kimi, same fail-open class as
  # verify_domain_absent above): the previous `2>/dev/null || echo ""`
  # treated a QUERY ERROR (wp-cli failure, connectivity issue) identically
  # to "confirmed zero orphans" — a check that can never actually fail is as
  # dangerous as one with broken syntax. A query that errors is now reported
  # as UNKNOWN and IS a hard failure (an unverified check must never pass
  # silently); only a query that ran and genuinely found nothing prints the
  # pass line, and only a query that ran and found real orphans prints the
  # (non-blocking) warning. -------------------------------------------------
  local orphans orphan_rc
  orphans=$(graft_check_orphan_parents 2>>"$report") && orphan_rc=0 || orphan_rc=$?
  if [ "$orphan_rc" -ne 0 ]; then
    echo "- [ ] **HARD FAIL: the orphan post_parent check could not run (query error) — treated as UNKNOWN, never as a silent pass** — see above" >> "$report"
    hard_fail=1
  elif [ -z "$orphans" ]; then
    echo "- [x] no orphan post_parent references" >> "$report"
  else
    echo "- [ ] orphan post_parent references found (post ID(s), design doc §9.2 — check manually / remap via id-map.tsv): $(echo "$orphans" | tr '\n' ' ')" >> "$report"
  fi

  # --- expected navigation present -------------------------------------------
  if verify_nav_present "$manifest" 2>>"$report"; then
    echo "- [x] expected navigation is present on B (or wp_navigation was not part of this run's migrate selection)" >> "$report"
  else
    echo "- [ ] **HARD FAIL: wp_navigation was migrated but B has no navigation post** — see above" >> "$report"
    hard_fail=1
  fi

  # --- HTTP smoke check (best-effort — never a hard fail on its own absence,
  # design doc §6.5) ----------------------------------------------------------
  local site_b_url="${SITE_B_URL:-}"
  local front_title=""
  if [ -n "$site_b_url" ]; then
    front_title=$(wp_remote b post get "$(wp_remote b option get page_on_front 2>/dev/null || echo "")" --field=post_title 2>/dev/null || echo "")
    if verify_http_smoke "$site_b_url" "$front_title" 2>>"$report"; then
      echo "- [x] HTTP smoke check: ${site_b_url} returns 200 with expected content (best-effort)" >> "$report"
    else
      echo "- [ ] HTTP smoke check FAILED (best-effort, not a hard fail — see above): ${site_b_url}" >> "$report"
    fi
  else
    echo "- [ ] HTTP smoke check skipped — no SITE_B_URL configured in this profile" >> "$report"
  fi

  # --- stack re-licensing reminder (design doc §12/§6.5) — not a pass/fail
  # check: licensing isn't something sitegraft can verify. Just a reminder
  # that would otherwise be easy to forget once the run reports success. ----
  local copied; copied=$(echo "$manifest" | jq -r '.stack // {} | to_entries[] | select(.value.resolution == "copy") | .key')
  if [ -n "$copied" ]; then
    echo "- [ ] **REMINDER: re-license on B before going live** — copied from A and activated: $(echo "$copied" | tr '\n' ' ')" >> "$report"
  fi

  {
    echo
    if [ "$hard_fail" -eq 0 ]; then
      echo "**Result: PASS**"
    else
      echo "**Result: HARD FAIL — see the item(s) above marked HARD FAIL. Do not consider this graft done.**"
    fi
  } >> "$report"

  log_info "verify report written: ${report}"
  return "$hard_fail"
}
