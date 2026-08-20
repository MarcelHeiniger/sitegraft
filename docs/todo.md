# Todo — sitegraft

> Current backlog. Prioritized. Reflects the live state after Step 6 (polish).
> **Last sync: 2026-08-20**

## Next steps (priority)

- [ ] **Pre-`1.0.0` gate:** a real dry run against a staging copy of a genuine A/B
      pair, closing design doc §0.2's R2/R4 — see `docs/definition-of-done.md`.
      Not satisfiable by more DDEV-only testing. This is the one thing standing
      between the current `1.0.0-rc1` tag and a plain `1.0.0` — Marcel's call, on
      a real pair, not something Step 6 (or any DDEV-only work) can close.
- [ ] Review/merge the Step 6 PR (dry-run + stack-override audit, EOF durcissement
      on the plain selection fallback, `docs/usage.md`, LICENSE/README already in
      place, version bumped to `1.0.0-rc1`).

## Backlog

- [ ] **`modules/acss.sh` (Automatic.css) — not shipped.** Spec'd in full in the
      design doc §3.4, but its own `TODO_VERIFY_LEGACY_ACSS_SLUG` blocker (the
      pre-4.0 Automatic.css plugin folder name) has never been checked against a
      real install — shipping a guessed slug would violate that section's own
      explicit instruction. Needs someone with a real pre-4.0 ACSS site to confirm
      the folder name, then the module is otherwise ready to create verbatim from
      the design doc.
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
