# ADR 0003 — Target bash 3.2 compatibility (no associative arrays)

**Date:** 2026-08-19 · **Status:** proposed (Rosalinde's decision, pending Marcel's validation)

## Context

The mandate calls for portability across "any Mac or PC, macOS + Linux/WSL" with
minimal dependencies, and explicitly asks to "decide and document" the targeted
bash version. macOS ships bash 3.2 by default (the last version under the GPLv2
license — Apple never updated to GPLv3-licensed bash 4+). The module registry
system (design doc §3) would naturally have used an associative array
(`declare -A`) — available only from bash 4 onward.

## Decision

sitegraft targets bash 3.2 compatibility. No associative arrays, no `mapfile`, no
`${var,,}` (native lowercase, bash 4+ only). The module registry is a plain
space-separated string of names, walked with a classic `for` loop; an optional
module function's presence is checked with `type -t`.

## Consequences

- (+) Runs with nothing extra to install on a Mac straight out of the box.
- (+) Consistent with the mandate's "minimal dependencies" spirit.
- (−) Slightly more verbose code style in places (no bash 4+ syntactic sugar) —
  accepted, documented in the project's `CLAUDE.md` as a code convention.
- (−) If the tool grows a lot (dozens of modules), the lack of an associative
  array could become awkward — not applicable in v1 (3 modules), to be revisited
  if the module count outgrows what flat lists handle comfortably.
