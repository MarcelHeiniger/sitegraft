#!/usr/bin/env bash
# lib/plan.sh — phase: plan. Builds default selections from module detection,
# warns on scope gaps (design doc §12/§13), gates on custom code found on B
# (§14), drives interactive stack resolution and adjustment, freezes the
# manifest.

# plan_defaults <scan_a_json_path> <scan_b_json_path> [profile] — dispatches
# every discovered module against both scans (design doc §6.2 step 2-3): a
# module detected on A goes to migrate (with whatever
# post_types/option_keys/tables it declares); a module detected on B and NOT
# on A goes to protect instead. A module detected on both sites is only ever
# migrated — its content on B is expected to be replaced/merged by the
# graft, not separately protected. Not pure (reads scan files from disk and
# calls into the module registry), so tested directly with fabricated
# modules rather than as a jq one-liner — see tests/unit/test_plan.bats.
#
# `profile` (optional, new in this fix-pack) is passed straight through to
# manifest_new to populate the manifest's `profile` field (design doc §4).
# SITE_A_ALIAS/SITE_B_ALIAS are read directly from the environment, not
# passed as parameters — by the time phase_plan calls this, profile_load has
# already exported them (same pattern every other SITE_*_* consumer in this
# codebase uses, e.g. wp_remote in lib/inventory.sh).
plan_defaults() {
  local scan_a_json="$1" scan_b_json="$2" profile="${3:-}"
  local manifest
  # Issue #73: this used to read `.site_url`, a key `scan` never wrote (the
  # only two places that key existed in the whole codebase were these two
  # `jq` READS of it) — every manifest froze with search_replace.from/to
  # both defaulted to the literal string "unknown".
  #
  # Priority order (Marcel's own catch, verified live against a real
  # profile and a real scan on the same run): `SITE_A_URL`/`SITE_B_URL`
  # from the profile — if the operator set them — WIN over `scan`'s own
  # `home_url`, not the other way around. Both keys have been on
  # SITEGRAFT_PROFILE_KEYS (lib/profile.sh) since design doc §5.1, both
  # are optional, and until this fix SITE_A_URL was read NOWHERE in the
  # codebase (dead configuration an operator could fill in and have
  # silently ignored) while SITE_B_URL was read only by verify's HTTP
  # smoke check — neither ever reached the domain remap this issue is
  # about. profile_load has already exported both as real (not merely
  # local) shell variables by the time phase_plan calls this (same
  # pattern every other SITE_*_* consumer in this codebase already relies
  # on, e.g. wp_remote in lib/inventory.sh), so reading them here needs no
  # new plumbing.
  #
  # The reasoning FOR this order, not just the mechanics: the operator
  # knows which public domain they are actually migrating to/from — this
  # tool can only ever INFER it, from whatever WordPress happens to have
  # recorded in its own `home` option. Those two can disagree, and not as
  # an edge case: reproduced live on a real DDEV-fronted site A, where
  # `home` held DDEV's own internal `*.ddev.site:8443` address (what `wp
  # option get home` actually returns behind that proxy) while the site's
  # real content — 27 occurrences, measured directly against the
  # database — carried the PUBLIC domain the profile's own SITE_A_URL
  # already named. A site behind any proxy, SSH tunnel, or local dev
  # front-end can carry more than one domain in its own database, and
  # `home` is not guaranteed to be the one that matters for THIS
  # migration's content. An operator-supplied SITE_A_URL/SITE_B_URL is
  # exact, by construction; scan's `home_url` is a best-effort inference
  # that can be wrong in exactly this reproducible way.
  #
  # `home_url` is NOT removed as a result — it stays scan's own recorded
  # fact (real inventory data worth having regardless of whether plan
  # ends up using it) and remains the FALLBACK here whenever the profile
  # doesn't name a URL for that site: still the best available guess, and
  # still what lets manifest_validate's own #73 guard (lib/manifest.sh)
  # refuse to freeze when even that guess is missing/unusable, and still
  # subject to the choice between `home`/`siteurl` this fix-pack argued
  # for and now surfaces as a warning when they diverge on A
  # (inventory_scan_site's own header comment; plan_warn_scope_gaps,
  # below) — reduced to a second-rank signal now that a correct
  # profile-supplied URL is the FIRST place this looks, not the only one.
  local site_a_domain site_b_domain site_a_source site_b_source
  if [ -n "${SITE_A_URL:-}" ]; then
    site_a_domain="$SITE_A_URL"; site_a_source="the profile's SITE_A_URL"
  else
    site_a_domain=$(jq -r '.home_url // "unknown"' "$scan_a_json" 2>/dev/null || echo unknown)
    site_a_source="scan's home_url"
  fi
  if [ -n "${SITE_B_URL:-}" ]; then
    site_b_domain="$SITE_B_URL"; site_b_source="the profile's SITE_B_URL"
  else
    site_b_domain=$(jq -r '.home_url // "unknown"' "$scan_b_json" 2>/dev/null || echo unknown)
    site_b_source="scan's home_url"
  fi
  # NIT-1 (third review round): the override was totally silent — nothing
  # said which source (profile vs scan) supplied either end, even though
  # the whole justification for reading SITE_A_URL/SITE_B_URL at all is a
  # count this tool itself never runs. `log_warn`, not `log_info`: this
  # function's STDOUT is the manifest JSON itself, captured by every
  # caller via `manifest=$(plan_defaults ...)` — `log_info` (lib/core.sh)
  # writes to stdout and would corrupt that capture; every logging
  # primitive safe to use inside this function writes to stderr.
  log_warn "plan: A's domain remap source is ${site_a_source} ('${site_a_domain}')"
  log_warn "plan: B's domain remap source is ${site_b_source} ('${site_b_domain}')"

  # BLOCKER-1 (third review round): SITE_A_URL/SITE_B_URL are taken
  # verbatim above — lib/profile.sh whitelists the KEY, never validates
  # the VALUE. See _plan_normalize_remap_url's own header comment for the
  # full reasoning (two reproduced corruption shapes: a trailing slash on
  # one side only, or a missing scheme on one side only) and why this
  # normalization has to run on WHICHEVER value was just chosen — profile
  # or scan — not only on the profile path: a half-profile/half-scan pair
  # is exactly the shape most likely to mismatch in form, and it is the
  # shape this priority order makes newly possible.
  site_a_domain=$(_plan_normalize_remap_url "A's domain (${site_a_source})" "$site_a_domain") || return 1
  site_b_domain=$(_plan_normalize_remap_url "B's domain (${site_b_source})" "$site_b_domain") || return 1
  manifest=$(manifest_new \
    "$site_a_domain" \
    "$site_b_domain" \
    "$profile" "${SITE_A_ALIAS:-a}" "${SITE_B_ALIAS:-b}")

  # A module found on A was classified `migrate`, and only a module found
  # ONLY on B (the `elif`) was classified `protect`. "Present on A" is a
  # reasonable proxy for "this is what we are bringing over" — right up until
  # A is itself a clone of B's production site, which is the normal way these
  # redesigns get built. Then the target's own business plugin is present on
  # BOTH sides, wins the first test, and lands in `migrate`: graft would
  # overwrite B's live bookings/orders with A's copy, stale since the fork.
  # Exactly the outcome this tool exists to make impossible, reachable by
  # doing nothing more exotic than enabling a shipped module.
  #
  # Swapping the two tests is NOT the fix, and looks like it is. `core-wp`
  # detects the `page` post type and `etch` detects the Etch plugin — both are
  # present on A and B in any real redesign, so a plain B-first rule sends
  # them to `protect` and the run migrates nothing at all. A silent no-op
  # instead of a data loss: still a broken tool.
  #
  # The missing distinction is what KIND of module it is, and the contract has
  # no field for it — but it does have a reliable proxy already. Migration
  # never copies tables: manifest_add_migrate does not even take a tables
  # argument, by design (design doc §3.2, plugin-owned tables are a
  # protection concern). So a module that declares `_tables` can only be
  # describing data to protect. Those modules, and only those, are tested
  # against B first.
  #
  # Everything else keeps the old order exactly: core-wp, etch and acss
  # declare no tables, so they still go to `migrate` when present on A, and
  # to `protect` when found only on B.
  # Selections are resolved through module_selection (lib/modules.sh), never
  # by calling a module's `_post_types`/`_option_keys` directly, so that the
  # scan-computed `_dynamic` lists and the `_option_keys_exclude` globs are
  # applied HERE — at the one point where a module's claim becomes manifest
  # content. That placement is the whole reason issue #13's fix is complete
  # rather than partial: graft and verify read the manifest and nothing else
  # (graft_migrate_options, verify_*), so an option key excluded before the
  # manifest is written is excluded everywhere downstream, with no second
  # enforcement point to keep in sync. See
  # docs/decisions/0007-module-dynamic-selections.md.
  #
  # WHICH scan a `_dynamic` function is resolved against follows the bucket
  # the module is headed for, decided below: a module bound for `migrate`
  # describes what leaves A, so it sees scan A; a module bound for `protect`
  # describes what must not be touched on B, so it sees scan B. `tables` is
  # always resolved against B — migration never copies tables by design
  # (manifest_add_migrate takes no tables argument), so a table claim can
  # only ever be about B.
  local mod
  for mod in $SITEGRAFT_MODULES; do
    # N5: whether a module OWNS tables is decided from whether it DECLARES a
    # tables function, not from expanding one. The expansion used to come
    # first, for every discovered module, so a `_tables_dynamic` that failed
    # took the whole run down even for a module present on NEITHER site —
    # while the identical failure in a `_post_types_dynamic` was harmless,
    # because that expansion already happened after detection. The asymmetry
    # was an accident of ordering, not a rule anyone chose.
    #
    # Declaring the function is the claim of kind this ordering rule is
    # actually about ("a module that declares `_tables` can only be
    # describing data to protect"), so reading the declaration is if anything
    # closer to the rule's own wording than counting the expanded list was.
    # One behavior does change: a module that declares a tables function which
    # legitimately returns nothing for THIS site is now tested against B
    # first, where it used to be treated as tableless. That is the same
    # answer for every shipped module (core-wp, etch and acss declare no
    # tables at all) and the safer direction for any other: a module that
    # says it owns tables is describing data to protect even on a site where
    # it currently owns none.
    local owns_tables=0
    if module_has_fn "$mod" tables || module_has_fn "$mod" tables_dynamic; then
      owns_tables=1
    fi

    local bucket="" target_scan=""
    if [ "$owns_tables" = "1" ] && module_call "$mod" detect "$scan_b_json"; then
      bucket=protect; target_scan="$scan_b_json"
    elif module_call "$mod" detect "$scan_a_json"; then
      bucket=migrate; target_scan="$scan_a_json"
    elif module_call "$mod" detect "$scan_b_json"; then
      bucket=protect; target_scan="$scan_b_json"
    else
      continue
    fi

    local pt_lines ok_lines pt ok
    pt_lines=$(module_selection "$mod" post_types "$target_scan") || return 1
    ok_lines=$(module_selection "$mod" option_keys "$target_scan") || return 1
    pt=$(_plan_lines_to_json "$pt_lines")
    ok=$(_plan_lines_to_json "$ok_lines")

    if [ "$bucket" = migrate ]; then
      manifest=$(manifest_add_migrate "$manifest" "$mod" "$pt" "$ok")
    else
      # Expanded HERE, and only here: `manifest_add_migrate` takes no tables
      # argument by design, so the list is needed for the protect bucket and
      # nowhere else. Narrowing the expansion to the one place its result is
      # used is what removes the "aborts on a module nobody detected" case,
      # while keeping it fail-closed for the module whose manifest entry
      # actually depends on it.
      local tb_lines tb
      tb_lines=$(module_selection "$mod" tables "$scan_b_json") || return 1
      tb=$(_plan_lines_to_json "$tb_lines")
      manifest=$(manifest_add_protect "$manifest" "$mod" "$pt" "$tb" "$ok")
    fi
  done

  echo "$manifest"
}

