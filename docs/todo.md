# Todo — sitegraft

> Current backlog. Prioritized. Reflects the live state (task API) after each
> "update the project".
> **Last sync: 2026-08-19**

## Next steps (priority)

- [ ] Marcel's go-ahead on the 5 open technical decisions (`docs/status.md` →
      Recent decisions)
- [ ] Start plan Step 1: core + profiles/credentials + scan
      (`docs/plans/2026-08-19-sitegraft-implementation.md`)
- [ ] Step 2: manifest + interactive selection (`gum choose`, fallback `fzf`)
- [ ] Step 3: backup + restore
- [ ] Step 4: graft (media → WXR import → mu-plugin mapping → remaps)
- [ ] Step 5: verify + DDEV integration harness
- [ ] Step 6: polish (dry-run everywhere, `docs/usage.md`, LICENSE, public README)

## Backlog

- [ ] The hypothetical `motopress.sh` module — written as a worked example in the
      design doc, not yet implemented or tested against a real MotoPress install
- [ ] A detailed `docs/usage.md` (beyond the README) if the README grows too long
- [ ] An install script (`install.sh` or Homebrew/apt instructions for the
      dependencies: `jq`, `gum`, `rsync`, `bats-core`)

## Ideas / later

- Support a "diff report" output mode for `verify` (HTML or markdown) — YAGNI for
  v1, revisit once the tool has been used on a real run
- Possible Homebrew publication (`brew install sitegraft`) if the tool sees use
  beyond Marcel — out of scope for v1

## Recently done

- [x] Design doc + implementation plan + skeleton delivered (2026-08-19, Rosalinde)
- [x] Full repo rewritten in US English for public release (2026-08-19, Rosalinde)
