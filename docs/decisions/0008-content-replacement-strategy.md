# ADR 0008 — How `graft` replaces content that already exists on B

**Date:** 2026-08-26 · **Status:** accepted (Marcel's arbitration, 2026-08-26)

This ADR was first written as `proposed`, recommending option 3 (in-place graft)
as the primary path. Marcel answered the three questions that version listed
under "What would change this decision", and all three answers go against that
recommendation. The decision below is therefore **not** the one this document
originally carried. What changed, and what did not, is set out in
"Why this ADR reverses its own recommendation" before the decision itself.

Addresses issue #10. It does not close it: this is the explicit, documented
choice that issue asks for, plus the scope split between what is fixed now and
what is deferred.

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
descend from one database and share titles, dates and post IDs — on the
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

### The three answers this decision rests on

The `proposed` version of this ADR could not choose without three facts about
how these projects actually run. Marcel supplied them:

1. **Does the workflow take B offline for the cutover?** — **Yes.** B is put
   offline for the switchover; it is not expected to keep serving visitors while
   a graft is in flight.
2. **Do these redesigns restructure the site, or restyle existing pages?** —
   **Usually restructure**: new page tree, renamed URLs. But not always — some
   sitegraft users will only want to restyle pages that already exist. Both are
   real; restructuring is the dominant one.
3. **Do A and B share GUIDs?** — **No, about 99% of the time.** The clone
   pipeline does not preserve them.

## Why this ADR reverses its own recommendation

The failure-mode analysis of the three options below is unchanged, and Marcel
did not contest any of it. What changed is the weight of two facts it depended
on:

- Option 3 was recommended because its pairing was to be **mechanical and
  exact** — GUID equality, free in a shared-origin pair. Answer 3 removes that
  tier in the normal case. What is left is slug + post type, which is a
  heuristic: usually right, and wrong precisely when the site has been
  restructured and slugs have moved. Option 3 keeps a real domain of use, but
  not the one that made it the default answer.
- Option 1 was demoted because of its live failure mode — 404s for real
  visitors, an interrupted `clean` leaving B empty, and a restore that discards
  business writes taken during the run. Answer 1 bounds all three: with B
  offline there are no visitors to 404 and no concurrent writes to lose. The
  objection does not vanish (see below — the `--force` collateral is permanent
  and has nothing to do with the window), but it stops being decisive.
- Answer 2 then settles which one is *primary*: if most redesigns change the
  page tree and the URLs, the property only option 1 has — reproducing A
  including slugs, hierarchy and menu order — is not a nice-to-have, it is the
  deliverable.

So: the recommendation flips, the analysis does not. Recording it this way
rather than rewriting the document as if option 1 had always been the answer is
the point of keeping an ADR at all.

## Options considered

### Option 1 — Delete B's targeted content before importing (the `clean` step)

Delete B's pre-existing posts of the migrated post types (§6.6's `clean`,
speced, not implemented; `graft` refuses loudly today if
`manifest.clean.enabled` is set by hand), then import into an empty field. No
collisions, every item inserts, `id-map.tsv` is complete, every existing remap
works unchanged, `page_on_front` remaps correctly. B ends up as a faithful copy
of A for those post types — **including A's slugs, hierarchy and menu order**,
which is the one thing the other two options do not give, and which is exactly
what a restructuring redesign is for.

- **Live failure mode — bounded by the offline window, not eliminated.** It
  destroys before it knows the replacement will land. Between the delete and a
  successful import there are no pages; an interruption in that window (dropped
  connection, PHP fatal, importer timeout) leaves B **empty**, recoverable only
  by a full `restore`. With B offline for the cutover, two of the three
  consequences go away: no visitor sees a 404, and a restore no longer discards
  business writes that happened during the run. The third does not: the empty
  state and the restore are still real, so `clean` still requires backup
  evidence, not a backup marker.
  - **"Offline" has to mean offline.** A maintenance-mode plugin that filters
    only the frontend still lets cron, REST endpoints and webhooks write. If
    the guarantee that makes this option acceptable is "nothing else writes to B
    during the run", then that is a **precondition to check**, not an assumption
    to inherit — at minimum: confirm the offline mechanism with the operator,
    and record when the backup was taken relative to it.