# _plan_lines_to_json <newline_separated> — the one place the "one name per
# line" module convention is turned into the JSON array the manifest stores.
# Empty lines are dropped, so an empty input yields [] rather than [""].
_plan_lines_to_json() {
  printf '%s\n' "$1" | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# design doc §13 (review finding B2): plan only ever builds a manifest, it
# never touches B, so this is a warning, never a hard failure. The rendering-
# stack mismatch has its own, more useful per-component treatment now
# (plan_resolve_stack, Task 2.4) instead of being a separate blanket warning
# here — offering a fix beats restating that something doesn't match.
plan_warn_scope_gaps() {
  local scan_a_json="$1" scan_b_json="$2"
  if jq -e '.classic_menus_detected == true' "$scan_a_json" >/dev/null 2>&1; then
    log_warn "A has classic nav menu(s) with items ($(jq -r '.classic_menu_names | join(", ")' "$scan_a_json")) — sitegraft v1 does not migrate classic menu assignments (design doc §13). Migrate them by hand or write a module."
  fi
}

# plan_warn_asset_domain_gap <manifest_json> <scan_a_json> — issue #73,
# MAJOR-2(b), MOVED and CORRECTED in the third review round. This used to
# live inside plan_warn_scope_gaps, called BEFORE plan_defaults ever ran,
# comparing scan's own recorded home_url against scan's own site_url —
# which structurally cannot know what plan_defaults actually chose,
# because at that point it hadn't run yet. Once SITE_A_URL/SITE_B_URL
# could win over scan's home_url (this same fix-pack), that produced two
# provably wrong outcomes on the exact scenario this warning exists for:
#   - SILENT when it should have fired: home_url == site_url == the
#     proxy's internal address (both equal, so the old check saw no
#     divergence) while SITE_A_URL names the real public domain — the
#     actual chosen `from` and A's site_url DO diverge, asset URLs won't
#     be rewritten, and the operator hears nothing.
#   - WRONG when it did fire: it named A's scanned home_url in the
#     message ("this run's domain remap only ever rewrites A's HOME
#     domain (https://a.ddev.site:8443)") when the run's ACTUAL remap
#     source was the profile's public SITE_A_URL the whole time — a
#     warning asserting something false about the very run it describes,
#     in a codebase whose first convention is that a check must never
#     claim what it hasn't earned.
#
# Fixed by moving the comparison to run on the CHOSEN `from`
# (`.options.search_replace.from` in the already-built manifest — read
# from `plan`'s own output, not re-derived, so this can never diverge
# from what plan_defaults/the prefilled manifest actually decided) versus
# A's SCANNED site_url — the one half of the old comparison that was
# always correct, since site_url is never itself a remap candidate.
# Called from _phase_plan_build AFTER `manifest` is finalized (both the
# plan_defaults path and the SITEGRAFT_MANIFEST_PREFILLED path — a
# hand-written manifest can have exactly the same gap), not from
# plan_warn_scope_gaps' own early call, which runs before that value
# exists.
#
# Guarded on both being present, non-"unknown"/non-empty strings — a
# `from` or `site_url` scan/plan could not determine is a DIFFERENT,
# harder failure the #73 guards elsewhere already handle; this warning is
# only about two REAL, resolvable values that happen to disagree.
plan_warn_asset_domain_gap() {
  local manifest="$1" scan_a_json="$2"
  local chosen_from a_site
  chosen_from=$(echo "$manifest" | jq -r '.options.search_replace.from // ""')
  a_site=$(jq -r '.site_url // ""' "$scan_a_json" 2>/dev/null)
  if [ -n "$chosen_from" ] && [ -n "$a_site" ] && [ "$chosen_from" != "unknown" ] && [ "$a_site" != "unknown" ]; then
    local chosen_from_origin a_site_origin
    chosen_from_origin=$(_plan_url_origin "$chosen_from")
    a_site_origin=$(_plan_url_origin "$a_site")
    if [ "$chosen_from_origin" != "$a_site_origin" ]; then
      log_warn "this run's domain remap source ('${chosen_from}') and A's own recorded siteurl ('${a_site}') are on different origins — the remap (design doc §9.4) only ever rewrites ${chosen_from_origin}; any asset URL built from A's siteurl (media/plugin/theme URLs under ${a_site_origin} — WP_CONTENT_URL and everything derived from it) will NOT be rewritten and will keep pointing at ${a_site_origin} after migration. Known, documented scope limit (issue #73, MAJOR-2) — review B's migrated content for lingering ${a_site_origin} references after graft, or write a module/manual pass to cover it."
    fi
  fi
}

# _plan_normalize_remap_url <label> <url> — issue #73, BLOCKER-1 (third
# review round): SITE_A_URL/SITE_B_URL are taken verbatim by
# plan_defaults above (lib/profile.sh whitelists the KEY, never validates
# the VALUE), and the resulting from/to pair feeds straight into
# `sitegraft_remap_domain` (lib/php/content-remap-functions.php), a bare
# string split()/join() — never a URL-aware rewrite. Before this fix-pack
# `from`/`to` always came from `wp option get home`, which WordPress
# stores untrailingslashit'd and always with a scheme — both ends were
# structurally guaranteed to match in form. A hand-typed profile value
# opens that guarantee to two corruption shapes, both reproduced live
# against the real function:
#   - a trailing slash on one side, none on the other: from=
#     "https://a.example.com/" to="https://b.example.com" turns
#     ".../about" into "https://b.example.comabout" (the slash that used
#     to separate them was part of `from`'s own match, so it vanishes
#     with it) — same for every asset URL, e.g. an <img src> loses the
#     slash before "wp-content/uploads/...".
#   - a missing scheme on one side: from="a.example.com" (bare host)
#     matches as a SUBSTRING inside "https://a.example.com/about" (the
#     scheme just isn't part of the match), so the replacement re-inserts
#     `to`'s own scheme INSIDE the original one: "https://" + "https://
#     b.example.com" + "/about" = "https://https://b.example.com/about".
# Both shapes leave the recorded `from` string structurally ABSENT from
# the corrupted output — verify_domain_absent's own content search finds
# nothing and reports the domain-absence check GREEN on a run that just
# wrote broken URLs into every migrated page. None of the three existing
# #73 guards (manifest_validate, graft_domain_remap_unusable_reason,
# graft_verify_domain_remap_usable) catch this either: they check
# presence/placeholder/equality, never FORM, and a malformed-but-present,
# non-"unknown", from-not-equal-to-to string satisfies all three.
#
# Normalizes to origin form (scheme://host[:port] — never a trailing
# slash, since the capturing group stops at the first `/`) using the SAME
# regex `_plan_url_origin` (below) already uses, but with the OPPOSITE
# failure contract: `_plan_url_origin` always succeeds (it backs a
# warning, which must never itself abort a run over a value it merely
# couldn't parse); this function REFUSES — logs and returns 1 — on
# anything that doesn't parse as an absolute URL with a real scheme,
# because feeding an unparseable value into a raw str_replace is exactly
# the defect being closed here. Empty string and the literal placeholder
# "unknown" pass through UNCHANGED rather than being rejected: those are
# sentinel values manifest_validate's own #73 guard is already the
# designated place to refuse freezing over — this function's job is
# catching a value that LOOKS usable (non-empty, not "unknown") but isn't
# actually well-formed, the class none of the other guards can see.
_plan_normalize_remap_url() {
  local label="$1" url="$2"
  case "$url" in
    ''|unknown) printf '%s' "$url"; return 0 ;;
  esac
  # BLOCKER (fourth review round): this used to emit BASH_REMATCH[1] from
  # the SAME absolute-URL regex below, which stops capturing at the first
  # `/` — that kills a trailing slash, which is the point, but it ALSO
  # discards a real PATH, which is not. `wp option get home` returns the
  # path on a subdirectory install (design doc §785, lib/inventory.sh's
  # own header comment, test_inventory.bats' own fixtures all use
  # "https://a.example.com/wp") — a documented, common, fully-supported
  # site shape this codebase already models everywhere else. Reached with
  # NO profile involved at all: scan's own home_url on a subdirectory
  # install is enough on its own, so this used to be reachable on every
  # single subdirectory-install migration, not just a malformed profile
  # value. Every downstream URL built from the truncated `from`
  # (verify_domain_absent's own search included) then silently agrees
  # with the corrupted, path-stripped remap and reports green.
  #
  # Fixed by keeping the regex for what it is actually good at —
  # VALIDATING that the value is an absolute URL with a real scheme — and
  # emitting `${url%/}` (strip at most ONE trailing slash, bash's own
  # parameter-expansion suffix removal) instead of the truncating
  # capture group. That keeps the two rules independent: a trailing
  # slash is a formatting artifact (removed), a path is real routing
  # information (kept).
  #
  # NIT (fifth review round): an earlier version of this comment rejected
  # a loop on the grounds that collapsing further would re-hide the path
  # defect behind a second transformation. That reasoning was wrong, and
  # documenting a hazard that does not exist is how the weaker option got
  # chosen. A trailing-slash loop removes only TRAILING SLASHES — it can
  # never eat a path segment, because it strips one `/` at a time from
  # the end and stops the moment the last character is not a slash.
  # "https://a.example.com/blog/" under a loop is "https://a.example.com/
  # blog", exactly as required. (`%%/` was moot for the same reason: for
  # a one-character pattern, `%%` and `%` are identical.)
  #
  # `${url%/}` alone strips exactly ONE trailing slash, so a doubled
  # slash survives as precisely the shape this function exists to remove:
  # "https://a.example.com//" became "https://a.example.com/", which then
  # rewrites <a href="https://a.example.com/about"> to
  # "https://b.example.comabout" — corrupted, and invisible to
  # verify_domain_absent, which searches for the recorded `from` and no
  # longer finds it. Not reachable from `wp option get home`, which
  # cannot produce a doubled slash, but a hand-typed profile value can.
  # The loop below closes it.
  #
  # Whitespace ANYWHERE is refused rather than trimmed -- the glob below
  # is `*[[:space:]]*`, so it also catches an INTERNAL space
  # ("https://a b.example.com"), which no amount of trimming could fix and
  # which the URL regex would otherwise accept (`[^/?#]+` matches a
  # space). Refusing the whole class uniformly is what makes that safe.
  # A `from` with
  # a stray space matches nothing in B's content, so the remap is a
  # silent no-op that verify then reports green — the same false-green
  # this issue exists to kill. A leading space was already refused by the
  # anchored regex; a trailing one was not, because `%/` does not fire
  # when the last character is a space. Copy-paste into a profile makes
  # that plausible, so every position is rejected explicitly and loudly.
  #
  # A NON-BREAKING space (U+00A0) is a routine copy-paste artifact from
  # rendered pages, and `[[:space:]]` does NOT match it outside a UTF-8
  # locale -- measured: caught under en_US.UTF-8 and de_CH.UTF-8, MISSED
  # under C/POSIX and fr_FR.ISO8859-1. sitegraft runs on orchestrators
  # where LC_ALL=C is the norm (cron, CI, a bare SSH environment), which
  # is exactly where it would slip through, match nothing in B's content,
  # and leave a silent no-op remap under a green verify. Matched
  # explicitly by its UTF-8 bytes so the guard does not depend on locale.
  case "$url" in
    *[[:space:]]*|*$'\xc2\xa0'*)
      log_error "plan: refusing to build a domain remap — ${label} ('${url}') contains whitespace. A remap source carrying a stray space matches nothing in B's content, so the remap would be a silent no-op that verify then reports green (issue #73). Remove the space and try again."
      return 1
      ;;
  esac
  if [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]+ ]]; then
    local normalized="$url"
    while [ "${normalized%/}" != "$normalized" ]; do
      normalized="${normalized%/}"
    done
    printf '%s' "$normalized"
    return 0
  fi
  log_error "plan: refusing to build a domain remap — ${label} ('${url}') does not parse as an absolute URL with a scheme (e.g. https://example.com). Feeding this straight into graft's raw string search-replace would corrupt every migrated URL it partially matches instead of rewriting it (issue #73, BLOCKER-1). Fix the value — in the profile if this is SITE_A_URL/SITE_B_URL, or by re-running 'sitegraft scan' if it's a scan-recorded home_url — and try again."
  return 1
}

