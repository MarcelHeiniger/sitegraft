# Status — sitegraft

**STATUS: in progress**  <!-- idea → in progress → live/production → maintenance → archived -->
**Last updated: 2026-08-20** (Step 6 self-review)

## Summary

All 6 steps of the implementation plan are done. `main` has scan, plan, backup,
graft, verify, and restore fully implemented, unit-tested (`bats`), and exercised
end-to-end by the DDEV integration harness. This Step 6 pass (polish) audited
`--dry-run`/`--allow-stack-mismatch` consistency across every writing phase, closed
an EOF-defaults-to-migrate durcissement flagged (non-blocking) back in the Step 2
review, ran a full design-doc-vs-code self-review, and wrote the public-facing
usage docs. PR #6 (Step 6) then went through a double review (Kimi + Viktor); a
fix-pack on the same PR closed 2 blocking findings and several smaller ones (see
"Step 6 fix-pack" below). `SITEGRAFT_VERSION` is `1.0.0-rc2` — the one thing still
blocking a plain `1.0.0` tag is the pre-`1.0.0` DoD gate (a real dry run against a
genuine A/B pair), which is deliberately **not** satisfiable by more DDEV-only
work; see `docs/definition-of-done.md`.

## Done

- [x] Full brainstorming session with Marcel (13 decisions locked in, out of scope to reopen)
- [x] Project skeleton, `PROJECT.md` + `docs/*.md`, design doc, 6-step implementation
      plan, ADRs — all delivered 2026-08-19 before Step 1 started
- [x] Independent plan review (Kimi) resolved: 7 plan-code defects + 3 scope gaps,
      see `docs/plans/2026-08-19-sitegraft-plan-review.md` for the finding-by-finding log
- [x] **Step 1** — core (`lib/core.sh`: logging, dry-run, temp/trap handling),
      profiles + credentials (`lib/profile.sh`), `scan` (`lib/inventory.sh`), the
      module registry (`lib/modules.sh`), and the DDEV harness skeleton. Merged as PR #1.
- [x] **Step 2** — manifest format (`lib/manifest.sh`), interactive `plan`
      (`lib/plan.sh`): item selection via `gum choose`/`fzf`/plain-text fallback,
      rendering-stack resolution, the custom-code awareness gate, default-deny
      computation. Merged as PR #2.
- [x] **Step 3** — `backup` + `restore` (`lib/backup.sh`): full DB + wp-content
      export/import, checksums of protected data, a genuinely self-contained
      generated `restore.sh`. Merged as PR #3.
- [x] **Step 4** — `graft` (`lib/graft.sh`): rendering-stack sync + hard
      precondition, media sync routed through the orchestrator, WXR export/import,
      `wordpress-importer` provisioning, the mapping mu-plugin
      (`mu-plugins/sitegraft-id-mapper.php`), ID/domain remaps, options migration,
      idempotent-reimport pruning. Merged as PR #4.
- [x] **Step 5** — `verify` (`lib/verify.sh`): protected-checksum comparison,
      migrated-option/`page_on_front`/domain-absence checks, orphan-`post_parent`
      warning, an optional HTTP smoke check — plus the full DDEV harness assertion
      set tying every phase together in one real run. Merged as PR #5.
