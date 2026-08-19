# ADR 0001 — Modular bash CLI with separate phases

**Date:** 2026-08-19 · **Status:** accepted

## Context

Marcel regularly rebuilds WordPress Etch/ACSS sites and has to repeat, by hand, the
job of replacing a live target site's design/content layer without touching its
business plugins' data. Several architectures were possible: a WordPress plugin
installed on the target site, a web application (MCP/UI), or a standalone CLI
driven from a third machine.

## Decision

sitegraft is a plain bash CLI (no Python/Node, no WordPress plugin, no web UI, no
MCP), organized into independent, re-runnable phases
(`scan → plan → backup → graft → verify → restore`), with a file-based pluggable
module system to declare what should be migrated vs. protected depending on which
business plugin is present on the target site.

## Consequences

- (+) No persistent installation on A or B — the tool leaves no trace once a run
  finishes (aside from the temporary mu-plugin, removed at the end of `graft`).
- (+) Each phase is independently inspectable and re-runnable — an interrupted
  `graft` doesn't force redoing an already-completed `scan`/`plan`/`backup`.
- (+) The module system makes the tool reusable across every future Etch
  migration, whatever business plugin the target site runs, with no changes to
  the core.
- (−) No graphical interface — all interaction stays on the command line
  (`gum`/`fzf` for the interactive parts), acceptable for a single-operator tool.
- (−) Bash portability imposes code style constraints (see ADR 0003).
