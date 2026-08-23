# ADR 0007 — Scan-computed module selections, and a real `_option_keys_exclude`

**Date:** 2026-08-23 · **Status:** proposed (Rosalinde's decision, pending Marcel's validation)

Supersedes the "v1 status" note under the design doc's §3.2 table, which states
that `<mod>_option_keys_exclude` is inert. It is no longer inert.

Closes issues #13, #15 and #16 — one contract change, because they are one gap.

## Context

Three reports, one shape.

**#13 — a documented safety mechanism that did nothing.** `docs/usage.md` §5 and
the design doc §3.2 both described `<mod>_option_keys_exclude` as the way to carve
license keys out of a broad option-key prefix. Nothing in `lib/` or `bin/` ever
called it. A module author who read the docs, returned `my_plugin_*` from
`_option_keys`, and listed `my_plugin_license_*` under `_option_keys_exclude`
shipped a module that copies license keys — and, separately, a module whose
"prefix" was never expanded by anything either (see the Consequences section:
enumerate it from the scan with `_option_keys_dynamic`). In Etch's case that
includes an `ai_api_key`, copied from one site to another. The code read as if it were handled. Both shipped modules
avoided the trap only by using explicit allowlists instead of prefixes, which is a
workaround, not a fix.

**#15 — a name that cannot be written down in advance.** The active theme's
customizer settings live in `theme_mods_<stylesheet>`. That option belongs with a
migrated design, and no module could declare it: `<mod>_option_keys` returns a
static list, and this key's *name* depends on the site's active theme slug, which
is only known after `scan`.

**#16 — a definition without its content.** Etch lets a site declare its own post
types and stores the declarations in the `etch_cpts` option, which
`modules/etch.sh` migrates. The target received the *definition* and none of the
*posts*: the type arrived registered and empty. The names to migrate are whatever
`etch_cpts` happens to declare on that particular site — again knowable only after
`scan`.

#15 and #16 are the same missing capability seen from two directions, and #13 is
the reason the obvious workaround for both (return a broad prefix and exclude the
rest) was unsafe. Special-casing each would have left the contract exactly as
misleading as it was.

## Decision

### 1. Every selection kind gains a `_dynamic` counterpart

| Function | Required | Signature |
|---|:---:|---|
| `<mod>_post_types` | no\* | → stdout, one post type per line |
| `<mod>_post_types_dynamic` | no\* | `<scan_json>` → stdout, one post type per line |
| `<mod>_option_keys` | no\* | → stdout, one `wp_options` key per line |
| `<mod>_option_keys_dynamic` | no\* | `<scan_json>` → stdout, one key per line |
| `<mod>_tables` | no\* | → stdout, one table suffix per line |
| `<mod>_tables_dynamic` | no\* | `<scan_json>` → stdout, one suffix per line |
| `<mod>_option_keys_exclude` | no | → stdout, one shell glob per line |

\* At least one of those six must exist. A `_dynamic` function counts as a claim in
its own right — a module whose entire claim is computed from the scan is a
legitimate module (`module_validate_contract`, `lib/modules.sh`).
`_option_keys_exclude` deliberately does **not** count: an exclusion narrows a
claim, it never makes one.

A `_dynamic` function receives exactly one argument, the path to a `scan-*.json`,
and must derive its answer from that file alone. `plan` is offline by design (design
doc §6.2) — a `_dynamic` function must never call `wp`, `ssh`, or the network.

### 2. `module_selection` is the one expansion point

```
module_selection <prefix> <kind> <scan_json>
```

`lib/modules.sh`. Emits the module's effective list for one kind, one name per
line. It is the *only* thing allowed to call a module's `_post_types` /
`_option_keys` / `_tables` / `_*_dynamic` / `_option_keys_exclude`. It:

1. calls the static function, if declared;
2. calls the `_dynamic` function with `<scan_json>`, if declared, and appends
   its lines after the static ones;
3. de-duplicates, preserving first-seen order;
4. for `option_keys` only, drops every name matching any glob returned by
   `<mod>_option_keys_exclude` — **statics and dynamics alike**;
5. rejects any name containing a comma or whitespace.

Point 5 is not stylistic. Names travel onward through a comma-joined
`--post_type=` CSV (`graft_export_wxr`) and through unquoted `for key in $(...)`
word splitting (`graft_migrate_options`); a name carrying either character would
silently become two wrong names.

