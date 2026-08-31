#!/usr/bin/env bash
# lib/backup.sh — phases: backup, restore. Full DB + wp-content export of B,
# pulled to the orchestrator, plus a normalized checksum snapshot of protected
# data and a genuinely self-contained restore.sh (design doc §6.3/§6.7, review
# findings A2, A3, A5).

# design doc §6.3, review finding A5: `wp db export` shells out to mysqldump,
# whose output embeds a "-- Dump completed on ..." timestamp comment (and
# other "-- "-prefixed comment lines) that differs between two exports of
# byte-identical data taken seconds apart. Stripping every "-- "-prefixed
# line before hashing makes the checksum depend only on the actual data. This
# exact function is reused, unmodified, by `backup` (below), `verify` (Step
# 5), and the DDEV harness (Task 3.2) — one implementation, so the three call
# sites can never drift (the bug finding A5 exists to prevent).
#
# `grep -v ... || true` — plan bug found and fixed here, not present in the
# plan's original pseudocode: under `set -o pipefail` (bin/sitegraft's own
# mode, and the DDEV harness's), `grep -v` that matches ZERO lines exits 1 —
# content that is empty, or is entirely "-- " comment lines (a legitimately
# possible `wp db export --tables=` result for an empty table), would make
# this whole pipeline report failure even though shasum/awk go on to compute
# a perfectly valid checksum of empty input right after it. Same guard
# already established in lib/plan.sh's _plan_apply_selection for the
# identical reason.
backup_checksum() {
  printf '%s' "$1" | { grep -v '^-- ' || true; } | shasum -a 256 | awk '{print $1}'
}

# backup_wp_cmd_literal <alias: a|b> — prints a literal command prefix for
# <alias> with no reference to any sitegraft function. Used only decoratively,
# to document the resolved wp-cli invocation inside the generated restore.sh's
# header comment (backup_generate_restore_script below) — the real restore
# commands are built directly there, exactly like backup_db_export's own
# ssh/local branches, so this function's only consumer is a comment.
#
# Deliberately does NOT use bash's `${var:?msg}` for the required-path check
# (an earlier draft did) — lib/core.sh's sitegraft_cleanup comment and
# lib/inventory.sh's wp_remote both document, at length, why that specific
# bash 3.2 parameter-expansion failure mode reports $?=0 to any EXIT trap
# regardless of what it does. An explicit check + `return 1` is the same
# pattern wp_remote already uses for exactly this reason.
backup_wp_cmd_literal() {
  local alias_lc="$1"
  local alias_uc; alias_uc=$(printf '%s' "$alias_lc" | tr '[:lower:]' '[:upper:]')
  local host_var="SITE_${alias_uc}_SSH_HOST"
  local path_var="SITE_${alias_uc}_WP_PATH"
  local cmd_var="SITE_${alias_uc}_WP_CMD"
  local host="${!host_var:-}"
  local path="${!path_var:-}"
  if [ -z "$path" ]; then
    log_error "missing ${path_var}"
    return 1
  fi
  local wp_cmd="${!cmd_var:-wp}"

  if [ -n "$host" ]; then
    # issue #75 (review nit): this line is decorative (this function's own
    # header comment) -- but an operator who copies it BECAUSE it looked
    # like a working command, on a profile whose dedicated key this line
    # silently dropped, would land on the exact "Permission denied" issue
    # #75 was filed over. Carries -i too now, purely so the copy is honest.
    local ssh_key; ssh_key=$(ssh_key_for "$alias_lc")
    if [ -n "$ssh_key" ]; then
      printf 'ssh -i %s %s "%s --path=%s"' "$ssh_key" "$host" "$wp_cmd" "$path"
    else
      printf 'ssh %s "%s --path=%s"' "$host" "$wp_cmd" "$path"
    fi
  else
    printf '%s --path=%s' "$wp_cmd" "$path"
  fi
}

# backup_db_export <dest_dir> — full DB export of B, gzipped, written to
# <dest_dir>/b-db.sql.gz. Takes an explicit destination (not derived from a
# run dir internally) so both phase_backup (writing into
# "${run_dir}/backup") and phase_restore's pre-restore safety snapshot
# (writing into a "pre-restore-<timestamp>" dir) can share this one
# implementation instead of duplicating the ssh/rsync command construction a
# second time — one place to get the two-hop routing and quoting right,
# matching backup_checksum's own "never three implementations" reasoning
# above.
backup_db_export() {
  local dest_dir="$1"
  log_info "exporting B database to ${dest_dir}/b-db.sql.gz ..."
  mkdir -p "$dest_dir"
  # `set -o pipefail;` at the head of every string below — issue #99: a
  # `bash -c` child does NOT inherit bin/sitegraft's own `set -o pipefail`
  # (verified: a freshly started child bash has default SHELLOPTS). Without
  # it, `<producer> | gzip > file`'s exit status is gzip's alone — an export
  # that dies mid-stream still leaves gzip a clean EOF to close out
  # successfully, so a genuinely truncated dump was reported as backup
  # success. See lib/backup.sh's git history / issue #99 for the measured
  # reproduction.
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    # issue #75: `-i <key>` when SITE_B_SSH_KEY is set. This whole command
    # is a hand-built string that `bash -c` re-parses (needed so the pipe to
    # `gzip` runs locally, not on B), so the key -- like every other
    # operator-supplied value in this string -- goes through sq() before
    # being spliced in, not a bare interpolation.
    local ssh_key; ssh_key=$(ssh_key_for b)
    # review nit: an `&&`-as-statement here is harmless TODAY (it is not
    # this function's last statement), but this codebase has been bitten
    # three times by exactly this shape silently swallowing a real failure
    # under `set -e` when it ends up last in a function -- an explicit
    # if/then costs one line and can never become that trap later.
    local ssh_key_opt=""
    if [ -n "$ssh_key" ]; then
      ssh_key_opt="-i $(sq "$ssh_key") "
    fi
    run_or_echo bash -c "set -o pipefail; ssh ${ssh_key_opt}'${SITE_B_SSH_HOST}' \"${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db export - --add-drop-table\" | gzip > '${dest_dir}/b-db.sql.gz'"
  else
    run_or_echo bash -c "set -o pipefail; ${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db export - --add-drop-table | gzip > '${dest_dir}/b-db.sql.gz'"
  fi
}

# _backup_local_exec_prefix <alias> — for a LOCAL (no SSH_HOST) site, returns
# the wrapper prefix implied by SITE_<ALIAS>_WP_CMD, with its trailing "wp"
# token stripped, so a non-wp-cli command (tar, rm — needed for raw file-tree
# operations wp-cli has no equivalent for) can run through the exact same
# execution context wp-cli commands already use.
#
# Design doc §5.1's WP_CMD contract is exactly this shape by construction:
# either the bare string "wp", or "<wrapper...> -- wp" for a container-
# wrapped local install (its own documented example is DDEV's
# "ddev exec --raw -p <project> -- wp") — so stripping a trailing " wp" is a
# well-defined transform of a value whose shape the design doc already fully
# specifies, not a fragile heuristic bolted on afterward. Empty result means
# "run directly on the orchestrator's own filesystem, no wrapper at all" (a
# genuinely bare-metal local WP_CMD="wp") — also the fallback for any
# SITE_*_WP_CMD shape this helper doesn't recognize (fail toward "no
# wrapper", the safer of the two wrong answers: a spurious prefix could
# execute nonsense, while assuming no wrapper just fails loudly at the
# direct-filesystem-access attempt if that assumption was wrong).
#
# Strips every `--raw` token from the derived prefix, if present — bug found
# live running the real DDEV harness (a THIRD one, in the same feature): DDEV's
# own `--raw` flag exists solely to stop `ddev exec` from re-parsing the
# command through an inner shell, which otherwise mangles PHP `$variables`
# inside a `wp eval` snippet (design doc §5.1, why WP_CMD needs `--raw` for
# wp-cli in the first place). It has nothing to do with — and, verified
# live, actively breaks — piping binary stdin into the container: `echo hi |
# ddev exec --raw -p X -- cat` silently produces NOTHING (the tar stream
# this prefix feeds arrives empty, failing downstream with "gzip: stdin: not
# in gzip format"), while the exact same invocation WITHOUT --raw correctly
# forwards it. Since none of tar/rm/mkdir's arguments ever contain a PHP
# `$variable` to protect, `--raw`'s entire reason for existing doesn't apply
# here — dropping it is safe and fixes stdin forwarding for exactly the
# commands this helper's callers need it for.
#
# NIT hardening (Viktor, backlog item taken in this same PR per house rule —
# fix now, not as a follow-up): a single `${prefix/--raw /}` only strips the
# FIRST `--raw ` occurrence and requires a trailing space, which happens to
# be fine for every real DDEV invocation (`--raw` always precedes `-p`,
# never appears twice, never sits at the very end) but is a needlessly
# narrow implementation for what's meant to be a general "any wrapper
# shaped like WP_CMD" helper. `${prefix//--raw /}` (double slash: replace
# ALL occurrences, not just the first) handles repeats; the trailing `case`
# additionally strips a bare `--raw` with no following token, in case it
# ever ends up as the last word of the prefix (it never does today, given
# the trailing " wp" is always stripped first — this is defense against a
# WP_CMD shape nobody has written yet, not a fix for an observed bug).
_backup_local_exec_prefix() {
  local alias_lc="$1"
  local alias_uc; alias_uc=$(printf '%s' "$alias_lc" | tr '[:lower:]' '[:upper:]')
  local cmd_var="SITE_${alias_uc}_WP_CMD"
  local wp_cmd="${!cmd_var:-wp}"
  local prefix
  case "$wp_cmd" in
    wp) prefix='' ;;
    *\ wp) prefix="${wp_cmd% wp}" ;;
    *) prefix='' ;;
  esac
  prefix="${prefix//--raw /}"
  case "$prefix" in
    *--raw) prefix="${prefix%--raw}" ;;
  esac
  # Trim a possible trailing space left behind by the bare-trailing-"--raw"
  # strip above (cosmetic: an unquoted "${prefix} tar ..." interpolation
  # would still word-split correctly with a stray trailing space, but a
  # clean value is cheap to guarantee and avoids relying on that).
  prefix="${prefix% }"
  printf '%s' "$prefix"
}

# backup_wp_content <dest_dir> — mirrors B's wp-content/ into <dest_dir>
# (design doc §6.3 / review finding A3: without this, restore.sh can never
# return B's files — media uploaded by graft, any theme/plugin file changes —
# to their pre-graft state, only the database). Same dest_dir
# parameterization as backup_db_export, for the same reuse-not-duplicate
# reason (phase_backup vs. phase_restore's pre-restore snapshot).
#
# Plan bug found and fixed here, via the real DDEV harness (not caught by any
# unit test, not present in the plan's original pseudocode): the first draft
# of this function used a plain `rsync` for BOTH the "local" branches (SSH
# unset), assuming SITE_B_WP_PATH is always directly reachable on the
# orchestrator's own filesystem whenever there's no SSH hop. That's true for
# a genuinely bare-metal local install, but false for the wrapped-local case
# design doc §5.1 explicitly documents and the DDEV harness actually
# exercises: SITE_*_WP_PATH is the CONTAINER-internal docroot ("/var/www/
# html"), which does not exist on the orchestrator's own filesystem at all.
# `wp-cli` commands never hit this (their output streams back through the
# wrapper's own stdout — see backup_db_export, unaffected by this bug), but
# rsync needs actual filesystem access, which only the wrapper can provide.
# Reproduced live: "rsync: change_dir wp-content failed: No such file or
# directory" against a real DDEV project, then fixed by streaming a tar
# archive through the same wrapper prefix wp-cli commands already use.
#
# Step 4's media sync (`graft_media_pull_cmd`/`graft_media_push_cmd`, design
# doc §6.4 step 1) will face this identical problem — reuse
# _backup_local_exec_prefix there rather than rediscovering this the hard way
# a second time.
backup_wp_content() {
  local dest_dir="$1"
  log_info "archiving B wp-content to ${dest_dir} ..."
  mkdir -p "$dest_dir"
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    # issues #75/#94: rsync_pull_remote (lib/inventory.sh) carries B's
    # dedicated SSH key and forces rsync's default arg-escaping -- see its
    # own header comment for both. Requires sitegraft_require_rsync_arg_
    # escaping to have already run once, at phase_backup's start.
    rsync_pull_remote b "$SITE_B_SSH_HOST" "${SITE_B_WP_PATH}/wp-content/" "${dest_dir}/"
  else
    local prefix; prefix=$(_backup_local_exec_prefix b)
    if [ -n "$prefix" ]; then
      # -C "$SITE_B_WP_PATH" (the docroot itself), archiving its wp-content/
      # subdirectory — NOT $(dirname "$SITE_B_WP_PATH"). Bug found live in
      # the harness (second one, in the same function): design doc §6.3's
      # illustrative ssh/tar snippet uses `-C $(dirname "$SITE_B_WP_PATH")
      # wp-content`, which is wrong — wp-content lives directly under the
      # docroot (SITE_B_WP_PATH itself), not under its PARENT directory.
      # Reproduced live: "tar: wp-content: Cannot stat: No such file or
      # directory" against a real DDEV project (WP_PATH=/var/www/html,
      # dirname=/var/www, which has no wp-content). The plan's actual
      # reviewed Task 3.1 code for the rsync branches already got this
      # right (`${SITE_B_WP_PATH}/wp-content/`, no dirname) — only the
      # design doc's own illustration had the bug, and it's what this new
      # tar branch was modeled on.
      # `set -o pipefail;` — issue #99, same swallow as backup_db_export's
      # own comment above: without it this pipeline's exit status is the
      # EXTRACTING tar's alone, so a source tar that dies partway through
      # (still writing a complete, valid archive for what it did manage to
      # read) is reported as a successful wp-content backup.
      run_or_echo bash -c "set -o pipefail; ${prefix} tar czf - -C '${SITE_B_WP_PATH}' wp-content | tar xzf - -C '${dest_dir}' --strip-components=1"
    else
      run_or_echo rsync -avz "${SITE_B_WP_PATH}/wp-content/" "${dest_dir}/"
    fi
  fi
}

# backup_list_b_wp_content — prints B's wp-content, one ABSOLUTE path per
# entry, NUL-delimited, read from B's OWN filesystem through B's own access
# path (ssh, the container wrapper, or directly). Deliberately the same
# mechanism, on the same side of the wrapper, as the `_sg_list_live` the
# generated restore.sh uses — see backup_write_wp_content_manifest below for
# why that identity is the whole point and not an implementation detail.
#
# Not run_or_echo-wrapped: it is a read of B that produces the value its
# caller returns, and its only caller already returns early under --dry-run
# without writing a manifest at all.
backup_list_b_wp_content() {
  local root="${SITE_B_WP_PATH}/wp-content"
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    # issue #75: `-i <key>` when SITE_B_SSH_KEY is set. Not routed through
    # ssh_remote_run (lib/inventory.sh) -- that helper wraps run_or_echo,
    # and this call must always run for real, dry-run or not (see this
    # function's own header comment: its only caller already handles
    # --dry-run itself, by returning early before ever reaching here).
    local ssh_key; ssh_key=$(ssh_key_for b)
    if [ -n "$ssh_key" ]; then
      ssh -i "$ssh_key" -- "$SITE_B_SSH_HOST" "find $(sq "$root") -mindepth 1 -print0"
    else
      ssh -- "$SITE_B_SSH_HOST" "find $(sq "$root") -mindepth 1 -print0"
    fi
  else
    local prefix; prefix=$(_backup_local_exec_prefix b)
    if [ -n "$prefix" ]; then
      bash -c "${prefix} find $(sq "$root") -mindepth 1 -print0"
    else
      find "$root" -mindepth 1 -print0
    fi
  fi
}

