# ADR 0002 — Manifest as JSON, parsed via `jq`

**Date:** 2026-08-19 · **Status:** proposed (Rosalinde's decision, pending Marcel's validation)

## Context

The manifest produced by `plan` and consumed by `graft` needs to represent a nested
structure: per module, a list of post_types, a list of option_keys, a list of
tables, plus a default-deny `_unclaimed` bucket and checksums computed later by
`backup`. A flat KEY=VALUE format (like the profiles) can't cleanly represent that
nesting without fragile naming conventions (`MIGRATE_ETCH_POST_TYPES="a b c"`, etc.).

## Decision

The manifest is a JSON file, read and written exclusively via `jq` inside
`lib/manifest.sh`.

## Consequences

- (+) Native nested structure, readable, versionable, diffs cleanly in git (useful
  if a reference manifest ever gets committed for a test).
- (+) `jq` is nearly universal (`brew install jq`, `apt install jq`, already present
  on many dev machines).
- (−) A new mandatory runtime dependency (not just a test one) — added to the
  preflight check list (`sitegraft` must verify its presence and fail cleanly with
  an install hint otherwise).
- (−) Handling JSON in bash is more verbose than plain shell variables — accepted
  as a reasonable cost given the shape of the problem.
