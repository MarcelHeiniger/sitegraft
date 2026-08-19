#!/usr/bin/env bash
# lib/graft.sh — phase: graft. Rendering-stack sync/precondition, media sync,
# WXR export/import, mu-plugin mapping, ID/domain remaps, options migration,
# optional clean/idempotence pruning. See design doc §6.4, §9, §12.
#
# Requires lib/backup.sh to already be sourced (bin/sitegraft's "graft" case
# does this) — graft.sh reuses _backup_local_exec_prefix (lib/backup.sh,
# Task 3.1) for every local (non-ssh) file transfer that touches a
# container-wrapped site (e.g. DDEV), rather than re-deriving it. That
# function's own comment predicted this exact need: "Step 4's media sync
# will face this identical problem — reuse _backup_local_exec_prefix there
# rather than rediscovering this the hard way a second time." The same
# problem turned out to apply well beyond media: stack-component sync, WXR
# export/import staging, the mapping mu-plugin, and id-map.log retrieval all
# hit the identical "SITE_*_WP_PATH is a container-internal path, invisible
# to the orchestrator's own filesystem" issue backup_wp_content solved once
# already — see the local-transfer helpers immediately below.

# --- Local-transfer helpers (wrapped-local / bare-local / ssh-remote) ------
#
# Every real (non-pure) transfer function below routes through exactly one
# of: an ssh+rsync branch (handled directly by the caller, unchanged from
# the plan's literal two-hop design), or one of the helpers here for the
# non-ssh case, which itself splits into wrapped-local (DDEV-style — needs
# to stream through the wrapper, since the container filesystem isn't the
# orchestrator's) and bare-local (a real path on the orchestrator's own
# filesystem — plain rsync/cp suffices, same as backup_wp_content's own
# "else" branch).

graft_local_prefix() { _backup_local_exec_prefix "$1"; }

# graft_pull_dir <alias> <src_dir_on_alias> <host_dest_dir> — pull a whole
# directory FROM <alias> (A or B) TO the orchestrator. Mirrors
# backup_wp_content's tar-through-the-wrapper technique for a wrapped-local
# site; a source directory that doesn't exist yet (e.g. A has never had any
# media uploaded) is treated as "nothing to pull", not an error.
graft_pull_dir() {
  local alias_lc="$1" src_dir="$2" host_dest_dir="$3"
  mkdir -p "$host_dest_dir"
  local prefix; prefix=$(graft_local_prefix "$alias_lc")
  if [ -n "$prefix" ]; then
    if ! is_dry_run && ! $prefix test -d "$src_dir" >/dev/null 2>&1; then
      log_info "source directory does not exist on ${alias_lc} yet (nothing to pull): ${src_dir}"
      return 0
    fi
    run_or_echo bash -c "${prefix} tar -c -z -f - -C '${src_dir}' . | tar -x -z -f - -C '${host_dest_dir}'"
  else
    if ! is_dry_run && [ ! -d "$src_dir" ]; then
      log_info "source directory does not exist on ${alias_lc} yet (nothing to pull): ${src_dir}"
      return 0
    fi
    run_or_echo rsync -avz "${src_dir%/}/" "${host_dest_dir%/}/"
  fi
}

# graft_push_dir <alias> <host_src_dir> <dest_dir_on_alias> [--keep-existing]
# — push a whole directory FROM the orchestrator TO <alias>. --keep-existing
# mirrors rsync --ignore-existing (design doc §6.4 step 1: never overwrite a
# file already on B) for the wrapped-local tar path, using tar's own
# -k/--keep-old-files — supported by both GNU tar and macOS/BSD tar
# (bsdtar), so this is portable without an extra dependency.
graft_push_dir() {
  local alias_lc="$1" host_src_dir="$2" dest_dir="$3" mode="${4:-}"
  local prefix; prefix=$(graft_local_prefix "$alias_lc")
  if [ -n "$prefix" ]; then
    local untar_opts="-x -z -f -"
    [ "$mode" = "--keep-existing" ] && untar_opts="-x -z -k -f -"
    run_or_echo bash -c "${prefix} mkdir -p '${dest_dir}' && tar -c -z -f - -C '${host_src_dir}' . | ${prefix} tar ${untar_opts} -C '${dest_dir}'"
  else
    run_or_echo mkdir -p "$dest_dir"
    if [ "$mode" = "--keep-existing" ]; then
      run_or_echo rsync -avz --ignore-existing "${host_src_dir%/}/" "${dest_dir%/}/"
    else
      run_or_echo rsync -avz "${host_src_dir%/}/" "${dest_dir%/}/"
    fi
  fi
}

# graft_push_file <alias> <host_file> <dest_dir_on_alias> <dest_name> — push
# a single file (the mapping mu-plugin is the only caller today).
graft_push_file() {
  local alias_lc="$1" host_file="$2" dest_dir="$3" dest_name="$4"
  local prefix; prefix=$(graft_local_prefix "$alias_lc")
  if [ -n "$prefix" ]; then
    run_or_echo bash -c "${prefix} mkdir -p '${dest_dir}' && cat '${host_file}' | ${prefix} tee '${dest_dir}/${dest_name}' >/dev/null"
  else
    run_or_echo mkdir -p "$dest_dir"
    run_or_echo rsync -avz "$host_file" "${dest_dir}/${dest_name}"
  fi
}

# graft_remove_file <alias> <path_on_alias> — remove a single file on A/B
# (the mapping mu-plugin's own removal is the only caller today).
graft_remove_file() {
  local alias_lc="$1" path="$2"
  local prefix; prefix=$(graft_local_prefix "$alias_lc")
  if [ -n "$prefix" ]; then
    run_or_echo bash -c "${prefix} rm -f '${path}'"
  else
    run_or_echo rm -f "$path"
  fi
}