# backup_write_wp_content_manifest <archive_dir> <manifest_file> — records
# exactly what this backup covers, one relative path per entry, NUL-delimited
# (issue #14).
#
# This is what makes an exact-state restore possible on a wrapped-local target
# without ever wiping wp-content. The obstacle backup_generate_restore_script
# ran into is real and unchanged: a container sync (DDEV's Mutagen) can mount a
# subdirectory of wp-content, and removing that directory fails with "Device or
# resource busy" — so the restore never removes the directory. With this
# manifest it does not have to: it can list what B's wp-content holds now,
# subtract what the backup covered, and remove precisely that difference. Only
# known additions are deleted, never a wipe-and-rebuild.
#
# READ FROM B, NOT FROM THE PULLED COPY — and this reversed an earlier
# decision, for a reason that was measured rather than reasoned about. The
# earlier version listed the copy on the orchestrator, arguing the copy is what
# restore.sh puts back and is therefore the authoritative description of the
# backup. That argument is sound and still wrong, because it assumes the copy
# carries B's filenames. It does not, and not in a corner case:
#
#   $ printf x > src/$'Caf\xc3\xa9.css'          # NFC, as B stores it
#   $ tar czf - -C . src | tar xzf - -C dst --strip-components=1
#   $ ls dst | od -c   ->   C a f e 314 201 . c s s     # NFD
#
# macOS's bsdtar rewrites a name from NFC (é as one code point) to NFD (e plus
# a combining acute) while extracting. backup_wp_content's local branch is
# exactly that tar pipeline, so on a macOS orchestrator — the tool's primary
# environment — the copy's accented names differ BYTE FOR BYTE from B's. The
# manifest inherited that, `comm` compares bytes, and every accented file the
# backup contained was classified as a file added since the backup and deleted.
# Reproduced end to end with no shim and no forged input: a wp-content holding
# `themes/Café.css` came back from `restore.sh` without it, exit code 0, and
# the script printed "Confirmed: B's wp-content now holds exactly what this
# backup holds." Accented upload filenames are ordinary on the French- and
# German-language sites this tool exists for.
#
# Listing B directly removes the conversion from the loop entirely: both sides
# of the comparison — this manifest, and restore.sh's own `_sg_list_live` —
# now come from the same filesystem's own bytes, so byte equality is correct
# by construction instead of by luck. No Unicode tables, no `uconv`/`iconv`
# dependency on the target, nothing to be portable about.
#
# The cost is a drift window: a file that lands on B between the archive being
# pulled and this listing is recorded as original and will be KEPT by a later
# restore. That is the conservative direction (a file left in place, never a
# file deleted), and the tool already documents that B is expected to be
# quiescent for the duration.
#
# The archive is still cross-checked against it, by ENTRY COUNT, and that check
# is load-bearing in both directions:
#   - manifest shorter than the archive  -> the manifest is truncated, and a
#     truncated keep-list deletes everything it fails to mention;
#   - archive shorter than the manifest  -> the wp-content pull was partial,
#     which `backup_verify_wp_content` cannot see (it only tests non-empty).
# Because the two listings now come from independent sources, their agreement
# is real evidence. Under the old design they could not disagree — the manifest
# was generated FROM the archive — so a partial pull produced a manifest and an
# archive that were partial together, agreed with each other, and drove a
# restore that deleted files which had never been additions.
#
# Counts, not names: the archive's names may legitimately differ from B's, for
# exactly the normalization reason above. Names are compared at restore time
# instead, where both sides come from B (see _sg_assert_backup_landed in the
# generated script).
#
# NUL-delimited, because a WordPress uploads directory is user-supplied
# filenames: spaces, quotes, glob characters and (rarely, but legally) newlines
# all occur. A newline-delimited manifest would silently split one such name
# into two entries — and on the restore side, two entries that match nothing
# are two extra deletions. The generated restore.sh re-validates every entry it
# reads before acting on it.
#
# An EMPTY manifest is refused rather than written: it says "the backup covered
# nothing", which on the restore side reads as "every file in wp-content is an
# addition — delete all of them". A real wp-content is never empty, and
# backup_verify_wp_content already refuses an empty archive for the same
# reason.
backup_write_wp_content_manifest() {
  local archive_dir="$1" manifest_file="$2"
  if is_dry_run; then
    log_info "[dry-run] would record a wp-content manifest at ${manifest_file}"
    return 0
  fi
  if [ ! -d "$archive_dir" ]; then
    log_error "cannot record a wp-content manifest: ${archive_dir} does not exist"
    return 1
  fi
  local root="${SITE_B_WP_PATH}/wp-content"
  local raw="${manifest_file}.listing" partial="${manifest_file}.partial"
  rm -f "$raw" "$partial"
  if ! backup_list_b_wp_content > "$raw"; then
    log_error "could not list B's wp-content (${root}) to record a manifest"
    rm -f "$raw"
    return 1
  fi

  # Anchored to B's own wp-content root: a listing that returns a path from
  # somewhere else is not a listing this manifest can describe, and the
  # manifest is what a restore later deletes from. Refuse it here, where
  # nothing has been written to B yet. Recorded in a flag rather than returned
  # from inside the loop, because the loop's stdout is the manifest being
  # written — leaving through the middle of it is how a half-written manifest
  # gets left on disk.
  local abs rel count=0 bad=""
  while IFS= read -r -d '' abs; do
    [ -n "$abs" ] || continue
    case "$abs" in
      "${root}/"?*) ;;
      *) bad="$abs"; break ;;
    esac
    rel=".${abs#"$root"}"
    printf '%s\0' "$rel"
    count=$((count + 1))
  done < "$raw" > "$partial"
  rm -f "$raw"

  if [ -n "$bad" ]; then
    log_error "cannot record a wp-content manifest: listing B's wp-content returned a path outside ${root} ([${bad}])"
    rm -f "$partial"
    return 1
  fi
  if [ "$count" -eq 0 ]; then
    log_error "wp-content manifest at ${manifest_file} came out empty — refusing to keep a manifest that would tell restore.sh to delete every file in B's wp-content"
    rm -f "$partial"
    return 1
  fi

  local archive_count
  archive_count=$( ( cd "$archive_dir" && find . -mindepth 1 -print0 ) | tr -dc '\0' | wc -c | tr -d ' ' )
  if [ "$count" -ne "$archive_count" ]; then
    # issue #99: this is only ever reached when the pull ITSELF reported
    # success — phase_backup calls backup_wp_content, checks its exit
    # status (`|| exit 1`), and only then calls this function, so any
    # tool-reported transfer failure (tar or rsync) already aborted one
    # step earlier, before this cross-check ever ran. Say that explicitly,
    # rather than leaving an operator to suspect a swallowed error that
    # (with backup_wp_content's own `set -o pipefail;` fix) no longer
    # happens: what remains genuinely ambiguous is either a race (B changed
    # between the listing this manifest is built from and the pull) or a
    # transfer tool that dropped something without ever reporting it as a
    # failure (rare, but not something an exit code alone can rule out).
    log_error "backup aborted: B's wp-content holds ${count} path(s) but the archive pulled from it (${archive_dir}) holds ${archive_count}. The pull itself reported success — this cross-check exists for what an exit code cannot catch: either B was written to between the listing and the pull (re-run with B quiescent), or the transfer silently dropped something without reporting an error (check its output above for anything unusual). Both make this backup unsafe to restore from — a restore would delete files that were never additions."
    rm -f "$partial"
    return 1
  fi

  mv "$partial" "$manifest_file"
  chmod 600 "$manifest_file" 2>/dev/null || true
  log_info "recorded wp-content manifest: ${manifest_file} (${count} path(s), cross-checked against the archive)"
}

# backup_verify_db_export <gz_file> <table_prefix> — design doc §6.3 (Marcel's
# nightshift mandate): a backup that "completed" but is silently truncated or
# corrupted is worse than a loud error — verify the artifact genuinely looks
# like a usable WordPress DB export before declaring the backup good. Not a
# full restore-and-diff (too slow/heavy to run on every backup) — cheap sanity
# checks: gzip validity, a minimum size floor, and the presence of at least
# two of WordPress's own core tables (options, posts) in the decompressed
# dump, read at the LIVE table prefix so this works on any prefix, not just
# the "wp_" default.
backup_verify_db_export() {
  local gz_file="$1" table_prefix="$2"
  if [ ! -s "$gz_file" ]; then
    log_error "backup verification failed: ${gz_file} is missing or empty"
    return 1
  fi
  local size; size=$(wc -c < "$gz_file" | tr -d ' ')
  # 200 bytes is not a rigorous certification, just a floor low enough to
  # never reject a real (even tiny, single-table) WordPress export, and high
  # enough to catch a zero/near-zero-byte truncated file.
  if [ "$size" -lt 200 ]; then
    log_error "backup verification failed: ${gz_file} is suspiciously small (${size} bytes) — refusing to trust it"
    return 1
  fi
  if ! gzip -t "$gz_file" 2>/dev/null; then
    log_error "backup verification failed: ${gz_file} is not a valid gzip file"
    return 1
  fi
  # A literal backtick, held as data (assigned inside single quotes, so bash
  # never treats it as command substitution) — mysqldump quotes table names
  # in CREATE TABLE statements with backticks, and grep -F needs the exact
  # literal to search for.
  local bt='`'
  local table found
  for table in "${table_prefix}options" "${table_prefix}posts"; do
    # `grep -q` exits the instant it finds a match. That closes the pipe on
    # the still-writing `gunzip`, which is killed by SIGPIPE and exits 141 —
    # and under bin/sitegraft's `set -o pipefail` (line 3) the PIPELINE then
    # reports 141, i.e. a failure, even though the table was found.
    #
    # It is size-dependent, which is why it stayed hidden: on a dump small
    # enough that gunzip finishes writing before grep exits, no signal is
    # ever delivered and the check passes. Every DDEV-harness backup is that
    # small. The first real target's 73 MB database was rejected with both
    # of its tables plainly present in the file — and since `graft`
    # structurally refuses to run without the `backup.complete` marker this
    # check gates, it made the tool unable to finish a backup against any
    # genuine site.
    #
    # `grep -c` consumes the whole stream rather than exiting early, so no
    # SIGPIPE is ever delivered. The `|| true` keeps a legitimate zero-match
    # result (grep exits 1 when it matches nothing) from tripping `set -e`
    # before the count below can be tested — the two cases must stay
    # distinguishable, which is exactly what the previous version lost.
    found=$(gunzip -c "$gz_file" 2>/dev/null | grep -cF "CREATE TABLE ${bt}${table}${bt}" || true)
    if [ "${found:-0}" -eq 0 ]; then
      log_error "backup verification failed: expected table '${table}' not found in ${gz_file}"
      return 1
    fi
  done
  # issue #99: gzip validity and the size floor above cannot see a dump that
  # is SHORT rather than corrupt — an export that dies mid-stream still
  # produces a perfectly valid, complete gzip stream for whatever it had
  # written before it died. And the core-table probe above only sees up to
  # "posts", which sits in the MIDDLE of an alphabetical mysqldump table
  # list — a die AFTER wp_posts (wp_usermeta, wp_users, wp_terms,
  # wp_comments never written) is structurally invisible to it.
  #
  # mysqldump/mariadb-dump write a single, unconditional completion comment
  # as the LAST line of every export they finish — verified against a real
  # `wp db export` run (WordPress 6.x + MariaDB 12.3.3, not assumed from
  # memory of the format), present even for a database with a single table
  # and for one with none of its own. A dump that stops before that line
  # stopped mid-write, full stop, regardless of which tables happen to have
  # been captured before the cut. mariadb-dump's own source (write_footer())
  # emits one of two literal forms depending on --dump-date:
  #   "-- Dump completed on <timestamp>"   (default)
  #   "-- Dump completed"                  (--skip-dump-date)
  # — matched on the shared "-- Dump completed" prefix so both are accepted.
  #
  # ANCHORED to the last 5 lines, not searched anywhere in the file. An
  # unanchored `grep` over the whole decompressed dump is a real false
  # negative, not a hypothetical: `wp_options` is dumped FIRST — before this
  # very check's own core-table probe even runs — and is exactly where
  # UpdraftPlus/Duplicator/All-in-One WP Migration park log rows and dump
  # fragments from a PREVIOUS backup. A site that has ever used one of those
  # plugins can carry an `option_value` containing the literal string
  # "-- Dump completed on ..." as ordinary DATA, long before the real
  # export dies partway through. Measured: a dump truncated right after
  # `wp_posts` (no real footer) but carrying that string in an
  # `wp_options` row is wrongly ACCEPTED by an unanchored search and
  # correctly REJECTED once anchored to the tail. 5 lines covers
  # mariadb-dump's fixed trailing sequence (the SET-restore lines, a blank
  # line, then the comment itself) with margin, verified against both a
  # real dump and a fabricated one carrying the poisoned string.
  #
  # `grep -c` (not `-q`), for the exact SIGPIPE-under-pipefail reason
  # documented on the core-table probe above: `-q` would exit on first
  # match and can kill a still-writing `gunzip` with SIGPIPE on a large
  # dump, which `set -o pipefail` then reports as this pipeline's own
  # failure even though the marker was found. `tail` itself always reads
  # its input through to EOF regardless of `-n`, so it introduces no new
  # SIGPIPE risk of its own here.
  #
  # A WordPress install running the SQLite integration plugin DOES reach
  # this check, and needs its own dialect handled correctly rather than
  # assumed away. CORRECTED (this comment previously claimed sqlite3 never
  # quotes CREATE TABLE at all — wrong; that was a table created by hand
  # with no quoting, not what a real drop-in emits). `sqlite3 .dump`
  # replays `sqlite_master.sql` VERBATIM, with whatever quoting the table
  # was originally CREATEd with — measured directly. Quoting is therefore a
  # property of the drop-in that created the tables, not of sqlite3, and it
  # has changed between releases: v2.x's `WP_SQLite_Translator` used double
  # quotes, but the current v3.x `WP_SQLite_Driver` (verified against its
  # own source, class-wp-sqlite-connection.php's `quote_identifier()`)
  # deliberately uses BACKTICKS — specifically to avoid a documented SQLite
  # quirk where a misspelled double-quoted identifier silently falls back
  # to being read as a string literal instead of erroring. So a real,
  # current `wp db export` on a SQLite-backed B DOES pass the backtick-
  # quoted core-table probe above and DOES reach this check.
  #
  # `wp db export`'s own SQLite path (verified against wp-cli/db-command's
  # source) shells out to `sqlite3 -init <file containing ".dump"> <copy>
  # .exit` — a real `.dump`, not something sitegraft has to emulate. That
  # dump has no mysqldump-shaped footer at all; it has its own, different
  # one: `.dump` wraps the ENTIRE export in exactly one `BEGIN
  # TRANSACTION;` / `COMMIT;` pair (verified against a real multi-table
  # dump) — one COMMIT, for the whole file, at the true end.
  #
  # NOT the same thing as mysqldump's own "COMMIT;" — measured, and this is
  # the trap a same-window "accept either string" version of this check
  # would fall into: mysqldump/mariadb-dump writes a per-table
  # "COMMIT;" / "SET AUTOCOMMIT=..." pair once PER TABLE (dump_table(),
  # gated on the --no-autocommit flag — CORRECTED, prior round: no flag
  # from `wp db export` is needed to turn this on. That flag's own struct
  # entry (mysqldump.cc: `{"no-autocommit", ..., GET_BOOL, OPT_ARG, 1, 0,
  # 0, 0, 0, 0}` — the "1" is its def_value) defaults it ON; the plain C
  # initializer `no_autocommit=0` earlier in the same file is overwritten
  # by that def_value before any command-line argument is ever read, a
  # known my_getopt quirk. Verified from that source, not assumed — and
  # independently, empirically confirmed: a real 12-table `wp db export`
  # against MariaDB 11, no autocommit-related flag passed anywhere, still
  # produced 12 separate "COMMIT;" lines, scattered throughout, one right
  # after EVERY table's own data. A mysqldump-dialect export truncated
  # immediately after any single table's own per-table COMMIT — before
  # every table after it was ever written, the exact #99 shape — would
  # still show "COMMIT;" in its last few lines. Accepting "COMMIT;"
  # generically, for both dialects in the same tail window, would silently
  # readmit that truncation. The two dialects need two different markers,
  # checked only against dumps of their own kind.
  #
  # BOTH markers ANCHORED TO A WHOLE LINE, not matched as a substring
  # anywhere within one — a second, narrower version of the same tail-
  # anchoring problem solved above, and just as real: "COMMIT;" is
  # ordinary SQL vocabulary that shows up in ordinary WordPress content (a
  # post about transactions, a code snippet, a plugin's own log line), and
  # measured directly — a SQLite export truncated right after `wp_posts`,
  # before `wp_users` and the real closing COMMIT, but with a `wp_posts`
  # row whose content happens to contain the substring "COMMIT;" is wrongly
  # ACCEPTED by an unanchored `grep -cF` and correctly REJECTED once
  # anchored to the FULL line (`grep -cx`). The mysqldump marker gets the
  # same treatment for the same reason, anchored to the START of a line
  # (`grep -c '^...'`) rather than to the full line, because the marker's
  # own line takes two shapes: "-- Dump completed on <date>" normally, and
  # a bare "-- Dump completed" under --skip-dump-date (both measured, and
  # both documented above). A start-of-line anchor covers the two; a
  # full-line anchor would reject the second.
  #
  # Sniffed from the dump's OWN FIRST line, which only the tool that wrote
  # the dump controls (never table data, unlike the tail this check reads)
  # — a `sqlite3 .dump` always opens with "PRAGMA foreign_keys=OFF;"
  # (verified, unconditional). mysqldump/mariadb-dump's own first line is
  # NOT a reliable "-- " comment to sniff FOR — measured directly against a
  # real MariaDB 11 dump: its actual first line is
  # "/*M!999999\- enable the sandbox mode */", a versioned MariaDB
  # directive, not a "-- "-prefixed comment at all (a prior round of this
  # same comment claimed otherwise, unverified). So the mysqldump/mariadb
  # dialect is the FALLBACK here — anything that doesn't match the SQLite
  # signature — rather than something separately sniffed for; the two
  # dialects genuinely in scope for `wp db export` don't need a positive
  # match on both sides to be told apart. `head -1` (not `-q`-style
  # anything), same SIGPIPE-under-pipefail reasoning as the rest of this
  # function — `|| true` keeps a pipe closed early by `head` from turning
  # into a false failure here.
  local first_line
  first_line=$(gunzip -c "$gz_file" 2>/dev/null | head -1 || true)
  local found marker_desc
  if [[ "$first_line" == "PRAGMA foreign_keys"* ]]; then
    found=$(gunzip -c "$gz_file" 2>/dev/null | tail -5 | grep -cx -- 'COMMIT;' || true)
    marker_desc="a SQLite export's closing COMMIT;"
  else
    found=$(gunzip -c "$gz_file" 2>/dev/null | tail -5 | grep -c -- '^-- Dump completed' || true)
    marker_desc="mysqldump's completion marker ('-- Dump completed ...')"
  fi
  if [ "${found:-0}" -eq 0 ]; then
    log_error "backup verification failed: ${gz_file} has no ${marker_desc} in its final lines — the export looks truncated, not just missing a table. Re-run the backup; if this keeps happening, check whether B's export died partway (disk full, network drop, killed process)."
    return 1
  fi
}