- **A soft delete does not work.** `post_exists()` filters on title, date and
  type, with no post-status filter — a *trashed* post still matches, so the
  importer would still print `already exists`. To defeat the collision the
  delete has to be `wp post delete --force`. There is no reversible form of this
  option at the WXR level.
- **What it does to data B has and A does not — unchanged by the offline
  window, and the real remaining cost.** `--force` takes the post's comments,
  its full postmeta (including meta written onto those pages by B's own
  plugins — SEO records, translation links, form or membership configuration),
  its revisions and its term relationships. Every row in a *protected*
  third-party table that references one of those post IDs is left dangling, and
  default-deny correctly forbids sitegraft from fixing them. The protected
  tables stay byte-identical, so `verify`'s checksum check passes — **precisely
  while the thing it protects is being hollowed out.** Same class of defect as
  the one this ADR exists to fix. Being offline changes none of this; it is
  permanent, not transient.
  - On a genuine restructure this collateral is partly *correct* — the old page
    ceases to exist, so its revisions going with it is not a loss. What is not
    correct is doing it silently. See "What `clean` owes the operator" below.
- **Interrupted mid-run.** `graft`'s resumability markers are per-step and
  coarse. If `clean` completes and `import` is interrupted halfway, a resume
  skips `clean` (marker present) and re-runs `import` from the top — the items
  inserted by the first attempt now collide with themselves and are skipped and
  left unmapped, reproducing issue #10 inside the fix. The same hazard already
  exists today for `prune`, which runs before `import` and is marker-gated the
  same way.
- **What it demands of `backup`/`restore`.** More than exists today.
  `backup.complete` is a marker and `backup_verify_db_export` checks gzip
  validity, a size floor and a non-empty `wp-content` — a sanity check, not
  evidence that the dump restores. Deleting a site's pages on the strength of an
  unrehearsed backup is not defensible even offline. It also inherits the
  documented wrapped-local caveat (overwrite-only restore, no deletions).
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
  selection, a typed confirmation, a restore-rehearsal gate, the dangling-
  reference report, and fixing the resume ordering. Moderate code, high safety
  work.

### Option 2 — Import, then repoint: swap slugs and the front-page trio, trash the old

- **It does not work as written on the case that motivates it.** In the
  shared-origin case the importer skips the colliding items, so there are no new
  posts to repoint. To make them insert you must first defeat `post_exists()` —
  either by mutating B's existing posts (title or date) so the check misses, or
  by rewriting the WXR on the orchestrator. So this option is not "a
  non-destructive import followed by a swap"; it is **mutate B's live rows,
  import, swap, trash** — it pays a destructive write before it starts.
- **Failure mode.** Two windows instead of one. After the import, B holds
  duplicates — two of every page, the new ones carrying `-2` slugs. Then the
  swap itself is hundreds of `wp_update_post` calls, each firing `save_post` on
  every plugin B runs (SEO regeneration, cache purges, translation sync,
  revision creation). An interruption mid-swap leaves half the site pointing at
  new content and half at old, with suffixed slugs on both sides and no marker
  saying which set is authoritative — unless the tool first wrote a durable
  per-post journal (old ID, old slug, new ID, new slug, action) to the run dir.
  That journal is real, non-trivial work that neither other option needs.
- **What it does to data B has and A does not.** Its strength, and its trap.
  Nothing is force-deleted, so comments, meta and revisions survive and the old
  rows remain reversible. But every third-party reference still points at the
  **old** post, now in the trash, and nothing points at the new one — a plugin
  holding "page 16 is the checkout page" is now aimed at a trashed page.
  Repointing them is exactly what default-deny forbids sitegraft from doing on
  its own. The result: the site's own navigation looks correct while
  integrations quietly aim at trash, surfacing days later. **The least loud
  failure mode of the three, which on a client site makes it the most
  dangerous** — and note that taking B offline does nothing about it, because
  the damage surfaces after B comes back.
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

Build an explicit A→B correspondence for items present on both sides, then, for
each frozen pair, write A's `post_content`, `post_excerpt`, `post_title` and the
**module-declared** meta keys onto B's existing post, and add the pair to
`id-map.tsv` so every remap already in the codebase (attachment IDs in content,
featured images, domain search-replace, module `post_import` hooks) works
unchanged. Items only on A still go through the WXR import; items only on B are
left alone by default-deny.

