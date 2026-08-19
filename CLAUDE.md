# CLAUDE.md — sitegraft (repo)

**Read `PROJECT.md` first** (entry point: idea, infra, status, todo, DoD), then
`docs/plans/` and `docs/status.md` before doing anything on this project.

## What

A portable bash CLI that grafts the design/content layer of a WordPress Etch/ACSS
site (site A) onto a live target site (site B) without touching B's plugins/data.

## Language

**Everything in this repo is US English** — docs, code, and comments alike. This
repo is shared publicly with the Etch community; there is no French content
anywhere in it (project docs outside `repo/`, e.g. the container-level README, may
stay French — that's outside what gets published).

## Dev / build

Not implemented yet — see `docs/plans/2026-08-19-sitegraft-implementation.md` for
the build sequence. Once the tool exists:
```sh
# unit tests (pure functions in lib/)
bats tests/unit/

# integration tests (DDEV harness, 2 disposable sites)
tests/integration/ddev-harness.sh
```

## Deployment

N/A — sitegraft doesn't deploy anywhere; it's a CLI cloned/installed on the machine
that runs it (see `docs/infrastructure.md`).

## Conventions

- **Versioning**: bump the version in `bin/sitegraft` (the `SITEGRAFT_VERSION`
  variable) on every user-visible behavior change.
- **Never raw SQL filtered by hand for content.** Content = WXR (`wp export`/
  `wp import`). Options = `wp option get/update --format=json`, one at a time.
  Plugin-owned tables = targeted `wp db export --tables=X,Y`.
- **Never `sed`/raw regex on WordPress data.** Always `wp search-replace` (safe on
  serialized PHP).
- **Never `scp`.** Always `rsync` for any file transfer.
- **The module system is the extensibility point.** A new business plugin to
  protect = a new `modules/<plugin>.sh` file, zero changes to `lib/` or `bin/`. See
  the design doc §3 for the exact contract.
- **Safe default (default-deny).** Anything detected on B but not covered by a
  known module is protected by default, never migrated/overwritten without an
  explicit manifest selection.
- **Zero secrets in the repo — public GitHub repo.** No real host, IP, password,
  token, or client name, not even as a "realistic-looking" example. Only generic
  placeholders (`example.com`, `user@host`, `<profile>`). Real credentials live
  outside the repo (`~/.config/sitegraft/<profile>.creds`, gitignored) or are
  entered interactively.
- **Bash 3.2 portability** (no associative arrays) — see
  `docs/decisions/0003-bash-compatibility.md`.
