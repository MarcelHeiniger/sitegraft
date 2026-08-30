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
  local pre post
  pre=$(echo "$manifest" | jq '.checksums_protected_pre_graft')
  post="$recomputed"

  # issue #97: backup_compute_protected_checksums (lib/backup.sh) records a
  # table it could not export as the literal string "unreadable" — never a
  # valid "sha256:..." value — rather than silently checksumming it as
  # though its content were empty. By construction this can only ever
  # appear under an "_unclaimed:<table>" key here: a DECLARED module's
  # table failing to export makes that function return non-zero, which
  # phase_verify's own pre-existing #33 HARD FAIL already catches before
  # this function is ever called (see backup_compute_protected_checksums'
  # own header comment for the full split).
  #
  # Split out FIRST, before the plain string-diff below ever runs. Compared
  # straight through it, "unreadable" vs "unreadable" would silently read
  # as a MATCH — the issue's own measured worst case, sha256("") matching
  # itself because the table was never actually read either time, one level
  # below where #33 already closed the identical shape for a total
  # recompute failure. "unreadable" vs a real checksum would, just as
  # wrongly, read as a content CHANGE it never actually observed. Neither
  # is right: a table this run could not read on at least one side is its
  # own third outcome, NOT VERIFIED — not a confirmed match, not a
  # confirmed change.
  local unread
  unread=$(jq -n --argjson pre "$pre" --argjson post "$post" \
    '[$pre | keys[] as $k | select($pre[$k] == "unreadable" or $post[$k] == "unreadable") | $k]')

  local diffs
  diffs=$(jq -n --argjson pre "$pre" --argjson post "$post" --argjson unread "$unread" \
    '[$pre | keys[] as $k | select(($unread | index($k)) == null) | select($pre[$k] != $post[$k]) | $k]')

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

  local unread_count; unread_count=$(echo "$unread" | jq 'length')
  if [ "$unread_count" != "0" ]; then
    log_warn "table(s) could not be read on at least one side of this run and were excluded from the changed/unchanged comparison — not verified this run, neither confirmed unchanged nor flagged as changed: $(echo "$unread" | jq -r 'map(sub("^_unclaimed:"; "")) | join(", ")')"
  fi

  if [ "$(echo "$soft" | jq 'length')" != "0" ]; then
    log_warn "unclaimed table(s) on B changed during this run: $(echo "$soft" | jq -r 'join(", ")') — no module declares them, so this is reported rather than failed. Expected for tables WordPress writes on its own (the action scheduler, sessions, usermeta after a login). If any of these hold data that must be guaranteed untouched, write a module declaring them."
  fi

  if [ "$(echo "$hard" | jq 'length')" != "0" ]; then
    log_error "protected data changed for: $(echo "$hard" | jq -r 'join(", ")')"
    echo "$hard"
    return 1
  fi

  # Consumed by phase_verify, below, to move the report's "protected data
  # unchanged" line into its own INCOMPLETE bucket instead of the plain PASS
  # tick when this is non-zero — the same parseable-suffix convention
  # verify_options_match already uses (OPTIONS_COMPARED:) for the identical
  # reason: a caller downstream of a `run`/`$(...)` capture needs a count
  # this function alone can produce, without a second, independently-
  # drifting recount in phase_verify.
  echo "UNREADABLE_COUNT:${unread_count}"
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
  local keys
  keys=$(echo "$manifest" | jq -r '[.migrate[].option_keys[]?] | unique[]')
  # A read loop over fd 3, not `for key in $(...)` (issue #34) — the exact
  # same fix, for the exact same reason, as graft_migrate_options
  # (lib/graft.sh): the old form relied on UNQUOTED word splitting, so an
  # option key containing whitespace became two keys, neither of which has
  # an "option-<fragment>.value" file on disk, so both silently hit the
  # `[ -f ... ] || continue` guard below — a key that was never genuinely
  # compared, AND `total` inflated by one per fragment rather than one per
  # real key, corrupting the "N of M compared" count issue #23/#26 added
  # specifically so a shortened comparison could never pass unnoticed.
  # #29 already fixed this shape in graft_migrate_options and rejects
  # comma/space names at three entry points (module_selection,
  # manifest_validate, graft_migrate_options itself) — that rejection is
  # deliberately NOT repeated here, but not because it's already closed
  # upstream for every manifest this function sees: unlike
  # graft_migrate_options, which WRITES to B's live database and must
  # refuse an ambiguous name outright, this function only reads and
  # compares — handling the key correctly is strictly better than refusing
  # it. And phase_verify does NOT re-run manifest_validate before calling
  # this (it only checks the manifest file is valid JSON, then `cat`s it);
  # manifest_validate is only ever called from manifest_freeze. So a
  # manifest hand-edited after being frozen reaches here UNVALIDATED —
  # exactly the scenario issue #34 names (lib/graft.sh's own comment on
  # graft_migrate_options documents the identical gap: "a manifest edited
  # AFTER being frozen never passes through validation again either"). The
  # fd-3 read below is what makes that safe here, not an upstream check.
  # fd 3 rather than stdin also matters for a second, independent reason:
  # the loop body calls wp_remote, which shells out to `ssh` with no `-n`
  # and no `</dev/null` (lib/inventory.sh) — `ssh` DRAINS stdin. A
  # stdin-fed loop would have the very first iteration's `ssh` call
  # swallow every remaining key, silently truncating the comparison to one
  # key while still reporting a clean "1 of 1" pass (reproduced; see this
  # function's own test "reads keys on fd 3, so a loop-body command that
  # drains stdin (ssh) cannot swallow the remaining keys").
  while IFS= read -r key <&3; do
    [ -n "$key" ] || continue
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
  done 3<<< "$keys"
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
#
# Return codes are three-valued, like verify_page_on_front's (Viktor's
# re-review of PR #26, BLOCKING): 0 = examined a non-empty scope and found
# the domain absent, 1 = found it (or the check's own machinery failed —
# fail closed), 2 = COULD NOT VERIFY, because the scope was EMPTY. That last
# state is not hypothetical and it is not benign: with no id-map.tsv and no
# selected option keys, the payload is `{"post_ids": [], "option_keys": []}`,
# the PHP body below loops over two empty arrays, `$hits` stays empty, and
# the function would return "OK" having examined literally nothing — the
# exact "0 of N read as a pass" defect issue #23 exists to stop, reappearing
# inside the check that closes issue #22. It is reachable in precisely the
# run this file is about: lib/graft.sh warns and leaves id-map.tsv untouched
# when the ID-mapper mu-plugin did not run, which makes every remap after it
# a no-op — and it is the one run where a stale domain is MOST likely.
#
# The scope size is also echoed on stdout as `DOMAIN_SCOPE:<posts>:<options>`
# (same machine-readable-marker convention as verify_options_match's
# OPTIONS_COMPARED above, and read the same way by phase_verify) so the
# report can state what was examined instead of just ticking a box. A count
# on the line is what makes this class of defect impossible to reintroduce
# unnoticed.
verify_domain_absent() {
  local run_dir="$1" id_map_tsv="$2" manifest="$3" domain="$4"
  [ -n "$domain" ] || return 0

  # Issue #73, second guard: the same "unknown" placeholder / broken-`to`
  # shape that made graft_search_replace_domain (lib/graft.sh) run a real,
  # silently-successful no-op (or actively corrupting) search-replace also
  # blinds THIS check — searching B's content for a string that was never
  # usable to begin with reliably finds nothing, so a manifest that could
  # never have had a working domain remap would otherwise report "the
  # domain is absent" as a genuine, verified finding. manifest_validate is
  # meant to refuse freezing such a manifest in the first place; this is
  # the belt for one that reaches verify without passing through that gate
  # (SITEGRAFT_MANIFEST_PREFILLED, or hand-edited after freezing).
  #
  # graft_domain_remap_unusable_reason (lib/graft.sh — `verify` loads this
  # file too, see bin/sitegraft's `require_lib graft 4`) is the SAME check
  # graft_search_replace_domain and graft_migrate_options use, so "usable"
  # cannot drift between what graft was willing to run and what verify is
  # willing to trust the result of (BLOCKER-1, second review round: an
  # earlier version of this guard only ever compared `domain` against
  # "unknown"/`to`, never checked whether `to` ITSELF was empty or
  # "unknown" — exactly the shape a B-side scan failure produces, and the
  # one case this whole check exists to catch: A's home_url resolved fine,
  # B's didn't, graft wrote B's own broken placeholder into every migrated
  # page, and a check that only looked at `domain` never noticed). `to`
  # comes from THIS manifest (not a second parameter) — verify already has
  # it, and every other verify_domain_absent call site already passes the
  # manifest, so no signature change was needed to close this.
  local domain_to unusable_reason
  domain_to=$(echo "$manifest" | jq -r '.options.search_replace.to // ""')
  unusable_reason=$(graft_domain_remap_unusable_reason "$domain" "$domain_to")
  if [ -n "$unusable_reason" ]; then
    log_error "domain-absence check refused: ${unusable_reason}. This manifest could never have had a working domain remap, so 'the domain is absent from B' cannot be a genuine finding here — it would just mean nothing usable was ever searched for (issue #73, same guard as graft_search_replace_domain's). Rebuild the manifest: set SITE_A_URL/SITE_B_URL in the profile to each site's real public domain and re-run 'sitegraft plan' -- plan_defaults reads those in PREFERENCE to scan's own home_url guess, which a proxied/tunneled/local-dev site (DDEV's own *.ddev.site, an SSH tunnel, a reverse proxy) can get wrong in a way no re-scan fixes. Failing that: re-run 'sitegraft scan' if a value is genuinely missing, or hand-edit scan-a.json/scan-b.json's home_url yourself if scan ran cleanly but simply recorded the wrong domain."
    return 1
  fi

  local post_ids_json option_keys_json payload_json remote_path lib_path
  post_ids_json='[]'
  [ -s "$id_map_tsv" ] && post_ids_json=$(graft_migrated_post_ids_json "$id_map_tsv")
  option_keys_json=$(echo "$manifest" | jq -c '[.migrate[]?.option_keys[]?] | unique')

  local post_count option_count
  post_count=$(echo "$post_ids_json" | jq 'length')
  option_count=$(echo "$option_keys_json" | jq 'length')
  echo "DOMAIN_SCOPE:${post_count}:${option_count}"
  if [ "$post_count" -eq 0 ] && [ "$option_count" -eq 0 ]; then
    log_error "domain-absence check has nothing in scope to examine: this run recorded 0 migrated post(s) (${id_map_tsv}) and 0 migrated option(s) in its manifest — a check that examined nothing must never report the domain absent"
    return 2
  fi

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
#
# Return codes are deliberately three-valued, not a plain boolean: 0 =
# verified correct (or genuinely not applicable), 1 = verified WRONG (a
# hard failure), 2 = COULD NOT VERIFY at all (see below) — phase_verify
# tells these apart and must never fold 2 into a pass (Nat's review of PR
# #26, same root cause as issue #23: "0 of N compared" silently read as a
# pass is the exact defect this file exists to stop making).
#
# Nat's review, blocking finding: page_on_front IS selected here (the guard
# just above already returned if it weren't), so graft_migrate_options
# (lib/graft.sh) unconditionally writes option-page_on_front.value for it —
# every selected key gets a file in the same pass, nothing selective about
# it. The file's ABSENCE therefore means the migrate_options step itself
# never reached this run_dir at all (interrupted mid-loop, not yet resumed)
# — the identical "0 of N" shape issue #23 fixed for the options-match
# report line, just manifesting in this sibling function instead. The OLD
# code read the missing file via `tr -d '"' < missing_file`, silently got
# back an empty string, and the ''|null|false|0 case right below folded
# that into "A never configured one" — a pass on data that was simply never
# produced, indistinguishable from the genuine "A had none" case it was
# meant to also cover. Checking existence FIRST, before ever reading the
# file's content, is what makes the two cases distinguishable again: a file
# that exists and says "0" is a real, positive statement from A; a file
# that does not exist is silence, and silence must never be read as a pass.
#
# Why the two missing-file cases are treated ASYMMETRICALLY (Viktor's
# re-review of PR #26, N9 — the asymmetry is deliberate and worth stating,
# because it looks arbitrary otherwise): a missing `option-page_on_front.value`
# is INCOMPLETE (2), but a missing id-map.tsv ENTRY for a front page A really
# had is a HARD FAIL (1). The difference is what each absence proves about
# B's current state. A missing .value file means graft never got as far as
# recording A's value — nothing was written to B on the strength of it, so B
# is merely UNKNOWN. A missing id-map entry means the import DID run (posts
# were created on B) but without a working remap, so B's page_on_front is
# now pointing at whatever ID it pointed at before: confirmed-wrong, not
# just unknown. Confirmed-wrong is a hard failure; unknown is not.
#
# Success is also three-valued in MEANING even though all three exit 0 — not
# selected / A never configured one / verified correct against B are three
# different statements, and the report must not print one line for all
# three (that ambiguous disjunction is exactly what issue #12 was filed
# about). Each success path therefore echoes a marker on stdout —
# `PAGE_ON_FRONT:not-selected`, `PAGE_ON_FRONT:a-had-none`,
# `PAGE_ON_FRONT:verified:<id>` — the same machine-readable-marker
# convention verify_options_match and verify_domain_absent use, read by
# phase_verify to pick the right report line. A success path added later
# without a marker is reported as UNVERIFIED rather than silently inheriting
# one of the three claims.
#
# The INCOMPLETE (2) case is similarly not one undifferentiated reason:
# `PAGE_ON_FRONT:non-numeric-map-entry` (issue #69) marks the specific
# sub-case of "id-map.tsv has an entry, but its column 2 is not a numeric
# id" apart from the plain "the value file was never written this run" case
# — the two are different facts about what happened and phase_verify reports
# them with different wording (see its own `front_rc -eq 2` handling).
verify_page_on_front() {
  local run_dir="$1" id_map_tsv="$2" manifest="$3"
  echo "$manifest" | jq -e '[.migrate[].option_keys[]?] | index("page_on_front") != null' >/dev/null 2>&1 \
    || { echo "PAGE_ON_FRONT:not-selected"; return 0; } # not part of this run's migrate selection — nothing to check
  if [ ! -f "${run_dir}/option-page_on_front.value" ]; then
    log_error "page_on_front was selected for migration but ${run_dir}/option-page_on_front.value does not exist — graft's migrate_options step for this key never ran (an interrupted run resumed past it?), so page_on_front cannot be verified"
    return 2
  fi
  local old_front_id
  old_front_id=$(tr -d '"' 2>/dev/null < "${run_dir}/option-page_on_front.value")
  case "$old_front_id" in
    ''|null|false|0) echo "PAGE_ON_FRONT:a-had-none"; return 0 ;; # A never had a front page configured — nothing to check
  esac
  local expected_new_id
  expected_new_id=$(awk -F'\t' -v old="$old_front_id" '$1==old{print $2}' "$id_map_tsv" 2>/dev/null)
  if [ -z "$expected_new_id" ]; then
    log_error "A's page_on_front (page ${old_front_id}) has no corresponding entry in id-map.tsv — the remap did not happen (or the ID mapper was missing, or the imported post silently failed), so B's page_on_front cannot be verified against it"
    return 1
  fi
  # Issue #69: this lookup has no `$3` type filter -- any id-map.tsv row
  # whose column 1 numerically matches old_front_id wins, whatever column 3
  # says. Identical shape to core_wp_post_import's own page_on_front/
  # page_for_posts WRITE lookup (modules/core-wp.sh), closed there for #61:
  # a legacy id-map.tsv written before that fix can carry a `term:` row
  # whose column 2 is the literal string "Array" (PHP's array-to-string
  # coercion from the since-removed wp_import_insert_term handler — see that
  # function's own comment for the full history). A numeric collision
  # between old_front_id and such a row's column 1 would land "Array" in
  # expected_new_id here too. Unlike the write side, this is a READ: the
  # value is only ever compared against B's live option, so the worst case
  # is a FALSE HARD FAIL on the collision, never a corrupting write — which
  # is why this was split out as non-blocking (issue #69). Still worth
  # closing: a false hard fail sends someone hunting a migration bug that
  # does not exist. Guarded on shape, same as the write side: a non-numeric
  # column 2 is reported as uncheckable (INCOMPLETE, not a hard fail),
  # rather than compared against B's live value as though it were a real id.
  case "$expected_new_id" in
    *[!0-9]*)
      log_error "A's page_on_front (page ${old_front_id}) maps to a non-numeric id in id-map.tsv ('${expected_new_id}') — refusing to treat this as B's expected page_on_front. This row was almost certainly written by an older sitegraft version (see modules/core-wp.sh's identical guard on the write side); report this with the run directory."
      echo "PAGE_ON_FRONT:non-numeric-map-entry"
      return 2
      ;;
  esac

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
  echo "PAGE_ON_FRONT:verified:${live_front_id}"
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
#
# Same marker convention, and for the same reason, as verify_page_on_front
# above (Viktor's re-review of PR #26, N1 — extended here because the
# navigation report line carried the identical ambiguous disjunction,
# "present on B (or wp_navigation was not part of this run's migrate
# selection)", ticked identically for two completely different facts):
# `NAV:not-selected` vs `NAV:verified:<count>`.
verify_nav_present() {
  local manifest="$1"
  echo "$manifest" | jq -e '[.migrate[].post_types[]?] | index("wp_navigation") != null' >/dev/null 2>&1 \
    || { echo "NAV:not-selected"; return 0; }
  local count
  count=$(wp_remote b post list --post_type=wp_navigation --field=ID 2>/dev/null | grep -c . || true)
  if [ "${count:-0}" -lt 1 ]; then
    log_error "wp_navigation was migrated but B has no navigation post after graft"
    return 1
  fi
  echo "NAV:verified:${count}"
}

