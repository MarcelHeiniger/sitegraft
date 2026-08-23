# Infrastructure — sitegraft

> ⚠️ **SANITIZED — no secrets here.** This file ships in the handoff zip AND in a
> **public** GitHub repo. No password, token, private key, real host, or IP — not
> even a "realistic-looking" example. Only `example.com`, `user@host`, `<profile>`.
> Real access lives as **pointers** in `../.credentials/` → break-glass
> `~/.SuperUser/<server>.md` (local, never committed, never in this repo).

## Tech stack

- **Language:** plain bash, bash 3.2 compatible (stock macOS) — see
  `docs/decisions/0003-bash-compatibility.md`. No Python, no Node, no WP plugin.
- **Runtime dependencies:** `ssh`, `rsync` (never `scp`), `wp-cli` (on A, on B, or
  via a local wrapper such as `ddev exec --raw -p <project> -- wp` — see the
  design doc §5.1 for why `--raw` is required), `jq` (manifest JSON parsing),
  `gum` (interactive UI, fallback `fzf`, fallback plain text prompts).
- **Test-only dependencies:** `bats-core` (unit tests for `lib/`'s pure functions),
  `ddev` (2-disposable-site integration harness).
- **No database of its own.** All data flows through A and B's own WordPress
  databases (via wp-cli).

## Where it runs

sitegraft is **not hosted** — it's a tool you run from any machine (the
"orchestrator") that has the runtime dependencies above.

| Role | Description | Notes |
|------|-------------|-------|
| Orchestrator | Machine (Mac/Linux/WSL) where `sitegraft` is launched | Run state (`~/.sitegraft/runs/<id>/`) is local to this machine |
| Site A | Source WordPress Etch/ACSS site, reachable via SSH+wp-cli or local DDEV | Read-only for sitegraft (never modified) |
| Site B | Live target WordPress site, reachable via SSH+wp-cli or local DDEV | Written only during the `graft` phase, after backup |

Each real A↔B pair (hosts, paths, SSH aliases) is declared in a profile file
`profiles/<name>.conf` — local-only and gitignored: no secrets, but real
hosts, paths and site URLs. Only `profiles/example.conf` is tracked.
Credentials (SSH key, an optional password) live either in
`~/.config/sitegraft/<profile>.creds` (chmod 600, gitignored) or are entered
interactively. See design doc §5 for the exact format of both.

## Deployment

sitegraft doesn't "deploy": it's a CLI you clone/install (`git clone` + `PATH`, or
copy `bin/sitegraft` + `lib/` + `modules/`) onto the orchestrating machine. No
deployment CI/CD applies.

## DNS / domains

N/A — sitegraft doesn't manage or change DNS. B's domain stays whatever it already
is; sitegraft only runs a `wp search-replace` from A's domain to B's **inside the
imported content** (see design doc, post-import remapping).

## CI / tests

- **Unit tests** (`tests/unit/*.bats`): pure functions in `lib/*.sh`, runnable with
  no external dependency other than bats-core. Must be green before any commit
  touching `lib/`.
- **Integration tests** (`tests/integration/`): a DDEV harness with 2 disposable
  sites (A = simulated Etch content, B = a fake protected plugin + its own CPT +
  its own SQL table). Central assertion: B's fake plugin data is byte-identical
  before/after a full `graft` run. Must be green before any merge touching
  `graft`/`backup`.
- No hosted CI planned for this project at this stage (a personal tool, not a
  company repo with a mandatory pipeline) — `bats` + the DDEV harness run locally
  before commit/merge. Revisit if the public repo attracts outside contributions.

## Backups / restore

This is a feature of the tool itself (the `backup` phase), not external infra: a
full `wp db export` of B + a `tar` of `wp-content`, pulled to the orchestrator via
`rsync`, along with a generated, ready-to-run `restore.sh`. Full detail in design
doc §6.3 (backup phase) and §6.7 (restore phase).