# backup_verify_wp_content <dir> — companion sanity check for the wp-content
# archive: it exists and isn't empty. Deliberately shallow (no attempt to
# verify every expected subdirectory) — a genuinely truncated rsync (network
# drop mid-transfer, disk full on the orchestrator) most often either leaves
# nothing at all or leaves a directory with content, so "non-empty" already
# catches the realistic failure mode without pretending to certify every file
# arrived intact.
backup_verify_wp_content() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    log_error "backup verification failed: ${dir} does not exist"
    return 1
  fi
  if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    log_error "backup verification failed: ${dir} is empty"
    return 1
  fi
}

# backup_generate_restore_script <run_dir> — design doc §6.3 / review finding
# A2: every command below is resolved and baked in literally at generation
# time. restore.sh never sources any sitegraft lib file and never calls a
# sitegraft function — it needs only ssh, rsync, tar, gzip/gunzip, and wc to
# run,
# so it keeps working even copied somewhere with no sitegraft checkout at all
# (design doc §6.3: "self-contained, ready to run with no other context").
#
# Marcel's nightshift mandate, second half: restore.sh also refuses to run if
# the backup it's about to restore from is corrupted — the integrity check
# baked into the generated script below is a second, independent line of
# defense against the case where a backup passed verification at CREATION
# time (backup_verify_db_export/backup_verify_wp_content, called by
# phase_backup) but was damaged afterward (disk error, an accidental partial
# copy of the run dir to somewhere else, anything between backup time and
# restore time). It's written using only gzip/wc/ls — never a sitegraft
# function — to keep the self-containment guarantee intact.
#
# Every operator-supplied value baked into the script below goes through sq()
# (lib/inventory.sh), which emits a single-quoted shell LITERAL. It is not
# cosmetic. The three heredocs that build this script are expanding heredocs:
# what bash writes into the file is text, and that text is parsed again by
# bash when the script RUNS. Interpolating a profile value between plain
# double quotes therefore hands it to a shell — a SITE_B_WP_PATH of
# "/var/www/html$(id > /tmp/x)" ran `id` at line 31 of the generated script,
# before the first integrity check and even under --dry-run (reproduced live
# in this exact form). A single apostrophe in the same value — a DDEV project
# named after somebody — produced a restore.sh that bash could not parse at
# all, while `backup` went on to write backup.complete and call the backup
# good. sq() closes both: a literal is data, in every shell that re-reads it.
#
# The one value that is deliberately NOT quoted is `$prefix`
# (_backup_local_exec_prefix's wrapper command line, derived from
# SITE_B_WP_CMD). It has to stay a sequence of separate command words to be a
# command at all — SITE_B_WP_CMD is, by the design doc's own §5.1 contract, a
# command line the tool executes. That is unchanged from `main` and from every
# other phase; it is a property of what WP_CMD is, not of this script.
backup_generate_restore_script() {
  local run_dir="$1"
  local wp_cmd_b restore_db_cmd restore_wp_content_cmd
  # issue #14: which file semantics this script provides, and how it provides
  # them. Baked in, and printed by the script itself when it runs — an
  # operator reading "restore" has to be told what "restore" means here at the
  # moment they run it, not only in the `backup` log they may never have seen.
  local restore_semantics prune_mode="rsync-delete" prune_helpers
  local b_wp_content_root="${SITE_B_WP_PATH:-}/wp-content"
  # issue #44: only the ssh-remote branch's wp-content step hands a
  # `host:path` destination to rsync, which is the one case where rsync — not
  # this script — builds a second, remote command line out of SITE_B_WP_PATH.
  # sq() (this function's own header comment) protects every path THIS
  # script's ssh/tar/rsync-local invocations run through, but it cannot reach
  # that second command line: rsync constructs it itself, on the far end,
  # after this script has already exited. Baked into restore.sh as
  # NEEDS_RSYNC_ARG_ESCAPING so the one runtime check below (added with the
  # fix) only ever runs for the branch that actually needs it. See the
  # `rsync -avz --delete <src> host:path` line just below for what this
  # requires and why (and ADR 0010 for why it is NOT `--protect-args`, which
  # was the first version of this fix and was reverted — a real remote
  # incompatibility, found in review, not a hypothetical).
  local needs_rsync_arg_escaping=0
  # Defined for every branch so the generated script has one uniform shape;
  # only the manifest branch ever calls them.
  prune_helpers="_sg_list_live() { echo 'internal error: this restore.sh does not use a wp-content manifest' >&2; return 1; }
_sg_list_live_symlinks() { echo 'internal error: this restore.sh does not use a wp-content manifest' >&2; return 1; }
_sg_delete_from_stdin() { echo 'internal error: this restore.sh does not use a wp-content manifest' >&2; return 1; }"

  # Decorative only (see backup_wp_cmd_literal's own comment) — if it can't
  # resolve for any reason, the header comment just says so; it never blocks
  # generating the actual restore commands below. Newlines are folded to
  # spaces: this value is interpolated into a `#` comment line, and a value
  # carrying a newline would end that comment and turn the remainder into code.
  wp_cmd_b="$(backup_wp_cmd_literal b 2>/dev/null || echo '(unresolved)')"
  wp_cmd_b="$(printf '%s' "$wp_cmd_b" | tr '\n' ' ')"

  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    # Two shells parse the remote half: restore.sh's own, then the far end's.
    # Hence sq() applied twice to the remote path — the inner call quotes it
    # for the remote shell, the outer one quotes that whole command string for
    # the local one. That covers both `ssh` invocations below (mkdir, and
    # `wp db import` piped over ssh): each bakes ONE command string that THIS
    # script hands, as a single argument, to a remote shell it explicitly
    # asked for — sq() quoting that string for the remote shell is exactly
    # the right and sufficient protection, verified live (a SITE_B_WP_PATH of
    # "/var/www/$(touch pwned)html" round-trips as inert text through both).
    #
    # `rsync -avz --delete <src> host:path`, below, is a different shape: the
    # text after `host:` is never an argument on a command line THIS script
    # controls. rsync reads it, then builds ITS OWN remote command line (to
    # invoke `rsync --server` on the far end) and hands THAT to ssh — a
    # second, independent command-construction step this function's sq()
    # calls never reach, because it happens inside rsync, on the far end,
    # after this script has already run. Whether that second command line
    # protects special characters in the destination path is entirely
    # rsync's own behavior, not this script's — measured to differ by
    # implementation and, within GNU rsync itself, by VERSION:
    #
    #   - GNU rsync >= 3.2.4 (April 2022) backslash-escapes the destination
    #     for the remote shell BY DEFAULT, no flag required — confirmed live
    #     (a loopback ssh stand-in, `$(touch PWNED)` embedded in the
    #     destination: inert). `--old-args` reverts to the old, unescaped
    #     behavior on purpose (an explicit opt-OUT), and running WITH it
    #     reproduces the injection — confirmed live too.
    #   - GNU rsync 3.0.0-3.2.3 does NOT escape by default. `--protect-args`/
    #     `-s` exists on those versions and would close the gap for them —
    #     see ADR 0010 for why this fix does not use it anyway.
    #   - macOS's own bundled `/usr/bin/rsync` is not GNU rsync at all — it's
    #     OpenBSD's `openrsync` (the only rsync macOS 15+ ships). It performs
    #     NO escaping, ever, and has no `--protect-args`/`-s`/`--old-args`.
    #
    # `--protect-args` was the FIRST version of this fix and was reverted:
    # measured live (a real GNU 3.4.4 client against a real openrsync
    # SERVER, both invoked for real, not simulated), plain `rsync -avz
    # --delete` (no flag) against that openrsync server SUCCEEDS — GNU's own
    # default escaping is a purely client-side, wire-protocol-transparent
    # behavior that needs nothing from the remote. `--protect-args` against
    # that same openrsync server FAILS: the client sends `--server -s...`,
    # openrsync's own arg parser on the far end rejects `-s` outright, and
    # the transfer dies with "connection unexpectedly closed" (code 12) —
    # `man rsync` documents `-s` as "refused by restricted shells" for
    # exactly this reason (rrsync and other forced-command SSH setups are a
    # standard hardening for backup accounts, i.e. squarely a real B). So
    # `--protect-args` would have fixed the local-openrsync case at the cost
    # of BREAKING every ssh-remote restore whose B enforces one — a strictly
    # worse trade for a class of target this project cannot assume away.
    #
    # The fix actually shipped, revised once more in review: `--no-old-args`
    # is now on the invocation itself, not just checked for. The runtime
    # check below (issue #44) verifies the LOCAL rsync is CAPABLE of default
    # escaping (`--old-args` support is the proxy) — but capability is not
    # the same as what actually runs. `man rsync`, under `--old-args`: "You
    # may also control this setting via the RSYNC_OLD_ARGS environment
    # variable. If it has the value '1', rsync will default to a
    # single-option setting" — i.e. an operator (or a wrapper script, or a
    # profile sourced before this one) can set RSYNC_OLD_ARGS=1 and the
    # capability check still passes (the binary still RECOGNIZES the flag)
    # while the UNFLAGGED command below would silently run unescaped.
    # Confirmed live: with RSYNC_OLD_ARGS=1 exported, `rsync --old-args
    # --version` exits 0 (probe: pass) and a plain `rsync -avz --delete`
    # with the same destination lets the embedded command execute (fix:
    # bypassed) — this is not hypothetical, rsync's own COMPATIBILITY docs
    # explicitly suggest exporting RSYNC_OLD_ARGS=1 for old scripts.
    # `--no-old-args` forces escaping regardless of that variable — measured
    # live, RSYNC_OLD_ARGS=1 exported AND `--no-old-args` on the command:
    # inert. It stays purely client-side (unlike `--protect-args`/`-s`,
    # reverted above): against a real openrsync SERVER it produces the
    # identical escaped wire content the safe default does, and the
    # transfer succeeds — it does not reopen the restricted-shell
    # regression that `--protect-args` caused. It requires nothing newer
    # than 3.2.4, the same floor the capability check already requires (it
    # is the on/off pair of the same feature `--old-args` toggles). The
    # runtime check remains: it is still worth refusing loudly, before
    # touching B, on a rsync that cannot even parse `--no-old-args` (i.e.
    # does not have the feature at all) rather than letting rsync itself
    # fail on an unrecognized option mid-restore.
    needs_rsync_arg_escaping=1
    # issue #75: restore.sh is generated ONCE, here, and then runs
    # standalone with no sitegraft function or profile in scope (this
    # function's own header comment) — so SITE_B_SSH_KEY, if set, has to be
    # resolved and baked in now, exactly like every other operator-supplied
    # value this function bakes in via sq(). Both `ssh` invocations get a
    # plain `-i $(sq "$ssh_key")` (same shape as ssh_key_for's every other
    # consumer). The `rsync` invocation cannot take `-i` directly — it
    # invokes ssh itself, and rsync's own flag for that is `-e`/`--rsh` —
    # built by the SAME rsync_ssh_e_arg (lib/inventory.sh) every live pull
    # site uses now, computed here (this function runs in the live
    # process, at generation time) and then sq()'d ONCE more to bake the
    # resulting string in as a literal in restore.sh's own source — see
    # rsync_ssh_e_arg's own comment for why it double-quotes rather than
    # single-quotes the key (review-found correction: a single-quoted
    # value here broke outright, live, on a key path containing an
    # apostrophe, which rsync's own `-e` tokenizer gives no meaning to
    # sq()'s `'''` encoding).
    local ssh_key="${SITE_B_SSH_KEY:-}"
    local ssh_i_opt="" rsync_e_opt=""
    if [ -n "$ssh_key" ]; then
      local e_arg; e_arg=$(rsync_ssh_e_arg "$ssh_key") || return 1
      ssh_i_opt="-i $(sq "$ssh_key") "
      rsync_e_opt=" -e $(sq "$e_arg")"
    fi
    restore_wp_content_cmd="ssh ${ssh_i_opt}$(sq "$SITE_B_SSH_HOST") $(sq "mkdir -p $(sq "${SITE_B_WP_PATH}/wp-content")") && rsync -avz --no-old-args --delete${rsync_e_opt} $(sq "${run_dir}/backup/b-wp-content/") $(sq "${SITE_B_SSH_HOST}:${SITE_B_WP_PATH}/wp-content/")"
    restore_db_cmd="gunzip -c $(sq "${run_dir}/backup/b-db.sql.gz") | ssh ${ssh_i_opt}$(sq "$SITE_B_SSH_HOST") $(sq "${SITE_B_WP_CMD} --path=$(sq "${SITE_B_WP_PATH}") db import -")"
    restore_semantics="exact-state, via rsync --delete — wp-content is mirrored back to exactly what this backup contains, and any file added to it since is removed"
  else
    local prefix; prefix=$(_backup_local_exec_prefix b)
    if [ -n "$prefix" ]; then
      # Wrapped local (e.g. DDEV) — mirrors backup_wp_content's own
      # tar-through-the-wrapper fix above, reversed.
      #
      # Deliberately NOT `rm -rf wp-content` first (an earlier draft did,
      # to reproduce rsync --delete's full mirror semantics) — bug found
      # live running the real DDEV harness: `rm -rf` failed with "Device or
      # resource busy" on wp-content/uploads, because DDEV's Mutagen sync
      # mounts (at least) that subdirectory rather than making it a plain
      # file tree, and removing a mount point out from under an active sync
      # fails. A generic wrapper has no reliable, portable way to know
      # ahead of time which subdirectories of a containerized site might be
      # separate mounts, so it never attempts to remove the directory
      # itself — only extracts the backup ON TOP of what's there.
      #
      # That constraint still holds, and is still respected — but it no
      # longer costs the restore its meaning (issue #14). An earlier version
      # of this branch stopped at the extraction and documented the result
      # as overwrite-only: after a graft, restore left the copied theme, the
      # copied plugins and every new upload in place, so B's database came
      # back and B's filesystem did not — exactly in the situation where a
      # restore is most needed. What was missing was never the ability to
      # delete a file, only a safe way to know WHICH files to delete. The
      # backup now records that (backup_write_wp_content_manifest), so the
      # script below extracts the backup in place and then removes precisely
      # the paths B holds that the manifest does not list. No wipe, no mount
      # point removed, no guessing: only known additions.
      prune_mode="manifest"
      restore_semantics="exact-state, by difference against this backup's own wp-content archive — the archive is extracted in place, then every path wp-content holds that the archive does not contain is reported and removed (wp-content itself is never removed: on a container-synced target that can fail with 'Device or resource busy'). The backup's manifest is what certifies the archive is complete; it never selects anything for deletion"
      restore_wp_content_cmd="${prefix} mkdir -p $(sq "${SITE_B_WP_PATH}/wp-content") && tar czf - -C $(sq "${run_dir}/backup/b-wp-content") . | ${prefix} tar xzf - -C $(sq "${SITE_B_WP_PATH}/wp-content")"
      # The two wrapped commands the prune needs, isolated into their own
      # tiny functions so the rest of the generated logic is wrapper-
      # agnostic. Paths are NEVER passed as arguments here: the list of
      # things to remove reaches `rm` through xargs on stdin, NUL-delimited,
      # so a filename containing a space, a quote or a glob character can
      # neither be split nor re-expanded by any shell the wrapper puts in
      # between (several do — see _backup_local_exec_prefix's own comment on
      # `--raw`).
      # issue #35: _sg_list_live_symlinks is the extract-half counterpart of
      # _sg_list_live above — same wrapper, same `find`'s own default -P (never
      # follows a symlink it traverses through), restricted to `-type l` so
      # _sg_assert_no_symlink_targets (below) can check which of THIS backup's
      # own directory paths currently exist on B as a symlink rather than a
      # real directory, before the extraction that would write through one.
      prune_helpers="_sg_list_live() { ${prefix} find $(sq "${SITE_B_WP_PATH}/wp-content") -mindepth 1 -print0; }
_sg_list_live_symlinks() { ${prefix} find $(sq "${SITE_B_WP_PATH}/wp-content") -mindepth 1 -type l -print0; }
_sg_delete_from_stdin() { ${prefix} xargs -0 rm -rf --; }"
      log_info "B is a wrapped-local site (SITE_B_WP_CMD implies a wrapper, e.g. DDEV) — the generated restore.sh restores wp-content to exactly what this backup contains: it extracts the backup's archive in place and then removes the paths wp-content holds that the archive does not, recomputed after the extraction. It never removes wp-content itself (a container sync can make that fail with 'Device or resource busy'), and it refuses to remove anything at all — rather than silently downgrading to overwrite-only — if this backup's manifest is missing, empty, unreadable, reads back as no entries, disagrees with the archive's entry count, or if any listed path is unsafe or is still missing from B after the extraction."
      # MAJOR bug found by review (Viktor), confirmed live: `${SITE_B_WP_CMD}`
      # still carries `--raw`, and `--raw` doesn't just fail to help stdin —
      # it silently DROPS it. Reproduced on a real DDEV project: seeded an
      # option, exported the DB, mutated the option, then piped the export
      # back through `gunzip -c dump.sql.gz | ddev exec --raw -p X -- wp db
      # import -` — wp-cli printed "Success: Imported from 'STDIN'." and
      # exited 0, but the option was STILL the mutated value: the import ran
      # against EMPTY stdin and silently did nothing. The exact same command
      # WITHOUT --raw correctly restored the original value. A restore that
      # reports success while actually restoring nothing is the worst
      # possible failure mode this tool has — worse than a loud error.
      # Fixed by using `${prefix}` (already --raw-stripped, see
      # _backup_local_exec_prefix's own comment) plus a literal "wp", instead
      # of `${SITE_B_WP_CMD}`, for db import specifically. Never a problem for
      # backup_db_export's own use of `${SITE_B_WP_CMD}` with --raw intact —
      # db EXPORT only needs stdOUT to flow (verified working across every
      # DDEV harness run so far), and this asymmetry (stdout fine, stdin
      # dropped) is exactly what makes this bug easy to miss without testing
      # a real round-trip.
      restore_db_cmd="gunzip -c $(sq "${run_dir}/backup/b-db.sql.gz") | ${prefix} wp --path=$(sq "${SITE_B_WP_PATH}") db import -"
    else
      restore_wp_content_cmd="rsync -avz --delete $(sq "${run_dir}/backup/b-wp-content/") $(sq "${SITE_B_WP_PATH}/wp-content/")"
      restore_db_cmd="gunzip -c $(sq "${run_dir}/backup/b-db.sql.gz") | ${SITE_B_WP_CMD} --path=$(sq "${SITE_B_WP_PATH}") db import -"
      restore_semantics="exact-state, via rsync --delete — wp-content is mirrored back to exactly what this backup contains, and any file added to it since is removed"
    fi
  fi

  # The script is written in three passes, on purpose. Pass 1 and 3 are
  # EXPANDING heredocs (they bake in resolved paths and commands); pass 2 is a
  # QUOTED heredoc, so the generic logic — which is ordinary bash with its own
  # runtime variables — is written literally, without a backslash in front of
  # every `$`. That escaping is exactly where a generated script acquires
  # bugs no test of the generator can see.
  # Every one of these is a shell LITERAL, produced by sq() — see this
  # function's own header comment for the command-execution and unparseable-
  # script bugs that reach the generated file through these six lines.
  local q_db_dump q_wp_content_dir q_manifest q_root q_prune_mode q_semantics q_run_dir
  q_db_dump=$(sq "${run_dir}/backup/b-db.sql.gz")
  q_wp_content_dir=$(sq "${run_dir}/backup/b-wp-content")
  q_manifest=$(sq "${run_dir}/backup/b-wp-content.manifest")
  q_root=$(sq "$b_wp_content_root")
  q_prune_mode=$(sq "$prune_mode")
  q_semantics=$(sq "$restore_semantics")
  # Comment line, same newline-folding reason as wp_cmd_b above.
  q_run_dir=$(printf '%s' "$run_dir" | tr '\n' ' ')

  cat > "${run_dir}/restore.sh" <<EOF
#!/usr/bin/env bash
# restore.sh-capability: dry-run
# Generated by 'sitegraft backup' for run: ${q_run_dir}
# Self-contained: every command below is a literal, baked-in ssh/rsync/wp-cli
# invocation (wp-cli literal prefix: ${wp_cmd_b}). This script never calls a
# sitegraft function and never sources a sitegraft lib file — it runs
# standalone with nothing but ssh, rsync, tar, gzip/gunzip, wc, and (on a
# wrapped-local target) find, sort, comm, mktemp and xargs.
#
# Run it with --dry-run to see what it would restore and, on a wrapped-local
# target, exactly which paths it would remove — without writing anything.
#
# Integrity check scope, tightened per review (Kimi): the checks below (gzip
# validity, a size floor, non-empty wp-content) catch a truncated, empty, or
# structurally-broken backup — the realistic failure modes of a partial
# transfer or disk-full write. They do NOT catch corruption that PRESERVES
# gzip's own structure and file size while damaging the SQL content inside
# it (e.g. a few bytes flipped mid-dump by a storage-layer bit-rot event) —
# that class of corruption passes gzip -t (gzip's own checksum only covers
# the compressed stream's integrity, not whether the decompressed bytes
# still form valid SQL) and can still land within the size floor. This is a
# cheap sanity check, explicitly not a cryptographic guarantee — the
# authoritative check for pre/post data integrity is Step 5's checksum
# comparison against manifest.checksums_protected_pre_graft, not this
# script.
set -euo pipefail

DB_DUMP=${q_db_dump}
WP_CONTENT_DIR=${q_wp_content_dir}
WP_CONTENT_MANIFEST=${q_manifest}
B_WP_CONTENT_ROOT=${q_root}
PRUNE_MODE=${q_prune_mode}
RESTORE_SEMANTICS=${q_semantics}
NEEDS_RSYNC_ARG_ESCAPING=${needs_rsync_arg_escaping}

${prune_helpers}
EOF

  cat >> "${run_dir}/restore.sh" <<'EOF'

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "usage: restore.sh [--dry-run]"
      echo "  --dry-run   report what would be restored, and exactly which paths would be"
      echo "              removed from wp-content, then exit without writing anything."
      exit 0
      ;;
    *) echo "restore.sh: unknown argument: $1 (accepted: --dry-run, -h/--help)" >&2; exit 2 ;;
  esac
