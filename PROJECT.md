---
agency_project_id: 01a0572b-fa47-7926-8239-c88878c5bed4
agency_slug: sitegraft
---

# sitegraft — Project Folder

> **ENTRY POINT.** This file plus the links below contain **everything** needed to
> pick this project back up. An external dev unzipping this folder has **nothing**
> else to look up (no vault, no API, no Slack): idea, infra, status, todo, definition
> of done.
>
> **STATUS: in progress (v1 feature-complete — `1.0.0-rc4`, pending the pre-`1.0.0` gate)**
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

**First real client migration done — but the pre-`1.0.0` gate is NOT closed** (the
target was empty; see §6). On 2026-08-27/28 sitegraft performed its first real
client migration — a live WordPress Etch/ACSS site onto a separate hosted
target — and Marcel confirmed the result by hand. `SITEGRAFT_VERSION` is
`1.0.0-rc15`.

It took three runs, and the two failures are the point:

1. **Run 1 stopped itself.** The import-completeness gate (#53) refused a graft in
   which one item of 48 never landed. Root cause #16: a module's post-type-defining
   option was migrated *after* the WXR import, so the type was unregistered while
   the import ran. Without that gate the run would have reported success with
   content silently missing.
2. **Run 2 reported PASS and was wrong.** Every check was green; a human looked at
   the page and saw `Image with ID … not found` where the logo and hero belonged.
   Etch blocks reference media by id, the attachments got new ids on the target,
   and nothing rewrote them (#84) — including ids carried through
   operator-named component props (#86).
3. **Run 3 passed, verified by code and by human.** 6 pages, 0 broken-image
   placeholders, 0 references to the source domain, all font assets served.

**The lesson that shaped the fixes**: `verify` was green *because* of the defect.
Its content check compares the target's content to the source's — an id that
should have been rewritten and wasn't leaves the two **identical**, therefore
conformant. Anything requiring a remap is structurally invisible to an equality
comparison. Each remap now needs its own guard asking a *different* question, and
two such guards (`verify_id_references_resolve`,
`verify_component_prop_references_resolve`) were added and proved on the real run.

→ Detail: [`docs/status.md`](docs/status.md)

## 5. What's left to do (todo)

- [ ] **Pre-`1.0.0` gate — NOT closed.** The pilot ran onto a *virgin* target: 2
      pages, 0 attachments, no active plugins. The half the gate exists for was
      never exercised — see §6.
- [ ] **Graft onto a target that has lived.** A B with its own accumulated
      content, media, plugins and users. That is what default-deny, `protect`, id
      collisions with existing content, and the `keep-B` stack resolution are
      *for*, and none of them met real resistance on the pilot.
- [ ] **#82** — Etch taxonomies (`etch_taxonomies`) are never migrated. Same shape
      as #16 one level up, but **silent**: the completeness gate counts items, and
      a post whose terms were dropped still lands.
- [ ] **#83** — `wp-content/fonts/` is never synced, so WordPress 6.5+'s Font
      Library is lost without a word. Worked around by hand on the pilot.
- [ ] **#88** — the rewrite passes match only compact JSON; a spaced call site is
      left untouched. Pre-existing, low likelihood, total invisibility. Includes a
      cheap guard worth doing on its own: the remap already knows when it *decided*
      to rewrite, so "decided, but the text did not change" can be reported.
- [ ] **#79** — the DDEV harness fixture does not cover the shapes where the
      defects actually live (ssh-remote target, post types outside
      `exclude_from_search`, blocks carrying id references). It went green on three
      separate broken builds this session.
- [ ] Backlog: `modules/acss.sh` legacy slug, §5.2 interactive credentials,
      `motopress`/`classic-menus` modules, the `clean` sub-step of `graft`.
→ Detail: [`docs/todo.md`](docs/todo.md)

## 6. Definition of Done

The v1 DoD is met. The pre-`1.0.0` gate (design doc §0.2 R2/R4 — a real run on a
genuine A/B pair) is **not**, and marking it closed on the pilot would have been
wrong: **the target was empty.** 2 pages, 0 attachments, no active plugins. Source
side, the run was demanding — 1466 posts, 1438 attachments, a real Etch/ACSS stack,
a real remote target over ssh, two real restores. Target side, it graft onto a
blank page.

Everything sitegraft's safety model exists for went untested, because nothing
pushed back:

- **default-deny and `protect`** — B's own 2 pages and 1 post survived, which is
  the smallest possible evidence. A site with real content to lose was never tried.
- **id collisions with B's existing content** — the pilot's target had almost no
  ids of its own to collide with.
- **the `keep-B` stack resolution** — every plugin and the theme resolved to
  `copy`, because B had none. That branch has never run on a real pair.

So the gate stands as written, and needs a target that has lived: a site with its
own history, plugins, media and users. Until then the pilot proves the pipeline
and the source side, not the protection model.

Separately, what the pilot *did* expose is a gap in the **verification model** (see
§4): a future DoD should require, for every id remap, a guard that does not rest on
source/target content equality.
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