### 3. When it is called, and against which scan

`plan_defaults` (`lib/plan.sh`), once per module per kind, at the one moment a
module's claim becomes manifest content. Nowhere else — `graft` and `verify` read
the manifest and nothing but the manifest, so an option key excluded before the
manifest is written is excluded everywhere downstream. There is no second
enforcement point to keep in sync, which is why wiring #13 *here* closes it rather
than half-closing it.

The scan a `_dynamic` function is resolved against follows the bucket the module
is headed for:

| Bucket | Scan | Why |
|---|---|---|
| `migrate` | `scan-a.json` | the selection describes what leaves A |
| `protect` | `scan-b.json` | the selection describes what must not be touched on B |
| `tables` (any bucket) | `scan-b.json` | migration never copies tables — `manifest_add_migrate` takes no tables argument (design doc §3.2), so a table claim can only ever be about B |

Detection runs **first**, and `tables` is expanded only for a module actually
headed for `protect`. An earlier draft of this ADR expanded `tables` for every
discovered module *before* detection, because the expanded list was what decided
which side the module got tested against first — so a `<mod>_tables_dynamic` that
failed aborted the run even for a module present on **neither** site, while the
identical failure in a `_post_types_dynamic` was harmless because that expansion
already happened after detection. That asymmetry was an accident of ordering, not
a rule anyone chose.

