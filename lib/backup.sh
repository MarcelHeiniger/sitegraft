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
    printf 'ssh %s "%s --path=%s"' "$host" "$wp_cmd" "$path"
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
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo bash -c "ssh '${SITE_B_SSH_HOST}' \"${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db export - --add-drop-table\" | gzip > '${dest_dir}/b-db.sql.gz'"
  else
    run_or_echo bash -c "${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db export - --add-drop-table | gzip > '${dest_dir}/b-db.sql.gz'"
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
    run_or_echo rsync -avz "${SITE_B_SSH_HOST}:${SITE_B_WP_PATH}/wp-content/" "${dest_dir}/"
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
      run_or_echo bash -c "${prefix} tar czf - -C '${SITE_B_WP_PATH}' wp-content | tar xzf - -C '${dest_dir}' --strip-components=1"
    else
      run_or_echo rsync -avz "${SITE_B_WP_PATH}/wp-content/" "${dest_dir}/"
    fi
  fi
}

# backup_write_wp_content_manifest <src_dir> <manifest_file> — records exactly
# what this backup's wp-content archive contains, one relative path per entry,
# NUL-delimited (issue #14).
#
# This is what makes an exact-state restore possible on a wrapped-local target
# without ever wiping wp-content. The obstacle backup_generate_restore_script
# ran into is real and unchanged: a container sync (DDEV's Mutagen) can mount a
# subdirectory of wp-content, and removing that directory fails with "Device or
# resource busy" — so the restore never removes the directory. With this
# manifest it does not have to: it can list what B's wp-content holds now,
# subtract what the backup held, and remove precisely that difference. Only
# known additions are deleted, never a wipe-and-rebuild.
#
# Generated from the PULLED COPY on the orchestrator, not by asking B a second
# time: the copy is what restore.sh will actually put back, so it is the only
# listing that can be authoritative about "what this backup contains". Asking B
# again would also open a window in which a file lands between the archive and
# the listing and is then treated as original.
#
# NUL-delimited, because a WordPress uploads directory is user-supplied
# filenames: spaces, quotes, glob characters and (rarely, but legally) newlines
# all occur. A newline-delimited manifest would silently split one such name
# into two entries — and on the restore side, two entries that match nothing
# are two extra deletions. The generated restore.sh re-validates every entry it
# reads before acting on it.
#
# An EMPTY manifest is refused rather than written: it says "the backup
# contained nothing", which on the restore side reads as "every file in
# wp-content is an addition — delete all of them". A real wp-content is never
# empty, and backup_verify_wp_content already refuses an empty archive for the
# same reason; this is the same check applied to the artifact derived from it.
backup_write_wp_content_manifest() {
  local src_dir="$1" manifest_file="$2"
  if is_dry_run; then
    log_info "[dry-run] would record a wp-content manifest at ${manifest_file}"
    return 0
  fi
  if [ ! -d "$src_dir" ]; then
    log_error "cannot record a wp-content manifest: ${src_dir} does not exist"
    return 1
  fi
  if ! ( cd "$src_dir" && find . -mindepth 1 -print0 ) > "$manifest_file"; then
    log_error "could not record a wp-content manifest at ${manifest_file}"
    rm -f "$manifest_file"
    return 1
  fi
  if [ ! -s "$manifest_file" ]; then
    log_error "wp-content manifest at ${manifest_file} came out empty — refusing to keep a manifest that would tell restore.sh to delete every file in B's wp-content"
    rm -f "$manifest_file"
    return 1
  fi
  chmod 600 "$manifest_file" 2>/dev/null || true
  log_info "recorded wp-content manifest: ${manifest_file}"
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
backup_generate_restore_script() {
  local run_dir="$1"
  local wp_cmd_b restore_db_cmd restore_wp_content_cmd
  # issue #14: which file semantics this script provides, and how it provides
  # them. Baked in, and printed by the script itself when it runs — an
  # operator reading "restore" has to be told what "restore" means here at the
  # moment they run it, not only in the `backup` log they may never have seen.
  local restore_semantics prune_mode="rsync-delete" prune_helpers
  local b_wp_content_root="${SITE_B_WP_PATH:-}/wp-content"
  # Defined for every branch so the generated script has one uniform shape;
  # only the manifest branch ever calls them.
  prune_helpers="_sg_list_live() { echo 'internal error: this restore.sh does not use a wp-content manifest' >&2; return 1; }
_sg_delete_from_stdin() { echo 'internal error: this restore.sh does not use a wp-content manifest' >&2; return 1; }"

  # Decorative only (see backup_wp_cmd_literal's own comment) — if it can't
  # resolve for any reason, the header comment just says so; it never blocks
  # generating the actual restore commands below.
  wp_cmd_b="$(backup_wp_cmd_literal b 2>/dev/null || echo '(unresolved)')"

  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    restore_wp_content_cmd="ssh '${SITE_B_SSH_HOST}' \"mkdir -p '${SITE_B_WP_PATH}/wp-content'\" && rsync -avz --delete '${run_dir}/backup/b-wp-content/' '${SITE_B_SSH_HOST}:${SITE_B_WP_PATH}/wp-content/'"
    restore_db_cmd="gunzip -c '${run_dir}/backup/b-db.sql.gz' | ssh '${SITE_B_SSH_HOST}' \"${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db import -\""
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
      restore_semantics="exact-state, via this backup's own wp-content manifest — the backup is extracted in place, then every path wp-content holds that the manifest does not list is reported and removed (wp-content itself is never removed: on a container-synced target that can fail with 'Device or resource busy')"
      restore_wp_content_cmd="${prefix} mkdir -p '${SITE_B_WP_PATH}/wp-content' && tar czf - -C '${run_dir}/backup/b-wp-content' . | ${prefix} tar xzf - -C '${SITE_B_WP_PATH}/wp-content'"
      # The two wrapped commands the prune needs, isolated into their own
      # tiny functions so the rest of the generated logic is wrapper-
      # agnostic. Paths are NEVER passed as arguments here: the list of
      # things to remove reaches `rm` through xargs on stdin, NUL-delimited,
      # so a filename containing a space, a quote or a glob character can
      # neither be split nor re-expanded by any shell the wrapper puts in
      # between (several do — see _backup_local_exec_prefix's own comment on
      # `--raw`).
      prune_helpers="_sg_list_live() { ${prefix} find '${SITE_B_WP_PATH}/wp-content' -mindepth 1 -print0; }
_sg_delete_from_stdin() { ${prefix} xargs -0 rm -rf --; }"
      log_info "B is a wrapped-local site (SITE_B_WP_CMD implies a wrapper, e.g. DDEV) — the generated restore.sh restores wp-content to exactly what this backup contains: it extracts the backup in place and then removes the paths the backup's manifest does not list. It never removes wp-content itself (a container sync can make that fail with 'Device or resource busy'), and it refuses to remove anything at all if that manifest is missing, empty or unsafe rather than silently downgrading to overwrite-only."
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
      restore_db_cmd="gunzip -c '${run_dir}/backup/b-db.sql.gz' | ${prefix} wp --path='${SITE_B_WP_PATH}' db import -"
    else
      restore_wp_content_cmd="rsync -avz --delete '${run_dir}/backup/b-wp-content/' '${SITE_B_WP_PATH}/wp-content/'"
      restore_db_cmd="gunzip -c '${run_dir}/backup/b-db.sql.gz' | ${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db import -"
      restore_semantics="exact-state, via rsync --delete — wp-content is mirrored back to exactly what this backup contains, and any file added to it since is removed"
    fi
  fi

  # The script is written in three passes, on purpose. Pass 1 and 3 are
  # EXPANDING heredocs (they bake in resolved paths and commands); pass 2 is a
  # QUOTED heredoc, so the generic logic — which is ordinary bash with its own
  # runtime variables — is written literally, without a backslash in front of
  # every `$`. That escaping is exactly where a generated script acquires
  # bugs no test of the generator can see.
  cat > "${run_dir}/restore.sh" <<EOF
#!/usr/bin/env bash
# restore.sh-capability: dry-run
# Generated by 'sitegraft backup' for run: ${run_dir}
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

DB_DUMP="${run_dir}/backup/b-db.sql.gz"
WP_CONTENT_DIR="${run_dir}/backup/b-wp-content"
WP_CONTENT_MANIFEST="${run_dir}/backup/b-wp-content.manifest"
B_WP_CONTENT_ROOT="${b_wp_content_root}"
PRUNE_MODE="${prune_mode}"
RESTORE_SEMANTICS="${restore_semantics}"

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

_sg_die() { echo "$1" >&2; exit 1; }

SG_NL='
'
SG_PRUNE_COUNT=0

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
_sg_check_rel() {
  case "$1" in
    ./?*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *../*|*/..) return 1 ;;
  esac
  case "$1" in
    *"$SG_NL"*) return 1 ;;
  esac
  return 0
}