# graft_remove_dir <alias> <path_on_alias> — remove a whole directory on A/B
# (used to clean up the temporary export/import staging dir inside a
# wrapped-local container after each transfer).
graft_remove_dir() {
  local alias_lc="$1" path="$2"
  local prefix; prefix=$(graft_local_prefix "$alias_lc")
  if [ -n "$prefix" ]; then
    run_or_echo bash -c "${prefix} rm -rf '${path}'"
  else
    run_or_echo rm -rf "$path"
  fi
}

# --- Task 4.1: stack sync, precondition, media, mu-plugin ------------------

# design doc §6.4 step 0a (Marcel's revision of finding B1, amended for the
# ACSS v4 plugin-folder-rename case, §3.4): rsync every manifest.stack.
# <component> marked resolution=copy from A to B, then activate it.
#
# CORRECTION (caught by Marcel, not by review or self-review): an earlier
# draft of this function hardcoded slug="etch" / slug="automatic-css" per
# component via a case statement. That's exactly the bug design doc §3.2's
# rule exists to prevent: ACSS's plugin folder changed with the v4 release, so
# a hardcoded "automatic-css" would silently do nothing (or worse, sync the
# wrong path) against any pre-4.0 install. The ONLY source of truth for a
# slug, here, is manifest.stack.<component>.slug_a — resolved once by `scan`
# (via inventory_resolve_slug, Task 1.5) and frozen into the manifest by
# `plan` (Task 2.4). This function never re-derives, guesses, or hardcodes a
# slug for any component, theme included.
#
# Never touches a component marked "skip" — those are graft_check_stack_
# precondition's problem below, not this function's.
#
# Routes both hops (A -> orchestrator staging, staging -> B) through
# graft_pull_dir/graft_push_dir for the non-ssh case, so this works
# identically whether A/B are ssh-remote, wrapped-local (DDEV), or bare-local
# — see the helpers block above. Falls back to plain rsync for the bare-local
# case, matching the exact command shape the plan's own unit tests assert.
graft_sync_stack() {
  local run_dir="$1" manifest="$2"
  local component
  for component in $(echo "$manifest" | jq -r '.stack // {} | to_entries[] | select(.value.resolution == "copy") | .key'); do
    local slug rel_dir
    slug=$(echo "$manifest" | jq -r --arg c "$component" '.stack[$c].slug_a')
    if [ "$component" = "theme" ]; then
      rel_dir="wp-content/themes/${slug}"
    else
      rel_dir="wp-content/plugins/${slug}"
    fi
    log_info "syncing stack component '${component}' (resolved slug: ${slug}) from A to B (design doc §12)..."
    local staging="${run_dir}/stack-staging/${component}"
    mkdir -p "$staging"

    if [ -n "${SITE_A_SSH_HOST:-}" ]; then
      run_or_echo rsync -avz "${SITE_A_SSH_HOST}:${SITE_A_WP_PATH}/${rel_dir}/" "${staging}/"
    elif [ -n "$(graft_local_prefix a)" ]; then
      graft_pull_dir a "${SITE_A_WP_PATH}/${rel_dir}" "$staging"
    else
      run_or_echo rsync -avz "${SITE_A_WP_PATH}/${rel_dir}/" "${staging}/"
    fi

    if [ -n "${SITE_B_SSH_HOST:-}" ]; then
      run_or_echo rsync -avz "${staging}/" "${SITE_B_SSH_HOST}:${SITE_B_WP_PATH}/${rel_dir}/"
    elif [ -n "$(graft_local_prefix b)" ]; then
      graft_push_dir b "$staging" "${SITE_B_WP_PATH}/${rel_dir}"
    else
      run_or_echo rsync -avz "${staging}/" "${SITE_B_WP_PATH}/${rel_dir}/"
    fi

    if [ "$component" = "theme" ]; then
      run_or_echo wp_remote b theme activate "$slug"
    else
      run_or_echo wp_remote b plugin activate "$slug"
    fi
  done
}

# design doc §6.4 step 0b (Marcel's revision of finding B1): a hard precondition
# on whatever graft_sync_stack did NOT just resolve — never re-litigates a
# component the manifest already recorded as resolution=copy.
graft_check_stack_precondition() {
  local scan_a="$1" scan_b="$2" manifest="$3" allow_mismatch="$4"
  local diff unresolved
  diff=$(inventory_stack_diff "$scan_a" "$scan_b")
  unresolved=$(echo "$diff" | jq -r --argjson m "$manifest" \
    '[keys[] | select(($m.stack[.].resolution // "skip") != "copy")]')
  if [ "$(echo "$unresolved" | jq 'length')" = "0" ]; then
    return 0
  fi
  if [ "$allow_mismatch" != "1" ]; then
    log_error "B's rendering stack does not match A's for: $(echo "$unresolved" | jq -r 'join(", ")') — refusing to graft. Re-run with --allow-stack-mismatch to override, or resolve it in 'sitegraft plan' first (design doc §12)."
    return 1
  fi
  log_warn "STACK MISMATCH OVERRIDDEN (--allow-stack-mismatch) for: $(echo "$unresolved" | jq -r 'join(", ")') — the grafted content may render as nothing on B until the stack is aligned by hand."
  # DEVIATION from the plan's literal Task 4.1 pseudocode, found via TDD (the
  # plan's own given test for this exact path — "allows a remaining mismatch
  # with the override flag" — fails against the literal pseudocode: no bats
  # test can answer an interactive gum/read prompt, and every OTHER
  # confirmation helper in this codebase (lib/plan.sh's _plan_confirm) is
  # documented as "genuinely not unit-testable ... covered by the DDEV
  # harness instead", never asserted to return 0 from a bare bats `run`).
  # --allow-stack-mismatch is itself already an explicit, hard-to-mistype
  # flag an operator must deliberately pass — design doc §12's "loud,
  # unmissable confirmation" is the SECOND layer of that, meant for a human
  # sitting at an interactive terminal, not a barrier a scripted/CI run
  # (already carrying its own explicit override) can never get past. Gated
  # on stdin being a real TTY, the same signal `read`'s own behavior already
  # depends on: an interactive run still gets the loud prompt exactly as
  # designed; a non-interactive run (bats, the DDEV harness, any scripted
  # invocation) proceeds on the flag alone, with the warning above already
  # on the record.
  if [ -t 0 ]; then
    if command -v gum >/dev/null 2>&1; then
      gum confirm "Proceed anyway? This is not the usual confirmation — B's theme/Etch/ACSS genuinely does not match A's." || return 1
    else
      local ans
      read -r -p "Type EXACTLY 'proceed anyway' to continue despite the stack mismatch: " ans
      [ "$ans" = "proceed anyway" ] || return 1
    fi
  else
    log_warn "no interactive terminal detected — proceeding on --allow-stack-mismatch alone (the loud confirmation above is skipped only for non-interactive/scripted runs)"
  fi
}