# _plan_url_origin <url> — scheme://host[:port], stripping any path/query/
# fragment. Used only by plan_warn_scope_gaps' home/siteurl divergence
# check just above: comparing full URL strings would flag a subdirectory
# install (same origin, different path — one domain-prefix remap already
# covers both) as a false divergence; comparing origins does not.
# `[[ =~ ]]`/`BASH_REMATCH` is an existing convention in this codebase
# (lib/profile.sh's own profile-line parser), and portable to the bash 3.2
# floor (docs/decisions/0003-bash-compatibility.md) unlike associative
# arrays or other newer bashisms. Falls back to the raw input unchanged if
# it doesn't look like an absolute URL at all — never errors, since a
# malformed value here should read as "origins differ" (safe direction:
# warn) rather than silently skip the check.
_plan_url_origin() {
  local url="$1"
  if [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$url"
  fi
}

# _plan_confirm <prompt> — plain yes/no. gum if available, else a bare `read`
# defaulting to "no" (an unattended/non-interactive shell with no gum reads
# EOF on the `read`, which bash reports as a failing read — falls through to
# the [ "${ans:-n}" = "y" ] check, which is false; declining by default on an
# unanswerable prompt is the safe direction for every caller of this
# function).
_plan_confirm() {
  local prompt="$1"
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt"
  else
    local ans
    read -r -p "${prompt} [y/N] " ans
    [ "${ans:-n}" = "y" ]
  fi
}

# Deliberately a different, harder-to-trigger confirmation than _plan_confirm
# — design doc §12/§14: overwriting something already installed on B, or
# proceeding past the custom-code awareness gate, are heavier decisions than
# a plain yes/no and must never be one accidental keystroke away, let alone
# automatic.
_plan_confirm_strong() {
  local prompt="$1"
  if command -v gum >/dev/null 2>&1; then
    gum confirm --affirmative="Yes, I understand" --negative="Cancel" "$prompt"
  else
    local ans
    read -r -p "${prompt} Type YES (all caps) to confirm: " ans
    [ "$ans" = "YES" ]
  fi
}

# Presents a flat list of "module: item" toggles built from the manifest's
# migrate bucket and returns the subset the operator kept, one per line.
# gum first, fzf fallback, plain numbered-prompt fallback last.
#
# MINOR bug found live (Viktor's review of PR #2), fixed: `gum choose
# --selected.all` is not a real flag — confirmed against a real `gum choose
# --help` (installed 0.17.0 via `brew install gum` to check): it errors
# "unknown flag --selected.all", exit 80, on the PRIMARY interactive path,
# before the operator ever sees a prompt. The real flag (`--help`: "Options
# that should start as selected (selects all if given *)") is
# `--selected='*'`. Minimum gum version for THAT specific wildcard: 0.15.0 —
# checked against the real release history (`gh api
# repos/charmbracelet/gum/releases`), not asserted from memory: `--selected`
# on `choose` shipped earlier, in v0.7.0, but the `*` "select all" shorthand
# used here landed in v0.15.0 (PR #769). Verified live against 0.17.0 that
# the corrected flag clears parsing and reaches the TTY-open step — the
# furthest any environment without a real controlling terminal can verify.
_plan_prompt_items() {
  local items="$1" # newline-separated "module: item" strings
  if [ -z "$items" ]; then
    return 0
  fi
  if command -v gum >/dev/null 2>&1; then
    printf '%s\n' "$items" | gum choose --no-limit --selected='*'
  elif command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$items" | fzf -m --bind 'ctrl-a:select-all'
  else
    log_warn "neither gum nor fzf found — falling back to a plain yes/no prompt per item"
    # MAJOR bug fixed here (found live, reproduced before this fix): `done <<<
    # "$items"` redirects fd0 for the WHOLE while loop, so the inner `read -r
    # -p "Keep...` ans` — which also defaults to reading fd0 — consumed the
    # NEXT item line as its own answer instead of prompting the operator.
    # Reproduced with 3 items and answers y/n/y: every item came out kept
    # regardless of the typed answers, a silent, wrong selection with no
    # error. Fix: the outer loop reads items from fd3 (bound only to this
    # while loop, via `done 3<<< "$items"`), leaving fd0 entirely free for
    # the inner interactive prompt — the same plain `read -r -p` used
    # (unmodified, on purpose, for consistency) by _plan_confirm/
    # _plan_confirm_strong above, which read fd0 without incident because
    # nothing else in those functions ever contends for it.
    local line ans kept_buf=""
    while IFS= read -r line <&3; do
      [ -n "$line" ] || continue
      # Durcissement (Step 6, tracked from Viktor's Step 2 review, non-
      # blocking at the time): checking `read`'s own exit status here,
      # not just `${ans:-y}`, is the fix. A real operator pressing Enter on
      # this [Y/n] prompt returns 0 with ans="" — that IS a genuine answer
      # (silence means "accept the pre-picked default", the same UX gum's
      # own `--selected='*'` pre-checks everywhere else in this file) and
      # legitimately keeps defaulting to "kept" below. EOF is a different
      # signal entirely: `read` returns non-zero when stdin is closed/
      # exhausted before a line was ever delivered (no TTY, output piped
      # from something that ended, a forgotten redirect) — nobody answered
      # anything. Before this fix, `${ans:-y}` could not tell the two
      # apart: on EOF, ans is also unset, so it silently took the SAME "y"
      # (keep/migrate) branch as a real Enter press — for a tool whose
      # entire job is not touching data nobody explicitly approved moving,
      # defaulting an unanswerable prompt to "migrate this" is the least
      # conservative of the two wrong directions. Fail-safe direction
      # chosen here: abort the whole selection rather than guess.
      #
      # Buffered into $kept_buf rather than printed line-by-line as each
      # item is answered (a deliberate change from the pre-fix version):
      # nothing is written to stdout at all until every item has a real
      # answer. If EOF hits partway through, this function's stdout is
      # completely empty — not just "missing the unanswered items", the
      # already-answered ones ahead of it are withheld too — so the
      # all-or-nothing guarantee holds even for a hypothetical future
      # caller that reads this function's stdout without checking its exit
      # status (plan_select_interactive itself does check it, via its own
      # `|| return 1`, but this makes the function's own contract safe on
      # its own terms rather than relying solely on the caller).
      if ! read -r -p "Keep '${line}'? [Y/n] " ans; then
        log_error "selection interrupted: no operator answer for '${line}' (stdin hit EOF, not a real Enter keystroke) — aborting the whole selection rather than guessing. No manifest will be frozen from this run. Re-run 'sitegraft plan' from a real interactive terminal, or use SITEGRAFT_MANIFEST_PREFILLED for a scripted/non-interactive run (design doc §6.2)."
        return 1
      fi
      case "${ans:-y}" in
        y|Y|'') kept_buf="${kept_buf}${line}"$'\n' ;;
      esac
    done 3<<< "$items"
    printf '%s' "$kept_buf"
  fi
}