done

SG_TMP=""
_sg_cleanup() { [ -n "$SG_TMP" ] && rm -rf "$SG_TMP"; return 0; }
trap _sg_cleanup EXIT

# NOTE: this exits the script, and it does so with an explicit `exit`, not by
# returning non-zero and relying on `set -e`. That matters if it is ever called
# from somewhere errexit does not reach — the left operand of `||`, a `!`, an
# `if` condition — where a `return 1` would be silently downgraded to a warning
# that lets the restore carry on. Keep the `exit`.
_sg_die() { echo "$1" >&2; exit 1; }

# issue #44: only the ssh-remote branch sets NEEDS_RSYNC_ARG_ESCAPING=1 (see
# backup_generate_restore_script's comment on the `rsync ... host:path` line
# for the full reasoning, including why this checks for DEFAULT escaping
# rather than requiring `--protect-args` — that flag was tried first and
# reverted: measured live against a real openrsync SERVER, it makes rsync
# refuse a connection that plain, unflagged rsync completes successfully).
#
# `--old-args` is the probe, not `--version` or a parsed version string:
# it is the explicit opt-OUT of default arg-escaping, so a rsync that
# recognizes it is one that HAS the default-escaping feature at all —
# openrsync (macOS's own /usr/bin/rsync, a different codebase, the only
# rsync macOS 15+ ships) recognizes neither `--old-args` nor default
# escaping. This is a CAPABILITY check, not a guarantee of what the actual
# restore command runs with: an earlier version of this comment claimed a
# rsync recognizing `--old-args` escapes "by construction" when the flag is
# absent, which review measured false — `RSYNC_OLD_ARGS=1` in the
# environment (an operator's profile, a wrapper script; rsync's own
# COMPATIBILITY docs explicitly suggest exporting it for old scripts) makes
# a fully-capable rsync default to the OLD, unescaped behavior even with the
# flag absent, while this exact probe still passes (the binary still
# recognizes `--old-args`). Confirmed live. That is why the restore command
# below carries `--no-old-args` explicitly, rather than relying on this
# probe's pass meaning "the plain invocation is safe" — `--no-old-args`
# FORCES escaping regardless of RSYNC_OLD_ARGS, confirmed live including
# against a real openrsync SERVER (same escaped wire content as the safe
# default, transfer succeeds — it does not reopen the restricted-shell
# regression `--protect-args` caused). This check's job is narrower than it
# used to be: refuse loudly, before touching B, on a rsync that cannot even
# parse `--no-old-args` — not vouch for what the flag-less command would
# have done.
#
# Defined as a function, not run inline here, so the caller (below, after
# the --dry-run early exit) can place the call where it belongs: right
# before the command it gates, not before the argument-parsing / dry-run
# logic above it. An earlier version of this check ran unconditionally at
# this point in the script and made --dry-run refuse too, on a target whose
# rsync lacks this — losing the one thing --dry-run exists for (a safe
# preview) to a check the preview path never actually needs, since it never
# calls rsync at all.
_sg_check_rsync_arg_escaping() {
  [ "$NEEDS_RSYNC_ARG_ESCAPING" -eq 1 ] || return 0
  if ! command -v rsync >/dev/null 2>&1; then
    _sg_die "refusing to restore: rsync is required for this restore and was not found on PATH. Install a GNU-rsync-compatible build (e.g. 'brew install rsync' on macOS; already the default via apt on Debian/Ubuntu) and re-run. Nothing was restored."
  fi
  if ! rsync --old-args --version >/dev/null 2>&1; then
    _sg_die "refusing to restore: this restore's wp-content step forces rsync to escape B's path (--no-old-args) so B's SSH shell never gets a chance to interpret it, and the rsync resolved on PATH here does not support that option at all. This is most often macOS's own /usr/bin/rsync (openrsync, a different implementation from GNU rsync, which never escapes anything): put a GNU rsync >= 3.2.4 first on PATH (e.g. 'brew install rsync' on macOS; already the default via apt on Debian/Ubuntu) and re-run. Nothing was restored. (This is a requirement on the LOCAL rsync only — nothing is required of B's.)"
  fi
}

SG_NL='
'
SG_PRUNE_COUNT=0
SG_ARCHIVE_COUNT=0
SG_MANIFEST_COUNT=0

# _sg_check_rel <relative-path> — the anchor of everything below. Every path
# this script may delete is built by joining B's wp-content root to a path
# that passed through here, so this is the one place where a path could stop
# meaning "inside wp-content". It rejects anything that is not a plain
# relative path under "./", anything carrying a ".." component (which would
# climb out of wp-content), and anything containing a newline (which would
# make the line-oriented set difference below treat one path as two). A
# rejected path is never skipped-and-ignored: the caller aborts the whole
# restore, because a listing that contains one path this script cannot reason
# about is a listing it cannot safely act on at all.
#
# The ".." test is per COMPONENT, not a substring match. A `*../*` glob also
# matches "themes/foo../bar" — a directory legally named "foo.." — and, being
# fail-closed, that did not risk a wrong deletion; it aborted the entire
# restore over a perfectly valid filename, at the moment the operator most
# needs the restore to run.
_sg_check_rel() {
  case "$1" in
    ./?*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *"$SG_NL"*) return 1 ;;
  esac
  local rest="${1#./}" comp
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) comp="${rest%%/*}"; rest="${rest#*/}" ;;
      *)   comp="$rest"; rest="" ;;
    esac
    if [ "$comp" = ".." ]; then return 1; fi
  done
  return 0
}

# The keep-set is the ARCHIVE, and the manifest never deletes anything.
#
# Which of the two artifacts drives the deletion is not a style question, and
# the answer is not the one that looks obvious. It is settled by what the
# extraction does to B's filenames, measured on macOS:
#
#   dst/ holds  Caf\xc3\xa9.css        (NFC — B's own name)
#   src/ holds  Cafe\xcc\x81.css       (NFD — the archive's name)
#   $ tar czf - -C src . | tar xzf - -C dst
#   dst/ now holds  Cafe\xcc\x81.css   (RENAMED)
#
# Extracting the backup does not merely overwrite B's files, it renames them to
# the archive's own byte sequences. So immediately after the extraction — which
# is the only moment at which anything is deleted — B's names ARE the archive's
# names, whatever normalization either side started in. That makes the archive
# listing the one keep-set that is correct by construction, and it makes any
# listing taken BEFORE the extraction (including the manifest) a listing of
# names that may no longer exist.
#
# The manifest still exists, and is still required, for a different job it is
# the only artifact able to do: certify that the archive is COMPLETE. It was
# produced independently, from B's own filesystem at backup time, so comparing
# their entry counts catches a wp-content pull that was partial and an archive
# that lost files afterwards — neither of which a keep-set can detect about
# itself. It is a witness, never an authority: no path is ever deleted because
# the manifest failed to mention it.
#
# _sg_scan_prune — lists B, subtracts the archive. Sets SG_PRUNE_COUNT and
# writes $SG_TMP/to-remove.txt (relative, sorted, for reporting),
# $SG_TMP/to-remove.nul (absolute, NUL-delimited, for xargs) and
# $SG_TMP/missing.txt (archive paths B does not show).
#
# Re-runnable on purpose: it is called again after the extraction, and again
# after the removal to check the removal actually happened.
_sg_scan_prune() {
  local rel abs
  if ! _sg_list_live > "$SG_TMP/live.raw"; then
    _sg_die "refusing to remove anything from B: could not list B's current wp-content (${B_WP_CONTENT_ROOT})"
  fi

  while IFS= read -r -d '' abs; do
    [ -n "$abs" ] || continue
    case "$abs" in
      "${B_WP_CONTENT_ROOT}/"?*) ;;
      *) _sg_die "refusing to remove anything from B: listing B's wp-content returned a path outside ${B_WP_CONTENT_ROOT} ([${abs}])" ;;
    esac
    rel=".${abs#"${B_WP_CONTENT_ROOT}"}"
    _sg_check_rel "$rel" || _sg_die "refusing to remove anything from B: listing B's wp-content returned an unsafe path ([${abs}]) — it is not a plain relative path under wp-content, or it carries a '..' component, or its name contains a newline. A newline in a filename is legal and rare; this script cannot tell such a path apart from two paths, so it refuses to act on the whole listing rather than risk removing the wrong thing. Rename or remove that file by hand, then re-run."
    printf '%s\n' "$rel"
  done < "$SG_TMP/live.raw" > "$SG_TMP/live.txt"

  # "Nothing came back" and "there is nothing to remove" are different
  # answers, and only one of them is safe to act on. A live WordPress
  # wp-content is never empty, so an empty listing means the listing failed
  # silently — a wrapper swallowing its output, a wrong path — and reporting
  # an exact-state restore off the back of it would be reporting success
  # this script has not earned.
  if [ ! -s "$SG_TMP/live.txt" ]; then
    _sg_die "refusing to remove anything from B: listing B's wp-content (${B_WP_CONTENT_ROOT}) returned zero entries. A live wp-content is never empty, so this is a listing that failed silently, not a target with nothing to remove."
  fi

  LC_ALL=C sort "$SG_TMP/live.txt" > "$SG_TMP/live.sorted"
  LC_ALL=C comm -13 "$SG_TMP/archive.sorted" "$SG_TMP/live.sorted" > "$SG_TMP/to-remove.txt"
  # The mirror image: paths the archive holds that B does not show. Before the
  # extraction that is ordinary (they are about to be restored); after it, it
  # is not — see _sg_assert_backup_landed.
  LC_ALL=C comm -23 "$SG_TMP/archive.sorted" "$SG_TMP/live.sorted" > "$SG_TMP/missing.txt"

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    printf '%s\0' "${B_WP_CONTENT_ROOT}/${rel#./}"
  done < "$SG_TMP/to-remove.txt" > "$SG_TMP/to-remove.nul"

  SG_PRUNE_COUNT=$(wc -l < "$SG_TMP/to-remove.txt" | tr -d ' ')
}

