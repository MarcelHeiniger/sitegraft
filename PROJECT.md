# sitegraft — Project Folder

> **ENTRY POINT.** This file plus the links below contain **everything** needed to
> pick this project back up. An external dev unzipping this folder has **nothing**
> else to look up (no vault, no API, no Slack): idea, infra, status, todo, definition
> of done.
>
> **STATUS: idea (design + plan delivered, implementation not started)**
> **Last updated: 2026-08-19** (via "update the project")

---

## 1. In one line

A portable bash CLI that "grafts" the design/content layer of a freshly built
WordPress Etch/ACSS site (site A) onto a live target site (site B), without ever
touching B's business plugins or their data — for any future Etch migration,
project-agnostic.

## 2. Idea & vision

Marcel regularly builds WordPress redesigns in Etch/ACSS for clients whose
production site already runs a business plugin loaded with real data (e.g.
bookings, e-commerce). Manually replacing the theme/content without touching the
plugin's data is repetitive, risky, and unsupported by any tooling. sitegraft wraps
that move in a tested, replayable tool that's extensible by simply adding a file.
→ Detail: [`docs/idea.md`](docs/idea.md)

## 3. Infrastructure

A 100% local/portable tool: bash + wp-cli + ssh/rsync. No hosted service, no
database of its own. Run state is stored on the machine running the tool (the
"orchestrator"), never permanently on A or B. **No secrets.**
→ Detail: [`docs/infrastructure.md`](docs/infrastructure.md)
→ Access/creds: **never here** — pointers live in `../.credentials/` (break-glass
`~/.SuperUser/`).

## 4. Where the project stands (status)

Design doc and implementation plan delivered 2026-08-19 (Rosalinde). No tool code
exists yet — only the project skeleton and documentation are in place. No pilot run
is planned: validation happens exclusively through the DDEV test harness (2
disposable WP sites) described in the design doc.
→ Detail: [`docs/status.md`](docs/status.md)

## 5. What's left to do (todo)

- [ ] Validate the design doc and the 5 open decisions with Marcel (see
      `docs/status.md` → Recent decisions)
- [ ] Plan step 1: core + profiles/credentials + scan (see
      `docs/plans/2026-08-19-sitegraft-implementation.md`)
- [ ] Step 2: manifest + interactive selection
- [ ] Step 3: backup + restore
- [ ] Step 4: graft (media + WXR + mu-plugin mapping + remaps)
- [ ] Step 5: verify + DDEV integration harness
- [ ] Step 6: polish (dry-run everywhere, usage docs, LICENSE, public README)
→ Detail: [`docs/todo.md`](docs/todo.md)

## 6. Definition of Done

A full `scan → plan → backup → graft → verify` run succeeds on the DDEV harness
(site A with simulated Etch content, site B with a fake protected plugin) without
altering a single byte of B's fake plugin data, with a working, tested `restore.sh`.
→ Detail: [`docs/definition-of-done.md`](docs/definition-of-done.md)

## 7. Getting started (dev)

See [`README.md`](README.md) — install / build / test / run locally.

## 8. Decision history

[`docs/decisions/`](docs/decisions/) — one decision = one file (an ADR: "why X").
Implementation plans: [`docs/plans/`](docs/plans/).
Full design doc:
[`docs/superpowers/specs/2026-08-19-sitegraft-design.md`](docs/superpowers/specs/2026-08-19-sitegraft-design.md).

---

### Update convention

This folder is the project's **source of truth**. When Marcel says **"update the
project"**: Nat pulls the live state (task API + session work), reconciles it, and
rewrites sections 4-5-6 plus the date above. The folder stays **always zip-ready**
afterward.

### Note on repo visibility

`repo/` is intended to be published as a **public GitHub repo** (MarcelHeiniger
account, an exception to the "all repos private" convention) — it will be shared
with the Etch community. Strict consequence: **zero secrets, zero real hosts/IPs,
zero client names, not even as "realistic-looking" examples** — only generic
placeholders (`example.com`, `user@host`, `<profile>`). **The entire `repo/`,
including every internal doc, is US English** — there is no French content anywhere
in the published repo.
