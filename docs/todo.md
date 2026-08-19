# Todo — sitegraft

> Current backlog. Prioritized. Reflects the live state (task API) after each
> "update the project".
> **Last sync: 2026-08-19**

## Next steps (priority)

- [ ] Marcel's go-ahead on the 5 open technical decisions (`docs/status.md` →
      Recent decisions)
- [ ] Start plan Step 1: core + profiles/credentials + scan + DDEV harness skeleton
      (`docs/plans/2026-08-19-sitegraft-implementation.md`)
- [ ] Step 2: manifest + interactive selection (`gum choose`, fallback `fzf`) +
      rendering-stack/classic-menu warnings
- [ ] Step 3: backup (DB + wp-content) + restore, with a genuinely self-contained
      `restore.sh`
- [ ] Step 4: graft — rendering-stack hard precondition, media/WXR routed through
      the orchestrator, `wordpress-importer` provisioning, scoped remaps, options
      migration
- [ ] Step 5: verify + the full DDEV harness assertion set (migrated options,
      `page_on_front`, domain absence, protected-data checksums)
- [ ] Step 6: polish (dry-run + stack-override audit, `docs/usage.md`, LICENSE,
      public README) — bump to `1.0.0-rc1`, not `1.0.0`

## Backlog

- [ ] The hypothetical `motopress.sh` module — written as a worked example in the
      design doc, not yet implemented or tested against a real MotoPress install
- [ ] A possible `modules/classic-menus.sh` — v1 explicitly does not migrate
      classic nav menu assignments (design doc §13); `scan` detects and warns,
      nothing more. Revisit only if a real project needs it.
- [ ] A detailed `docs/usage.md` (beyond the README) if the README grows too long
- [ ] An install script (`install.sh` or Homebrew/apt instructions for the
      dependencies: `jq`, `gum`, `rsync`, `bats-core`)
- [ ] **Pre-`1.0.0` gate:** a real dry run against a staging copy of a genuine A/B
      pair, closing design doc R2/R4 — see `docs/definition-of-done.md`. Not
      satisfiable by more DDEV-only testing.

## Ideas / later

- Support a "diff report" output mode for `verify` (HTML or markdown) — YAGNI for
  v1, revisit once the tool has been used on a real run
- Possible Homebrew publication (`brew install sitegraft`) if the tool sees use
  beyond Marcel — out of scope for v1

## Recently done

- [x] Design doc + implementation plan + skeleton delivered (2026-08-19, Rosalinde)
- [x] Full repo rewritten in US English for public release (2026-08-19, Rosalinde)
- [x] Independent plan review (Kimi) resolved: 7 plan-code defects (A1-A7) and 3
      scope gaps (B1-B3) fixed across the plan and the design doc, plan
      restructured to build the DDEV harness incrementally from Step 1 (C1), a
      pre-`1.0.0` real-dry-run gate added to the DoD (D) — see
      `docs/plans/2026-08-19-sitegraft-plan-review.md` for the finding-by-finding
      resolution log (2026-08-19, Rosalinde)