- **Failure mode — the mildest of the three.** Damage is per-row and the site is
  functional in every intermediate state: a partial run leaves some pages on the
  new design and some on the old, which is ugly but resolves, with no 404, no
  duplicate, no dangling reference, no empty site.
- **What it does to data B has and A does not.** Best of the three, by
  construction. No post is deleted, trashed or renumbered; comments, revisions,
  term relationships and every third-party reference by post ID stay valid and
  keep pointing at the right row. And because `wp_update_post` writes a
  revision, WordPress's own UI gives a **per-page undo**: the only option where
  a single wrong page can be reverted without restoring the whole site.
- **Its real risk is the correspondence, not the write — and answer 3 makes that
  risk larger than the `proposed` version of this ADR assumed.** The pairing was
  to be exact (GUID equality) with slug + post type as a fallback. With GUIDs
  not shared in ~99% of pairs, **slug + post type is the normal path**, and it
  is a heuristic. A mispaired item overwrites live content with the wrong
  content, silently, and it misfires exactly where slugs have been reused for
  different pages — which is what a restructure does. Two consequences, both
  recorded in the decision below: the GUID tier stays (it is free, and correct
  in the 1%) but nothing may depend on it; and every slug-derived pair — i.e.
  effectively all of them — has to be reviewed by the operator before `graft`
  applies it, not just the leftovers. That is materially more operator work than
  "mechanical and exact" implied.
  - Worth stating for the 1%: GUID equality proves shared database lineage, not
    that the two rows are the same page today. WordPress sets `guid` from the
    permalink at creation and does not maintain it as an identity. It is a
    strong hint, not a proof.
- **Its second risk is meta.** Etch keeps load-bearing state in `postmeta`
  (findings F3/F6), so content alone is not enough; but B's paired row may also
  carry meta from B's own plugins. Replacing all meta destroys them; replacing
  none breaks Etch. The policy that fits this codebase is the one it already
  has: replace only the meta keys a **module declares**, leave every other key
  on B's row untouched. That makes this option the most default-deny-aligned of
  the three, and it requires `modules/etch.sh` to declare its meta keys — which
  findings F4 and F6 already require independently.
- **Its limitation, which answer 2 turns into a scope boundary rather than a
  drawback.** Grafting in place keeps **B's** slugs, hierarchy and menu order.
  For a redesign that restyles pages that already exist, that is not a
  limitation — it is the correct behavior, and the safer one, because no inbound
  link breaks. For a redesign that restructures the site, the restructuring
  simply does not land. So this option is not a weaker general path; it is the
  right path for one of the two cases and the wrong one for the other.
- **Interrupted mid-run.** Naturally idempotent — re-applying the same source
  content to the same row yields the same bytes. Resume is free here, unlike in
  options 1 and 2 where it has to be designed.
- **How `verify` proves it.** For every frozen pair, B's `post_content` after
  the run must match A's after the same remaps, and must differ from the
  checksum recorded for that row before the graft.
- **Cost.** Comparable to option 2 in raw lines, and every line is in the
  codebase's existing idiom: the pairing is a join over two scans already
  performed; the write reuses the payload-push + `wp eval` pattern that
  `graft_remap_attachment_ids` and `graft_search_replace_domain` already use;
  `id-map.tsv` takes the pairs unchanged.

## Decision

**Two first-class paths, one per real use case, chosen explicitly by the
operator. Option 2 is rejected.**

1. **`clean_import` (option 1) — for a redesign that restructures the site.**
   The dominant case. Delete B's pre-existing content for the selected post
   types, then import A's WXR into an empty field. It is the only one of the
   three that reproduces A **including slugs, hierarchy and menu order**, which
   is precisely what a redesign that changes the page tree and the URLs is
   asking for. Its decisive objection in the `proposed` version — the live
   failure mode — is bounded by the operator taking B offline for the cutover.
2. **`in_place` (option 3) — for a redesign that restyles existing pages.**
   Secondary in volume, real in kind. Graft A's content and module-declared meta
   onto B's paired rows. It keeps B's slugs and hierarchy, which in this case is
   the right answer and not a shortcoming, and it never deletes, trashes or
   renumbers anything.