# _sg_scan_prune — computes the set of paths B's wp-content holds that this
# backup does not: read the manifest, list B, subtract. Sets SG_PRUNE_COUNT
# and writes $SG_TMP/to-remove.txt (relative, sorted, for reporting) and
# $SG_TMP/to-remove.nul (absolute, NUL-delimited, for xargs).
#
# Re-runnable on purpose: it is called a second time after the removal, to
# check that the removal actually happened.
_sg_scan_prune() {
  local rel abs
  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    _sg_check_rel "$rel" || _sg_die "refusing to remove anything from B: this backup's wp-content manifest holds an entry that is not a safe relative path under wp-content ([${rel}]) — the manifest is corrupt or was tampered with"
    printf '%s\n' "$rel"
  done < "$WP_CONTENT_MANIFEST" > "$SG_TMP/manifest.txt"

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

  LC_ALL=C sort "$SG_TMP/manifest.txt" > "$SG_TMP/manifest.sorted"
  LC_ALL=C sort "$SG_TMP/live.txt" > "$SG_TMP/live.sorted"
  LC_ALL=C comm -13 "$SG_TMP/manifest.sorted" "$SG_TMP/live.sorted" > "$SG_TMP/to-remove.txt"

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    printf '%s\0' "${B_WP_CONTENT_ROOT}/${rel#./}"
  done < "$SG_TMP/to-remove.txt" > "$SG_TMP/to-remove.nul"

  SG_PRUNE_COUNT=$(wc -l < "$SG_TMP/to-remove.txt" | tr -d ' ')
}