- [x] **Step 6 (this pass, 2026-08-20)** — polish:
  - **Task 6.1** (`--dry-run`/`--allow-stack-mismatch` audit): grepped every
    mutating call across `lib/*.sh` for `run_or_echo` coverage — found and fixed
    two real gaps the grep-only pass wouldn't have caught on its own:
    `modules/core-wp.sh`'s `core_wp_post_import` wrote to B unconditionally
    (module `post_import` hooks run regardless of `--dry-run`, and this one
    never routed its write through `run_or_echo`); `bin/sitegraft` never had
    global `--dry-run` handling (each phase parsed its own, but `plan` — which
    never needed one — rejected the flag as "unknown"). Fixing the second one
    surfaced a real bash 3.2 bug: `"${args[@]}"` on an empty array is an
    "unbound variable" under `set -u` on bash 3.2 (fixed in 4.4) — silently
    broke `./bin/sitegraft --help`/`-h`/`--version` until caught by a new test
    file (`tests/unit/test_bin_sitegraft.bats`, the first to exercise the real
    executable as a subprocess rather than loading `lib/*.sh` functions directly).
  - **Durcissement** (tracked from Viktor's Step 2 review, non-blocking then):
    `_plan_prompt_items`' plain (no-gum/no-fzf) fallback used `${ans:-y}` for its
    `[Y/n]` default, which couldn't distinguish a real Enter keystroke (safe:
    `read` returns 0) from stdin hitting genuine EOF (`read` returns non-zero) —
    an unattended/no-TTY invocation silently defaulted to "keep/migrate", the
    least conservative of the two wrong answers. Fixed to abort the whole
    selection on EOF instead of guessing, with no manifest ever frozen from it;
    the normal interactive Enter-keystroke default is unchanged.
  - **Self-review against the design doc** found three real drifts:
    `SITE_*_SSH_KEY` (§5.2) was parsed/whitelisted but never actually passed to
    `ssh -i` (fixed); `modules/etch.sh` was fully spec'd in §3.3 but never
    created as a real file, meaning a real Etch site never got auto-detected
    into `plan`'s defaults (fixed — created it, content unchanged from the
    design doc, plus one small addition (`etch_stack_candidates`) flagged in
    the PR as a judgment call); `modules/acss.sh` (§3.4) and the §5.2
    interactive-credentials-prompt are confirmed genuine, deliberate v1 gaps
    — documented in the design doc and `docs/todo.md` rather than rushed or
    silently left inconsistent. `docs/definition-of-done.md`'s "3 v1 modules"
    line corrected to reflect 2 shipped (`core-wp`, `etch`).
  - `docs/usage.md` written (install, profile setup, all six phases with exact
    flags, the module contract including the dry-run requirement for
    `post_import` hooks, the security model). `README.md` resynced with the
    real CLI (was still describing `ddev wp` as the DDEV wrapper — wrong per
    §5.1's own correction — and claiming "implementation not started").
  - `SITEGRAFT_VERSION` bumped `0.5.1` → `1.0.0-rc1`.
  - Full `bats tests/unit/` suite green throughout (grew from 283 to 300+ tests
    across this pass); DDEV harness re-run at the end of the pass — see the PR
    report for its exit status.
- [x] **Step 6 fix-pack (same PR #6, 2026-08-20)** — after a double review
  (Kimi: not mergeable; Viktor: mergeable but with a required in-PR fix):
  - **BLOCKER (both reviewers, reproduced live by Viktor):**
    `graft_mark_step` (`lib/graft.sh`) wrote its `graft.<step>.done` marker
    unconditionally, dry-run or not — a `graft --dry-run` against a run
    directory wrote every marker for real, so a REAL `graft` against that
    SAME run directory right after saw every step as already done and
    silently skipped the whole pipeline (reported "graft complete" without
    migrating anything). Fixed by guarding the one shared function every
    call site goes through; added both a fast unit-level regression test and
    a new DDEV harness assertion (`graft --dry-run` first, assert no marker
    files, then the real graft that follows, whose existing assertions only
    pass if it actually did the work).
  - **MAJOR-A (Viktor):** `phase_verify` (`lib/verify.sh`) set
    `SITEGRAFT_DRY_RUN=1` for `--dry-run` and never reset it (unlike
    `phase_scan`'s own identical-shape M6 fix) — every read in `verify` goes
    through `wp_remote`/`run_or_echo`, so under dry-run every check parsed
    `"[dry-run] ..."` text instead of real data and reported a false HARD
    FAIL on a graft that actually succeeded. Fixed with the same
    scan-style neutralization; `docs/usage.md`'s incorrect "no-op on verify"
    claim corrected too.
  - **MINOR-C (Viktor):** `<mod>_option_keys_exclude` is declared in the
    module contract and implemented by `modules/etch.sh`, but nothing in
    `lib/`/`bin/` ever reads it — inert. Documented as NOT WIRED (design doc
    §3.2/§3.3, `modules/_template.sh`, `modules/etch.sh`) rather than wired
    up unreviewed this late, per the reviewers' own stated default.
  - **NITs:** `sitegraft --dry-run graft` (flag before the phase name) used
    to read "--dry-run" as the phase itself and fail with a confusing
    "unknown phase" error — fixed to strip `--dry-run` from the whole argv
    before the phase is read. Design doc §9.1/§9.4 had their superseded,
    copy-pasteable `wp search-replace --tables=...postmeta,options` sample
    commands actually removed (not just annotated) — the exact shape of the
    MAJOR-2 data-corruption bug they described could otherwise still be
    copy-pasted into a future implementation. `phase_restore`'s `--dry-run`
    log message claimed the pre-restore safety snapshot is "still taken for
    real" — it isn't (same `run_or_echo` gating as everything else); message
    corrected, behavior was already correct.
  - `SITEGRAFT_VERSION` bumped `1.0.0-rc1` → `1.0.0-rc2`.
  - `bats tests/unit/` green (310 tests); DDEV harness re-run live — see the
    PR report for its exit status and the new dry-run-marker assertion.

## In progress

- [ ] Nothing — Step 6 PR (with the fix-pack applied) ready for review/merge.

## Blocked / pending

- **Pre-`1.0.0` gate**: a real dry run against a staging copy of a genuine A/B
  pair (design doc §0.2's R2/R4) — Marcel's call, on a real pair, not something
  any further DDEV-only work can close. See `docs/definition-of-done.md`.
- `modules/acss.sh`: needs someone with a real pre-4.0 Automatic.css install to
  confirm the legacy plugin-folder name before it can ship (see `docs/todo.md`).

## Recent decisions

Technical decisions from the original design (§0.1/§0.2 of the design doc) are
long since validated by the fact that Steps 1-6 were built on them without
reopening any of the five. Additional decisions made during Step 6 (detail in each
commit's own message and the design doc's inline status notes):
- Added `bin/sitegraft`'s global `--dry-run` handling alongside (not instead of)
  every phase's own per-flag parsing — the per-phase parsing stays load-bearing
  for the unit tests, which call `phase_*` functions directly.
- `modules/etch.sh` created for real from the design doc's own §3.3 content, plus
  one addition beyond that verbatim block (`etch_stack_candidates`) — flagged in
  the Step 6 PR report for a second look rather than treated as an obviously-safe
  unilateral call.
- `modules/acss.sh` deliberately NOT created — its own design doc spec (§3.4)
  already instructs not to guess the unverified legacy ACSS slug, and Step 6 is
  a polish pass, not the place to do that real-world verification.