3. **Option 2 is rejected**, for the reasons already written above: it costs the
   most, requires destructive writes to B anyway (so it does not buy
   non-destructiveness), and its characteristic failure — integrations pointing
   at trashed rows while the site looks correct — is silent, which is the one
   property this codebase has decided it will not ship.
4. **Content present only on A** goes through the WXR import in both modes.
   **Content present only on B** is untouched in `in_place` mode, and in
   `clean_import` mode is deleted only if its post type was explicitly selected
   for `clean` — never as an implication of `migrate`.

### How the operator chooses: no default

`plan` adds a `replace.mode` selection with exactly two values, `clean_import`
and `in_place`. **There is no default. A manifest with `replace.mode` unset does
not freeze, and `graft` refuses to run against one** — the same fail-closed shape
`graft` already uses today for `clean.enabled=true`, and for the same reason.

The argument, since a wrong default here destroys client content:

- **A default on the dominant case means the destructive path is what you get by
  pressing Enter.** An operator who wanted a restyle and accepted the default
  gets `wp post delete --force` across B's pages, with the collateral described
  above, recoverable only by a full restore. That is the exact shape this repo's
  first rule exists to prevent, and it contradicts design doc §3.6 directly:
  nothing destructive may be reachable as an implication of another selection.
- **A default on the safe case is not the answer either.** It would silently
  under-deliver on most runs — the operator asks for a restructure, sitegraft
  quietly performs a restyle, the tree and the URLs do not change, and every
  check passes because in-place grafting did exactly what in-place grafting
  does. A success that was not what was asked for is still a success that was
  not earned.
- The two failure directions are not symmetric in severity, but they are
  symmetric in kind: both are the tool deciding something the operator did not
  say. The mode is not a preference with a sensible fallback; it is the single
  fact that determines what the run does to a client's site. It has to be
  answered.

Practically: `plan` asks in the operator's language, not the tool's — "this
redesign changes the site's structure and its URLs" versus "this redesign
restyles pages that already exist, keeping the current structure" — and states
in one line what each does to B. Non-interactive runs (`--yes` and equivalents)
must carry the mode explicitly on the command line or in a pre-written manifest;
they must not infer one. `clean_import` keeps its own typed confirmation on top
of the mode selection: choosing the mode authorizes the strategy, not the
deletion of a specific count of posts.

### Redirects: out of scope, and said so loudly

Answer 2 makes this unavoidable rather than incidental: if `clean_import` is the
dominant path and it reproduces A's slugs and hierarchy, then **the URLs of a
client's live site change on every run of it**, and inbound links, bookmarks,
search results and any hard-coded link in an external system break. sitegraft
manages no redirects — there is no redirect code anywhere in the repo. Marcel
accepts that as the product's position; what follows is the shape it takes.

The decision, in two halves:

- **Writing redirects is out of scope, permanently, for `lib/`.** Redirects live
  in something B owns — a redirect plugin's own table, the server config, or a
  CDN. The first is protected by default-deny; the other two are outside
  sitegraft's reach entirely. Building a redirect engine is a second product,
  not a step in this one. If it is ever built it belongs in a
  `modules/<redirect-plugin>.sh`, under the same explicit-selection contract as
  every other module, and it is a separate decision.
- **Reporting the URLs that no longer exist is in scope, and is mandatory.**
  sitegraft is the only party that sees both B before the graft and B after it,
  and it sees them for free — it has both inventories. Every run must end by
  writing a URL-change report to the run directory, and `verify` must state in
  its summary how many public URLs changed **and that no redirect was created
  for them.** Silence here would be the familiar defect in a new place: the run
  succeeds, and the operator finds out from a client's search console.

This is the honest split. "Redirects are your job" is a defensible limitation;
"redirects are your job and we won't tell you which ones you need" is not.

#### The URL-change report is an action list, not a log

The point of the artifact is that the operator walks it once and decides, URL by
URL, between a 301 and an accepted removal. So it distinguishes three
populations, because they do not call for the same decision:

| Class | What it is | What the operator does |
|---|---|---|
| `moved` | A path on B before the graft that has an evident counterpart after it | Point a 301 at the proposed target, or override it |
| `gone` | A path on B before the graft with **no** counterpart after it | Decide: 301 to something only they know, or 410 / accept the removal |
| `new` | A path that exists only after the graft | No redirect. Listed for the sitemap and for re-indexing |

**`gone` is the class that matters and the one a plain old→new mapping does not
produce.** For those rows sitegraft proposes **no** target. It cannot: the
replacement does not exist, so any suggestion would be a guess dressed as an
answer — the exact defect this repo's first rule names. The operator is the only
party who knows whether a retired service page should point at its successor,
at a category, or nowhere at all.

**Classification fails toward `gone`, never toward `moved`.** Deciding that
B's old `/a/b` "became" A's `/c/d` is the same correspondence problem
`in_place`'s pairing has, and with GUIDs unavailable it rests on the same
title + post type heuristic, with the same failure mode. A wrong `moved` row
hands the operator a plausible 301 to the wrong page and it will be applied
without much scrutiny, because it looks decided. A row put in `gone` that was
really a move only costs the operator one judgement call on a list they are
reading anyway. So: only a correspondence sitegraft can justify is emitted as
`moved`; everything doubtful goes to `gone` with no target, and the report says
which signal produced each `moved` row.

#### Format: headerless TSV, site-relative paths

`class` TAB `old_path` TAB `new_path` TAB `post_type` TAB `title`, one row per
URL, no header line, `-` for a field that has no value (`new_path` on a `gone`
row, `old_path` on a `new` row). Tabs and newlines are stripped from the title.

- **TSV, not JSON**, even though the manifest is JSON and `jq` is already a
  dependency (ADR 0002). This artifact is a flat list of tuples whose consumer
  is a rule generator: `awk -F'\t' '$1=="moved"'` turns it into server or plugin
  redirect rules in one line. JSON would earn its place if the data were nested;
  it is not.
- **Headerless, fixed columns, class first** — the same shape as `id-map.tsv`
  (`old_id` TAB `new_id` TAB `post_type`), which is the only artifact `graft`
  writes today. One artifact convention in the run dir, not two. A header line
  would break naive pipelines, and a `#` comment line invites every reader to
  handle it differently; the column contract belongs in `docs/usage.md` and in
  `verify`'s summary, not in the data.
- **`-` rather than an empty field**, so the column count never varies and an
  empty field can never be read as "absent" or "parse error".
- **Site-relative paths, not absolute URLs.** Redirect rules are written against
  paths, and keeping the domain out means the artifact stays correct if B's
  domain is not what the run assumed.

#### Where B's "before" URLs come from, and why it is a `graft` step

They must be read **while they still exist** — after `backup`, before `clean`.
A report that cannot be produced after the fact is not a report, and once
`clean` has run, B's old paths exist nowhere but the backup.

That read belongs to `graft`, not to `scan`, even though `scan` is already the
two-site phase:

- `scan` can have run days before `graft`, and B is a live site. An inventory
  taken then describes a B that may no longer be the B about to be deleted.
- The pairing (option 3) belongs in `scan` for the opposite reason: it is an
  operator decision that has to be *frozen* into the manifest before anything
  runs. This inventory is not a decision, it is evidence about the state being
  destroyed, and evidence must be fresh.
- Taking it immediately after `backup` also ties it to the snapshot a `restore`
  would return to, which is the state the operator would be comparing against.

Concretely: a `url_inventory` step in `graft`'s existing marker sequence,
writing `urls-before.tsv`, and **`clean` refuses to run if that file is missing
or empty** — the same fail-closed shape `graft` already uses when
`clean.enabled` is set without an implementation. The resume-ordering fix listed
under "Required regardless" applies to it directly: a resume must not skip
`url_inventory` and then run `clean`.

The final `url-changes.tsv` is produced at the **end** of `graft`, by diffing
`urls-before.tsv` against B's URLs read back from B — not against A's, and not
against what the import intended. It has to describe what B actually serves now,
which is also what makes it checkable: `verify` re-reads B and asserts every
`moved` target resolves, and that no `gone` path still resolves. That gives
`verify` a falsifiable assertion instead of trusting `graft`'s own bookkeeping,
which is the failure this ADR exists to fix.