# _sg_load_keep_sets — reads the two backup-side listings once: the archive
# (the keep-set) and the manifest (its independent witness). Neither depends on
# B, so neither is re-read on the later scans.
_sg_load_keep_sets() {
  local rel abs

  while IFS= read -r -d '' abs; do
    [ -n "$abs" ] || continue
    rel="$abs"
    _sg_check_rel "$rel" || _sg_die "refusing to remove anything from B: this backup's wp-content archive (${WP_CONTENT_DIR}) holds an entry that is not a safe relative path under wp-content ([${rel}]) — the archive is damaged or was tampered with"
    printf '%s\n' "$rel"
  done < <( cd "$WP_CONTENT_DIR" && find . -mindepth 1 -print0 ) > "$SG_TMP/archive.txt"

  # Reachable, and load-bearing. An earlier version of this comment claimed the
  # integrity block above made it unreachable, because that block refuses a
  # WP_CONTENT_DIR that is missing or lists nothing. That was wrong, and the
  # counter-example is one chmod:
  #
  #   $ chmod 400 <run>/backup/b-wp-content
  #   [ -d ] passes; ls -A returns names (read bit is set)  -> integrity block OK
  #   restore.sh: line NNN: cd: .../b-wp-content: Permission denied
  #   refusing to remove anything from B: ... archive ... listed no entries.
  #
  # Listing the directory needs the READ bit; entering it to run `find` needs
  # the EXECUTE bit. Mode 400 has one and not the other, so the integrity block
  # is satisfied and the listing still comes back empty. Nothing upstream
  # catches it either: the `cd` fails inside a process substitution, whose exit
  # status `set -e` and `pipefail` never see. This line is the only thing
  # standing between a keep-set of zero paths and deleting all of B's
  # wp-content.
  if [ ! -s "$SG_TMP/archive.txt" ]; then
    _sg_die "refusing to remove anything from B: this backup's wp-content archive (${WP_CONTENT_DIR}) listed no entries. An empty keep-list would mean every file in B's wp-content is an addition to delete."
  fi

  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    _sg_check_rel "$rel" || _sg_die "refusing to remove anything from B: this backup's wp-content manifest holds an entry that is not a safe relative path under wp-content ([${rel}]) — the manifest is corrupt or was tampered with"
    printf '%s\n' "$rel"
  done < "$WP_CONTENT_MANIFEST" > "$SG_TMP/manifest.txt"

  # A non-empty FILE and a non-empty PARSED listing are different facts. `[ -s ]`
  # — the only check the manifest used to get — proves the first. A manifest
  # that carries bytes but no NUL delimiter (a newline-delimited file, a copy
  # that lost its trailing NUL) passes it and yields ZERO entries here, and zero
  # entries used to mean "the backup covered nothing", i.e. every path on B is
  # an addition. Measured on this exact script before this check existed: a
  # manifest truncated to 10 bytes emptied a 7-path wp-content, including the
  # two files the backup itself contained, and only then failed. The
  # re-verification pass could not catch it either — it re-read the SAME
  # manifest, so it agreed with itself.
  if [ ! -s "$SG_TMP/manifest.txt" ]; then
    _sg_die "refusing to restore: this backup's wp-content manifest (${WP_CONTENT_MANIFEST}) is not empty as a file but yielded no entries when read. It is NUL-delimited; a copy that lost its delimiters reads as an empty listing, and this script will not certify an archive against a listing it could not read. The manifest is corrupt. Take a fresh backup, or restore from a run that has an intact one."
  fi

  # The cross-check. Compared by entry COUNT, not by name: the two listings come
  # from different filesystems (the manifest from B's own, the archive from the
  # orchestrator's copy) and macOS's tar rewrites accented names between them,
  # so the same file legitimately appears under two byte sequences. Counts are
  # immune to that and still catch what matters: a truncated manifest, a run dir copied only
  # in part, and a wp-content pull that was incomplete when the backup ran.
  SG_ARCHIVE_COUNT=$(wc -l < "$SG_TMP/archive.txt" | tr -d ' ')
  SG_MANIFEST_COUNT=$(wc -l < "$SG_TMP/manifest.txt" | tr -d ' ')
  if [ "$SG_MANIFEST_COUNT" -ne "$SG_ARCHIVE_COUNT" ]; then
    _sg_die "refusing to restore: this backup's wp-content manifest does not describe the archive it sits next to. The manifest (${WP_CONTENT_MANIFEST}) lists ${SG_MANIFEST_COUNT} path(s); the archive (${WP_CONTENT_DIR}) holds ${SG_ARCHIVE_COUNT}. Either the archive is incomplete — in which case restoring from it would delete files that were never additions — or the manifest was truncated after the backup was taken. Take a fresh backup, or restore from a run whose two artifacts agree."
  fi

  LC_ALL=C sort "$SG_TMP/archive.txt" > "$SG_TMP/archive.sorted"
  LC_ALL=C sort "$SG_TMP/manifest.txt" > "$SG_TMP/manifest.sorted"
  # Union of the two, used ONLY to keep the pre-extraction preview honest — see
  # _sg_prune_preflight.
  LC_ALL=C sort -u "$SG_TMP/archive.txt" "$SG_TMP/manifest.txt" > "$SG_TMP/accounted.sorted"

  # issue #35: which of the archive's own paths are REAL DIRECTORIES
  # specifically — a symlink standing in for one of these, on B, is the shape
  # that lets extraction write outside wp-content (see
  # _sg_assert_no_symlink_targets, below, and _sg_list_live_symlinks in this
  # script's header). Filtered from archive.txt (already validated as safe
  # relative paths above) rather than a second `find -type d`, so this can
  # never disagree with it. WP_CONTENT_DIR is the pulled-down archive sitting
  # on THIS machine's own filesystem — never behind a wrapper.
  #
  # `[ -d ] && [ ! -L ]`, NOT a bare `[ -d ]` — bug found by review. `-d`
  # follows a symlink to test what it points AT, so a bare `-d` cannot tell
  # "this archive path is a real directory" apart from "this archive path is
  # a symlink whose target happens to be a directory". The second case is
  # exactly the issue's own motivating setup, reproduced on the archive side
  # of this very check: wp-content/uploads was ALREADY a symlink (to a
  # separate volume, an NFS mount, a CDN-synced directory) at BACKUP time, so
  # neither tar creation side dereferenced it — the archive's own "uploads"
  # is a symlink entry too, not a directory tree. A bare `-d` on that entry
  # returned true whenever its target genuinely existed as a directory
  # (measured: it does, on the machine running this generator), so
  # archive-dirs.sorted wrongly counted "uploads" as a real directory, its
  # unchanged symlink on B matched it below, and a perfectly legitimate
  # restore was refused over nothing — the archive holds no files under that
  # name at all, so there was never anything for extraction to write through
  # it. `[ ! -L ]` closes that: an archive entry that is itself a symlink is
  # never treated as a directory this check needs to protect.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -d "${WP_CONTENT_DIR}/${rel#./}" ] && [ ! -L "${WP_CONTENT_DIR}/${rel#./}" ]; then
      printf '%s\n' "$rel"
    fi
  done < "$SG_TMP/archive.txt" > "$SG_TMP/archive-dirs.txt"
  LC_ALL=C sort "$SG_TMP/archive-dirs.txt" > "$SG_TMP/archive-dirs.sorted"
}

# _sg_assert_no_symlink_targets — issue #35. Called from _sg_prune_preflight,
# strictly BEFORE the extraction that would otherwise write through one.
#
# GNU tar has no portable flag to refuse this on extract, and this script runs
# on the TARGET machine, where neither the tar variant nor its version is
# known — so this detects rather than leaning on any particular tar's own
# protective behavior. Same shape as every other check in this script: read
# both sides, decide, refuse, never guess.
#
# This is a real fix, not defensive padding for a case that cannot happen —
# measured across three extractors, all fed the IDENTICAL ordinary recursive
# archive (built by either gtar or bsdtar; this tool never builds any other
# shape) through this exact `tar czf - | tar xzf -` pipeline, against a
# destination directory symlink:
#
#   extractor                        recursive archive (this tool's shape)
#   GNU tar 1.30 / 1.34 / 1.35       replaces the symlink with a real dir — safe
#   bsdtar 3.5.3 (macOS)             replaces the symlink with a real dir — safe
#   busybox tar 1.36 / 1.37 / 1.38   writes straight through the symlink — UNSAFE
#
# busybox tar ignores the archive's own directory entry for the symlinked
# name (it is present — verified — and changes nothing) and follows the
# symlink anyway. Reachable today: a bare `alpine` or `nginx:alpine` image
# ships busybox tar; `wordpress:cli` and the `*-fpm-alpine` WordPress/PHP
# images install GNU tar 1.35 instead, so they are unaffected as of this
# writing — but which extractor a given target actually has is exactly the
# thing this script cannot know, which is why that fact is not load-bearing
# here.
#
# The set checked is deliberately narrow: only paths this backup's OWN
# archive holds as a directory (archive-dirs.sorted). A symlink elsewhere in
# wp-content that this backup never touches is inert — there is no archive
# entry by that name for tar to extract through it — and refusing over it
# would be alarming and wrong, not safe. Restricting to DIRECTORIES
# specifically is that same narrowness, not a gap in it: verified (review,
# second pass) that busybox tar extracting a plain FILE archive member onto
# an existing symlink of that name replaces it rather than following it, the
# same safe behavior every extractor above shows for a directory entry with
# a real directory already there — the write-through is specific to a
# directory path COMPONENT being a portal during the deeper recursive write,
# which only a directory-shaped archive entry can trigger.
#
# Byte comparison, not normalized: like every other listing this script
# compares (see _sg_assert_backup_landed's own comment on NFC/NFD), archive-
# dirs.sorted and live-symlinks.sorted are compared by raw bytes below. An
# accented directory name that is a symlink on B in a different Unicode
# normalization than the archive's own bytes will not be matched here, and
# the restore proceeds as if it were not a symlink at all — the same known
# gap this file already documents at length for the prune half, not
# something this guard attempts to normalize away; a case-folding alias
# (`Uploads` vs `uploads`, only reachable on a case-insensitive filesystem —
# not the Linux containers this branch actually targets) is the same family
# of gap, left equally undetected.
#
# TOCTOU: this runs at preflight, the extraction runs later — a symlink put
# in place in between is not re-checked, which is outside this tool's
# realistic threat model (an operator running a second, adversarial process
# against B during a restore) but is worth stating plainly rather than
# implying atomicity this script does not have.
_sg_assert_no_symlink_targets() {
  local abs rel
  if ! _sg_list_live_symlinks > "$SG_TMP/live-symlinks.raw"; then
    _sg_die "refusing to restore: could not check B's current wp-content (${B_WP_CONTENT_ROOT}) for symlinks before extracting this backup's archive on top of it"
  fi
  while IFS= read -r -d '' abs; do
    [ -n "$abs" ] || continue
    case "$abs" in
      "${B_WP_CONTENT_ROOT}/"?*) ;;
      *) _sg_die "refusing to restore: listing B's wp-content for symlinks returned a path outside ${B_WP_CONTENT_ROOT} ([${abs}])" ;;
    esac
    rel=".${abs#"${B_WP_CONTENT_ROOT}"}"
    _sg_check_rel "$rel" || _sg_die "refusing to restore: listing B's wp-content for symlinks returned an unsafe path ([${abs}]) — it is not a plain relative path under wp-content, or it carries a '..' component, or its name contains a newline."
    printf '%s\n' "$rel"
  done < "$SG_TMP/live-symlinks.raw" > "$SG_TMP/live-symlinks.txt"
  [ -s "$SG_TMP/live-symlinks.txt" ] || return 0
  LC_ALL=C sort "$SG_TMP/live-symlinks.txt" > "$SG_TMP/live-symlinks.sorted"
  LC_ALL=C comm -12 "$SG_TMP/archive-dirs.sorted" "$SG_TMP/live-symlinks.sorted" > "$SG_TMP/symlink-collision.txt"
  [ -s "$SG_TMP/symlink-collision.txt" ] || return 0
  {
    echo "refusing to restore: B's wp-content (${B_WP_CONTENT_ROOT}) has the following path(s) as a SYMLINK where this backup's archive holds a real directory. Extracting on top of a symlinked directory can write files outside the directory this restore is scoped to (a symlinked wp-content/uploads pointing at a separate volume, an NFS mount, or a CDN-synced directory is a common real-world shape of exactly this). sitegraft does not support restoring onto a symlinked wp-content entry in this situation — nothing was written. Replace the symlink with a real directory (moving its target's contents back under wp-content first, if that is where they actually live) and re-run, or restore this backup somewhere else and reconcile the files by hand."
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      printf '  %s\n' "${B_WP_CONTENT_ROOT}/${rel#./}"
    done < "$SG_TMP/symlink-collision.txt"
  } >&2
  exit 1
}

_sg_prune_preflight() {
  [ "$PRUNE_MODE" = "manifest" ] || return 0
  [ -e "$WP_CONTENT_MANIFEST" ] || _sg_die "refusing to restore: this backup has no wp-content manifest (${WP_CONTENT_MANIFEST}). On this target wp-content cannot be safely wiped and rebuilt, so an exact-state restore depends on knowing what this backup covered — and without that manifest there is nothing to certify the archive against, so restoring could delete files that were never additions. Refusing rather than quietly downgrading to overwrite-only. Take a fresh backup, or restore from a run that has a manifest."
  [ -f "$WP_CONTENT_MANIFEST" ] || _sg_die "refusing to restore: ${WP_CONTENT_MANIFEST} is not a regular file"
  [ -r "$WP_CONTENT_MANIFEST" ] || _sg_die "refusing to restore: the wp-content manifest ${WP_CONTENT_MANIFEST} is not readable"
  [ -s "$WP_CONTENT_MANIFEST" ] || _sg_die "refusing to restore: the wp-content manifest ${WP_CONTENT_MANIFEST} is empty. An empty manifest cannot certify that this backup's archive is complete, and an incomplete archive restored as an exact state deletes files that were never additions. The backup is incomplete."
  SG_TMP=$(mktemp -d) || _sg_die "refusing to restore: could not create a temporary directory"
  _sg_load_keep_sets
  # issue #35: before anything on B is even LISTED for removal, refuse if
  # extracting this backup's archive would write through a symlink standing
  # in for one of the archive's own directories.
  _sg_assert_no_symlink_targets
  _sg_scan_prune

  # The preview is deliberately WIDER than the keep-set: a path is only
  # reported for removal if neither the archive nor the manifest accounts for
  # it. Before the extraction, B still carries its own names — which on macOS
  # are not the archive's names for any accented file (see the block comment
  # above) — and threatening to delete a file that the extraction is in fact
  # about to rename would be alarming and wrong. The real removal set is
  # recomputed after the extraction, when B's names are the archive's names.
  LC_ALL=C comm -13 "$SG_TMP/accounted.sorted" "$SG_TMP/live.sorted" > "$SG_TMP/to-preview.txt"
  SG_PRUNE_COUNT=$(wc -l < "$SG_TMP/to-preview.txt" | tr -d ' ')
}

_sg_report_prune() {
  [ "$PRUNE_MODE" = "manifest" ] || return 0
  if [ "$SG_PRUNE_COUNT" -eq 0 ]; then
    echo "B's wp-content holds no path this backup does not — nothing will be removed."
    return 0
  fi
  echo "${SG_PRUNE_COUNT} path(s) in B's wp-content are not in this backup and will be REMOVED:"
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    printf '  %s\n' "${B_WP_CONTENT_ROOT}/${rel#./}"
  done < "$SG_TMP/to-preview.txt"
}

# _sg_assert_backup_landed — run AFTER the archive has been extracted onto B
# and BEFORE anything is removed. Every path the archive holds must now be
# present on B, byte for byte. Extracting the archive is what puts them there,
# under the archive's own names, so anything still missing means the extraction
# did not fully land — and this script is one step away from deleting files
# while holding a listing it cannot reconcile with the backup.
#
# The other cause is Unicode normalization. "Café.css" has two legal UTF-8
# encodings — NFC (é as one code point, C3 A9) and NFD (e followed by a
# combining acute, 65 CC 81) — and `comm` compares bytes. Extraction normally
# settles that by renaming B's file to the archive's form (measured; see the
# block comment above), but a target that creates a second entry instead of
# renaming, or a tar that converts on the way out, leaves the two forms apart.
#
# What this does NOT do is normalize. Doing that portably needs a Unicode table
# (uconv, iconv -f UTF-8-MAC, python3's unicodedata) that is not guaranteed on
# whatever machine a restore runs on, and this script's whole premise is that
# it runs with ssh/rsync/tar/gzip/find/sort/comm/xargs and nothing else. So it
# detects and refuses, naming the files, and says what it suspects. Refusing a
# restore is recoverable; deleting a file the backup contained is not.
_sg_assert_backup_landed() {
  [ -s "$SG_TMP/missing.txt" ] || return 0
  local n rel shown=0
  n=$(wc -l < "$SG_TMP/missing.txt" | tr -d ' ')
  {
    echo "refusing to remove anything from B: ${n} path(s) this backup contains are still not present on B after extracting it. Nothing was removed, and the database has NOT been touched."
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      shown=$((shown + 1))
      if [ "$shown" -gt 20 ]; then echo "  ... and $((n - 20)) more"; break; fi
      printf '  %s\n' "${B_WP_CONTENT_ROOT}/${rel#./}"
    done < "$SG_TMP/missing.txt"
    # issue #45: naming the paths (above) is not the same as telling the
    # operator what to do about it. The most likely cause, by far, is not a
    # failed extraction (a genuinely un-landed file is rare and this script
    # would already have failed loudly earlier, at the tar/rsync step
    # itself) — it is that the backup and the target disagree on Unicode
    # normalization for these paths: B has each of these files already,
    # spelled with a different, equally legal, sequence of bytes.
    echo "Either the extraction did not fully land, or — more likely, since a failed extraction would already have failed loudly at the tar/rsync step itself — the backup and the target disagree on Unicode normalization for ${n} path(s): an accented filename has two legal UTF-8 encodings (NFC, one code point; NFD, a letter plus a combining mark), and B may be showing one of them while this backup used the other. This script compares bytes, not characters, and refuses rather than guess which of two byte-different names is 'the same file' and delete the one it does not recognise."
    echo "To move forward by hand: for each path listed above, find the file B already has under that name (same folder, same visible characters, different bytes underneath) and rename it on B's filesystem to match the byte sequence printed above exactly — for example, copy the path above as the destination of an 'mv'. If that rename appears to do nothing (some filesystems, including macOS's own APFS by default, treat both byte forms as the same path — the rename is then a true no-op, not a mistake), this backup cannot be restored automatically on this filesystem pairing; apply it by hand outside sitegraft instead. (If a path above genuinely does not exist anywhere on B — not even under a different spelling — the extraction itself did not land it; investigate that instead.) Then re-run this script. Why this restore does not attempt that renaming itself, and when that would be worth revisiting, is written down in docs/decisions/0009-restore-unicode-normalization-refusal.md."
  } >&2
  exit 1
}