# _plan_apply_selection <manifest_json> <kept_items> — pure(ish) half of
# selection handling, split out from plan_select_interactive specifically so
# it's unit-testable: given the manifest and the flat "module: item" list the
# operator decided to KEEP (one per line, exactly what _plan_prompt_items
# returns), rewrites every module's migrate.post_types/option_keys down to
# just the kept subset. An item is classified as a post_type or an
# option_key by checking which of the module's two original lists it came
# from — never by guessing from the string shape.
#
# v1 scope, same as the original plan's Task 2.3: only migrate items are
# touched here. Deselecting an item REMOVES it from migrate — it does not
# move it to protect. An operator who deselects something sitegraft would
# otherwise have migrated is left with that item in neither bucket for this
# run (manifest_validate accepts this, no conflict) rather than it being
# swept into protect, which the design's default-deny principle would
# arguably prefer. Documented as a known v1 gap, not silently shipped as if
# it were a non-issue — protect items (including `_unclaimed`, computed
# after this by phase_plan) stay visible-but-not-togglable here on purpose
# (design doc §3.6: lifting something out of the safe default should never
# be one accidental keystroke).
_plan_apply_selection() {
  local manifest="$1" kept="$2"
  local mod
  for mod in $(echo "$manifest" | jq -r '.migrate | keys[]'); do
    local mod_pt_list mod_re mod_kept_raw kept_pt kept_ok
    mod_pt_list=$(echo "$manifest" | jq -c --arg m "$mod" '.migrate[$m].post_types')
    # $mod is filename-derived (lib/modules.sh: hyphens -> underscores from
    # modules/<name>.sh), never attacker-controlled remote input — but it's
    # still interpolated into a grep/sed REGEX below, and an operator could
    # in principle name a module file something regex-special. Escaped
    # anyway (cheap, and turns a "low risk, note it" nit into a closed one)
    # rather than trusting every future module filename to stay
    # regex-innocuous.
    mod_re=$(printf '%s' "$mod" | sed 's/[.[\*^$()+?{|]/\\&/g')
    # `|| true`: found live, reproduced under `set -euo pipefail` (the mode
    # bin/sitegraft runs under) — with pipefail, a `grep` that matches
    # nothing makes the WHOLE pipeline's exit status non-zero even though
    # the trailing `sed` exits 0, and `set -e` then aborts the function at
    # this assignment. This fires on every real run where a module's kept
    # list is empty (fully deselected in the prompt above) — not a
    # theoretical case.
    mod_kept_raw=$(printf '%s\n' "$kept" | { grep "^${mod_re}: " || true; } | sed "s/^${mod_re}: //")
    kept_pt=$(printf '%s\n' "$mod_kept_raw" | jq -R -s --argjson pt "$mod_pt_list" -c \
      'split("\n") | map(select(length > 0)) | map(select(. as $x | ($pt | index($x))))')
    kept_ok=$(printf '%s\n' "$mod_kept_raw" | jq -R -s --argjson pt "$mod_pt_list" -c \
      'split("\n") | map(select(length > 0)) | map(select(. as $x | ($pt | index($x)) | not))')
    manifest=$(echo "$manifest" | jq --arg m "$mod" --argjson pt "$kept_pt" --argjson ok "$kept_ok" \
      '.migrate[$m].post_types = $pt | .migrate[$m].option_keys = $ok')
  done
  echo "$manifest"
}