# Pure argv-inspection helpers (design doc §6.4 step 1) — NOT what
# graft_media_sync itself calls for the wrapped-local case (it needs the
# tar-through-the-wrapper technique above, which isn't expressible as a
# single rsync argv); these exist so the two-hop shape (ssh vs. no-ssh,
# never scp, never --ignore-existing missing on the push side) is directly
# unit-testable without a live site.
graft_media_pull_cmd() {
  local site_a_ssh_host="$1" src="$2" dst="$3"
  if [ -n "$site_a_ssh_host" ]; then
    printf 'rsync\n-avz\n%s:%s\n%s\n' "$site_a_ssh_host" "$src" "$dst"
  else
    printf 'rsync\n-avz\n%s\n%s\n' "$src" "$dst"
  fi
}

graft_media_push_cmd() {
  local site_b_ssh_host="$1" src="$2" dst="$3"
  if [ -n "$site_b_ssh_host" ]; then
    printf 'rsync\n-avz\n--ignore-existing\n%s\n%s:%s\n' "$src" "$site_b_ssh_host" "$dst"
  else
    printf 'rsync\n-avz\n--ignore-existing\n%s\n%s\n' "$src" "$dst"
  fi
}

# design doc §6.4 step 1 / review finding A4: A's uploads are pulled to the
# orchestrator's run directory first, then pushed to B — A is never assumed
# reachable from B directly, exactly like the WXR transfer in step 5.
#
# DEVIATION from the plan's literal pseudocode: that version always used a
# plain rsync for the non-ssh case, which breaks for a wrapped-local site
# (SITE_*_WP_PATH is a container-internal path — see the helpers block
# above). Routes through graft_pull_dir/graft_push_dir instead, which fall
# back to the exact same plain rsync for a genuinely bare-local site.
graft_media_sync() {
  local run_dir="$1"
  local staging="${run_dir}/media-staging"
  mkdir -p "$staging"
  log_info "pulling A's media to the orchestrator..."
  if [ -n "${SITE_A_SSH_HOST:-}" ]; then
    run_or_echo rsync -avz "${SITE_A_SSH_HOST}:${SITE_A_WP_PATH}/wp-content/uploads/" "${staging}/"
  else
    graft_pull_dir a "${SITE_A_WP_PATH}/wp-content/uploads" "$staging"
  fi
  log_info "pushing media to B (never overwriting existing files)..."
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo rsync -avz --ignore-existing "${staging}/" "${SITE_B_SSH_HOST}:${SITE_B_WP_PATH}/wp-content/uploads/"
  else
    graft_push_dir b "$staging" "${SITE_B_WP_PATH}/wp-content/uploads" --keep-existing
  fi
}

graft_deploy_mu_plugin() {
  local mu_dir="${SITE_B_WP_PATH}/wp-content/mu-plugins"
  local src="${SITEGRAFT_ROOT}/mu-plugins/sitegraft-id-mapper.php"
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo ssh -- "$SITE_B_SSH_HOST" "mkdir -p $(sq "$mu_dir")"
    run_or_echo rsync -avz "$src" "${SITE_B_SSH_HOST}:${mu_dir}/sitegraft-id-mapper.php"
  else
    graft_push_file b "$src" "$mu_dir" "sitegraft-id-mapper.php"
  fi
}

# Recommended (Marcel's nightshift mandate): callers wrap this in a trap so
# the mu-plugin is removed even when graft fails partway through — see
# phase_graft's own trap below. Leaving a temporary logging mu-plugin behind
# on a failed run would be a silent, ongoing side effect on B.
graft_remove_mu_plugin() {
  local target="${SITE_B_WP_PATH}/wp-content/mu-plugins/sitegraft-id-mapper.php"
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo ssh -- "$SITE_B_SSH_HOST" "rm -f $(sq "$target")"
  else
    graft_remove_file b "$target"
  fi
}

# --- Task 4.2: WXR export/import, integrity gate, importer provisioning ---

graft_integrity_gate() {
  local file="$1" allowed_json="$2"
  [ -s "$file" ] || { log_error "WXR file is empty: ${file}"; return 1; }
  grep -q '<wp:wxr_version>' "$file" || { log_error "no <wp:wxr_version> marker in: ${file}"; return 1; }
  local item_count; item_count=$(grep -c '<item>' "$file" || true)
  [ "$item_count" -ge 1 ] || { log_error "no <item> found in: ${file}"; return 1; }

  local found_types leaked
  found_types=$(grep -o '<wp:post_type>[^<]*</wp:post_type>' "$file" \
    | sed -E 's#</?wp:post_type>##g' | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))')
  # `$allowed | index(.)` rebinds `.` to $allowed before index runs, so it
  # always searches $allowed for $allowed and `leaked` is always [] — silently
  # defeating this integrity gate (fixed in commit 770e4c1, per the design
  # doc/plan errata — verified here by a dedicated test asserting the gate
  # actually catches a leaked post_type, not merely that it "runs"). Binding
  # the element with `as $x` so index searches for the right thing. Same trap
  # as manifest_compute_unclaimed's own fix (lib/manifest.sh).
  leaked=$(jq -n --argjson found "$found_types" --argjson allowed "$allowed_json" \
    '[$found[] as $x | select(($allowed | index($x)) | not) | $x]')
  if [ "$(echo "$leaked" | jq 'length')" != "0" ]; then
    log_error "WXR contains post_type(s) outside the manifest allowlist: $(echo "$leaked" | jq -r 'join(", ")')"
    return 1
  fi
}

