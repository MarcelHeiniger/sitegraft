# Plan Review — sitegraft implementation plan (2026-08-19)

> **Status:** RESOLVED (2026-08-19) — every finding below (A1-A7, B1-B3, C1) was
> fixed in the plan and, where the design doc had drifted from it, in the design
> doc too. See each finding's **Resolution:** note. The rewritten plan supersedes
> the version this review was originally done against.
> **Reviewed documents:**
> `docs/superpowers/specs/2026-08-19-sitegraft-design.md` (the spec) and
> `docs/plans/2026-08-19-sitegraft-implementation.md` (the plan).
> **How to use this file:** resolve every finding below by updating the plan — and
> the design doc where the two have drifted — **before** starting Step 1 of the
> plan. Then record the outcome in `docs/status.md` and `docs/todo.md`.
>
> Note: the review itself found the planning quality high overall (measurable DoD,
> ADRs, explicit risks R1–R4, default-deny). The findings below are concrete defects
> and gaps, not a rejection of the approach.

---

## A. Bugs already embedded in the plan's code

These would break or silently misbehave if the plan were executed verbatim. The
plan is a **guide, not a bible** — but since it ships full code, these defects
would be transcribed by a literal executor.

### A1. The options-migration step is missing from `phase_graft`

- **Where:** design doc §6.4 step 8 vs. plan Task 4.4 (`phase_graft`).
- **Problem:** the design requires copying every manifest `option_keys` entry from
  A to B (`wp option get --format=json` on A, `wp option update --format=json` on
  B, with `page_on_front` handled specially per §9.3). The plan's `phase_graft`
  step list (media → mu-plugin → prune → export → import → fetch ID map → remap →
  hooks → clean) contains **no options step at all**. As written, the tool migrates
  content but never the Etch/ACSS settings — arguably the core of the design layer.
- **Fix:** add a `graft_migrate_options` step to `phase_graft` (marker-gated like
  the others), persisting each fetched option value into the run dir (e.g.
  `option-<key>.value`) so §9.3's `core_wp_post_import` has its input file — the
  plan currently reads `$state_dir/option-page_on_front.value` but **nothing ever
  writes it**.

**Resolution:** added `graft_migrate_options` (plan Task 4.4) as a marker-gated
`migrate_options` step in `phase_graft`, ordered after the remaps and before
`module_hooks` — it writes `option-<key>.value` for every migrated key (so
`core_wp_post_import` has its input file) and pushes every key except
`page_on_front`/`page_for_posts` straight to B.

### A2. `restore.sh` is not self-contained

- **Where:** plan Task 3.1 (`backup_generate_restore_script`) and Task 3.2.
- **Problem:** the generated `restore.sh` calls `wp_remote`, a bash function
  defined in `lib/inventory.sh`. Run standalone — which is the design's promise
  (design doc §6.3: "self-contained script … ready to run with no other context") —
  it fails with `command not found`. The same defect appears inside `phase_backup`
  itself: `run_or_echo bash -c "wp_remote b db export …"` invokes `wp_remote` in a
  subshell where the function is not defined (no `export -f`, and that wouldn't be
  bash-3.2/portable anyway).
- **Fix:** have the backup phase resolve the concrete ssh/wp command lines at
  generation time and bake **literal commands** (ssh host, `--path=`, gzip pipe)
  into `restore.sh`. Never reference sitegraft functions from generated artifacts.

**Resolution:** added `backup_wp_cmd_literal` (plan Task 3.1) to resolve a literal,
baked command prefix at generation time; `backup_generate_restore_script` now
writes only literal ssh/rsync/gzip/wp-cli invocations into `restore.sh` — it never
sources a sitegraft lib file or calls a sitegraft function. `phase_backup`'s own DB
export was also fixed to stop shelling out to `wp_remote` inside a `bash -c`
subshell where the function wasn't defined; it now uses the same literal-command
approach directly.

### A3. The wp-content files backup is missing