# verify_id_references_resolve <run_dir> <id_map_tsv> — issue #84: the
# GENERAL guard the issue itself asked for, not a `mediaId`-only patch.
# Every known id-bearing block attribute this codebase's own remap hooks
# already understand -- `mediaId` (modules/etch.sh's etch_post_import,
# wp:etch/dynamic-image), `ref` (that SAME hook's component remap, AND
# modules/core-wp.sh's own nav `ref`, wp:etch/component / wp:core/
# navigation) and `parentPageID` (modules/core-wp.sh's
# _core_wp_remap_nav_page_ids, wp:core/page-list) -- is scanned on B's
# LIVE, post-graft content for every post THIS run imported, and every
# value found must resolve to an actual post on B, of ANY post type
# (issue #84 fix-pack, below) -- but ONLY that it exists, never that it
# is the RIGHT KIND of post. A mediaId pointing at a real page instead of
# an attachment still passes this guard; it asks "does this id resolve to
# a post on B", not "does it resolve to the post THIS attribute means".
# That is a real, accepted limit, not an oversight -- see the SCOPE
# section below for why a kind-aware check is out of reach for a dumb,
# fixed-key scan like this one.
#
# WHY THIS EXISTS, and why verify_migrated_content_matches_source (guard 1,
# above) cannot substitute for it: that guard proves B's content equals
# what A's content becomes AFTER graft's own remaps -- which is exactly
# the comparison a NEVER-APPLIED remap passes trivially. An id that was
# supposed to change and did not makes A's "already remapped" copy and
# B's real, unremapped copy byte-identical, so equality holds; this issue's
# own report calls that "structurally invisible" to a content-equality
# check, and it is right -- issue #84 was found live, by a human reading
# the rendered page, AFTER `verify` had already said PASS. This guard asks
# a different question, one equality cannot ask: not "does B match what
# was intended", but "does every id this content actually claims to
# reference exist, right now, on B" -- true (or false) regardless of
# whether the remap ran, ran correctly, or never ran at all. It would have
# caught issue #84's own defect before etch_post_import above ever learned
# to fix mediaId, and it closes the same class of bug for any FUTURE
# id-bearing attribute this codebase's remap hooks have not been taught
# yet -- a broken reference renders loud (DynamicImageBlock's own "Image
# with ID ... not found" placeholder) or silent (an empty template body,
# etch_post_import's own header comment on its `ref` remap) depending on
# which attribute it is; this guard does not care which, it only asks
# whether the target exists.
#
# --post_type=any IS NOT "every post type" -- fix-pack finding, execution-
# proven against a real Etch site. WordPress's own handling of "any"
# (WP_Query, and every `wp post list --post_type=any` call built on it)
# resolves to `get_post_types(['exclude_from_search' => false])`, which
# on a real Etch/block-theme site excludes wp_block, wp_template,
# wp_navigation and wp_global_styles -- precisely the post types this
# guard exists to scan, since those are exactly where a mediaId/ref/
# parentPageID reference lives. Measured directly: `wp post list
# --post__in=<a real wp_block id> --post_type=any --post_status=any`
# returned NOTHING for a genuinely published wp_block. The two wp_remote
# calls below need OPPOSITE fixes for this, because they ask different
# questions:
#
#   - The CONTENT FETCH (call 1) needs the post types THIS RUN actually
#     migrated -- known precisely, straight from id-map.tsv's own third
#     column (the same file that built $scope_csv two lines below it),
#     never "any" and never the manifest's *selected* types either: what
#     matters here is what id-map.tsv says actually landed on B, the same
#     "measure, don't assume" discipline verify_migrated_content_matches_
#     source's own B1 fix (this file, its own header comment) already
#     established for the identical mistake one function up.
#
#   - The EXISTENCE CHECK (call 2) cannot use ANY fixed post_type list,
#     precise or not: a reference can point at a post of a DIFFERENT type
#     than the citing post (a page's mediaId points at an attachment; a
#     wp_navigation's ref can point at a page) or, in principle, a type
#     this run never touched at all. `--post_type=any`'s exclude_from_
#     search filter is the wrong tool for "does this id exist as a post,
#     full stop" regardless of type -- so this call goes through a `wp
#     eval` testing `get_post()` per id instead, which is genuinely
#     type-agnostic (core's own function for "resolve an id to a post
#     object or null", with no post_type/post_status filtering built in
#     at all) rather than a second, still-incomplete post_type allowlist.
#
# SCOPE, deliberately narrow rather than a blind numeric sweep across
# every JSON value in the content: only the THREE attribute names this
# codebase's own module hooks already treat as unambiguous id references.
# A bare `"id":<n>` is NOT included here on purpose -- unlike
# `mediaId`/`ref`/`parentPageID`, that key is genuinely overloaded: an
# attachment id via graft's own generic remap (lib/php/content-remap-
# functions.php), a wp_navigation navigation-link's POST id only when
# paired with `"kind":"post-type"`, a TERM id when paired with
# `"kind":"taxonomy"` under the SAME `"id"` key, or a completely unrelated
# HTML `id="..."` attribute on an ordinary etch/element block. Deciding
# which meaning applies at each occurrence needs the same kind-aware
# walker modules/core-wp.sh's own _core_wp_nav_remap_php already is, not a
# second, independently-drifting reimplementation of it here — this
# function deliberately stays a dumb, fixed-key scan, the same discipline
# verify_migrated_content_matches_source's own header comment gives for
# not reimplementing each module's remap logic a second time.
#
# NOT MATCHED, noted rather than silently missed: a JSON-escaped mediaId
# (`\"mediaId\":\"35199\"`, the way Etch stores some blobs as double-
# encoded JSON elsewhere) is not matched by the grep patterns below, the
# same way etch_post_import's own remap does not write that form either
# -- not observed on the real site this was measured against (every
# instance was the plain, singly-encoded form), and the remap side and
# this guard are at least consistent with each other about it: neither
# would silently disagree with the other about content it can't see.
#
# Reported explicitly rather than silently absorbed into "the family this
# guard covers" (see this issue's own PR description for the fuller
# account, including the "bild"-style case one post away that this guard
# also cannot see: an Etch COMPONENT PROP with an operator-chosen name,
# e.g. `"bild":"35253"` passed as a prop into a component whose own
# template consumes it as `{props.bild}` inside a `mediaId` attribute one
# post away -- the literal id never appears under the literal key
# `mediaId` at THAT call site at all, so this dumb, fixed-key scan cannot
# find it there. Out of scope for this fix -- tracked as a follow-up
# issue, not left unfindable: the component post IS the source of truth
# for what a prop name resolves to, so a targeted follow-up can read it
# and close this deterministically, it just needs a different mechanism
# than this guard's fixed-key scan).
#
# Also deliberately narrow in WHAT'S SCANNED: only posts THIS RUN imported
# (id-map.tsv's own non-attachment, non-term rows — the SAME scope
# verify_migrated_content_matches_source uses, for the identical reason:
# B's pre-existing content is not this run's to police).
#
# Three-valued like the checks above it in this file: 0 + `ID_REFS:<checked>:0`
# = every reference found resolves (including the genuine "0 of 0" pass
# when nothing was migrated, or nothing migrated carried any of the three
# attributes at all); 1 = HARD FAIL, either a live `wp post list`/`wp eval`
# call itself failed (fail-closed — the same B4 discipline verify_migrated_
# content_matches_source's own header comment documents: a read that
# fails is UNKNOWN, never a silent "nothing found") or a reference was
# found that does not resolve to any post on B.
verify_id_references_resolve() {
  local run_dir="$1" id_map_tsv="$2"

  [ -s "$id_map_tsv" ] || { echo "ID_REFS:0:0"; return 0; }

  local scope_csv
  scope_csv=$(awk -F'\t' '$3 != "attachment" && $3 !~ /^term:/ && $2 ~ /^[0-9]+$/ { print $2 }' "$id_map_tsv" \
    | sort -un | paste -sd, -)
  [ -n "$scope_csv" ] || { echo "ID_REFS:0:0"; return 0; }

  # The EXACT post types this run migrated, read straight from id-map.tsv's
  # own third column -- never "any" (see this function's own header
  # comment for why that silently drops wp_block/wp_template/wp_navigation)
  # and never the manifest's declared selection either: id-map.tsv is what
  # actually landed, which is what this call needs to find it again.
  # Non-empty whenever $scope_csv is (same source rows, same filters).
  local scope_types_csv
  scope_types_csv=$(awk -F'\t' '$3 != "attachment" && $3 !~ /^term:/ && $2 ~ /^[0-9]+$/ { print $3 }' "$id_map_tsv" \
    | sort -u | paste -sd, -)

  local live_json live_rc
  live_json=$(wp_remote b post list --post__in="$scope_csv" --post_type="$scope_types_csv" --post_status=any --fields=ID,post_content --format=json 2>/dev/null) && live_rc=0 || live_rc=$?
  if [ "$live_rc" -ne 0 ]; then
    log_error "could not read B's migrated post content for the id-reference guard (post list failed) — treated as UNKNOWN, never as a silent pass"
    return 1
  fi
  echo "$live_json" | jq -e . >/dev/null 2>&1 || {
    log_error "B's post list for the id-reference guard did not return valid JSON"
    return 1
  }

  # <citing_post_id>\t<referenced_id>\t<attribute> — one row per match,
  # written to a real file rather than accumulated in a bash variable: the
  # same referenced id can be cited by many posts, and reconstructing
  # embedded-newline records back out of a plain string (bash 3.2, no
  # associative arrays — docs/decisions/0003-bash-compatibility.md) is
  # exactly the class of bug an awk-processed TSV file sidesteps. `$$`-
  # suffixed for the same reason every other run_dir scratch file in this
  # file is (see _verify_wxr_items_remapped's own comment): two `verify`
  # runs against the same run_dir at once must never read or clobber each
  # other's file.
  local pairs_file="${run_dir}/.verify-id-refs-pairs.$$.tsv"
  : > "$pairs_file"
  chmod 600 "$pairs_file" 2>/dev/null || true
  local row pid content
  while IFS= read -r row <&3; do
    [ -n "$row" ] || continue
    pid=$(echo "$row" | jq -r '.ID')
    content=$(echo "$row" | jq -r '.post_content')
    # Same three literal JSON keys etch_post_import/_core_wp_remap_nav_page_ids
    # remap — see this function's own header comment for why "id" itself
    # is deliberately excluded, and for the escaped-JSON form neither side
    # matches. Quote-optional on mediaId only (issue #84's own PR
    # description: measured as the quoted-string form on a real site; the
    # bare-number form is not ruled out for a future Etch version, so both
    # are matched here, same as the remap side).
    printf '%s\n' "$content" | grep -oE '"mediaId":"?[0-9]+"?' | grep -oE '[0-9]+' \
      | while IFS= read -r rid; do printf '%s\t%s\tmediaId\n' "$pid" "$rid" >> "$pairs_file"; done
    printf '%s\n' "$content" | grep -oE '"ref":[0-9]+' | grep -oE '[0-9]+' \
      | while IFS= read -r rid; do printf '%s\t%s\tref\n' "$pid" "$rid" >> "$pairs_file"; done
    printf '%s\n' "$content" | grep -oE '"parentPageID":[0-9]+' | grep -oE '[0-9]+' \
      | while IFS= read -r rid; do printf '%s\t%s\tparentPageID\n' "$pid" "$rid" >> "$pairs_file"; done
  done 3<<< "$(echo "$live_json" | jq -c '.[]')"

  if [ ! -s "$pairs_file" ]; then
    rm -f "$pairs_file"
    echo "ID_REFS:0:0"
    return 0
  fi

  local referenced_json checked_total
  referenced_json=$(awk -F'\t' '{print $2}' "$pairs_file" | sort -un \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber)')
  checked_total=$(echo "$referenced_json" | jq 'length')

  # Existence, deliberately type-agnostic (this function's own header
  # comment explains why --post_type=any cannot serve this call): a `wp
  # eval` running get_post() per candidate id, on B, entirely server-side
  # -- core's own "resolve an id to a post object or null" primitive,
  # which applies no post_type or post_status filtering at all, so it
  # answers the actual question this check asks ("does this id exist as
  # ANY post on B") rather than an approximation of it through a post
  # type list that would need to be kept in step with every type B might
  # ever hold. Comment-free by construction, same as etch_post_import's
  # own heredoc (modules/etch.sh) -- see that function's own note on why
  # an unbalanced parenthesis inside a "//" comment on its own line broke
  # this bash's heredoc-inside-command-substitution parsing, execution-
  # proven while building this fix; kept out here rather than re-risked.
  local existing_ids exist_rc php
  php=$(cat <<PHP
\$ids = json_decode('${referenced_json}', true);
if ( ! is_array( \$ids ) ) { return; }
foreach ( \$ids as \$id ) {
	if ( null !== get_post( (int) \$id ) ) {
		echo \$id . "\n";
	}
}
PHP
)
  existing_ids=$(wp_remote b eval "$php" 2>/dev/null) && exist_rc=0 || exist_rc=$?
  if [ "$exist_rc" -ne 0 ]; then
    log_error "could not confirm which referenced id(s) exist on B for the id-reference guard (eval failed) — treated as UNKNOWN, never as a silent pass"
    rm -f "$pairs_file"
    return 1
  fi

  local existing_json missing_json missing_count
  existing_json=$(printf '%s\n' "$existing_ids" | jq -R -s -c \
    'split("\n") | map(select(length > 0) | select(test("^[0-9]+$")) | tonumber)')
  missing_json=$(jq -n --argjson a "$referenced_json" --argjson b "$existing_json" '$a - $b')
  missing_count=$(echo "$missing_json" | jq 'length')

  if [ "$missing_count" -gt 0 ]; then
    local detail="" rid citing
    while IFS= read -r rid; do
      [ -n "$rid" ] || continue
      citing=$(awk -F'\t' -v id="$rid" '$2==id{printf "%s(%s) ", $1, $3}' "$pairs_file")
      detail="${detail}${rid}[cited by ${citing% }] "
    done <<< "$(echo "$missing_json" | jq -r '.[]')"
    log_error "migrated content references id(s) that do not resolve to any post on B: ${detail% }"
    rm -f "$pairs_file"
    echo "ID_REFS:${checked_total}:${missing_count}"
    return 1
  fi

  rm -f "$pairs_file"
  echo "ID_REFS:${checked_total}:0"
}