What decides the order now is whether the module **declares** a tables function
(`module_has_fn "$mod" tables || module_has_fn "$mod" tables_dynamic`) — which is
the claim of *kind* the rule was always about ("a module that declares `_tables`
can only be describing data to protect"), so reading the declaration is if
anything closer to the rule's own wording than counting the expanded list was.
One behavior changes with it: a module declaring a tables function that
legitimately returns nothing for *this* site is now tested against B first, where
it used to be treated as tableless. That is the same answer for every shipped
module (`core-wp`, `etch` and `acss` declare no tables at all) and the safer
direction for any other. `module_selection` stays fail-closed for the module whose
manifest entry actually depends on the list.

Because dynamic names land in the manifest exactly like static ones, `plan`'s
interactive selection lists and toggles each of them individually, and
`_plan_apply_selection` classifies them from the manifest's own lists — never by
guessing from the string's shape. That is #16's second acceptance criterion, and
it falls out of putting the merge before the prompt rather than after it.

### 4. Failure and emptiness are different answers

An empty list and an error must not leave a module the same way.

- A `_dynamic` (or static, or exclude) function **exiting non-zero** aborts
  `module_selection`, which aborts `plan_defaults`, which aborts `phase_plan`. No
  manifest is frozen. The message names the exact function and scan file.
- A function **exiting zero with no output** is a legitimate answer: this module
  claims nothing of that kind on that site. It contributes nothing and the run
  continues.
- A failing `<mod>_option_keys_exclude` is treated exactly as hard as a failing
  `_dynamic`. Continuing with the unfiltered union would migrate precisely the
  keys the module asked to hold back — the #13 defect, restaged as an error path.

This is CLAUDE.md's "fail closed" and "a check must distinguish *verified true*
from *could not verify*" applied to the module boundary. It costs a module author
nothing to be explicit: return 0 for "nothing here", non-zero for "I could not
tell".

Escape hatch, and it is real: `SITEGRAFT_MANIFEST_PREFILLED` bypasses
`plan_defaults` entirely (`phase_plan` no longer calls it on that path), so a
scripted run can still proceed while a module's dynamic selection is broken. The
error message says so, and that statement is now true.

### 5. What the two shipped modules do with it

- **`core_wp_option_keys_dynamic`** (#15) emits `theme_mods_<stylesheet>`, read
  from `active_theme.stylesheet` in the scan. It claims the key only if the scan
  also shows the option present: `graft_migrate_options` falls back to the literal
  `null` when `wp option get` finds nothing on A and writes that to B, so claiming
  a key A does not have would *blank* B's own theme mods. A scan with no active
  theme, or no options list at all, is an error — neither is a WordPress site, and
  "the scan is malformed" must not read as "there is nothing to migrate".

  It lives in `core-wp`, not `etch`, where the gap was first noted: `theme_mods_`
  is written by WordPress core for whatever theme is active, classic or block, with
  none of the "only worth migrating when the theme is being replaced by a block
  theme" condition that keeps `wp_template`/`wp_global_styles` in `etch`.

- **`etch_post_types_dynamic`** (#16) reads `etch_cpts` and claims the post types
  it declares. It accepts a list of names, a list of definition objects, or a map
  keyed by name, each also as a JSON string. A **single definition object**
  (`{"slug":"fotos","label":"Fotos"}`) is refused rather than read as a map, which
  would otherwise turn its field names into post types and exit 0. A declared name
  the scanned site does not actually register is **dropped, with a warning**:
  offering a post type that does not exist is how `graft` came to export an empty
  WXR while `verify` reported PASS (CLAUDE.md's first rule, in its original form).
  A declared name that is not a legal WordPress post-type name (non-`[a-z0-9_-]`,
  or longer than 20 characters) is a defect in the data and **is** an error.

  A value it cannot read at all **warns, loudly, and claims nothing**. An earlier
  draft made this an abort, on the reasoning that "unreadable" and "declares none"
  must not produce the same answer. The reasoning holds; the abort did not. `scan`
  did not pass `--unserialize` to `wp option list` at the time, so a PHP array —
  the default shape `update_option` produces, and therefore the *likely* one —
  reached this function as the serialized string `a:1:{…}` and stopped `plan`
  dead. Verified on the project's own DDEV harness output, where `etch_settings`,
  `etch_styles`, `active_plugins` and the empty `sticky_posts` are all serialized
  strings. That traded "this run migrates less than it could" for "this tool does
  not run at all", including on the wholly benign `a:0:{}`. The scan now
  unserializes (below), which removes the common case; the warning names the
  option, the consequence, and — when the value still looks PHP-serialized — the
  one-command fix, which satisfies CLAUDE.md's "a skipped step is visible" without
  putting `plan` on the floor.

- **`scan` passes `--unserialize` to `wp option list`.** Without it wp-cli returns
  each `option_value` exactly as the database holds it, so every PHP array arrives
  as a serialized string. Verified live against WP-CLI 2.12.0 on a real install
  rather than assumed: `a:2:{i:0;s:5:"fotos";…}` → `["fotos","news"]`, `a:0:{}` →
  `[]`, `a:1:{s:5:"fotos";a:1:{…}}` → `{"fotos":{…}}`; strings and scalars are
  untouched; a *corrupt* serialized value unserializes to PHP `false` and is
  recorded as JSON `false`. The flag has been part of `wp option list` since 2018
  (wp-cli/entity-command), so it predates every wp-cli 2.x this tool can run
  against. `modules/etch.sh`'s `etch_cpts` reader is the only consumer of
  `.option_value` in the codebase, and the scan file gets *smaller*, not larger
  (measured: 13 896 → 12 043 bytes on a stock WordPress install — PHP's `s:10:"…"`
  framing plus JSON escaping of its embedded quotes costs more than the decoded
  structure).

## Consequences

- (+) `<mod>_option_keys_exclude` does what the documentation always said it did.
  A broad claim plus exclusions is now a safe, supported way to write a module,
  which is what makes the pattern usable for plugins with dozens of options. To be
  precise about what "broad" means here: nothing in sitegraft ever expands a
  pattern into option keys — `graft_migrate_options` runs `wp option get` on the
  literal manifest string — so the broad claim has to be *enumerated from the scan*
  by `_option_keys_dynamic`, and `_option_keys_exclude` filters the names the module
  itself returned.
- (+) A module can express a claim whose *names* come from the scanned site, which
  is what #15 and #16 both needed. The core learned one general capability instead
  of two special cases, and adding a module still requires zero changes to `lib/`
  or `bin/`.
- (+) `plan` now stops on a module that cannot answer, instead of planning a
  quietly smaller migration.
- (−) A broken third-party module can now block `plan` outright. Deliberate: the
  alternative is a run that silently migrates less than it says. Mitigated by
  `SITEGRAFT_MANIFEST_PREFILLED` and by an error message that names the function —
  which now names the module's **real** exit code. It used to say `exited 0` for
  every failure, whatever the module actually returned, because `rc=$?` sat inside
  an `if ! cmd; then` body and so read the status of the `!` rather than of the
  function. A message that reports a failure and names 0 as its cause is the
  bookkeeping lie CLAUDE.md's first rule is about, and it was the one number an
  operator would have carried to the module author. All three sites use
  `cmd || { rc=$?; … }`, and the tests assert the number.
- (−) `etch_post_types_dynamic` reads a structure that has been observed on a real
  site but **not verified field by field**. It accepts three plausible shapes and
  warns loudly on anything else, rather than guessing. If a real site turns up a
  fourth shape, `plan` says so by name instead of migrating half of it — but the
  definitive answer is still one query on a live Etch install that uses the
  feature, which nobody has run. Tracked in `docs/todo.md`.
- (−) `<mod>_tables_dynamic` is supported and unused. Kept for contract
  uniformity: a rule of the form "these two kinds can be dynamic, that one cannot"
  is a rule every module author has to look up, and it costs nothing here.
- (−) Two names that a module legitimately owns but that carry a comma or
  whitespace are now rejected at plan time. No WordPress post type can contain
  either, and an option key that does could not survive `graft` regardless — this
  turns a silent corruption into a message.

  That rule is enforced at **three** points, not one. `module_selection` is the
  elegant single place, and it only ever runs on the `plan_defaults` path: a
  `SITEGRAFT_MANIFEST_PREFILLED` or hand-edited manifest — both documented
  workflows for repairing or resuming a run — reaches `graft` without passing
  through it, and `manifest_validate` used to check nothing but migrate/protect
  overlap. So the same rule now also runs in `manifest_validate` (which
  `manifest_freeze` gates on), and again in `graft_migrate_options`, whose key
  loop is the thing that writes to B's live database and which a manifest edited
  *after* freezing never revalidates. That loop also stopped relying on unquoted
  word splitting — it reads over fd 3 — so an unguarded name can no longer become
  two `wp option update` calls against names nobody planned.

- **`theme_mods_<slug>` is rewritten before it lands on B, not copied.** #15 made
  the key migratable, and every `theme_mods_` row is full of the *source* site's
  own local IDs: `custom_logo` (an attachment), `nav_menu_locations` (terms),
  `custom_css_post_id` (a post). None of them is remapped by
  `graft_remap_attachment_ids`, which only ever rewrites `post_content` and
  `post_excerpt`, never an option value — so a straight copy is the same defect
  §9.3 already documents for `page_on_front`, one option over. Its failure mode is
  the worse of the two: if B happens to own an attachment carrying A's number,
  B's logo silently becomes a *different, wrong image* rather than a missing one,
  and nothing on B looks broken enough to prompt a second look.

  `core_wp_post_import` (which runs immediately after `graft_migrate_options`, so
  the values are on disk and B has already received the unfixed one) remaps
  `custom_logo` through `id-map.tsv` and **removes** `nav_menu_locations` and
  `custom_css_post_id`: sitegraft v1 migrates neither classic menus (design doc
  §13) nor `custom_css`, so B has no counterpart for those ids and the map has no
  rows for them — removing the key restores WordPress's own "not configured"
  default. When `id-map.tsv` has no row for the logo, the key is **dropped, out
  loud**, never guessed at.

- **A failed `plan` names the stale manifest it did not replace.** "no manifest
  will be frozen from this run" is true and misleading in the same breath: a
  `manifest.json` from an earlier, successful plan is still in the run directory,
  still `frozen: true`, and `graft` reads that file and nothing else. It is named
  on every failure path, together with what running `graft` would do — and
  deliberately **not** deleted, since removing an operator's frozen plan on a
  failure path is destructive and the old plan may be exactly what they intend to
  run.

- **`graft` no longer writes the literal `null` for a key A does not have.**
  `wp option get` exits non-zero for a missing option, and the fetch used to fall
  back to `|| echo 'null'` and push that to B — *erasing* B's own value. A site A
  without Etch's Loop Manager has no `etch_cfs`, but `etch_option_keys` is a
  static allowlist that names it regardless, so `graft` ran
  `option update etch_cfs null` on B. `core_wp_option_keys_dynamic`'s own header
  comment already warned about precisely this mechanism ("claiming a key A does
  not have would BLANK B's own theme_mods") — documented there, unguarded in
  `graft`. A key A does not have is now skipped, out loud, and no
  `option-<key>.value` file is left behind for a `post_import` hook to act on.
