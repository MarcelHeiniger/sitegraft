# ADR 0006 — `bats-core` for `lib/`'s unit tests

**Date:** 2026-08-19 · **Status:** proposed (Rosalinde's decision, pending Marcel's validation)

## Context

The mandate calls for TDD "where it makes sense — `lib/`'s pure functions are
testable with bats," which already implies bats without naming it explicitly as a
dependency. The precise framework choice and its scope (unit tests only, with
integration left to the DDEV harness) still needed to be locked in.

## Decision

`bats-core` for every unit test under `tests/unit/*.bats`, targeting `lib/`'s pure
functions (parsing, validation, formatting — anything that touches neither SSH nor
wp-cli nor a real site's filesystem). A test-only dependency, never required for
the tool's normal execution.

## Consequences

- (+) The standard framework for testing bash, declarative syntax close to
  conventional unit tests (`@test "description" { ... }`), integrates natively
  with `set -euo pipefail`.
- (+) Cleanly separates what's fast to test (pure functions, `bats`) from what
  needs the full DDEV harness (anything touching a real WordPress site).
- (−) A new development dependency (`brew install bats-core` /
  `npm install -g bats` / cloning the repo) — no impact on the tool's end user,
  only on whoever contributes code.