_sg_apply_prune() {
  [ "$PRUNE_MODE" = "manifest" ] || return 0
  # Re-scan now that the archive has been extracted: B's names are the
  # archive's names from here on, so this is the first listing that can be
  # subtracted from without guessing.
  _sg_scan_prune
  _sg_assert_backup_landed
  # And it must agree with what the operator was shown. The preview is computed
  # against the archive AND the manifest, so the two sets coincide whenever
  # nothing moved; a difference means either something else is writing to B's
  # wp-content, or the extraction left both normalization forms of a name
  # behind instead of renaming one into the other.
  if ! cmp -s "$SG_TMP/to-preview.txt" "$SG_TMP/to-remove.txt"; then
    _sg_die "refusing to remove anything from B: the set of paths to remove is not the one reported above. Either something else is writing to B's wp-content, or extracting this backup left a filename present under two different Unicode normalizations (compare the listing above to B's actual files by hand — a name repeated with different bytes underneath is the tell; see docs/decisions/0009-restore-unicode-normalization-refusal.md for the remedy). Nothing was removed, and the database has NOT been touched."
  fi
  [ "$SG_PRUNE_COUNT" -gt 0 ] || return 0
  echo "Removing ${SG_PRUNE_COUNT} path(s) added to wp-content since this backup ..."
  # The list travels on stdin, NUL-delimited: no path is ever a command-line
  # argument, so no shell between here and rm can split or re-expand one.
  if ! _sg_delete_from_stdin < "$SG_TMP/to-remove.nul"; then
    echo "removing the files added since this backup FAILED. wp-content was restored on top of B's current files, but files added since the backup may still be there — B is NOT in its pre-backup state. The database has NOT been touched yet. Investigate before re-running." >&2
    exit 1
  fi
  # Never report a removal that did not happen. A wrapper can report success
  # while silently swallowing what it was handed — `ddev exec --raw` does
  # exactly that to piped stdin, and this list is piped. Re-listing B and
  # re-diffing is the only thing that tells "removed" apart from "reported
  # removed".
  _sg_scan_prune
  if [ "$SG_PRUNE_COUNT" -ne 0 ]; then
    echo "the removal command reported success, but ${SG_PRUNE_COUNT} path(s) it was told to remove are still present on B — the removal silently did nothing (a wrapper that drops its stdin does exactly this). B is NOT in its pre-backup state, and the database has NOT been touched. Investigate before re-running." >&2
    exit 1
  fi
  echo "Confirmed: B's wp-content now holds exactly what this backup holds."
}

echo "Verifying backup integrity before restoring anything..."
if [ ! -s "$DB_DUMP" ]; then
  echo "refusing to restore: $DB_DUMP is missing or empty (corrupted or incomplete backup)" >&2
  exit 1
fi
DB_DUMP_SIZE=$(wc -c < "$DB_DUMP" | tr -d ' ')
if [ "$DB_DUMP_SIZE" -lt 200 ]; then
  echo "refusing to restore: $DB_DUMP is suspiciously small (${DB_DUMP_SIZE} bytes)" >&2
  exit 1
fi
if ! gzip -t "$DB_DUMP" 2>/dev/null; then
  echo "refusing to restore: $DB_DUMP is not a valid gzip file (corrupted backup)" >&2
  exit 1
fi
if [ ! -d "$WP_CONTENT_DIR" ] || [ -z "$(ls -A "$WP_CONTENT_DIR" 2>/dev/null)" ]; then
  echo "refusing to restore: $WP_CONTENT_DIR is missing or empty (corrupted or incomplete backup)" >&2
  exit 1
fi
echo "Backup integrity OK."

# What "restore" means on THIS target, said at the moment it is run — not
# only in the `backup` log the operator may never have seen (issue #14).
echo "Restore semantics: ${RESTORE_SEMANTICS}"

# Computed, and printed, BEFORE anything is written: nothing is removed here.
# The set is the same either way — extracting the backup can only add paths
# the manifest already lists — so computing it first costs nothing and means
# the operator sees the deletion list before the first byte is written.
_sg_prune_preflight
_sg_report_prune
EOF

  cat >> "${run_dir}/restore.sh" <<EOF

if [ "\$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] would restore B's wp-content from \${WP_CONTENT_DIR}/ (the exact command is in this script)"
  echo "[dry-run] would restore B's database from \${DB_DUMP}"
  echo "[dry-run] nothing was written to B."
  exit 0
fi

# issue #44: checked here, not earlier — this is the local rsync capability
# this restore is actually about to depend on, and --dry-run (above) never
# reaches this line at all, so a preview stays available even against a
# target this specific check would otherwise refuse.
_sg_check_rsync_arg_escaping

echo "Restoring B wp-content from \${WP_CONTENT_DIR}/ ..."
# Bug found live (not present in the plan's original pseudocode): the
# restore command below is an "A && B" (or "A && B | C") list, and bash's
# \`set -e\` explicitly does NOT abort on the failure of a command that is
# part of such a list, even for the list's own overall non-zero exit status
# — only a bare pipeline or a plain simple command triggers it. Reproduced
# live: an earlier draft relied on \`set -e\` alone here, and when the first
# command in the chain failed (see the busy-mount-point case above), the
# script silently fell through to the database restore step and printed
# "Restore complete." as if wp-content had actually been restored. Wrapping
# the whole chain in an explicit \`if ! { ...; }\` forces its exit status to
# be checked and acted on, regardless of which shape the chain takes.
if ! { ${restore_wp_content_cmd}; }; then
  echo "restoring B's wp-content FAILED — the database has NOT been touched yet; B's files may be left partially restored. Investigate before re-running." >&2
  exit 1
fi
# After the extraction, never before: the destructive half of the restore
# runs only once the restorative half has succeeded, so an interrupted
# restore leaves more of B behind, not less.
_sg_apply_prune
echo "Restoring B database from \${DB_DUMP} ..."
if ! { ${restore_db_cmd}; }; then
  echo "restoring B's database FAILED — wp-content was already restored above; B is now in a MIXED state (new files, old database). Investigate immediately." >&2
  exit 1
fi
echo "Restore complete."
EOF

  # NIT-N6 (Kimi): the last thing a backup produces is the only artifact that
  # is a PROGRAM, and nothing checked that bash could even read it. A single
  # apostrophe in SITE_B_WP_PATH used to emit a restore.sh with a syntax error
  # in it, and `backup` still wrote backup.complete — a backup declared good
  # whose restore path cannot run at all. sq() above is the fix for that
  # particular value; this is the net under it, and the natural place to catch
  # whatever the NEXT unquoted interpolation turns out to be. Discarded rather
  # than left behind: a restore.sh that does not parse is not a partial
  # capability, and leaving it means the missing-restore.sh guard in
  # phase_restore never fires either.
  local parse_err
  if ! parse_err=$(bash -n "${run_dir}/restore.sh" 2>&1); then
    rm -f "${run_dir}/restore.sh"
    log_error "the generated restore.sh does not parse and has been discarded — a backup whose restore script bash cannot read is not restorable. Check the profile's SITE_B_* values for a character that broke the generated file: ${parse_err}"
    return 1
  fi
  chmod 700 "${run_dir}/restore.sh"
}

# backup_prefix_tables_csv <prefix> <tables_csv> — pure string function, no
# I/O. lib/manifest.sh's own documented convention (see its comment above
# manifest_compute_unclaimed): a module's declared `tables` are bare
# SUFFIXES ("fakebooking_reservations"), never the live-prefixed name a real
# install actually uses ("wp_fakebooking_reservations") — wp-cli's own
# `--tables=`/`db query` need the real, prefixed name. One shared
# implementation (same "never three different implementations" reasoning as
# backup_checksum's own normalization above) so backup and verify resolve a
# manifest's table suffixes to real table names IDENTICALLY — a mismatch
# here would make backup's PRE-graft checksum and verify's POST-graft
# checksum silently stop being comparable.
backup_prefix_tables_csv() {
  local prefix="$1" tables_csv="$2"
  [ -n "$tables_csv" ] || return 0
  local IFS=','
  local out="" t
  for t in $tables_csv; do
    [ -n "$t" ] || continue
    out="${out}${out:+,}${prefix}${t}"
  done
  printf '%s' "$out"
}

