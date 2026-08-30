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
- [ ] **Every `ssh` call in this repo is missing `-o BatchMode=yes -o
      ConnectTimeout=<n>`.** Pre-existing, not introduced by #83's fix-pack —
      noted while adding `ssh_test_dir_rc` (`lib/inventory.sh`), which is a
      probe run mid-graft and inherits the same gap: without `BatchMode=yes`,
      a host whose key auth fails can fall back to an interactive password
      prompt, which blocks a run this tool otherwise treats as fully
      unattended; without a `ConnectTimeout`, an unreachable host hangs on
      the OS's own TCP timeout instead of failing promptly. Worth fixing
      once, for every `ssh` invocation in the codebase, not piecemeal per
      call site.

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
      (`lib/graft.sh`) syncs it alongside `graft_media_sync`, reading the
      real font directory from `wp_get_font_dir()` on both A and B (never
      hardcoded — the path is filterable via `font_dir`), same
      `--keep-existing` safety as media. `wp_get_font_dir()` COMPUTES/
      FILTERS the path; it does not CREATE the directory (that only
      happens on WordPress's own first real font upload), so a non-empty
      path with nothing on disk yet is the ORDINARY case for any A that
      has simply never used the Font Library.

      The ssh-remote pull branch went through TWO review rounds to get
      this right. Round 1: the branch had no existence check at all and
      aborted the whole graft on the routine rsync-against-absent-source
      exit 23. Round 2, on the fix for round 1: the existence probe
      (`graft_ssh_path_exists`) collapsed EVERY non-zero ssh exit into
      "absent, nothing to pull" — including ssh's own connection/auth
      failure code (255), which meant a dedicated `SITE_A_SSH_KEY` profile
      whose ssh connection genuinely failed skipped the sync SILENTLY,
      marked the step done, and reported the graft a success, never
      retrying on resume (before issue #83 existed at all, that same
      profile failed LOUDLY at rsync instead — round 1's own fix had
      turned a noisy failure into a silent false success). Fixed by making
      the probe three-valued (exists / confirmed absent / could not
      determine) via a shared `ssh_test_dir_rc` helper
      (`lib/inventory.sh`, factored out of `inventory_check_path_topology`'s
      own pre-existing probe so `SITE_<ALIAS>_SSH_KEY` handling, issue
      #75, cannot drift between the two again) — "could not determine" is
      now a hard failure, never a no-op. Both rounds mutation-tested. A
      having fonts while B cannot resolve a Font Library directory of its
      own at all is, separately, also a hard failure, not a silent drop.

      Known, deliberate gap, not built here: this syncs the FILES only.
      Core WordPress 6.5's Font Library also registers
      `wp_font_face`/`wp_font_family` posts in the database, and no
      module migrates those — on a site that genuinely uses core's Font
      Library admin UI (not Etch, which references font files by URL
      from its own CSS option and never touches these post types), B
      would receive the files with no post pointing at them. YAGNI until
      a real site needs it; noted so it is never silently assumed solved.

      Also addresses — not "closes"; see the scope note below — the
      issue's own detection half: `_graft_migrate_one_option_key` (shared
      by `graft_migrate_options`/
      `graft_migrate_post_type_defining_options`) now WARNS (`log_warn`,
      does NOT refuse the push) when a migrated OPTION's value still
      appears to reference A's domain after the rewrite pass. Widened on
      review to a case-insensitive, scheme-agnostic (`http`/`https`/
      protocol-relative `//host`) raw-byte search — what actually catches
      the pilot's own `etch_global_stylesheets` shape (a JSON blob stored
      AS A STRING, double-escaped by `wp option get --format=json` in a
      way the rewrite's exact-substring match cannot parse; proven with a
      real `php json_encode()` fixture in `tests/unit/test_graft_options.bats`,
      not a fabricated string `--format=json` never produces; remeasured
      by review against all 6 realistic forms — case, scheme,
      protocol-relative, the JSON-blob-in-a-string shape, and two more —
      6/6 caught, none refused). Downgraded from an earlier hard refusal:
      no flag anywhere in this CLI can skip a single option key, this step
      runs AFTER the WXR import, so a refusal abandons a half-migrated B
      and every resume repeats the identical refusal — not a practicable
      remedy mid-migration.

      Second review round also found the widened check false-positiving
      SYSTEMATICALLY (every key, every run, not occasionally) on the
      apex/www migration shape ("example.com" -> "www.example.com"),
      where A's host is a literal substring of B's own — a value the
      rewrite corrected perfectly still triggered the warning, because
      B's own new host still contains A's old one. Fixed by stripping
      every occurrence of B's own (scheme-stripped) host from the value
      before searching for A's; verified both directions (a clean rewrite
      of that shape no longer warns, a genuine leftover reference still
      does).

      Scope, stated precisely so this is not overclaimed: OPTION VALUES
      only, a heuristic substring search, and does not touch post CONTENT
      at all — #88's own class below (block-attribute id rewrites inside
      WXR-imported post content matching only the compact JSON form) is a
      completely separate mechanism and remains open, unaffected by this
      fix. `verify_domain_absent` (`lib/verify.sh`) remains the second,
      independent check, covering both options and post content, via a
      separate `sitegraft verify` run. What this check still cannot see:
      a deliberately over-encoded value (percent-encoding/HTML entities
      CAN alter any byte, including a hostname's own letters — measured;
      an earlier draft of this same entry overclaimed that they could
      not) — what IS true is that no conventional WordPress/PHP encoder
      (`rawurlencode()`, `esc_url()`, `htmlspecialchars()`) touches an
      unreserved character, so the forms those actually produce are still
      caught; a hand-crafted, non-conventionally-encoded value is not, and
      was never this check's claimed scope.
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
