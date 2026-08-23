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
shipped a module that copies license keys — and, in Etch's case, an `ai_api_key` —
from one site to another. The code read as if it were handled. Both shipped modules
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
  keyed by name, each also as a JSON string (the scan records whatever
  `wp option list --format=json` produced, and unserialization behaviour differs
  across wp-cli versions). A value it cannot read is an **error**, not an empty
  list — the two are indistinguishable from the outside, and treating the first as
  the second silently reproduces the exact defect this closes. A declared name the
  scanned site does not actually register is **dropped, with a warning**: offering
  a post type that does not exist is how `graft` came to export an empty WXR while
  `verify` reported PASS (CLAUDE.md's first rule, in its original form).

## Consequences

- (+) `<mod>_option_keys_exclude` does what the documentation always said it did.
  A broad prefix plus exclusions is now a safe, supported way to write a module,
  which is what makes the pattern usable for plugins with dozens of options.
- (+) A module can express a claim whose *names* come from the scanned site, which
  is what #15 and #16 both needed. The core learned one general capability instead
  of two special cases, and adding a module still requires zero changes to `lib/`
  or `bin/`.
- (+) `plan` now stops on a module that cannot answer, instead of planning a
  quietly smaller migration.
- (−) A broken third-party module can now block `plan` outright. Deliberate: the
  alternative is a run that silently migrates less than it says. Mitigated by
  `SITEGRAFT_MANIFEST_PREFILLED` and by an error message that names the function.
- (−) `etch_post_types_dynamic` reads a structure that has been observed on a real
  site but not verified field by field. It is written to accept three plausible
  shapes and to fail loudly on anything else, rather than to guess. If a real site
  turns up a fourth shape, `plan` says so by name instead of migrating half of it.
- (−) `<mod>_tables_dynamic` is supported and unused. Kept for contract
  uniformity: a rule of the form "these two kinds can be dynamic, that one cannot"
  is a rule every module author has to look up, and it costs nothing here.
- (−) Two names that a module legitimately owns but that carry a comma or
  whitespace are now rejected at plan time. No WordPress post type can contain
  either, and an option key that does could not survive `graft` regardless — this
  turns a silent corruption into a message.
