# sitegraft — Usage Guide

This is the full manual: install, configure a profile, and run every phase from
`scan` through `restore`. If you only need the elevator pitch and a quick example,
see [`README.md`](../README.md) instead — this document is the detail behind it.

## 1. What you need before you start

- **bash** — the stock bash 3.2 shipped with macOS works unmodified; bash ≥ 4 on
  Linux/WSL works too.
- **ssh**, **rsync** — sitegraft never uses `scp`. Both sites (A and B) must be
  reachable over SSH with `wp-cli` installed, or be local sites the orchestrator
  can drive directly (see "Local sites and DDEV" below).
- **`wp-cli`** — on both A and B (directly, or through a wrapper like DDEV's).
- **`jq`** — manifest parsing.
- **`gum`** — interactive selection prompts (menus, confirmations). Falls back to
  `fzf` if `gum` isn't installed, then to plain numbered `[y/N]` text prompts if
  neither is — sitegraft always works, gum just makes it nicer to use.

Test-only (not needed to run sitegraft against real sites): **`bats-core`** for the
unit tests, **`ddev`** for the integration test harness.

### Install the dependencies

```sh
# macOS
brew install jq gum bats-core rsync
brew install ddev/ddev/ddev   # only if you'll run the integration test harness

# Debian/Ubuntu
sudo apt install jq rsync
# gum has no apt package — see https://github.com/charmbracelet/gum#installation
```

### Windows without admin rights

WSL requires admin privileges to install, so it's not an option on a locked-down
work machine. The fix isn't to run sitegraft on Windows itself — bash 3.2/4 tooling
doesn't translate — it's to run sitegraft on a **remote orchestrator** instead: any
spare Linux or macOS machine you already have shell access to (a small cloud VM, a
Raspberry Pi, a colleague's box). Install the dependencies above there, then connect
to it over SSH from Windows (PuTTY, Windows Terminal's built-in SSH client, or
anything else) and drive sitegraft from that shell. The orchestrator only needs the
dependencies above — it doesn't need to be site A or B itself, it just needs SSH
reach to both.

### Sites that are remote AND containerized

sitegraft drives a site in one of two ways, and they are the only two:

- **over SSH** — it runs `wp` on the SSH host, and assumes wp-cli sees the same
  filesystem paths that `rsync` does;
- **locally through a wrapper** — the site runs in a container on the machine
  sitegraft itself runs on, and the container-path indirection is handled
  explicitly.

A site that is **both** — reachable over SSH, with wp-cli running inside a
container on the far end — fits neither, and `scan` now refuses it rather than
letting it fail later and quietly. It would otherwise pass files to paths the
container cannot see, and `wp export --dir=/tmp/...` would write inside the
container while the pull read the SSH host's `/tmp`: an empty export, reported
as a successful graft.

**The workaround is to move the orchestrator, not the site.** Install and run
sitegraft *on that server*, and leave its `SITE_*_SSH_HOST` empty so the site
takes the supported local+wrapper path above. Two things to get right when you
do:

- `SITE_*_WP_PATH` becomes the **container** path (typically
  `/var/www/html`), not the host path;
- `SITE_*_WP_CMD` must end in ` wp`, so any `--path` baked into a container
  command has to move out into `SITE_*_WP_PATH` — sitegraft appends its own.

For example, for a site served from a `docker run` wrapper:

```sh
SITE_B_SSH_HOST=""
SITE_B_WP_PATH="/var/www/html"
SITE_B_WP_CMD="docker run --rm -i --volumes-from <container> -u 33:33 -e HOME=/tmp wordpress:cli wp"
```

The `-i` matters: without it the container gets no stdin, and the `tar` streams
sitegraft uses for file transfer arrive empty.

Two limits worth knowing before you rely on this. The backup then lives on the
same machine as the target rather than on a separate orchestrator, which is
weaker than the design intends. And it is simply unavailable when A and B are
containerized on two *different* remote hosts — you cannot be local to both.
Making that case work properly is tracked as issue #19.

### Local sites and DDEV

If A or B is a local DDEV site (common for a freshly built A), point that site's
`SITE_*_SSH_HOST` at nothing (leave it unset) and set `SITE_*_WP_CMD` to
`ddev exec --raw -p <project> -- wp` instead of a bare `wp`. See
[`profiles/example.conf`](../profiles/example.conf) for the exact shape, and the
design doc §5.1 for why `--raw` specifically is required (without it, DDEV
re-parses the command through an inner shell, which silently corrupts any `wp eval`
snippet containing a PHP `$variable`).

## 2. Install sitegraft itself

```sh
git clone https://github.com/MarcelHeiniger/sitegraft.git
cd sitegraft
# add bin/ to PATH, or symlink bin/sitegraft onto something already on it:
ln -s "$(pwd)/bin/sitegraft" /usr/local/bin/sitegraft
```

## 3. Set up a profile

A profile is a file at `profiles/<name>.conf` describing the A/B site pair —
hosts, WordPress install paths, and how to invoke `wp-cli` on each. Profiles
**never contain secrets** — but they do contain real infrastructure details:
real hostnames, real filesystem paths, real site URLs, a real SSH user. That is
exactly the material `CLAUDE.md` keeps out of this public repo, so profiles are
**local-only, not committed** — `.gitignore` excludes every `profiles/*.conf`
except `profiles/example.conf` itself, which holds only placeholders. A newly
created profile is untracked by default; verify with `git status` before you
ever `git add` one by hand.

```sh
cp profiles/example.conf profiles/my-migration.conf
```

Then edit it:

```sh
SITE_A_ALIAS="a"
SITE_A_SSH_HOST="user@host-a.example.com"   # empty ("") for a local site
SITE_A_WP_PATH="/var/www/site-a/htdocs"
SITE_A_WP_CMD="wp"                          # or a DDEV wrapper, see above
SITE_A_URL="https://a.example.com"

SITE_B_ALIAS="b"
SITE_B_SSH_HOST="user@host-b.example.com"
SITE_B_WP_PATH="/var/www/site-b/htdocs"
SITE_B_WP_CMD="wp"
SITE_B_URL="https://b.example.com"

SITEGRAFT_STATE_DIR="${HOME}/.sitegraft/runs"
SITEGRAFT_CREDS_FILE="${HOME}/.config/sitegraft/my-migration.creds"
```

If either site needs a specific SSH private key (rather than whatever your
ssh-agent/default identity already provides), create the credentials file
referenced above — **never commit this file**, and it must be `chmod 600` or
sitegraft refuses to read it:

```sh
mkdir -p ~/.config/sitegraft && chmod 700 ~/.config/sitegraft
cat > ~/.config/sitegraft/my-migration.creds <<'EOF'
SITE_A_SSH_KEY="/absolute/path/to/private_key_a"
SITE_B_SSH_KEY="/absolute/path/to/private_key_b"
EOF
chmod 600 ~/.config/sitegraft/my-migration.creds
```

No credentials file at all is a perfectly normal setup too — sitegraft just falls
back to ssh's own default identity resolution (ssh-agent, `~/.ssh/config`), which
is all most setups need.

## 4. The six phases

```
scan → plan → backup → graft → verify → (restore, only if you need to roll back)
```

Every phase is independently re-runnable. `scan` and `plan` never write to B at
all; nothing on B is touched until `backup` has completed successfully, and
nothing about B's design is replaced until `graft`.

### 4.1 `scan` — read-only inventory of A and B

```sh
sitegraft scan --profile my-migration
```

Reads (never writes) both sites: post types, options, custom database tables,
installed plugins, active theme/version. Writes `scan-a.json`/`scan-b.json` into a
new timestamped run directory under `SITEGRAFT_STATE_DIR`. Always safe to re-run —
`scan` ignores `--dry-run` entirely because it has nothing to simulate (there's
nothing to write in the first place).

### 4.2 `plan` — decide what to migrate and what to protect

```sh
sitegraft plan --profile my-migration
```

Interactive. Builds a manifest from what `scan` found and what the installed
[modules](#5-the-module-system) claim, then:

1. **Custom-code awareness gate** (blocking): if `scan` found signs of custom code
   tied to B's current theme (a child theme, a populated `functions.php`,
   mu-plugins, known snippet-manager plugins), `plan` refuses to write anything
   until you explicitly confirm you've reviewed it. Replacing B's theme would
   otherwise silently stop that code from running — `backup` already archives all
   of `wp-content` either way, so nothing is actually lost, this gate exists to
   prevent a surprise, not data loss.
2. **Rendering-stack resolution**: for the active theme, Etch, and ACSS, if A and B
   differ (missing on B, or present under a different slug/version), `plan` offers
   to copy A's version onto B — never installed from anywhere else, only ever
   replicated from A. A plain confirmation if it's simply missing on B; a heavier,
   separate confirmation if B already has *something* there (that existing folder
   is never deleted, just left alongside the new one, inactive).
3. **Item-level selection**: review exactly which post types/options each detected
   module wants to migrate, with sensible defaults pre-selected — toggle any of
   them off.

The result is a **frozen manifest** (`manifest.json` in the run directory).
Anything not explicitly selected into `migrate` is protected by default
(default-deny, see [Security](#6-security-model) below) — nothing is migrated by
accident.

### 4.3 `backup` — back up B before anything is touched

```sh
sitegraft backup --profile my-migration [--dry-run]
```

Full database export + `wp-content` archive of B, pulled to the orchestrating
machine, plus a **self-contained, ready-to-run `restore.sh`** written into the same
run directory. This must succeed before `graft` will run at all — `graft` refuses
outright if no `backup.complete` marker exists for the run.

`--dry-run` prints the commands that would run and skips writing real backup
files, checksums, or the completion marker — it never claims success for a backup
that wasn't actually taken.

### 4.4 `graft` — the actual A → B transfer

```sh
sitegraft graft --profile my-migration [--dry-run] [--allow-stack-mismatch]
```

Syncs whatever the plan approved for the rendering stack, then hard-refuses if
anything is still mismatched — pass `--allow-stack-mismatch` to override, which
itself requires a second, louder confirmation than anything else in this tool
(`plan`'s own copy-offer already gives you a way to avoid ever needing this flag).
Then: media sync (files copied to B's uploads directory), attachment import (every
attachment on A registered as a WordPress attachment on B), WXR export/import of the
selected content, ID remapping (attachments, featured images,
`page_on_front`/`page_for_posts`), domain search-replace scoped to migrated content
only, options migration, and any module-specific post-import hooks.

Attachment import is batched, not one container invocation per attachment: a single
`wp eval` on A collects every attachment's metadata, and a single `wp eval` on B
imports and remaps all of them in one WordPress bootstrap. On a site with a few
hundred attachments this completes in minutes rather than the hours a per-attachment
loop would take. The step end-of-run report always states how many attachments were
**actually** imported and remapped — never how many were merely requested — and the
step fails outright (non-zero exit, listing which attachments) if it cannot account
for every one of them, rather than silently reporting fewer as a success.

`--dry-run` prints every command it would run instead of running it — nothing on B
is touched. Every step is also individually idempotent (tracked via marker files in
the run directory), so a `graft` that's interrupted partway through can simply be
re-run and picks up where it left off, rather than starting over or duplicating
content — the attachment-import step specifically re-checks, per attachment, what B
already has before importing anything, so a resumed run neither re-imports an
attachment already there nor skips one that's still missing.

### 4.5 `verify` — confirm the graft actually worked

```sh
sitegraft verify --profile my-migration
```

Read-only against B, end-to-end. Checks: every protected checksum from `backup`
still matches (nothing sitegraft wasn't told to touch actually changed), migrated
options carry A's exact values, `page_on_front` resolves to the correctly remapped
page, A's domain string is absent from B's migrated content, and (if configured) an
HTTP smoke check that B's front page actually renders with an expected marker.
Writes a report into the run directory.

Every check in the report is accounted for on every run — verified, explicitly not
applicable, or explicitly unverifiable — never silently absent while `Result: PASS`
still prints. A ticked check either **names what it examined** (a count, a page ID)
or **names the known fact** that made it not applicable; "it passed" and "there was
nothing to look at" never render the same way. Concretely:

- The migrated-options line names how many of the selected keys were actually
  compared, e.g. `migrated options match A's values on B (12 of 12 compared)`. If
  some were selected but none had a value to compare against (a run interrupted
  before the options step and later resumed), that is reported as unverified —
  never as a plain, uncounted pass.
- The domain-absence check always prints a line, and when it really ran it says how
  much it looked at, e.g. `A's domain string is absent from the content graft
  imported (48 migrated post(s) + 3 migrated option(s) scanned)`. The counts matter:
  the check is scoped to what *this run* migrated, so if `id-map.tsv` is empty and
  no option keys were selected there is nothing in scope, and it reports
  **unverified** rather than "absent". (An empty `id-map.tsv` is exactly what a run
  whose ID-mapper never loaded looks like — `graft` warns about it — and it is the
  run most likely to have left A's domain behind.)
- When no domain is configured for the migration at all, the same line is marked
  not applicable — a known fact read from the manifest, not an uncertainty. If the
  manifest has no `options.search_replace.from` key whatsoever (a hand-written
  manifest; `plan` always writes one), that is different again: nothing is known
  either way, and it is reported as not verifiable.
- `page_on_front` gets one of four distinct lines, never a single line covering
  several of them at once: verified against B (naming the page ID it resolved to),
  not applicable because it was not part of this run's migrate selection, not
  applicable because A's own recorded value says A never had a front page, or
  unverified. It **fails** verify if A had a front page selected for migration and
  `graft` could not resolve it through `id-map.tsv` — that used to be read as "A
  never configured one" and passed silently; a missing remap is now a hard failure,
  not an exemption. If page_on_front was selected but its recorded value was never
  written to disk at all (the same "interrupted, later resumed" shape as the
  migrated-options case above), that is reported as unverified too.
- The navigation line likewise separates "present on B (N wp_navigation post(s)
  found)" from "not applicable — wp_navigation was not part of this run's migrate
  selection".
- The HTTP smoke check, when the profile has no `SITE_B_URL`, is marked not
  applicable rather than left as an unticked box under a `PASS` footer.
- A `manifest.json` that is not valid JSON aborts the phase outright. Every check
  reads its scope from that file, so a malformed manifest would otherwise produce a
  report full of confident ticks for checks that examined nothing.

**The overall `Result:` and exit code are three-valued, not a plain pass/fail:**

| Result | Meaning | Exit code |
|---|---|---|
| `PASS` | Every check verified correct, or was genuinely not applicable (a known fact, e.g. no domain configured for this migration). | `0` |
| `HARD FAIL` | At least one check found a confirmed defect, or a check's own execution failed outright (a query/`wp eval` that could not run — this signals the read machinery itself may be unreliable, a strictly worse condition than "some data just wasn't produced yet"). | `1` |
| `INCOMPLETE` | No hard failure, but at least one check had nothing to work with — an earlier step's data was never produced (a graft interrupted and later resumed), or the check's scope came out empty, or the manifest never recorded what it would have needed. The check's own machinery is fine; there is simply nothing to check it against. The graft is not confirmed good, but it is also not confirmed bad. | `2` |

`HARD FAIL` outranks `INCOMPLETE` when a run has both — a confirmed defect is the
stronger, more actionable signal. A caller scripting against `verify`'s exit code
should treat anything non-zero as "do not consider this graft done", and treat `2`
specifically as "re-run `graft` to resume the interrupted step(s), then verify
again" rather than as a defect to investigate.

`--dry-run` is accepted here too, but `verify` is already read-only against B by
construction — there is nothing for it to simulate, so it just runs the real checks
either way. This is deliberate, not an oversight: an earlier version of this phase
set the dry-run flag and never reset it, which made every check below read the
literal text `[dry-run] ...` instead of B's actual data and report a false failure
on a graft that had actually succeeded — fixed, and `--dry-run` on `verify` is now
exactly as safe (and exactly as unnecessary) as passing it to `scan`.

### 4.6 `restore` — roll B back

```sh
sitegraft restore --profile my-migration --run <run-id> [--yes] [--dry-run]
```

Runs the run's generated `restore.sh` — but first takes its own safety snapshot of
B's *current* state (database and `wp-content`) into a `pre-restore-<timestamp>/`
subfolder, complete with its own generated `restore.sh`, so even a restore stays
reversible. Asks for confirmation unless `--yes` is passed. `<run-id>` is the
directory name `scan` created (printed at the end of every phase, and listable
under `SITEGRAFT_STATE_DIR/<profile>-*`).

You can also run the run directory's `restore.sh` directly (`./run-dir/restore.sh`)
without sitegraft at all — it's self-contained on purpose (only needs ssh, rsync,
tar, gzip/gunzip, wc), so it still works even if you no longer have a sitegraft
checkout on hand.

### Flag reference

| Flag | Phases | Effect |
|---|---|---|
| `--profile <name>` | all | Required. Which `profiles/<name>.conf` to use. |
| `--run <run-dir>` | plan, backup, graft, verify, restore | Which run directory to operate on. Defaults to the most recent one for the profile (required for `restore`). |
| `--dry-run` | all | Print what would happen instead of doing it. `scan`/`plan`/`verify` accept it too for CLI consistency, but each is read-only (or writes only locally) already, so it's a safe no-op there — the real reads/checks always run. |
| `--allow-stack-mismatch` | graft only | Override the rendering-stack hard precondition. Triggers a second, louder confirmation. |
| `--yes` | restore only | Skip the confirmation prompt. |
| `-h`, `--help` | — | Print usage. |
| `--version` | — | Print the installed version. |

## 5. The module system

What sitegraft can migrate and what it must protect is declared by small,
pluggable **graft modules** — one file per WordPress plugin or content domain, in
`modules/`. The core (`lib/`, `bin/`) never changes to add support for a new
plugin; you add one file.

Shipped in this repo:
- **`core-wp`** (`modules/core-wp.sh`) — WordPress core content: pages, posts, the
  front-page option trio (`show_on_front`/`page_on_front`/`page_for_posts`,
  correctly remapped through the ID map rather than blindly copied), and the
  active theme's `theme_mods_<slug>` customizer settings, resolved from the scan
  and rewritten before they land on B — `custom_logo` is remapped through the ID
  map (A's attachment number would otherwise point at whatever image B happens to
  give that number), and `nav_menu_locations`/`custom_css_post_id` are removed,
  since sitegraft migrates neither classic menus nor `custom_css` and B has no
  counterpart for those IDs.
- **`etch`** (`modules/etch.sh`) — the WordPress post types Etch actually stores
  content in (`wp_block`, `wp_template`, `wp_global_styles`), its options
  (settings, styles, global stylesheets, CSS toolbar values, CFS/CPT definitions),
  the post types `etch_cpts` declares on the scanned site, and a post-import hook
  that remaps Etch's own component references.
- **`acss`** (`modules/acss.sh`) — Automatic.css's framework configuration, plus
  the stack-sync candidates for both plugin-folder names the plugin has shipped
  under (the pre-4.0 → 4.0 rename).
- `modules/_template.sh` — a documented skeleton, copy it to get started.
- `modules/motopress.sh.example` — a complete worked example for a hypothetical
  future module (MotoPress Hotel Booking), showing every part of the contract
  including a plugin-owned table and a post-import remap hook. Not loaded by
  default (the `.example` suffix keeps it out of module discovery) — drop the
  suffix to activate it for real.

### Writing your own module

Copy [`modules/_template.sh`](../modules/_template.sh) to `modules/<your-plugin>.sh`
(the function prefix is the filename with hyphens turned into underscores, so
`modules/my-plugin.sh` → functions prefixed `my_plugin_`). A module must define:

| Function | Required | Role |
|---|:---:|---|
| `<mod>_name` | yes | Human-readable name shown in prompts. |
| `<mod>_detect <scan_json>` | yes | Exit 0/1 — is this plugin present on the scanned site? |
| `<mod>_post_types` | at least one of these six | Post types this module owns, one per line. |
| `<mod>_post_types_dynamic <scan_json>` | | Same, but computed from the scan — for names only knowable after `scan`. |
| `<mod>_option_keys` | | `wp_options` keys this module owns, one per line. |
| `<mod>_option_keys_dynamic <scan_json>` | | Same, but computed from the scan. |
| `<mod>_tables` | | Plugin-owned SQL table suffixes (without the live `$table_prefix`), one per line. |
| `<mod>_tables_dynamic <scan_json>` | | Same, but computed from the scan. |
| `<mod>_option_keys_exclude` | no | Glob patterns removed from the option keys this module claims (e.g. license keys, DB version markers). Applied to both the static and the dynamic lists. Note it filters *names your module returned*; sitegraft never expands a pattern into keys, so a broad claim has to be enumerated from the scan by `_option_keys_dynamic` — see below. |
| `<mod>_post_import <state_dir> <id_map_tsv> <wp_cmd_b>` | no | Hook run after WXR import + generic remaps, for module-specific fixups (e.g. remapping an internal ID reference in postmeta). |
| `<mod>_stack_candidates` | no | If this plugin also needs to be *present and matching* on B for migrated content to render (like Etch or ACSS), one candidate plugin-folder slug per line, most-preferred/current first. |

### Selections computed from the scan

Some names cannot be written down in advance, because they depend on the site.
The active theme's customizer settings live in `theme_mods_<stylesheet>`, and Etch
lets a site declare its own post types in the `etch_cpts` option — in both cases
the *name* is only knowable once `scan` has run. That is what the `_dynamic`
functions are for. Each receives one argument, the path to a `scan-*.json`, and
prints names one per line just like its static counterpart:

```sh
# The active theme's customizer settings — modules/core-wp.sh does this for real.
my_plugin_option_keys_dynamic() {
  jq -r '"theme_mods_" + .active_theme.stylesheet' "$1"
}
```

The two lists are merged, so a module can have both; every name — static or
dynamic — appears individually in `plan`'s selection prompt and can be
deselected there.

A `_dynamic` function must work from the scan file alone. `plan` never touches the
live sites, so calling `wp` or `ssh` from one is not supported.

**Exiting non-zero means "I could not tell", and stops the run.** Printing nothing
and exiting 0 means "this module claims nothing here", and is fine. Those are
different answers and sitegraft treats them differently: a `_dynamic` function that
fails aborts `plan` with a message naming the function, rather than quietly
planning a smaller migration. (If you need to get a run through while a module is
broken, `SITEGRAFT_MANIFEST_PREFILLED` skips module defaults entirely — see §4.)

The same applies to `<mod>_option_keys_exclude`: if it fails, `plan` refuses,
because continuing would migrate exactly the keys it was there to hold back.

**Keeping secrets out of a broad prefix.** A "prefix" is never a wildcard sitegraft
resolves for you: `graft_migrate_options` runs `wp option get <key>` on the literal
string in the manifest, so returning `my_plugin_*` from the static `_option_keys`
would end up running `wp option update 'my_plugin_*'` on B. Enumerate the prefix
from the scan with `_option_keys_dynamic`, as below, and let
`_option_keys_exclude` carve the secrets back out. It is applied to the
static and dynamic option keys alike, before anything is written to the manifest —
and the manifest is the only thing `graft` and `verify` ever read, so an excluded
key is excluded everywhere. That makes "return the whole prefix, exclude the
secrets" a safe way to write a module:

```sh
my_plugin_option_keys_dynamic() {
  jq -r '.options[]?.option_name | select(startswith("my_plugin_"))' "$1"
}
my_plugin_option_keys_exclude() {
  printf 'my_plugin_license_*\nmy_plugin_*_api_key\n'
}
```

Names containing a comma or whitespace are rejected: they cannot survive `graft`'s
post-type CSV or its option-key word splitting, and would silently be read as two
different names.

See [`docs/decisions/0007-module-dynamic-selections.md`](decisions/0007-module-dynamic-selections.md)
for the full contract and the reasoning behind each rule.

**If your `post_import` hook writes to B, wrap every such call in `run_or_echo`**
(from `lib/core.sh`, already sourced by the time any hook runs) — hooks are called
unconditionally, including under `--dry-run`, and a hook that calls `$wp_cmd_b`
directly instead would write to B even on a dry run. See
`modules/motopress.sh.example`'s `motopress_post_import` for the pattern, and the
design doc §3.2 for the full contract.

**Never hardcode a plugin's folder name to build a file path.** `_stack_candidates`
exists purely for *detection* — a plugin's real folder name can differ between
installs (Automatic.css's pre-4.0 → 4.0 rename is the real-world case this
protects against). Whichever candidate `scan` actually finds present is what
travels forward into the manifest; that resolved value, never the module's
candidate list, is the only thing `graft` is ever allowed to read when building an
`rsync` path.

## 6. Security model

sitegraft's whole reason to exist is a strict boundary: replace B's *design/content*
layer with A's, without so much as glancing at anything B's business plugins own.
Concretely:

- **Non-contamination.** Every table/option a protection module declares on B gets
  a checksum taken during `backup`, *before* `graft` touches anything, and
  `verify` recomputes and compares it after. This is byte-for-byte, not visual —
  if a protected table changed even by one byte, `verify` hard-fails.
- **Default-deny.** Anything `scan` finds on B that isn't explicitly covered by a
  known module is listed as "protected by default" and never migrated or
  overwritten — you have to actively select something into `migrate` for it to
  move. An unrecognized table doesn't accidentally end up unprotected; it ends up
  unmigrated.
- **The custom-code awareness gate.** `plan` refuses to freeze a manifest for a B
  showing custom-code signals (child theme, `functions.php`, mu-plugins, snippet
  plugins) until you explicitly confirm you've reviewed it — replacing the theme
  would otherwise silently stop that code from running.
- **Backup before any write.** `graft` structurally cannot run without a completed
  `backup` for the same run (`backup.complete` marker) — there is no path to
  "graft without a safety net," accidental or otherwise.
- **The rendering-stack precondition.** `graft` refuses to run if B's active
  theme, Etch, or ACSS doesn't match A's, unless you pass
  `--allow-stack-mismatch` and get through its own separate, louder confirmation.
  Grafted content with nothing on B able to render it would "succeed" by every
  content-level measure while producing a visibly broken site — this gate exists
  so that never happens silently.
- **Nothing sitegraft copies is ever installed from anywhere external.** The only
  things `graft` ever writes to B's `wp-content/themes/`/`wp-content/plugins/` are
  literal copies of what's already on A, never a download from wp.org or a
  marketplace, never a license activation.
- **`--dry-run` everywhere.** Every phase that writes (`backup`, `graft`,
  `restore`) supports it, and it's accepted as a safe no-op on every other phase
  too — you can always see exactly what a run would do before it does it.

## 7. Testing

```sh
bats tests/unit/                    # pure lib/ functions, no external dependencies
tests/integration/ddev-harness.sh   # 2 disposable DDEV sites, full scan->graft->verify run
```

The integration harness is the actual proof this tool is safe: it spins up a fake
"site A" with simulated Etch content and a fake "site B" with a fake protected
plugin (its own custom post type, its own SQL table, its own options), runs a full
graft, and asserts the protected plugin's data is byte-identical before and after —
plus the positive assertions (migrated content actually landed correctly, domain
strings were rewritten, `page_on_front` resolves right).
