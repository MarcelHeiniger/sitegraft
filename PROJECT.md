# sitegraft — Project Folder

> **ENTRY POINT.** This file plus the links below contain **everything** needed to
> pick this project back up. An external dev unzipping this folder has **nothing**
> else to look up (no vault, no API, no Slack): idea, infra, status, todo, definition
> of done.
>
> **STATUS: in progress (v1 feature-complete — `1.0.0-rc1`, pending the pre-`1.0.0` gate)**
> **Last updated: 2026-08-20** (via "update the project")

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

All 6 implementation-plan steps are done (`main`, PRs #1-#5 plus the Step 6 polish
pass): scan, plan, backup, graft, verify, and restore are fully implemented,
unit-tested, and exercised end-to-end by the DDEV harness. `SITEGRAFT_VERSION` is
`1.0.0-rc1` — not a plain `1.0.0` yet, because the pre-`1.0.0` DoD gate (a real dry
run against a genuine A/B pair, not the DDEV harness) is still open and deliberately
not closeable by more DDEV-only work. No pilot run has happened yet.
→ Detail: [`docs/status.md`](docs/status.md)

## 5. What's left to do (todo)

- [ ] **Pre-`1.0.0` gate**: a real dry run against a staging copy of a genuine A/B
      pair — Marcel's call, on a real pair (see `docs/definition-of-done.md`).
- [ ] Review/merge the Step 6 polish PR.
- [ ] Backlog: `modules/acss.sh` (blocked on verifying a real legacy ACSS slug),
      the §5.2 interactive-credentials prompt, the `motopress`/`classic-menus`
      modules, the `clean` sub-step of `graft`.
→ Detail: [`docs/todo.md`](docs/todo.md)

## 6. Definition of Done

The v1 DoD (all 6 phases implemented, 2 shipped modules working end-to-end on the
DDEV harness, non-contamination + restore + `--dry-run` + default-deny all verified,
repo publish-ready) is met. The separate pre-`1.0.0` gate (a real dry run on a
genuine A/B pair, closing design doc §0.2's R2/R4) is **not** — that's the one item
left unchecked, deliberately, pending a real run.
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
