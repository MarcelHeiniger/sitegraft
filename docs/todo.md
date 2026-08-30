# Todo — sitegraft

> Current backlog. Prioritized. Reflects the live state after the first real
> client migration.
> **Last sync: 2026-08-28**

## Next steps (priority)

- [ ] **Pre-`1.0.0` gate — still open.** The 2026-08-28 pilot was a full real
      migration, human-confirmed, but onto a **virgin target** (2 pages, 0
      attachments, no active plugins). It proves the pipeline and the source side;
      it does not prove the protection model, which is the half the gate exists
      for. Do not tick this on a graft onto a blank site.
- [ ] **Graft onto a target that has lived** — a B with its own accumulated
      content, media, plugins and users. Exercises what the pilot could not:
      default-deny and `protect` against content that actually matters, id
      collisions with B's existing posts, and the **`keep-B` stack resolution**,
      which has never run on a real pair (every item resolved to `copy` on the
      pilot because B had no plugins).
- [ ] **#82 — Etch taxonomies.** `etch_taxonomies` is claimed by no module.
      Same defect as #16 one level up, and **worse**: the completeness gate counts
      items, so a post whose terms were dropped still lands and the gate passes.
      Not triggered on the pilot site (the option does not exist there).
- [ ] **#88 — spaced JSON.** Every rewrite pass matches the compact form only; a
      spaced call site is left untouched, by two independent causes. Pre-existing
      (#84/#85 miss it identically), never emitted by WordPress's serializer.
      Contains a cheap sub-task worth doing regardless: the remap decodes each
      block, so it knows when it *decided* to rewrite — reporting "decided, but the
      raw text did not change" turns total silence into a named post id.
- [ ] **#79 — the harness fixture misses the shapes that matter.** It went green
      on three separate broken builds this session. Needs: an ssh-remote target, a
      post type outside `get_post_types(['exclude_from_search' => false])`, and
      blocks carrying id references.
- [ ] Consider making the HTTP smoke marker configurable per profile — it
      currently looks for "Home" and false-fails on any non-English site.

## Backlog

- [x] **Read a real `etch_cpts` row off a live Etch install that uses the
      feature.** Done as part of issue #16's fix-pack: queried a live Etch
      1.6.6 install with a real, in-use custom post type directly (`wp option
      get etch_cpts --format=json`). The row is the map-keyed-by-name shape
      `etch_post_types_dynamic` already handled correctly (`{"fotos":
      {"slug":"fotos", ...}}`) — the OTHER two shapes stay defensive/
      unconfirmed. The same query traced WHERE Etch reads it
      (`Etch\Services\ContentTypeService::register_post_types()`, hooked on
      `init` priority 5), which is what settled issue #16's actual defect:
      an ORDERING bug (the option reached B too late for that `init` hook to
      register the type before the WXR import ran), not a selection bug. See
      `modules/etch.sh`'s `etch_post_types_dynamic` (updated "CONFIRMED"
      comment) and `etch_post_type_defining_option_keys`.