- **Where:** design doc §6.3 (DB export **and** `tar` of `wp-content`) vs. plan
  Task 3.1 (`phase_backup` only exports the DB; it writes a `.wp-content-path` file
  but never archives anything).
- **Problem:** the project DoD requires `restore.sh` to return B to its **exact**
  pre-graft state. Without a files backup, media uploaded by the graft and any
  changed files can never be rolled back.
- **Fix:** add the `wp-content` archive (pulled to the orchestrator) to
  `phase_backup`, and the matching restore step to `restore.sh`.

**Resolution:** added `backup_wp_content` (plan Task 3.1), an `rsync` pull of B's
`wp-content/` into `${run_dir}/backup/b-wp-content/`, called from `phase_backup`
alongside the DB export; `backup_generate_restore_script` now also emits an
`rsync --delete` restore step for the wp-content tree, ahead of the DB import.

### A4. Remote site A is not handled for file transfers

- **Where:** plan Task 4.1 (`graft_media_sync`) and Task 4.4 (`phase_graft`
  export/import wiring).
- **Problem:** `graft_media_sync` uses `${SITE_A_WP_PATH}/wp-content/uploads/` as a
  **local** rsync source — it breaks when A is behind SSH. Likewise the WXR export
  lands in a directory on A, then `wp_remote b import` is pointed at a path B
  cannot see. The design doc (§6.4 step 5) specifies two hops through the
  orchestrator; the plan never implements the A→orchestrator and
  orchestrator→B legs. The plan only works when both sites are local (DDEV) — i.e.
  only inside the test harness.
- **Fix:** route all A-sourced transfers through the run dir on the orchestrator
  (rsync A→orchestrator, then orchestrator→B), for both media and WXR files.

**Resolution:** `graft_media_sync` (plan Task 4.1) now pulls A's uploads into
`${run_dir}/media-staging/` first, then pushes from there to B — never A→B
directly. `graft_export_wxr`/`graft_import_wxr` (plan Task 4.2) got the same
treatment: the WXR export lands in `${run_dir}/export/` (via an intermediate
`rsync` hop when A is remote) before being pushed to B for import. Design doc §6.4
step 1 was updated to state the two-hop routing explicitly for media, matching
step 5's existing language for WXR.

### A5. Protected-data checksums are unstable (mysqldump timestamps)

- **Where:** plan Task 3.1 (`backup_checksum` over `wp db export` output) and Task
  5.1 (`verify` comparison); same pattern in the DDEV harness (Task 5.3).
- **Problem:** `wp db export` shells out to mysqldump, whose output embeds a
  "Dump completed on …" timestamp comment. Pre- and post-graft checksums will
  differ **even when the data is identical** — `verify` would hard-fail on a
  perfect run, and the harness's central assertion would be flaky.
- **Fix:** normalize before hashing: strip comment lines (or pass
  `--skip-comments` through to mysqldump), or hash sorted row content via
  `wp db query "SELECT * FROM <table> ORDER BY <pk>"` instead of raw dumps.
  Whatever the choice, the pre/post/harness checksum code paths must use the
  **same** normalization.

