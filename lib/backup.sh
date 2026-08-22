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

  # Decorative only (see backup_wp_cmd_literal's own comment) — if it can't
  # resolve for any reason, the header comment just says so; it never blocks
  # generating the actual restore commands below.
  wp_cmd_b="$(backup_wp_cmd_literal b 2>/dev/null || echo '(unresolved)')"

  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    restore_wp_content_cmd="ssh '${SITE_B_SSH_HOST}' \"mkdir -p '${SITE_B_WP_PATH}/wp-content'\" && rsync -avz --delete '${run_dir}/backup/b-wp-content/' '${SITE_B_SSH_HOST}:${SITE_B_WP_PATH}/wp-content/'"
    restore_db_cmd="gunzip -c '${run_dir}/backup/b-db.sql.gz' | ssh '${SITE_B_SSH_HOST}' \"${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db import -\""
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
      # itself — only extracts the backup ON TOP of what's there. Documented
      # trade-off, not silently accepted: this path overwrites every file
      # the backup contains with its pre-graft version, but does NOT delete
      # a file added to wp-content since the backup was taken. Full mirror/
      # delete semantics are only guaranteed by the ssh-remote and
      # genuinely-bare-local branches below, where the target is a plain
      # file tree rsync can safely wipe and rebuild.
      restore_wp_content_cmd="${prefix} mkdir -p '${SITE_B_WP_PATH}/wp-content' && tar czf - -C '${run_dir}/backup/b-wp-content' . | ${prefix} tar xzf - -C '${SITE_B_WP_PATH}/wp-content'"
      log_warn "B is a wrapped-local site (SITE_B_WP_CMD implies a wrapper, e.g. DDEV) — the generated restore.sh will overwrite wp-content in place but will NOT delete files added to it since this backup (no portable way to safely wipe a containerized directory that may itself be a separate mount — see the code comment in backup_generate_restore_script). Full mirror/delete semantics on restore are only guaranteed for an ssh-remote or genuinely local (unwrapped) B."
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
    fi
  fi

  cat > "${run_dir}/restore.sh" <<EOF
#!/usr/bin/env bash
# Generated by 'sitegraft backup' for run: ${run_dir}
# Self-contained: every command below is a literal, baked-in ssh/rsync/wp-cli
# invocation (wp-cli literal prefix: ${wp_cmd_b}). This script never calls a
# sitegraft function and never sources a sitegraft lib file — it runs
# standalone with nothing but ssh, rsync, tar, gzip/gunzip, and wc.
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

echo "Verifying backup integrity before restoring anything..."
if [ ! -s "\$DB_DUMP" ]; then
  echo "refusing to restore: \$DB_DUMP is missing or empty (corrupted or incomplete backup)" >&2
  exit 1
fi
DB_DUMP_SIZE=\$(wc -c < "\$DB_DUMP" | tr -d ' ')
if [ "\$DB_DUMP_SIZE" -lt 200 ]; then
  echo "refusing to restore: \$DB_DUMP is suspiciously small (\${DB_DUMP_SIZE} bytes)" >&2
  exit 1
fi
if ! gzip -t "\$DB_DUMP" 2>/dev/null; then
  echo "refusing to restore: \$DB_DUMP is not a valid gzip file (corrupted backup)" >&2
  exit 1
fi
if [ ! -d "\$WP_CONTENT_DIR" ] || [ -z "\$(ls -A "\$WP_CONTENT_DIR" 2>/dev/null)" ]; then
  echo "refusing to restore: \$WP_CONTENT_DIR is missing or empty (corrupted or incomplete backup)" >&2
  exit 1
fi
echo "Backup integrity OK."

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
    log_info "backup artifacts verified: valid gzip, core tables present, wp-content non-empty"

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
      --dry-run) SITEGRAFT_DRY_RUN=1; shift ;;
      *) log_error "unknown flag for restore: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] && [ -n "$run_dir" ] || {
    log_error "restore requires --profile <name> --run <run-dir>"
    return 1
  }
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
  local pre_restore_dir="${run_dir}/pre-restore-$(date +%Y%m%dT%H%M%S)"
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
    if [ -f "${pre_restore_dir}/backup/b-db.sql.gz" ]; then
      chmod 600 "${pre_restore_dir}/backup/b-db.sql.gz"
    fi
  ) || return 1
  backup_generate_restore_script "$pre_restore_dir"

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
