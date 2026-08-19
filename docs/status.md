# Status — sitegraft

**STATUS: idea**  <!-- idea → in progress → live/production → maintenance → archived -->
**Last updated: 2026-08-19** (via "update the project")

## Summary

The brainstorming session with Marcel is complete (13 decisions locked in, see
design doc §0). Rosalinde delivered the full design doc, a 6-step implementation
plan, the project skeleton, and the handoff documentation, then an independent
review of the plan (done by Kimi before Step 1 started) surfaced 7 concrete
plan-code defects and 3 scope gaps; Rosalinde resolved every one of them — the
plan was rewritten, the design doc gained two new sections plus several
clarifications, and the review file now carries a one-line resolution per
finding. No line of the tool's own code exists yet. Nothing blocks starting Step
1 of the (now-revised) plan, pending Marcel's validation of the 5 technical
decisions Rosalinde made alone (see "Recent decisions" below).

## Done

- [x] Full brainstorming session with Marcel (13 decisions locked in, out of scope to reopen)
- [x] Project skeleton created (`repo/` + `dist/` + `.credentials/`)
- [x] `PROJECT.md` + `docs/{idea,infrastructure,status,todo,definition-of-done}.md` written
- [x] Project `CLAUDE.md` adapted
- [x] Full design doc (`docs/superpowers/specs/2026-08-19-sitegraft-design.md`)
- [x] 6-step implementation plan (`docs/plans/2026-08-19-sitegraft-implementation.md`)
- [x] Design doc self-review (placeholders/contradictions/ambiguities)
- [x] ADRs for the open decisions (`docs/decisions/000x-*.md`)
- [x] Entire repo rewritten in US English for public release to the Etch community (2026-08-19)
- [x] Independent plan review (Kimi) done and every finding resolved: 7 plan-code
      defects (A1-A7 — missing options migration, non-self-contained `restore.sh`,
      missing wp-content backup, unhandled remote-A transfers, unstable
      mysqldump-timestamp checksums, unscoped search-replace, missing
      wordpress-importer provisioning), 3 scope gaps (B1 rendering-stack
      precondition, B2 classic-menu v1 assumption, B3 weak harness assertions),
      and a sequencing fix (C1 — DDEV harness built incrementally from Step 1, not
      as a Step 5 afterthought). Design doc gained §12 (stack precondition
      product decision) and §13 (classic-menu scope), plus clarifications in §6.1,
      §6.3, §6.4, §6.5, §9.1, §9.4. `docs/definition-of-done.md` gained a
      pre-`1.0.0` real-dry-run gate (item D). See
      `docs/plans/2026-08-19-sitegraft-plan-review.md` for the full
      finding-by-finding resolution log (2026-08-19, Rosalinde).
- [x] Marcel amended B1/B2 and added a third guardrail before Step 1 started
      (2026-08-19, Rosalinde): **B1 revised** — `plan` now offers to *copy* a
      missing/mismatched rendering-stack component from A (never installed from
      anywhere else), recorded in the manifest's new `stack` key, with the
      original refuse/`--allow-stack-mismatch` behavior kept only for whatever's
      declined; **B2 clarified** — design doc reworded so "block themes only"
      reads unambiguously as A-only, B running Divi/Elementor/Bricks/classic
      themes is the normal case, not a precondition; **new guardrail** —
      `scan` detects custom-code signals on B (child theme, `functions.php`,
      mu-plugins, snippet plugins) and `plan` blocks on any of them until an
      explicit acknowledgment, since replacing B's theme would otherwise
      silently drop that code. Design doc gained new §12 rewrite + new §14
      (self-review renumbered to §15); plan gained Tasks 1.6, 2.4, 2.5, and a
      revised Task 4.1. See `docs/plans/2026-08-19-sitegraft-plan-review.md` §E
      for the resolution notes.

## In progress

- [ ] Nothing — waiting on Marcel's go-ahead to start Step 1 of the revised implementation plan

## Blocked / pending

- Validation of the 5 technical decisions Rosalinde made alone (see below)
- Marcel's go-ahead to create the public GitHub repo (Nat handles that, not Rosalinde)

## Recent decisions

Technical decisions made alone during design, **to be validated by Marcel**
(detail and rationale in design doc §0 and the matching ADRs):
1. `jq` as a dependency to parse/write the manifest as JSON (structure nested by
   module × post_types/option_keys).
2. Targeted bash 3.2 portability (no associative arrays) rather than requiring
   bash ≥ 4 — so it runs unmodified on stock macOS.
3. Run state-dir location and retention: `~/.sitegraft/runs/<profile>-<timestamp>/`
   on the orchestrator, never cleaned up automatically (left to the operator).
4. Mapping mu-plugin delivered by dropping a file via `rsync` into
   `wp-content/mu-plugins/` (auto-loaded by WordPress, no wp-cli activation
   needed) rather than through a `wp plugin install` mechanism.
5. `bats-core` as the unit test framework for `lib/`'s pure functions.

Clarification received mid-task (already reflected everywhere): the repo will be
shared with the Etch community as a **public GitHub repo** under MarcelHeiniger —
consequences (zero secrets/realistic-looking examples, MIT LICENSE, the entire repo
in US English including internal docs) applied across every affected file.

Additional decisions made alone during the plan-review resolution pass (2026-08-19,
detail in the review file's resolution notes and design doc §12/§13): the
`--allow-stack-mismatch` override flag's exact confirmation UX (a distinct,
louder prompt than the usual `gum confirm`, not reusing it); `graft_content_tables_csv`
scoping search-replace to exactly `posts,postmeta,options` (not a wider or
narrower set); `SITEGRAFT_HARNESS_STOP_AFTER` as the mechanism for validating the
DDEV harness incrementally per step.