# design doc §8 does not hold against the currently-shipped wordpress-importer
# (0.9.5, the version wp-cli installs from wp.org): verified live, its
# process_attachment() unconditionally requires fetch_attachments=true, and
# even then does a REAL wp_safe_remote_get() of A's own attachment URL —
# there is no "assume the file already exists locally, just create the
# post" code path at all. Passing --skip=attachment (as graft_import_wxr
# now does) makes it hard-error per attachment instead ("Fetching
# attachments is not enabled"); the alternative, fetch_attachments=true,
# means an ACTUAL live HTTP fetch of A from B for every attachment — which
# wp_safe_remote_get's own SSRF protection can reject outright depending on
# network topology (reproduced live via the DDEV harness: "A valid URL was
# not provided" against a *.ddev.site hostname) and, more fundamentally,
# directly contradicts this tool's own non-negotiable "never assume A is
# reachable from B" principle (design doc §6.4 step 1, review finding A4).
#
# Attachments are migrated OURSELVES instead, entirely independent of
# wp-cli's `import` command. graft_media_sync (Task 4.1) has already
# rsync'd/tar-streamed the real files onto B by the time this runs, at the
# exact same relative wp-content/uploads/<path> A used — so this only ever
# needs `wp media import --skip-copy` (register the already-placed local
# file in place, per wp-cli's own docs: "media files ... are imported to
# the library but not moved on disk") against a file already on B's own
# filesystem. No network fetch, no dependency on A being reachable from B —
# closer to sitegraft's own stated architecture than a WXR-based attachment
# import could ever be.
#
# Writes id-map.tsv rows in the exact same format the mapping mu-plugin
# produces (old_id<TAB>new_id<TAB>post_type, §7) by APPENDING — graft_fetch_id_map
# (below) appends B's own post/term log to the same file afterward, so by
# the time graft_remap_attachment_ids (Task 4.3) runs, id-map.tsv already
# has a complete picture regardless of which mechanism produced which row.
graft_import_attachments() {
  local run_dir="$1"
  local id_map_tsv="${run_dir}/id-map.tsv"
  local ids
  ids=$(wp_remote a post list --post_type=attachment --format=csv --fields=ID 2>/dev/null | tail -n +2)
  [ -n "$ids" ] || return 0
  local old_id
  for old_id in $ids; do
    [ -n "$old_id" ] || continue
    local rel_path title new_id
    rel_path=$(wp_remote a post meta get "$old_id" _wp_attached_file 2>/dev/null)
    if [ -z "$rel_path" ]; then
      log_warn "attachment ${old_id} on A has no _wp_attached_file meta — skipping (not a locally-stored file, e.g. an external/offloaded media library entry)"
      continue
    fi
    title=$(wp_remote a post get "$old_id" --field=post_title 2>/dev/null)
    if is_dry_run; then
      printf '[dry-run] wp_remote b media import %s/wp-content/uploads/%s --skip-copy --title=%s --porcelain\n' "$SITE_B_WP_PATH" "$rel_path" "$title"
      continue
    fi
    new_id=$(wp_remote b media import "${SITE_B_WP_PATH}/wp-content/uploads/${rel_path}" --skip-copy --title="$title" --porcelain 2>/dev/null)
    if [ -z "$new_id" ]; then
      log_warn "failed to import attachment (A id ${old_id}, file ${rel_path}) onto B — was it actually placed by graft_media_sync? skipping"
      continue
    fi
    # Same idempotent-reimport marker the mapping mu-plugin sets on every
    # other imported post (§7/§11) — attachments bypass the mu-plugin
    # entirely (see this function's own header comment), so this is set by
    # hand here instead, to keep graft_prune_previous_run's coverage
    # consistent across every migrated post_type, attachments included.
    wp_remote b post meta update "$new_id" _sitegraft_source_id "$old_id" >/dev/null 2>&1
    printf '%s\t%s\tattachment\n' "$old_id" "$new_id" >> "$id_map_tsv"
  done
}

# design doc §6.4 step 3/5 / review finding A4: export lands in the run directory
# on the orchestrator, pulled from A first if A is remote — never assumed
# directly visible to B.
#
# DEVIATION from the plan's literal pseudocode: the non-ssh branch there
# passed --dir="$staging" (an orchestrator path) straight to `wp export`,
# which breaks identically to graft_media_sync's original bug for a
# wrapped-local A — wp-cli actually runs INSIDE the container, so --dir must
# be a container-internal path there too, pulled out afterward via
# graft_pull_dir (same tar-through-the-wrapper technique).
graft_export_wxr() {
  local post_types_csv="$1" run_dir="$2"
  local staging="${run_dir}/export"
  mkdir -p "$staging"
  if [ -n "${SITE_A_SSH_HOST:-}" ]; then
    local remote_dir="/tmp/sitegraft-export-$$"
    run_or_echo ssh -- "$SITE_A_SSH_HOST" "mkdir -p $(sq "$remote_dir")"
    run_or_echo wp_remote a export --post_type="$post_types_csv" --dir="$remote_dir"
    run_or_echo rsync -avz "${SITE_A_SSH_HOST}:${remote_dir}/" "${staging}/"
    run_or_echo ssh -- "$SITE_A_SSH_HOST" "rm -rf $(sq "$remote_dir")"
  else
    local prefix; prefix=$(graft_local_prefix a)
    if [ -n "$prefix" ]; then
      local container_dir="/tmp/sitegraft-export-$$"
      run_or_echo $prefix mkdir -p "$container_dir"
      run_or_echo wp_remote a export --post_type="$post_types_csv" --dir="$container_dir"
      graft_pull_dir a "$container_dir" "$staging"
      graft_remove_dir a "$container_dir"
    else
      run_or_echo wp_remote a export --post_type="$post_types_csv" --dir="$staging"
    fi
  fi
}