#### `in_place` produces the report too

`in_place` keeps B's slugs and hierarchy, so in the normal case nothing moves
and nothing disappears: the report should contain `new` rows only, for the
A-only items that came in through the WXR import. The report is still produced,
unconditionally, for two reasons.

- **Proving it beats assuming it.** "This path changes no URLs" is a claim about
  a run, and the artifact is what makes it true or false. A `gone` row under
  `in_place` is structurally impossible — nothing is deleted — so `verify` must
  **fail** if one appears. That turns a free by-product into a real check on the
  in-place writer.
- **The slug / parent / menu_order opt-in makes `in_place` a URL-changing path.**
  This ADR already provides for that opt-in, and the moment it is selected the
  report is not a formality: it is the thing that makes the opt-in reviewable,
  and the same 301-or-410 walk applies. Building the report only for
  `clean_import` would mean discovering it was needed in `in_place` on the first
  run that used the opt-in.

### What `clean` owes the operator, beyond the confirmation

Because `clean_import` is now the primary path rather than an escape hatch, its
safety work is on the critical path and not deferrable within step 2:

- **A pre-flight report of protected-table rows referencing the post IDs about
  to be deleted.** Report, never repair — repairing is what default-deny
  forbids. Today those references go dangling while `verify`'s checksum check
  passes; the operator has to at least be told.
- **A typed confirmation naming the post types and the exact count** of posts
  about to be force-deleted.
- **Restore evidence, not a restore marker,** before the first destructive
  write.
- **`urls-before.tsv`, captured before the first deletion,** with `clean`
  refusing to run without it. It is the only moment at which B's outgoing URLs
  can still be read from B.
- **The resume ordering fix** (below), without which `clean` reproduces issue
  #10 inside its own fix.

## Scope: what is decided now, what is built later

**Both paths are second-step work.** This ADR freezes the strategy and its
framing; it does not start the implementation. Deferred to step 2:

- the `replace.mode` selection in `plan` and its fail-closed enforcement in
  `graft`;
- `clean` (option 1): the deletion pass, the typed confirmation, the
  protected-reference pre-flight report, the restore-rehearsal gate;
- the `url_inventory` step in `graft` (`urls-before.tsv`, gating `clean`), the
  `url-changes.tsv` action list with its `moved`/`gone`/`new` classification,
  `verify`'s "N URLs changed, no redirects created" summary line, and `verify`'s
  assertions on it (every `moved` target resolves, no `gone` path resolves, no
  `gone` row at all under `in_place`);
- the pairing computation in `scan` and the in-place writer (option 3),
  including the operator review of slug-derived pairs;
- `modules/etch.sh` declaring its meta keys — a dependency of the in-place path
  on findings F4/F6.

### Required regardless — and not deferrable

These three are **not** part of the choice and **not** step-2 work. They are
defects in the code that is on `main` today, they are what let a graft that
migrated nothing print `PASS`, and they will run against the next real pair
whether or not either path exists yet:

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
  tomorrow) merely because its marker is present. This one already bites without
  either path: `prune` is marker-gated and runs before `import` on `main` now.

Why they cannot wait for step 2:

- They are unconditional. Nothing about them depends on which path is built, so
  deferring them buys no design freedom — it only leaves the lie in place
  longer.
- Issue #10's acceptance criterion has two halves: "B's pages carry the source's
  content" **and** "`verify` fails if they do not". The second half is these
  three, and it is satisfiable now. Shipping it turns the tool's behavior on a
  shared-origin pair from a false `PASS` into a loud failure that names what did
  not happen. That is a legitimate, honest interim state, and it is strictly
  better than what exists.
- They are small and they protect every run in the meantime; step 2 is a feature
  and the next real pair will not wait for it.

## Irreversible for the operator — requires loud interactive confirmation

- **`clean`'s `wp post delete --force`.** Irreversible at row level: comments,
  postmeta, revisions and term relationships go with the post, and third-party
  references to those IDs are left dangling. Recoverable only by a full restore.
  Requires a typed confirmation naming the post types and the **exact count** of
  posts about to be deleted, and must not run against a backup that has not been
  shown to restore.