_sg_prune_preflight() {
  [ "$PRUNE_MODE" = "manifest" ] || return 0
  [ -e "$WP_CONTENT_MANIFEST" ] || _sg_die "refusing to restore: this backup has no wp-content manifest (${WP_CONTENT_MANIFEST}). On this target wp-content cannot be safely wiped and rebuilt, so that manifest is the only way to know which files were added after the backup — without it, restoring would silently leave every one of them in place. Refusing rather than quietly downgrading to overwrite-only. Take a fresh backup, or restore from a run that has a manifest."
  [ -f "$WP_CONTENT_MANIFEST" ] || _sg_die "refusing to restore: ${WP_CONTENT_MANIFEST} is not a regular file"
  [ -r "$WP_CONTENT_MANIFEST" ] || _sg_die "refusing to restore: the wp-content manifest ${WP_CONTENT_MANIFEST} is not readable"
  [ -s "$WP_CONTENT_MANIFEST" ] || _sg_die "refusing to restore: the wp-content manifest ${WP_CONTENT_MANIFEST} is empty. An empty manifest would mean every file in B's wp-content is an addition — i.e. delete all of them. The backup is incomplete."
  SG_TMP=$(mktemp -d) || _sg_die "refusing to restore: could not create a temporary directory"
  _sg_scan_prune
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
  done < "$SG_TMP/to-remove.txt"
}

