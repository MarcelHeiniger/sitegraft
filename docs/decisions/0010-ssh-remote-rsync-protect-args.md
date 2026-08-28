# ADR 0010 — the ssh-remote restore requires a LOCAL rsync that default-escapes its arguments; it does NOT use `--protect-args`

**Date:** 2026-08-28 · **Status:** accepted (revised same day — see History)

## Context

The ssh-remote branch of the generated `restore.sh` (`backup_generate_restore_script`
in `lib/backup.sh`) restores `wp-content` with:

```sh
rsync -avz --delete <local archive>/ <SITE_B_SSH_HOST>:<SITE_B_WP_PATH>/wp-content/
```

Every operator-supplied value baked into `restore.sh` goes through `sq()`
(single-quote it as a shell literal), which protects the LOCAL shell that
parses `restore.sh` itself. It does not protect anything beyond that: the
text after `SITE_B_SSH_HOST:` is read by `rsync`, which then builds its OWN
remote command line (to invoke `rsync --server` on the far end) and hands
that to `ssh` — a second, independent command-construction step that
happens inside `rsync`, on the far end, after `restore.sh` has already
finished running. Whether that second command line protects shell
metacharacters in the destination path is rsync's own behavior, not
something this script's quoting can reach.

That behavior differs by implementation AND, within GNU rsync, by version —
both measured directly, live, not assumed from documentation.

### Measurement 1 — does the LOCAL rsync escape the destination by default?