**Resolution:** `backup_checksum` (plan Task 3.1) now strips every line starting
with `-- ` (mysqldump's comment/timestamp lines) before hashing. This single
function is reused, unmodified, by `phase_backup`, `phase_verify`, and the DDEV
harness (which sources `lib/backup.sh` specifically to call it instead of piping
to `shasum` directly) — the three call sites share one implementation by
construction, so they cannot drift apart. Design doc §6.3 documents this as a
project-wide rule, not an implementation detail.

### A6. Search-replace runs across ALL tables, including protected ones

- **Where:** plan Task 4.3 (`graft_remap_attachment_ids`), Task 4.4
  (`graft_search_replace_domain`); design doc §9.1/§9.4.
- **Problem:** `wp search-replace` without `--tables=` scans every table with the
  site prefix — including tables owned by the protected plugin. The tool's core
  promise is "never touch B's protected data", but as written the remaps can
  modify protected tables directly; the failure would only be caught after the
  fact by `verify` (and only if A5 is fixed).
- **Fix:** scope every search-replace to the content tables it is meant to touch
  (`--tables=$wpdb->posts,postmeta,options,…` as appropriate), and keep protected
  tables explicitly out.

**Resolution:** added `graft_content_tables_csv` (plan Task 4.3), which resolves
B's live `$wpdb->prefix` and returns exactly
`{$prefix}posts,{$prefix}postmeta,{$prefix}options` — the only table scope any
`search-replace` call in the tool is allowed to use. `graft_remap_attachment_ids`
and `graft_search_replace_domain` both now take this CSV as a required parameter
and pass it as `--tables=`. Design doc §9.1/§9.4 code examples were updated to
show the same scoping.

### A7. `wordpress-importer` provisioning is missing from the plan

- **Where:** design doc §6.4 step 6 (install/activate the importer on B if absent,
  restore its exact prior state afterwards) vs. plan Task 4.4 (`phase_graft` calls
  `wp import` without ever ensuring the importer exists).
- **Fix:** add an importer check/install step (marker-gated), including the
  record-and-restore of B's pre-existing plugin state.

**Resolution:** added `graft_ensure_importer` (records B's pre-existing
install/active state to `.wordpress-importer-pre-state` before installing or
activating) and `graft_restore_importer_state` (reverses exactly that recorded
state afterward) — both wired into `phase_graft` as marker-gated
`importer_setup`/`importer_cleanup` steps (plan Task 4.2), bracketing the import
step.

---

## B. Missing scope

### B1. The design layer itself (theme / Etch / ACSS presence on B) is never checked

- **Where:** design doc §3 (module contract), §6.1 (scan); plan Step 1.
- **Problem:** sitegraft migrates content, options and media, but nothing verifies
  that B runs the same rendering stack as A (active theme, Etch, ACSS), and no
  module covers `stylesheet`/`template`. If B lacks Etch, the grafted content
  renders as nothing and the run still "succeeds".
- **Fix:** extend `scan` to record A's and B's active theme and plugin versions,
  and add a hard precondition in `plan`/`graft`: refuse (or loudly warn and require
  explicit confirmation) when B's rendering stack doesn't match A's. Whether
  sitegraft should ever *install* the stack on B stays a deliberate product
  decision — document it either way in the design doc.

**Resolution:** `scan` now records each site's active theme and every plugin's
version (plan Task 1.5, design doc §6.1). `inventory_stack_matches` compares theme
stylesheet + Etch/ACSS versions between A and B. `plan` warns loudly but never
blocks (`plan_warn_scope_gaps`, Task 2.2); `graft` treats a mismatch as a hard
precondition failure and refuses to start unless launched with an explicit
`--allow-stack-mismatch` flag, which still requires a loud, distinct confirmation
prompt before proceeding (`graft_check_stack_precondition`, Task 4.1). The product
decision — sitegraft never installs the stack on B, that stays out of scope
deliberately — is documented as new design doc §12.

### B2. Classic menus are unaddressed

- **Where:** design doc §0 point 11 / §6.1 cover block navigation
  (`wp_navigation`, dynamic `wp:page-list`); `nav_menu` / `nav_menu_item` appear
  nowhere.
- **Fix:** either add classic-menu post types/taxonomies to the `core-wp` module,
  or document "block themes only" as an explicit v1 assumption in the design doc
  and in `scan`'s output.

**Resolution:** documented as an explicit v1 assumption — new design doc §13
("Navigation scope: block themes only in v1"), with the rationale (Etch is
block-theme/FSE-first; classic menus need theme-location knowledge a generic core
feature can't have) and a note that a `modules/classic-menus.sh` is a plausible
future module, not attempted now (YAGNI). `scan` detects classic menus with items
on A (`wp menu list`, plan Task 1.5) and `plan` surfaces a warning
(`plan_warn_scope_gaps`, Task 2.2) — no silent drop.

### B3. The DDEV harness's positive assertions are too weak

- **Where:** plan Task 5.3 / design doc §10 step 7.
- **Problem:** the harness asserts (1) protected data unchanged and (2) one
  migrated post exists on B. It would **pass** with A1 unfixed (options never
  migrated), with the domain remap broken, or with `page_on_front` pointing at a
  wrong ID.
- **Fix:** extend the harness to assert: migrated options present with the right
  values on B (e.g. the seeded `etch_settings`), `page_on_front` remapped to a
  valid page on B, the A-domain string absent from imported content, and — already
  planned — protected data byte-identical pre/post graft **and** post restore.

**Resolution:** the harness (plan Task 5.2) now asserts, after `graft`: A's
migrated content is present and rendered, `etch_settings` carries A's exact seeded
value, `page_on_front` resolves to B's own "Home" page (not merely *some* page —
the fixture seed now sets and tracks the front page explicitly, Task 1.4), and a
`wp db query` confirms zero rows still containing A's domain string. `verify`
itself (Task 5.1) grew matching checks (`verify_options_match`,
`verify_domain_absent`, a tightened `page_on_front` check) so the same guarantees
hold outside the harness too, not only inside it.

---

## C. Sequencing recommendation

### C1. Build the DDEV harness skeleton before the risky phases, not in Step 5

- **Where:** plan structure (harness = Task 5.2/5.3, after backup/graft are
  written).
- **Problem:** the riskiest code (`backup`, `graft`) is written in Steps 3–4 but
  only meets a real WordPress install in Step 5. Task 5.3 step 2 already budgets
  for "fix whatever the first real run surfaces" — a big-bang debugging session is
  the expected outcome.
- **Fix:** deliver a minimal harness (spin up two DDEV sites, seed fixtures, tear
  down) as part of **Step 1**, and grow its assertions as each phase lands
  (`scan` → fixture visible in `scan-*.json`; `backup` → files exist and checksum
  stable; `graft` → full assertions from B3). Each phase then gets integration
  feedback immediately instead of at the end.

**Resolution:** the plan was restructured exactly as recommended. Task 1.4 (Step 1)
now delivers the harness skeleton and both fixtures — spin up, seed, teardown, no
sitegraft phases yet. Task 1.5 adds the `scan` call and asserts the fixtures are
visible in `scan-*.json`. Task 3.2 (Step 3) adds `plan`+`backup` and asserts the
backup files exist and the checksum is stable. Task 5.2 (Step 5) completes the
harness with `graft`/`verify`/`restore` and the full B3 assertion set. A
`SITEGRAFT_HARNESS_STOP_AFTER` env var (`seed`/`scan`/`backup`) lets each task
validate its own increment without needing later phases to exist yet — no single
task has to write or debug the whole harness at once.

---

## D. Out of scope of this review (already handled well)

- R1–R4 in the design doc §0.2 remain valid and honest — especially R2/R4: the
  first run against real Etch content stays a moment of truth. Consider a
  documented "first real dry-run on a staging copy of a genuine A/B pair" as a
  pre-v1.0.0 checklist item to close that gap deliberately.
- The 5 open technical decisions (status.md → Recent decisions) still await
  Marcel's validation; this review does not revisit them.

**Resolution:** added "first real dry-run on a staging copy of a genuine A/B pair"
as an explicit pre-v1.0.0 checklist item in `docs/definition-of-done.md`, gating
the `1.0.0` version tag specifically (Task 6.3 of the plan bumps to `1.0.0-rc1`,
not `1.0.0`, until this item is checked). This deliberately does not get satisfied
by more DDEV-only testing — it is the moment R2 and R4 (design doc §0.2) actually
get closed, not merely re-flagged. The 5 open technical decisions remain
unrevisited here, as instructed — they're a separate approval track from this
plan-review pass.