# plan_select_interactive <manifest_json> — fine-tunes the migrate selection
# at post_type/option_key granularity (design doc §6.2 step 6). The prompting
# half (this function) is genuinely not unit-testable — no TTY, no gum/fzf in
# CI — covered by the DDEV harness via the non-interactive
# SITEGRAFT_MANIFEST_PREFILLED path instead, same as the original plan's
# Task 2.3 documents. The selection-APPLICATION half is split out into
# _plan_apply_selection above precisely so that part isn't shipped untested.
plan_select_interactive() {
  local manifest="$1"
  local items kept
  items=$(echo "$manifest" | jq -r '.migrate | to_entries[] | .key as $m | (.value.post_types[]?, .value.option_keys[]? | "\($m): \(.)")')
  if [ -z "$items" ]; then
    echo "$manifest"
    return 0
  fi
  echo "Review the items sitegraft will MIGRATE from A onto B (space to toggle, enter to confirm):" >&2
  # `|| return 1`, not left implicit: matches plan_custom_code_gate's own
  # explicit-check convention a few lines below in phase_plan (this
  # codebase's established pattern — see lib/core.sh's sitegraft_cleanup
  # comment and multiple other spots for why bare reliance on `set -e`
  # propagating out of a `var=$(...)` assignment is not trusted here).
  # Needed for real, not just defensive: this is the propagation path for
  # _plan_prompt_items' EOF durcissement fix above — an aborted selection
  # (gum/fzf cancelled, or the plain-fallback EOF case) must stop
  # plan_select_interactive from ever handing a guessed/partial `kept` list
  # to _plan_apply_selection, and must stop phase_plan from freezing a
  # manifest built from it.
  kept=$(_plan_prompt_items "$items") || {
    log_error "item selection did not complete — manifest not frozen. Re-run 'sitegraft plan' when ready to make a full selection."
    return 1
  }
  _plan_apply_selection "$manifest" "$kept"
}

