# Findings — first reconnaissance against a real A/B pair

**Date:** 2026-08-22
**Context:** the pre-`1.0.0` Definition-of-Done gate (`docs/definition-of-done.md`) —
a real run against a genuine A/B pair rather than the DDEV harness.
**Phase reached:** reconnaissance only. **Nothing has been written to either site.**
No sitegraft phase has been executed yet; every finding below comes from read-only
`wp-cli` queries and from reading this repo's own source.

Sites are referred to as **A** (source: a freshly redesigned Etch/ACSS site) and
**B** (target: a restorable clone of a live site carrying business-plugin data),
per the repo's placeholder convention.

## The pair, in the abstract

| | A (source) | B (target) |
|---|---|---|
| Runtime | DDEV, PHP 8.4 | Docker (Apache + MariaDB), PHP 8.3 |
| wp-cli | via the DDEV wrapper | via a throwaway `wordpress:cli` container |
| Reachability | SSH, then containerized | SSH, then containerized |
| Table prefix | default | non-default |
| Active theme | `etch-theme-child` 1.0.0 (parent `etch-theme` 0.0.7) | `astra` 4.12.7 (`etch-theme` 0.0.7 present, inactive) |
| Etch | 1.6.5 | 1.4.11 |
| ACSS | `automaticcss-plugin` 4.0.0-rc-1 | absent |
| Page builder in place | Etch | Elementor + Elementor Pro |
| Business plugins | Hotel Booking 6.1.0, WooCommerce, a payment gateway | Hotel Booking 5.0.4, WooCommerce, the same gateway, remote monitoring, SMTP |
| Multilingual | none | full WPML stack |
| Snippet manager | WPCodeBox 2 | WPCodeBox 2 |

Two observations about the pair itself, before the defects:

- **A is not a "freshly built site."** The README's mental model is a clean new
  build. In practice A is the client's production site cloned and then redesigned,
  so A *also* carries business-plugin content (bookings, orders) — stale since the
  fork. `plan`'s default-deny protects B, but nothing warns the operator that
  A-side business content exists and must never be selected into `migrate`.
- **A is monolingual, B is multilingual.** No module covers WPML, so default-deny
  protects its tables — but imported content arrives with no language assignment
  at all. sitegraft neither handles nor warns about this today.

---

## F1 — A site that is both remote *and* containerized has no supported topology

`wp_remote` (`lib/inventory.sh`) has exactly two branches:

- `SITE_*_SSH_HOST` set → `ssh <host> "<WP_CMD> --path=<WP_PATH> …"`, with file
  transfers as `rsync <host>:<path>`. This assumes wp-cli runs **on the SSH host**,
  against the **same paths** rsync uses.
- `SITE_*_SSH_HOST` empty → a local wrapper, with container-path indirection
  handled properly (`_backup_local_exec_prefix`, `graft_pull_dir`/`graft_push_dir`
  streaming through the wrapper via `tar`).

A site reachable over SSH whose wp-cli then runs **inside a container** fits
neither. Setting `SSH_HOST` breaks in two independent ways:

1. `wp_remote` always appends `--path=$SITE_*_WP_PATH` (`lib/inventory.sh`). The
   host path (`/srv/…/public`) does not exist inside the container, which sees
   `/var/www/html`. Every wp-cli call fails.
2. `graft_export_wxr` runs `wp export --dir=/tmp/sitegraft-export-$$`, then
   `rsync`s from the **host's** `/tmp` — but wp-cli wrote into the **container's**
   `/tmp`. The pull silently yields nothing. `graft_import_wxr` has the mirror
   image of the same bug.

**Impact:** unusable, and (2) fails quietly rather than loudly.