_sg_apply_prune() {
  [ "$PRUNE_MODE" = "manifest" ] || return 0
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
backup_compute_protected_checksums() {
  local alias_lc="$1" manifest="$2"
  local prefix
  prefix=$(inventory_table_prefix "$alias_lc") || return 1
  local checksums='{}' mod
  for mod in $(echo "$manifest" | jq -r '.protect | keys[]'); do
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
        local one_content one_sum
        one_content=$(wp_remote "$alias_lc" db export - --tables="$tbl" 2>/dev/null || echo "")
        one_sum=$(backup_checksum "$one_content")
        checksums=$(echo "$checksums" | jq --arg m "_unclaimed:${tbl}" --arg s "sha256:${one_sum}" '.[$m] = $s')
      done 3<<< "$(echo "$manifest" | jq -r --arg m "$mod" '.protect[$m].tables // [] | .[]')"
      continue
    fi

    local prefixed_tables_csv tables_content sum
    prefixed_tables_csv=$(backup_prefix_tables_csv "$prefix" "$tables_csv")
    tables_content=$(wp_remote "$alias_lc" db export - --tables="$prefixed_tables_csv" 2>/dev/null || echo "")
    sum=$(backup_checksum "$tables_content")
    checksums=$(echo "$checksums" | jq --arg m "$mod" --arg s "sha256:${sum}" '.[$m] = $s')
  done
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
    backup_db_export "${run_dir}/backup"
    backup_wp_content "${run_dir}/backup/b-wp-content"
    # issue #14: recorded here, right after the archive it describes, so the
    # two can never be out of step. The generated restore.sh refuses to remove
    # anything without it.
    #
    # `|| exit 1`, not left to the `set -e` above. Found while mutation-testing
    # this change, and it is not what the surrounding code assumes: bash
    # suppresses `set -e` for the WHOLE of a compound command that is the left
    # operand of `||` — which this subshell is (`) || return 1`). A failure
    # here would therefore NOT have stopped the subshell; execution would have
    # carried on and the backup would have gone on to write backup.complete
    # with no manifest, reporting a success it had not earned. The two calls
    # above are saved from the same trap only by their own downstream
    # verification (backup_verify_db_export / backup_verify_wp_content); this
    # one says so explicitly instead of relying on that.
    backup_write_wp_content_manifest "${run_dir}/backup/b-wp-content" "${run_dir}/backup/b-wp-content.manifest" || exit 1
    if [ -f "${run_dir}/backup/b-db.sql.gz" ]; then
      chmod 600 "${run_dir}/backup/b-db.sql.gz"
    fi
  ) || return 1

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
    log_info "backup artifacts verified: valid gzip, core tables present, wp-content non-empty, wp-content manifest recorded"

    # design doc §6.3: checksums of the protected tables/options exports,
    # using the exact same normalization backup_checksum defines above, and
    # the exact same table-suffix-to-live-prefix resolution phase_verify
    # (Step 5) will later reuse via backup_compute_protected_checksums —
    # see that function's own comment for why this must never be a second,
    # independent implementation.
    local checksums
    checksums=$(backup_compute_protected_checksums b "$manifest") || { log_error "could not compute protected-data checksums — aborting before declaring the backup good"; return 1; }
    manifest=$(echo "$manifest" | jq --argjson c "$checksums" '.checksums_protected_pre_graft = $c')
    echo "$manifest" > "${run_dir}/manifest.json"
    chmod 600 "${run_dir}/manifest.json" 2>/dev/null || true
  fi

  backup_generate_restore_script "$run_dir"

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

  if [ "$yes" -ne 1 ]; then
    if command -v gum >/dev/null 2>&1; then
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
    backup_db_export "${pre_restore_dir}/backup"
    backup_wp_content "${pre_restore_dir}/backup/b-wp-content"
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
  ) || return 1
  backup_generate_restore_script "$pre_restore_dir"

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