# design doc §12 (Marcel's revision of review finding B1, amended for the
# ACSS v4 plugin-folder-rename case, §3.4): for each stack component
# inventory_stack_diff reports, offer to copy A's resolved slug to B, using a
# stronger confirmation whenever B already has *something* under that module
# (slug_b not null) — whether that's literally the same slug at a different
# version, or a different slug entirely (the legacy-vs-current ACSS case).
# Never installs from anywhere but A. Declining leaves the component "skip"
# — graft's hard precondition (Task 4.1) picks it up from there.
plan_resolve_stack() {
  local manifest="$1" scan_a_json="$2" scan_b_json="$3"
  local diff; diff=$(inventory_stack_diff "$scan_a_json" "$scan_b_json")
  local component
  for component in $(echo "$diff" | jq -r 'keys[]'); do
    local slug_a slug_b ver_a ver_b resolution
    slug_a=$(echo "$diff" | jq -r --arg c "$component" '.[$c].slug_a')
    slug_b=$(echo "$diff" | jq -r --arg c "$component" '.[$c].slug_b')
    ver_a=$(echo "$diff" | jq -r --arg c "$component" '.[$c].version_a')
    ver_b=$(echo "$diff" | jq -r --arg c "$component" '.[$c].version_b')
    if [ "$slug_b" = "null" ]; then
      log_warn "${component} is on A (${slug_a} v${ver_a}) but not on B."
      if _plan_confirm "Copy ${component} from A and activate it on B?"; then
        resolution="copy"
      else
        resolution="skip"
      fi
    else
      log_warn "B already has ${component} installed as '${slug_b}' (v${ver_b}) — A has it as '${slug_a}' (v${ver_a}). Copying A's version will add A's folder alongside B's existing one and activate it."
      if _plan_confirm_strong "Copy A's ${component} ('${slug_a}' v${ver_a}) to B and activate it, leaving B's existing '${slug_b}' folder in place but inactive?"; then
        resolution="copy"
      else
        resolution="skip"
      fi
    fi
    manifest=$(echo "$manifest" | jq \
      --arg c "$component" --arg sa "$slug_a" --arg sb "$slug_b" --arg va "$ver_a" --arg vb "$ver_b" --arg r "$resolution" \
      '.stack[$c] = {
        slug_a: $sa,
        slug_b: (if $sb == "null" then null else $sb end),
        version_a: $va, version_b: $vb,
        resolution: $r
      }')
  done
  echo "$manifest"
}