# backup_compute_protected_checksums <alias> <manifest_json> — the exact
# checksum computation phase_backup uses to populate
# manifest.checksums_protected_pre_graft, extracted into its own function
# (review/nightshift follow-up, design doc §6.3/§6.5) specifically so
# phase_verify (Step 5) can recompute the IDENTICAL thing post-graft — never
# a second, subtly different implementation that could silently drift from
# this one. Real bug found live via the Step 5 DDEV harness (not caught by
# any earlier unit test, since every unit test's wp_remote/
# inventory_table_prefix stubs return canned content regardless of the
# --tables= value passed in): without backup_prefix_tables_csv's
# resolution, this loop's `--tables=` argument never matched any real table
# on a live install (a bare suffix, not B's actual live-prefixed table
# name) — silently checksumming empty content instead of the real protected
# data. Not a smaller bug than it sounds: an empty-vs-empty checksum still
# "matches" before/after graft, so the tool's central non-contamination
# promise would have reported success without ever actually having checked
# anything.
#
# A module with no `tables` at all (e.g. `_unclaimed`, always `tables: []`,
# or any post_type/option_key-only module) is skipped, not sent as an empty
# --tables= (not a meaningful export request) — plan bug fix already present
# before this extraction, kept as-is.
#
# issue #97 — three states per table, not two. A `wp db export` that fails
# (a locked table, a permissions error, a table this run's manifest names
# but this particular install does not actually have) used to fall through
# an internal `|| echo ""` and get checksummed as though its content were
# the empty string — indistinguishable from a table that really is empty.
# The worst case (measured, not hypothetical): the SAME table fails to
# export before the graft and after it. sha256("") matches itself, and the
# report ends up asserting protected data is unchanged for a table it never
# actually read, either time.
#
# Fixed by checking wp_remote's own exit status instead of discarding it,
# and then splitting on which of the two buckets above (declared vs.
# `_unclaimed`) the failing table belongs to — the same split this
# function's docblock already draws for a table that CHANGED, extended here
# to a table that could not be READ, for the identical reason:
#
#   - A DECLARED module's table failing to export is a hard failure of this
#     whole function (non-zero return, nothing printed). An operator named
#     that table as something to protect; if it cannot be read, the
#     function does not know whether it is untouched, and has no scope
#     narrower than "protected data cannot be confirmed" to report that in.
#     Both of this function's callers already treat a non-zero return as a
#     hard failure — `phase_backup`, below, refuses to declare the backup
#     good, and `phase_verify`'s recompute (lib/verify.sh) already hard-
#     fails the same way for issue #33 (a total recompute failure). One
#     failure mode, inherited by both phases for free, rather than a new,
#     second one that could drift from #33's.
#
#   - An `_unclaimed:<table>` failing to export is NOT treated as a reason
#     to abort the whole computation. These tables are, by definition,
#     outside anything the operator declared protected — often several
#     dozen of them on a real site. Aborting backup (which blocks the
#     operator on the very command meant to protect them, before the graft
#     has even started) over ONE such table having a transient permission
#     quirk or a lock held by an unrelated process would be exactly the
#     "legitimate case a hardening wrongly refuses" this issue warns
#     against — the same argument already made, for CHANGES rather than
#     read failures, in the hard/soft split above. Instead, the table's
#     checksum value is the literal string "unreadable" — never a valid
#     "sha256:..." value — so it can never again silently pass as either a
#     match or a no-op empty read. `verify_compare_checksums` (lib/
#     verify.sh) treats that sentinel as its own third outcome: NOT
#     VERIFIED, neither a confirmed match nor a confirmed change — closing
#     the exact "unreadable-vs-unreadable still matches itself" case this
#     issue measured, one level below where #33 already closed it for a
#     total recompute failure.
#
# Measured, not assumed (corrected, review of PR #105 — the first version of
# this comment guessed wrong): a DECLARED module's table that does not
# actually exist on B (a static `_tables` function, per lib/plan.sh's own
# comment on `owns_tables`, is never filtered against a live scan the way a
# `_tables_dynamic` selection is — so this is a real, reachable shape, not a
# hypothetical one; modules/motopress.sh.example, shipped in this repo,
# declares exactly one such static table) is treated as a hard failure too,
# same as any other unreadable declared table — and it turns out that isn't
# a shortcut around a harder distinction, it's the only reading the data
# supports. Verified live against a real MariaDB 11: `wp db export
# --tables=<name>` (mysqldump underneath) exits 6 with `Couldn't find
# table: "wp_x"` BOTH for a table that genuinely does not exist AND for one
# that exists but this wp-cli user has no privilege on — same exit code,
# same message text, in both cases. MySQL/MariaDB does this ON PURPOSE (an
# unprivileged user should not be able to learn a hidden table's existence
# from mysqldump's own error) — there is nothing in wp_remote's exit status
# OR mysqldump's stderr that tells "absent" apart from "exists, but you may
# not see it". Treating them identically isn't settling for less; there is
# no more to read.
#
# What CAN be told apart, from data already on disk: whether THIS RUN'S OWN
# manifest even claims to know the table exists. `phase_backup`/
# `phase_verify` (below) pass scan-b.json's own `.tables` list — the live,
# already-prefixed table names `sitegraft scan` actually saw on B, the
# exact same string space `backup_prefix_tables_csv` resolves a module's
# suffix into — as this function's OPTIONAL third argument. When present, a
# declared table absent from THAT list gets a message that says so
# specifically ("module X declares table Y, which B's last scan never
# saw — a module/site mismatch"), instead of the generic unreadable-table
# message. It changes nothing about the OUTCOME (still a hard failure
# either way — unreadable is unreadable, per the paragraph above) — only
# the message, which is the actual point: an operator staring at "could not
# export" needs to know whether to go check permissions on B or to go fix
# the module. `manifest_compute_unclaimed` (lib/manifest.sh) already
# resolves table names against this exact scan-b.json list, for the
# identical reason; this reuses the same data, not a second lookup of it.
#
# An absent third argument (every 2-arg call site, including every existing
# unit test) means "no scan-b.json list available to cross-check against",
# never "B has zero tables" — only a real, NON-EMPTY JSON array turns the
# mismatch message on. An omitted argument, an unparseable one, AND a
# genuinely empty array `[]` all fall through to the generic message
# instead — `[]` is what a scan that saw nothing at all looks like
# (including a failed `wp db tables`, which lib/inventory.sh's own
# inventory_scan_site now refuses to swallow into an empty array — issue
# #107 — but this guard stays as defense in depth for a scan file written
# before that fix, or edited by hand), and "the scan saw nothing" must
# read as "unknown", never as "confirmed this table doesn't exist".
backup_compute_protected_checksums() {
  local alias_lc="$1" manifest="$2" scan_b_tables_json="${3:-}"
  local prefix
  prefix=$(inventory_table_prefix "$alias_lc") || return 1
  # issue #97 review fix-pack: "" (the default above) means "no scan-b.json
  # table list available" — NOT "B has zero tables". Only a genuine,
  # NON-EMPTY JSON array turns the mismatch message in the declared-table
  # branch below on; an empty string, a value that fails to parse as an
  # array, OR a genuinely empty array `[]`, all fall through to the generic
  # message instead.
  #
  # `and length > 0` (review, PR #105 round 2): a bare `[]` used to pass
  # `type == "array"` and set have_scan_tables=1, which then reported EVERY
  # declared table as a module/site mismatch — accusing the module for a
  # scan that saw nothing at all. Reachable through the exact default this
  # issue is about, one layer up: lib/inventory.sh's inventory_scan_site
  # built scan-b.json's `.tables` via `wp_remote ... db tables | jq -R -s
  # -c ...` with no exit-status check on the wp-cli call, so a failing `wp
  # db tables` (permissions, connectivity) was swallowed by the pipe into
  # an empty array rather than aborting the scan — fixed at that source by
  # issue #107, which now fails the scan outright instead. This guard is
  # kept regardless, as defense in depth for a scan file predating that
  # fix or edited by hand: an empty scan result means "unknown whether B
  # has this table", the identical "empty vs. unread" conflation this
  # whole issue exists to close, not "confirmed absent" — so it must not
  # be allowed to accuse a module of a mismatch it cannot actually see.
  local have_scan_tables=0
  if [ -n "$scan_b_tables_json" ] && echo "$scan_b_tables_json" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    have_scan_tables=1
  fi
  local checksums='{}' mod
  local mods
  mods=$(echo "$manifest" | jq -r '.protect | keys[]')
  # A read loop over fd 3, not `for mod in $(...)` (issue #40) — same fix,
  # same reason, as graft_migrate_options/verify_options_match: unquoted
  # command substitution word-splits, so a module name containing whitespace
  # becomes two names, one of which matches nothing in .protect and is
  # silently skipped rather than checksummed. Module names are read from
  # `modules/*.sh` filenames (lib/modules.sh) with nothing stopping an author
  # from picking one with a space in it. fd 3 rather than stdin also matters
  # here: the `_unclaimed` branch below runs wp_remote (ssh) inside a NESTED
  # read loop of its own, which already uses fd 3 for the same reason.
  while IFS= read -r mod <&3; do
    [ -n "$mod" ] || continue
    local tables_csv
    tables_csv=$(echo "$manifest" | jq -r --arg m "$mod" '.protect[$m].tables // [] | join(",")')
    [ -n "$tables_csv" ] || continue

    # `_unclaimed` is checksummed ONE TABLE AT A TIME, under keys of the form
    # "_unclaimed:<table>". Every other module keeps a single aggregate
    # checksum over all the tables it declares.
    #
    # The difference is about what a mismatch can tell the operator. A module
    # declares a handful of tables it owns, so "this module's data changed"
    # is already actionable. `_unclaimed` is everything else on B — often
    # ninety-odd tables — and one aggregate over that says only "something,
    # somewhere, moved", which nobody can act on and everybody learns to
    # ignore. Named per table, the same information becomes a short, precise
    # list.
    #
    # It also lets verify treat the two differently: a declared table that
    # changed is a hard failure, an unclaimed one is reported. That
    # distinction is the whole reason this list can be populated at all —
    # tables like the action scheduler's are written continuously by
    # WordPress itself, and would otherwise fail every run.
    #
    # Cost: one `wp db export` per unclaimed table instead of one for the
    # set. Real, and worth it — these run on a site that is meant to be
    # quiescent for the duration anyway.
    if [ "$mod" = "_unclaimed" ]; then
      # Read on fd 3, not stdin. wp_remote runs inside this loop, and a
      # wrapper of the form `docker run -i` (or an ssh) consumes the loop's
      # own fd0 — the first table would be checksummed and every table after
      # it silently skipped. lib/graft.sh already guards its id-map loops the
      # same way, for the same reason; caught here by a test that expected
      # two checksums and got one.
      local tbl
      while IFS= read -r tbl <&3; do
        [ -n "$tbl" ] || continue
        # NOT run through backup_prefix_tables_csv: `_unclaimed.tables` holds
        # FULL table names as scan read them off the site, where a module's
        # `_tables` holds bare suffixes for sitegraft to prefix. Prefixing
        # these a second time would ask for `wpfn_wpfn_...`.
        #
        # issue #97: `wp_remote`'s own exit status is checked, not discarded
        # — a failed export is recorded as the sentinel "unreadable" (see
        # this function's own header comment), never checksummed as though
        # its content were empty. Out-of-scope by definition, so this one
        # table's failure does not abort the sweep — the loop continues to
        # the next table either way.
        local one_content
        if one_content=$(wp_remote "$alias_lc" db export - --tables="$tbl" 2>/dev/null); then
          local one_sum
          one_sum=$(backup_checksum "$one_content")
          checksums=$(echo "$checksums" | jq --arg m "_unclaimed:${tbl}" --arg s "sha256:${one_sum}" '.[$m] = $s')
        else
          log_warn "could not export unclaimed table '${tbl}' on ${alias_lc} for its protected-data checksum — recorded as unreadable rather than checksummed as empty. Out of the declared protect scope, so this table alone does not abort the run; see verify's report for what an unreadable table means for this run's result."
          checksums=$(echo "$checksums" | jq --arg m "_unclaimed:${tbl}" '.[$m] = "unreadable"')
        fi
      done 3<<< "$(echo "$manifest" | jq -r --arg m "$mod" '.protect[$m].tables // [] | .[]')"
      continue
    fi

    local prefixed_tables_csv tables_content sum
    prefixed_tables_csv=$(backup_prefix_tables_csv "$prefix" "$tables_csv")
    # issue #97: same exit-status check as the `_unclaimed` branch above,
    # but this table WAS named by an operator as protected — no "out of
    # scope" reading is available here, so a failed export is a hard
    # failure of the whole computation (see this function's own header
    # comment for why both callers already do the right thing with that).
    #
    # Review fix-pack (PR #105, mineur 5): stderr is now captured, not
    # discarded — a module can declare several tables at once
    # (`prefixed_tables_csv` is a CSV, one wp_remote call for the lot), so
    # without this the error named the whole list and never which one
    # actually failed. mysqldump already names it in its own stderr; this
    # surfaces that text instead of re-deriving it. sitegraft_mktemp_dir
    # (lib/core.sh) is the established capture-stderr-to-a-file pattern
    # this codebase already uses for exactly this reason (lib/graft.sh's
    # WXR helpers, lib/verify.sh's content-remap CLI) — its directory is
    # registered for cleanup on exit, not removed here.
    #
    # tmp_dir's OWN result is verified before use (review, PR #105 round
    # 2): at the time, sitegraft_mktemp_dir's `mktemp -d` was not itself
    # guarded (lib/core.sh), so a full/read-only TMPDIR made it echo an
    # empty string rather than fail loudly. Measured: an unverified
    # `stderr_file` in that case becomes the bare path "/stderr" — the
    # redirect itself then fails to open (a real, unrelated error, since
    # "/" is not writable), so `wp_remote` never even runs, and a table
    # that would have exported PERFECTLY gets reported as unreadable, with
    # a raw shell redirection error leaking a filesystem path into the
    # message on top. sitegraft_mktemp_dir itself now fails loudly on a
    # bad mktemp (issue #109) — this check stays regardless, because this
    # function is called as the left side of `||` by its own caller
    # (backup_compute_protected_checksums), which disables errexit for
    # its entire call tree, so even sitegraft_mktemp_dir's own `return 1`
    # would otherwise be silently absorbed here too (verified live, same
    # mechanism as lib/graft.sh's two callers fixed by the same issue).
    # Falls back to /dev/null (the exact behavior every call site had
    # before this fix-pack introduced stderr capture at all) whenever
    # tmp_dir does not come back as a real, existing directory — this
    # failure mode is about losing the improved diagnostic, never about
    # losing correctness: the export itself still runs (or still fails)
    # on its own merits.
    local tmp_dir stderr_file="" err_text=""
    tmp_dir=$(sitegraft_mktemp_dir)
    if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
      stderr_file="${tmp_dir}/stderr"
    fi
    if ! tables_content=$(wp_remote "$alias_lc" db export - --tables="$prefixed_tables_csv" 2>"${stderr_file:-/dev/null}"); then
      [ -n "$stderr_file" ] && [ -s "$stderr_file" ] && err_text=$(cat "$stderr_file")
      # Review fix-pack (PR #105, design ask): when scan-b.json's own table
      # list is available (see this function's own header comment), a
      # declared table absent from it gets a message that names the actual
      # mismatch — module vs. site — rather than the generic unreadable-
      # table message below. Still a hard failure either way; only the
      # wording changes.
      if [ "$have_scan_tables" = "1" ]; then
        local missing
        # `as $t | select(($scan | index($t)) | not) | $t`, NOT
        # `select(($scan | index(.)) | not)` — lib/manifest.sh's own
        # manifest_compute_unclaimed carries a comment on this exact jq
        # pitfall (found there via TDD, reproduced here the same way while
        # writing this fix-pack's tests): piping INTO `index(.)` rebinds
        # `.` to whatever was piped in ($scan itself), not to the outer
        # $wanted[] element under select — silently searching $scan for
        # $scan, which is never found, so `missing` never named anything.
        # `as $t` binds the element explicitly, immune to the rebind.
        missing=$(jq -n --argjson scan "$scan_b_tables_json" --arg csv "$prefixed_tables_csv" \
          '($csv | split(",") | map(select(length > 0))) as $wanted
           | [$wanted[] as $t | select(($scan | index($t)) | not) | $t]')
        if [ "$(echo "$missing" | jq 'length')" != "0" ]; then
          log_error "module '${mod}' declares table(s) $(echo "$missing" | jq -r 'join(", ")') that ${alias_lc}'s last scan (scan-b.json) never saw — a module/site mismatch, not (necessarily) a permission or lock problem. Re-run 'sitegraft scan' if B has genuinely changed since, or fix/remove this module's declared table name(s).${err_text:+ (mysqldump also reported: ${err_text})}"
          return 1
        fi
      fi
      log_error "could not export table(s) [${prefixed_tables_csv}] declared by protected module '${mod}' — a table this run was asked to protect could not be read, so it cannot be confirmed unchanged. Never checksummed as empty.${err_text:+ (${err_text})}"
      return 1
    fi
    sum=$(backup_checksum "$tables_content")
    checksums=$(echo "$checksums" | jq --arg m "$mod" --arg s "sha256:${sum}" '.[$m] = $s')
  done 3<<< "$mods"
  printf '%s' "$checksums"
}

# backup_content_checksum_of_row <post_json_row> — sha256 of one post's
# post_content+post_excerpt, issue #52 / ADR 0008's "Required regardless"
# list. <post_json_row> is a single element of a `wp post list --format=json
# --fields=ID,post_content,post_excerpt` array (an object with those three
# keys; a missing post_excerpt is treated as "", not an error — some callers
# may hand this a row shape that never had one).
#
# Hashes a compact JSON PAIR of the two fields, never a plain string
# concatenation of them: "ab"+"c" and "a"+"bc" must never collide onto the
# same checksum, and jq's `-c` encoding is what makes the field boundary
# unambiguous regardless of what bytes either field holds (newlines,
# unicode, an embedded NUL-shaped byte sequence — none of it needs any
# escaping of its own here, unlike a raw bash string join, which cannot
# even represent a real NUL byte in a captured variable in the first
# place). Same reasoning as backup_checksum's own normalization above:
# ONE implementation, called both where the pre-graft snapshot is captured
# (backup_compute_content_checksums, below — phase_backup) and where it is
# recomputed post-graft (lib/verify.sh's verify_migrated_content_changed_
# from_pregraft) — never two independently-drifting copies of "how do you
# checksum a post's content".
backup_content_checksum_of_row() {
  local row_json="$1"
  echo "$row_json" | jq -c '{c: (.post_content // ""), e: (.post_excerpt // "")}' | shasum -a 256 | awk '{print $1}'
}

# backup_compute_content_checksums <alias> <manifest_json> — issue #52 /
# ADR 0008's "Required regardless" list: a pre-graft content-checksum
# snapshot of <alias>'s OWN posts, for every post_type selected in
# manifest.migrate (attachment excluded — attachments are migrated by file
# sync, design doc §9, never verified by content equality), keyed by
# <alias>'s own post ID. This is the pre-graft baseline lib/verify.sh's guard 2
# (verify_migrated_content_changed_from_pregraft) checks a post-graft
# re-read against: a row whose checksum comes back IDENTICAL after the
# graft ran was never actually touched — exactly the shape of the observed
# defect (a colliding item wordpress-importer silently skipped instead of
# importing, see ADR 0008's Context section and issue #52).
#
# Captured HERE, in backup — not in graft, not in verify — because backup is
# the one phase graft's own precondition guard (`[ -f
# "${run_dir}/backup.complete" ]`, phase_graft in lib/graft.sh) GUARANTEES
# has already run, completely, before graft's first write to B. A record
# that can only be produced after graft has already run is not a "before"
# record at all — this has to be taken while the data it will later be a
# baseline FOR still reflects B's genuinely pre-graft state. (It could in
# principle be computed inside `graft` itself, right before graft's first
# write — but backup already runs strictly earlier and is already the
# phase that snapshots "protected data as it stood before this run", so
# putting a second, independent pre-graft snapshot mechanism in a different
# phase would only invite the two to drift on timing.)
#
# Stored on manifest.content_checksums_pre_graft by phase_backup below —
# same single-source-of-truth pattern checksums_protected_pre_graft already
# uses (one JSON value living in manifest.json, recomputed post-graft by
# the exact same per-row checksum function, never a second hand-kept-in-
# sync copy). A run whose manifest predates this feature simply has no
# such key at all — lib/verify.sh's own guard is responsible for treating
# that absence as INCOMPLETE, never as "confirmed unchanged" or a silent
# pass; see that function's own comment.
#
# Returns `{}` (a real, valid, empty snapshot — not an error) when nothing
# is selected for migration at all: an options-only run has no post content
# to snapshot, and "computed a snapshot of zero post_types" is a known
# fact, not a failure. Fails CLOSED (non-zero, logged) when B's post list
# itself could not be read or did not come back as valid JSON — the
# identical "a query error is not the same as a confirmed empty result"
# discipline backup_compute_protected_checksums and lib/verify.sh's own
# checks already apply throughout this codebase.
backup_compute_content_checksums() {
  local alias_lc="$1" manifest="$2"
  local post_types_csv
  post_types_csv=$(echo "$manifest" | jq -r '[.migrate[].post_types[]?] | unique | map(select(. != "attachment")) | join(",")')
  [ -n "$post_types_csv" ] || { echo '{}'; return 0; }

  local rows
  rows=$(wp_remote "$alias_lc" post list --post_type="$post_types_csv" --post_status=any --fields=ID,post_content,post_excerpt --format=json 2>/dev/null) || {
    log_error "could not list ${alias_lc}'s post(s) of type(s) ${post_types_csv} to compute the pre-graft content-checksum snapshot"
    return 1
  }
  echo "$rows" | jq -e . >/dev/null 2>&1 || {
    log_error "post list for the pre-graft content-checksum snapshot did not return valid JSON"
    return 1
  }

  local checksums='{}'
  local row id sum
  # Read on fd 3, not stdin (same convention, same reason, as this file's
  # own _unclaimed loop immediately above and lib/graft.sh's id-map loops):
  # nothing inside this particular loop body shells out to ssh, so stdin
  # isn't actually at risk here today, but a future edit that adds a
  # wp_remote call inside the loop must not silently reintroduce that
  # class of bug — matching the established pattern up front costs nothing.
  while IFS= read -r row <&3; do
    [ -n "$row" ] || continue
    id=$(echo "$row" | jq -r '.ID')
    sum=$(backup_content_checksum_of_row "$row")
    checksums=$(echo "$checksums" | jq --arg id "$id" --arg s "sha256:${sum}" '.[$id] = $s')
  done 3<<< "$(echo "$rows" | jq -c '.[]')"
  printf '%s' "$checksums"
}

# phase_backup --profile <name> [--run <run-dir>] [--dry-run] — design doc
# §6.3: full DB + wp-content backup of B, pulled to the orchestrator, BEFORE
# graft ever writes anything to B. Requires a frozen manifest (`sitegraft
# plan` must have already run for this profile/run).
phase_backup() {
  local profile="" run_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      --dry-run) SITEGRAFT_DRY_RUN=1; shift ;;
      *) log_error "unknown flag for backup: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "backup requires --profile <name>"; return 1; }
  profile_load "$profile" || return 1

  # issue #94 / ADR 0010: one check, at phase start, not re-probed before
  # each of this phase's ssh-remote pulls (backup_wp_content is the only
  # one today, but the check belongs at this level, not inside that
  # function, so a future second pull site doesn't have to remember to add
  # its own copy — see sitegraft_require_rsync_arg_escaping's own comment
  # for why a phase-start check was chosen over a per-call probe). Skipped
  # entirely under --dry-run (never calls rsync for real) and when B isn't
  # ssh-remote at all (nothing here needs it).
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    is_dry_run || sitegraft_require_rsync_arg_escaping || return 1
  fi

  [ -n "$run_dir" ] || run_dir=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1 || true)
  [ -n "$run_dir" ] || {
    log_error "no scan/plan run found for profile ${profile} — run 'sitegraft scan' and 'sitegraft plan' first"
    return 1
  }
  [ -f "${run_dir}/manifest.json" ] || {
    log_error "no frozen manifest found at ${run_dir}/manifest.json — run 'sitegraft plan' first"
    return 1
  }
  jq -e '.frozen == true' "${run_dir}/manifest.json" >/dev/null 2>&1 || {
    log_error "manifest at ${run_dir}/manifest.json is not frozen — re-run 'sitegraft plan' to freeze it"
    return 1
  }

  # design doc §0 (--dry-run global contract) / mission clarification: backup
  # never reads B destructively in the first place (db export and rsync pull
  # are both read-only against B regardless of dry-run) — what --dry-run
  # actually simulates here is the WRITE side, on the orchestrator:
  # run_or_echo (inside backup_db_export/backup_wp_content) prints the
  # commands instead of running them, so no real backup files land in
  # run_dir. Verification, checksumming, and the backup.complete marker are
  # all skipped in that case — there is nothing real yet to verify, and a
  # dry run must never look like a completed, restorable backup.
  if is_dry_run; then
    log_info "--dry-run: backup will print the commands it would run (read-only against B either way) and NOT write real backup files, checksums, or a completion marker"
  fi

  # MAJOR bug found by review (Viktor), reproduced live: the subshell's LAST
  # statement used to be `[ -f ... ] && chmod 600 ...`. Under a real
  # --dry-run, backup_db_export writes nothing (run_or_echo only prints),
  # so `[ -f ]` is false, the `&&` short-circuits chmod, and the subshell's
  # own exit status becomes that FALSE test's status (1) — which
  # `) || return 1` then reads as a hard failure. A dry run used to abort
  # with a false "failed" report, and never reached
  # backup_generate_restore_script below, so the "restore.sh was generated
  # for inspection" log line was a lie too. `set -e` inside the subshell is
  # a separate, additional hardening (Viktor's NIT): without it, a genuine
  # backup_db_export failure on a REAL (non-dry-run) call wasn't guaranteed
  # to stop the subshell early — this makes that fail fast and loud instead
  # of relying solely on the verification step below to catch it.
  (
    set -e
    umask 077
    mkdir -p "${run_dir}/backup"
    chmod 700 "${run_dir}/backup"
    # `|| exit 1` on all three, not left to the `set -e` above. Verified on
    # bash 3.2.57: bash suppresses errexit for the WHOLE of a compound command
    # that is the left operand of `||` — which this subshell is (`) || return
    # 1`) — and an explicit `set -e` inside it does NOT re-enable it:
    #
    #   f() { return 1; }
    #   ( set -e; echo A; f; echo B; true ) || echo "subshell failed"
    #   -> A / B, and "subshell failed" never prints.
    #
    # An earlier version documented the first two as "saved by their own
    # downstream verification" instead. That is true of the database dump,
    # which really is checked afterwards (gzip -t, a size floor, its core
    # tables). It is not true of wp-content: backup_verify_wp_content only
    # tests that the directory is non-empty, so a PARTIAL pull passes it. This
    # feature makes that materially worse — the manifest is cross-checked
    # against the archive, and both would be partial together on the same run —
    # so the restore would go on to delete files that were never additions.
    # Two lines, rather than an argument about why they are not needed.
    backup_db_export "${run_dir}/backup" || exit 1
    backup_wp_content "${run_dir}/backup/b-wp-content" || exit 1
    # issue #14: recorded here, right after the archive it cross-checks
    # against, so the two can never be out of step. The generated restore.sh
    # refuses to remove anything without it.
    backup_write_wp_content_manifest "${run_dir}/backup/b-wp-content" "${run_dir}/backup/b-wp-content.manifest" || exit 1
    if [ -f "${run_dir}/backup/b-db.sql.gz" ]; then
      chmod 600 "${run_dir}/backup/b-db.sql.gz"
    fi
  ) || { log_error "backup failed while exporting/archiving B — see the transfer tool's own output above for the reason (db export, wp-content pull, or wp-content manifest). No backup.complete was written."; return 1; }

  local manifest
  manifest=$(cat "${run_dir}/manifest.json")

  if ! is_dry_run; then
    local prefix
    prefix=$(inventory_table_prefix b) || { log_error "could not determine B's live table prefix — aborting before declaring the backup good"; return 1; }
    backup_verify_db_export "${run_dir}/backup/b-db.sql.gz" "$prefix" || return 1
    backup_verify_wp_content "${run_dir}/backup/b-wp-content" || return 1
    # issue #14: the manifest is a backup artifact like the other two, and it
    # is what a restore of a wrapped-local B is useless without — so it is
    # verified before the backup is declared good, not discovered missing at
    # restore time.
    if [ ! -s "${run_dir}/backup/b-wp-content.manifest" ]; then
      log_error "backup verification failed: ${run_dir}/backup/b-wp-content.manifest is missing or empty — without it, restore.sh cannot return B's wp-content to exactly this state and will refuse to remove anything"
      return 1
    fi
    # issue #99 (review NIT): the completion-marker check is now the
    # load-bearing signal that the export actually finished (the core-table
    # probe alone cannot see a die-after-posts truncation) — say so here,
    # not just "core tables present", which is the exact reassurance #99
    # cites as a false one.
    log_info "backup artifacts verified: valid gzip, mysqldump completion marker present, core tables present, wp-content non-empty, wp-content manifest recorded"

    # design doc §6.3: checksums of the protected tables/options exports,
    # using the exact same normalization backup_checksum defines above, and
    # the exact same table-suffix-to-live-prefix resolution phase_verify
    # (Step 5) will later reuse via backup_compute_protected_checksums —
    # see that function's own comment for why this must never be a second,
    # independent implementation.
    #
    # issue #97 review fix-pack (PR #105): scan-b.json's own `.tables` list
    # is read here, if the file exists and parses, and handed to
    # backup_compute_protected_checksums as its optional third argument —
    # see that function's own header comment for what it does with it (an
    # actionable module/site-mismatch message for a declared table absent
    # from B's last scan, rather than a generic unreadable-table one). Left
    # unset (empty string) on any read/parse failure — a missing or broken
    # scan-b.json is not itself a backup failure, it only means this one
    # message stays generic, exactly like every 2-arg call this function
    # already had before this fix-pack.
    local scan_b_tables=""
    if [ -f "${run_dir}/scan-b.json" ]; then
      scan_b_tables=$(jq -c '.tables // empty' "${run_dir}/scan-b.json" 2>/dev/null) || scan_b_tables=""
    fi
    local checksums
    checksums=$(backup_compute_protected_checksums b "$manifest" "$scan_b_tables") || { log_error "could not compute protected-data checksums — aborting before declaring the backup good"; return 1; }
    manifest=$(echo "$manifest" | jq --argjson c "$checksums" '.checksums_protected_pre_graft = $c')

    # issue #52 / ADR 0008's "Required regardless" list: the pre-graft
    # content-checksum snapshot lib/verify.sh's content-equality guards read
    # back post-graft. Computed here, right alongside the protected-data
    # checksums immediately above and for the identical reason — this is
    # the one moment guaranteed to run, completely, before graft's first
    # write to B (see backup_compute_content_checksums' own comment). A
    # failure here aborts the backup the same way a failure to compute the
    # protected checksums does: a backup that could not record what B
    # looked like before the graft is not a backup this tool may declare
    # good.
    local content_checksums
    content_checksums=$(backup_compute_content_checksums b "$manifest") || { log_error "could not compute the pre-graft content-checksum snapshot — aborting before declaring the backup good"; return 1; }
    manifest=$(echo "$manifest" | jq --argjson c "$content_checksums" '.content_checksums_pre_graft = $c')

    echo "$manifest" > "${run_dir}/manifest.json"
    chmod 600 "${run_dir}/manifest.json" 2>/dev/null || true
  fi

  # `|| return 1`: the generated restore.sh is now refused (and discarded) if
  # bash cannot parse it, and a backup whose restore script does not exist is
  # not a backup that may be marked complete.
  backup_generate_restore_script "$run_dir" || return 1

  if ! is_dry_run; then
    touch "${run_dir}/backup.complete"
    chmod 600 "${run_dir}/backup.complete" 2>/dev/null || true
    log_info "backup complete: ${run_dir}/backup.complete"
    log_info "to restore this backup, run: ${run_dir}/restore.sh   (or: sitegraft restore --profile ${profile} --run ${run_dir})"
  else
    log_info "[dry-run] backup simulated — restore.sh was generated for inspection at ${run_dir}/restore.sh, but its target files were not created (dry-run) and backup.complete was not written"
  fi
}

