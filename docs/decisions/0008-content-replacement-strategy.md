# ADR 0008 — How `graft` replaces content that already exists on B

**Date:** 2026-08-23 · **Status:** proposed (Petra's decision, pending Marcel's
validation — see issue #10, which asks for exactly this: an explicit, documented
choice rather than an implied one)

## Context

`graft` migrates content by exporting a WXR from A and importing it on B
(design doc §6.4 steps 3–7). `wordpress-importer` **inserts**. For each item it
first runs WordPress's own `post_exists( post_title, '', post_date )`; on a match
of the same post type it prints `already exists` and moves on, having written
nothing. It also never fires `wp_import_insert_post` for that item, so the
mapping mu-plugin (§7) logs no row — which means every downstream remap that
reads `id-map.tsv` (attachment IDs inside content, `_thumbnail_id`,
`page_on_front`, every module `post_import` hook) silently has nothing to do.

On the first real run: 153 items in the WXR, **40 imported, 113 skipped**, every
page among the skipped. B received A's theme, components and templates while
keeping its own content — its front page stayed at the 5 722 bytes it already
had instead of A's 35 882 bytes of Etch markup. `verify` returned **PASS**,
because not one of its checks compares the *content* of a migrated post against
its source (see `lib/verify.sh`: protected checksums, migrated option values,
domain absence, `page_on_front` resolution, orphan parents, nav presence, HTTP
smoke — all of which are satisfied by a graft that migrated no content at all).

**This is the normal case, not an edge case.** These redesigns are built by
cloning the client's production site and rebuilding on the copy, so A and B
descend from one database and share GUIDs, titles, dates and post IDs — on the
reference pair, A's front page and B's front page were *both* ID 16. Every page
collides, so nothing lands.

The inverse case is no better. A source built from scratch collides with
nothing, so its pages import *alongside* B's, `post_name` gets an automatic `-2`
suffix, and `page_on_front` still points at B's old page. Either way, "replace
the design layer" does not happen for content that already exists on B.

Two constraints frame every option below:

- **Default-deny (design doc §3.6).** Anything detected on B and not claimed by
  a module is protected and is never migrated or wiped without an explicit
  manifest selection. B is a **live** site carrying business-plugin data.
- **"Never report success you have not earned" (CLAUDE.md, first rule).** The
  defect above is that rule's signature failure: the safety mechanism ran, and
  its bookkeeping lied. Any option is judged first on what it does on a live
  target when it goes wrong, not on elegance.

## Options considered

### Option 1 — Delete B's targeted content before importing (the `clean` step)

Delete B's pre-existing posts of the migrated post types (§6.6's `clean`,
speced, not implemented; `graft` refuses loudly today if
`manifest.clean.enabled` is set by hand), then import into an empty field. No
collisions, every item inserts, `id-map.tsv` is complete, every existing remap
works unchanged, `page_on_front` remaps correctly. B ends up as a faithful copy
of A for those post types — **including A's slugs, hierarchy and menu order**,
which is the one thing the other two options do not give.

- **Live failure mode — the worst of the three.** It destroys before it knows
  the replacement will land. Between the delete and a successful import, a live
  site has no pages: 404s for real visitors, and any interruption in that window
  (dropped SSH hop, PHP fatal, importer timeout, the orchestrator sleeping)
  leaves B **empty**, recoverable only by a full `restore` — which also rolls
  back everything B's business plugins wrote during the run (orders, bookings,
  form entries taken while the graft was in flight). In practice this converts
  sitegraft from "grafts onto a live target" into "grafts onto a target you take
  offline first". That is a product decision, not an implementation detail.
- **Note that a soft delete does not work.** `post_exists()` filters on title,
  date and type, with no post-status filter — a *trashed* post still matches, so
  the importer would still print `already exists`. To defeat the collision the
  delete has to be `wp post delete --force`. There is no reversible form of this
  option at the WXR level.
- **What it does to data B has and A does not.** The most damage of the three.
  `--force` takes the post's comments, its full postmeta (including meta written
  onto those pages by B's own plugins — SEO records, translation links, form or
  membership configuration), its revisions and its term relationships. Every row
  in a *protected* third-party table that references one of those post IDs is
  left dangling, and default-deny correctly forbids sitegraft from fixing them.
  The protected tables stay byte-identical, so `verify`'s checksum check passes
  — **precisely while the thing it protects is being hollowed out.** Same class
  of defect as the one this ADR exists to fix.
