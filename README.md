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

> **Status: design complete, implementation not started.** See
> [`PROJECT.md`](PROJECT.md) for the current state of the project. The full design
> document lives at
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
until `backup` has completed successfully. `graft` also refuses to run if B's
active theme, Etch, or ACSS version doesn't match A's — grafted content with
nothing to render it is a failure mode, not a success — unless you explicitly
pass `--allow-stack-mismatch` and confirm you mean it.

## The module system

The core of sitegraft is generic. What it can migrate on A and what it must protect on
B is declared by small, pluggable **graft modules** — one file per WordPress plugin or
content domain, in `modules/`. Adding support for a new plugin tomorrow is one new
file; the core never changes. See the design doc for the exact contract and a worked
example module.

Modules shipped in v1: `core-wp` (pages, posts, blocks, navigation, templates, global
styles, media), `etch` (Etch's custom post types and options), `acss` (Automatic CSS
settings and generated inventory). A `_template.sh` is provided for writing new ones.

## Requirements

- bash (works on the stock bash 3.2 shipped with macOS, and on any bash ≥ 4 on Linux/WSL)
- `ssh`, `rsync` — never `scp`
- `wp-cli`, reachable on both A and B (directly, or via a `ddev wp` wrapper for local
  DDEV sites)
- `jq` — manifest parsing
- `gum` (falls back to `fzf`, falls back to plain text prompts) — interactive selection

Test-only: `bats-core` for unit tests, `ddev` for the integration test harness.

**Windows without admin rights:** WSL requires admin privileges to install, so it's
not an option on a locked-down machine. Instead, run sitegraft itself on a remote
orchestrator machine (any Linux or macOS box you have shell access to — a spare
server, a cloud VM, even a Raspberry Pi) and connect to it over SSH from Windows.
The orchestrator only needs the dependencies above; it doesn't need to be A or B.

## Install

Not published yet. Once implemented:

```sh
git clone https://github.com/MarcelHeiniger/sitegraft.git
cd sitegraft
# add bin/ to PATH, or symlink bin/sitegraft somewhere on it
```

## Usage

```sh
sitegraft scan    --profile <profile>
sitegraft plan    --profile <profile>
sitegraft backup  --profile <profile>
sitegraft graft   --profile <profile> [--dry-run] [--allow-stack-mismatch]
sitegraft verify  --profile <profile>
sitegraft restore --profile <profile> --run <run-id>
```

A `<profile>` is a file in `profiles/<name>.conf` describing the A/B pair (hosts,
paths, wrapper commands) — see `profiles/example.conf`. Profiles never contain
secrets; credentials are read from `~/.config/sitegraft/<profile>.creds` (chmod 600,
never committed) or entered interactively.

## Writing a module

See [`modules/_template.sh`](modules/_template.sh) and the design doc's module
contract section for the full walkthrough, including a worked example for a
hypothetical booking plugin.

## Testing

```sh
bats tests/unit/                 # pure lib/ functions, no external dependencies
tests/integration/ddev-harness.sh  # 2 disposable DDEV sites, full scan→graft→verify run
```

The integration harness is the actual proof this tool is safe: it spins up a fake
"site A" with simulated Etch content and a fake "site B" with a fake protected plugin
(its own CPT, its own SQL table, its own options), runs a full graft, and asserts the
protected plugin's data is byte-identical before and after.

## License

MIT — see [`LICENSE`](LICENSE).
