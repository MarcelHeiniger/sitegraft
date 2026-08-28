# ADR 0010 — the ssh-remote restore requires an rsync that supports
`--protect-args`

**Date:** 2026-08-28 · **Status:** accepted

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

That behavior turns out to differ by implementation. Measured directly (this
review, 2026-08-28), using a loopback `ssh` stand-in that reproduces real
ssh's own documented behavior (join every argument after the host with a
single space, hand the result to the remote user's shell) without a real
remote host:

- **GNU rsync 3.4.4** (Homebrew on macOS, the default via `apt` on
  Debian/Ubuntu — both already this project's documented install path, see
  `docs/usage.md`) escapes shell metacharacters in the destination by
  default, even *without* `--protect-args`. `--protect-args` (`-s`) makes it
  stronger still: with the flag, the destination never becomes command-line
  text at all — it travels over rsync's own protocol instead.
- **`/usr/bin/rsync` on macOS** is not GNU rsync. It is `openrsync`
  (OpenBSD's implementation, adopted by Apple after GNU rsync's licence
  moved to GPLv3 — the only rsync macOS ships as of macOS 15). It performs
  **no escaping at all**: a destination of `host:/tmp/x $(touch PWNED)y/`
  round-tripped through the loopback harness and the embedded command ran.
  It also does not implement `--protect-args` (or its short form `-s`) at
  all — passing either exits immediately with `rsync: unrecognized option`.

sitegraft's own `docs/decisions/0003-bash-compatibility.md` already commits
this project to "any Mac or PC, macOS + Linux/WSL" as a first-class target,
and `docs/usage.md`'s own install step already asks macOS users to
`brew install rsync` — but nothing enforced that a real GNU rsync (rather
than whatever `rsync` happens to resolve first on `PATH`) is actually what
runs a restore, possibly much later, possibly on a machine or in a shell
(cron, a minimal-PATH launchd job) that never sourced the profile that put
Homebrew first on `PATH`.

## Decision

1. The ssh-remote wp-content restore command gains `--protect-args`.
2. `restore.sh` probes for support (`rsync --protect-args --version`) before
   attempting the restore, on the ssh-remote branch only, and refuses with an
   explicit, actionable message — naming `openrsync` and the `brew install
   rsync` remedy — rather than letting a bare `rsync: unrecognized option`
   surface partway through a restore. See the `NEEDS_RSYNC_PROTECT_ARGS`
   check in the generated script (issue #44).
3. This is a real, load-bearing version/implementation requirement, and it is
   written down here rather than left implicit: **the ssh-remote restore
   path requires a GNU-rsync-compatible `rsync` (>= 3.0.0, which is when
   `--protect-args` was introduced) resolved first on `PATH` at restore
   time.** `docs/usage.md`'s existing `brew install rsync` / `apt install
   rsync` step already satisfies this for anyone who follows it; what this
   ADR adds is that the requirement is now enforced, not merely suggested.

## Alternatives considered, and rejected

- **Do nothing beyond documenting it.** Rejected: the vulnerability this
  closes (issue #44) is exactly the case that hardening a documentation page
  cannot fix — an operator who never reads it is the one still exposed.
- **Escape the destination path manually instead of using `--protect-args`**
  (backslash-escape shell metacharacters before handing the path to rsync).
  Considered because it would work on any rsync implementation, including
  openrsync, which passes an already-escaped string through unmodified
  (measured). Rejected for this fix: it re-introduces exactly the
  completeness problem `--protect-args` exists to avoid — this script would
  be responsible for enumerating every character a remote `/bin/sh` treats
  as special, forever, instead of relying on rsync's own protocol bypass.
  `--protect-args` is the robust mechanism; failing loudly on rsync
  implementations that lack it is a smaller, more honest surface than a
  hand-rolled escaper this codebase would have to keep correct.
- **Silently fall back to unprotected `rsync --delete`** when
  `--protect-args` is unsupported. Rejected outright: that is choosing to
  ship the exact vulnerability issue #44 reports, on exactly the platform
  (`macOS`, `docs/decisions/0003`) this project explicitly targets.

## Consequences

- (+) Closes the remote-shell-expansion vulnerability (issue #44) for every
  rsync that supports `--protect-args` — which includes both of this
  project's own documented install paths.
- (+) Where it does not close the gap (openrsync, or any other rsync without
  the flag), the failure mode changes from "silently vulnerable" to "loudly
  refuses, names the fix" — strictly safer, never a worse outcome than
  before this change.
- (−) A restore run against openrsync now fails outright rather than
  succeeding (unsafely). This is accepted: sitegraft's own documented
  install instructions already ask for a real rsync; this makes that
  requirement actually load-bearing instead of silently optional.
- (−) The two `ssh` invocations on the same branch (the `mkdir -p` and the
  piped `wp db import`) needed no equivalent change — verified live with the
  same loopback technique: `sq()` applied twice (once for the remote shell,
  once for the local one that reads `restore.sh`) already protects them,
  because both are ONE command string this script itself hands to a remote
  shell it explicitly invoked, not a second command-line construction step
  happening inside another program. Recorded here so a future reader does
  not go looking for a matching fix on those two lines and wonder why there
  isn't one.

## Reopening condition

Revisit if openrsync (or another non-`--protect-args` rsync) needs to become
a supported target — at that point the manual-escaping alternative above, or
requiring the operator's `rsync-path`/`--rsync-path` to point at a
GNU-compatible binary explicitly, would need a real design pass rather than
a silent fallback.
