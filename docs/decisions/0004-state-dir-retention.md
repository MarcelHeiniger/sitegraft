# ADR 0004 — Run state directory: location and manual retention

**Date:** 2026-08-19 · **Status:** proposed (Rosalinde's decision, pending Marcel's validation)

## Context

Every sitegraft run produces sensitive artifacts that need to be kept at least
until fully verified: the frozen manifest, the ID correspondence table, a full
backup of B, per-phase logs. A decision was needed on where these artifacts live
on the orchestrating machine, and if/when they get cleaned up automatically.

## Decision

`~/.sitegraft/runs/<profile>-<timestamp>/` on the orchestrating machine. No
automatic cleanup — deletion is a manual operator action.

## Consequences

- (+) A run's backup stays available until the operator explicitly deletes it —
  no risk of a `restore.sh` pointing at a backup that got auto-purged at the wrong
  moment.
- (+) Each run is isolated and timestamped, independently inspectable.
- (−) Potential buildup over time if the tool is used often (full site backups) —
  no purge command in v1 (YAGNI, see `docs/todo.md` → Ideas/later — a
  `sitegraft prune` could be added later if the need is confirmed).
- (−) No automatic guard against a full disk — left to the operator to watch for
  now.
