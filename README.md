# sitegraft

**Graft the design/content layer of a freshly built WordPress site onto a live target
site — without touching the target's plugins or their data.**

sitegraft is a portable bash CLI for a specific, recurring migration problem: you've
built a new WordPress site (**site A**, typically Etch + ACSS) and you need to move
its design and content onto an existing, live site (**site B**) that already runs
business-critical plugin data — bookings, orders, memberships, whatever it is — that
must come out the other side byte-for-byte untouched.

sitegraft is not a general WordPress migration tool. It does one job precisely:
replace the *design/content* layer of B with A's, and never so much as glance at
anything B's plugins own.

> **Status: v1, feature-complete.** All six phases (`scan`, `plan`, `backup`,
> `graft`, `verify`, `restore`) are implemented and covered by both unit tests and
> a full DDEV integration harness. See [`PROJECT.md`](PROJECT.md) for the current
> state of the project, [`docs/definition-of-done.md`](docs/definition-of-done.md)
> for exactly what "done" means (including the one gate still open before a plain
> `1.0.0` tag — a real dry run against a genuine A/B pair), and the full design
> document at
> [`docs/superpowers/specs/2026-08-19-sitegraft-design.md`](docs/superpowers/specs/2026-08-19-sitegraft-design.md).

## Why

Doing this by hand — manual WXR exports, hand-filtered SQL dumps, `sed` over
serialized PHP — is slow, unrepeatable, and one mistake away from corrupting a
customer's live data. sitegraft turns it into a small set of separately re-runnable
phases, built entirely on WordPress's own tooling (`wp-cli` and native WXR export/
import), with a mandatory backup and a one-command rollback before anything on B is
touched.

## How it works

```
scan → plan → backup → graft → verify → (restore if needed)
```

- **scan** — read-only inventory of both A and B: post types, options, custom tables,
  detected plugins.
- **plan** — interactive selection of what to migrate from A and what to protect on B;
  produces a frozen manifest file.
- **backup** — full database export + `wp-content` archive of B, pulled to the
  orchestrating machine, plus a ready-to-run `restore.sh`.
- **graft** — media sync, WXR import, ID remapping, done.
- **verify** — smoke checks that the graft succeeded and nothing protected was touched.
- **restore** — one command, rolls B back to its pre-graft state.

Every phase is independently re-runnable and inspectable. Nothing is destructive
until `backup` has completed successfully.

**Safety gates.** If B's active theme, Etch, or ACSS is missing or a different
version than A's, `plan` offers to copy the component from A and activate it on
B (never installed from anywhere else — sitegraft only ever replicates what's
already on A); a version already on B is never silently overwritten, that
needs its own explicit confirmation. Anything left unresolved makes `graft`
refuse outright unless you pass `--allow-stack-mismatch` and confirm you mean
it. Separately, if `scan` finds signs of custom code tied to B's current theme
(a child theme, a populated `functions.php`, mu-plugins, known snippet-manager
plugins), `plan` won't write a manifest at all until you explicitly confirm
you've reviewed it — replacing the theme would otherwise silently stop that
code from running. (`backup` already archives all of `wp-content`, so nothing
is truly lost either way — the gate is there to prevent a surprise, not to
prevent data loss that's already covered.)

## The module system

The core of sitegraft is generic. What it can migrate on A and what it must protect on
B is declared by small, pluggable **graft modules** — one file per WordPress plugin or
content domain, in `modules/`. Adding support for a new plugin tomorrow is one new
file; the core never changes. See [`docs/usage.md`](docs/usage.md#5-the-module-system)
for the exact contract and how to write one.

Modules shipped in v1: `core-wp` (pages, posts, the front-page option trio and the
active theme's `theme_mods_<slug>`), `etch` (Etch's post types and options) and
`acss` (Automatic.css's framework configuration, plus the stack-sync candidates for
both plugin-folder names it has shipped under). A `_template.sh` and a complete
worked example (`motopress.sh.example`) are provided for writing new ones.

## Requirements

- bash (works on the stock bash 3.2 shipped with macOS, and on any bash ≥ 4 on Linux/WSL)
- `ssh`, `rsync` — never `scp`
- `wp-cli`, reachable on both A and B (directly, or via a wrapper like
  `ddev exec --raw -p <project> -- wp` for a local DDEV site)
- `jq` — manifest parsing
- `gum` (falls back to `fzf`, falls back to plain text prompts) — interactive selection

Test-only: `bats-core` for unit tests, `ddev` for the integration test harness.

```sh
# macOS
brew install jq gum bats-core rsync
brew install ddev/ddev/ddev   # only if running the integration test harness

# Debian/Ubuntu
sudo apt install jq rsync
# gum has no apt package — see https://github.com/charmbracelet/gum#installation
```

**Windows without admin rights:** WSL requires admin privileges to install, so it's
not an option on a locked-down machine. Instead, run sitegraft itself on a remote
orchestrator machine (any Linux or macOS box you have shell access to — a spare
server, a cloud VM, even a Raspberry Pi) and connect to it over SSH from Windows.
The orchestrator only needs the dependencies above; it doesn't need to be A or B.

## Install

```sh
git clone https://github.com/MarcelHeiniger/sitegraft.git
cd sitegraft
# add bin/ to PATH, or symlink bin/sitegraft onto something already on it:
ln -s "$(pwd)/bin/sitegraft" /usr/local/bin/sitegraft
```

## Quickstart

```sh
cp profiles/example.conf profiles/my-migration.conf   # edit hosts/paths for real
sitegraft scan    --profile my-migration                          # read-only inventory of A and B
sitegraft plan    --profile my-migration                          # interactive: pick what to migrate/protect
sitegraft backup  --profile my-migration                          # full backup of B, with a ready-to-run restore.sh
sitegraft graft   --profile my-migration --dry-run                # preview the transfer, touches nothing
sitegraft graft   --profile my-migration                          # the real A -> B transfer
sitegraft verify  --profile my-migration                          # confirm nothing protected changed
sitegraft restore --profile my-migration --run <run-id>           # only if you need to roll back
```

`<profile>` is a file at `profiles/<name>.conf` describing the A/B pair (hosts,
paths, wrapper commands) — see `profiles/example.conf`. Profiles never contain
secrets, but they do hold real infrastructure details, so they're gitignored by
default (only `profiles/example.conf` is tracked); an optional credentials file
at `~/.config/sitegraft/<profile>.creds` (chmod 600, never committed) can pin a
specific SSH key per site — without one, sitegraft falls back to your
ssh-agent/default identity, which is enough for most setups.

**Full usage guide:** [`docs/usage.md`](docs/usage.md) — every flag, the exact
contract for writing a new module, and the full security model (non-contamination,
default-deny, the custom-code gate, backup-before-write, the rendering-stack
precondition).

## Testing

```sh
bats tests/unit/                 # pure lib/ functions, no external dependencies
tests/integration/ddev-harness.sh  # 2 disposable DDEV sites, full scan→graft→verify run
```

Shell lint (same check + config CI runs — see `.shellcheckrc` for the repo's
documented exceptions):

```sh
shellcheck bin/sitegraft
shellcheck lib/*.sh
shellcheck modules/*.sh modules/*.sh.example
shellcheck tests/integration/*.sh tests/integration/fixtures/*.sh
```

The integration harness is the actual proof this tool is safe: it spins up a fake
"site A" with simulated Etch content and a fake "site B" with a fake protected plugin
(its own CPT, its own SQL table, its own options), runs a full graft, and asserts the
protected plugin's data is byte-identical before and after.

## License

MIT — see [`LICENSE`](LICENSE).
