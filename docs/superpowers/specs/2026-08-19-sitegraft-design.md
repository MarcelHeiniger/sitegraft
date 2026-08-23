# sitegraft — Design Doc

**Date:** 2026-08-19 · **Author:** Rosalinde · **Status:** accepted (self-review done)

> This document is the full spec for sitegraft. The implementation plan
> (`docs/plans/2026-08-19-sitegraft-implementation.md`) argues from this document —
> the two travel together.

---

## 0. Decisions already made (do not reopen)

Full brainstorming session with Marcel, 2026-08-19. Summarized here for the record
(detail lives in the original mission brief, not reproduced here):

1. Name **sitegraft**, CLI command `sitegraft`.
2. Modular bash CLI organized in phases — no monolith, no Python/Node, no WordPress
   plugin, no web UI, no MCP.
3. Technical base: WP-CLI + native WXR for content; options copied individually
   (`wp option get/update`); tables owned by a plugin via `wp db export --tables=`.
4. Pluggable module system ("graft modules") — the extensibility point.
5. Separate, re-runnable phases: `scan → plan → backup → graft → verify → restore`.
6. Interactive selection at post-type + option-key granularity, via `gum choose`
   (fallback `fzf`), result = a frozen manifest.
7. Backup built into the tool, host-agnostic, with a generated `restore.sh`.
8. Old→new ID mapping via a temporary mu-plugin on B, hooked into wordpress-importer.
9. Two credential paths (per-profile file OR interactive prompt); profiles hold
   no secrets, but they do hold real hosts and paths, so they are local-only
   and gitignored (issue #18).
10. Bash portability, minimal dependencies, never `scp`.
11. Etch specifics: templates live in the database only (no file fallback);
    navigation is often a dynamic `wp:page-list` block — verify per site in `scan`,
    never assume.
12. Optional `clean` sub-step inside `graft`.
13. Hardening: `set -euo pipefail`, mktemp+trap, WXR integrity gate, a global
    `--dry-run`, `--authors=skip`, colored logs, never `scp`.

**Clarification received mid-design (already reflected throughout this document and
the whole repo):** `repo/` will be published as a **public** GitHub repo under the
MarcelHeiniger account. Consequence: zero secrets, zero real hosts/IPs, zero client
names anywhere — not even as "realistic-looking" examples — only generic placeholders
(`example.com`, `user@host`, `<profile>`); MIT LICENSE; the entire repo, including
every doc, is US English.

### 0.1 Decisions Rosalinde made alone during design (need validation)

The original mission brief left several implementation points open ("decide and
document it"). Here are the choices made, with rationale, to be validated by Marcel
before Step 1 of the plan starts:

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **`jq`** as a dependency to read/write the manifest as **JSON** | The manifest has a structure nested per module (post_types × option_keys × tables). A flat KEY=VALUE format can't represent that cleanly. `jq` is nearly universal (`brew install jq` / `apt install jq`), lightweight, and far safer than a hand-rolled JSON parser in bash. |
| D2 | **Target bash 3.2 compatibility** (no associative arrays, no `mapfile`) instead of requiring bash ≥ 4 | Stock macOS still ships bash 3.2 (bash 4+ is GPLv3, which Apple won't bundle). Requiring `brew install bash` would break the promise of "runs on any Mac with nothing extra beyond the listed dependencies." The module registry is therefore a plain list of names (a string), not an associative array — see §3.2. |
| D3 | **State directory**: `~/.sitegraft/runs/<profile>-<timestamp>/` on the orchestrator, **never cleaned up automatically** | This directory holds the only inspectable safety copies of a run (manifest, ID map, logs, backup). Automatic purging would be dangerous — retention/cleanup stays a manual operator action (`sitegraft prune` could be added later, YAGNI for v1). |
| D4 | **Mapping mu-plugin delivered by dropping a file via `rsync`** into `wp-content/mu-plugins/`, not via `wp plugin install` | WordPress must-use plugins load automatically the moment they're present in `mu-plugins/` — no activation needed, so there's no `wp plugin activate/deactivate` state to manage. A plain file drop + delete is simpler and safer (nothing to deactivate if the run crashes). |
| D5 | **`bats-core`** as the unit test framework for `lib/`'s pure functions | The de facto standard for testing bash, syntax close to conventional unit tests, integrates natively with `set -euo pipefail`, well documented. |

### 0.2 Points to challenge (risks flagged by Rosalinde)

Called out explicitly so Nat has Marcel rule on them rather than burying them in
technical detail:

- **R1 — Idempotent reimport (§11) relies on a metadata convention
  (`_sitegraft_source_id`) that sitegraft itself must set via the mu-plugin.**
  If an operator ever imports content onto B by any means other than sitegraft, this
  safeguard won't see it. Acceptable for v1 (personal tool, controlled usage) but
  worth keeping in mind if the tool is ever used by a third party.
- **R2 — ID remapping inside Etch content (§9.1) uses a two-pass sentinel technique
  on `wp search-replace --regex`.** It's robust on paper but has only been validated
  by reasoning, not by a real run against actual Etch content exported under a real
  license. The DDEV harness (§10) simulates this format without a real Etch license —
  a gap between the real format and the simulated one is possible and would only
  surface on the first real run.
- **R3 — Default-deny on tables/options unclaimed by any module (§3.6) protects well,
  but if `scan` fails to detect a table (e.g. a table without the standard
  `$table_prefix`, or a plugin that stores data somewhere other than the database),
  it never shows up in the manifest — neither on the protected side nor the ignored
  side. The risk isn't contamination (nothing is touched if nothing is selected) but
  a false sense of scan completeness.** This should be documented clearly in `scan`'s
  output ("this scan covers X tables out of Y found in the database — manually verify
  whether the protected plugin stores data outside these tables").
- **R4 — No pilot run is planned before the tool is fully built.**
  The DDEV harness tests the mechanics, not the real-world variety of Etch content
  and third-party plugins encountered in actual use. The first real run will remain
  a moment of truth, even with 100% green tests in DDEV.

---

## 1. Overview

```
site A (Etch/ACSS, source)   ──┐
                                ├──►  sitegraft (orchestrator)  ──►  site B (target, live)
site B (target, live, read)  ──┘
```

sitegraft runs on a third machine (the "orchestrator" — Marcel's Mac, or any machine
with the dependencies). It drives A and B via SSH+wp-cli (or `ddev exec --raw
-p <project> -- wp` locally — see §5.1 for why, verified against a real DDEV
install during Step 1 implementation).
Nothing is installed permanently on A or B — only a temporary mu-plugin touches B,
for the duration of an import, and is then removed.

## 2. Tool layout

```
sitegraft/
├── bin/
│   └── sitegraft                       # entrypoint: parses phase + --profile + flags, dispatches into lib/
├── lib/
│   ├── core.sh                         # logging, colors, require_cmd, mktemp+trap, dry-run helper, ssh/rsync/wp wrappers
│   ├── profile.sh                      # profile loading (profiles/*.conf) + credentials
│   ├── modules.sh                      # module discovery/registry/dispatch (convention-based, bash 3.2)
│   ├── inventory.sh                    # scan phase: introspects a site (post_types, options, tables, plugins)
│   ├── manifest.sh                     # plan phase: builds, validates, reads/writes the manifest (JSON via jq)
│   ├── backup.sh                       # backup phase + restore.sh generation
│   ├── graft.sh                        # graft phase: media, WXR, mu-plugin, remaps, optional clean
│   └── verify.sh                       # verify phase: smoke checks + protected-data checksum comparison
├── modules/
│   ├── _template.sh                    # documented skeleton for writing a new module
│   ├── core-wp.sh                      # pages, posts, blocks, navigation, templates, global styles, media
│   ├── etch.sh                         # Etch CPTs/options
│   ├── acss.sh                         # ACSS options
│   └── motopress.sh.example            # full worked example — NOT auto-loaded (`.example` suffix)
├── mu-plugins/
│   └── sitegraft-id-mapper.php         # template rsynced onto B during graft, removed after (see §8)
├── profiles/
│   └── example.conf                    # example profile, zero secrets
├── tests/
│   ├── unit/
│   │   ├── test_core.bats
│   │   ├── test_manifest.bats
│   │   ├── test_modules.bats
│   │   └── test_graft_remap.bats
│   └── integration/
│       ├── ddev-harness.sh             # full harness orchestration (see §10)
│       └── fixtures/
│           ├── site-a-seed.sh          # seeds simulated Etch content on A
│           └── site-b-fake-plugin/
│               └── fake-plugin.php     # fake protected plugin, its own CPT, table, options
├── docs/                               # this directory
├── LICENSE
├── README.md
└── .gitignore
```

Naming convention: a module's function prefix is its filename without the
extension, hyphens replaced with underscores. `modules/core-wp.sh` → prefix
`core_wp_`. `modules/motopress.sh.example` → prefix `motopress_` (see §3).

## 3. The module contract

### 3.1 Principle

The tool's core knows **no** plugin by name. It only knows "modules" — files
`modules/<name>.sh` that declare, through functions with a conventioned prefix, what
they own. Adding support for a plugin tomorrow means adding one file, with zero
changes to `lib/` or `bin/`.

Every module serves **in both directions**:
- On side A (source): the module says what to migrate.
- On side B (target): the same module says what to protect — if detected on B and not
  selected for migration, everything it declares automatically moves to the
  "hands off" list.

### 3.2 Conventioned functions

For a module with prefix `<mod>` (e.g. `core_wp`, `etch`, `acss`, `motopress`):

| Function | Required | Signature | Role |
|----------|:--------:|-----------|------|
| `<mod>_name` | yes | `<mod>_name` → stdout: human-readable name | Name shown in `gum choose` prompts |
| `<mod>_detect` | yes | `<mod>_detect <scan_json_path>` → exit 0/1 | Is this plugin/domain present on the scanned site? |
| `<mod>_post_types` | no* | `<mod>_post_types` → stdout: one post_type per line | Post types owned by this module |
| `<mod>_option_keys` | no* | `<mod>_option_keys` → stdout: one `wp_options` key per line | Options owned by this module |
| `<mod>_option_keys_exclude` | no | `<mod>_option_keys_exclude` → stdout: one glob pattern per line | **NOT WIRED — see status note directly below.** Originally: exclusions within a broad prefix (e.g. licenses, DB versions). |
| `<mod>_tables` | no* | `<mod>_tables` → stdout: one table suffix per line (without `$table_prefix`) | Plugin-owned SQL tables, outside WXR content |
| `<mod>_post_import` | no | `<mod>_post_import <state_dir> <id_map_tsv> <wp_cmd_b>` | Hook run after WXR import + generic remaps, for module-specific fixups |
| `<mod>_stack_candidates` | no | `<mod>_stack_candidates` → stdout: one candidate plugin slug per line, most-preferred first | Declares this module's plugin for §12's stack-sync — **detection only**, see below and §3.4 |

\* At least ONE of the three functions `_post_types` / `_option_keys` / `_tables`
must exist — a module that declares nothing has no reason to exist.

> **v1 status (Step 6 self-review, review fix-pack, 2026-08-20):
> `<mod>_option_keys_exclude` is declared in the contract and implemented by
> `modules/etch.sh` (also shown in `modules/_template.sh`'s stub), but IS NOT
> READ ANYWHERE — no code in `lib/` or `bin/` ever calls
> `module_has_fn "$mod" option_keys_exclude` or consumes its output. It is
> currently inert. Harmless for `etch` specifically, because
> `etch_option_keys` is already a complete, explicit allowlist that never
> includes a license/DB-version key in the first place — there is nothing
> for the exclusion to actually do there. It would NOT be harmless for a
> future module that returns a broad prefix from `_option_keys` (e.g.
> `"my_plugin_*"` instead of an explicit list) while counting on
> `_option_keys_exclude` to carve license/secret keys back out — those keys
> would migrate anyway, silently. Until this is wired (or removed), every
> module's `_option_keys` MUST already be a complete, explicit allowlist —
> never rely on `_option_keys_exclude` for anything.** Deliberately left
> unimplemented rather than added in this fix-pack (no existing caller
> needs prefix expansion, and wiring a mechanism nothing uses is exactly the
> YAGNI this codebase otherwise avoids) — see `docs/todo.md` if this needs
> to change.

**`<mod>_post_import` and `--dry-run` (added in Step 6's dry-run audit, which
found and fixed a real violation of this in `modules/core-wp.sh`):**
`graft_run_module_post_import` (lib/graft.sh) calls every module's
`post_import` hook unconditionally, whether or not `--dry-run` was passed —
there is no separate "skip module hooks in dry-run" branch. A hook that
mutates B (via the `wp_cmd_b` prefix it's handed) MUST wrap every such call in
`lib/core.sh`'s `run_or_echo` — never invoke `$wp_cmd_b` directly for a
write. `run_or_echo` is already sourced by the time any module hook runs, so
this is zero extra work: `run_or_echo $wp_cmd_b option update key value`
instead of `$wp_cmd_b option update key value`. Read-only `$wp_cmd_b` calls
(e.g. `post list` to look something up) don't need wrapping. See
`modules/motopress.sh.example`'s `motopress_post_import` for a worked
example, and `modules/core-wp.sh`'s `core_wp_post_import` for the real fix.

`lib/modules.sh` discovers modules via the glob `modules/*.sh` (the `.example`
suffix is explicitly excluded, as is `_template.sh`), sources each file, and builds
`SITEGRAFT_MODULES` — a space-separated string of names (no associative array,
bash 3.2 constraint — see D1). Each optional function's presence is checked with
`type -t <mod>_xxx >/dev/null 2>&1` before being called.

**Rule — slugs and paths are never hardcoded to build a sync path, anywhere in
this tool.** `<mod>_stack_candidates` exists purely to help *detection*: a
plugin's folder name on disk can legitimately differ between installs (a
version upgrade renaming the directory, exactly the ACSS v4 case documented in
§3.4) — a module may know several candidate slugs, in preference order, for
recognizing "is this module's plugin here at all, and under which name." That
list is never itself used to construct an `rsync` source or destination path.
The **real, resolved** folder name — whichever candidate `scan` actually finds
present on that specific site — is what gets carried forward, first into
`inventory_stack_diff`'s output, then frozen into the manifest's `stack` key
(§4), and that manifest value, not the module's candidate list, is the only
thing `graft_sync_stack` (§12, §6.4 step 0a) is allowed to read when building a
path. A module's job is to say "these are the names this plugin might go by";
scan's job is to say which one is actually there; graft's job is to trust only
that second answer.

### 3.3 Concrete example — `modules/etch.sh`

```bash
#!/usr/bin/env bash
# modules/etch.sh — graft module for Etch (page builder)

etch_name() { echo "Etch"; }

etch_detect() {
  # $1 = path to a scan-*.json produced by `sitegraft scan`
  jq -e '.plugins[] | select(.name == "etch")' "$1" >/dev/null 2>&1
}

etch_post_types() {
  cat <<'EOF'
etch_cfs
etch_cpts
etch_loops
EOF
}

etch_option_keys() {
  cat <<'EOF'
etch_css_toolbar_values
etch_global_stylesheets
etch_settings
etch_styles
EOF
}

# NOT WIRED in v1 — see §3.2's status note. etch_option_keys above is
# already a complete explicit allowlist, so this is harmless here, but
# nothing in lib/ or bin/ ever reads this function's output.
etch_option_keys_exclude() {
  cat <<'EOF'
etch_license_*
etch_db_version
EOF
}
```

### 3.4 Concrete example — `modules/acss.sh` (multiple candidate slugs for detection)

ACSS is the worked example for `<mod>_stack_candidates` (§3.2) because it's a
real, already-hit case, not a hypothetical: **Automatic.css's plugin folder
changed with the v4 release** — a site still running a pre-4.0 install has ACSS
under a different directory name than a fresh v4+ install does. `acss_detect`
and `acss_stack_candidates` both need to recognize *either* name; only the one
actually found is ever used to build a path (§3.2's rule, enforced in §12/§6.4
step 0a — this module never constructs a sync path itself).

```bash
#!/usr/bin/env bash
# modules/acss.sh — graft module for Automatic.css (ACSS)

acss_name() { echo "Automatic.css"; }

acss_detect() {
  # $1 = path to a scan-*.json produced by `sitegraft scan`. True if ANY
  # candidate slug is present — detection never assumes which one.
  local candidate
  while IFS= read -r candidate; do
    jq -e --arg c "$candidate" '.plugins[] | select(.name == $c)' "$1" >/dev/null 2>&1 && return 0
  done <<< "$(acss_stack_candidates)"
  return 1
}

acss_option_keys() {
  cat <<'EOF'
automatic_css_settings
automatic_css_generated_inventory
EOF
}

# NOT WIRED in v1 — see §3.2's status note (not that it matters here: this
# whole module is unshipped, see the status note further below in this
# section).
acss_option_keys_exclude() {
  cat <<'EOF'
automatic_css_license_*
automatic_css_db_version
EOF
}

# §3.2/§12: detection-only. Most-preferred (current) slug first. graft_sync_stack
# never reads this function directly — it reads the specific slug scan already
# resolved and froze into the manifest (§4).
#
# TODO_VERIFY_LEGACY_ACSS_SLUG below is a deliberate placeholder, not a real
# value — the actual pre-4.0 Automatic.css plugin folder name is not known with
# certainty here and must be checked against a real pre-4.0 install before the
# acss module ships (plan Task 4.1). Do not guess a real-looking slug to fill
# this in without that verification.
acss_stack_candidates() {
  cat <<'EOF'
automatic-css
TODO_VERIFY_LEGACY_ACSS_SLUG
EOF
}
```

> **v1 status (Step 6 self-review, 2026-08-20): `modules/acss.sh` does NOT
> exist in the repo.** Only `modules/core-wp.sh` and `modules/etch.sh`
> (added in Step 6 — see that file's own header comment) are real, shipped
> v1 modules; `modules/motopress.sh.example` is the intentional
> never-loaded worked example (§3.5). Correctly so, not an oversight:
> `TODO_VERIFY_LEGACY_ACSS_SLUG` above is exactly the blocker this comment
> already names, and it's still open — nobody has checked a real pre-4.0
> Automatic.css install to confirm its actual legacy folder name. Shipping
> `modules/acss.sh` with a guessed value would violate this section's own
> instruction not to. `docs/definition-of-done.md`'s "3 v1 modules
> (core-wp, etch, acss)" line is corrected accordingly — see that file and
> `docs/todo.md` → Backlog for the up-to-date scope.

### 3.5 Example of a future module — `modules/motopress.sh.example`

Shipped as a full worked example (not a real v1 module — MotoPress support isn't
implemented). Copying this file to `modules/motopress.sh` (dropping the `.example`
suffix) and adapting it is the expected move for adding real MotoPress support later.

```bash
#!/usr/bin/env bash
# modules/motopress.sh.example — worked example: a hypothetical future module.
# Copy to modules/motopress.sh (drop the .example suffix) to activate it for real.
# MotoPress Hotel Booking is NOT implemented in v1 — this file exists purely to show
# the contract end-to-end, including a table and a post_import remap hook.

motopress_name() { echo "MotoPress Hotel Booking"; }

motopress_detect() {
  jq -e '.plugins[] | select(.slug == "motopress-hotel-booking")' "$1" >/dev/null 2>&1
}

motopress_post_types() {
  cat <<'EOF'
mphb_booking
mphb_room_type
mphb_rate
mphb_room
EOF
}

motopress_option_keys() {
  cat <<'EOF'
mphb_settings
EOF
}

motopress_tables() {
  # Suffixes only — sitegraft prefixes with the live $table_prefix of the site.
  cat <<'EOF'
mphb_room_type_meta
EOF
}

# Example post-import hook: not used for migration in v1 (MotoPress data always
# lands in the "protect" bucket, never in "migrate", for the case Marcel described —
# a live B with real bookings). Shown here purely to document the hook signature for
# a future module that DOES migrate a plugin's content.
motopress_post_import() {
  state_dir="$1"
  id_map_tsv="$2"
  wp_cmd_b="$3"
  # Example: if mphb_room_type posts had been migrated, remap a hypothetical
  # "related_room_id" postmeta pointing at another migrated post.
  while IFS=$'\t' read -r old_id new_id post_type; do
    [ "$post_type" = "mphb_room_type" ] || continue
    $wp_cmd_b post list --post_type=mphb_booking --meta_key=related_room_id \
      --meta_value="$old_id" --field=ID | while read -r booking_id; do
        $wp_cmd_b post meta update "$booking_id" related_room_id "$new_id"
    done
  done < "$id_map_tsv"
}
```

### 3.6 Safe default (default-deny)

During `plan`, after every known module has been checked against the scans of A and
B, anything left on B — post_type, table, or option key — unclaimed by any module
(migrate or protect) falls into an automatic `_unclaimed` bucket in the manifest,
marked protected. **Nothing is ever migrated or wiped by default.** An operator who
wants to migrate something not yet covered has to write a module for it (even a
minimal one) — that's deliberate friction, not an oversight.

**Tracked implementation gap, `_unclaimed.tables` (as of Step 2, `plan`):**
`manifest_compute_unclaimed` (`lib/manifest.sh`) currently enumerates unclaimed
`post_types` and `option_keys` against B's scan, but leaves `_unclaimed.tables`
`[]` — not a silent oversight, a deliberately deferred extension, for two
stacked reasons. First, module-declared tables are suffixes only
(`fakebooking_reservations`), while `scan-b.json`'s `.tables` holds the live,
prefixed names (`wp_fakebooking_reservations`) — matching them needs either a
live table-prefix lookup (a wp-cli round trip `plan` has never made; every
`plan_*` function works only from already-scanned JSON on disk, and this
section's own "writes only locally" has always implicitly meant reads too) or
an `endswith($suffix)` heuristic, which is resolvable without a live call.
Second, and the harder half endswith-matching doesn't solve: no `core-wp`
module exists yet (Step 4, Task 4.1) to claim WordPress's own tables
(`wp_posts`, `wp_options`, `wp_users`, ...) as core-handled — so naively
enumerating unclaimed tables today would flood the bucket with every core WP
table on B, mislabeled as "protected by default-deny" when graft's
content-migration path (WXR + `wp option`) touches several of them regardless
via a different mechanism entirely. That's not a bigger protected set, it's a
misleading one. **The safety property does not depend on this enumeration**:
`graft` (Step 4) must build its DB-table-copy step exclusively from
`protect.<module>.tables`/`migrate.<module>.tables` — an explicit allowlist
read from the manifest, never a live "whatever's on B" scan. `_unclaimed` is a
reporting/audit bucket, not itself the enforcement point; an incomplete
`tables` enumeration is a visibility gap, not a protection gap. Revisit once a
`core-wp` module exists and can exempt its own tables from the bucket.

## 4. Manifest format

Produced by `plan`, frozen, consumed as-is by `graft`. JSON, parsed via `jq`.

```jsonc
{
  "sitegraft_manifest_version": 1,
  "profile": "example",
  "created_at": "2026-08-19T10:00:00Z",
  "frozen": true,
  "site_a": { "url": "https://a.example.com", "alias": "a" },
  "site_b": { "url": "https://b.example.com", "alias": "b" },
  "migrate": {
    "core-wp": {
      "post_types": ["page", "post", "wp_block", "wp_navigation", "wp_template", "wp_template_part", "wp_global_styles"],
      "option_keys": ["show_on_front", "page_on_front", "page_for_posts"],
      "media": true
    },
    "etch": {
      "post_types": ["etch_cfs", "etch_cpts", "etch_loops"],
      "option_keys": ["etch_css_toolbar_values", "etch_global_stylesheets", "etch_settings", "etch_styles"]
    },
    "acss": {
      "option_keys": ["automatic_css_settings", "automatic_css_generated_inventory"]
    }
  },
  "protect": {
    "example-plugin": {
      "post_types": ["example_booking", "example_room_type"],
      "tables": ["example_room_type_meta"],
      "option_keys": ["example_plugin_settings"]
    },
    "_unclaimed": {
      "post_types": ["unknown_cpt_found_on_b"],
      "tables": [],
      "option_keys": [],
      "note": "found on B, unclaimed by any module — protected by default-deny"
    }
  },
  "clean": {
    "enabled": false,
    "post_types": []
  },
  "options": {
    "search_replace": { "from": "https://a.example.com", "to": "https://b.example.com" }
  },
  "stack": {
    "theme": { "slug_a": "etch-theme", "slug_b": null, "version_a": "1.0", "version_b": null, "resolution": "copy" },
    "etch": { "slug_a": "etch", "slug_b": null, "version_a": "2.0", "version_b": null, "resolution": "copy" },
    "acss": { "slug_a": "automatic-css", "slug_b": "acss-legacy-slug-placeholder", "version_a": "4.1", "version_b": "3.9", "resolution": "skip" }
  },
  "custom_code_review": {
    "acknowledged": true,
    "signals": {
      "child_theme": true,
      "functions_php": { "exists": true, "bytes": 4213, "lines": 187 },
      "mu_plugins": ["custom-redirects.php"],
      "snippet_plugins_detected": ["code-snippets"]
    }
  },
  "checksums_protected_pre_graft": {
    "example-plugin": "sha256:…"
  }
}
```

`stack` (§12) records `plan`'s resolution for each of the three tracked stack
components (theme, `etch`, `acss`) whenever A and B differ. **`slug_a`/`slug_b`
are the real, resolved plugin/theme folder names `scan` found present on each
site** — never a name the module declared as a detection candidate (§3.2), never
guessed, never hardcoded anywhere downstream. This is what the ACSS example
above shows: `slug_a` is `"automatic-css"` (A is a fresh v4+ build) while
`slug_b` is a different, legacy folder name (B predates the v4 rename) — same
module, two different real directory names, both resolved from what `scan`
actually found via each site's `plugin list`, not assumed to match. `slug_b:
null` means the component was entirely absent on B. `version_a`/`version_b`
are that resolved plugin's version at each site. `resolution` is `"copy"`
(operator confirmed — `graft` will `rsync` **exactly `slug_a`'s directory**
from A to B and activate it under that name) or `"skip"` (operator declined, or
the mismatch hasn't been resolved yet — `graft`'s hard precondition applies,
see §6.4 step 0b). A component absent from `stack` entirely means A and B
already matched (same slug, same version) at `plan` time — nothing to resolve.
`graft_sync_stack` (§6.4 step 0a) reads only `slug_a`/`resolution` from this
key — it never re-derives a slug from a module or from any hardcoded name.

`custom_code_review` (§14) is present only when `scan-b.json.custom_code_detected`
was `true` — its `acknowledged: true` is the only way `plan` ever freezes a
manifest for a B with any custom-code signal raised; `signals` is a frozen copy
of what `scan` found, kept for the record rather than re-read live at `graft` time.

Validation rules (`lib/manifest.sh :: manifest_validate`):
- `frozen` must be `true` for `graft` to accept the manifest.
- No post_type/table/option-key may appear in both `migrate` and `protect`
  (conflict → `plan` refuses to freeze).
- `checksums_protected_pre_graft` is computed and written by the `backup` phase (not
  by `plan`), and consumed by `verify`.

## 5. Profile + credentials format

### 5.1 Profile — `profiles/<name>.conf` (local-only and gitignored, zero secrets)

```sh
# profiles/example.conf — sitegraft profile template. No secrets here, but a
# real profile holds real hosts, paths and site URLs, so profiles/*.conf are
# gitignored and only this example is tracked. Copy it; never commit the copy.

SITE_A_ALIAS="a"
SITE_A_SSH_HOST="user@host-a.example.com"
SITE_A_WP_PATH="/var/www/site-a/htdocs"
SITE_A_WP_CMD="wp"                      # or "ddev exec --raw -p <project> -- wp" for a local DDEV site — see note below
SITE_A_URL="https://a.example.com"

SITE_B_ALIAS="b"
SITE_B_SSH_HOST="user@host-b.example.com"
SITE_B_WP_PATH="/var/www/site-b/htdocs"
SITE_B_WP_CMD="wp"
SITE_B_URL="https://b.example.com"

SITEGRAFT_STATE_DIR="${HOME}/.sitegraft/runs"
SITEGRAFT_CREDS_FILE="${HOME}/.config/sitegraft/example.creds"
```

**DDEV local sites — verified against a real install (v1.25.2) during Step 1
implementation, corrected from an earlier draft that assumed `SITE_*_WP_CMD="ddev
wp"`:** `ddev wp` is not a real command outside a project's own directory —
`wp` only exists as a project-scoped custom command DDEV resolves from the
current working directory, and `ddev --project <name> wp ...` is not valid
syntax at all (`ddev` has no such flag). The correct wrapper is
`ddev exec --raw -p <project> -- wp`, which runs from any directory. `--raw`
is required, not optional: without it, `ddev exec` reparses the command
through an inner shell before it reaches the container, which silently
mangles any PHP `$variable` inside a `wp eval` snippet (bash expands it to
empty before PHP ever sees it) — exactly what §14's custom-code-signal
detection relies on. Because this command runs *inside* the container,
`SITE_*_WP_PATH` must be the **container-internal** docroot (typically
`/var/www/html` for a DDEV project configured with `--docroot=.`), never the
orchestrator's host path — the host path doesn't exist inside the container,
and `wp --path=<host-path>` fails wp-cli's "is this a WordPress install?"
check.

An empty `SITE_*_SSH_HOST` means "local site, driven directly through
`SITE_*_WP_CMD` with no SSH" (the case of a local DDEV site on the orchestrator
itself).

### 5.2 Credentials — two paths

**(a) File** at `~/.config/sitegraft/<profile>.creds` (chmod 600, gitignored, never
committed) — **enforced, not just advisory**: `profile_load` refuses to read a
`.creds` file that is not mode 600 (verified live during the post-review
fix-pack that the old code never actually checked this):

```sh
SITE_A_SSH_KEY="/absolute/path/to/private_key_a"
SITE_B_SSH_KEY="/absolute/path/to/private_key_b"
```

**(b) Interactive prompt** at launch (`gum input --password` for sensitive values)
if the credentials file referenced by the profile doesn't exist — with an explicit
offer to save it ("save to `~/.config/sitegraft/example.creds` so you don't have to
re-enter it? [y/N]"), never automatic.

> **v1 status (Step 6 self-review, 2026-08-20): (b) is NOT implemented.**
> `profile_load` (a) parses the `.creds` file when present, exactly as
> documented, but when it's absent it only logs a warning and proceeds
> without `SITE_*_SSH_KEY` — never prompts. Deliberately left as a
> documented gap rather than added late in the polish pass (see
> `docs/status.md`/`docs/todo.md` → Backlog): not a broken state in
> practice, since a missing key just falls back to ssh's own default
> identity resolution (ssh-agent / `~/.ssh/config`), the common case working
> fine either way. An operator who needs a specific per-site key today
> creates `~/.config/sitegraft/<profile>.creds` by hand (chmod 600) — path
> (a), fully working.

`lib/profile.sh :: profile_load` **parses** the `.conf` file itself, line by line
(never `source`s/`.`s it — corrected during the post-review fix-pack: a
source-after-shape-check design was verified live to let both trailing shell
code and an embedded command substitution execute). Only an anchored
`KEY="value"` / `KEY='value'` line is accepted, and only for a key on a fixed
SITE_*/SITEGRAFT_* whitelist — no arbitrary code, ever. Then loads the matching
`.creds` file the same way if it exists — otherwise it warns and proceeds
without it, per the v1 status note above, rather than triggering (b).

## 6. Exact phase walkthrough

### 6.1 `scan` (read-only, A and B)

```sh
wp --path="$WP_PATH" post-type list --format=json
wp --path="$WP_PATH" option list --format=json          # full dump — filtered later per module
# `wp db tables` has no --format=json (only "list" or "csv", verified against a
# real wp-cli install) — request the default list and build the JSON array with jq.
wp --path="$WP_PATH" db tables --format=list --all-tables-with-prefix
wp --path="$WP_PATH" plugin list --format=json           # helps with module detection
```
```sh
wp --path="$WP_PATH" theme list --status=active --format=json
wp --path="$WP_PATH" menu list --format=json             # classic nav menus, see §13 — checked on both sites, only meaningful as a warning on A
```
Writes `scan-a.json` and `scan-b.json` to the state directory. Strictly read-only —
no writes to A or B. Freely re-runnable.

The Etch-specific check Marcel asked for (§0, point 11): `scan` checks whether
**A's** navigation is a dynamic `wp:page-list` block (no hardcoded IDs) by
inspecting the content of the `wp_navigation` posts it finds — never assumed, always
verified, result recorded in `scan-a.json` (`"nav_uses_dynamic_page_list":
true/false`). This is an A-only check by nature — B's navigation, whatever form it
takes, is either being replaced or is none of sitegraft's business (§13).

**Rendering stack (see §12):** `scan` also records each site's active theme
(`active_theme.stylesheet`/`.version`) and, via the existing `plugin list` dump,
every plugin's version — this raw `plugin list` output is a real per-site
directory listing (each plugin's `name` field *is* its actual folder name), so
it's also the only source `inventory_stack_diff` (§12) is ever allowed to
resolve a plugin's real slug from — never a hardcoded string, never a module's
own guess. This is what `plan` and `graft` use to detect a stack mismatch
between A and B, and (§12) to offer copying a missing component from A to B,
before any content is transferred. **This is not a check that B must already
resemble A** — quite the opposite; see §12 and §13 for why B running something
entirely different (Divi, Elementor, a classic theme) is the normal case this
check exists to handle gracefully, not to reject.

**Classic menus (see §13):** `scan` records, **for both sites**, whether any
classic nav menus exist with items assigned
(`"classic_menus_detected": true/false` plus the menu names) — but `plan` only
ever turns this into a warning **for A** ("A has N classic menu(s) with items —
sitegraft v1 does not migrate classic menu assignments"). B having classic menus
triggers no warning: it is B's own, pre-existing navigation, not a defect.

**Custom code on B (see §14):** `scan` also collects a small set of heuristic
signals — **on B only**, deliberately shallow (no code parsing, no static
analysis — YAGNI):

```sh
wp --path="$SITE_B_WP_PATH" theme get --field=template "$(wp theme list --status=active --field=name)"
wp --path="$SITE_B_WP_PATH" eval 'if (file_exists($f = get_stylesheet_directory()."/functions.php")) { echo json_encode(["exists"=>true,"bytes"=>filesize($f),"lines"=>count(file($f))]); } else { echo json_encode(["exists"=>false]); }'
wp --path="$SITE_B_WP_PATH" eval 'echo json_encode(array_map("basename", glob(WP_CONTENT_DIR."/mu-plugins/*.php") ?: []));'
```

recorded in `scan-b.json` as:

```jsonc
"custom_code_signals": {
  "child_theme": true,
  "functions_php": { "exists": true, "bytes": 4213, "lines": 187 },
  "mu_plugins": ["custom-redirects.php"],
  "snippet_plugins_detected": ["code-snippets"]
},
"custom_code_detected": true
```

`child_theme` is `true` when the active theme's `template` differs from its own
`name` (WordPress's own definition of a child theme). `snippet_plugins_detected`
cross-references the existing `plugin list` dump, filtered to `status=active`
(an installed-but-inactive snippet plugin injects nothing at runtime), against
a short, deliberately extensible list of known snippet-manager slugs
(`code-snippets`, `wpcode`, `insert-headers-and-footers`, …) — add to the list
as new ones come up, don't build a general plugin classifier. `custom_code_detected`
is `true` iff any of the four signals is non-empty/`true` — the single boolean
`plan`'s gate (§14) checks. None of this is checked on A — A is a fresh Etch
build; this signal set exists specifically to catch what B might be quietly
running.

**Fail closed, never fail open (post-review hardening, verified live):** a
signal this cannot actually determine (a wp-cli query on B errors) is
recorded by name in a `unknown_signals` array, never silently guessed as
"absent" — `custom_code_detected` treats any `unknown_signals` entry the
same as a positive signal. A blocking gate must not pass through on a check
it could not verify.

### 6.2 `plan` (interactive, writes only locally)

1. Loads `scan-a.json` / `scan-b.json`.
2. For each discovered module, calls `<mod>_detect` against both scans.
3. Builds the defaults: modules detected on A with Etch/ACSS content → pre-checked
   on the migration side; modules detected on B and absent from the migration
   selection → pre-checked on the protection side.
4. **Custom-code awareness gate (§14) — blocking, not a warning:** if
   `scan-b.json.custom_code_detected` is `true`, `plan` stops here and requires
   an explicit typed/`gum confirm` acknowledgment — the exact same weight as
   `--allow-stack-mismatch`'s override, not a message that scrolls past:
   *"Did you review B's theme for custom code (functions.php, code snippets,
   mu-plugins) before replacing the theme? Custom code living in the old theme
   will be LOST."* Declining means `plan` **exits without writing a manifest at
   all** — nothing built in steps 1-3 above is kept; there is nothing to resume
   until the operator re-runs `plan` ready to acknowledge. Accepting records
   `manifest.custom_code_review = {"acknowledged": true, "signals": {...}}` (a
   copy of `scan-b.json.custom_code_signals`, for the record). No signals
   raised → this step is invisible, nothing to acknowledge. Runs before any
   further step below, since none of them should matter until this is settled.
5. **Stack resolution (§12) — for each of `theme`/`etch`/`acss` where A and B
   differ:**
   - **Absent on B:** "`etch` is on A (v2.0) but not on B — copy it from A and
     activate it on B? [y/N]" (`gum confirm`, plain wording, defaults to the
     common case). Accepted → `stack.<component> = {..., "resolution": "copy"}`.
   - **Present on B, different version:** a **louder** warning first ("B already
     has `acss` v2.5 installed — A has v3.0. Copying A's version will **replace**
     B's existing install."), then a **separate** confirm before the same copy
     is offered — never the same single keystroke as the absent case. Declined
     or accepted, same as above, into `stack.<component>.resolution`.
   - **Declined (either case):** `stack.<component> = {..., "resolution": "skip"}`
     — `graft`'s hard precondition (§6.4 step 0b) will apply to it.
   - Matching components are simply omitted from `stack` — nothing to resolve.
6. `gum choose --no-limit` (fallback `fzf`, fallback a numbered list + text prompt)
   to fine-tune the migrate/protect selection (individual post_types and
   option_keys).
7. Validates (no migrate/protect conflict, see §4), computes the `_unclaimed` bucket
   automatically, writes `manifest.json` with `"frozen": false`.
8. Explicit confirmation (`gum confirm "Freeze this manifest?"`) → `"frozen": true`.

### 6.3 `backup` (writes only to the orchestrator's state dir — B not deeply touched yet)

```sh
# on B:
ssh "$SITE_B_SSH_HOST" "wp --path=$SITE_B_WP_PATH db export - --add-drop-table | gzip" \
  > "$STATE_DIR/backup/b-db.sql.gz"
ssh "$SITE_B_SSH_HOST" "tar czf - -C $(dirname "$SITE_B_WP_PATH") wp-content" \
  > "$STATE_DIR/backup/b-wp-content.tar.gz"
```
Then generates `$STATE_DIR/restore.sh` — a self-contained script that hardcodes
(inside the run, not the repo) the backup path and the same wp-cli/rsync commands in
reverse, ready to run with no other context needed. **Self-contained means literal:**
`restore.sh` bakes in the resolved ssh/rsync/wp-cli command lines at generation time
and never calls back into a sitegraft bash function — a script that shells out to
`wp_remote` (or any other sitegraft helper) would fail the moment it's copied
anywhere without a sitegraft checkout, which defeats the point of a standalone
rollback script. Also computes `checksums_protected_pre_graft` (sha256 of the
protected tables/options exports) and writes them into `manifest.json`. Marks
`$STATE_DIR/backup.complete` — `graft` refuses to start without this marker.

**Checksum normalization (applies everywhere a protected-data checksum is taken —
`backup`, `verify`, and the DDEV harness use the exact same normalization):**
`wp db export` shells out to `mysqldump`, whose output embeds a
`-- Dump completed on …` timestamp comment (and similar `-- ` comment lines). Two
exports of byte-identical data taken seconds apart will hash differently if the raw
dump is hashed directly. Every checksum in this tool is therefore computed over the
dump with all lines starting with `-- ` stripped first — a single shared function,
never three different implementations, so the three call sites can never drift.

### 6.4 `graft`

0a. **Stack sync (see §12):** for every `stack.<component>` in the manifest with
    `"resolution": "copy"`, `rsync` that component's plugin/theme directory
    A → orchestrator (into the run dir) → B — the same two-hop routing as every
    other transfer, never `scp`, never a direct A↔B connection — then
    `wp plugin activate <slug>` or `wp theme activate <stylesheet>` on B. Marker-
    gated like every other step. This is the **only** place `graft` ever writes
    to B's `wp-content/themes/` or `wp-content/plugins/`, and it only ever
    copies from A — never downloads from wp.org or any other external source.
0b. **Precondition — remaining stack mismatches (see §12):** after 0a, refuses to
    continue if A's and B's active theme or Etch/ACSS versions still differ (i.e.
    components the manifest recorded as `"resolution": "skip"`, or a new
    mismatch `plan` never saw because B changed since) — unless launched with the
    explicit `--allow-stack-mismatch` override, which still requires a loud,
    hard-to-miss confirmation before continuing. This runs before step 1, so a
    mismatch is caught before anything is touched.
1. **Media**: `rsync -avz --ignore-existing` of `wp-content/uploads/` A → B (never
   overwriting a file already present on B — protects media already used by the
   protected plugin in case of a filename collision). **Routed through the
   orchestrator, not A→B directly** — exactly like the WXR transfer in step 5: A is
   never assumed to be reachable from B (or vice versa), only from the
   orchestrator. Media is pulled A → orchestrator (into the run directory) and then
   pushed orchestrator → B.
2. **Mu-plugin**: drop `mu-plugins/sitegraft-id-mapper.php` onto B via `rsync`.
3. **WXR export on A**, filtered to the manifest's post_types:
   ```sh
   wp --path="$SITE_A_WP_PATH" export --post_type=page,post,etch_cfs,... --dir=/tmp/sitegraft-export/
   ```
4. **Integrity gate** (before any transfer) on every `.xml` file produced: size > 0,
   `<wp:wxr_version>` present, ≥ 1 `<item>`, and **every** `<wp:post_type>` found in
   the file ∈ the manifest's `post_types` list — abort otherwise (protects against a
   wp-cli export that includes more than requested).
5. **Transfer** the WXR A → orchestrator → B via `rsync` (two hops, never assuming a
   direct A↔B connection).
6. **`wordpress-importer`** installed + activated on B if absent (pre-existing state
   noted so it can be restored exactly after the import).
7. **Import**:
   ```sh
   wp --path="$SITE_B_WP_PATH" import /tmp/sitegraft-import/*.xml --authors=skip
   ```
   Never `--fetch_attachments` — media is already in place (step 1), and
   `wordpress-importer`'s default behavior without that flag doesn't re-download
   anything; it expects the file to already exist at the right path (see §9 for the
   important detail of this behavior).
8. **Options**: `wp option get --format=json` on A for every `option_keys` in the
   manifest, `wp option update --format=json` on B (except `page_on_front` — see
   §9.3).
9. **Retrieving the mapping log** (`wp-content/sitegraft-id-map.log` on B) →
   `$STATE_DIR/id-map.tsv` via `rsync`.
10. **Removing the mu-plugin** from B, deactivating/uninstalling
    `wordpress-importer` if sitegraft installed it itself.
11. **Remaps** — see §9 for details.
12. **Optional `clean`** (§6.6) if `manifest.clean.enabled = true`.

Each sub-step drops a marker `$STATE_DIR/graft.step<N>.done` — an interrupted
`graft` resumes at the sub-step after the last marker, never from scratch.

### 6.5 `verify` (read-only on B)

- Recounts migrated post_types (A before vs. B after, expecting consistency).
- Recomputes checksums of protected data (same normalization as `backup`, see §6.3),
  compares against `manifest.checksums_protected_pre_graft` — **any mismatch is a
  hard failure**.
- Spot-checks that migrated options carry the exact values fetched from A (e.g. the
  option file written during `graft`'s options step vs. B's live value) — catches a
  silently-skipped or partially-applied options migration.
- Verifies that B's `show_on_front`/`page_on_front` resolves to an existing page
  (and, when `page_on_front` was remapped, that it resolves to the **correct**
  remapped page, not merely *some* existing page).
- Verifies A's domain string is **absent** from B's imported content (posts,
  postmeta, options) — catches an incomplete or broken domain search-replace.
- Verifies the expected navigation is present.
- Verifies (best-effort, `curl -sS -o /dev/null -w '%{http_code}'`) that B's root
  URL returns 200.
- **Lists every stack component `graft` copied from A** (§12, from
  `manifest.stack.*.resolution == "copy"`) as an explicit reminder: *"Etch was
  copied from A and activated on B — it is unlicensed. Re-license it on B before
  going live."* Not a check that can pass or fail (licensing isn't something
  sitegraft can verify), just a reminder that would otherwise be easy to forget
  once the run reports success.
- Writes `$STATE_DIR/verify-report.md`, exits non-zero on a hard failure.

### 6.6 `clean` (an optional sub-step of `graft`, never run on its own)

Removes on B the **migrated** content types that already existed as B's "old design
layer" before the graft (never the protected types). Requires `backup.complete`.
Only acts on the post_types listed in `manifest.clean.post_types` (an explicit
subset of `migrate`, never inferred automatically).

### 6.7 `restore`

```sh
sitegraft restore --profile <profile> --run <run-id> [--yes] [--dry-run]
```
Runs `$STATE_DIR/restore.sh` for the designated run. Before restoring anything, it
takes a mini-backup of B's current state ("a backup of the backup") — both
database AND wp-content, since restore.sh's own wp-content step is exactly as
destructive to files as the db import is to data — into a `pre-restore-<timestamp>/`
subfolder of the same run. Asks for confirmation (`gum confirm`) unless `--yes` is
passed.

**"Even a restore has to stay reversible" is itself turnkey, not merely data-only:**
the pre-restore snapshot gets its own generated `restore.sh` (reusing
`backup_generate_restore_script`, pointed at the snapshot folder instead of the
run's own `backup/`) — a `pre-restore-<timestamp>/restore.sh` an operator can run
directly to roll B back to its state right before the restore attempt, rather than
having to hand-reconstruct the right ssh/rsync/wp-cli commands under pressure.

**Exact-state scope, amended in the Step 3 fix-pack review (Viktor/Kimi):**
"restores B to the exact pre-graft state" is only fully guaranteed for an
**ssh-remote or genuinely local (unwrapped)** B — both branches use `rsync
--delete`, so a file added to `wp-content` after the backup is genuinely removed on
restore. A **wrapped-local B** (a container-exec wrapper like DDEV — used in
practice only by this project's own test harness, never a documented real-world
profile shape beyond that) is **overwrite-only**: `backup_generate_restore_script`
deliberately never attempts `rm -rf wp-content` on that path, because a
Mutagen-style bind/sync mount can make the directory itself un-removable ("Device
or resource busy", reproduced live) — restoring there overwrites every file the
backup contains with its pre-graft version, but does not delete a file added since.
This is a real, documented trade-off, not an oversight; the DDEV harness proves the
deletion guarantee separately, directly against the bare-local (unwrapped) code
path, rather than resting on a DDEV-only round-trip that can never exercise it.

## 7. The mapping mu-plugin — `mu-plugins/sitegraft-id-mapper.php`

```php
<?php
/**
 * Plugin Name: sitegraft ID Mapper (temporary)
 * Description: Logs old->new post/term ID pairs during a sitegraft WXR import.
 * Installed and removed automatically by `sitegraft graft` — do not install by hand.
 */

add_action( 'wp_import_insert_post', function ( $post_id, $original_post_id, $postdata, $post ) {
    $log = WP_CONTENT_DIR . '/sitegraft-id-map.log';
    $post_type = isset( $postdata['post_type'] ) ? $postdata['post_type'] : 'unknown';
    file_put_contents( $log, "{$original_post_id}\t{$post_id}\t{$post_type}\n", FILE_APPEND | LOCK_EX );
    update_post_meta( $post_id, '_sitegraft_source_id', $original_post_id ); // for idempotence, see §11
}, 10, 4 );

add_action( 'wp_import_insert_term', function ( $term_id, $term, $original_id ) {
    $log = WP_CONTENT_DIR . '/sitegraft-id-map.log';
    file_put_contents( $log, "{$original_id}\t{$term_id}\tterm:{$term}\n", FILE_APPEND | LOCK_EX );
}, 10, 3 );
```

Log format (`id-map.tsv` after retrieval): `old_id<TAB>new_id<TAB>post_type`, one
line per imported post/term. This is the single source of truth for every
post-import ID remap.

## 8. `wp import`'s default behavior around media (important)

`wordpress-importer` **does not re-download** attached files by default — the
`--fetch_attachments` flag is required for that, and sitegraft never passes it.
Without that flag, the import creates `attachment` posts and their metadata
assuming the file already exists at the computed path
(`wp-content/uploads/YYYY/MM/file.ext`). This is exactly why the order is: **media
first** (rsync, step 1 of `graft`), **WXR import second** (step 7). If the order
were reversed, the import would leave attachments with a missing file.

> **v1 status (Step 6 self-review, 2026-08-20): the mechanism above is no longer
> how attachments actually get onto B, though the media-before-content ORDERING
> is still correct.** `lib/graft.sh`'s `graft_import_attachments` (header comment
> has the full history) found that the shipped `wordpress-importer` 0.9.5's
> `process_attachment()` unconditionally requires `--fetch_attachments=true` and
> does a real remote HTTP fetch — there is no "assume the file is already there"
> path to rely on at all, contrary to what this section assumed. Attachments are
> instead migrated entirely OUTSIDE the WXR path: `wp media import --skip-copy`
> against the files `graft_media_sync` already placed on B, run as its own step
> BEFORE the WXR import (which is itself given `--skip=attachment`, per
> `graft_export_wxr`, so wordpress-importer never touches attachment posts at
> all). The media-first ordering this section argues for is still exactly right —
> just via a different mechanism than described above.

## 9. Post-import remapping strategy

### 9.1 Doubly-embedded image ID references (Etch content)

Etch embeds an image reference two ways in the same block: the `"id":X` attribute
(JSON inside `post_content`) AND an absolute URL (`<img src="https://…">`). The
domain is handled separately (§9.4). The ID must be remapped precisely, with no
collisions.

**Two-pass sentinel technique** — to eliminate any risk that a new ID already
substituted gets re-matched by an old ID processed later in the same batch.

> ⚠️ **SUPERSEDED — do not implement the `wp search-replace --tables=...` shape
> this subsection originally showed. Kept here (Step 6 self-review,
> 2026-08-20) ONLY as a paragraph description of what NOT to do, with the
> actual dangerous command removed, specifically so it can't be copy-pasted.**
> The original sample scoped both passes with `--tables=` to
> `{$prefix}posts,{$prefix}postmeta,{$prefix}options`, reasoning that this was
> "deliberate and non-negotiable" scoping. It was wrong: `wp search-replace`
> has no ROW-level scoping — `--tables=` only narrows which tables it scans,
> and within a scoped table it still touches every row, including a protected
> plugin's own `wp_options`/`wp_postmeta` rows if that plugin happens to share
> those tables (nearly always true — `wp_options` is one shared table for the
> whole site). This is exactly the MAJOR-2 bug a pre-Step-6 security-review
> fix-pack found and fixed live: a protected plugin's own `wp_options` row
> carrying a colliding `"id":<N>` payload got silently rewritten by this exact
> shape of command. Reimplementing this subsection literally would reintroduce
> that real data-corruption bug.
>
> **What's actually shipped:** the real two-pass sentinel substitution
> (`old_id -> sentinel -> new_id`, same ordering guarantee) is applied by
> `graft_remap_attachment_ids` in `lib/graft.sh`, via PHP `preg_replace` in
> `lib/php/content-remap-functions.php`'s `sitegraft_remap_attachment_refs` —
> never `wp search-replace`, and never scoped by TABLE at all. Instead it is
> scoped by ROW, explicitly: it fetches and rewrites ONLY `post_content` and
> `post_excerpt` of the exact set of `post_id`s this specific run imported
> (from `id-map.tsv`) — nothing else in `wp_posts`, and neither `wp_postmeta`
> nor `wp_options` are touched by this function at all (see the "known
> consequence" note below for why not, and where those two are actually
> handled instead). Read `graft_remap_attachment_ids`'s own header comment in
> `lib/graft.sh` for the full mechanism, including why the payload is pushed
> as a file rather than embedded in the `wp eval` source.
>
> **Known, real, narrower-than-this-subsection's-original-claim consequence:**
> `wp_postmeta` can hold serialized PHP, which needs WordPress's own
> `maybe_unserialize()`/`maybe_serialize()` round-trip to touch safely — out
> of scope for this generic remap, same position as §11's "a CPT-specific meta
> reference is the relevant module's `post_import` hook's job." An
> attachment-ID reference living in `wp_postmeta` (not `post_content`/
> `post_excerpt`) is therefore never remapped by this generic pass — accepted
> as the safer trade-off, not fixed in Step 6. (`_thumbnail_id`, the one
> universal postmeta-stored attachment reference every post_type can carry, IS
> handled — by its own dedicated, narrowly-targeted function,
> `graft_remap_featured_images` in `lib/graft.sh`, not by this one.)

The sentinel tokens guarantee that no pass-2 substitution can ever be re-matched by
a pass-1 rule still waiting to run (impossible, since the two passes are strictly
sequential and disjoint by construction) — this guarantee itself still holds
exactly as described; only the vehicle (PHP `preg_replace` over an explicit
row set, not `wp search-replace --tables=`) changed.

### 9.2 `post_parent`

`wordpress-importer` already natively remaps `post_parent` (and the featured-image
thumbnail) internally during import, via its own correspondence table built during
the run — **provided the parent post is included in the same import** (see §11,
"deep page hierarchies"). `verify` checks that no `post_parent` on B points to an ID
that doesn't exist on B (an orphan); if an orphan is found, an explicit remap via
`id-map.tsv` is offered as a manual fix (not automatic — this case signals a
manifest selection mistake).

### 9.3 `page_on_front` / `show_on_front`

`page_on_front` on A holds **A's** page ID. A plain `wp option update` would copy
that ID as-is onto B — wrong. Handled as a dedicated remap in
`core_wp_post_import` (the `core-wp` module's hook, not a generic core case):

```sh
core_wp_post_import() {
  state_dir="$1"; id_map_tsv="$2"; wp_cmd_b="$3"
  old_front_id=$(cat "$state_dir/option-page_on_front.value" 2>/dev/null || echo "")
  [ -n "$old_front_id" ] || return 0
  new_front_id=$(awk -F'\t' -v old="$old_front_id" '$1==old{print $2}' "$id_map_tsv")
  [ -n "$new_front_id" ] && $wp_cmd_b option update page_on_front "$new_front_id"
}
```

### 9.4 Domain search-replace, A→B

Two mandatory passes (a plain variant and a JSON-escaped variant, since Etch stores
some data as JSON blobs in certain options/postmeta) — A's domain string must be
scrubbed from every field it could appear in, in migrated content.

> ⚠️ **SUPERSEDED — same correction as §9.1's own status note, same reason the
> dangerous sample itself has been removed rather than merely annotated (Step 6
> self-review, 2026-08-20).** This subsection originally showed
> `wp --path="$SITE_B_WP_PATH" search-replace 'https://a.example.com'
> 'https://b.example.com' --tables="$CONTENT_TABLES" --skip-columns=guid
> --precise` (plus its JSON-escaped variant), reasoning that `--tables=`
> scoping made it safe. It is the identical MAJOR-2 mistake as §9.1's original
> sample: `--tables=` only narrows which TABLES are scanned, not which ROWS
> within them, so a protected plugin's own `wp_options`/`wp_postmeta` row is
> still directly in scope. Do not implement this shape.
>
> **What's actually shipped:** `graft_search_replace_domain` (`lib/graft.sh`)
> uses the same run-scoped fetch/`preg_replace`/write-back technique as §9.1 —
> `sitegraft_remap_domain` in `lib/php/content-remap-functions.php`, applied
> only to `post_content`/`post_excerpt` of the exact posts this run imported.
> A domain string living in a migrated `wp_options` value is handled
> separately and safely, inside `graft_migrate_options` (`lib/graft.sh`),
> scoped to exactly the manifest's explicit `option_keys` — never a blind
> table-wide pass over `wp_options`.

`--skip-columns=guid` (still a real, correct principle even though the sample
above showing it is gone): WordPress's `guid` isn't supposed to change after
creation — let wp-cli/the import handle its value natively instead of
rewriting it by hand. The shipped implementation honors this by construction
(it never touches `guid` at all — only `post_content`/`post_excerpt`), not via
an explicit flag.

## 10. DDEV test harness

`tests/integration/ddev-harness.sh` is **built incrementally, not as a single
monolithic script written at the end.** A minimal skeleton (spin up two disposable
sites, seed the fixtures below, tear down) ships with the plan's very first step,
so every later phase gets real integration feedback the moment it's implemented
instead of meeting a real WordPress install for the first time at the very end.
The harness's assertions grow phase by phase:

- After `scan` lands: the fixtures seeded on A and B are visible in the resulting
  `scan-*.json` (post_types, options, active theme, and — see §13 — no false
  positive on classic menus for A's fixture).
- After `backup` lands: the backup files exist (`b-db.sql.gz`, the `b-wp-content/`
  tree) and re-hashing them immediately produces the same checksum (normalization
  in §6.3 is stable, not merely "usually the same").
- After `graft` lands: the full set of assertions below.

Orchestration:

1. `ddev config` + `ddev start` for two disposable projects (site "A" and site "B"),
   WP core installed via `wp core install`.
2. **Seed A** (`fixtures/site-a-seed.sh`): a throwaway mu-plugin registers the
   `etch_cfs`/`etch_cpts`/`etch_loops` CPTs (needed so `wp export`'s
   `--post_type=` recognizes them), then seeds fake content (`wp post create`) and
   fake options (`wp option update etch_settings '...' --format=json`) — **with no
   real Etch license**, only the shape of the data (CPTs + options), which is
   enough to test the migration mechanics.
3. **Seed B** (`fixtures/site-b-fake-plugin/fake-plugin.php`): a fake plugin
   dropped onto B as an mu-plugin, registering a `fakebooking_reservation` CPT,
   creating a `{$prefix}fakebooking_reservations` table via `dbDelta`, seeding a
   few rows plus a `fakebooking_settings` option.
4. Snapshots checksums of B's protected data (before any sitegraft run).
5. Full run: `sitegraft scan/plan/backup/graft/verify --profile ddev-test`
   (the interactive `plan` step is driven non-interactively via a pre-filled
   manifest passed as an argument, to automate the test).
6. **Central assertion**: recompute checksums of B's protected data, compare
   byte-for-byte against step 4's snapshot.
7. **Positive assertions** — a passing run must also prove the migration actually
   did its job, not merely that it left protected data alone:
   - A's migrated content (e.g. the seeded `etch_cfs` post) is present and
     rendered on B.
   - A's migrated options are present on B with the **exact values** seeded on A
     (e.g. `etch_settings`), not merely "some value."
   - `page_on_front` on B, if remapped, resolves to the correct migrated page (not
     just *any* existing page).
   - A's domain string is **absent** from B's imported content.
8. `sitegraft restore`, then another comparison: B returns exactly to its
   pre-graft state (both the design layer and the protected data).
9. Teardown `trap`: `ddev delete -O` on both projects, whether the run succeeded or
   failed — nothing persistent should survive a test run.

## 11. Edge cases

| Case | sitegraft behavior |
|------|---------------------|
| A CPT with an internal ID reference in postmeta (e.g. "related product") | Outside the core's generic remap — that's the job of the relevant module's `<mod>_post_import` hook (full example in §3.5). |
| Slug collisions between B's existing content and the imported content | Handled natively by WordPress (automatic `-2` suffix on insert) — that part is real and safe. **v1 status (Step 6 self-review, 2026-08-20): the `verify`-side warning described here (diffing `post_name` A vs. post-import B) was never implemented — `lib/verify.sh` has no such check.** Not a safety gap (WordPress's own renaming is enough to prevent corruption/collision), but it is a real, not-yet-built piece of this row's original claim — an operator gets no automatic heads-up to go check internal links after a slug rename. Left as a documented `docs/todo.md` backlog item rather than added late in Step 6: it would need a new cross-site read (A's pre-migration `post_name`, which nothing in `verify` currently fetches — every existing `verify` check is B-only, see that file's own header comment), not a small addition. |
| `page_on_front` / `show_on_front` | Dedicated remap via `core_wp_post_import`, see §9.3. |
| Deep page hierarchies | Selection is per-post_type, never per-individual-post (`plan`'s item-level toggle operates on a whole module's `post_types`/`option_keys` lists — see `lib/plan.sh`'s `_plan_apply_selection`), and the WXR export for a selected post_type pulls every post of that type via `wp export --post_type=`. A "partial hierarchy" (some but not all ancestors selected) is therefore impossible **by construction** — there was never a need for `plan` to run a separate explicit ancestor-validation step, and none exists in the shipped code. This section originally implied a validation step; the invariant it was protecting is real and does hold, just via a simpler mechanism (whole-post_type, all-or-nothing migration) than "validates ALL potential ancestors are selected too" suggests. |
| Idempotent reimport | Every post imported by sitegraft carries `_sitegraft_source_id` (set by the mu-plugin, §7). Before any import, `graft` lists and deletes (`wp post delete --force`) any post of the selected post_types carrying this meta from a previous run — a rerun never duplicates content. Distinct from the `clean` step (which removes B's **original pre-existing** content, not content sitegraft placed itself). |

## 12. Design-layer stack precondition (product decision)

sitegraft migrates *content, options, and media*. The *rendering stack* those
things depend on (the active theme, Etch, ACSS) is a different kind of thing —
code, not content — and B needing it is not an edge case: **the single most common
real invocation of sitegraft is a B that runs an entirely different stack from A**
(a legacy Divi, Elementor, or Bricks site, or a classic theme with none of Etch/
ACSS installed at all — see §13, this is the normal case B2 describes, not a
failure mode). If B doesn't end up running the same stack as A, the grafted
content has nothing to render it: the run would "succeed" by every content-level
measure while producing a visually broken site.

**Decision: sitegraft never installs anything from an external source — it only
replicates what already exists on A.** There is a real difference between those
two things. "Installing a stack" could mean downloading a theme from wp.org or a
plugin marketplace, activating a license, resolving a version sitegraft has never
seen — real, riskier automation that has no place quietly happening inside
`graft`. "Replicating from A" means copying files sitegraft can already read,
onto a site it already has write access to, because the operator explicitly asked
for exactly that pairing (A → B) in the profile. sitegraft does the second thing,
opt-in, never the first.

Concretely:

- `scan` records each site's active theme (`stylesheet`/`version`) and every
  plugin's version (already dumped via `plugin list`) — see §6.1. **No slug or
  path is ever hardcoded to interpret this data.** A module may declare several
  candidate slugs for *detecting* its plugin (`<mod>_stack_candidates`, §3.2 —
  ACSS's real-world case, §3.4: the plugin folder changed with the v4 release,
  so a pre-4.0 B and a v4+ A have the *same* module but *different* real
  directory names); whichever candidate is actually found in a site's own
  `plugin list` is that site's resolved slug, and only that resolved value ever
  travels further downstream.
- For each stack component (active theme, Etch, ACSS) where A and B's resolved
  slug or version differ, `plan` resolves it interactively into the manifest's
  new `stack` key (§4) — `slug_a`/`slug_b` are frozen in at this point, exactly
  as `scan` found them, one resolution per component for the rest of the run.
  See §6.2 for the exact flow:
  - **Absent on B:** offers to copy it — `rsync` **`slug_a`'s specific
    directory** (`wp-content/themes/<slug_a>/` or `wp-content/plugins/<slug_a>/`)
    A → orchestrator → B (never `scp`, never A↔B directly — the same two-hop
    routing as every other transfer in this tool, and never the whole
    `themes/`/`plugins/` tree), then `wp plugin activate` / `wp theme activate`
    that same slug on B. A plain confirm; this is the common case (§13).
  - **Present on B but under a different slug or version:** **warns loudly**
    (naming both resolved slugs/versions explicitly, e.g. "B has ACSS under
    `slug_b`, A has it under `slug_a`") and requires an **explicit, separate
    confirmation** before offering the same copy — this leaves B's existing
    folder in place (never deleted or renamed automatically, out of scope for
    v1) and adds A's folder alongside it, activating the new one; a heavier
    decision than filling a plain absence, never done automatically or by the
    same quick keystroke.
  - **Declined either way:** the component stays an unresolved mismatch — see
    below, unchanged from the original decision.
  - Whatever the operator decides is recorded in the manifest, not re-asked at
    `graft` time.
- `graft`'s stack-sync step (§6.4 step 0a, `graft_sync_stack`) executes every
  `stack.<component>` decision recorded as `copy`, reading only `slug_a` and
  `resolution` from the manifest — this is the only place sitegraft ever writes
  to B's `wp-content/themes/` or `wp-content/plugins/`, and it never
  re-resolves, guesses, or falls back to a hardcoded name of its own.
- Any component **left unresolved** (declined, or newly detected at `graft` time
  because `scan`/`plan` are re-runnable and B may have changed) is still a **hard
  precondition failure** (§6.4 step 0b) — `graft` refuses to run unless launched
  with `--allow-stack-mismatch`, and even then only after a loud, unmissable
  confirmation distinct from the quiet `gum confirm` used elsewhere.

**Guardrail — licensing is never touched, and this is a structural fact, not a
policy choice sitegraft has to remember to honor.** The copy step `rsync`s a
plugin or theme's *code directory* only. It never touches `wp_options` (that's a
database table, categorically outside the scope of an `rsync` of a filesystem
directory), and license keys for premium plugins are stored as options, not as
files inside the plugin folder, in every case this tool has to deal with (Etch,
ACSS). Combined with the pre-existing module-level exclusions (`etch_license_*`,
`*_db_version`, etc. — §3.3 — never in any module's migrated `option_keys` to
begin with), **a copied Etch/ACSS on B always comes up unlicensed.** This is not
a gap to fix: re-licensing B is a deliberate manual step, done by a human, after
the graft — `verify`'s report explicitly lists every stack component sitegraft
copied, as a reminder that this step is still outstanding.

This remains a scope boundary on the *installation* half of the problem, not an
oversight: sitegraft will never reach out to wp.org, a marketplace, or any URL
that isn't A itself. If a future version ever wants that, it should be its own
deliberately-scoped module, not a silent addition to `graft`.

## 13. Navigation scope: block themes only on A (source) in v1

**Read this section carefully if you're evaluating sitegraft from the Etch
community: this is a statement about site A only. It says nothing about what B
has to be.**

§0 point 11 and §6.1's navigation check cover block-theme navigation exclusively —
dynamic `wp:page-list` blocks and `wp_navigation` posts — **and this applies only
to A, the Etch build being migrated from.** sitegraft's whole premise requires A
to be a block-theme/FSE Etch site; that part was never in question.

**B is a completely different story, and this is the important part: B running a
legacy stack — Divi, Elementor, Bricks, a classic (non-block) theme, classic nav
menus, whatever it is — is not merely tolerated, it is the *primary, expected*
case sitegraft exists for.** B's entire design layer being something other than
Etch is precisely the situation being replaced or protected around (see §12: the
common case is B having none of Etch/ACSS installed at all, which `plan`/`graft`
now handle by offering to copy the stack from A, not by requiring B to already
match). Nothing in sitegraft ever inspects B's theme type as a gate on whether the
tool can run — the stack check in §12 is about whether A's *specific* stack
(Etch/ACSS/its theme) ends up present on B by the end of the run, never about
what B's *original* stack was.

**Classic menus (`nav_menu`/`nav_menu_item`, the `wp_nav_menu()` theme-location
system) are explicitly out of scope for v1 — on A only.** This is a deliberate
assumption, not a gap that slipped through:

- Etch is a block-theme/FSE-first builder — A is block-theme territory by
  construction, so a classic menu found on A would be unusual and worth a warning.
- A classic menu found on **B** is completely unremarkable (B likely isn't a
  block theme to begin with, per the point above) and triggers **no warning at
  all** — there is nothing to warn about; it's B's existing navigation, doing
  exactly what it's supposed to do until the graft replaces or coexists with it.
- Classic menus carry theme-location assignments (`register_nav_menu` slugs) that
  are meaningless without knowing the target theme's registered locations —
  migrating them correctly (from A, if A ever had one) needs its own module, not
  a generic core feature.

`scan` **detects** classic menus on **A** (`wp menu list`, see §6.1) and records
whether any exist with items assigned, purely so `plan` can surface a warning
("A has N classic menu(s) with items — sitegraft v1 does not migrate classic menu
assignments, migrate them by hand or write a module") rather than silently
dropping something the operator might expect to be handled. `scan` collects the
same data for B too (harmless, and occasionally useful context), but `plan` never
warns about it — B having classic menus is not a problem, and framing it as one
would be exactly the misreading this section exists to prevent. A `modules/classic-
menus.sh` is a plausible future module (own post_type is `nav_menu_item`, own
taxonomy is `nav_menu`) for migrating a classic menu **from A** — not attempted in
v1 (YAGNI): no current sitegraft use case runs against a classic-menu A.

## 14. Custom code in B's theme (pre-graft awareness gate)

`graft` replaces B's design layer. If B's *current* theme carries custom PHP —
a child theme's `functions.php`, snippets, mu-plugins — that code stops running
the moment the theme is no longer active, whether or not anyone remembered it
was there. This is a distinct risk from §12's stack precondition: §12 is about
whether the *new* stack renders; this section is about not losing track of
something useful living in the *old* one.

**What `scan` looks for on B (§6.1), shallow by design (no code parsing, YAGNI):**
child theme (`template` ≠ `name`), presence/size/line-count of the active
theme's `functions.php`, the `wp-content/mu-plugins/` file listing, and a short
list of known snippet-manager plugin slugs. Any one of these being non-empty
sets `custom_code_detected: true`.

**The gate:** if `custom_code_detected` is `true`, `plan` (§6.2 step 4) blocks —
it will not write a frozen manifest — until the operator explicitly
acknowledges, with the exact same weight as `--allow-stack-mismatch`'s override
(a distinct, hard-to-miss confirmation, never a warning that scrolls by):

> *"Did you review B's theme for custom code (functions.php, code snippets,
> mu-plugins) before replacing the theme? Custom code living in the old theme
> will be LOST."*

The acknowledgment (or its absence — `plan` simply doesn't produce a manifest
until it's given) is recorded in `manifest.custom_code_review` (§4), alongside a
frozen copy of the signals that triggered it, for the record.

**What this gate is not:** snippets a snippet-manager *plugin* stores in its own
database tables or options are already **plugin data** — covered by the
default-deny module system (§3.6) like any other plugin, protected unless
explicitly selected for migration, with no special-casing needed here. The risk
this section exists for is narrower and different in kind: **code living in
theme *files*** (`functions.php`, anything a child theme or an mu-plugin loads)
that has no module, no database row, and no protection mechanism at all — it
simply stops executing when the theme is swapped. That's not a class of thing
`migrate`/`protect` selections can express; a confirmation gate is the right
tool for a risk this shaped, not a manifest key.

**And this is not data loss, even when it happens:** `backup` (§6.3, review
finding A3) archives B's entire `wp-content/` — the old theme's files included —
before `graft` touches anything. The gate exists to prevent a *surprise*, not to
prevent *loss*; the safety net for loss is the backup, already mandatory before
`graft` can run at all. An operator who declines to acknowledge, thinks better
of it, and re-runs `plan` ready to proceed has lost nothing by having been asked.

## 15. Self-review

Review pass done by Rosalinde after the full write-up:
- **Placeholders/TBD**: none found — every wp-cli command, file format, and code
  example is concrete and directly runnable (once the `example.com`/`user@host`
  placeholders are swapped for real profile values).
- **Internal contradictions**: none found between §6.4 (media before WXR ordering)
  and §8 (`wp import`'s default behavior) — consistent.
- **Ambiguity fixed during writing**: the distinction between `clean` (B's
  pre-existing content) and idempotence pruning (content sitegraft placed itself)
  wasn't explicit in the original brief — clarified and documented separately in
  §6.6 and §11 to avoid any confusion in the implementation plan.
- **Risks**: recorded explicitly in §0.2 (R1-R4) rather than buried in the prose, so
  Nat can have Marcel rule on them without having to extract them herself.

### 15.1 Second pass (2026-08-19) — resolving the independent plan review

An independent review of the plan against this design doc (`docs/plans/2026-08-19-
sitegraft-plan-review.md`, done by Kimi before Step 1 started) found 7 concrete
plan-code defects (A1-A7 — missing options-migration step, a non-self-contained
`restore.sh`, a missing wp-content backup, unhandled remote-A transfers, unstable
mysqldump-timestamp checksums, unscoped search-replace calls, missing
wordpress-importer provisioning) and 3 scope gaps this design doc hadn't addressed
at all (B1 — no rendering-stack precondition, now §12; B2 — no classic-menu
handling or documented assumption, now §13; B3 — the DDEV harness's positive
assertions were too weak to catch A1 or a broken remap). All were resolved: the
plan's code was fixed, and this design doc gained §12-§13 plus the clarifications
folded into §6.1, §6.3, §6.4, §6.5, §9.1, and §9.4 above. C1's sequencing
recommendation (build the DDEV harness incrementally from the plan's first step,
not as a big-bang integration effort at the end) reshaped §10 and the plan's step
structure. Every finding's resolution is recorded, one line each, directly in the
review file — nothing here duplicates that log. R1-R4 (§0.2) and the two open items
they left (a real Etch-content dry run, a real MotoPress-shaped module) remain
unresolved by design: closing R2/R4 with a first real dry run against a genuine A/B
pair is now an explicit pre-v1.0.0 checklist item (`docs/definition-of-done.md`).

### 15.2 Third pass (2026-08-19) — Marcel's amendments to B1/B2

Marcel amended the resolutions to B1 and B2 above before Step 1 started:

- **B1 amended:** the original resolution (refuse + `--allow-stack-mismatch`
  override, §15.1) was correct as a fallback but incomplete as the primary
  behavior — it made "B already has A's exact stack" an implicit precondition,
  when the actual common case is B running something else entirely (§13). §12
  now describes `plan` offering to **copy** a missing or mismatched component
  from A, with the refuse/override path kept only for whatever the operator
  declines or never resolves. §4's manifest schema gained the `stack` key to
  record the decision. Reworded the core sentence of §12 to the exact
  distinction Marcel drew: *"sitegraft never installs anything from an external
  source — it only replicates what already exists on A."*
- **B2 clarified (no behavior change, wording only):** §13 and §6.1 were
  rewritten so the block-themes-only assumption reads unambiguously as **A-only**
  — B running Divi, Elementor, Bricks, or a classic theme is the normal,
  supported, expected case (indeed the primary one), not a precondition failure.
  The classic-menu warning was already A-only in the code (`phase_scan` never
  checked B's `classic_menus_detected`); §13 previously didn't say so clearly
  enough for a reader to be sure. It does now.

This pass also caught two stale cross-references from §15.1's edits (§6.1 said
"see §13" for the stack precondition, which is actually §12, and "see §14" for
classic menus, which is §13) — fixed alongside the amendment.

### 15.3 Fourth pass (2026-08-19) — custom-code-in-B's-theme awareness gate

Marcel added a third guardrail in the same round as B1/B2: `graft` replacing B's
design layer can silently discard custom PHP that only ran because B's old
theme was active (`functions.php`, mu-plugins, snippet-manager content). New
§14 documents the decision: `scan` collects shallow heuristic signals on B only
(child theme, `functions.php` presence/size, mu-plugins listing, known
snippet-plugin slugs — §6.1), and `plan` gates on them exactly as hard as the
stack-mismatch override (§6.2 step 4) — not a scrollable warning, an explicit
acknowledgment, or no manifest gets written. §4 gained `custom_code_review`
to record it. Distinguished explicitly from data already protected by
default-deny (a snippet plugin's own DB rows) versus the actual gap this closes
(code living in theme files, which no module or protection mechanism covers) —
and from data loss, since `backup`'s full `wp-content` archive (§6.3, finding
A3) already makes the old theme's files recoverable regardless; this gate is
about not being surprised, not about preventing loss that `backup` already
prevents.

### 15.4 Fifth pass (2026-08-19) — no hardcoded plugin slugs, ever

Marcel caught a bug in §12's own worked example before Step 1 started: ACSS's
plugin folder changed with the v4 release, so a pre-4.0 B and a v4+ A can run
the *same* module under *different* real directory names — and an early draft
of `graft_sync_stack` had hardcoded `"automatic-css"` for the component, which
would silently fail to sync a pre-4.0 install correctly. Fixed at the root: §3.2
gained the optional `<mod>_stack_candidates` function (detection-only, several
candidate slugs, most-preferred first) and the explicit rule that a candidate
list is never itself used to build a path — only the specific slug `scan`
actually finds present on a given site is allowed to. §3.4 is the worked
example (the ACSS case, with the legacy pre-4.0 slug left as a deliberate,
clearly marked placeholder — not invented, to be verified against a real
install before implementation). §4's `stack` schema changed from a single
version string per component to `{slug_a, slug_b, version_a, version_b}` so
each site's independently resolved real slug travels all the way from `scan`
through `plan`'s decision into `graft_sync_stack`, which now reads only
`slug_a` from the manifest and never re-derives, guesses, or hardcodes
anything. §3 was renumbered (3.4 inserted, motopress example and default-deny
shifted to 3.5/3.6) to make room for the ACSS example next to Etch's.