**Workaround, no code change:** run sitegraft on the remote host itself (the
README's "remote orchestrator"), leaving both `SSH_HOST` values empty so both
sites take the supported local+wrapper path. Note the `WP_CMD` contract —
`_backup_local_exec_prefix` only recognizes a value ending in ` wp` — so any
`--path` baked into a container command must be moved out into `WP_PATH`.

**Suggested fix:** either document this topology and its workaround explicitly, or
add an optional exec-prefix/container-path key so remote+containerized becomes a
first-class case.

---

## F2 — WordPress notices on stdout corrupt every `--format=json` read

With `display_errors` on, WordPress prints each notice **twice**: once to stderr
(`PHP Notice: …`) and once to stdout (`Notice: …`). `inventory_scan_site` captures
stdout and pipes it to `jq`.

**Evidence:** running a wp-cli command with `2>/dev/null` still shows the `Notice:`
lines — they are on stdout by definition.

**Impact:** `scan` parses corrupt JSON on any site with a plugin emitting notices
at load time, which is extremely common. `lib/inventory.sh` already takes care to
keep stderr out of `$menus` (comment "N2"); the stdout copy defeats that.

**Mitigation, no code change:** put the suppression in the profile's `WP_CMD` —
`… -- env WP_CLI_PHP_ARGS=-ddisplay_errors=0 wp` (no space inside the value, or
word-splitting breaks it).

**Suggested fix:** strip any non-JSON preamble before parsing, or set
`WP_CLI_PHP_ARGS` from sitegraft itself.

---

## F3 — `modules/etch.sh` declares three post types that do not exist

`etch_post_types` returns `etch_cfs`, `etch_cpts`, `etch_loops`. On a real Etch
1.6.5 install, `wp post-type list` returns **none of them**. Etch registers no
custom post type at all: it stores its markup as Gutenberg blocks in `post_content`
plus `postmeta` on ordinary `page`/`post` records, which `core-wp` already covers.
Etch's own admin UI confirms it ("No custom post types available").

The module's file header states it was copied verbatim from the design doc's §3.3
and was never validated against a real install.

**Impact — the worst class of failure this tool can produce:** `plan` offers three
non-existent post types, `graft` exports an empty WXR, `verify` finds nothing
wrong. The run reports success having migrated no content whatsoever.

**Suggested fix:** drop `etch_post_types` entirely (the contract requires only one
of post_types/option_keys/tables, and `etch_option_keys` satisfies it).

---

## F4 — `modules/etch.sh` omits real, load-bearing options

Options actually present on a real Etch 1.6.5 install, against what the module
declares:

| Option | Module | Should be |
|---|---|---|
| `etch_settings`, `etch_styles`, `etch_global_stylesheets`, `etch_css_toolbar_values` | declared | keep |
| `etch_loops` | **missing** | **migrate** — this is the Loop Manager's saved loops |
| `theme_mods_<active-theme>` | **missing** | migrate (or handle as a theme concern) |
| `etch_migrations`, `etch_svg_version`, `etch_db_version` | absent / partly excluded | never migrate — schema state |
| `etch_license_key`, `etch_license_status`, `etch_license_options`, `etchtheme_license_options` | not declared | never migrate ✓ |

The license keys are safe today **only** because `etch_option_keys` is an explicit
allowlist — see F5.

**Impact:** a site's saved loops silently fail to migrate; so do the active theme's
customizer settings.

---

## F5 — `<mod>_option_keys_exclude` is inert (latent secret leak)

`modules/etch.sh`'s own comment records it: nothing in `lib/` or `bin/` ever calls
`module_has_fn "$mod" option_keys_exclude`, so the function's return value is
never read. Harmless for `etch`, whose `option_keys` is an explicit allowlist.

**Impact:** the moment any module returns a broad prefix from `_option_keys`
expecting `_option_keys_exclude` to carve license/secret keys back out — exactly
what `docs/usage.md` §5 documents the field for — those keys migrate to B. This is
a documented capability that does not exist.

**Suggested fix:** wire it, or remove it from the documented contract. It should
not stay documented-but-inert.

---

## F6 — No `etch_post_import` hook: Etch's own ID references are never remapped

`graft` remaps attachments, featured images, and the front-page option trio, plus
whatever a module's `post_import` hook handles. `modules/etch.sh` declares no such
hook.

Because Etch stores its configuration in `postmeta` (F3), any post ID referenced
*inside* that meta — a loop bound to a CPT, a link stored as an ID, a component
referencing a page — arrives on B still carrying **A's** IDs. Post IDs change
across a WXR import by construction.

**Impact:** the graft appears to succeed, styling included, while internal
references point at unrelated posts or at nothing. `verify` cannot detect it: its
checks cover protected checksums, migrated options, `page_on_front`, and domain
strings — none of which look inside migrated postmeta.

**Suggested fix:** an `etch_post_import` hook walking Etch's meta keys through
`id-map.tsv`, on the model of `modules/motopress.sh.example`.

---

## F7 — WPCodeBox is missing from the snippet-manager detection list

`SITEGRAFT_SNIPPET_PLUGIN_SLUGS` (`lib/inventory.sh`) lists `code-snippets`,
`wpcode`, `insert-headers-and-footers`. WPCodeBox 2 (`wpcodebox2`) is a widely used
snippet manager and is active on the target site here.

**Impact:** §14's blocking custom-code gate does not fire on that signal. It still
fires here via the mu-plugins signal, so the gate is not defeated in this instance
— but on a B whose only custom-code signal is WPCodeBox, `plan` would freeze a
manifest with no warning at all.

**Suggested fix:** add `wpcodebox2` to the list.

---

## F8 — `modules/acss.sh`: the blocker is partly lifted

`docs/usage.md` §5 says the module is unshipped pending verification of ACSS's
plugin-folder name. Verified against a real install:

- **v4 folder name: `automaticcss-plugin`** (observed at 4.0.0-rc-1).
- Options: `automatic_css_settings` (the entire configuration — migrate),
  `automatic_css_db_version`, `automatic_css_license_key`,
  `automatic_css_license_status` (never migrate).
- No custom post types, no custom tables.
- Generated CSS lives in `wp-content/uploads/automatic-css/` (`automatic.css`,
  `automatic-variables.css`, the block-editor variants…), so it travels with
  `graft_media_sync`, which syncs the whole `uploads` tree — see F9.

Given F5, `acss_option_keys` must be an **explicit allowlist** naming
`automatic_css_settings` only. A broad `automatic_css_*` prefix would ship the
license key to B.

**Still unverified:** the pre-4.0 folder name. This finding does not close that
question.

---

## F9 — `--ignore-existing` leaves generated assets stale on re-graft

`graft_media_sync` pushes A's uploads to B with `--ignore-existing`
(`--keep-existing` on the wrapped path), never overwriting a file already on B.
Correct for user media — an existing attachment on B must not be clobbered.

But it also covers plugin-generated assets living under `uploads/`, such as ACSS's
compiled stylesheets. On a first graft they land correctly (B has no such
directory). On **any subsequent graft**, B keeps the first run's CSS while its
`automatic_css_settings` option is updated to A's newer values — a silent drift
between configuration and rendered output.

**Impact:** grows with how often the tool is re-run against the same target, which
is the intended usage for a staged migration.

**Suggested fix:** let a module declare generated-asset paths to refresh, or handle
it in a `post_import` hook.

---

## What this says about the DoD gate

Nine defects, none of which the DDEV integration harness could have surfaced —
its site A simulates Etch through a fake mu-plugin registering `etch_cfs` rather
than running real Etch, so F3, F4 and F6 were invisible by construction, and its
two sites are local and uncontainerized, so F1 and F2 could not arise.

F3 and F6 are the serious ones: both produce a run that reports success while
having migrated nothing (F3) or having migrated content whose internal references
are broken (F6). Neither is caught by `verify`.

**Recommendation: do not tag `1.0.0` until at least F3, F4 and F6 are fixed and
re-verified against a real pair.**