- **URL changes with no redirects (`clean_import`).** Not reversible in any
  useful sense once the site is back online and crawlers have seen it. The
  confirmation must state that inbound links to changed or removed paths will
  404, that sitegraft creates no redirects, and that `url-changes.tsv` is a
  list the operator is expected to walk before B goes back online — a `gone`
  row left undecided is a 404 shipped to a client.
- **The in-place overwrite of a page's content and declared meta (`in_place`).**
  Reversible via WP revisions and the backup, but still a write to content
  default-deny protects. The frozen pairing must be presented and confirmed —
  and with GUIDs unavailable, that means the slug-derived pairs, which is
  essentially all of them, not just the leftovers.
- **Bulk `save_post` side effects.** Either path writes to many rows and fires
  every plugin's `save_post` on each; not undone by un-trashing or by reverting
  a revision. Worth stating in the confirmation prompt rather than discovering
  through a client's cache or search console.

## What would change this decision

- **If `in_place` turns out to be what most users actually select.** The split
  here follows Marcel's own workflow, where restructuring dominates. If the
  broader Etch community's usage is the opposite, the *ordering* of the
  implementation should follow the usage — the decision itself (two explicit
  paths) does not change.
- **If slug + post type proves unreliable in practice for `in_place` pairing.**
  It is a heuristic and it is now the only mechanical tier available. If real
  pairs produce mispairings that survive operator review, `in_place` needs a
  stronger identity (an explicit source-ID marker written by a prior sitegraft
  run, or an operator-authored mapping file) before it can be trusted on
  anything but small, hand-checked page sets.
- **If B cannot in fact be taken fully offline** for a given project — cron,
  REST or webhooks still writing during the run. `clean_import`'s risk profile
  reverts to the one described in the `proposed` version of this ADR, and that
  project should use `in_place` or accept a maintenance window it can actually
  enforce.
- **If Etch keeps per-page state outside the paired post's own row and declared
  meta.** Per-post pairing would then be insufficient on its own, and `in_place`
  would be unsound for Etch regardless of the pairing quality.

## Consequences

- (+) The dominant case — a redesign that restructures the site — is served by
  the only option that actually reproduces A's information architecture. The
  tool delivers the redesign, not a partial version of it.
- (+) The restyle case is served by the option that is safest for it, and keeps
  B's slugs, so it breaks no inbound links.
- (+) The mode is an explicit operator decision with no default, so neither
  destroying B's content nor quietly under-delivering can happen by inaction.
- (+) The URL-change report makes the redirect gap visible on every run instead
  of leaving the operator to discover it from a client, and it is an action list
  — the paths that no longer exist are named, so the 301-or-410 call can be made
  URL by URL rather than reconstructed later from a crawl.
- (+) `verify` gains falsifiable assertions from it (`moved` targets resolve,
  `gone` paths do not, no `gone` row under `in_place`) instead of trusting
  `graft`'s own account of what it did.
- (+) The three "required regardless" fixes land first, so the next real run
  fails loudly instead of printing `PASS` over an empty migration — even before
  either path exists.
- (−) `clean_import` force-deletes B's content for the selected post types, with
  permanent collateral on comments, plugin meta, revisions and third-party ID
  references. The offline window bounds the *transient* risk, not this one.
- (−) It depends on B genuinely being offline, which is a human procedure
  sitegraft can check for but cannot enforce.
- (−) sitegraft changes live URLs and creates no redirects. That is an accepted
  product limitation, not an oversight, and it is work the operator inherits on
  every restructuring graft: a `url-changes.tsv` to walk, and a decision to make
  on every `gone` row that sitegraft deliberately declines to guess.
- (−) The `moved`/`gone` split is heuristic, inherits the pairing's uncertainty,
  and is biased toward `gone` — so it will hand the operator judgement calls on
  URLs that did in fact simply move.
- (−) `in_place`'s pairing lost its exact tier: slug + post type is a heuristic
  and every pair needs operator review, which is real operator time on every run
  of that mode.
- (−) Two write paths for content instead of one, which is more surface to
  build, test and document than a single mechanism — and both are deferred, so
  issue #10's first half stays open until step 2.
- (−) `modules/etch.sh` must declare its meta keys before `in_place` is correct
  for Etch — a dependency on findings F4/F6 being fixed first.