Using a loopback `ssh` stand-in that reproduces real ssh's own documented
behavior (join every argument after the host with a single space, hand the
result to the remote user's shell) without a real remote host:

- **GNU rsync 3.4.4** backslash-escapes the destination by default — no flag
  needed. `$(touch PWNED)` embedded in the destination round-trips as inert
  text. Running the SAME command with `--old-args` (GNU rsync's explicit
  opt-OUT of this default) reproduces the injection: `PWNED` gets created.
  This default was added in **rsync 3.2.4 (15 April 2022)** — confirmed via
  `man rsync`'s own text under `--secluded-args`, its current name ("the
  default backslash-escaping of args that was added in 3.2.4"). It is
  **not** the same thing as `--protect-args`/`-s`, which is older (3.0.0,
  2008) and, on those older versions (3.0.0–3.2.3), had to be requested
  explicitly — those versions do not escape by default.
- **`/usr/bin/rsync` on macOS** is not GNU rsync. It is `openrsync`
  (OpenBSD's implementation, adopted by Apple after GNU rsync's licence
  moved to GPLv3 — the only rsync macOS ships as of macOS 15). It performs
  **no escaping at all**, ever, and implements neither `--protect-args`/`-s`
  nor `--old-args`.

### Measurement 2 — what does `--protect-args` do to the REMOTE side?

This is where the first version of this ADR was wrong, and was corrected
same-day in review. `--protect-args` does not only change how the local
`rsync` builds its command line — it also changes what the local `rsync`
*sends to the remote `rsync --server` process*, which has to understand the
new argument-passing mode too. Measured with a REAL local GNU rsync 3.4.4
client against a REAL local openrsync SERVER (both actually invoked, not
simulated, via a loopback `ssh` that dispatches to a genuine `rsync
--server` on the "remote" side):

- **Without `-s`**: the transfer succeeds. GNU's default escaping (3.2.4+)
  is a purely client-side, wire-protocol-transparent behavior — it needs
  nothing from the remote `rsync` at all.
- **With `-s` (`--protect-args`)**: the client sends `--server -s...`;
  openrsync's own argument parser on the far end does not recognize `-s` and
  rejects it; the connection dies with `error in rsync protocol data stream
  (code 12)`. `man rsync` documents `-s` as "refused by restricted shells"
  for the same underlying reason — and a forced-command, restricted-shell
  SSH account (`rrsync` or equivalent) is a standard hardening for a backup
  target, i.e. squarely a realistic B, not an edge case.

So `--protect-args` is strictly a WORSE trade than no flag at all: it closes
the gap only for a local-openrsync operator (who it also can't help, since
openrsync doesn't implement the flag either — the check below refuses for
them regardless), while actively BREAKING every ssh-remote restore whose B
enforces a restricted shell or runs an rsync that predates the flag's
protocol variant — a regression this project has no basis for assuming away.

## Decision

1. **The rsync invocation is unchanged** — still plain `rsync -avz --delete`,
   exactly as before this issue. No `--protect-args`, no `-s`.
2. `restore.sh` instead verifies, at runtime, that the LOCAL rsync
   default-escapes: the probe is `rsync --old-args --version` (see the
   `_sg_check_rsync_arg_escaping` function in the generated script) —
   `--old-args` is the explicit opt-OUT of the 3.2.4+ default, so a rsync
   that recognizes it is, by construction, one that escapes by default when
   the flag is absent (exactly how the real restore command runs). If the
   probe fails, `restore.sh` refuses with an explicit, actionable message —
   naming `openrsync`, the actual version floor (3.2.4), and the
   `brew install rsync` remedy — rather than a bare `rsync: unrecognized
   option` mid-restore, or (worse) a silent, successful-looking restore that
   never protected the path at all.
3. The check runs once, immediately before the wp-content restore step it
   gates — not earlier. It is skipped entirely under `--dry-run`, which
   never invokes rsync and therefore never needs it (an earlier draft ran
   the check unconditionally near the top of the script and made `--dry-run`
   refuse too, defeating the one thing a dry run exists for: a safe preview
   on a target this exact check would otherwise block). It also
   distinguishes "rsync is not installed at all" from "rsync is installed
   but lacks this capability" — two different problems with two different
   remedies — rather than reporting the second for both.
4. This is a real, load-bearing version/implementation requirement, and it
   is written down here rather than left implicit: **the ssh-remote restore
   path requires a GNU-rsync-compatible `rsync` >= 3.2.4 resolved first on
   `PATH`, on the LOCAL (orchestrator) machine, at restore time.** Nothing
   is required of B's rsync. `docs/usage.md`'s existing `brew install
   rsync` / `apt install rsync` step already satisfies this for anyone who
   follows it; what this ADR adds is that the requirement is now enforced
   for the ssh-remote wp-content step specifically, not merely suggested
   project-wide.

## Alternatives considered, and rejected

- **`--protect-args`/`-s`.** This was the FIRST version of this fix, shipped
  and then reverted in the same review round: Measurement 2 above is why —
  it breaks a real, common B configuration (restricted-shell / rrsync-style
  forced-command SSH accounts) that the unmodified `rsync -avz --delete`
  command has always worked against.
- **Do nothing beyond documenting it.** Rejected: the vulnerability this
  closes (issue #44) is exactly the case that hardening a documentation page
  cannot fix — an operator who never reads it is the one still exposed.
- **Escape the destination path manually** (backslash-escape shell
  metacharacters before handing the path to rsync, so even an rsync that
  doesn't escape by default — openrsync — would receive an already-safe
  string). Considered because openrsync passes an already-escaped string
  through unmodified (measured), so this WOULD work against it. Rejected for
  this fix anyway: it makes this script responsible for enumerating every
  character a remote `/bin/sh` treats as special, forever, and getting that
  list wrong once is worse than refusing outright — GNU rsync's own default
  escaping (3.2.4+) already does this correctly and is the dependency this
  fix chooses to require instead of re-implementing it.
- **Detect the REMOTE rsync's capability too** (SSH to B during the restore
  and probe there as well, so the check could adapt — e.g. still choose
  `--protect-args` when both ends support it). Rejected as unnecessary
  complexity for what default-escaping already solves single-sided: since
  the chosen fix needs nothing from B at all, there is no remote state left
  to detect.

## Consequences

- (+) Closes the remote-shell-expansion vulnerability (issue #44) for every
  local rsync >= 3.2.4 (both of this project's own documented install
  paths), with **no new requirement on B's rsync or shell** — a restricted-
  shell / rrsync B that worked before this fix still works after it.
- (+) Where the local rsync cannot meet this (openrsync, or GNU rsync
  < 3.2.4), the failure mode changes from "silently vulnerable" to "loudly
  refuses, names the fix, and does not fire under `--dry-run`" — safer than
  the unpatched behavior for that local rsync, and NOT the strict
  improvement over every alternative this ADR's first draft claimed: it is
  worse than doing nothing for the one case measurement 2 describes, which
  is exactly why that alternative (`--protect-args`) was not the one shipped.
- (−) A restore run with a local rsync that isn't GNU >= 3.2.4 (openrsync,
  or an old GNU rsync) now refuses outright rather than proceeding
  (unsafely, for openrsync; safely but undetected, for old GNU rsync without
  `--protect-args` requested). This is accepted: sitegraft's own documented
  install instructions already ask for a real, current rsync; this makes
  that requirement load-bearing instead of silently optional. There is
  deliberately no override for an operator who cannot install a newer rsync
  and whose `SITE_B_WP_PATH` is known to be free of anything that needs
  escaping — fail-closed with no escape hatch is accepted as the cost of a
  security fix that a human cannot audit case-by-case at restore time; a
  future request to add one should be weighed against that reasoning
  explicitly, not treated as a bug in this decision.
- (−) The two `ssh` invocations on the same branch (the `mkdir -p` and the
  piped `wp db import`) needed no equivalent change — verified live with the
  same loopback technique: `sq()` applied twice (once for the remote shell,
  once for the local one that reads `restore.sh`) already protects them,
  because both are ONE command string this script itself hands to a remote
  shell it explicitly invoked, not a second command-line construction step
  happening inside another program. Recorded here so a future reader does
  not go looking for a matching fix on those two lines and wonder why there
  isn't one.

## History

This ADR originally recommended `--protect-args`/`-s`, on the strength of
Measurement 1 alone (local escaping behavior) without checking what the flag
requires of the REMOTE `rsync --server` process. Review caught this before
merge: a live test against a real openrsync server (Measurement 2) showed
`-s` breaks the connection outright, and `man rsync`'s own "refused by
restricted shells" note explains why in general. The same review also
caught that the original text mis-cited default escaping as a 3.0.0 feature
(that is `--protect-args`'s own introduction date; default escaping is
3.2.4). Both are corrected above; the decision itself changed from
"add `--protect-args`" to "require default escaping instead."

## Reopening condition

Revisit if a local rsync that cannot reach 3.2.4 (or an equivalent) needs to
become a supported way to run restore.sh — at that point the manual-
escaping alternative above, or requiring the operator's `rsync-path` to
point at a GNU-compatible binary explicitly, would need a real design pass
rather than a silent fallback.
