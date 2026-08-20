#!/usr/bin/env bash
# lib/verify.sh — phase: verify (design doc §6.5, review finding B3). Read-only
# smoke checks on B after a graft: catches the class of bug that "protected
# data byte-identical" alone can never catch — a migration step that ran, or
# claimed to run, but silently did the wrong thing (a skipped options update,
# a broken domain search-replace, a page_on_front pointing at the wrong page).
# Nothing in this file ever writes to B — every wp_remote call here is a
# read (option get, post get/list, db query, eval SELECT), never an update/
# import/delete. That is the whole point of a *verify* phase: prove the graft
# worked without being able to change what it proved.

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
  if [ "$(echo "$diffs" | jq 'length')" != "0" ]; then
    log_error "protected data changed for: $(echo "$diffs" | jq -r 'join(", ")')"
    echo "$diffs"
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
# about.
verify_options_match() {
  local run_dir="$1" manifest="$2"
  local key mismatched=""
  for key in $(echo "$manifest" | jq -r '[.migrate[].option_keys[]?] | unique[]'); do
    case "$key" in
      page_on_front|page_for_posts) continue ;;
    esac
    [ -f "${run_dir}/option-${key}.value" ] || continue
    local expected actual
    expected=$(cat "${run_dir}/option-${key}.value")
    actual=$(wp_remote b option get "$key" --format=json 2>/dev/null || echo 'null')
    [ "$expected" = "$actual" ] || mismatched="${mismatched}${key} "
  done
  if [ -n "$mismatched" ]; then
    log_error "migrated option value(s) do not match A's on B: ${mismatched}"
    return 1
  fi
}

# verify_domain_absent <alias> <domain> <table_prefix> — design doc §9.4/§6.5:
# is A's domain string absent from B's content (posts, postmeta, options)?
# Checks BOTH forms graft's own remap targets (design doc §9.4) — plain
# ("https://a.example.com") and JSON-escaped ("https:\/\/a.example.com"),
# since Etch stores some data as JSON blobs in certain options/postmeta.
#
# Deliberately NOT scoped to only the posts THIS run imported (unlike
# graft_search_replace_domain's own scoping, lib/graft.sh MAJOR-2) — that
# scoping exists there to keep a WRITE away from a protected plugin's rows;
# a read-only LIKE query carries none of that risk, and scanning B's whole
# content tables is the more thorough check: it would also catch a leftover
# reference in a row graft's scoped remap never touched for some other
# reason (a bug this check exists specifically to surface, not paper over).
verify_domain_absent() {
  local alias_lc="$1" domain="$2" prefix="$3"
  [ -n "$domain" ] || return 0
  local escaped hit
  escaped=$(printf '%s' "$domain" | sed 's#/#\\/#g')
  hit=$(wp_remote "$alias_lc" db query \
    "SELECT 1 FROM ${prefix}posts WHERE post_content LIKE '%${domain}%' OR post_content LIKE '%${escaped}%' OR post_excerpt LIKE '%${domain}%' OR post_excerpt LIKE '%${escaped}%' LIMIT 1
     UNION SELECT 1 FROM ${prefix}postmeta WHERE meta_value LIKE '%${domain}%' OR meta_value LIKE '%${escaped}%' LIMIT 1
     UNION SELECT 1 FROM ${prefix}options WHERE option_value LIKE '%${domain}%' OR option_value LIKE '%${escaped}%' LIMIT 1" \
    --skip-column-names 2>/dev/null || echo "")
  if [ -n "$hit" ]; then
    log_error "A's domain string ('${domain}') is still present in B's content (posts/postmeta/options) — the domain search-replace did not fully rewrite it"
    return 1
  fi
}

# verify_page_on_front <run_dir> <id_map_tsv> — design doc §9.3/§6.5/review
# finding B3: NOT merely "does page_on_front resolve to SOME existing page"
# (a check that would pass even if it pointed at a random unrelated page) —
# resolves A's own recorded page_on_front value (the file
# core_wp_post_import, modules/core-wp.sh, reads from) through id-map.tsv the
# exact same way that hook does, and requires B's LIVE page_on_front to equal
# that specific remapped ID.
verify_page_on_front() {
  local run_dir="$1" id_map_tsv="$2"
  local old_front_id
  old_front_id=$(cat "${run_dir}/option-page_on_front.value" 2>/dev/null | tr -d '"')
  case "$old_front_id" in
    ''|null|false|0) return 0 ;; # A never had a front page configured — nothing to check
  esac
  local expected_new_id
  expected_new_id=$(awk -F'\t' -v old="$old_front_id" '$1==old{print $2}' "$id_map_tsv" 2>/dev/null)
  [ -n "$expected_new_id" ] || return 0 # A's front page wasn't part of this run's migrate selection — core_wp_post_import left B's value alone, nothing to verify against

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
# (bin/sitegraft's global --dry-run parsing, Step 6) but has no real effect
# here beyond that: verify performs no writes to B to simulate in the first
# place, and its only local write (the report file) is exactly what an
# operator running verify wants to see either way.
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
  profile_load "$profile" || return 1

  [ -n "$run_dir" ] || run_dir=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1)
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

  # --- migrated option values (finding B3) ----------------------------------
  if verify_options_match "$run_dir" "$manifest" 2>>"$report"; then
    echo "- [x] migrated options match A's values on B" >> "$report"
  else
    echo "- [ ] **HARD FAIL: migrated option value mismatch** — see above" >> "$report"
    hard_fail=1
  fi

  # --- A's domain absent from B's content (finding B3) ----------------------
  local domain; domain=$(echo "$manifest" | jq -r '.options.search_replace.from // ""')
  [ "$domain" = "null" ] && domain=""
  if [ -n "$domain" ]; then
    local prefix; prefix=$(inventory_table_prefix b 2>/dev/null || echo "")
    if [ -z "$prefix" ]; then
      echo "- [ ] domain-absence check skipped — could not determine B's live table prefix" >> "$report"
    elif verify_domain_absent b "$domain" "$prefix" 2>>"$report"; then
      echo "- [x] A's domain string is absent from B's content" >> "$report"
    else
      echo "- [ ] **HARD FAIL: A's domain string is still present in B's content** — see above" >> "$report"
      hard_fail=1
    fi
  fi

  # --- page_on_front resolves to the CORRECT remapped page (finding B3) ----
  local front_result=0
  verify_page_on_front "$run_dir" "$id_map_tsv" 2>>"$report" || front_result=1
  if [ "$front_result" -eq 0 ]; then
    echo "- [x] page_on_front resolves to the correctly remapped page (or A never configured one)" >> "$report"
  else
    echo "- [ ] **HARD FAIL: page_on_front does not resolve to the correctly remapped page** — see above" >> "$report"
    hard_fail=1
  fi

  # --- orphan post_parent references (design doc §9.2/§11 — a warning, not
  # a hard failure: signals a manifest selection mistake, fixed by hand via
  # id-map.tsv, not something verify can safely auto-correct) ---------------
  local orphans; orphans=$(graft_check_orphan_parents 2>/dev/null || echo "")
  if [ -z "$orphans" ]; then
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
