# Idea & Vision — sitegraft

## Problem

Marcel regularly rebuilds existing WordPress sites in Etch/ACSS. The target site
("B") is often already in production with a business plugin loaded with real,
non-negotiable data (e.g. a booking plugin with live customer reservations). The
redesign must replace ONLY the design/content layer (theme, pages, templates,
navigation, styles) — never touch B's business plugin's data or configuration.
Today this is done by hand, site by site, with no tooling: slow, non-reproducible,
and risky (a bad search-replace or a hand-filtered raw SQL export can corrupt a
client's production data).

## Solution / value proposition

sitegraft is a bash CLI that wraps this move into separate, inspectable, replayable
phases: scan both sites, decide precisely what to migrate and what to protect, back
up B before any change, run the transfer through WordPress's own native mechanisms
(WXR + wp-cli, never raw SQL filtered by hand for content), verify the result, and
allow a one-command rollback. The pluggable module system turns every new business
plugin (MotoPress today, something else tomorrow) into a simple file declaration,
with no changes to the tool's core — making it directly reusable across all of
Marcel's future Etch migrations, whatever plugin B needs protected.

## Target / users

- **Sole current user: Marcel**, as the operator running Etch migrations for his
  own projects and his clients' (agencies, brochure sites, business sites).
- No multi-user, no SaaS, no web UI: a personal tool built to the standard of a
  real internal product, published open-source for visibility (public repo) but
  with no commercial ambition at this stage.

## Scope

**In scope:**
- Migrating site A (a freshly built Etch/ACSS site) → site B (an existing, live
  site), one run at a time, one site pair at a time.
- Protection/migration modules for WordPress core content + Etch + ACSS from v1;
  extensible by file for any future business plugin.
- A full backup of B before any write, restore via a single script.
- Local execution (Mac/Linux/WSL) driving A and B remotely via SSH/wp-cli, or
  locally via DDEV.
- Validation through a DDEV test harness (2 disposable sites); no production pilot
  run planned while the tool is being built.

**Explicitly out of scope:**
- No MCP, no web UI, no WordPress plugin installed on A or B.
- No multi-site batch support (one A→B pair per run).
- No native Windows support (WSL yes, native cmd/PowerShell no).
- No migration of third-party plugins themselves (only protecting their data) —
  sitegraft never installs/configures a business plugin on B.
- No continuous / bidirectional sync: sitegraft does a one-time A→B transfer, not
  replication.

## Context & history

Born from a brainstorming session with Marcel on 2026-08-19, motivated by the
concrete case of a site B running MotoPress Hotel Booking in production with live
reservations. Every architecture decision (name, modular bash CLI approach,
WXR/wp-cli base, module system, separate phases, interactive selection, backup
strategy, ID mapping via a temporary mu-plugin, portability) was locked in before
the design doc was written — see
`docs/superpowers/specs/2026-08-19-sitegraft-design.md` for the full detail and
reasoning.