# verify_component_prop_references_resolve <run_dir> <id_map_tsv> — issue
# #86, the follow-up verify_id_references_resolve's own header comment
# already named as unfindable by its fixed-key scan: an Etch component PROP
# with an OPERATOR-CHOSEN name (e.g. "bild" on the real site this issue
# reports), carrying an id at a CALL site's own attribute
# (`wp:etch/component {"ref":R,"attributes":{"bild":"35253"}}`) whose
# meaning only the REFERENCED COMPONENT's own body knows
# (`"mediaId":"{props.bild}"`). No fixed-key scan at the call site — not
# this file's own three-key guard above, not any future one — can ever find
# an id under a name only the component itself defines. modules/etch.sh's
# etch_post_import now remaps this at graft time (see that function's own
# extensive header comment for the full discovery-then-remap mechanism,
# what it measured on the real reference site, and its documented,
# depth-1 scope); this is the matching VERIFY side, so a broken reference
# through this path is provable the same way issue #84's was, not merely
# fixed on faith.
#
# A SEPARATE function rather than folded into verify_id_references_resolve:
# that guard is a deliberately DUMB, fixed-key scan (its own header
# comment) — three literal JSON keys, nothing else, precisely so it never
# has to understand Etch's component/props mechanism at all. This one
# inherently must: it reads a component's OWN body to learn what one of
# ITS props means before it can judge anything about a call site. Keeping
# that knowledge here, rather than growing the other guard's "dumb" claim
# into something that is not, keeps that guard's own contract honest.
#
# ONE `wp eval` call, not two like verify_id_references_resolve above:
# unlike that guard (which must ask two separate, differently-scoped
# questions — its own header comment explains why `--post_type=any` can
# serve neither), everything here — reading migrated components' own
# bodies, reading migrated posts' live content, and checking existence —
# is a get_post()/get_post_field() call B's own PHP can make directly,
# entirely server-side, with no post_type filtering question to get wrong.
#
# SCOPE, matching etch_post_import's own discovery exactly (same
# reasoning, not re-derived here — see that function's header comment):
# only migrated wp_block posts (id-map.tsv's own third column) are read
# for discovery; only their DIRECT `"mediaId"/"ref"/"parentPageID":
# "{props.X}"` usage marks a prop id-bearing — never by the prop's name,
# never because a call site's value merely looks numeric (exigence #3: a
# component's own "titre" holding "2024" must never be treated as an id).
# Only migrated, non-attachment, non-term posts (the SAME scope verify_id_
# references_resolve and verify_migrated_content_matches_source both use)
# are scanned for call sites.
#
# FIX-PACK (Viktor's review of PR #87) replaced the block-boundary matcher
# below with the SAME hand-rolled, linear, JSON-string-aware scanner
# (`sitegraft_json_span`/`sitegraft_find_component_blocks`/`sitegraft_
# attributes_span`) etch_post_import's own header comment documents in
# full — duplicated here rather than shared, for the same reason the
# discovery pattern above already is (this function's own header comment).
# The read-only consequence of the SAME blockers that mechanism closed on
# the write side:
#
#   - BLOCKER 1: the OLD PCRE-recursive pattern returned `false`
#     (PREG_BACKTRACK_LIMIT_ERROR) on a single unbalanced brace anywhere in
#     a citing post's JSON, and this guard treated that exactly like "no
#     matches" — a damaged block read back as a clean, green
#     `COMPONENT_PROP_REFS:0:0`, the opposite of what a guard whose whole
#     point is "prove it, don't assume it" is for. A block that fails to
#     parse now produces a `MALFORMED:<pid>` line, and the guard HARD
#     FAILS rather than silently passing over it (see below).
#   - BLOCKER 3: the OLD version decoded the whole block's JSON to find
#     `$decoded['attributes'][$propname]`, correctly, but that was never
#     the actual defect on the write side — reading is inherently safe
#     against blocker 3's OUT-OF-SCOPE-WRITE risk (nothing here writes
#     anything), so this guard's own main logic reads `$decoded
#     ['attributes']` straight off the whole-block decode below and never
#     calls `sitegraft_attributes_span` at all. That function is still
#     defined here — DEAD CODE in this file specifically, kept ONLY so the
#     two files' scanner functions stay byte-identical (review of PR #87
#     verified this with an md5 diff; a future edit to the block/span
#     finders that does not also touch this copy would silently drift
#     without either side's OWN test suite ever exercising the unused
#     copy's behavior to catch it). Documented here rather than silently
#     assumed equivalent.
#   - BLOCKER 2 (chained double-remap) has no read-side equivalent — this
#     guard never writes, so there is nothing to double-apply.
#
# Component composition (a migrated component's own body calling ANOTHER
# component) is depth 1, the same documented limit as the remap side.
# UNLIKE the remap side (which warns at graft time and moves on), THIS
# guard reports it as INCOMPLETE (nit 5, Viktor's review): etch_post_import's
# own warning is a different phase's log output, gone by the time an
# operator reads this report, and issue #86's own requirement — "the SAME
# pass must make verify able to see the case" — held at depth 1 and did
# NOT hold at depth 2 before this fix (a genuinely dangling id through such
# a composition read back as a green "0 found to check").
#
# Detected during discovery, but NOT short-circuited there (a LATER
# ordering fix, same review, next round): citing posts are still scanned
# for MALFORMED blocks even when composition was found, and MALFORMED, if
# present, is reported and returned INSTEAD of NESTED — a site that is
# BOTH composed AND carrying content this guard cannot even parse fails
# CLOSED (HARD FAIL), rather than settling for the softer "cannot fully
# vouch" INCOMPLETE a nested-only site gets. An earlier version returned
# on NESTED before the citing-post loop ran at all, which made that
# priority declared but unreachable — see verify_component_prop_
# references_resolve's own MALFORMED-handling comment below for the full
# account.
#
# Three-valued, like verify_page_on_front/verify_migrated_content_matches_
# source (see their own header comments) — NOT two-valued as the first
# version of this guard was. 0 + `COMPONENT_PROP_REFS:<checked>:0` = every
# discovered prop reference resolves (including the "0 checked" pass when
# no migrated component declares an id-bearing prop, or none of its
# callers pass a literal digit for one); 1 = HARD FAIL, the live `wp eval`
# call itself failed, a call site's JSON did not parse (MALFORMED), or a
# reference was found that does not resolve to any post on B (fail-closed,
# same B4 discipline as every guard in this file — a read that fails is
# UNKNOWN, never a silent pass); 2 = INCOMPLETE, component composition was
# detected and this guard's depth-1 discovery cannot fully vouch for this
# site's component props. HARD FAIL takes priority over INCOMPLETE when a
# run could in principle produce evidence for both (checked before it,
# below) — matching phase_verify's own "HARD FAIL, not INCOMPLETE, when a
# run has both" precedent (this file's own header comment on that exact
# rule).
verify_component_prop_references_resolve() {
  local run_dir="$1" id_map_tsv="$2"

  [ -s "$id_map_tsv" ] || { echo "COMPONENT_PROP_REFS:0:0"; return 0; }

  # No migrated component at all -- there is no post whose body could ever
  # declare a prop id-bearing, so there is nothing for a call site to be
  # judged against. Checked BEFORE issuing any wp_remote call (same
  # discipline verify_id_references_resolve's own "no-op" cases follow):
  # this is the common case for every graft that migrated no Etch
  # component, and it must cost nothing.
  local component_ids_json
  component_ids_json=$(awk -F'\t' '$3 == "wp_block" && $2 ~ /^[0-9]+$/ { print $2 }' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber) | unique')
  [ "$(printf '%s' "$component_ids_json" | jq 'length')" != "0" ] || { echo "COMPONENT_PROP_REFS:0:0"; return 0; }

  local citing_ids_json
  citing_ids_json=$(awk -F'\t' '$3 != "attachment" && $3 !~ /^term:/ && $2 ~ /^[0-9]+$/ { print $2 }' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber) | unique')
  [ "$(printf '%s' "$citing_ids_json" | jq 'length')" != "0" ] || { echo "COMPONENT_PROP_REFS:0:0"; return 0; }

  # Discovery pattern and call-site block pattern are the SAME two patterns
  # modules/etch.sh's etch_post_import uses, deliberately duplicated rather
  # than shared: `verify` does not load modules/*.sh at all (bin/sitegraft's
  # `verify` case never calls `modules_discover`, unlike `graft`'s), and
  # this file's own established convention for the fixed-key guard above is
  # exactly this — independently hardcode the same knowledge on both sides,
  # heavily cross-referenced, rather than reach into a module's internals
  # from a phase that structurally never loads them.
  local php
  php=$(cat <<PHP
function sitegraft_json_span( \$text, \$start ) {
	\$len = strlen( \$text );
	if ( \$start >= \$len || \$text[ \$start ] !== '{' ) { return null; }
	\$depth = 0;
	\$in_string = false;
	\$escaped = false;
	for ( \$i = \$start; \$i < \$len; \$i++ ) {
		\$ch = \$text[ \$i ];
		if ( \$in_string ) {
			if ( \$escaped ) {
				\$escaped = false;
			} elseif ( '\\\\' === \$ch ) {
				\$escaped = true;
			} elseif ( '"' === \$ch ) {
				\$in_string = false;
			}
			continue;
		}
		if ( '"' === \$ch ) {
			\$in_string = true;
		} elseif ( '{' === \$ch ) {
			\$depth++;
		} elseif ( '}' === \$ch ) {
			\$depth--;
			if ( 0 === \$depth ) {
				return array( \$start, \$i + 1 );
			}
		}
	}
	return null;
}
function sitegraft_find_component_blocks( \$content ) {
	\$blocks = array();
	\$prefix = '<!-- wp:etch/component ';
	\$offset = 0;
	\$len = strlen( \$content );
	while ( true ) {
		\$pos = strpos( \$content, \$prefix, \$offset );
		if ( false === \$pos ) { break; }
		\$json_start = \$pos + strlen( \$prefix );
		while ( \$json_start < \$len && ( ' ' === \$content[ \$json_start ] || "\t" === \$content[ \$json_start ] || "\n" === \$content[ \$json_start ] || "\r" === \$content[ \$json_start ] ) ) {
			\$json_start++;
		}
		if ( \$json_start >= \$len || '{' !== \$content[ \$json_start ] ) {
			if ( '-->' === substr( \$content, \$json_start, 3 ) || '/-->' === substr( \$content, \$json_start, 4 ) ) {
				\$offset = \$json_start;
				continue;
			}
			\$blocks[] = array( 'ok' => false, 'offset' => \$pos );
			\$offset = \$pos + strlen( \$prefix );
			continue;
		}
		\$span = sitegraft_json_span( \$content, \$json_start );
		if ( null === \$span ) {
			\$blocks[] = array( 'ok' => false, 'offset' => \$pos );
			\$offset = \$json_start + 1;
			continue;
		}
		\$blocks[] = array( 'ok' => true, 'start' => \$span[0], 'end' => \$span[1] );
		\$offset = \$span[1];
	}
	return \$blocks;
}
function sitegraft_attributes_span( \$content, \$block_start, \$block_end ) {
	\$needle = '"attributes":';
	\$pos = strpos( \$content, \$needle, \$block_start );
	if ( false === \$pos || \$pos >= \$block_end ) { return null; }
	\$val_start = \$pos + strlen( \$needle );
	while ( \$val_start < \$block_end && ' ' === \$content[ \$val_start ] ) { \$val_start++; }
	if ( \$val_start >= \$block_end || '{' !== \$content[ \$val_start ] ) { return null; }
	\$span = sitegraft_json_span( \$content, \$val_start );
	if ( null === \$span || \$span[1] > \$block_end ) { return null; }
	return \$span;
}

\$component_ids = json_decode('${component_ids_json}', true);
\$citing_ids = json_decode('${citing_ids_json}', true);
if ( ! is_array( \$component_ids ) || ! is_array( \$citing_ids ) ) { return; }
\$component_prop_map = array();
\$nested = array();
foreach ( \$component_ids as \$cid ) {
	\$cid = (int) \$cid;
	\$cbody = get_post_field( 'post_content', \$cid );
	if ( is_string( \$cbody ) && '' !== \$cbody ) {
		if ( preg_match_all( '/"(mediaId|ref|parentPageID)":"\{props\.([A-Za-z0-9_]+)\}"/', \$cbody, \$pm, PREG_SET_ORDER ) ) {
			foreach ( \$pm as \$prow ) {
				\$component_prop_map[ \$cid ][ \$prow[2] ] = \$prow[1];
			}
		}
		if ( preg_match( '#<!--\s+wp:etch/component\s+#', \$cbody ) ) {
			\$nested[] = \$cid;
		}
	}
}
\$pairs = array();
\$malformed = array();
foreach ( \$citing_ids as \$pid ) {
	\$pid = (int) \$pid;
	\$content = get_post_field( 'post_content', \$pid );
	if ( ! is_string( \$content ) || '' === \$content ) { continue; }
	\$blocks = sitegraft_find_component_blocks( \$content );
	foreach ( \$blocks as \$block ) {
		if ( empty( \$block['ok'] ) ) {
			\$malformed[] = \$pid;
			continue;
		}
		\$block_text = substr( \$content, \$block['start'], \$block['end'] - \$block['start'] );
		\$decoded = json_decode( \$block_text, true );
		if ( null === \$decoded ) {
			\$malformed[] = \$pid;
			continue;
		}
		if ( ! is_array( \$decoded ) || ! isset( \$decoded['ref'] ) ) { continue; }
		\$ref_id = (int) \$decoded['ref'];
		if ( ! isset( \$component_prop_map[ \$ref_id ] ) ) { continue; }
		\$call_attrs = ( isset( \$decoded['attributes'] ) && is_array( \$decoded['attributes'] ) ) ? \$decoded['attributes'] : array();
		foreach ( \$component_prop_map[ \$ref_id ] as \$propname => \$kind ) {
			if ( ! array_key_exists( \$propname, \$call_attrs ) ) { continue; }
			\$val = \$call_attrs[ \$propname ];
			if ( is_int( \$val ) ) {
				\$pairs[] = \$pid . ':' . ( (string) \$val ) . ':' . \$propname;
			} elseif ( is_string( \$val ) && preg_match( '/^\d+\z/', \$val ) ) {
				\$pairs[] = \$pid . ':' . \$val . ':' . \$propname;
			}
		}
	}
}
if ( ! empty( \$malformed ) ) {
	foreach ( array_unique( \$malformed ) as \$mpid ) {
		echo 'MALFORMED:' . \$mpid . "\n";
	}
	return;
}
if ( ! empty( \$nested ) ) {
	foreach ( \$nested as \$ncid ) {
		echo 'NESTED:' . \$ncid . "\n";
	}
	return;
}
// This short-circuit sits BELOW the citing-post loop on purpose (review
// round 4). An empty \$component_prop_map has two causes, not one: either
// no migrated component declares an id-bearing prop -- genuinely nothing
// for this guard to check -- or get_post_field came back empty for the
// migrated components, i.e. they never landed on B at all, which is a real
// migration failure. Above the loop this printed a green "0 found to check"
// over that second case AND swallowed any malformed call site with it.
// Below the loop, \$malformed is populated first, so a block this guard
// cannot parse is reported either way. The cost is one get_post_field per
// citing post on a site whose components declare no id-bearing prop; the
// sibling guards in this phase already load every migrated post.
if ( empty( \$component_prop_map ) ) {
	echo "NONE\n";
	return;
}
if ( empty( \$pairs ) ) {
	echo "NONE\n";
	return;
}
\$referenced = array();
foreach ( \$pairs as \$p ) {
	\$parts = explode( ':', \$p, 3 );
	\$referenced[ \$parts[1] ] = true;
}
foreach ( array_keys( \$referenced ) as \$rid ) {
	echo 'CHK:' . \$rid . ':' . ( null !== get_post( (int) \$rid ) ? '1' : '0' ) . "\n";
}
foreach ( \$pairs as \$p ) {
	echo 'PAIR:' . \$p . "\n";
}
PHP
)

  local out rc
  out=$(wp_remote b eval "$php" 2>/dev/null) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_error "could not evaluate migrated content's component-prop id references for the id-reference guard (eval failed) — treated as UNKNOWN, never as a silent pass"
    return 1
  fi

  if [ -z "$out" ] || [ "$out" = "NONE" ]; then
    echo "COMPONENT_PROP_REFS:0:0"
    return 0
  fi

  # Fix-pack (Viktor's review of PR #87, blocker 1; ordering fixed in a
  # later round, see below): a MALFORMED line means sitegraft_json_span
  # (the PHP above) could not parse at least one wp:etch/component call
  # site on B as balanced JSON -- the discovery/scan simply could not be
  # trusted for that post. Checked BEFORE the NESTED case below, and both
  # BEFORE the normal CHK/PAIR parse: a read that could not run correctly
  # is UNKNOWN, the same fail-closed discipline every other guard in this
  # file follows, and takes priority over the (softer) INCOMPLETE outcome
  # NESTED produces.
  #
  # That priority is REAL, not merely declared here: an earlier version of
  # this PHP short-circuited on NESTED (return) BEFORE the citing-post
  # loop that populates $malformed even ran, so the two markers could
  # never appear together and this bash-side ordering was unreachable in
  # practice -- a site both composed AND carrying a truncated block read
  # back as INCOMPLETE, never the HARD FAIL it should have been. The PHP
  # above now always scans the citing posts (populating $malformed) before
  # it decides what to report, so $nested -- collected earlier, during
  # component discovery -- and $malformed can both be set at once, and the
  # PHP echoes MALFORMED and returns first when it is. That is what gives
  # this bash-side ordering something real to prioritize between.
  if printf '%s
' "$out" | grep -q '^MALFORMED:'; then
    local malformed_posts
    malformed_posts=$(printf '%s
' "$out" | awk -F: '$1=="MALFORMED"{printf "%s ", $2}')
    log_error "could not parse a wp:etch/component call site as balanced JSON on B, on post(s): ${malformed_posts% } — component-prop id references on those post(s) could not be verified, treated as UNKNOWN, never as a silent pass"
    return 1
  fi

  # Fix-pack (Viktor's review, NIT 5): a migrated component whose OWN body
  # calls ANOTHER component (composition depth > 1) is exactly the gap
  # etch_post_import's own discovery documents and warns about at graft
  # time -- but that warning is a DIFFERENT phase's log output, gone by
  # the time an operator reads THIS report. Without this check, verify
  # printed a green "(0 found to check)" for a site where an id genuinely
  # hangs unresolved through that composition -- issue #86's own
  # requirement ("the SAME pass must make verify able to see the case")
  # held at depth 1 and silently did not at depth 2. Reported as
  # INCOMPLETE (2), not a silent pass and not a HARD FAIL: this guard's
  # OWN machinery is fine, it is TELLING you it cannot fully vouch for
  # this site's component props, the same distinction phase_verify already
  # draws for page_on_front/navigation above.
  if printf '%s
' "$out" | grep -q '^NESTED:'; then
    local nested_cids
    nested_cids=$(printf '%s
' "$out" | awk -F: '$1=="NESTED"{printf "%s ", $2}')
    log_error "component(s) ${nested_cids% } call another wp:etch/component in their own body (composition depth > 1) — this guard's discovery only looks one level deep (issue #86's own documented scope limit), so component-prop id references cannot be fully verified on this site"
    echo "COMPONENT_PROP_REFS:INCOMPLETE"
    return 2
  fi

  local checked=0 missing=0 detail="" line rid exists citing_desc
  while IFS= read -r line; do
    case "$line" in
      CHK:*)
        checked=$((checked + 1))
        rid="${line#CHK:}"; rid="${rid%%:*}"
        exists="${line##*:}"
        if [ "$exists" = "0" ]; then
          missing=$((missing + 1))
          citing_desc=$(printf '%s
' "$out" | awk -F: -v id="$rid" '$1=="PAIR" && $3==id {printf "%s(%s) ", $2, $4}')
          detail="${detail}${rid}[cited by ${citing_desc% }] "
        fi
        ;;
    esac
  done <<< "$out"

  if [ "$missing" -gt 0 ]; then
    log_error "migrated content references id(s), through an Etch component prop, that do not resolve to any post on B: ${detail% }"
    echo "COMPONENT_PROP_REFS:${checked}:${missing}"
    return 1
  fi

  echo "COMPONENT_PROP_REFS:${checked}:0"
}

# _verify_wxr_items_remapped <run_dir> <id_map_tsv> <manifest_json> — issue
# #52 shared helper behind both content-equality guards below. Parses A's
# already-exported WXR file(s) (${run_dir}/export/*.xml, written by
# graft_export_wxr, lib/graft.sh, and still on disk after the run) and
# rewrites each item's content/excerpt with the SAME two remaps graft
# itself applies (lib/php/content-remap-functions.php's
# sitegraft_remap_attachment_refs/sitegraft_remap_domain) — entirely on the
# orchestrator, via lib/php/verify-content-remap-cli.php (no network call
# to A or B for this step; see that file's own header for the full
# reasoning, and ADR 0008's "Required regardless" list for why this must
# compare against "the value graft was supposed to produce", not A's raw
# bytes).
#
# Memoized for the lifetime of the CURRENT process (issue #52 fix-pack,
# review finding M1) — both guards below call this, and each call is a
# real `php` invocation over A's WHOLE exported WXR, so calling it twice
# per `phase_verify` run parsed the same file(s) twice for no reason. A
# plain bash global variable does NOT work for this: every call site below
# invokes this function via command substitution (`x=$(_verify_wxr_items_
# remapped ...)`), and command substitution always forks a subshell in
# bash — a global this function sets would live and die inside that
# subshell, invisible to the parent shell the SECOND call runs in. A cache
# FILE survives across that subshell boundary; its name is suffixed with
# `$$` (this process's PID, same convention lib/backup.sh's own payload/
# stderr temp files now use — see this function's own use of `$$` below)
# so two verify runs against the same run_dir at once can never read or
# clobber each other's cache. phase_verify removes it once both guards
# have run (see phase_verify's own comment) — on the NORMAL exit path
# only. Review round 2 minor finding, acknowledged rather than fully
# closed: a `verify` killed (SIGKILL/power loss) before that cleanup line
# leaves the cache file behind, and a LATER, unrelated process that
# happens to reuse the same PID could in principle read it. An EXIT trap
# would close this properly, but lib/core.sh's own sitegraft_cleanup
# comment documents exactly why installing a SECOND `trap ... EXIT` from
# inside a function bats calls directly (phase_verify is exactly that) is
# unsafe here — it clobbers bats' own per-test trap and was a real,
# previously-fixed bug in this codebase. The mitigation below (requiring
# the cache to be NEWER than id-map.tsv, checked before trusting it) closes
# the practically relevant case — something in run_dir changed since the
# cache was written — without that risk; it does not close the narrower
# case where nothing changed and the stale cache happens to still be
# correct, which is also the case where reusing it does no harm.
#
# Three-valued, like verify_page_on_front/verify_domain_absent (see their
# own header comments for the same reasoning): 0 + a JSON array on stdout =
# genuinely parsed — including a legitimate, real "[]" when this run's
# migrate selection has no non-attachment post_type at all, which is
# nothing to check, not an error; 2 = INCOMPLETE, post_types ARE selected
# but no WXR export was found in run_dir (an interrupted run resumed past
# the export step — this function's own data source was never produced,
# the same "0 of N" shape issue #23 already established elsewhere in this
# file); 1 = HARD FAIL, the php driver itself could not run, could not
# parse one of the WXR files (lib/php/wxr-content-functions.php's `false`
# return — review finding m1: distinct from a file that parsed fine and
# genuinely has zero items), or did not return valid JSON — the tool's own
# machinery is broken right now, not merely "nothing was ready yet" (the
# identical fail-closed distinction verify_domain_absent's own comment
# draws for its `wp eval` failure path).
_verify_wxr_items_remapped() {
  local run_dir="$1" id_map_tsv="$2" manifest="$3"
  local cache_file="${run_dir}/.verify-content-items-cache.$$.json"
  # `-nt` (newer than): a cache file is only trusted if nothing in this
  # run_dir that its content depends on has been touched since it was
  # written -- see this function's own header comment for what this does
  # and does not close. `-nt` is true when id_map_tsv doesn't exist at all
  # (bash's own documented behavior for a missing right-hand file), which
  # is fine: no id-map.tsv to have changed means there is nothing this
  # check could catch anyway.
  if [ -f "$cache_file" ] && [ "$cache_file" -nt "$id_map_tsv" ]; then
    cat "$cache_file"
    return 0
  fi

  local post_types_csv
  post_types_csv=$(echo "$manifest" | jq -r '[.migrate[].post_types[]?] | unique | map(select(. != "attachment")) | join(",")')
  [ -n "$post_types_csv" ] || { echo '[]'; return 0; }

  # Portable glob-existence check (bash 3.2, no nullglob — same idiom
  # lib/graft.sh's own `for f in "${staging}"/*.xml` loops use): an
  # unmatched glob is left as the literal pattern string, so `[ -e "$f" ]`
  # is what tells "found nothing" apart from "found real file(s)".
  local wxr_files=() f
  for f in "${run_dir}"/export/*.xml; do
    [ -e "$f" ] && wxr_files+=("$f")
  done
  if [ "${#wxr_files[@]}" -eq 0 ]; then
    log_error "post_type(s) ${post_types_csv} are selected for migration but no WXR export was found under ${run_dir}/export — the export step never ran (an interrupted run resumed past it?), so migrated content cannot be verified against it"
    return 2
  fi

  # id-map.tsv's own attachment rows ARE the attachment id-remap map
  # graft_remap_attachment_ids builds from (lib/graft.sh) — reused
  # verbatim, never a second, independently-drifting reconstruction of
  # "which attachment IDs actually changed this run".
  local attachments_json domain_from domain_to
  attachments_json='[]'
  [ -f "$id_map_tsv" ] && attachments_json=$(awk -F'\t' '$3=="attachment"{printf "%s\t%s\n", $1, $2}' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {old: .[0], new: .[1]})')
  domain_from=$(echo "$manifest" | jq -r '.options.search_replace.from // ""')
  domain_to=$(echo "$manifest" | jq -r '.options.search_replace.to // ""')
  # Same "null" -> "" mapping lib/graft.sh's own phase_graft applies to
  # these same two manifest keys (a hand-written manifest — manifest_new
  # always populates them, but a hand-edited one might carry a literal
  # `null` — see phase_graft's own comment on this exact pair).
  [ "$domain_from" = "null" ] && domain_from=""
  [ "$domain_to" = "null" ] && domain_to=""

  local wxr_files_json
  wxr_files_json=$(printf '%s\n' "${wxr_files[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')

  local payload_json payload_file
  payload_json=$(jq -n --argjson files "$wxr_files_json" --argjson attachments "$attachments_json" \
    --arg from "$domain_from" --arg to "$domain_to" \
    '{wxr_files: $files, attachments: $attachments, domain: {from: $from, to: $to}}')
  # $$-suffixed (review finding m4): a fixed name here would let two
  # `verify` invocations against the SAME run_dir at once (an operator
  # re-running verify while a previous one is still going, or a script
  # firing both) overwrite each other's payload mid-read. Every temp file
  # this function creates uses the same suffix, for the same reason.
  payload_file="${run_dir}/.verify-content-payload.$$.json"
  printf '%s' "$payload_json" > "$payload_file"
  chmod 600 "$payload_file" 2>/dev/null || true

  # stderr captured SEPARATELY from stdout — stdout on success is the
  # NDJSON result and must never be contaminated by a diagnostic line the
  # driver also happened to print. `&&`/`||`, not a bare assignment (the
  # same set -e pitfall verify_domain_absent's own comment documents at
  # length).
  local stderr_file="${run_dir}/.verify-content-stderr.$$"
  local ndjson rc
  ndjson=$(php "${SITEGRAFT_ROOT}/lib/php/verify-content-remap-cli.php" "$payload_file" 2>"$stderr_file") && rc=0 || rc=$?
  local err_text=""
  [ -s "$stderr_file" ] && err_text=$(cat "$stderr_file")
  rm -f "$payload_file" "$stderr_file"

  if [ "$rc" -ne 0 ]; then
    log_error "could not parse/remap A's exported WXR for the content-equality guard(s): ${err_text}"
    return 1
  fi
  # M1, round 2: the driver now streams one compact JSON object per line
  # (NDJSON), never a single json_encode()'d array — see that file's own
  # comment for why. `jq -s` (slurp) reassembles the stream into the JSON
  # array this function has always returned; empty input slurps to `[]`,
  # matching a genuinely empty result. This reassembly cost lives here, in
  # a separate process (jq), not inside the php driver's own memory_limit.
  local result
  result=$(printf '%s' "$ndjson" | jq -s -c '.' 2>/dev/null)
  if [ -z "$result" ] || ! echo "$result" | jq -e . >/dev/null 2>&1; then
    log_error "the WXR content-remap driver did not return valid NDJSON: ${ndjson}"
    return 1
  fi
  printf '%s' "$result" > "$cache_file"
  chmod 600 "$cache_file" 2>/dev/null || true
  printf '%s' "$result"
}

# verify_migrated_content_matches_source <run_dir> <id_map_tsv> <manifest>
# — issue #52 / ADR 0008's "Required regardless" list, guard 1: for every
# post THIS run actually imported (every non-attachment, non-term row in
# id-map.tsv — review finding B3: id-map.tsv's `term:`-tagged rows are a
# TERM import, not a post, written by mu-plugins/sitegraft-id-mapper.php's
# wp_import_insert_term handler; excluded the same way modules/core-wp.sh's
# own B1 fix already excludes them from its own map, for the identical
# reason given there: post and term ids are independent sequences that
# both start at 1 on a fresh site, so an unfiltered term row can collide
# with, and silently stand in for, a real post's row), B's LIVE
# post_content/post_excerpt must equal A's after the same domain and ID
# remaps graft itself applies (_verify_wxr_items_remapped, above) — not
# A's raw bytes.
#
# Scope is deliberately id-map.tsv's own rows: an item wordpress-importer
# SKIPPED never reaches id-map.tsv at all (ADR 0008's Context section;
# issue #53), so it is never "migrated" by this function's own definition
# of the word — that is exactly what verify_migrated_content_changed_
# from_pregraft (below) exists to catch instead. The two guards are
# deliberately complementary, not redundant: this one proves an imported
# post got the RIGHT content; the other proves a post that was supposed to
# change actually did.
#
# Review finding B2, SECOND fix (round 2 — the first was wrong, and the
# history is worth keeping): a post whose content a module's post_import
# hook rewrote AFTER graft's own id/domain remap (etch's component-ref
# remap, core-wp's nav-link remap) cannot be claimed byte-equal without
# also modeling that hook's own rewrite, which this function deliberately
# does not do (see below). The FIRST fix excluded by POST_TYPE — "does a
# hook exist that COULD touch this type" — gated on whether
# modules/etch.sh existed on disk. Since that module ships in every real
# checkout and its hook has no post_type restriction at all, that
# predicate was TRUE unconditionally, on every real install, for every
# post_type — it excluded everything, always, and reported the run PASS
# regardless. That is worse than the false-hard-fail defect it replaced:
# it silently stopped implementing ADR 0008's first "Required regardless"
# item at all (a real remap failure, a #43-shaped backslash corruption, a
# write that landed wrong — none of that was caught by anything anymore),
# while ticking `- [x]`.
#
# The actual fix excludes by POST, not by post_type. graft_record_module_
# content_rewrite (lib/graft.sh) is called by each hook — modules/etch.sh's
# etch_post_import, modules/core-wp.sh's core_wp_post_import — once per
# post it ACTUALLY rewrote (never per post it merely could have), into
# ${run_dir}/module-content-rewrites.tsv. This function reads that file
# back and excludes exactly those ids, comparing every OTHER migrated post
# for real — the only form that still implements ADR 0008's first item:
# nothing is excluded on the strength of "a hook exists", only on the
# strength of "this specific post is where a hook actually wrote".
#
# Deliberately NOT a general model of "what did the hook change it TO" —
# that would mean reimplementing each module's own remap logic
# orchestrator-side (the etch component-ref regex, the core-wp nav-link
# walker), which would diverge from the real thing over time, the same
# argument this file already makes against a THIRD reimplementation of
# graft's own content remaps. Knowing WHICH posts a hook touched is cheap
# (the hook already counts them) and sufficient: excluded posts are
# reported UNVERIFIED (see this function's own report line in
# phase_verify), never ticked and never hard-failed on a comparison this
# function was never in a position to make safely.
#
# Floor, in case module-content-rewrites.tsv ever again ends up excluding
# everything in scope (a future module with an unconditional hook, a
# manifest selecting only post_types every shipped hook touches): if
# EVERY row in scope was excluded, this returns INCOMPLETE (2), never a
# tick — see the checkable_total==0 branch below. Honest, but not
# sufficient on its own, which is why the exclusion above is by post, not
# by type, in the first place.
#
# Review finding B1: the live fetch below is scoped with --post_type
# (this run's own non-attachment/non-term migrate post_types) and
# --post_status=any. Without --post_type, `wp post list --post__in=...`
# silently defaults to post_type=post (WP_Query::get_posts()'s own final
# `else` branch, wp-includes/class-wp-query.php) — every migrated PAGE
# would come back invisible to this exact query and read as "not found on
# B", a false HARD FAIL. Execution-proven against a flag-aware stub in
# tests/unit/test_verify.bats, which also proves the OLD, flag-blind call
# shape used to fail this exact way.
#
# Marker convention matches verify_options_match's own OPTIONS_COMPARED
# line, extended with a third number for review finding B2:
# `CONTENT_MATCH:<compared>:<checkable>:<excluded>` on stdout, always,
# whether this ultimately passes or hard-fails — <checkable> is every
# non-attachment/non-term id-map.tsv row NOT excluded under B2 above;
# <compared> is how many of those actually had a B row fetched AND a WXR
# item to compare against (a row missing either is logged and treated as
# a mismatch below, never silently dropped from <checkable>, and never
# silently counted as <compared> either); <excluded> is how many rows were
# skipped under B2, never silently folded into either of the other two
# counts. A distinct marker, `CONTENT_MATCH:none-imported:<items_total>`,
# and return code 2 (INCOMPLETE — review finding B5), covers the case
# id-map.tsv has ZERO matching rows even though A's WXR export was not
# itself empty of these post_types: "nothing was actually imported
# despite content existing to import" must never render as the same tick
# as "there was genuinely nothing to import" (`CONTENT_MATCH:0:0:0`,
# still a real PASS, reserved for when A's own WXR export was ALSO empty
# of these post_types). A third marker,
# `CONTENT_MATCH:no-rewrite-record:<total>`, and return code 2 (review
# round 3, MAJOR), covers module-content-rewrites.tsv being entirely
# ABSENT (not merely empty) — this run predates graft_run_module_post_
# import (lib/graft.sh) creating it unconditionally, or a kill mid-hook
# lost it — see this function's own B2 section below for why that must
# never be read the same as "present and genuinely empty".
verify_migrated_content_matches_source() {
  local run_dir="$1" id_map_tsv="$2" manifest="$3"

  local post_types_csv
  post_types_csv=$(echo "$manifest" | jq -r '[.migrate[].post_types[]?] | unique | map(select(. != "attachment")) | join(",")')
  [ -n "$post_types_csv" ] || { echo "CONTENT_MATCH:not-selected"; return 0; }

  local items_json rc
  items_json=$(_verify_wxr_items_remapped "$run_dir" "$id_map_tsv" "$manifest") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  local items_total
  items_total=$(echo "$items_json" | jq '[.[] | select(.post_type != "attachment")] | length')

  local rows_json='[]'
  [ -f "$id_map_tsv" ] && rows_json=$(awk -F'\t' '$3 != "attachment" && $3 !~ /^term:/{printf "%s\t%s\t%s\n", $1, $2, $3}' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {old_id: (.[0]|tonumber), new_id: (.[1]|tonumber), post_type: .[2]})')

  local total; total=$(echo "$rows_json" | jq 'length')
  if [ "$total" -eq 0 ]; then
    if [ "$items_total" -gt 0 ]; then
      # B5: A's WXR export was NOT empty, yet id-map.tsv has no matching
      # row at all for it — every one of A's items for this migrate
      # selection was skipped. This is not a pass; it is exactly the
      # shape of the observed defect and must read as unverified, never
      # as "0 of 0, nothing to do".
      log_error "A's WXR export selected ${items_total} item(s) of post_type(s) ${post_types_csv}, but id-map.tsv has NO matching row for any of them — nothing was actually imported this run, so content equality cannot be verified for anything"
      echo "CONTENT_MATCH:none-imported:${items_total}"
      return 2
    fi
    echo "CONTENT_MATCH:0:0:0"
    return 0
  fi

  # B2 (round 2's real fix): exclude by POST, never by post_type.
  #
  # Review round 3 (MAJOR): the file's mere ABSENCE is now checked
  # SEPARATELY from it being present-but-empty — graft_run_module_post_
  # import (lib/graft.sh) creates it unconditionally (dry-run excepted)
  # before any hook runs, so PRESENT (even empty) means "this run's hooks
  # were given the chance to record what they rewrote" and a real empty
  # file is a genuine, trustworthy "nothing was rewritten" signal. ABSENT
  # means this run predates that guarantee, or a kill mid-hook lost
  # whatever it would have recorded (see that function's own comment) —
  # this guard cannot tell the two apart, and must not guess "nothing
  # excluded" the way an earlier version of this fix-pack did (that
  # silently read a genuinely rewritten post's un-module-remapped bytes as
  # a false HARD FAIL). Same has()-style treatment as manifest.content_
  # checksums_pre_graft's own absence a few lines up in guard 2 below.
  local rewrites_file="${run_dir}/module-content-rewrites.tsv"
  if [ ! -f "$rewrites_file" ]; then
    # The honest advice here is NOT "re-run graft" (review round 4 nit):
    # if THIS run dir's graft already completed under an older sitegraft
    # version, graft.module_hooks.done is already on disk, so
    # `graft_step_done "$run_dir" module_hooks` (lib/graft.sh's phase_graft)
    # short-circuits and graft_run_module_post_import never runs again —
    # re-running `sitegraft graft` against this SAME run dir will never
    # produce this file, and this check would read INCOMPLETE forever. No
    # write to B ever results from that (every graft step is marker-
    # gated), so the cost is a wasted run and operator confusion, not
    # damage — but the advice has to be right: start a fresh run
    # (`sitegraft scan`/`plan`/`backup`/`graft` into a NEW run dir) instead
    # of resuming this one.
    log_error "this run has no module-content-rewrites.tsv at all — it predates graft_run_module_post_import (lib/graft.sh) creating that file unconditionally, or a kill mid-hook lost it, so this guard cannot tell whether a module's post_import hook rewrote any of the ${total} post(s) in scope. If this run dir's graft already completed under an older sitegraft version, re-running graft against it will NOT produce this file (the module_hooks step is already marked done and will be skipped) — start a fresh run (new scan/plan/backup/graft) instead."
    echo "CONTENT_MATCH:no-rewrite-record:${total}"
    return 2
  fi
  local rewritten_ids_json='[]'
  [ -s "$rewrites_file" ] && rewritten_ids_json=$(jq -R -s -c \
    'split("\n") | map(select(length > 0) | select(test("^[0-9]+$")) | tonumber) | unique' \
    "$rewrites_file")

  local checkable_json checkable_total excluded
  checkable_json=$(echo "$rows_json" | jq --argjson rw "$rewritten_ids_json" \
    '[.[] | select((.new_id as $id | $rw | index($id)) == null)]')
  checkable_total=$(echo "$checkable_json" | jq 'length')
  excluded=$((total - checkable_total))

  if [ "$checkable_total" -eq 0 ]; then
    # Floor (review finding B2, part b): every row in scope was excluded
    # -- nothing was actually verified. total>0 is guaranteed here (the
    # branch above already returned for total==0), so excluded==total>0
    # always holds when checkable_total is 0.
    log_error "every migrated post in scope (${excluded}) was rewritten by a module's post_import hook after graft's own remap — byte-equality could not be verified for any of them this run"
    echo "CONTENT_MATCH:0:0:${excluded}"
    return 2
  fi

  # B1: --post_type and --post_status=any — see this function's own header
  # comment for why their absence is a false HARD FAIL, not a harmless
  # omission.
  local new_ids_csv live_json live_rc
  new_ids_csv=$(echo "$checkable_json" | jq -r '[.[].new_id] | join(",")')
  live_json=$(wp_remote b post list --post__in="$new_ids_csv" --post_type="$post_types_csv" --post_status=any --fields=ID,post_content,post_excerpt --format=json 2>/dev/null) && live_rc=0 || live_rc=$?
  # B4: the same fail-OPEN pattern verify_domain_absent's own header
  # comment already documents fixing once elsewhere in this file — a read
  # that itself fails is UNKNOWN, never silently "nothing found".
  if [ "$live_rc" -ne 0 ]; then
    log_error "could not read B's current content for the migrated-content-equality guard (post list failed) — treated as UNKNOWN, never as a silent pass"
    return 1
  fi
  echo "$live_json" | jq -e . >/dev/null 2>&1 || {
    log_error "B's post list for the migrated-content-equality guard did not return valid JSON"
    return 1
  }

  local compared=0 mismatched=""
  local row old_id new_id expected_content expected_excerpt live_row actual_content actual_excerpt found
  # fd 3, not stdin — same convention/reason as every other id-map.tsv-
  # derived loop in this codebase (lib/graft.sh's own comment on this
  # exact pattern): nothing in this loop shells out to ssh today, but
  # matching the established convention up front costs nothing and keeps
  # a future edit from silently reintroducing that class of bug.
  while IFS= read -r row <&3; do
    [ -n "$row" ] || continue
    old_id=$(echo "$row" | jq -r '.old_id')
    new_id=$(echo "$row" | jq -r '.new_id')
    found=$(echo "$items_json" | jq --argjson id "$old_id" '[.[] | select(.post_id == $id)] | length')
    if [ "$found" -eq 0 ]; then
      mismatched="${mismatched}${new_id}(no-source-item) "
      continue
    fi
    expected_content=$(echo "$items_json" | jq -r --argjson id "$old_id" '[.[] | select(.post_id == $id)][0].post_content')
    expected_excerpt=$(echo "$items_json" | jq -r --argjson id "$old_id" '[.[] | select(.post_id == $id)][0].post_excerpt')
    live_row=$(echo "$live_json" | jq -c --argjson id "$new_id" '[.[] | select(.ID == $id)][0] // empty')
    if [ -z "$live_row" ]; then
      mismatched="${mismatched}${new_id}(not-found-on-b) "
      continue
    fi
    compared=$((compared + 1))
    actual_content=$(echo "$live_row" | jq -r '.post_content')
    actual_excerpt=$(echo "$live_row" | jq -r '.post_excerpt')
    if [ "$actual_content" != "$expected_content" ] || [ "$actual_excerpt" != "$expected_excerpt" ]; then
      mismatched="${mismatched}${new_id} "
    fi
  done 3<<< "$(echo "$checkable_json" | jq -c '.[]')"

  echo "CONTENT_MATCH:${compared}:${checkable_total}:${excluded}"
  if [ -n "$mismatched" ]; then
    log_error "migrated post content does not match A's (after the same remaps graft applies), post ID(s) on B: ${mismatched}"
    return 1
  fi
}

# verify_migrated_content_changed_from_pregraft <run_dir> <id_map_tsv>
# <manifest> — issue #52 / ADR 0008's "Required regardless" list, guard 2:
# the cheaper, non-normalizable guard that ALONE would have caught the
# observed defect (this file's own module header; ADR 0008's Context
# section). A WXR item wordpress-importer SKIPPED (never reaches
# id-map.tsv — see verify_migrated_content_matches_source's own comment
# and issue #53) leaves B's own pre-existing row untouched. If that row's
# content checksum on B TODAY is IDENTICAL to the checksum
# backup_compute_content_checksums recorded for it BEFORE the graft ran
# (lib/backup.sh, manifest.content_checksums_pre_graft), the row was never
# actually touched — confirmed-wrong, not merely unverified.
#
# Pairing is by POST ID, deliberately NOT a title+post_date+post_type
# replication of wordpress-importer's own post_exists() matching: A and B
# share IDs in the dominant real-world case ADR 0008 describes (both sites
# are clones of one origin database — "A's front page and B's front page
# were both ID 16"), which is exactly the case that produced the observed
# defect. This is a DELIBERATE, DOCUMENTED scope limit, not an oversight:
# for a from-scratch A whose IDs do not collide with B's at all, a skipped
# item's old_id simply will not be a key in content_checksums_pre_graft,
# and this guard reports nothing for it — neither a false pass nor a false
# fail. That case is issue #53's job (surfacing an "already exists" skip
# directly, at the source), not this guard's job to mis-detect via a
# coincidental, wrong pairing.
#
# Review finding B3: id-map.tsv's `term:`-tagged rows are excluded from
# the "already imported" set the same way guard 1 excludes them from its
# own scope (see that function's own comment for the full reasoning) —
# otherwise a term id colliding with a genuinely-skipped page's old id
# would silently MASK the skip: the term's own row would make the page's
# old_id look imported when nothing of the page ever was.
#
# A run whose manifest has no content_checksums_pre_graft key AT ALL (a
# run from before this feature existed) is INCOMPLETE (2), never a silent
# pass: a baseline that cannot be produced after the fact is not a baseline —
# see lib/backup.sh's backup_compute_content_checksums for where and why
# it is captured, and why it cannot be reconstructed later.
#
# Review finding B1: the live fetch below is scoped with --post_type and
# --post_status=any, for the identical reason guard 1's own header comment
# gives — without them, every skipped PAGE reads as "not found on B" and
# this guard silently PASSES on exactly the run it exists to catch (this
# is the run that motivated #52 in the first place: measured, with a
# flag-blind stub, as `CONTENT_UNCHANGED:1:1` / exit 0 on B holding only a
# page).
#
# Review finding B4: a `wp post list` call that itself FAILS (B not
# reachable, a real query error) is now a HARD FAIL, never a silent
# "nothing to compare" — the previous `|| echo '[]'` here was the
# identical fail-OPEN shape verify_domain_absent's own header comment
# already documents fixing once elsewhere in this file. A paired id
# absent from a response that DID succeed is a real finding too — the
# post existed pre-graft (it is a key in content_checksums_pre_graft) and
# is gone from B now — not something to skip past quietly.
#
# Review finding B5: `checked == 0 AND skipped > 0` means every skipped
# item was UNPAIRABLE (no pre-graft record for its id) — a real gap this
# guard cannot see past, not a pass: it examined nothing and must say so
# (return 2, INCOMPLETE), never tick "0 of N confirmed changed" under
# Result: PASS. `checked == 0 AND skipped == 0` stays a genuine pass —
# nothing was skipped at all, so there is truly nothing for this guard to
# say.
#
# Marker convention: `CONTENT_UNCHANGED:<checked>:<skipped>` on stdout —
# <skipped> is every WXR item (non-attachment, non-term) whose old_id is
# NOT in id-map.tsv at all (i.e. not genuinely imported this run);
# <checked> is how many of those ALSO had a pre-graft checksum recorded
# for that same id (the only ones this guard can actually say anything
# about).
verify_migrated_content_changed_from_pregraft() {
  local run_dir="$1" id_map_tsv="$2" manifest="$3"

  local post_types_csv
  post_types_csv=$(echo "$manifest" | jq -r '[.migrate[].post_types[]?] | unique | map(select(. != "attachment")) | join(",")')
  [ -n "$post_types_csv" ] || { echo "CONTENT_UNCHANGED:not-selected"; return 0; }

  local items_json rc
  items_json=$(_verify_wxr_items_remapped "$run_dir" "$id_map_tsv" "$manifest") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local imported_ids_json='[]'
  [ -f "$id_map_tsv" ] && imported_ids_json=$(awk -F'\t' '$3 != "attachment" && $3 !~ /^term:/{print $1}' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber)')

  # Review finding m5, acknowledged rather than further defended against:
  # the INCOMPLETE gate a few lines below is conditioned on skipped_total,
  # which is only as correct as this subtraction — an under-computed
  # imported_ids_json (B3's own bug, now fixed) or a parsing gap in
  # items_json would silently produce a LOWER skipped_total than reality,
  # for the wrong reason, and this gate cannot see past its own inputs
  # being wrong. B3 closes the one concrete way that was happening; no
  # further speculative hardening is added here against a hypothetical
  # FUTURE miscount, the same way no check anywhere else in this file
  # defends against its own upstream data being silently wrong in a way
  # its own reads cannot detect.
  local skipped_json
  skipped_json=$(jq -n --argjson items "$items_json" --argjson imported "$imported_ids_json" \
    '([$items[] | select(.post_type != "attachment") | .post_id] | unique) - $imported')
  local skipped_total; skipped_total=$(echo "$skipped_json" | jq 'length')

  # The pre-graft snapshot is only REQUIRED once there is something to pair
  # it against — a run with nothing skipped genuinely has nothing for this
  # guard to say, snapshot or no snapshot, and must not be marked
  # INCOMPLETE over a gap that would never have been consulted. A run with
  # at least one skipped item AND no content_checksums_pre_graft key at
  # all (this run's manifest predates the snapshot, lib/backup.sh's
  # backup_compute_content_checksums) genuinely cannot say whether those
  # items are unchanged — a baseline that cannot be produced after the fact
  # is not a baseline.
  if [ "$skipped_total" -gt 0 ] && ! echo "$manifest" | jq -e 'has("content_checksums_pre_graft")' >/dev/null 2>&1; then
    log_error "${skipped_total} WXR item(s) selected for migration were not imported this run, and this run's manifest has no content_checksums_pre_graft to check them against — it predates the pre-graft content-checksum snapshot. Re-run backup and graft against a sitegraft version that records it."
    return 2
  fi

  local pre_graft; pre_graft=$(echo "$manifest" | jq -c '.content_checksums_pre_graft // {}')

  local paired_json
  paired_json=$(jq -n --argjson skipped "$skipped_json" --argjson pre "$pre_graft" \
    '[$skipped[] | select($pre[(.|tostring)] != null)]')
  local checked; checked=$(echo "$paired_json" | jq 'length')

  echo "CONTENT_UNCHANGED:${checked}:${skipped_total}"
  if [ "$checked" -eq 0 ]; then
    if [ "$skipped_total" -gt 0 ]; then
      # B5: skipped items exist but none of them could be paired against
      # a pre-graft record — this guard could not examine any of them.
      log_error "${skipped_total} item(s) were skipped this run, but none of their ids had a pre-graft content checksum recorded (see this function's own header comment on ID-based pairing's documented scope limit) — this guard examined nothing and cannot confirm they are unchanged"
      return 2
    fi
    return 0
  fi

  # B1: --post_type and --post_status=any — see this function's own header
  # comment.
  local ids_csv live_json live_rc
  ids_csv=$(echo "$paired_json" | jq -r 'join(",")')
  live_json=$(wp_remote b post list --post__in="$ids_csv" --post_type="$post_types_csv" --post_status=any --fields=ID,post_content,post_excerpt --format=json 2>/dev/null) && live_rc=0 || live_rc=$?
  # B4: fail closed on the read itself, `&&`/`||` capturing the REAL exit
  # status rather than folding a failed call into an empty-but-successful
  # result.
  if [ "$live_rc" -ne 0 ]; then
    log_error "could not read B's current content for the pre-graft-comparison guard (post list failed) — treated as UNKNOWN, never as a silent pass"
    return 1
  fi
  echo "$live_json" | jq -e . >/dev/null 2>&1 || {
    log_error "B's post list for the pre-graft-comparison guard did not return valid JSON"
    return 1
  }

  # Two SEPARATE findings, review finding B4 (minor): "still byte-identical
  # to its pre-graft state" and "gone from B entirely" are different facts
  # about different failure modes, and reporting a vanished post under the
  # byte-identical message was itself the wrong diagnosis of what happened
  # to it.
  local unchanged="" vanished=""
  local id live_row current_sum pre_sum
  while IFS= read -r id <&3; do
    [ -n "$id" ] || continue
    live_row=$(echo "$live_json" | jq -c --argjson id "$id" '[.[] | select(.ID == $id)][0] // empty')
    if [ -z "$live_row" ]; then
      # B4: a paired id absent from a SUCCESSFUL response is a finding —
      # the post existed pre-graft and is gone from B now — not a
      # silent `continue`.
      vanished="${vanished}${id} "
      continue
    fi
    current_sum="sha256:$(backup_content_checksum_of_row "$live_row")"
    pre_sum=$(echo "$pre_graft" | jq -r --arg id "$id" '.[$id]')
    [ "$current_sum" = "$pre_sum" ] && unchanged="${unchanged}${id} "
  done 3<<< "$(echo "$paired_json" | jq -c '.[]')"

  if [ -n "$unchanged" ]; then
    log_error "post(s) B already had, matching an item this run intended to migrate, are still byte-identical to their pre-graft state — the migration for these silently did not happen (an \"already exists\" import skip, or a write that never landed), post ID(s) on B: ${unchanged}"
  fi
  if [ -n "$vanished" ]; then
    log_error "post(s) B already had, matching an item this run intended to migrate, are no longer on B at all (present pre-graft, per content_checksums_pre_graft; absent from a SUCCESSFUL post list read now) — post ID(s) on B: ${vanished}"
  fi
  if [ -n "$unchanged" ] || [ -n "$vanished" ]; then
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
#
# Issue #32: when no marker is available (the caller's own front-page title
# lookup came back empty), the OLD version of this function silently skipped
# the body comparison and returned bare success — indistinguishable, to the
# caller, from "the marker was checked and matched". phase_verify's report
# line claimed BOTH "returns 200" AND "with expected content" regardless,
# having established only the first. Every success path below now echoes a
# marker on stdout, same convention as verify_page_on_front/verify_domain_
# absent/verify_nav_present in this file, so the caller can say exactly what
# was established: `HTTP_SMOKE:matched` (body genuinely checked and
# contains it) vs `HTTP_SMOKE:not-compared` (200 confirmed, body never
# looked at) vs `HTTP_SMOKE:no-curl` (issue #32 fix-pack NIT 1 -- curl
# itself is unavailable, so not even the status code was checked). curl is
# never `require_cmd`'d anywhere in this codebase, so that last path is live
# today, not provisioning for later. Deliberately still a PASS either way,
# not INCOMPLETE — decided consciously, not by omission: this check is
# documented above as best-effort by design (no SITE_B_URL is even
# required), and "not compared"/"no curl" are known facts about what ran,
# not an uncertainty about whether B is correct. What changes is only the
# WORDING, never whether the run counts as complete. A success path added
# later WITHOUT one of these markers is a different matter — see phase_
# verify's own default branch for it, same fail-closed convention every
# other marker-reading case in this file uses.
verify_http_smoke() {
  local url="$1" marker="${2:-}"
  [ -n "$url" ] || return 0
  command -v curl >/dev/null 2>&1 || { log_warn "curl not found — skipping the HTTP smoke check (best-effort only)"; echo "HTTP_SMOKE:no-curl"; return 0; }

  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
  if [ "$code" != "200" ]; then
    log_error "HTTP smoke check: ${url} returned ${code}, expected 200"
    return 1
  fi
  if [ -z "$marker" ]; then
    echo "HTTP_SMOKE:not-compared"
    return 0
  fi

  local body
  body=$(curl -sS --max-time 10 "$url" 2>/dev/null || echo "")
  case "$body" in
    *"$marker"*) echo "HTTP_SMOKE:matched" ;;
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
#
# Result / exit code is THREE-valued, not a plain pass/fail boolean (Nat's
# review of PR #26, blocking finding): a run can produce checks that come
# back verified-correct, verified-WRONG, or genuinely unable-to-be-verified
# at all (e.g. verify_options_match's own documented "a key graft never
# reached is not this function's job to have an opinion about" — real and
# correct for the FUNCTION, but "N of M selected keys had nothing to
# compare" cannot be reported as a plain pass to the OPERATOR, or CLAUDE.md's
# first rule — "a check must distinguish verified true from could not
# verify... report unknown, never OK" — is violated at exactly the layer
# that's supposed to enforce it).
#   - **PASS** (exit 0): every check either verified correct, or was
#     genuinely not applicable (a KNOWN fact — e.g. no domain configured for
#     this migration, nothing was selected for option migration at all —
#     never an unknown).
#   - **HARD FAIL** (exit 1): at least one check found a confirmed defect,
#     OR a check's own execution machinery failed (a query/eval that could
#     not run at all — see the orphan-check and domain-check comments below
#     for why THOSE stay hard fails rather than becoming INCOMPLETE).
#   - **INCOMPLETE** (exit 2): no hard failure, but at least one check had
#     nothing to compare against because an earlier step's data was never
#     produced (an interrupted graft resumed past it) — the check's own
#     machinery is fine, there is simply nothing on disk yet to check. This
#     graft is NOT confirmed good; it is also not confirmed bad. A caller
#     testing `$?` gets a third value precisely so it cannot mistake this
#     for either.
# HARD FAIL outranks INCOMPLETE when a run has both: a confirmed defect is
# the stronger, more actionable signal, and the exit code must reflect the
# worse of the two.
#
# Viktor's re-review of PR #26 widened INCOMPLETE from two checks to four,
# all four the same shape — a check whose own machinery is fine but which
# had nothing to work with:
#   - migrated options: N selected, 0 on disk to compare (issue #23).
#   - page_on_front: selected, but its recorded value was never written.
#   - domain absence: 0 migrated posts AND 0 migrated option keys in scope,
#     so the check would otherwise have "confirmed" absence having read
#     nothing (B1 — the same fail-open, one function further along).
#   - domain absence, second shape: the manifest has no
#     `options.search_replace.from` key at all, so this run cannot even say
#     whether a domain was configured (N4). Distinct from the key being
#     present and EMPTY, which is a real fact and stays a PASS.
# The rule those four share, and the one to keep applying to any check added
# later: a check that did not look at anything reports `- [ ] UNVERIFIED`
# and says why; a check that ticks `- [x]` either names what it examined (a
# count, an ID) or names the KNOWN fact that made it not applicable. "It
# passed" and "there was nothing to look at" must never render the same.
#
# Three checks below (domain absence, page_on_front, navigation) report
# their outcome to this function through a marker printed on stdout, and
# each of the three `case` blocks that reads one has a fail-closed DEFAULT
# branch: a success with no recognizable marker is reported UNVERIFIED, not
# assigned whichever claim happened to be listed first.
#
# All three default branches are UNREACHABLE as this file stands — every
# success path ends in its own `echo <marker>`. They are kept, and tested
# anyway, on purpose. Their entire reason to exist is the success path
# somebody adds later and forgets to mark, and an untested guard is the
# guard the next refactor deletes with nothing to say otherwise. That is not
# hypothetical here: the domain one was MISSING until a re-review found it,
# and a success without its marker printed `- [x] ... (0 migrated post(s) +
# 0 migrated option(s) scanned)` under `Result: PASS` with exit 0 — the same
# fail-open this file exists to close, on the very line it had just been
# closed on. The nav one existed but had no test, and could be replaced with
# a silent tick without a single test noticing.
#
# Deliberately NOT claimed here: that `- [ ]` now means UNVERIFIED and
# nothing else. Three other lines below still use an unticked box for a
# non-blocking FINDING (orphan parents found, the best-effort HTTP smoke
# check failing) or for the re-licensing REMINDER, all of which coexist
# with `Result: PASS` on purpose. Those are reported observations, not
# unverified checks; unifying that notation is a separate change and is not
# what this one did.
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
  # Viktor's re-review of PR #26, N3: existing != parsable. Every check below
  # reads its scope out of this file with `jq`, and a malformed manifest makes
  # each of those reads fail quietly and return nothing — which the checks
  # then read as "nothing was selected", i.e. four confident `[x]` ticks plus
  # a HARD FAIL blamed on "protected data changed". That diagnosis points the
  # operator at the wrong problem entirely. Validate once, up front, and
  # refuse the whole phase rather than producing a report that is wrong in
  # both directions at once.
  jq -e . "${run_dir}/manifest.json" >/dev/null 2>&1 || {
    log_error "the manifest at ${run_dir}/manifest.json is not valid JSON — every check in this phase reads its scope from it, so nothing here can be verified against it"
    return 1
  }
  local manifest; manifest=$(cat "${run_dir}/manifest.json")
  local id_map_tsv="${run_dir}/id-map.tsv"
  local report="${run_dir}/verify-report.md"
  local hard_fail=0
  local incomplete=0 incomplete_names=""

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
  #
  # Issue #33: the old `|| recomputed='{}'` fallback turned a genuine
  # recompute failure (wp-cli unreachable, `inventory_table_prefix` erroring,
  # any read `backup_compute_protected_checksums` needs to do its job) into
  # an EMPTY map, then let the comparison below proceed against it. With a
  # non-empty `checksums_protected_pre_graft` that still hard-fails (empty
  # can't match populated) — but the exposure is the run where the pre-graft
  # map is ITSELF `{}` (nothing was declared protected): empty compared
  # against empty matches, and the report printed "protected data unchanged"
  # / PASS on a run where nothing was computed and nothing could have been.
  # Reproduced directly (stub the recompute to fail against the shared
  # fixture's empty pre-graft map — see the test alongside this comment).
  #
  # The same argument #26 already applied to the orphan-parent query — a
  # broken read casts doubt on every other read in the run, so the query
  # failing is a hard failure, not a silent "found nothing" — applies here
  # and had not been applied: a recompute failure is now reported as a
  # failure, never substituted with a value that happens to look like a
  # clean result.
  local recomputed recompute_rc=0
  recomputed=$(backup_compute_protected_checksums b "$manifest" 2>>"$report") || recompute_rc=$?
  if [ "$recompute_rc" -ne 0 ]; then
    echo "- [ ] **HARD FAIL: could not recompute protected data checksums** — the recompute itself failed (wp-cli unreachable, or a read \`backup_compute_protected_checksums\` needs failed); see above. A broken read here casts doubt on every table this run was supposed to be protecting, so it is reported as a failure, never silently treated as \"nothing changed\"." >> "$report"
    hard_fail=1
  else
    # Issue #33 fix-pack (round 2, review finding): what phase_verify reads
    # here is the PRE-GRAFT SNAPSHOT (checksums_protected_pre_graft) --
    # captured by `backup`, a DIFFERENT phase than the recompute above,
    # which reads B's LIVE current state regardless of whether backup ever
    # ran. Those are two different facts, and the first round of this fix
    # collapsed them: `.checksums_protected_pre_graft // {}` treated an
    # ABSENT key the same as a PRESENT-and-empty one, both read as "0
    # declared, not applicable, PASS". They are not the same. A `backup
    # --dry-run` manifest never computes a real snapshot at all and leaves
    # the key OUT entirely (asserted by an existing test) -- reachable for
    # real via `backup --dry-run` followed by a genuine `graft` and
    # `verify`, not hypothetical. Whatever `.protect` itself declares, an
    # absent snapshot means protected data was never captured pre-graft, so
    # nothing here can be verified either way -- printing a PASS in that
    # state is the exact defect this issue exists to close, reintroduced by
    # the first round of its own fix.
    #
    # Presence is therefore tested FIRST, before ever reading a value out of
    # it -- same discipline the domain check's own `has("from")` guard
    # already uses in this function (Viktor's re-review of PR #26, N4/N5),
    # for the identical reason: a missing key is a different fact from a
    # present-and-empty one, and only one of them justifies a pass.
    if ! echo "$manifest" | jq -e 'has("checksums_protected_pre_graft")' >/dev/null 2>&1; then
      echo "- [ ] protected data unchanged: **UNVERIFIED — no pre-graft protected-data snapshot exists in this manifest** (backup never captured one -- a \`backup --dry-run\` manifest, or a run that reached verify without going through backup at all -- so protected data cannot be verified for this run, regardless of what this manifest's \`protect\` section declares)" >> "$report"
      incomplete=$((incomplete + 1))
      incomplete_names="${incomplete_names}protected-data-checksums "
    else
      # A real backup run writes a key for every protect module that has
      # actual TABLES (see backup_compute_protected_checksums's own header
      # comment) -- a module can be DECLARED (the shared fixture's own
      # `_unclaimed`) while carrying zero tables, which is why the count
      # below is worded as "0 table(s)", never "0 protected set(s) were
      # declared" (review finding: the fixture's `_unclaimed` module IS
      # declared, it simply has nothing to snapshot). That distinction is a
      # KNOWN fact read straight from the manifest, not a verified
      # comparison -- reported as such, distinctly from a real match, so the
      # report never claims to have compared data it never had.
      local pre_graft_count
      pre_graft_count=$(echo "$manifest" | jq '.checksums_protected_pre_graft | length')
      if [ "$pre_graft_count" -eq 0 ]; then
        echo "- [x] protected data unchanged (not applicable — this run's manifest declared 0 protected table(s) to snapshot, so there was nothing to compare)" >> "$report"
      else
        local checksum_diff
        if checksum_diff=$(verify_compare_checksums "$manifest" "$recomputed" 2>>"$report"); then
          # issue #97: verify_compare_checksums' own UNREADABLE_COUNT: line
          # (see its header comment) — an `_unclaimed` table that could not
          # be read on at least one side of this run. A declared module's
          # own read failure never reaches here at all (it already hard-
          # fails the recompute above, #33's path) — so this can only ever
          # be an out-of-scope table, and is reported through the SAME
          # three-valued INCOMPLETE bucket every other "could not verify"
          # finding in this phase already uses, never folded into the plain
          # "[x] ... compared" tick, which is exactly the false-green shape
          # this issue exists to close.
          local unread_count="${checksum_diff##*UNREADABLE_COUNT:}"
          case "$unread_count" in ''|*[!0-9]*) unread_count=0 ;; esac
          if [ "$unread_count" -gt 0 ]; then
            echo "- [ ] protected data unchanged: **UNVERIFIED for ${unread_count} of ${pre_graft_count} protected set(s)** — could not be read on at least one side of this run (see warning(s) above); the rest matched" >> "$report"
            incomplete=$((incomplete + 1))
            incomplete_names="${incomplete_names}protected-data-checksums(unreadable) "
          else
            echo "- [x] protected data unchanged (${pre_graft_count} protected set(s) compared)" >> "$report"
          fi
        else
          echo "- [ ] **HARD FAIL: protected data changed** — ${checksum_diff}" >> "$report"
          hard_fail=1
        fi
      fi
    fi
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
    # on) — but Nat's review of PR #26 is exactly right that the REPORT
    # cannot just print prose saying "not a pass" while the summary footer
    # still says PASS. This is INCOMPLETE, not a hard fail and not a pass:
    # counted separately so the final Result reflects it and the exit code
    # is non-zero (see phase_verify's own header comment for the 3-state
    # model).
    echo "- [ ] migrated options match A's values on B: **UNVERIFIED — 0 of ${options_total} selected option(s) could be compared** (not written to disk this run — see lib/verify.sh's verify_options_match)" >> "$report"
    incomplete=$((incomplete + 1))
    incomplete_names="${incomplete_names}migrated-options "
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
  #
  # Nat's review of PR #26, decided consciously rather than by omission: "no
  # domain configured" stays a PASS (`[x]`), not INCOMPLETE, under the new
  # 3-state model (see phase_verify's header comment) — deliberately, not
  # because it's outside this file's scope. INCOMPLETE means "we don't know
  # whether this is true"; "not applicable" here is a KNOWN FACT read
  # straight from the manifest (`options.search_replace.from` is empty —
  # this migration was never configured to rewrite a domain at all), not an
  # uncertainty. That is exactly the distinction issue #22's own acceptance
  # criteria draw ("verified, or explicitly not applicable, or not
  # verifiable" — three different things, not two).
  #
  # Viktor's re-review of PR #26, N4/N5: `jq -r '...from // ""'` maps THREE
  # distinct manifest states onto one empty string — the key is present and
  # empty (a real "no domain configured" fact), the key is absent, and
  # `.options` itself is absent. Only the first justifies the not-applicable
  # PASS line; the other two are a manifest that never said anything on the
  # subject, and printing a known fact on the strength of a missing key is
  # the same shape of claim this PR is closing everywhere else. The key's
  # presence is therefore tested SEPARATELY, before its value is read. (A
  # hand-written manifest is exactly where this happens: manifest_new always
  # populates the key, and lib/graft.sh documents the identical case at its
  # own read of it.) N5: the old `[ "$domain" = "null" ] && domain=""` line
  # that followed was dead code — jq's `// ""` already maps a JSON null onto
  # "" — and is gone; the explicit has("from") test below is what actually
  # separates the cases it was reaching for.
  # ---------------------------------------------------------------------------
  local domain="" domain_key_present=0
  if echo "$manifest" | jq -e '.options.search_replace | has("from")' >/dev/null 2>&1; then
    domain_key_present=1
    domain=$(echo "$manifest" | jq -r '.options.search_replace.from // ""')
  fi
  if [ "$domain_key_present" -eq 0 ]; then
    echo "- [ ] A's domain string is absent from the content graft imported: **UNVERIFIED** (not verifiable — the manifest has no options.search_replace.from, so this run cannot tell whether a domain was configured at all)" >> "$report"
    incomplete=$((incomplete + 1))
    incomplete_names="${incomplete_names}domain-absence "
  elif [ -z "$domain" ]; then
    echo "- [x] A's domain string is absent from the content graft imported (not applicable — no domain was configured for this migration)" >> "$report"
  else
    # verify_domain_absent's exit code is three-valued (0/1/2 — see its own
    # header comment), so this MUST capture the real code with `|| rc=$?`
    # rather than fold every non-zero into a hard fail the way an `elif
    # verify_domain_absent ...; then` chain would: that is the identical
    # pitfall the page_on_front wiring below already documents, and folding
    # 2 into 1 here would report "the domain is still present on B" for a
    # run where nothing was ever examined.
    local domain_output="" domain_rc=0
    domain_output=$(verify_domain_absent "$run_dir" "$id_map_tsv" "$manifest" "$domain" 2>>"$report") || domain_rc=$?
    # The scope marker is not optional decoration: a success WITHOUT it left
    # the counters at their initialized 0 and printed
    #   `- [x] ... (0 migrated post(s) + 0 migrated option(s) scanned)`
    # under `Result: PASS`, exit 0 — finding B1 walking back in through a
    # different door, on the exact line B1 was filed against. So a missing
    # marker is UNVERIFIED, never a tick, exactly like the page_on_front and
    # navigation cases below. `domain_marker_seen` (rather than testing the
    # counters for 0) keeps "the check said zero" separable from "the check
    # said nothing"; a genuine zero scope is already handled inside
    # verify_domain_absent, which returns 2 for it.
    local domain_posts=0 domain_options=0 domain_marker_seen=0
    case "$domain_output" in
      *DOMAIN_SCOPE:*)
        local domain_scope="${domain_output##*DOMAIN_SCOPE:}"
        domain_posts="${domain_scope%%:*}"
        domain_options="${domain_scope##*:}"
        domain_marker_seen=1
        ;;
    esac
    if [ "$domain_rc" -eq 0 ] && [ "$domain_marker_seen" -eq 0 ]; then
      echo "- [ ] A's domain string absent from the content graft imported: **UNVERIFIED — the check reported success without reporting the scope it examined** (a success path added without its marker — see lib/verify.sh's verify_domain_absent)" >> "$report"
      incomplete=$((incomplete + 1))
      incomplete_names="${incomplete_names}domain-absence "
    elif [ "$domain_rc" -eq 0 ]; then
      # The counts are the point, not decoration: "(migrated posts + migrated
      # options)" was a claim about what had been examined that the check
      # could make while having examined nothing at all.
      echo "- [x] A's domain string is absent from the content graft imported (${domain_posts} migrated post(s) + ${domain_options} migrated option(s) scanned)" >> "$report"
    elif [ "$domain_rc" -eq 2 ]; then
      echo "- [ ] A's domain string absent from the content graft imported: **UNVERIFIED — 0 migrated post(s) and 0 migrated option(s) were in scope, so nothing was examined** (see above; not a hard fail on its own, but not a pass)" >> "$report"
      incomplete=$((incomplete + 1))
      incomplete_names="${incomplete_names}domain-absence "
    else
      echo "- [ ] **HARD FAIL: A's domain string is still present in content graft imported, or the check could not be verified** — see above" >> "$report"
      hard_fail=1
    fi
  fi

  # --- page_on_front resolves to the CORRECT remapped page (finding B3;
  # issue #12 — the manifest is what lets verify_page_on_front tell "wasn't
  # part of this run" apart from "was selected but the remap didn't happen",
  # see that function's own header comment). verify_page_on_front's exit
  # code is three-valued (0/1/2 — see its own header comment), so this MUST
  # capture the actual code with `|| front_rc=$?`, not collapse every
  # non-zero into 1 the way the rest of this file's `|| x=1` idiom does —
  # doing that here would silently turn its INCOMPLETE (2) into a HARD FAIL.
  # ----------------------------------------------------------------------
  #
  # Viktor's re-review of PR #26, N1: exit code 0 covers THREE different
  # outcomes and this printed one byte-identical line for all of them —
  # "resolves to the correctly remapped page (or A never configured one)".
  # That "or" is the ambiguous disjunction issue #12 is about, preserved in
  # the report after being removed from the code, and inconsistent with the
  # domain line above that this same PR just made explicit. The function now
  # says WHICH outcome applied (see its header comment); each gets its own
  # line, and an unmarked success is reported as unverified rather than
  # assigned one of the three claims by default.
  local front_output="" front_rc=0
  front_output=$(verify_page_on_front "$run_dir" "$id_map_tsv" "$manifest" 2>>"$report") || front_rc=$?
  if [ "$front_rc" -eq 0 ]; then
    case "$front_output" in
      *PAGE_ON_FRONT:not-selected*)
        echo "- [x] page_on_front (not applicable — page_on_front was not part of this run's migrate selection)" >> "$report"
        ;;
      *PAGE_ON_FRONT:a-had-none*)
        echo "- [x] page_on_front (not applicable — A's own recorded value says A never configured a front page)" >> "$report"
        ;;
      *PAGE_ON_FRONT:verified:*)
        echo "- [x] page_on_front resolves to the correctly remapped page on B (post ${front_output##*PAGE_ON_FRONT:verified:})" >> "$report"
        ;;
      *)
        echo "- [ ] page_on_front: **UNVERIFIED — the check reported success without saying which of its outcomes applied** (a success path added without its marker — see lib/verify.sh's verify_page_on_front)" >> "$report"
        incomplete=$((incomplete + 1))
        incomplete_names="${incomplete_names}page_on_front "
        ;;
    esac
  elif [ "$front_rc" -eq 2 ]; then
    case "$front_output" in
      # Issue #69: a non-numeric id-map.tsv entry is a DIFFERENT reason to be
      # unable to verify than "the value file was never written" — the value
      # WAS written this run, it is id-map.tsv's row that cannot be trusted.
      # Reported distinctly, same discipline as every other marker in this
      # function: never reuse one INCOMPLETE line's wording for a cause it
      # does not actually describe.
      *PAGE_ON_FRONT:non-numeric-map-entry*)
        echo "- [ ] page_on_front: **UNVERIFIED — id-map.tsv's entry for A's front page is not a numeric id, so it cannot be trusted as B's expected page_on_front** (see above; not a hard fail on its own, but not a pass)" >> "$report"
        ;;
      *)
        echo "- [ ] page_on_front: **UNVERIFIED — selected for migration but its recorded value was never written this run** (see above; not a hard fail on its own, but not a pass)" >> "$report"
        ;;
    esac
    incomplete=$((incomplete + 1))
    incomplete_names="${incomplete_names}page_on_front "
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
  # (non-blocking) warning.
  #
  # Nat's review of PR #26 asked, given the new INCOMPLETE state (see
  # phase_verify's header comment), whether this belongs there instead of
  # HARD FAIL — it does not, and the distinction is real: INCOMPLETE is for
  # a check whose OWN machinery is fine but had nothing to compare because
  # an earlier step's data was never produced (migrated-options/
  # page_on_front above — the read succeeds, the file just isn't there yet,
  # a known and well-understood shape of an interrupted, resumed run). A
  # QUERY ERROR here means graft_check_orphan_parents' own read against B
  # failed to execute — wp-cli or the DB connection itself is broken RIGHT
  # NOW. That is not "some earlier step's data is missing", it is "the tool
  # this entire phase depends on may not be trustworthy for any of the
  # OTHER checks either" — a strictly worse, more urgent signal that HARD
  # FAIL communicates correctly and INCOMPLETE would understate. Same
  # reasoning applies to verify_domain_absent's own fail-closed "could not
  # run" branch below (a `wp eval` that errors), left unchanged for the
  # identical reason. ---------------------------------------------------
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

  # --- expected navigation present. Two success outcomes, two distinct
  # lines, same reasoning as page_on_front above (N1). ------------------------
  local nav_output="" nav_rc=0
  nav_output=$(verify_nav_present "$manifest" 2>>"$report") || nav_rc=$?
  if [ "$nav_rc" -ne 0 ]; then
    echo "- [ ] **HARD FAIL: wp_navigation was migrated but B has no navigation post** — see above" >> "$report"
    hard_fail=1
  else
    case "$nav_output" in
      *NAV:not-selected*)
        echo "- [x] expected navigation (not applicable — wp_navigation was not part of this run's migrate selection)" >> "$report"
        ;;
      *NAV:verified:*)
        echo "- [x] expected navigation is present on B (${nav_output##*NAV:verified:} wp_navigation post(s) found)" >> "$report"
        ;;
      *)
        echo "- [ ] expected navigation: **UNVERIFIED — the check reported success without saying which of its outcomes applied** (a success path added without its marker — see lib/verify.sh's verify_nav_present)" >> "$report"
        incomplete=$((incomplete + 1))
        incomplete_names="${incomplete_names}navigation "
        ;;
    esac
  fi

  # --- every known id-bearing block attribute in migrated content resolves
  # to an existing post on B (issue #84). Two-valued rather than three (no
  # INCOMPLETE state — unlike page_on_front/navigation above, there is no
  # "selected but not yet written" precondition this check depends on: it
  # reads B's LIVE content directly, and id-map.tsv either has migrated
  # rows to scan or it does not, which verify_id_references_resolve's own
  # `ID_REFS:0:0` pass already covers as "nothing to check", not as an
  # unknown). See that function's own header comment for why this closes
  # a blind spot verify_migrated_content_matches_source's own byte-equality
  # guard cannot: an id that should have been remapped and was not is
  # invisible to a comparison against "what A's content becomes after the
  # SAME remap" — this check instead asks whether the reference resolves
  # on B at all, independent of whether any remap ran. ---------------------
  local id_refs_output="" id_refs_rc=0
  id_refs_output=$(verify_id_references_resolve "$run_dir" "$id_map_tsv" 2>>"$report") || id_refs_rc=$?
  if [ "$id_refs_rc" -ne 0 ]; then
    # fix-pack nit: the counts belong on the HARD FAIL line too, not only
    # on the pass line -- an operator staring at a red report should not
    # have to go dig the raw log_error line out of stderr to see HOW MANY
    # references were checked and HOW MANY of them were missing. Only the
    # "a reference was found missing" failure path carries an ID_REFS
    # marker at all (verify_id_references_resolve's own header comment:
    # the live-fetch/existence-check failure paths return before printing
    # one) -- the generic line below covers those, honestly, rather than
    # printing counts it does not have.
    case "$id_refs_output" in
      *ID_REFS:*)
        local idrf_summary="${id_refs_output##*ID_REFS:}"
        local idrf_checked idrf_missing
        idrf_checked=$(echo "$idrf_summary" | cut -d: -f1)
        idrf_missing=$(echo "$idrf_summary" | cut -d: -f2)
        echo "- [ ] **HARD FAIL: migrated content references id(s) that do not resolve to any post on B** (${idrf_checked} checked, ${idrf_missing} missing) — see above" >> "$report"
        ;;
      *)
        echo "- [ ] **HARD FAIL: could not verify migrated content's id references against B (query failed)** — see above" >> "$report"
        ;;
    esac
    hard_fail=1
  else
    case "$id_refs_output" in
      *ID_REFS:*)
        local idr_summary="${id_refs_output##*ID_REFS:}"
        local idr_checked idr_missing
        idr_checked=$(echo "$idr_summary" | cut -d: -f1)
        idr_missing=$(echo "$idr_summary" | cut -d: -f2)
        if [ "$idr_checked" -eq 0 ]; then
          echo "- [x] id references (mediaId/ref/parentPageID) in migrated content resolve on B (0 found to check)" >> "$report"
        else
          echo "- [x] id references (mediaId/ref/parentPageID) in migrated content resolve on B (${idr_checked} checked, ${idr_missing} missing)" >> "$report"
        fi
        ;;
      *)
        echo "- [ ] id references resolve on B: **UNVERIFIED — the check reported success without saying which of its outcomes applied** (a success path added without its marker — see lib/verify.sh's verify_id_references_resolve)" >> "$report"
        incomplete=$((incomplete + 1))
        incomplete_names="${incomplete_names}id-references "
        ;;
    esac
  fi

  # --- the SAME id-reference question, one level deeper: an Etch component
  # PROP with an operator-chosen name (issue #86 — the case
  # verify_id_references_resolve's own header comment already named as
  # unfindable by its fixed-key scan; see verify_component_prop_references_
  # resolve's own header comment for the full mechanism, and its own NIT-5
  # fix-pack note for why this is now THREE-valued, not two, matching
  # verify_page_on_front's own rc==0/rc==2/else shape immediately above in
  # this file rather than the two-valued shape the id-references block
  # just above uses. ---------------------------------------------------------
  local cprop_output="" cprop_rc=0
  cprop_output=$(verify_component_prop_references_resolve "$run_dir" "$id_map_tsv" 2>>"$report") || cprop_rc=$?
  if [ "$cprop_rc" -eq 0 ]; then
    case "$cprop_output" in
      *COMPONENT_PROP_REFS:*)
        local cpr_summary="${cprop_output##*COMPONENT_PROP_REFS:}"
        local cpr_checked cpr_missing
        cpr_checked=$(echo "$cpr_summary" | cut -d: -f1)
        cpr_missing=$(echo "$cpr_summary" | cut -d: -f2)
        if [ "$cpr_checked" -eq 0 ]; then
          echo "- [x] component-prop id references (issue #86) in migrated content resolve on B (0 found to check)" >> "$report"
        else
          echo "- [x] component-prop id references (issue #86) in migrated content resolve on B (${cpr_checked} checked, ${cpr_missing} missing)" >> "$report"
        fi
        ;;
      *)
        echo "- [ ] component-prop id references resolve on B: **UNVERIFIED — the check reported success without saying which of its outcomes applied** (a success path added without its marker — see lib/verify.sh's verify_component_prop_references_resolve)" >> "$report"
        incomplete=$((incomplete + 1))
        incomplete_names="${incomplete_names}component-prop-id-references "
        ;;
    esac
  elif [ "$cprop_rc" -eq 2 ]; then
    echo "- [ ] component-prop id references: **UNVERIFIED — component composition (a migrated component calling another) was detected, one level deeper than this guard's discovery looks (issue #86's own documented scope limit)** — see above" >> "$report"
    incomplete=$((incomplete + 1))
    incomplete_names="${incomplete_names}component-prop-id-references "
  else
    case "$cprop_output" in
      *COMPONENT_PROP_REFS:*)
        local cprf_summary="${cprop_output##*COMPONENT_PROP_REFS:}"
        local cprf_checked cprf_missing
        cprf_checked=$(echo "$cprf_summary" | cut -d: -f1)
        cprf_missing=$(echo "$cprf_summary" | cut -d: -f2)
        echo "- [ ] **HARD FAIL: migrated content references id(s), through an Etch component prop, that do not resolve to any post on B** (${cprf_checked} checked, ${cprf_missing} missing) — see above" >> "$report"
        ;;
      *)
        echo "- [ ] **HARD FAIL: could not verify migrated content's component-prop id references against B (query failed, or a call site's JSON did not parse)** — see above" >> "$report"
        ;;
    esac
    hard_fail=1
  fi

  # --- migrated content matches A's, after the same remaps graft applies —
  # issue #52 / ADR 0008's "Required regardless" list, guard 1. Three-valued
  # exactly like page_on_front/navigation above (0/1/2, never folded). -------
  local content_match_output="" content_match_rc=0
  content_match_output=$(verify_migrated_content_matches_source "$run_dir" "$id_map_tsv" "$manifest" 2>>"$report") || content_match_rc=$?
  if [ "$content_match_rc" -eq 1 ]; then
    echo "- [ ] **HARD FAIL: migrated post content does not match A's (after remap) on B** — see above" >> "$report"
    hard_fail=1
  elif [ "$content_match_rc" -eq 2 ]; then
    case "$content_match_output" in
      *CONTENT_MATCH:none-imported:*)
        # review finding B5: A's WXR export was not empty, but NOTHING
        # from it actually landed in id-map.tsv this run — the exact
        # shape of the observed defect, and must never render as a pass.
        echo "- [ ] migrated content matches A's: **UNVERIFIED — ${content_match_output##*none-imported:} item(s) were selected for migration but id-map.tsv has no matching row for any of them (nothing was actually imported this run)** — see above" >> "$report"
        ;;
      *CONTENT_MATCH:no-rewrite-record:*)
        # review round 3, MAJOR: this run has no module-content-
        # rewrites.tsv at all (predates graft recording it unconditionally,
        # or a kill mid-hook lost it) -- guard 1 cannot tell "nothing was
        # module-rewritten" from "something was, and we lost the record",
        # so it refuses to guess in either direction rather than risk a
        # false HARD FAIL on a genuinely correct graft.
        #
        # Review round 4 nit: "re-run graft" is generic advice this
        # phase's own INCOMPLETE footer gives for every incomplete check,
        # and it does NOT work for this one specifically when the cause is
        # an old run dir -- see this check's own log_error for why (the
        # module_hooks step marker is already set, so a resume skips it).
        # Said explicitly here too, not just in the log.
        echo "- [ ] migrated content matches A's: **UNVERIFIED — no module-content-rewrites.tsv for this run (${content_match_output##*:} post(s) in scope) — cannot tell whether a module's post_import hook rewrote any of them. If this run dir's graft already completed under an older sitegraft version, re-running graft will NOT fix this (see above) — start a fresh run** — see above" >> "$report"
        ;;
      *CONTENT_MATCH:0:0:*)
        # review finding B2, floor (part b): every row in scope was
        # excluded because a module's post_import hook actually rewrote
        # it (module-content-rewrites.tsv) -- an honest but insufficient
        # fallback on its own, never rendered as a pass.
        echo "- [ ] migrated content matches A's: **UNVERIFIED — every migrated post in scope (${content_match_output##*:}) was rewritten by a module's post_import hook after graft's own remap, so byte-equality could not be verified for any of them** — see above" >> "$report"
        ;;
      *)
        echo "- [ ] migrated content matches A's: **UNVERIFIED — no WXR export found for this run's migrate selection** (see above; not a hard fail on its own, but not a pass)" >> "$report"
        ;;
    esac
    incomplete=$((incomplete + 1))
    incomplete_names="${incomplete_names}migrated-content "
  else
    case "$content_match_output" in
      *CONTENT_MATCH:not-selected*)
        echo "- [x] migrated content matches A's on B (not applicable — nothing was selected for content migration)" >> "$report"
        ;;
      *CONTENT_MATCH:*)
        local cm_summary="${content_match_output##*CONTENT_MATCH:}"
        local cm_compared cm_checkable cm_excluded
        cm_compared=$(echo "$cm_summary" | cut -d: -f1)
        cm_checkable=$(echo "$cm_summary" | cut -d: -f2)
        cm_excluded=$(echo "$cm_summary" | cut -d: -f3)
        if [ "$cm_checkable" -eq 0 ] && [ "$cm_excluded" -eq 0 ]; then
          echo "- [x] migrated content matches A's on B (0 of 0 — nothing was actually imported this run)" >> "$report"
        elif [ "$cm_excluded" -gt 0 ]; then
          # review finding B2: content a module's post_import hook
          # ACTUALLY rewrote (per module-content-rewrites.tsv — Etch
          # component refs, core-wp nav-link ids) is not claimed as
          # byte-equal — named here rather than silently folded into
          # "compared".
          echo "- [x] migrated content matches A's on B (${cm_compared} of ${cm_checkable} compared; ${cm_excluded} post(s) excluded — a module's post_import hook actually rewrote their content after graft's own remap, so byte-equality cannot be claimed for them)" >> "$report"
        else
          echo "- [x] migrated content matches A's on B (${cm_compared} of ${cm_checkable} compared)" >> "$report"
        fi
        ;;
      *)
        echo "- [ ] migrated content matches A's: **UNVERIFIED — the check reported success without saying which of its outcomes applied** (a success path added without its marker — see lib/verify.sh's verify_migrated_content_matches_source)" >> "$report"
        incomplete=$((incomplete + 1))
        incomplete_names="${incomplete_names}migrated-content "
        ;;
    esac
  fi

  # --- migrated content changed from its pre-graft state — issue #52 /
  # ADR 0008's "Required regardless" list, guard 2. This is the check that,
  # ON ITS OWN, would have caught the observed defect: a page wordpress-
  # importer silently skipped stays byte-identical to what backup recorded
  # for it before the graft ran. -----------------------------------------
  local content_unchanged_output="" content_unchanged_rc=0
  content_unchanged_output=$(verify_migrated_content_changed_from_pregraft "$run_dir" "$id_map_tsv" "$manifest" 2>>"$report") || content_unchanged_rc=$?
  if [ "$content_unchanged_rc" -eq 1 ]; then
    echo "- [ ] **HARD FAIL: a post B already had, matching an item this run intended to migrate, is still byte-identical to its pre-graft state** — see above" >> "$report"
    hard_fail=1
  elif [ "$content_unchanged_rc" -eq 2 ]; then
    # review finding B5: covers three distinct causes (WXR export missing;
    # no content_checksums_pre_graft snapshot at all; every skipped item
    # unpairable) — the log_error text captured above already names which
    # one applied for this run; this line's job is only to make sure NONE
    # of the three can ever render as a tick.
    echo "- [ ] migrated content changed from its pre-graft state: **UNVERIFIED** — see above" >> "$report"
    incomplete=$((incomplete + 1))
    incomplete_names="${incomplete_names}content-unchanged "
  else
    case "$content_unchanged_output" in
      *CONTENT_UNCHANGED:not-selected*)
        echo "- [x] migrated content changed from its pre-graft state (not applicable — nothing was selected for content migration)" >> "$report"
        ;;
      *CONTENT_UNCHANGED:*)
        local cu_summary="${content_unchanged_output##*CONTENT_UNCHANGED:}"
        local cu_checked="${cu_summary%%:*}" cu_skipped="${cu_summary##*:}"
        if [ "$cu_checked" -lt "$cu_skipped" ]; then
          # review finding B5 ("partial overlap"): not every skipped item
          # had a pre-graft record to check it against — say so plainly
          # rather than let the phrasing imply full coverage.
          echo "- [x] migrated content changed from its pre-graft state (${cu_checked} of ${cu_skipped} skipped-but-paired post(s) confirmed changed; the remaining $((cu_skipped - cu_checked)) had no pre-graft record to check — see verify_migrated_content_changed_from_pregraft's own ID-pairing scope limit)" >> "$report"
        else
          echo "- [x] migrated content changed from its pre-graft state (${cu_checked} of ${cu_skipped} skipped-but-paired post(s) confirmed changed)" >> "$report"
        fi
        ;;
      *)
        echo "- [ ] migrated content changed from its pre-graft state: **UNVERIFIED — the check reported success without saying which of its outcomes applied** (a success path added without its marker — see lib/verify.sh's verify_migrated_content_changed_from_pregraft)" >> "$report"
        incomplete=$((incomplete + 1))
        incomplete_names="${incomplete_names}content-unchanged "
        ;;
    esac
  fi

  # issue #52 fix-pack, review finding M1: the shared WXR-parse-and-remap
  # cache both guards above may have written (_verify_wxr_items_remapped,
  # this file) is process-scoped and has no reason to survive past this
  # phase_verify call — removed here so it never leaks into a later,
  # separate `sitegraft verify` invocation against the same run_dir.
  rm -f "${run_dir}/.verify-content-items-cache.$$.json" 2>/dev/null || true

  # --- HTTP smoke check (best-effort — never a hard fail on its own absence,
  # design doc §6.5) ----------------------------------------------------------
  local site_b_url="${SITE_B_URL:-}"
  local front_title=""
  if [ -n "$site_b_url" ]; then
    front_title=$(wp_remote b post get "$(wp_remote b option get page_on_front 2>/dev/null || echo "")" --field=post_title 2>/dev/null || echo "")
    # Issue #32: verify_http_smoke now echoes which of its success outcomes
    # applied (see its own header comment) — read it here instead of
    # assuming "returns 200" also means "with expected content". `no-curl`
    # is a KNOWN fact (curl genuinely is not on this machine — live today,
    # since curl is never `require_cmd`'d anywhere in this codebase),
    # ticked not-applicable like the no-SITE_B_URL case below. A success
    # with NO recognizable marker at all (a future success path added
    # without one) is a DIFFERENT thing — the check's own bookkeeping went
    # out of sync — and gets the same fail-closed default every other
    # marker-reading case in this file uses (issue #32 fix-pack, NIT 1):
    # UNVERIFIED, counted toward INCOMPLETE, never silently assumed to be
    # whichever outcome happens to read best.
    local smoke_output="" smoke_rc=0
    smoke_output=$(verify_http_smoke "$site_b_url" "$front_title" 2>>"$report") || smoke_rc=$?
    if [ "$smoke_rc" -eq 0 ]; then
      case "$smoke_output" in
        *HTTP_SMOKE:matched*)
          echo "- [x] HTTP smoke check: ${site_b_url} returns 200 with expected content (best-effort)" >> "$report"
          ;;
        *HTTP_SMOKE:not-compared*)
          echo "- [x] HTTP smoke check: ${site_b_url} returns 200 (body not compared — no front-page title available to match against) (best-effort)" >> "$report"
          ;;
        *HTTP_SMOKE:no-curl*)
          echo "- [x] HTTP smoke check (not applicable — curl not found on this machine; best-effort check skipped)" >> "$report"
          ;;
        *)
          echo "- [ ] HTTP smoke check: **UNVERIFIED — the check reported success without saying which of its outcomes applied** (a success path added without its marker — see lib/verify.sh's verify_http_smoke)" >> "$report"
          incomplete=$((incomplete + 1))
          incomplete_names="${incomplete_names}http-smoke "
          ;;
      esac
    else
      echo "- [ ] HTTP smoke check FAILED (best-effort, not a hard fail — see above): ${site_b_url}" >> "$report"
    fi
  else
    # Viktor's re-review of PR #26, N2: `- [ ]` means "not verified"
    # everywhere else in this report now, so an unticked box here sat
    # underneath a "Result: PASS" footer saying two contradictory things. No
    # SITE_B_URL in the profile is a KNOWN not-applicable read straight from
    # the loaded profile — the same category as "no domain was configured",
    # which is ticked — not an uncertainty.
    echo "- [x] HTTP smoke check (not applicable — no SITE_B_URL configured in this profile)" >> "$report"
  fi

  # --- stack re-licensing reminder (design doc §12/§6.5) — not a pass/fail
  # check: licensing isn't something sitegraft can verify. Just a reminder
  # that would otherwise be easy to forget once the run reports success. ----
  local copied; copied=$(echo "$manifest" | jq -r '.stack // {} | to_entries[] | select(.value.resolution == "copy") | .key')
  if [ -n "$copied" ]; then
    echo "- [ ] **REMINDER: re-license on B before going live** — copied from A and activated: $(echo "$copied" | tr '\n' ' ')" >> "$report"
  fi

  # --- overall result: three-valued, not a plain pass/fail boolean (Nat's
  # review of PR #26 — see this function's own header comment for the full
  # model). HARD FAIL outranks INCOMPLETE: a confirmed defect is checked
  # first and wins regardless of how many checks were also incomplete. ------
  local exit_code=0
  {
    echo
    if [ "$hard_fail" -ne 0 ]; then
      echo "**Result: HARD FAIL — see the item(s) above marked HARD FAIL. Do not consider this graft done.**"
      exit_code=1
    elif [ "$incomplete" -ne 0 ]; then
      # ${incomplete_names% } — the names are accumulated with a trailing
      # separator space, which otherwise prints as "... migrated-options ."
      # (N6 of Viktor's re-review of PR #26).
      echo "**Result: INCOMPLETE — ${incomplete} check(s) could not be verified: ${incomplete_names% }. This graft is not confirmed — re-run \`sitegraft graft\` to resume the interrupted step(s), then verify again.**"
      exit_code=2
    else
      echo "**Result: PASS**"
    fi
  } >> "$report"

  log_info "verify report written: ${report}"
  return "$exit_code"
}