- [ ] **Interactive credentials prompt (design doc §5.2, option (b)) — not
      implemented.** `lib/profile.sh` only supports the file-based credentials path
      today; a missing `.creds` file logs a warning and proceeds without
      `SITE_*_SSH_KEY` (falls back to ssh's own default identity resolution) rather
      than prompting interactively and offering to save the result. Not broken in
      practice — most setups don't need a per-site key at all — but a real gap
      against what §5.2 documents.
- [ ] The hypothetical `motopress.sh` module — written as a worked example in the
      design doc, not yet implemented or tested against a real MotoPress install.
- [ ] A possible `modules/classic-menus.sh` — v1 explicitly does not migrate
      classic nav menu assignments (design doc §13); `scan` detects and warns,
      nothing more. Revisit only if a real project needs it.
- [ ] The `clean` sub-step of `graft` (design doc §6.6 — removing B's pre-existing
      ORIGINAL content for a migrated post_type) is speced but not implemented.
      `graft` refuses loudly if `manifest.clean.enabled=true` is ever set by hand,
      rather than claiming a false success — but nothing in `plan` can currently
      set it to `true` in the first place (`plan_defaults`/`manifest_new` always
      default it `false`), so this is inert, not reachable, in the normal flow.
- [ ] An install script (`install.sh`) beyond the manual `brew`/`apt` snippets now
      in `README.md`/`docs/usage.md`.
- [ ] **`verify`'s slug-collision warning (design doc §11) — not implemented.**
      WordPress itself safely handles a `post_name` collision on B (automatic
      `-2` suffix), so this isn't a data-safety gap — but `verify` never warns an
      operator that a slug was renamed, which the design doc originally
      described. Needs a new cross-site read (A's pre-migration `post_name` for
      each migrated post) that no existing `verify` check currently does (every
      one is B-only today). Found in the Step 6 self-review; deliberately not
      added then (real feature work, not a small addition, this late in a
      polish pass).

## Ideas / later

- Support a "diff report" output mode for `verify` (HTML or markdown) — YAGNI for
  v1, revisit once the tool has been used on a real run.
- Possible Homebrew publication (`brew install sitegraft`) if the tool sees use
  beyond Marcel — out of scope for v1.
- `sitegraft prune` for `SITEGRAFT_STATE_DIR` retention (ADR 0004 — deliberately
  manual/YAGNI for v1, run directories are never auto-deleted).

## Done

- [x] **#83 — `wp-content/fonts/` is never synced.** `graft_fonts_sync`
      (`lib/graft.sh`) now syncs it alongside `graft_media_sync`, reading the
      real font directory from `wp_get_font_dir()` on both A and B (never
      hardcoded — the path is filterable via `font_dir`), same
      `--keep-existing` safety as media. A pre-6.5 A with no Font Library is
      a no-op, not an error; A having fonts while B cannot resolve one at all
      is a hard failure, not a silent drop. Also closes the issue's own
      detection half: `_graft_migrate_one_option_key` (shared by
      `graft_migrate_options`/`graft_migrate_post_type_defining_options`) now
      refuses to push a migrated option's value to B if it still contains
      A's raw domain string after the rewrite pass — the exact shape
      `etch_global_stylesheets` took on the pilot (see "Done by hand on the
      pilot target" in `docs/status.md`), caught inside `graft` itself
      rather than only by a separate `sitegraft verify` an operator might
      not run.
- [x] **`modules/acss.sh` (Automatic.css) — shipped.** The
      `TODO_VERIFY_LEGACY_ACSS_SLUG` blocker (the pre-4.0 plugin folder name) is
      closed: both folder names have now been observed on real installs on
      versions that bracket the rename — see `modules/acss.sh`'s own header for
      the evidence and for why the current name is ordered first.
- [x] Steps 1-5 (core/profiles/scan, manifest/plan, backup/restore, graft, verify)
      — merged to `main` as PRs #1-#5. See `git log --oneline` and each step's own
      commit/PR for detail; the full finding-by-finding history of the pre-Step-1
      plan review lives in `docs/plans/2026-08-19-sitegraft-plan-review.md`.
- [x] Step 6 (polish, this pass, 2026-08-20):
  - `--dry-run`/`--allow-stack-mismatch` audit across every writing phase; found
    and fixed two real gaps beyond what was already correct: a module
    `post_import` hook (`modules/core-wp.sh`) writing to B unconditionally,
    ignoring `--dry-run` entirely, and `bin/sitegraft` itself never handling
    `--dry-run` globally (only per-phase), which also surfaced a real bash 3.2
    `set -u`/empty-array bug in the fix (`./bin/sitegraft --help` was broken).
  - Durcissement: `_plan_prompt_items`' plain (no-gum/no-fzf) selection fallback
    used to default an unanswerable EOF prompt to "kept/migrate" — the least
    conservative of the two wrong answers. Now aborts the whole selection on EOF
    instead of guessing (tracked from Viktor's Step 2 review).
  - Self-review against the design doc found and fixed: `SITE_*_SSH_KEY`
    (design doc §5.2) parsed but never actually passed to `ssh -i`; a real,
    shipped `modules/etch.sh` never existed despite being fully spec'd in §3.3
    (created it); `modules/acss.sh` and the §5.2 interactive-creds-prompt
    confirmed as genuine, deliberate v1 gaps (documented above and in the design
    doc, not silently shipped as if resolved).
  - `docs/usage.md` added (full manual: install, profile setup, all six phases,
    module contract, security model); `README.md` brought back in sync with the
    real CLI and current v1 status (was still saying "implementation not
    started").
  - `SITEGRAFT_VERSION` bumped to `1.0.0-rc1` (not `1.0.0` — see the pre-`1.0.0`
    gate above).
  - **Fix-pack (same PR #6), after a double review (Kimi + Viktor):** fixed a
    BLOCKER (`graft --dry-run` wrote real resumability markers, so a real
    `graft` right after could silently skip the whole pipeline) and a MAJOR
    (`verify --dry-run` produced false HARD FAILs, mirrored `scan`'s own
    already-fixed version of the identical bug) plus smaller findings — see
    `docs/status.md` → "Step 6 fix-pack" for the full list.
    `SITEGRAFT_VERSION` bumped again to `1.0.0-rc2`.