- **Interrupted mid-run.** `graft`'s resumability markers are per-step and
  coarse. If `clean` completes and `import` is interrupted halfway, a resume
  skips `clean` (marker present) and re-runs `import` from the top — the items
  inserted by the first attempt now collide with themselves and are skipped and
  left unmapped, reproducing issue #10 inside the fix. Note the same hazard
  already exists for `prune`, which runs before `import` and is marker-gated the
  same way.
- **What it demands of `backup`/`restore`.** More than exists today.
  `backup.complete` is a marker and `backup_verify_db_export` checks gzip
  validity, a size floor and a non-empty `wp-content` — a sanity check, not
  evidence that the dump restores. Deleting a live site's pages on the strength
  of an unrehearsed backup is not defensible. It also inherits the documented
  wrapped-local caveat (overwrite-only restore, no deletions), and the "restore
  discards concurrent business writes" problem above.
- **Interaction with default-deny.** It needs the strictest possible framing:
  `clean.post_types` must stay an explicit subset of `migrate`, selected in its
  own pass, never implied by "migrate this post type". Today selecting `page`
  means "copy A's pages onto B"; it must never silently come to also mean
  "delete B's".
- **How `verify` proves it.** Easily: for each migrated post type, B's count
  equals A's *and* every post of that type carries `_sitegraft_source_id`. Plus
  the content check described under "Required regardless" below.
- **Cost.** The deletion loop is small (it is `graft_prune_previous_run` with a
  different selector). The real cost is everything around it: a separate `plan`
  selection, a typed confirmation, a restore-rehearsal gate, and fixing the
  resume ordering. Call it moderate code, high safety work.

### Option 2 — Import, then repoint: swap slugs and the front-page trio, trash the old

- **It does not work as written on the case that motivates it.** In the
  shared-origin case the importer skips the colliding items, so there are no new
  posts to repoint. To make them insert you must first defeat `post_exists()` —
  either by mutating B's existing posts (title or date) so the check misses, or
  by rewriting the WXR on the orchestrator. So this option is not "a
  non-destructive import followed by a swap"; it is **mutate B's live rows,
  import, swap, trash** — it pays a destructive write before it starts.
- **Live failure mode.** Two windows instead of one. After the import, B is live
  serving duplicates — two of every page, the new ones carrying `-2` slugs,
  visible to visitors, crawlers and any cache or CDN in front. Then the swap
  itself is hundreds of `wp_update_post` calls, each firing `save_post` on every
  plugin B runs (SEO regeneration, cache purges, translation sync, revision
  creation). An interruption mid-swap leaves half the site pointing at new
  content and half at old, with suffixed slugs on both sides and no marker
  saying which set is authoritative — unless the tool first wrote a durable
  per-post journal (old ID, old slug, new ID, new slug, action) to the run dir.
  That journal is real, non-trivial work that neither other option needs.
- **What it does to data B has and A does not.** Its strength, and its trap.
  Nothing is force-deleted, so comments, meta and revisions survive and the old
  rows remain reversible. But every third-party reference still points at the
  **old** post, now in the trash, and nothing points at the new one — a plugin
  holding "page 16 is the checkout page" is now aimed at a trashed page.
  Repointing them is exactly what default-deny forbids sitegraft from doing on
  its own. The result: the site's own navigation looks correct while integrations
  quietly aim at trash, surfacing days later. **The least loud failure mode of
  the three, which on a client site makes it the most dangerous.**
- **Interaction with default-deny.** It writes to rows B owns and the operator
  never selected — renaming a live page is not a side effect "migrate page" can
  be read as authorizing. It would need its own manifest key and its own
  confirmation, at which point it is no cheaper to authorize than option 1.
- **How `verify` proves it.** Hardest of the three: B legitimately holds both
  sets, so counts prove nothing. The check has to resolve each canonical slug
  and the front page to a post and compare *that* post's content to A's — i.e.
  the same content check the other options need, plus assertions that the old
  set is trashed and no `-2` duplicate is still reachable.
- **Cost.** Highest. Collision-defeat mechanism + rename pass + import + swap
  pass + per-post journal + resume semantics + the hardest `verify`.

### Option 3 — Graft in place: for items present on both sides, write A's content onto B's existing row

Build an explicit A→B correspondence for items present on both sides — GUID
equality first (exact and free in the shared-origin case), then slug + post
type, and **never** a fuzzy title match applied silently; anything not matched
mechanically is an operator decision, surfaced and frozen like every other
manifest choice. Then, for each frozen pair, write A's `post_content`,
`post_excerpt`, `post_title` and the **module-declared** meta keys onto B's
existing post, and add the pair to `id-map.tsv` so every remap already in the
codebase (attachment IDs in content, featured images, domain search-replace,
module `post_import` hooks) works unchanged. Items only on A still go through
the WXR import; items only on B are left alone by default-deny.