# design doc §14 (Marcel's third guardrail): the only truly blocking gate in
# `plan` — no manifest gets written past this point without an explicit
# acknowledgment. Uses _plan_confirm_strong (same weight as
# --allow-stack-mismatch's override), never the plain confirm used elsewhere.
plan_custom_code_gate() {
  local manifest="$1" scan_b_json="$2"
  if [ "$(echo "$scan_b_json" | jq -r '.custom_code_detected // false')" != "true" ]; then
    echo "$manifest"
    return 0
  fi
  log_warn "B has custom-code signal(s): $(echo "$scan_b_json" | jq -c '.custom_code_signals')"
  if ! _plan_confirm_strong "Did you review B's theme for custom code (functions.php, code snippets, mu-plugins) before replacing the theme? Custom code living in the old theme will be LOST."; then
    log_error "custom-code review not acknowledged — refusing to write a manifest. Re-run 'sitegraft plan' once you've reviewed B's theme."
    return 1
  fi
  echo "$manifest" | jq --argjson signals "$(echo "$scan_b_json" | jq '.custom_code_signals')" \
    '.custom_code_review = {acknowledged: true, signals: $signals}'
}

# plan_custom_code_gate_check_prefilled <manifest_json> <scan_b_json_path> —
# non-interactive counterpart to plan_custom_code_gate, used only on the
# SITEGRAFT_MANIFEST_PREFILLED path (phase_plan below). Deviation from the
# plan's literal Task 2.5 wiring, which called the INTERACTIVE gate
# unconditionally, before the prefilled branch — that would block any
# scripted run against a B with a custom-code signal on a live gum/read
# prompt with no TTY to answer it (verified live: this is exactly what the
# DDEV harness's B fixture triggers, via its seeded mu-plugin — see the PR
# report). This function never prompts and never silently skips the check:
# it structurally verifies the prefilled manifest already carries the
# acknowledgment the interactive gate would have required, refusing exactly
# as hard when it's missing — extending Task 2.4's own stated precedent for
# `stack` ("a prefilled manifest is expected to already carry whatever
# decisions its scenario needs") to the custom-code gate.
plan_custom_code_gate_check_prefilled() {
  local manifest="$1" scan_b_json_path="$2"
  if [ "$(jq -r '.custom_code_detected // false' "$scan_b_json_path" 2>/dev/null)" != "true" ]; then
    return 0
  fi
  if [ "$(echo "$manifest" | jq -r '.custom_code_review.acknowledged // false' 2>/dev/null)" = "true" ]; then
    return 0
  fi
  log_error "scan-b.json shows custom_code_detected=true but the prefilled manifest has no custom_code_review.acknowledged=true — refusing (design doc §14: even a scripted/non-interactive plan run must carry an explicit acknowledgment, never a silent skip of the gate)"
  return 1
}

