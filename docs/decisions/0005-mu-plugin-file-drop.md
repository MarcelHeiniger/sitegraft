# ADR 0005 — Mapping mu-plugin delivered by file drop, not `wp plugin install`

**Date:** 2026-08-19 · **Status:** proposed (Rosalinde's decision, pending Marcel's validation)

## Context

The mandate calls for a temporary mu-plugin on B to log the ID mapping during the
WXR import (see design doc §7). Two ways to place it: (a) as a real WordPress
plugin installed via `wp plugin install`/`wp plugin activate`, or (b) as a
"must-use plugin" — a PHP file simply dropped into `wp-content/mu-plugins/`, which
WordPress loads automatically with no activation step.

## Decision

File drop via `rsync` into `wp-content/mu-plugins/`. Removed by deleting the same
file at the end of the `graft` phase.

## Consequences

- (+) No activation state to manage on the wp-cli side — an mu-plugin present is
  loaded, one absent isn't. No risk of a "plugin left activated" if the run
  crashes midway.
- (+) A single file to transfer and delete — a simple move, easy to make
  idempotent and to verify in `verify`/post-crash cleanup.
- (−) Must-use plugins don't natively support WordPress's usual
  activation/deactivation hooks (`register_activation_hook`) — no consequence
  here, since the mu-plugin only needs to hook into `wp_import_insert_post`,
  which fires as soon as the file is present during the import.
- (−) If `wp-content/mu-plugins/` doesn't yet exist on B (rare but possible on a
  very minimal install), `graft` must create it before the `rsync` — noted as a
  prerequisite in the implementation plan.