# DEVIATION from the plan's literal pseudocode: that version passed a glob
# ("${remote_dir}/*.xml") as a single quoted argument straight to `wp_remote
# b import`. Two independent bugs make that unsafe:
#  1. wp_remote's ssh branch single-quotes every argument individually via
#     sq() before joining them into the remote command line (lib/inventory.sh)
#     — a glob inside a single-quoted string is never expanded by the remote
#     shell, so wp-cli would receive the literal string "*.xml" and fail to
#     find any file.
#  2. The non-ssh branch has the same container-path problem as
#     graft_export_wxr above for a wrapped-local B.
# Fixed by expanding the glob HERE, on the orchestrator's own staging dir
# (always a real host directory, already populated by graft_export_wxr's
# pull step), and importing each file by its exact basename — this also
# correctly handles `wp export` splitting a large site across multiple WXR
# files, which a single glob argument would have silently mishandled anyway.
graft_import_wxr() {
  local run_dir="$1"
  local staging="${run_dir}/export"
  local f base
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    local remote_dir="/tmp/sitegraft-import-$$"
    run_or_echo ssh -- "$SITE_B_SSH_HOST" "mkdir -p $(sq "$remote_dir")"
    run_or_echo rsync -avz "${staging}/" "${SITE_B_SSH_HOST}:${remote_dir}/"
    for f in "${staging}"/*.xml; do
      [ -e "$f" ] || continue
      base=$(basename "$f")
      run_or_echo wp_remote b import "${remote_dir}/${base}" --authors=skip --skip=attachment
    done
    run_or_echo ssh -- "$SITE_B_SSH_HOST" "rm -rf $(sq "$remote_dir")"
  else
    local prefix; prefix=$(graft_local_prefix b)
    if [ -n "$prefix" ]; then
      local container_dir="/tmp/sitegraft-import-$$"
      graft_push_dir b "$staging" "$container_dir"
      for f in "${staging}"/*.xml; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        run_or_echo wp_remote b import "${container_dir}/${base}" --authors=skip --skip=attachment
      done
      graft_remove_dir b "$container_dir"
    else
      for f in "${staging}"/*.xml; do
        [ -e "$f" ] || continue
        run_or_echo wp_remote b import "$f" --authors=skip --skip=attachment
      done
    fi
  fi
}

# design doc §6.4 step 6 / review finding A7: install+activate on B if absent,
# recording exactly what B had before so graft can put it back afterward.
graft_ensure_importer() {
  local run_dir="$1"
  local state_file="${run_dir}/.wordpress-importer-pre-state"
  if wp_remote b plugin is-installed wordpress-importer >/dev/null 2>&1; then
    printf 'installed\n' > "$state_file"
    if wp_remote b plugin is-active wordpress-importer >/dev/null 2>&1; then
      printf 'active\n' >> "$state_file"
    else
      printf 'inactive\n' >> "$state_file"
      run_or_echo wp_remote b plugin activate wordpress-importer
    fi
  else
    printf 'absent\n' > "$state_file"
    run_or_echo wp_remote b plugin install wordpress-importer --activate
  fi
}

graft_restore_importer_state() {
  local run_dir="$1"
  local state_file="${run_dir}/.wordpress-importer-pre-state"
  [ -f "$state_file" ] || return 0
  local pre_installed pre_active
  pre_installed=$(sed -n '1p' "$state_file")
  pre_active=$(sed -n '2p' "$state_file")
  if [ "$pre_installed" = "absent" ]; then
    run_or_echo wp_remote b plugin uninstall wordpress-importer --deactivate
  elif [ "$pre_active" = "inactive" ]; then
    run_or_echo wp_remote b plugin deactivate wordpress-importer
  fi
}

# graft_fetch_id_map <run_dir> — pull B's mapping log (design doc §6.4 step 9)
# and APPEND it to ${run_dir}/id-map.tsv, wrapper-aware (see the helpers
# block above). Deliberately APPENDS, never overwrites: graft_import_attachments
# (above) already wrote its own rows to this same file earlier in the run
# (attachments never go through the mu-plugin/WXR-import log at all, see its
# own comment) — this function must never truncate those. A missing log (no
# post/term was actually imported by the mu-plugin — should not happen once
# the integrity gate requires >=1 <item>, but fails safe rather than
# aborting the whole run on a `cat`/rsync error) is a no-op: whatever
# id-map.tsv already had (possibly just attachment rows, possibly nothing)
# is left exactly as-is.
graft_fetch_id_map() {
  local run_dir="$1"
  local src="${SITE_B_WP_PATH}/wp-content/sitegraft-id-map.log"
  local dest="${run_dir}/id-map.tsv"
  local tmp="${run_dir}/.id-map-fetch.tmp"
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo rsync -avz "${SITE_B_SSH_HOST}:${src}" "$tmp"
  else
    local prefix; prefix=$(graft_local_prefix b)
    if [ -n "$prefix" ]; then
      if ! is_dry_run && ! $prefix test -f "$src" >/dev/null 2>&1; then
        log_warn "no id-map.log found on B (no posts/terms were imported via WXR?) — id-map.tsv left as-is"
        return 0
      fi
      run_or_echo bash -c "${prefix} cat '${src}' > '${tmp}'"
    else
      if ! is_dry_run && [ ! -f "$src" ]; then
        log_warn "no id-map.log found on B (no posts/terms were imported via WXR?) — id-map.tsv left as-is"
        return 0
      fi
      run_or_echo rsync -avz "$src" "$tmp"
    fi
  fi
  if ! is_dry_run && [ -f "$tmp" ]; then
    cat "$tmp" >> "$dest"
    rm -f "$tmp"
  fi
}

# --- Task 4.3: ID-map remap (two-pass sentinel technique) ------------------

# design doc §9.1/§9.4 / review finding A6: the only table scope any
# search-replace call is allowed to use — a protected plugin's own tables are
# never in this list, so they can never be touched by a remap, even by
# accident. This is a structural invariant, not a convention to remember:
# every function below that calls `wp search-replace` takes its table scope
# as a parameter computed by THIS function (or graft_search_replace_domain's
# own identical call), never re-derived and never a live "whatever's on B"
# scan (design doc §3.6 / manifest.sh's own note on the same invariant).
graft_content_tables_csv() {
  local alias_lc="$1"
  local prefix; prefix=$(inventory_table_prefix "$alias_lc")
  printf '%sposts,%spostmeta,%soptions' "$prefix" "$prefix" "$prefix"
}

# Prints, one per line, tab-separated "pass<TAB>pattern<TAB>replacement" tuples
# implementing the two-pass sentinel technique from design doc §9.1. Pass 1: old_id
# -> unique sentinel token. Pass 2: sentinel token -> real new_id. Kept pure (no
# wp-cli calls) so the substitution logic is unit-testable on its own.
graft_build_sentinel_commands() {
  local id_map_tsv="$1"
  local old_id new_id post_type
  while IFS=$'\t' read -r old_id new_id post_type; do
    [ "$post_type" = "attachment" ] || continue
    printf '1\t"id":%s(?!\\d)\t"id":__SITEGRAFT_%s__\n' "$old_id" "$old_id"
    printf '1\twp-image-%s(?!\\d)\twp-image-__SITEGRAFT_%s__\n' "$old_id" "$old_id"
    printf '2\t__SITEGRAFT_%s__\t%s\n' "$old_id" "$new_id"
  done < "$id_map_tsv"
}

graft_remap_attachment_ids() {
  local id_map_tsv="$1" content_tables_csv="$2"
  local pass pattern replacement
  # `wp search-replace <old> <new> [<table>...]` takes table names as
  # REPEATABLE POSITIONAL arguments, not a --tables= flag — verified live
  # against a real wp-cli install (`wp search-replace --help`): the plan's
  # own pseudocode used --tables= throughout Tasks 4.3/4.4, which wp-cli
  # rejects outright ("unknown --tables parameter"). $tables is
  # deliberately left UNQUOTED below so it word-splits into separate argv
  # elements, same convention this codebase already uses for $wp_cmd/$prefix
  # (lib/inventory.sh's wp_remote, lib/backup.sh's _backup_local_exec_prefix).
  local tables="${content_tables_csv//,/ }"
  # MAJOR bug found live (reproduced via the DDEV harness, not caught by any
  # unit test — see tests/unit/test_graft_remap.bats's own dry-run-only
  # coverage, which never exercises a real child process here): `done <
  # <(...)` binds the process substitution to the loop's OWN fd0. wp_remote's
  # wrapped-local branch execs `ddev exec ... -- wp ...` for EVERY iteration
  # of the loop body, and `ddev exec` inherits/forwards the calling
  # process's stdin into the container by default — draining bytes still
  # buffered in the SAME pipe the outer `read` is consuming from. Reproduced
  # live: with two attachment sentinel substitutions queued in pass 1 (the
  # `"id":X` pattern and the `wp-image-X` pattern), only the FIRST ever
  # actually ran as a real wp-cli invocation — the second was silently
  # dropped, the loop reading EOF early — leaving `wp-image-X` never
  # rewritten while `"id":X` correctly was. Exact same root cause and exact
  # same fix already proven elsewhere in this codebase for the identical
  # symptom: lib/plan.sh's `_plan_prompt_items` ("MAJOR bug fixed here...").
  # Reading from fd 3 instead of fd 0 frees fd0 entirely for whatever the
  # loop body's own child processes do with it.
  #
  # Pass 1 fully before pass 2, per design doc §9.1 (sentinels must all land before
  # any get resolved to a real ID).
  while IFS=$'\t' read -r pass pattern replacement <&3; do
    [ "$pass" = "1" ] || continue
    run_or_echo wp_remote b search-replace "$pattern" "$replacement" $tables --regex --precise --skip-columns=guid
  done 3< <(graft_build_sentinel_commands "$id_map_tsv")
  while IFS=$'\t' read -r pass pattern replacement <&3; do
    [ "$pass" = "2" ] || continue
    run_or_echo wp_remote b search-replace "$pattern" "$replacement" $tables --precise --skip-columns=guid
  done 3< <(graft_build_sentinel_commands "$id_map_tsv")
}

# design doc §9.2 — verify.sh is where orphan post_parent gets reported; this
# function is the shared query both graft (for a debug log) and verify (for a
# hard check, Step 5) can call.
graft_check_orphan_parents() {
  wp_remote b eval '
    global $wpdb;
    $rows = $wpdb->get_col("SELECT ID FROM {$wpdb->posts} p WHERE p.post_parent <> 0
      AND NOT EXISTS (SELECT 1 FROM {$wpdb->posts} q WHERE q.ID = p.post_parent)");
    echo implode(PHP_EOL, $rows);
  '
}

# --- Task 4.4: options migration, domain remap, module hooks, pruning ------

graft_step_done() { [ -f "${1}/graft.${2}.done" ]; }
graft_mark_step() { touch "${1}/graft.${2}.done"; }

# design doc §6.4 step 8 / review finding A1: this step was missing entirely from
# the previous draft — sitegraft migrated content but never the Etch/ACSS settings.
# page_on_front/page_for_posts are written to disk (for core_wp_post_import, §9.3)
# but never blind-copied here, since A's value is A's own page ID.
graft_migrate_options() {
  local run_dir="$1" manifest="$2"
  local key
  for key in $(echo "$manifest" | jq -r '[.migrate[].option_keys[]?] | unique[]'); do
    local value
    value=$(wp_remote a option get "$key" --format=json 2>/dev/null || echo 'null')
    printf '%s' "$value" > "${run_dir}/option-${key}.value"
    case "$key" in
      page_on_front|page_for_posts) continue ;; # remapped by core_wp_post_import, §9.3
    esac
    run_or_echo wp_remote b option update "$key" "$value" --format=json
  done
}

# design doc §9.4: two mandatory passes (plain + JSON-escaped, since Etch
# stores some data as JSON blobs in certain options/postmeta), scoped with the
# same content_tables_csv as §9.1 for the same non-negotiable reason.
graft_search_replace_domain() {
  local from="$1" to="$2" content_tables_csv="$3"
  # Same positional-table-argument fix as graft_remap_attachment_ids above.
  local tables="${content_tables_csv//,/ }"
  run_or_echo wp_remote b search-replace "$from" "$to" $tables --skip-columns=guid --precise
  local from_escaped to_escaped
  from_escaped=$(printf '%s' "$from" | sed 's#/#\\/#g')
  to_escaped=$(printf '%s' "$to" | sed 's#/#\\/#g')
  run_or_echo wp_remote b search-replace "$from_escaped" "$to_escaped" $tables --skip-columns=guid --precise
}

# design doc §11 "idempotent reimport": before importing, delete any post B already
# has from a previous sitegraft run (marked with _sitegraft_source_id), for the
# post_types in this run's manifest. Distinct from the optional `clean` step, which
# removes B's pre-existing ORIGINAL content instead.
graft_prune_previous_run() {
  local post_types_csv="$1"
  [ -n "$post_types_csv" ] || return 0
  local ids
  ids=$(wp_remote b post list --post_type="$post_types_csv" --meta_key=_sitegraft_source_id --field=ID)
  [ -n "$ids" ] || return 0
  log_warn "pruning $(echo "$ids" | wc -l | tr -d ' ') post(s) left by a previous sitegraft run before re-importing"
  # Same fd0-collision class as graft_remap_attachment_ids's own fix above
  # (`echo | while read` binds the loop's fd0 to the pipe; wp_remote's
  # wrapped-local branch execs a child that inherits/drains that same fd0
  # on every iteration) — reading from fd 3 instead avoids it here too,
  # even though this specific loop wasn't the one caught live (the DDEV
  # harness only has one leftover post to prune, one iteration, nothing to
  # silently truncate) — fixed proactively rather than waiting to reproduce
  # it a second time with a multi-post fixture.
  local id
  while read -r id <&3; do
    [ -n "$id" ] && run_or_echo wp_remote b post delete "$id" --force
  done 3<<< "$ids"
}

graft_run_module_post_import() {
  local run_dir="$1" id_map_tsv="$2"
  local mod
  for mod in $SITEGRAFT_MODULES; do
    module_has_fn "$mod" post_import || continue
    log_info "running post_import hook for module: ${mod}"
    module_call "$mod" post_import "$run_dir" "$id_map_tsv" "wp_remote b"
  done
}

# _graft_exit_trap — recommended addition beyond the plan's literal Task 4.4
# wiring (Marcel's nightshift mandate — prefer the safer option even at
# extra cost): the mapping mu-plugin is removed even if graft fails partway
# through (a real wp-cli error, an interrupted run), not only on the happy
# path. Without this, an interrupted run would leave the mu-plugin active on
# B indefinitely, silently logging every future insert/update.
#
# Deliberately reads its state from a GLOBAL (SITEGRAFT_GRAFT_RUN_DIR), never
# from phase_graft's own `local run_dir` — this codebase already documents,
# at length (lib/core.sh's sitegraft_cleanup, bin/sitegraft's own trap
# placement), how a bash EXIT trap's execution context can outlive the
# function that installed it: `local` bindings are torn down the moment
# their function returns, but an EXIT trap fires at PROCESS/subshell exit,
# which can be later — a trap that closes over a `local` risks reading an
# already-unbound variable. Copying the one value the trap actually needs
# into a global right before arming the trap sidesteps that timing hazard
# entirely, verified live against bats' own `run` (which forks a subshell
# for capturing output — the trap fires within that subshell only, so this
# never leaks into or clobbers bats' own per-test EXIT trap machinery,
# unlike installing a trap at library SOURCE time, which is the documented
# bug bin/sitegraft's own header comment warns about).
#
# Chains to sitegraft_cleanup (bin/sitegraft's own EXIT trap, if this process
# came through bin/sitegraft and already installed it) instead of silently
# replacing it — `trap ... EXIT` set here would otherwise clobber it for the
# rest of the process, losing SITEGRAFT_TMP_REGISTRY cleanup. Captures the
# REAL original `$?` first, as sitegraft_cleanup's own extensively-documented
# fix requires, and returns that value regardless of what either cleanup
# operation's own exit status was.
_graft_exit_trap() {
  local rc=$?
  local rd="${SITEGRAFT_GRAFT_RUN_DIR:-}"
  if [ -n "$rd" ] && graft_step_done "$rd" mu_plugin 2>/dev/null && ! graft_step_done "$rd" mu_cleanup 2>/dev/null; then
    log_warn "graft interrupted or failed — removing the mapping mu-plugin from B before exiting (never left running unattended)"
    graft_remove_mu_plugin 2>/dev/null || true
    graft_mark_step "$rd" mu_cleanup 2>/dev/null || true
  fi
  if declare -F sitegraft_cleanup >/dev/null 2>&1; then
    sitegraft_cleanup || true
  fi
  return "$rc"
}

# phase_graft --profile <name> [--run <run-dir>] [--allow-stack-mismatch]
# [--dry-run] — design doc §6.4: performs the actual A -> B transfer.
phase_graft() {
  local profile="" run_dir="" allow_mismatch=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      --allow-stack-mismatch) allow_mismatch=1; shift ;;
      --dry-run) SITEGRAFT_DRY_RUN=1; shift ;;
      *) log_error "unknown flag for graft: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "graft requires --profile <name>"; return 1; }
  profile_load "$profile" || return 1
  [ -n "$run_dir" ] || run_dir=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1)
  [ -n "$run_dir" ] || { log_error "no scan/plan run found for profile ${profile} — run 'sitegraft scan' and 'sitegraft plan' first"; return 1; }
  [ -f "${run_dir}/backup.complete" ] || {
    log_error "no backup.complete marker for this run — refusing to graft without a backup"
    return 1
  }

  modules_discover
  local manifest; manifest=$(cat "${run_dir}/manifest.json")
  local post_types_csv; post_types_csv=$(echo "$manifest" | jq -r '[.migrate[].post_types[]?] | join(",")')
  # attachment is deliberately excluded from the WXR export's own post_type
  # filter — graft_import_attachments handles attachments itself (see its
  # own comment for why the standard WXR/wordpress-importer path doesn't
  # work at all against the currently-shipped wordpress-importer). Kept in
  # the full post_types_csv (used by prune and the integrity-gate allowlist)
  # since a future re-import should still prune any previously-migrated
  # attachment the same way as any other migrated content.
  local wxr_post_types_csv; wxr_post_types_csv=$(echo "$manifest" | jq -r '[.migrate[].post_types[]? | select(. != "attachment")] | join(",")')
  local content_tables_csv; content_tables_csv=$(graft_content_tables_csv b)

  SITEGRAFT_GRAFT_RUN_DIR="$run_dir"
  trap _graft_exit_trap EXIT

  # design doc §6.4 step 0a/0b (Marcel's revision of finding B1): sync whatever
  # plan approved for copying, THEN enforce the hard precondition on whatever
  # is left unresolved — never the other order, or the precondition would
  # refuse components graft_sync_stack was about to fix anyway.
  graft_step_done "$run_dir" stack_sync || { graft_sync_stack "$run_dir" "$manifest"; graft_mark_step "$run_dir" stack_sync; }
  graft_check_stack_precondition "${run_dir}/scan-a.json" "${run_dir}/scan-b.json" "$manifest" "$allow_mismatch" || return 1

  graft_step_done "$run_dir" media_sync    || { graft_media_sync "$run_dir"; graft_mark_step "$run_dir" media_sync; }
  graft_step_done "$run_dir" mu_plugin     || { graft_deploy_mu_plugin; graft_mark_step "$run_dir" mu_plugin; }
  # prune MUST run before import_attachments (bug found live): prune deletes
  # every post carrying _sitegraft_source_id as leftover from a PREVIOUS
  # run — import_attachments sets that exact meta on whatever it creates,
  # in THIS run. Reversed, prune would delete the attachment(s)
  # import_attachments just created a moment earlier, mistaking this run's
  # own fresh content for a prior run's leftovers (reproduced live: the
  # attachment vanished, and WordPress's next auto-increment ID for the
  # "Home" page happened to land exactly on the deleted attachment's old ID
  # — reading as "the page overwrote the attachment" until traced back to
  # prune actually deleting it first).
  graft_step_done "$run_dir" prune         || { graft_prune_previous_run "$post_types_csv"; graft_mark_step "$run_dir" prune; }
  graft_step_done "$run_dir" import_attachments || { graft_import_attachments "$run_dir"; graft_mark_step "$run_dir" import_attachments; }
  graft_step_done "$run_dir" importer_setup || { graft_ensure_importer "$run_dir"; graft_mark_step "$run_dir" importer_setup; }
  graft_step_done "$run_dir" export        || {
    graft_export_wxr "$wxr_post_types_csv" "$run_dir"
    if ! is_dry_run; then
      local f found_any=0
      for f in "${run_dir}/export"/*.xml; do
        [ -e "$f" ] || continue
        found_any=1
        graft_integrity_gate "$f" "$(echo "$manifest" | jq -c '[.migrate[].post_types[]?]')" || return 1
      done
      [ "$found_any" -eq 1 ] || { log_error "WXR export produced no .xml file(s) in ${run_dir}/export"; return 1; }
    fi
    graft_mark_step "$run_dir" export
  }
  graft_step_done "$run_dir" import        || { graft_import_wxr "$run_dir"; graft_mark_step "$run_dir" import; }
  graft_step_done "$run_dir" fetch_id_map  || { graft_fetch_id_map "$run_dir"; graft_mark_step "$run_dir" fetch_id_map; }
  graft_step_done "$run_dir" mu_cleanup    || { graft_remove_mu_plugin; graft_mark_step "$run_dir" mu_cleanup; }
  graft_step_done "$run_dir" importer_cleanup || { graft_restore_importer_state "$run_dir"; graft_mark_step "$run_dir" importer_cleanup; }
  graft_step_done "$run_dir" remap_ids     || { graft_remap_attachment_ids "${run_dir}/id-map.tsv" "$content_tables_csv"; graft_mark_step "$run_dir" remap_ids; }
  graft_step_done "$run_dir" remap_domain  || {
    graft_search_replace_domain "$(echo "$manifest" | jq -r '.options.search_replace.from')" "$(echo "$manifest" | jq -r '.options.search_replace.to')" "$content_tables_csv"
    graft_mark_step "$run_dir" remap_domain
  }
  graft_step_done "$run_dir" migrate_options || { graft_migrate_options "$run_dir" "$manifest"; graft_mark_step "$run_dir" migrate_options; }
  graft_step_done "$run_dir" module_hooks  || { graft_run_module_post_import "$run_dir" "${run_dir}/id-map.tsv"; graft_mark_step "$run_dir" module_hooks; }

  if [ "$(echo "$manifest" | jq -r '.clean.enabled')" = "true" ]; then
    graft_step_done "$run_dir" clean || {
      local clean_types; clean_types=$(echo "$manifest" | jq -r '.clean.post_types | join(",")')
      log_info "clean step: removing B's pre-existing content for: ${clean_types}"
      graft_mark_step "$run_dir" clean
    }
  fi

  log_info "graft complete for run: ${run_dir}"
}