# _plan_freeze_summary <manifest_json> — prints what "Freeze this manifest?"
# is actually about to freeze, on stdout (phase_plan redirects it to stderr,
# same as every other operator-facing message in this file). Recommended
# addition beyond the plan's literal spec (Viktor's review of PR #2): the
# original summary printed only migrate/protect MODULE KEYS ("migrate: etch,
# acss"), not the actual post_types/option_keys/tables an operator selected
# — so a broken selection (like the MAJOR fd-collision bug fixed alongside
# this) would sail through the freeze confirmation unnoticed, since the
# summary never showed enough to catch it. Now lists every item per module,
# for both buckets, including `protect._unclaimed` — an operator should see
# exactly what leaves A and what's protected on B before committing.
#
# Long lists are truncated to the first 15 items + a count of the rest —
# `_unclaimed.option_keys` (extended in this same fix-pack, lib/manifest.sh)
# can easily run into the hundreds on a real WordPress install (autoloaded
# core options, transients, plugin settings), and an unreadable wall of text
# defeats the whole point of this summary existing. Truncation is display-
# only: the full, untruncated list is still what's written to manifest.json
# and what graft consumes — nothing is actually dropped, only how much of it
# is echoed to the terminal before freezing.
_plan_freeze_summary() {
  local manifest="$1"
  echo "$manifest" | jq -r '
    def fmt_items($arr):
      if ($arr | length) == 0 then "(nothing selected)"
      elif ($arr | length) > 15 then (($arr[0:15] | join(", ")) + " ... and \(($arr | length) - 15) more")
      else ($arr | join(", ")) end;
    "migrate:",
    (.migrate | to_entries[] | "  " + .key + ": " + fmt_items((.value.post_types // []) + (.value.option_keys // []))),
    "protect:",
    (.protect | to_entries[] | "  " + .key + ": " + fmt_items((.value.post_types // []) + (.value.tables // []) + (.value.option_keys // [])))
  '
}

phase_plan() {
  local profile="" run_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      *) log_error "unknown flag for plan: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "plan requires --profile <name>"; return 1; }
  # Explicit check, not reliance on the caller's `set -e` (bin/sitegraft has
  # it, bats' function-call context doesn't always): phase_scan already
  # established this exact pattern (lib/inventory.sh) — the plan's own Task
  # 2.3 pseudocode for phase_plan omitted it, an inconsistency fixed here.
  profile_load "$profile" || return 1
  [ -n "$run_dir" ] || run_dir=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1 || true)
  [ -n "$run_dir" ] || { log_error "no scan run found for profile ${profile} — run 'sitegraft scan' first"; return 1; }

  # N6: every failure below leaves through one place, so the stale-manifest
  # warning is stated once and can never be forgotten on a path added later.
  local rc=0
  _phase_plan_build "$profile" "$run_dir" || rc=$?
  if [ "$rc" -ne 0 ]; then
    _plan_warn_stale_manifest "$run_dir"
  fi
  return "$rc"
}

# _plan_warn_stale_manifest <run_dir> — N6 (third review round). "no manifest
# will be frozen from this run" is true and misleading in the same breath: a
# manifest.json left by an EARLIER, successful plan is still sitting in the
# run directory, still `frozen: true`, and `sitegraft graft` reads that file
# and nothing else. An operator who fixes nothing and simply runs `graft`
# gets the old plan, silently — which is CLAUDE.md's "a skipped step is
# visible", applied to a step that was skipped by failing.
#
# Deliberately NOT deleted: removing an operator's frozen plan on a failure
# path is destructive, and the old plan may be exactly what they intend to
# run. Named instead, together with what would happen if they ran graft.
_plan_warn_stale_manifest() {
  local run_dir="$1"
  [ -f "${run_dir}/manifest.json" ] || return 0
  log_warn "a manifest from an earlier run is still present: ${run_dir}/manifest.json — this run froze nothing, but 'sitegraft graft' reads that file and would run the EARLIER plan. Delete it, or re-run 'sitegraft plan' successfully, before grafting."
}

_phase_plan_build() {
  local profile="$1" run_dir="$2"

  modules_discover
  plan_warn_scope_gaps "${run_dir}/scan-a.json" "${run_dir}/scan-b.json"

  local manifest

  # design doc §14: runs before any step below — none of them should matter
  # until this is settled. Deviation from the plan's literal Task 2.5 wiring
  # (documented in the Task 2.5 commit): the interactive gate is only ever
  # called on the interactive path now. The prefilled/scripted path gets its
  # own non-prompting structural check instead of the interactive gate
  # skipped outright — it can never proceed past a real custom-code signal
  # without an acknowledgment already recorded in the file it was handed,
  # same safety property, just verified instead of asked for live.
  if [ -n "${SITEGRAFT_MANIFEST_PREFILLED:-}" ]; then
    # Fully scripted path (DDEV harness / any non-interactive driver): the
    # prefilled manifest is expected to already carry whatever custom-code
    # acknowledgment AND stack decisions its scenario needs (design doc §12,
    # §14) — plan_resolve_stack's and plan_custom_code_gate's prompts are
    # skipped entirely here, same reasoning as plan_select_interactive below.
    #
    # plan_defaults is deliberately NOT called on this path (it used to be
    # called unconditionally, above the branch, and its result discarded one
    # line later). Two reasons, one cosmetic and one load-bearing: nothing
    # here consumes module defaults, and module_selection's own failure
    # message names SITEGRAFT_MANIFEST_PREFILLED as the way to get a run
    # through while a module's dynamic selection is broken — which would
    # have been a lie if a module failure still aborted this branch.
    manifest=$(cat "$SITEGRAFT_MANIFEST_PREFILLED")
    plan_custom_code_gate_check_prefilled "$manifest" "${run_dir}/scan-b.json" || return 1
  else
    # `|| return 1`, explicit rather than left to the caller's `set -e` (the
    # convention every other call in this function follows, and a real
    # propagation path, not a defensive one): plan_defaults returns non-zero
    # when a module's `_dynamic` selection function fails, and a plan built
    # from a claim a module could not produce must never reach the freeze
    # step (docs/decisions/0007-module-dynamic-selections.md).
    # The message below deliberately does NOT name a cause: plan_defaults
    # has three non-zero exits (a module's dynamic selection, and either
    # end of the domain remap failing to parse or carrying whitespace,
    # #73), each of which logs its own specific error immediately before
    # returning. Naming modules here was accurate while that was the only
    # cause and became a false claim printed under a true one when the
    # URL refusals started routing through the same path.
    manifest=$(plan_defaults "${run_dir}/scan-a.json" "${run_dir}/scan-b.json" "$profile") || {
      log_error "could not build the default selections — no manifest will be frozen from this run. The specific reason is in the error immediately above; plan_defaults refuses for a module whose dynamic selection failed, and also (since #73) for a domain-remap value that does not parse or carries whitespace."
      return 1
    }
    manifest=$(plan_custom_code_gate "$manifest" "$(cat "${run_dir}/scan-b.json")") || return 1
    # `|| return 1` added to both calls below (Step 6 durcissement pass) for
    # the same reason plan_custom_code_gate already has it just above —
    # consistency, and the real fix for plan_select_interactive: without
    # this, an aborted selection (see _plan_prompt_items' EOF handling)
    # would leave `manifest` holding whatever plan_select_interactive
    # printed on failure (nothing, since it returns 1 before echoing
    # anything) while phase_plan carried on toward freezing it anyway.
    # plan_resolve_stack itself never actually returns non-zero today (an
    # unanswered/EOF stack-copy prompt already resolves the safe way —
    # _plan_confirm/_plan_confirm_strong default to declining, i.e.
    # resolution="skip", the protective direction, not an abort) — added
    # here defensively, matching the same call shape, so a future change to
    # that function can't silently regress this propagation.
    manifest=$(plan_resolve_stack "$manifest" "${run_dir}/scan-a.json" "${run_dir}/scan-b.json") || return 1
    manifest=$(plan_select_interactive "$manifest") || return 1
  fi

  # MAJOR-2(b) fix (issue #73, third review round): must run HERE, after
  # `manifest` is finalized on BOTH branches above — see
  # plan_warn_asset_domain_gap's own header comment for why the earlier
  # placement (inside plan_warn_scope_gaps, called before this point ever
  # existed) was structurally unable to know the chosen remap source, and
  # produced both a false silence and a false claim as a result.
  plan_warn_asset_domain_gap "$manifest" "${run_dir}/scan-a.json"

  # design doc §3.6: default-deny — computed once, here, after the manifest
  # (whether built interactively above or supplied prefilled) has reached its
  # final migrate/protect state for this run, not inside plan_defaults where
  # it would only ever see the module defaults (see the Task 2.2 commit for
  # why that ordering is wrong).
  # `|| return 1` for the same reason as the three calls above (Step 6
  # hardening pass): without it, a failed assignment leaves `manifest`
  # empty and execution would carry on toward _plan_freeze_summary and
  # manifest_freeze as if unclaimed had resolved to nothing.
  manifest=$(manifest_compute_unclaimed "$manifest" "$(cat "${run_dir}/scan-b.json")") || return 1

  if [ -z "${SITEGRAFT_MANIFEST_PREFILLED:-}" ]; then
    _plan_freeze_summary "$manifest" >&2
    _plan_confirm "Freeze this manifest? Nothing outside migrate/protect above will ever be touched by graft." || {
      log_error "manifest not frozen — re-run 'sitegraft plan' when ready"
      return 1
    }
  fi

  manifest=$(manifest_freeze "$manifest") || { log_error "manifest failed validation — not frozen"; return 1; }
  # Recommended, matching phase_scan's own treatment of anything this tool
  # writes to the state dir (Task 1.5's M4 note): the manifest names every
  # module/post_type/option_key/table this run will touch, which is
  # information a shared/group-readable state dir shouldn't leak by default,
  # even though (unlike scan-*.json) it holds no raw option values. chmod
  # AFTER writing (not a umask change before it) — a umask change here would
  # leak out of this function for the rest of the process, the exact
  # subshell-scoping problem phase_scan's own M4 fix (lib/inventory.sh)
  # deliberately avoids.
  echo "$manifest" > "${run_dir}/manifest.json"
  chmod 600 "${run_dir}/manifest.json" 2>/dev/null || true
  log_info "manifest frozen: ${run_dir}/manifest.json"
}