# phase_restore --profile <name> --run <run-dir> [--yes] — design doc §6.7:
# runs the run's generated restore.sh, after taking a pre-restore safety
# snapshot of B's CURRENT state ("a backup of the backup" — even a restore
# has to stay reversible).
phase_restore() {
  local profile="" run_dir="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      # MINOR found by review (Viktor): the DoD lists --dry-run for every
      # phase that writes, including restore — this was missing entirely.
      --dry-run)
        # shellcheck disable=SC2034 # read via lib/core.sh's is_dry_run(), a different sourced file in the same bash process, not in this one -- a directive can't precede a one-line case branch (`pattern) cmd ;;`), only a plain command, hence the split
        SITEGRAFT_DRY_RUN=1
        shift
        ;;
      *) log_error "unknown flag for restore: $1"; return 1 ;;
    esac
  done
  if [ -z "$profile" ] || [ -z "$run_dir" ]; then
    log_error "restore requires --profile <name> --run <run-dir>"
    return 1
  fi
  profile_load "$profile" || return 1

  # issue #94 / ADR 0010: same guard as phase_backup's own (see that
  # function's comment for the full reasoning) -- restore's pre-restore
  # safety snapshot below reuses backup_wp_content unmodified, which now
  # requires this exact check to have already run. Missing here was a real
  # regression, not just an omission: reproduced live against an
  # openrsync-shaped stand-in, an ssh-remote restore got past the
  # confirmation prompt, past backup_db_export (which had already written a
  # real b-db.sql.gz), and only then failed inside backup_wp_content with
  # "unknown option '--no-old-args'" -- a partial pre-restore snapshot on
  # disk and a generic error pointing at the transfer tool's own output,
  # instead of refusing loudly before touching anything. Checked here,
  # before the confirmation prompt too, for the same reason: no point
  # asking an operator to confirm a restore this phase cannot actually run.
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    is_dry_run || sitegraft_require_rsync_arg_escaping || return 1
  fi

  [ -x "${run_dir}/restore.sh" ] || { log_error "no restore.sh found for run: ${run_dir}"; return 1; }

  if is_dry_run; then
    # NIT-F (review fix-pack): this message used to claim the pre-restore
    # snapshot is "still taken for real" under --dry-run — it isn't. The
    # snapshot below reuses backup_db_export/backup_wp_content, the exact
    # same functions phase_backup itself calls, and both are run_or_echo-
    # wrapped internally like everything else in this codebase's dry-run
    # story — under dry-run they print their commands instead of running
    # them, same as the restore.sh execution that follows. The BEHAVIOR is
    # correct (a real --dry-run genuinely touches nothing on B, snapshot
    # included — verified, this is the safe direction) — only this message
    # was wrong about what it does.
    log_info "--dry-run: restore will print the commands it would run for both the pre-restore snapshot and restore.sh's execution — neither actually runs, and nothing on B is touched"
  fi

  # issue #46 fix-pack: this `read -r -p` had no `[ -t 0 ]` guard, unlike
  # graft_check_stack_mismatch's identical confirmation prompt (this file's
  # sibling in lib/graft.sh, ~line 406), which already gates the same shape
  # of prompt on stdin being a real TTY. Without the guard, a scripted
  # `sitegraft restore` run without --yes on a non-interactive stdin that
  # never reaches EOF (a pipe, a parent shell, a supervised process) blocks
  # here forever instead of declining — the exact same failure mode #46
  # documented for a test stub, except this one is production code, reached
  # by the tool's own last-resort command. Mirrors graft.sh's gate: refuse
  # loudly and immediately when there is no TTY to prompt, rather than
  # blocking on a `read` that has nothing to read.
  if [ "$yes" -ne 1 ]; then
    if [ ! -t 0 ]; then
      log_error "restore needs --yes on a non-interactive stdin"
      return 1
    elif command -v gum >/dev/null 2>&1; then
      gum confirm "Restore B from ${run_dir}? This overwrites B's current database and wp-content." || return 1
    else
      local ans
      read -r -p "Restore B from ${run_dir}? This overwrites B's current database and wp-content. [y/N] " ans
      [ "${ans:-n}" = "y" ] || return 1
    fi
  fi

  # design doc §6.7 ("even a restore has to stay reversible") / Marcel's
  # nightshift mandate: snapshot B's CURRENT state, both database AND
  # wp-content, before running restore.sh. Reuses backup_db_export/
  # backup_wp_content unmodified — the same two functions phase_backup
  # itself calls, just pointed at a different destination directory —
  # rather than duplicating the ssh/rsync command construction a second
  # time (see those functions' own comments for why: this is exactly the
  # class of bug review finding A2 was about, a hand-rebuilt near-duplicate
  # that can drift out of sync with the already-correct implementation).
  #
  # DEVIATION from the plan's literal Task 3.2 pseudocode: that version only
  # snapshots B's database before restoring, not wp-content — but
  # restore.sh's own wp-content step runs `rsync --delete`, which is exactly
  # as destructive to files as the db import is to data. A safety snapshot
  # covering only half of what's about to be overwritten isn't a real safety
  # net for the other half. Taken per the nightshift mandate: prefer the
  # safer option even at extra cost (a slower pre-restore step).
  #
  # Nested under "<pre_restore_dir>/backup/" (matching phase_backup's own
  # layout) SPECIFICALLY so backup_generate_restore_script can be reused
  # unmodified below to make this snapshot itself turnkey-reversible — a
  # MINOR review recommendation (Viktor) taken: design §6.7 says "even a
  # restore has to stay reversible", and a data-only snapshot with no
  # restore.sh of its own isn't actually turnkey — recovering it today would
  # mean hand-reconstructing the right ssh/rsync/wp-cli commands under
  # pressure, exactly the situation a generated restore.sh exists to avoid.
  local pre_restore_dir
  pre_restore_dir="${run_dir}/pre-restore-$(date +%Y%m%dT%H%M%S)"
  log_info "snapshotting B's current state before restoring (safety net)..."
  # MAJOR bug found by review (Viktor), same root cause and same fix as
  # phase_backup's own subshell above — see that comment for the full
  # reproduction. `set -e` here too, for the same "fail fast on a real
  # failure instead of relying on a later check" reasoning.
  (
    set -e
    umask 077
    mkdir -p "${pre_restore_dir}/backup"
    chmod 700 "${pre_restore_dir}" "${pre_restore_dir}/backup"
    # `|| exit 1` for the same reason as phase_backup's own calls — see the
    # comment there: errexit does not fire inside a subshell that is the left
    # operand of `||`, explicit `set -e` or not.
    backup_db_export "${pre_restore_dir}/backup" || exit 1
    backup_wp_content "${pre_restore_dir}/backup/b-wp-content" || exit 1
    # The snapshot gets its own manifest for the same reason it gets its own
    # restore.sh: "even a restore has to stay reversible" means reversible to
    # the SAME standard. Without this, rolling back a restore on a
    # wrapped-local B would (correctly) refuse to remove anything, and the
    # safety net would be weaker than the thing it is a net for.
    # `|| exit 1` for the same reason as phase_backup's own call — see the
    # comment there: `set -e` does not fire inside a subshell that is the left
    # operand of `||`.
    backup_write_wp_content_manifest "${pre_restore_dir}/backup/b-wp-content" "${pre_restore_dir}/backup/b-wp-content.manifest" || exit 1
    if [ -f "${pre_restore_dir}/backup/b-db.sql.gz" ]; then
      chmod 600 "${pre_restore_dir}/backup/b-db.sql.gz"
    fi
  ) || { log_error "pre-restore safety snapshot failed while exporting/archiving B — see the transfer tool's own output above for the reason (db export, wp-content pull, or wp-content manifest). Refusing to restore without a safety net: B was not touched."; return 1; }
  backup_generate_restore_script "$pre_restore_dir" || {
    log_error "could not generate a restore.sh for the pre-restore safety snapshot at ${pre_restore_dir} — refusing to run the restore without a usable way back. Nothing on B was touched."
    return 1
  }

  # --dry-run used to mean "print the path of restore.sh and stop", which told
  # the operator nothing about what a restore would actually do. The one thing
  # worth knowing before restoring a wrapped-local B is which files it is
  # about to REMOVE from wp-content (issue #14), and only restore.sh can work
  # that out — it holds the backup's manifest and can list the live target. So
  # a dry run now executes restore.sh in its own --dry-run mode: it reads B,
  # reports what it would restore and remove, and writes nothing.
  #
  # Only if that script advertises the capability. A restore.sh generated by
  # an older sitegraft ignores unknown arguments and would run a REAL restore
  # if handed --dry-run — the exact "a skipped step is visible" failure this
  # codebase keeps having to relearn, except pointed at the most destructive
  # command it owns. Without the marker, the old print-only behavior stands,
  # and says why.
  if is_dry_run; then
    if grep -q 'restore.sh-capability: dry-run' "${run_dir}/restore.sh" 2>/dev/null; then
      log_info "--dry-run: running ${run_dir}/restore.sh --dry-run — it reads B to report exactly what it would restore and remove, and writes nothing"
      if ! "${run_dir}/restore.sh" --dry-run; then
        log_error "restore.sh --dry-run reported a problem — this restore would not succeed as it stands. Nothing on B was touched."
        return 1
      fi
      log_info "--dry-run: restore preview complete — nothing on B was touched, and the pre-restore safety snapshot was simulated only (not written)"
      return 0
    fi
    log_warn "this run's restore.sh was generated before restore.sh grew its own --dry-run mode: running it would perform a REAL restore, so it is only printed below. Re-run 'sitegraft backup' for this profile to get a restore.sh that can preview itself."
    run_or_echo "${run_dir}/restore.sh"
    return 0
  fi

  log_info "running ${run_dir}/restore.sh ..."
  # Bug found via TDD (not present in the plan's original pseudocode): a
  # bare `run_or_echo "${run_dir}/restore.sh"` on its own line, with no exit
  # status check, does NOT stop phase_restore or make it report failure when
  # restore.sh itself exits non-zero — this function isn't invoked under
  # `set -e` from every caller (bats' function-call context doesn't have it;
  # neither does an interactive shell sourcing lib/backup.sh directly), so
  # the very next statement (the "restore complete" log line) still runs and
  # phase_restore still returns 0. That's actively misleading: a failed or
  # partially-applied restore would be reported as a success. Caught live by
  # a test that makes the stand-in restore.sh exit 1 after printing output.
  if ! run_or_echo "${run_dir}/restore.sh"; then
    log_error "restore.sh failed — B may be left in a partially-restored state. Pre-restore safety snapshot is at ${pre_restore_dir} — run ${pre_restore_dir}/restore.sh to roll back to B's state right before this restore attempt"
    return 1
  fi
  log_info "restore complete. Pre-restore safety snapshot kept at ${pre_restore_dir} (its own restore.sh: ${pre_restore_dir}/restore.sh)"
}
