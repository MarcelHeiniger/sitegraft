# ADR 0009 — restore.sh refuses (and tells the operator how to fix it by hand)
rather than normalize a Unicode mismatch

**Date:** 2026-08-28 · **Status:** accepted

## Context

An accented filename has two legal UTF-8 encodings: NFC (an accented
character as one code point, e.g. `é` = `C3 A9`) and NFD (the base letter
plus a separate combining mark, e.g. `e` + `CC 81`). The wrapped-local
restore path (issue #14 / #35's manifest-driven prune) decides what to
delete from B's `wp-content` by comparing, as raw bytes, the paths this
backup's archive holds against the paths B currently reports. If the same
file is spelled with one encoding in the archive and the other on B, the
comparison sees two different paths — and on the "B minus archive" side,
that reads as "added since the backup," which reads as "delete it."

`_sg_assert_backup_landed` (`lib/backup.sh`) exists to catch exactly this
before anything is removed: after extracting the archive onto B, every path
the archive holds must now be reported by B, byte for byte. If it is not —
because the extraction genuinely failed to land a file, or because B is
showing the same file under the other normalization — the script refuses to
remove anything and exits non-zero. That refusal is correct and is not up
for debate here: deleting a file the backup contains because its name is
spelled with a different byte sequence would be silent, irreversible data
loss.

What issue #45 found is narrower: the refusal, as originally written, named
the paths it could not account for and stopped there. It never told the
operator *why*, in plain terms, or what to do next — and `restore` is the
command reached for when something has already gone wrong, which is the
worst possible moment to hand back an unexplained dead end.

Verified during review: in the real DDEV topology this ships against (target
inside a Linux container, orchestrator on macOS), the archive is NFC, the
manifest is NFC, and an accented filename round-trips intact — the
extraction itself resolves any mismatch by renaming B's file to the
archive's form (measured; see `backup_generate_restore_script`'s own block
comment on this). The refusal only fires when a backup taken under one
normalization regime is restored onto a target that is already showing the
other — in practice, a run directory produced on one machine and restored
via a different one, which is not a flow sitegraft currently claims to
support.

## Decision

1. **The refusal stays fail-closed.** Nothing changes about *when*
   `_sg_assert_backup_landed` fires or what it protects.
2. **The message now does two more things**: it names the situation in one
   sentence ("the backup and the target disagree on Unicode normalization
   for N path(s)"), and it states the manual remedy — find the same file on
   B under its current spelling and rename it to match the byte sequence the
   backup prints, then re-run. It also still allows for the rarer case (the
   extraction genuinely did not land a file) and says how to tell the two
   apart, and names the one case where the remedy itself cannot work: a
   normalization-INSENSITIVE target filesystem (macOS's own APFS, by
   default) where the rename is a true no-op — there, the message says to
   apply the backup by hand outside sitegraft instead of re-running into the
   same refusal indefinitely.
3. **The backup does NOT record which normalization it was taken under**,
   and restore.sh does NOT gain a normalizing pass. Both were considered and
   rejected for this fix (see Alternatives).

## Alternatives considered, and rejected for now

- **Record the normalization form in the backup manifest**, so a restore
  could detect the mismatch up front, before extraction, instead of after.
  Rejected: it does not remove the need for a manual remedy (the mismatch
  still has to be resolved by hand somehow), and it adds a field to a
  manifest format whose only current job is proving archive completeness —
  scope this codebase's own `manifest.sh` conventions do not otherwise carry.
  Worth revisiting if backup-on-one-machine / restore-from-another becomes
  an intentionally supported flow rather than an edge case.
- **Normalize automatically** (rewrite one side to match the other before
  comparing). Rejected on principle, not convenience: `restore.sh`
  deliberately depends on nothing but `ssh`, `rsync`, `tar`, `gzip`, `find`,
  `sort`, `comm`, `cmp`, `mktemp`, `wc`, `xargs` (its own header comment
  names most of these — `ssh`/`rsync`/`tar`/`gzip`/`wc`, plus, on a
  wrapped-local target, `find`/`sort`/`comm`/`mktemp`/`xargs` — `cmp` is used
  by `_sg_apply_prune` and is not separately called out there; listed here
  in full for accuracy, without effect on the argument, since none of them
  normalize either way) — a genuine Unicode normalization table
  (`iconv -f UTF-8-MAC`, `uconv`, Python's `unicodedata`) is not guaranteed
  to exist on whatever machine ends up running a restore, sometimes years
  after the backup was taken. A silent,
  best-effort normalize-and-hope is also just a slower way to arrive at the
  same wrong-file-deleted risk this refusal exists to prevent, if the guess
  is wrong.

## Consequences

- (+) An operator who hits this refusal now learns what happened and what to
  do about it, without reading this ADR or the source.
- (+) No new dependency, no new manifest field, no change to what gets
  detected or when.
- (−) The remedy is manual, one file at a time. For a backup with many
  affected paths this is tedious — accepted, because the scenario that
  triggers it (cross-machine backup/restore) is not one sitegraft currently
  supports at all, and the alternative (guessing which byte sequence is
  "right" and normalizing) trades a tedious-but-safe recovery for a fast,
  silent risk of deleting the wrong file.

## Reopening condition

Revisit recording the normalization form in the manifest (or detecting the
mismatch pre-extraction) if sitegraft ever adds backup-on-one-machine /
restore-via-a-different-machine as a real, intentionally supported flow —
at that point the mismatch stops being a rare edge case and the manual
per-file remedy stops being cheap enough to leave as the only answer.