- **Live failure mode — the mildest of the three.** Damage is per-row and the
  site is functional in every intermediate state: a partial run leaves some
  pages on the new design and some on the old, which is ugly but resolves, with
  no 404, no duplicate, no dangling reference, no empty site. There is no window
  in which B is broken for visitors.
- **What it does to data B has and A does not.** Best of the three, by
  construction. No post is deleted, trashed or renumbered; comments, revisions,
  term relationships and every third-party reference by post ID stay valid and
  keep pointing at the right row. `page_on_front` needs no remap at all in the
  shared-origin case — it already points at the correct row. And because
  `wp_update_post` writes a revision, WordPress's own UI gives a **per-page
  undo**: the only option where a single wrong page can be reverted without
  restoring the whole site.
- **Its real risk is the correspondence, not the write.** A mispaired item
  overwrites live content with the wrong content. This is why the pairing must
  be mechanical-or-explicit, frozen into the manifest during `scan`/`plan` (it
  is a two-site read, so it belongs in `scan`, which already reads both sides —
  not in `plan`, which by design touches no site), and reviewed before `graft`
  applies it.
- **Its second risk is meta.** Etch keeps load-bearing state in `postmeta`
  (findings F3/F6), so content alone is not enough; but B's paired row may also
  carry meta from B's own plugins. Replacing all meta destroys them; replacing
  none breaks Etch. The policy that fits this codebase is the one it already
  has: replace only the meta keys a **module declares**, leave every other key
  on B's row untouched. That makes this option the *most* default-deny-aligned
  of the three, and it requires `modules/etch.sh` to declare its meta keys —
  which findings F4 and F6 already require independently.
- **Its honest limitation — the strongest argument against it.** Grafting in
  place keeps **B's** slugs, hierarchy and menu order. If the redesign only
  restyles pages that already exist, that is exactly right (and safer: no
  inbound link breaks). If the redesign **restructures the site** — new tree,
  renamed URLs — that restructuring does *not* land. Slug/parent/menu_order can
  be added as an opt-in field set on the pairing, but changing a live page's URL
  breaks inbound links unless a redirect exists, and sitegraft manages no
  redirects. So: v1 grafts content and declared meta; structure is a separate,
  explicitly selected field set, loudly warned.
- **Interrupted mid-run.** Naturally idempotent — re-applying the same source
  content to the same row yields the same bytes. Resume is free here, unlike in
  options 1 and 2 where it has to be designed.
- **How `verify` proves it.** The acceptance criterion falls straight out: for
  every frozen pair, B's `post_content` after the run must match A's after the
  same remaps, and must differ from the checksum recorded for that row before
  the graft. See below.
- **Cost.** Comparable to option 2 in raw lines, and every line is in the
  codebase's existing idiom: the pairing is a join over two scans already
  performed; the write reuses the payload-push + `wp eval` pattern that
  `graft_remap_attachment_ids` and `graft_search_replace_domain` already use;
  `id-map.tsv` takes the pairs unchanged. Unlike the other two, it *removes*
  destructive surface instead of adding it.

## Decision

**Adopt option 3 as the primary path, keep option 1 as an explicitly selected
escape hatch, reject option 2.**

Concretely:

1. **Content present on both sides is grafted in place** through a pairing
   computed in `scan` (GUID, then slug + post type; anything else is an explicit
   operator decision), frozen in the manifest, and applied in `graft` as a
   field-and-meta-key allowlist write. The pairs are appended to `id-map.tsv`,
   so every remap and module hook downstream works with no changes.
2. **Content present only on A keeps going through the WXR import**, which is
   the path that already works for it.
3. **Content present only on B is untouched** — default-deny, unchanged.
4. **`clean` (option 1) is implemented, but only as an operator-selected
   action** for the genuinely different need of removing B's leftover old pages,
   never as the mechanism for replacing content. It stays off by default, needs
   its own selection pass and a typed confirmation, and it must not be reachable
   as an implication of `migrate`.
5. **Option 2 is rejected.** It costs the most, requires destructive writes to B
   anyway (so it does not buy non-destructiveness), and its characteristic
   failure — integrations pointing at trashed rows while the site looks correct
   — is silent, which is the one property this codebase has decided it will not
   ship.

### Required regardless of which option is chosen

These are not part of the choice; they are true for all three and must land with
it, or the acceptance criterion is not met:

- **`verify` must compare content, not just counts and options.** For every
  migrated/paired post: B's `post_content` must equal A's after the same domain
  and ID remaps the graft applies (the remap functions already live in
  `lib/php/content-remap-functions.php` and can be applied to A's copy on the
  orchestrator), and — a cheaper, non-normalizable guard that on its own would
  have caught the observed run — must **differ** from the checksum of that row
  recorded on B before the graft. Per CLAUDE.md, the test must prove the check
  can fail: assert it hard-fails against a run whose import was skipped.
- **A skipped item must be loud.** Any item the importer reports as
  `already exists`, and therefore never maps, must be surfaced and must fail the
  run rather than leaving downstream remaps to no-op in silence. Whether the map
  can instead be *completed* for skipped items — via `wp_import_post_data_raw`,
  or by reading the importer's own `processed_posts` at `import_end` — is a
  claim about a third-party plugin's internals and must be verified against the
  shipped version before anything depends on it.
- **The resume ordering must be fixed.** A resume that re-runs `import` must not
  skip the step that made the import safe (`prune` today, `clean`/pairing
  tomorrow) merely because its marker is present.

## Irreversible for the operator — requires loud interactive confirmation

- **`clean`'s `wp post delete --force`.** Irreversible at row level: comments,
  postmeta, revisions and term relationships go with the post, and third-party
  references to those IDs are left dangling. Recoverable only by a full restore,
  which itself discards everything B's live plugins wrote since the backup.
  Requires a typed confirmation naming the post types and the **exact count** of
  posts about to be deleted, and should not run against a backup that has not
  been shown to restore.
- **The in-place overwrite of a live page's content and declared meta
  (option 3).** Reversible via WP revisions and the backup, but it is still a
  write to content default-deny protects. The frozen pairing must be presented
  and confirmed, and any pair not matched mechanically must be confirmed
  individually.
- **Opting into slug / parent / menu_order propagation.** Changes live URLs and
  breaks inbound links; sitegraft manages no redirects. Off by default, warned
  loudly when selected.
- **Bulk `save_post` side effects.** Any option writes to many rows and fires
  every plugin's `save_post` on each; not undone by un-trashing or by reverting
  a revision. Worth stating in the confirmation prompt rather than discovering
  through a client's cache or search console.

## What would change this decision

- **If A and B do not in fact share GUIDs.** The whole recommendation rests on
  the pairing being mechanical and exact. If the clone pipeline regenerates
  GUIDs, or if A is more often built from scratch than cloned, the pairing
  degrades to slug matching plus judgement, and option 3 loses the property that
  makes it safe. This is cheap to settle empirically on the reference pair — one
  query per side — and it should be settled **before** implementation starts.
- **If the standard workflow already takes B offline for the cutover.** Option
  1's decisive drawback is its live failure mode. Behind a maintenance window
  that drawback largely evaporates, and its much smaller implementation, plus
  the fact that it reproduces A exactly including structure, would win.
- **If these redesigns routinely restructure the site** rather than restyle
  pages that already exist. In-place grafting reproduces A's page *content*, not
  A's information architecture; if the tree and the URLs change every time,
  option 1 is the honest shape and the redirect question has to be answered
  anyway.
- **If Etch turns out to keep per-page state outside the paired post's own row
  and declared meta.** Per-post pairing would then be insufficient on its own,
  and the balance shifts back toward a full replace.

## Consequences

- (+) The tool does on a live target what it claims to do — replaces the design
  layer of pages that exist on both sides — without deleting, trashing or
  renumbering anything on B.
- (+) B's comments, revisions, plugin meta and every third-party reference by
  post ID survive, because the rows survive. `page_on_front` needs no remap in
  the shared-origin case.
- (+) Every intermediate state of an interrupted run is a functioning site, and
  re-running is idempotent by construction.
- (+) A wrong page can be reverted individually through WordPress's own
  revisions, without a full restore.
- (+) The pairing and the meta allowlist are both explicit, which extends
  default-deny rather than carving an exception into it.
- (−) A's slugs, page hierarchy and menu order do **not** propagate by default;
  a redesign that restructures the site is only partly served until the opt-in
  field set exists.
- (−) `scan` grows a two-site read it does not have today (the pairing), and the
  manifest grows a section — more moving parts in the frozen artifact.
- (−) Two write paths for content instead of one (in-place for paired items, WXR
  for A-only items), which is more surface to test than a single mechanism.
- (−) `modules/etch.sh` must declare its meta keys before the in-place path is
  correct for Etch — a dependency on findings F4/F6 being fixed first.
- (−) `clean` still has to be built (as an escape hatch), so option 1's safety
  work — explicit selection, typed confirmation, restore evidence, resume
  ordering — is deferred, not avoided.
