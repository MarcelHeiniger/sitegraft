# Status — sitegraft

**STATUS: idea**  <!-- idea → in progress → live/production → maintenance → archived -->
**Last updated: 2026-08-19** (via "update the project")

## Summary

The brainstorming session with Marcel is complete (13 decisions locked in, see
design doc §0). Rosalinde delivered the full design doc, a 6-step implementation
plan, the project skeleton, and the handoff documentation. No line of the tool's own
code exists yet. Nothing blocks starting Step 1 of the plan, pending Marcel's
validation of the 5 technical decisions Rosalinde made alone (see "Recent
decisions" below) and the clarification received mid-task about the repo's public
visibility (already reflected across all docs).

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

## In progress

- [ ] Nothing — waiting on Marcel's go-ahead to start Step 1 of the implementation plan

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
