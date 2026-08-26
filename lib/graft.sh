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
    local tolerate_exit=""
    if [ "$mode" = "--keep-existing" ]; then
      # `-k` does NOT mean "skip files that already exist" — it means "treat
      # an existing file as an ERROR, refuse to touch it, and exit non-zero".
      # The rsync branch below uses --ignore-existing, which skips silently;
      # the two branches were not implementing the same thing.
      #
      # It aborted the first real graft outright. A and B were both clones of
      # the same production site, so nearly every file in A's uploads already
      # existed on B: tar emitted "Cannot open: File exists" for each one,
      # ended with "Exiting with failure status due to previous errors", and
      # `set -e` killed the run right after the media step — before the WXR
      # export had even started. The DDEV harness never saw it because its
      # two fixture sites share no media at all, so nothing ever collides.
      #
      # GNU tar's `--skip-old-files` is the flag that actually means what was
      # intended: skip, no diagnostic, exit 0. It is not in BSD/macOS tar, so
      # support is probed rather than assumed — and the probe runs through
      # the same wrapper the extraction will, since what matters is the tar
      # INSIDE the container, not the orchestrator's own.
      #
      # The probe's output is captured FIRST and matched from a here-string.
      # Written as `$prefix tar --help | grep -q ...` it fell into the very
      # trap this file already documents twice: grep -q exits on the first
      # match, SIGPIPEs the still-writing tar, and `set -o pipefail` turns
      # the successful match into a failed pipeline — so the probe answered
      # "unsupported" on a tar that supports it perfectly well, and every
      # real run silently took the degraded fallback below. Observed live.
      local tar_help
      tar_help=$($prefix tar --help 2>/dev/null || true)
      if grep -q -- '--skip-old-files' <<< "$tar_help"; then
        untar_opts="-x -z --skip-old-files -f -"
      else
        # Fallback for a tar without it: keep `-k`, but stop its
        # existing-file diagnostics from failing the whole graft. The cost is
        # explicit — on this path tar's exit status no longer distinguishes
        # "skipped files that were already there" from a genuine extraction
        # failure, so it is warned about rather than done quietly.
        untar_opts="-x -z -k -f -"
        tolerate_exit=" || true"
        log_warn "the tar reachable through this site's wrapper has no --skip-old-files; falling back to -k, whose exit status cannot distinguish an already-present file from a real extraction error. Check the transferred tree by hand if this run behaves oddly."
      fi
    fi
    run_or_echo bash -c "${prefix} mkdir -p '${dest_dir}' && { tar -c -z -f - -C '${host_src_dir}' . | ${prefix} tar ${untar_opts} -C '${dest_dir}'; }${tolerate_exit}"
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
    run_or_echo bash -c "${prefix} mkdir -p '${dest_dir}' && ${prefix} tee '${dest_dir}/${dest_name}' >/dev/null < '${host_file}'"
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
    graft_copy_wp_content_dir "$rel_dir" "${run_dir}/stack-staging/${component}"

    if [ "$component" = "theme" ]; then
      graft_sync_theme_parent "$slug" "$run_dir"
      run_or_echo wp_remote b theme activate "$slug"
    else
      run_or_echo wp_remote b plugin activate "$slug"
    fi
  done
}

# graft_copy_wp_content_dir <rel_dir> <staging> — copy one wp-content
# subdirectory from A to B, through whichever transport each side needs.
# Extracted out of graft_sync_stack so the parent-theme copy below reuses
# this exact three-branch logic instead of carrying a second copy of it that
# would drift.
graft_copy_wp_content_dir() {
  local rel_dir="$1" staging="$2"
  mkdir -p "$staging"

  if [ -n "${SITE_A_SSH_HOST:-}" ]; then
    # shellcheck disable=SC2153 # not a typo: SITE_A_WP_PATH is assigned in bin/sitegraft or a sourced profile, not in this file (cross-file, same blind spot as this file's SC2034 disables)
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
}

# graft_sync_theme_parent <child_slug> <run_dir> — a child theme cannot be
# activated without its parent, and graft_sync_stack only ever copied the
# ACTIVE theme. A child theme on A therefore landed on a B holding no parent
# for it, and the `wp theme activate` right after produced a broken site.
#
# Found on the first real pair, whose A runs a child theme: it worked there
# only because B happened to already carry the exact parent at the exact same
# version. That is luck. The next target — a B on an unrelated theme — has no
# reason to carry it at all.
#
# The parent is resolved with get_template(), which returns the parent's
# DIRECTORY slug (and, for a theme that is not a child, the theme's own
# slug — hence the equality check). `wp theme get --field=parent_theme`
# deliberately not used: it returns the parent's display Name, which is not a
# path.
#
# The parent is copied but never activated — a parent theme is activated
# through its child, not on its own.
graft_sync_theme_parent() {
  local child_slug="$1" run_dir="$2"

  # The two queries below are READS, and they have to run for real even under
  # --dry-run, because every decision this function makes depends on their
  # answers. wp_remote routes everything through run_or_echo, which under
  # --dry-run returns the literal string "[dry-run] <command>" instead of the
  # value — so without this, $parent becomes "[dry-run] docker exec ...
  # get_template();" and the copy path below is built out of that text.
  # Observed on this function's very first dry run. It is the same defect
  # docs/status.md records for `verify --dry-run`, which read "[dry-run] ..."
  # as though it were B's data and hard-failed a graft that had in fact
  # succeeded.
  #
  # The flag is saved, cleared for the two reads, and restored IMMEDIATELY
  # afterwards — before any branch below can return early. verify's original
  # version of this same manoeuvre cleared the flag and never restored it;
  # keeping the restore unconditional and in one place is what stops that
  # from happening again. The directory copy further down stays under
  # run_or_echo, as it must: that one is a write, and a dry run has to
  # simulate it.
  local saved_dry_run="${SITEGRAFT_DRY_RUN:-0}"
  local parent b_themes
  SITEGRAFT_DRY_RUN=0
  parent=$(wp_remote a eval "echo wp_get_theme('${child_slug}')->get_template();" 2>/dev/null || true)
  b_themes=$(wp_remote b theme list --field=name 2>/dev/null || true)
  SITEGRAFT_DRY_RUN="$saved_dry_run"

  parent=$(printf '%s' "$parent" | tr -d '\r' | tr -d '\n')
  b_themes=$(printf '%s' "$b_themes" | tr -d '\r')

  case "$parent" in
    ''|"$child_slug") return 0 ;;
  esac

  # Matched from a here-string rather than `... | grep -qx`: grep -q exits at
  # the first match and SIGPIPEs whatever is still writing upstream, which
  # under bin/sitegraft's `set -o pipefail` turns a successful match into a
  # failed pipeline (exit 141) — the same defect that made
  # backup_verify_db_export reject every valid real-site backup.
  if grep -qx "$parent" <<< "$b_themes"; then
    log_info "parent theme '${parent}' is already present on B — not copying it"
    return 0
  fi

  log_info "active theme '${child_slug}' is a child of '${parent}', which B does not have — copying the parent from A as well (never activated on its own)"
  graft_copy_wp_content_dir "wp-content/themes/${parent}" "${run_dir}/stack-staging/theme-parent"
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

  # CDATA-tolerant on purpose, even though it's NOT what triggers against a
  # real `wp export`: verified live (a real WP 7.1 / wp-cli export, both by
  # direct output inspection and by reading wp-cli's own
  # WP_Export_WXR_Formatter.php source — the `wp:post_type` line uses the
  # plain ->tag() form, not ->contains->cdata(), unlike title/content/meta_value,
  # which DO get CDATA-wrapped) that `<wp:post_type>` is emitted as plain
  # text, not `<wp:post_type><![CDATA[...]]></wp:post_type>` — so `[^<]*`
  # matches it today without any changes. Widened to `.*` plus a CDATA-marker
  # strip anyway, purely as defense-in-depth against a wp-cli version, a
  # different export path (e.g. wp-admin's own native exporter, which does
  # CDATA-wrap this field), or a hand-edited WXR ever changing that shape —
  # cheap to add, and this is a security control, not a place to bet on one
  # observed version's behavior never changing.
  local found_types leaked
  found_types=$(grep -o '<wp:post_type>.*</wp:post_type>' "$file" \
    | sed -E 's#</?wp:post_type>##g; s#<!\[CDATA\[##g; s#\]\]>##g' \
    | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))')

  # Fail CLOSED, not open: an `<item>` count >=1 (checked above) with ZERO
  # post_type actually extracted means the regex above didn't recognize
  # this file's shape at all — exactly the silent "leaked is always []"
  # failure mode commit 770e4c1's jq fix (below) exists to prevent, just
  # one layer up (a parsing gap instead of a comparison-logic gap). Refusing
  # here means a future export-format change this regex doesn't understand
  # aborts loudly instead of the gate quietly rubber-stamping everything.
  if [ "$(echo "$found_types" | jq 'length')" = "0" ]; then
    log_error "no <wp:post_type> could be parsed out of a WXR file that has ${item_count} <item>(s): ${file} — refusing to trust an integrity gate that found nothing to check"
    return 1
  fi

  # `$allowed | index(.)` rebinds `.` to $allowed before index runs, so it
  # always searches $allowed for $allowed and `leaked` is always [] — silently
  # defeating this integrity gate (fixed in commit 770e4c1, per the design
  # doc/plan errata — verified here by a dedicated test asserting the gate
  # actually catches a leaked post_type, not merely that it "runs"). Binding
  # the element with `as $x` so index searches for the right thing. Same trap
  # as manifest_compute_unclaimed's own fix (lib/manifest.sh).
  # WordPress's own exporter unions the attachments of every exported post
  # into the WXR — export_wp() adds `post_parent IN (<exported ids>) AND
  # post_type = 'attachment'` regardless of what --post_type asked for. So a
  # WXR taken from any site whose posts have attached media always contains
  # `attachment` items, no matter how narrow the export request was.
  #
  # sitegraft migrates media deliberately OUTSIDE the WXR (graft_media_sync
  # copies the files, then re-registers and remaps each one), and
  # graft_import_wxr passes `--skip=attachment`, so not a single one of those
  # entries is ever imported. Without this exemption the gate rejects every
  # real export: the first real graft died here, after three hours of media
  # work had already completed successfully.
  #
  # Exempted BY NAME rather than by widening $allowed_json, because the
  # reason is specific and does not generalize: `attachment` is tolerated in
  # the file only because the importer is known to skip it. Any other
  # unexpected post type must still fail this gate.
  local allowed_plus_skipped
  allowed_plus_skipped=$(jq -n --argjson a "$allowed_json" '($a + ["attachment"]) | unique')
  leaked=$(jq -n --argjson found "$found_types" --argjson allowed "$allowed_plus_skipped" \
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
# needs to register the already-placed local file against a file already on
# B's own filesystem. No network fetch, no dependency on A being reachable
# from B — closer to sitegraft's own stated architecture than a WXR-based
# attachment import could ever be.
#
# Issue #11 rewrite: the version of this step that shelled out to
# `wp media import --skip-copy` per attachment ran FOUR wp-cli container
# invocations per attachment (post meta get _wp_attached_file + post get
# --field=post_title against A, wp media import + post meta update
# _sitegraft_source_id against B). Measured on a 518-attachment reference
# pair: 6.4 imports/min, then 3.3 remaps/min — close to three hours for
# this step alone, almost entirely container-startup overhead, not real
# work. Rebuilt to mirror the content-remap mechanism (Task 4.3,
# graft_remap_attachment_ids below): one `wp eval` on A dumps every
# attachment's metadata as JSON in a single bootstrap
# (graft_collect_attachment_metadata_json), then one `wp eval` on B
# (graft_import_attachments itself, requiring
# lib/php/media-import-functions.php) does every insert and every meta
# write for every attachment in a single bootstrap — roughly 2000 container
# starts replaced with two, regardless of how many attachments there are.
#
# Resumability is preserved at the SAME granularity the rest of this file
# already promises (docs/usage.md: "a graft that's interrupted partway
# through can simply be re-run... rather than starting over or duplicating
# content") — actually tightened to true per-attachment granularity, which
# the pre-batch per-attachment loop this replaced did NOT have: that loop
# re-queried and unconditionally re-appended a row for every attachment on
# every call, with no check for one already present on B, so resuming
# after a partial interruption would have re-imported (and duplicated)
# whatever the earlier attempt had already finished. The batch instead asks
# B itself, in-process, which old_ids already carry _sitegraft_source_id
# before importing anything (sitegraft_media_import_batch's own docblock),
# and REPLACES id-map.tsv's attachment rows from that ground truth on every
# call rather than appending to them.

# graft_collect_attachment_metadata_json <alias_lc> — single wp eval
# returning a JSON array of every attachment's { old, rel_path, title } on
# <alias_lc>. rel_path is "" for an attachment with no _wp_attached_file
# meta (an external/offloaded media entry, e.g.) — included rather than
# dropped, so the batch's own accounting
# (lib/php/media-import-functions.php, sitegraft_media_build_report) can
# report it explicitly instead of it silently vanishing before ever
# reaching B, the same case the pre-batch loop logged with its own
# per-item warning.
#
# Two details in the eval below are load-bearing, and both are stated here
# rather than as PHP comments inside it: that source is bash
# SINGLE-quoted, so an apostrophe anywhere in it silently ends the string
# and breaks the script.
#
#   - get_post_field( "post_title", $id, "raw" ), never get_the_title(),
#     and never get_post_field's own two-argument form. Verified against
#     wp-includes/post.php and default-filters.php rather than assumed:
#     core hangs wptexturize, convert_chars and trim on `the_title`, so
#     get_the_title() is definitely lossy (and prefixes "Protected: " for a
#     password-protected attachment). get_post_field defaults $context to
#     "display", which runs sanitize_post_field, which returns early ONLY
#     for "raw" and otherwise applies `apply_filters( "post_title", ... )`.
#     Stock core hangs nothing on `post_title`, so on a clean install the
#     two forms look identical -- but any plugin on A can hook it, and a
#     graft must carry A's STORED bytes, not what A's plugins render. The
#     pre-batch loop read the raw column (`post get --field=post_title`);
#     "raw" is how this keeps that guarantee.
#
#   - JSON_INVALID_UTF8_SUBSTITUTE, behind a defined() guard. A title
#     holding latin1 bytes is routine on the elderly installs a graft tool
#     exists to migrate, and plain json_encode returns false on one
#     ("Malformed UTF-8 characters"). false echoes as the empty string, so
#     the eval would print NOTHING and the step would die on "could not
#     read the attachment list" -- fail-closed, but undiagnosable.
#
#     The guard is not decoration. The constant landed in PHP 7.2, and
#     NOTHING in this repo declares a PHP floor -- README states no PHP
#     requirement at all. The sites this substitution exists for (old,
#     latin1-titled WordPress) are exactly the ones most likely to be
#     running something older, where naming the bare constant is a fatal
#     error: it would turn a step that merely handled non-UTF-8 badly into
#     one that cannot run at all. Falling back to 0 is precisely the
#     pre-fix behaviour, so on PHP < 7.2 nothing gets worse and on 7.2+ the
#     bug is fixed. Chosen over declaring "PHP 7.2+ required", which would
#     exclude the population this tool exists to migrate.
graft_collect_attachment_metadata_json() {
  local alias_lc="$1"
  wp_remote "$alias_lc" eval '
    $ids = get_posts( array(
      "post_type"      => "attachment",
      "post_status"    => "inherit",
      "posts_per_page" => -1,
      "fields"         => "ids",
      "orderby"        => "ID",
      "order"          => "ASC",
    ) );
    $out = array();
    foreach ( $ids as $id ) {
      $out[] = array(
        "old"      => (int) $id,
        "rel_path" => (string) get_post_meta( $id, "_wp_attached_file", true ),
        "title"    => (string) get_post_field( "post_title", $id, "raw" ),
      );
    }
    echo json_encode( $out, defined( "JSON_INVALID_UTF8_SUBSTITUTE" ) ? JSON_INVALID_UTF8_SUBSTITUTE : 0 );
  '
}

# graft_push_media_import_lib <run_dir> — pushes
# lib/php/media-import-functions.php onto B, same wrapper-aware helper and
# lifecycle as graft_push_remap_lib (Task 4.3) uses for its own required
# library file.
graft_push_media_import_lib() {
  local run_dir="$1"
  graft_push_file b "${SITEGRAFT_ROOT}/lib/php/media-import-functions.php" "${SITE_B_WP_PATH}/wp-content" "sitegraft-media-import-functions.php"
  printf '%s/wp-content/sitegraft-media-import-functions.php' "$SITE_B_WP_PATH"
}

graft_import_attachments() {
  local run_dir="$1"
  local id_map_tsv="${run_dir}/id-map.tsv"

  local attachments_json
  attachments_json=$(graft_collect_attachment_metadata_json a)
  # Two different things land here as "not a JSON array", and the earlier
  # version of this comment described the first one wrongly. Under
  # bin/sitegraft's real `set -euo pipefail`, a wp-cli that EXITS non-zero
  # never reaches this check at all: `attachments_json=$(cmd)` aborts the
  # script on the spot. What actually gets here is (a) a wp-cli that exits
  # ZERO while printing non-JSON — a PHP notice/warning ahead of the
  # payload, an interactive prompt, a wrapper's own banner — and (b) a
  # --dry-run, where wp_remote's OWN internal echo (lib/inventory.sh)
  # substitutes literal "[dry-run] ..." text for the query. Both are
  # detected the same way and handled according to which one happened.
  if ! echo "$attachments_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    if is_dry_run; then
      # A --dry-run cannot know the attachment count: A was never queried.
      # It CAN name the two files this step writes into B's wp-content and
      # removes again — real writes on B that a reviewer reading a dry-run
      # has to see, and that the single generic line here before this
      # actively implied did not exist. The pre-batch per-attachment loop
      # listed every file it would import; that fidelity is not recoverable
      # without querying A, but the B-side writes are, so those are named.
      printf '[dry-run] wp_remote a eval (collect attachment metadata for import)\n'
      printf '[dry-run] push A'"'"'s attachment list -> %s/wp-content/sitegraft-media-import-payload.json (attachment count unknown under --dry-run: A was not queried)\n' "$SITE_B_WP_PATH"
      printf '[dry-run] push lib/php/media-import-functions.php -> %s/wp-content/sitegraft-media-import-functions.php\n' "$SITE_B_WP_PATH"
      printf '[dry-run] wp_remote b eval (sitegraft_media_import_batch over every attachment A reports)\n'
      printf '[dry-run] rm %s/wp-content/sitegraft-media-import-payload.json\n' "$SITE_B_WP_PATH"
      printf '[dry-run] rm %s/wp-content/sitegraft-media-import-functions.php\n' "$SITE_B_WP_PATH"
      return 0
    fi
    log_error "could not read A's attachment list — wp eval on A exited 0 but did not return a JSON array (see any output above). Raw output: ${attachments_json}"
    return 1
  fi

  local requested_count
  requested_count=$(echo "$attachments_json" | jq 'length')
  [ "$requested_count" -gt 0 ] || { log_info "no attachments on A — nothing to import"; return 0; }

  # Belt and braces, and knowingly unreachable today: under --dry-run
  # wp_remote never really queries A, so $attachments_json is always the
  # literal "[dry-run] ..." text and the branch above has already returned.
  # Getting here at all would mean wp_remote had started executing A-side
  # reads during a dry run — the one condition under which this second stop
  # is worth its four lines, since everything below it writes to B. Kept
  # deliberately; not counted as covered.
  if is_dry_run; then
    printf '[dry-run] wp_remote b eval (media import batch, %s attachment(s) requested)\n' "$requested_count"
    return 0
  fi

  local remote_path lib_path
  remote_path=$(graft_push_remap_payload "$run_dir" "$attachments_json" "sitegraft-media-import-payload.json")
  lib_path=$(graft_push_media_import_lib "$run_dir")

  # sitegraft_media_import_batch (required from the pushed lib) does every
  # insert and every meta write for every requested attachment inside this
  # ONE bootstrap — see that function's own docblock
  # (lib/php/media-import-functions.php) for the idempotent-resume and
  # fail-closed-accounting guarantees the glue code below relies on.
  local result_json
  result_json=$(wp_remote b eval '
    require_once WP_CONTENT_DIR . "/sitegraft-media-import-functions.php";
    $payload_path = WP_CONTENT_DIR . "/sitegraft-media-import-payload.json";
    $payload = json_decode( file_get_contents( $payload_path ), true );
    if ( ! is_array( $payload ) ) {
      echo json_encode( array( "ok" => false, "error" => "no media-import payload found or unreadable: " . json_last_error_msg() ) );
      return;
    }
    // The same UTF-8 substitution as the A-side collection, behind the
    // same defined() guard (see that docblock for why the guard is load-
    // bearing rather than decoration), but the stakes here are higher: by
    // this point the batch has ALREADY done all the work — every post inserted,
    // every _sitegraft_source_id written. A single non-UTF-8 byte anywhere
    // in the report (a filename, a WordPress error message built from a
    // path) made plain json_encode return false, which echoes as the empty
    // string, which graft_import_attachments correctly refuses — leaving
    // id-map.tsv unwritten with the import fully done. Re-running then
    // found everything already_present and failed to encode again: a
    // permanently stuck step. The pre-batch loop never had this failure
    // mode, because it passed titles through argv and never through JSON.
    $encoded = json_encode( sitegraft_media_import_batch( $payload ), defined( "JSON_INVALID_UTF8_SUBSTITUTE" ) ? JSON_INVALID_UTF8_SUBSTITUTE : 0 );
    if ( $encoded === false ) {
      // REACHABLE, contrary to what this comment claimed before. On PHP
      // 7.2+ the substitution above makes json_encode succeed, and the only
      // remaining failures would be INF/NAN, recursion or depth, none of
      // which this report can contain. But the defined() guard deliberately
      // falls back to flag 0 on older PHP — which README documents as
      // supported, and which is exactly the latin1-titled population this
      // whole substitution exists for. There, one non-UTF-8 byte in a
      // per-item error message (a filename, typically) brings the original
      // bug straight back. Measured on this report shape:
      //   json_encode($report, JSON_INVALID_UTF8_SUBSTITUTE)  -> string
      //   json_encode($report, 0)                             -> bool(false)
      //   json_last_error_msg() -> "Malformed UTF-8 characters..."
      // So this turns "empty stdout, no explanation" — the single hardest
      // thing to diagnose in this whole step — into a named error. It is
      // not exercised by the suite only because the suite runs on a PHP
      // where the constant exists; that is a coverage gap, not a dead
      // branch.
      $encoded = json_encode( array( "ok" => false, "error" => "media-import batch result could not be JSON-encoded: " . json_last_error_msg() ) );
    }
    echo $encoded;
  ')

  graft_remove_file b "$remote_path"
  graft_remove_file b "$lib_path"

  # Fail closed: no output, or output that isn't a JSON object, means the
  # wp eval process crashed or was killed partway through — exactly the
  # "silently ate an error per item and reported a global success" failure
  # mode issue #11 names as the worst possible outcome here. The actual
  # JSON shape is what's checked, not merely a non-zero exit from
  # run_or_echo/wp_remote — a `wp eval` that hits a genuine PHP fatal can
  # still leave partial, unparseable text on stdout.
  if ! echo "$result_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    log_error "media import batch on B produced no parseable result — refusing to report success. Raw output: ${result_json}"
    return 1
  fi

  local batch_error
  batch_error=$(echo "$result_json" | jq -r '.error // empty')
  if [ -n "$batch_error" ]; then
    log_error "media import batch on B failed: ${batch_error}"
    return 1
  fi

  local ok
  ok=$(echo "$result_json" | jq -r '.ok')
  if [ "$ok" != "true" ]; then
    log_error "media import batch on B did not account for every requested attachment: $(echo "$result_json" | jq -c '{requested, accounted_for}') — refusing to report success"
    return 1
  fi

  # Replace id-map.tsv's attachment rows from this call's ground-truth map
  # (imported now, or already present from an earlier partial call of this
  # same step) — never append. See this function's own header comment for
  # why append-only was the pre-batch implementation's duplicate-row bug on
  # a resumed, partially-completed step.
  # N5: `.map` missing entirely (an object result from some future/older
  # library version) sent `jq -r '.map | to_entries[]'` into "null (null)
  # has no keys", jq exit 5, INSIDE a `map_tsv=$(...)` assignment — under
  # bin/sitegraft's real `set -euo pipefail` that aborts the whole script
  # on a raw jq error line instead of this function's own controlled
  # log_error, exactly what the `type == "object"` guard above already
  # exists to prevent one level up. An EMPTY map is fine and expected (see
  # sitegraft_media_build_report's stdClass note) — what is refused is a
  # map that is absent or not an object.
  if ! echo "$result_json" | jq -e '(.map | type) == "object"' >/dev/null 2>&1; then
    log_error "media import batch on B returned no usable id map (.map is absent or not a JSON object) — refusing to rewrite id-map.tsv. Raw output: ${result_json}"
    return 1
  fi

  local other_rows map_tsv
  other_rows=""
  [ -f "$id_map_tsv" ] && other_rows=$(awk -F'\t' '$3!="attachment"' "$id_map_tsv")
  map_tsv=$(echo "$result_json" | jq -r '.map | to_entries[] | "\(.key)\t\(.value)\tattachment"')
  {
    [ -z "$other_rows" ] || printf '%s\n' "$other_rows"
    [ -z "$map_tsv" ] || printf '%s\n' "$map_tsv"
  } > "$id_map_tsv"

  local imported_count already_present_count no_local_file_count failed_count
  imported_count=$(echo "$result_json" | jq '.imported | length')
  already_present_count=$(echo "$result_json" | jq '.already_present | length')
  no_local_file_count=$(echo "$result_json" | jq '.no_local_file | length')
  failed_count=$(echo "$result_json" | jq '.failed | length')

  # An attachment A holds no _wp_attached_file for was never locally
  # storable in the first place (external/offloaded media): skipping it is
  # the correct outcome, not a failure, and stays a warning — the same
  # thing the pre-batch per-attachment loop did.
  if [ "$no_local_file_count" -gt 0 ]; then
    log_warn "skipped ${no_local_file_count} attachment(s) with no _wp_attached_file meta on A (not locally-stored, e.g. external/offloaded media): $(echo "$result_json" | jq -c '.no_local_file')"
  fi

  # What ACTUALLY landed on B, not what was planned (CLAUDE.md: "never
  # report success you have not earned"). already_present_count is > 0 only
  # when this call resumed a previously-interrupted run of this same step.
  # Printed BEFORE the refusal below so a failed step still tells the
  # operator what it did manage to do.
  log_info "media import: ${imported_count} newly imported, ${already_present_count} already present (resumed), ${no_local_file_count} skipped (no local file), ${failed_count} failed — ${requested_count} attachment(s) requested"

  # BLOCKER (review): this used to be a log_warn and a zero exit. `ok` from
  # the batch only means every attachment landed in SOME bucket, and
  # `failed` IS one of those buckets — so a batch that got 400 of 518 in
  # and lost 118 to per-item errors came back ok=true and this function
  # returned 0. phase_graft wires every step as `graft_step_done ... || {
  # <step>; graft_mark_step ...; }`, so a zero exit writes
  # graft.import_attachments.done, a resumed run skips this step FOREVER,
  # the 118 are never retried, and graft_remap_attachment_ids /
  # graft_remap_featured_images then hit `[ -s "$id_map_tsv" ] || return 0`
  # and say nothing at all. The only witness was this warning, in a
  # 3000-line log. Measured before the fix: 400/518 imported -> exit 0;
  # 0/518 imported -> exit 0 with a zero-byte id-map.tsv.
  #
  # Not theoretical, and routine on a SECOND graft: graft_prune_previous_run
  # deletes every _sitegraft_source_id-tagged post with `wp post delete
  # --force`, which removes the attached file from disk, so the next import
  # finds nothing to register and EVERY attachment fails — and the graft
  # used to carry on to completion with zero media.
  #
  # The id-map rewrite above deliberately stays above this refusal: what
  # did import is recorded, so a re-run retries only what failed (the
  # resume path sitegraft_media_import_batch already guarantees). There is
  # no --allow-partial-media escape hatch on purpose — re-running IS the
  # escape hatch, and it is the one that ends with the media actually
  # migrated.
  if [ "$failed_count" -gt 0 ]; then
    # Capped at 20. On a total failure this list holds one object per
    # attachment -- 518 of them on the reference pair -- and dumping all of
    # them onto a single line produces something nobody reads at 3am, which
    # is exactly when this message gets read. The count is already stated,
    # and the full set is one `jq` away in the batch result.
    local failed_sample failed_suffix
    failed_sample=$(echo "$result_json" | jq -c '.failed[0:20]')
    failed_suffix=""
    [ "$failed_count" -gt 20 ] && failed_suffix=" (first 20 of ${failed_count} shown)"
    log_error "failed to import ${failed_count} of ${requested_count} attachment(s) onto B: ${failed_sample}${failed_suffix} — refusing to report success; re-run to retry only the ones that failed"
    return 1
  fi
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
      # shellcheck disable=SC2086 # intentionally unquoted: prefix may be a multi-word wrapper (e.g. ddev exec ... wp) and must word-split
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
      # Staged under wp-content, NOT under /tmp. A wrapper of the form
      # `docker run --rm ...` starts a brand-new container for every single
      # invocation, so anything written outside a mounted volume is gone the
      # moment that container exits: the `mkdir -p` of a /tmp path happened
      # in one container and the `tar -x` into it ran in another, which had
      # never seen it ("tar: /tmp/sitegraft-import-<pid>: Cannot open: No
      # such file or directory"). Only the site tree, mounted in via
      # --volumes-from, is common to all of them.
      #
      # It worked on the source side because that wrapper is a `docker exec`
      # into a long-lived container, where /tmp does persist between calls —
      # the code's implicit assumption was that a wrapper always enters a
      # container that stays alive. It does not have to.
      #
      # wp-content is the right place regardless: graft already stages its
      # id-remap and domain-remap payloads there for exactly this reason, and
      # it is by definition writable and visible to wp-cli on any B. The
      # directory is removed by graft_remove_dir right after the import.
      local container_dir="${SITE_B_WP_PATH}/wp-content/sitegraft-import-$$"
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
        log_warn "no id-map.log found on B — id-map.tsv left as-is. This is legitimate only if the WXR import inserted NOTHING (every item already existed on B). If it did import posts, the mapping mu-plugin was not running, and EVERY remap that follows is now a no-op against an incomplete map: attachment ids inside content, featured images, page_on_front, and every module post_import hook. Check the import output above before trusting this run."
        return 0
      fi
      run_or_echo bash -c "${prefix} cat '${src}' > '${tmp}'"
    else
      if ! is_dry_run && [ ! -f "$src" ]; then
        log_warn "no id-map.log found on B — id-map.tsv left as-is. This is legitimate only if the WXR import inserted NOTHING (every item already existed on B). If it did import posts, the mapping mu-plugin was not running, and EVERY remap that follows is now a no-op against an incomplete map: attachment ids inside content, featured images, page_on_front, and every module post_import hook. Check the import output above before trusting this run."
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

# graft_content_tables_csv and graft_build_sentinel_commands used to live
# here — REMOVED (review, Viktor, NIT-1). Both went orphaned the moment
# graft_remap_attachment_ids/graft_search_replace_domain were rebuilt for
# MAJOR-2 (this same fix-pack) to stop scanning whole tables and instead
# rewrite only the specific posts this run imported: the two-pass sentinel
# logic moved into lib/php/content-remap-functions.php, run via a single
# `wp eval` per remap step, and neither bash function had any remaining
# caller. Their own unit tests stayed green regardless — a real, if
# accidental, false-coverage signal on exactly the logic (the remap that
# must never contaminate protected data) where a coverage gap matters most.
# See lib/php/content-remap-functions.php and its own bats-driven `php`
# tests (tests/unit/test_content_remap_functions.bats) for where this logic
# and its test coverage live now.

# graft_push_remap_lib <run_dir> — pushes lib/php/content-remap-functions.php
# onto B (wrapper-aware, same graft_push_file every other B-bound transfer
# in this file uses) so the `wp eval` snippets below can `require_once` it
# instead of re-embedding the substitution logic inline. Caller removes it
# afterward via graft_remove_file, same lifecycle as the JSON payload.
graft_push_remap_lib() {
  local run_dir="$1"
  graft_push_file b "${SITEGRAFT_ROOT}/lib/php/content-remap-functions.php" "${SITE_B_WP_PATH}/wp-content" "sitegraft-content-remap-functions.php"
  printf '%s/wp-content/sitegraft-content-remap-functions.php' "$SITE_B_WP_PATH"
}

# graft_migrated_post_ids_json <id_map_tsv> — every NEW post ID this run
# imported, as a JSON array of strings, in id-map.tsv's own row order.
# Shared by graft_remap_attachment_ids/graft_search_replace_domain below —
# both need exactly this same "which posts did THIS run actually touch"
# scope, so it's computed once instead of twice.
graft_migrated_post_ids_json() {
  local id_map_tsv="$1"
  awk -F'\t' '{print $2}' "$id_map_tsv" | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# graft_push_remap_payload <run_dir> <json> <remote_filename> — writes
# <json> to a local temp file and pushes it onto B via graft_push_file
# (wrapper-aware, same helper every other B-bound file transfer in this
# file uses), returning the CONTAINER-side path the PHP payload below reads
# from. Caller is responsible for removing it afterward via graft_remove_file.
graft_push_remap_payload() {
  local run_dir="$1" json="$2" remote_filename="$3"
  local local_payload="${run_dir}/.${remote_filename}"
  printf '%s' "$json" > "$local_payload"
  chmod 600 "$local_payload" 2>/dev/null || true
  graft_push_file b "$local_payload" "${SITE_B_WP_PATH}/wp-content" "$remote_filename"
  rm -f "$local_payload"
  printf '%s/wp-content/%s' "$SITE_B_WP_PATH" "$remote_filename"
}

# MAJOR-2 (review, Viktor — this is the important fix in this file):
# `wp search-replace` has no row-level scoping at all — the previous
# implementation ran it against the WHOLE content tables
# (wp_posts/wp_postmeta/wp_options), which means ANY row there, including a
# protected plugin's own settings in wp_options or its own postmeta, was in
# scope for this regex substitution. Reproduced live: a protected option
# carrying a colliding `"id":<N>` payload (N = an old attachment ID this run
# also happened to migrate) got silently rewritten — a real corruption of
# data this tool's core promise says it will never touch.
#
# Rebuilt to touch ONLY what this run actually imported, never a table
# scan: pushes a small JSON payload (the attachment old->new map, and the
# full list of migrated post IDs) onto B, then a SINGLE `wp eval` fetches
# post_content/post_excerpt for exactly those post IDs — never anything
# else — applies the identical two-pass sentinel technique (pass 1: every
# `"id":X`/`wp-image-X` -> a unique sentinel, ALL attachments, before pass
# 2 resolves any sentinel to its real new ID — same ordering guarantee as
# before, per design doc §9.1), and writes back only the posts that
# actually changed. A protected plugin's row anywhere else is never read,
# matched, or written — not filtered out after the fact, structurally
# unreachable by this function.
#
# PHP's own preg_replace (full PCRE, including the negative-lookahead the
# sentinel patterns need) does the substitution — not sed/grep -E, neither
# of which supports `(?!\d)` — and not a naive bash string replace either,
# which would be unsafe generically (this codebase's own CLAUDE.md: "never
# sed/raw regex on WordPress data") — post_content/post_excerpt specifically
# are plain TEXT columns, never PHP-serialized, so a direct fetch/modify/
# write-back is safe for exactly these two fields. This is why the scope
# is content-field-only: wp_postmeta values CAN be
# serialized PHP, and safely rewriting an arbitrary serialized structure
# needs WordPress's own maybe_unserialize()/maybe_serialize() round-trip —
# out of scope here, same as design doc §11's existing position that a
# CPT-specific meta reference is the relevant module's post_import hook's
# job, not a generic core remap's.
#
# The write-back itself is $wpdb->update() (sitegraft_write_remapped_post,
# in lib/php/content-remap-functions.php — read its own docblock for
# exactly which WordPress write-path behavior it trades away on purpose,
# and why), NOT wp_update_post(): wp_update_post()'s array-form/
# object-form slashing asymmetry is what issue #43 actually was.
#
# The payload is pushed to a real file rather than embedded via bash string
# interpolation into the PHP source: keeps the PHP body 100% static (no
# bash-side escaping of PHP's own quotes/`$`/backslashes to get wrong), and
# reuses the exact same wrapper-aware transfer helper every other B-bound
# file in this codebase already goes through.
graft_remap_attachment_ids() {
  local id_map_tsv="$1" run_dir="$2"
  [ -s "$id_map_tsv" ] || return 0

  local attach_map_json post_ids_json payload_json remote_path lib_path
  attach_map_json=$(awk -F'\t' '$3=="attachment"{printf "%s\t%s\n", $1, $2}' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {old: .[0], new: .[1]})')
  [ "$(echo "$attach_map_json" | jq 'length')" != "0" ] || return 0
  # B2 (Viktor's review of issue #17/PR #38, execution-proven): NOT
  # graft_migrated_post_ids_json (below) unfiltered -- that shared helper is
  # correct for graft_search_replace_domain's own use (a domain leak inside
  # a wp_navigation post's custom-link URL genuinely needs the same
  # search-replace every other migrated post gets), but wrong here.
  # sitegraft_remap_attachment_refs substitutes `"id":<old_attachment_id>`
  # for every post in scope with zero awareness of what that "id" MEANS in
  # context -- a wp_navigation post's navigation-link block can carry
  # "kind":"taxonomy" (a TERM id) or "kind":"post-type" (a POST id) under
  # the exact same `"id":N` JSON key, and this function's blind substitution
  # cannot tell them apart. Attachment ids and term ids are independent
  # sequences that both start at 1 on a fresh WordPress site, so a
  # collision is a real, not theoretical, risk on a small site: a
  # "kind":"taxonomy" link whose id happens to equal a migrated attachment's
  # OLD id would silently come out carrying that attachment's NEW id
  # instead of its own untouched term id -- corrupting a reference that was
  # never about an attachment at all. modules/core-wp.sh's own
  # _core_wp_remap_nav_page_ids (which runs AFTER this function, in the
  # module post_import step, and is the one place that DOES understand
  # "kind") cannot repair this after the fact: it only ever touches
  # "kind":"post-type" entries by the same ambiguity-safety design, so a
  # taxonomy-kind corruption introduced here survives untouched.
  #
  # PRECISION (third-round review, Viktor): the exclusion below removes the
  # ENTIRE wp_navigation post from this function's scope, not just its
  # navigation-link/navigation-submenu blocks specifically -- there is no
  # per-block granularity available at this point, only per-post. In
  # practice this loses nothing real: a wp_navigation post's content is,
  # by construction, navigation blocks (navigation-link, navigation-
  # submenu, page-list, and similar), and none of those embed an
  # attachment reference (they link to a page, post, term, or a bare
  # custom URL -- never a media item). A wp_navigation post that somehow
  # also carried an unrelated attachment-referencing block would lose
  # THAT block's attachment-id remap too, not just its navigation blocks'
  # ids -- an acceptable trade against corrupting a taxonomy-kind id, and
  # not a shape any real Navigation-block editing flow produces.
  post_ids_json=$(awk -F'\t' '$3 != "wp_navigation"{print $2}' "$id_map_tsv" \
    | jq -R -s -c 'split("\n") | map(select(length > 0))')
  payload_json=$(jq -n --argjson attachments "$attach_map_json" --argjson post_ids "$post_ids_json" \
    '{attachments: $attachments, post_ids: $post_ids}')
  remote_path=$(graft_push_remap_payload "$run_dir" "$payload_json" "sitegraft-id-remap-payload.json")
  lib_path=$(graft_push_remap_lib "$run_dir")

  # The actual substitution (sitegraft_remap_attachment_refs) and the
  # write-back (sitegraft_write_remapped_post) both live in
  # lib/php/content-remap-functions.php — required here, never re-embedded
  # inline (review, Viktor, NIT-1: keeps production and its own unit tests
  # running the literal same code, and both independently unit-testable —
  # the substitution in tests/unit/test_content_remap_functions.bats, the
  # write-back in tests/unit/test_content_remap_write.bats). The write-back
  # is $wpdb->update(), NOT wp_update_post() (issue #43) — see
  # sitegraft_write_remapped_post's own docblock for why the array form of
  # wp_update_post() silently ate every backslash this remap writes.
  run_or_echo wp_remote b eval '
    require_once WP_CONTENT_DIR . "/sitegraft-content-remap-functions.php";
    $payload_path = WP_CONTENT_DIR . "/sitegraft-id-remap-payload.json";
    $payload = json_decode( file_get_contents( $payload_path ), true );
    if ( ! $payload ) { echo "sitegraft: no id-remap payload found or unreadable\n"; return; }
    $count = 0;
    foreach ( $payload["post_ids"] as $post_id ) {
      $post_id = (int) $post_id;
      $post = get_post( $post_id );
      if ( ! $post ) { continue; }
      $content = sitegraft_remap_attachment_refs( $payload["attachments"], $post->post_content );
      $excerpt = sitegraft_remap_attachment_refs( $payload["attachments"], $post->post_excerpt );
      if ( sitegraft_write_remapped_post( $post, array( "post_content" => $content, "post_excerpt" => $excerpt ) ) ) {
        $count++;
      }
    }
    echo "sitegraft: id-remap rewrote {$count} post(s)\n";
  '
  graft_remove_file b "$remote_path"
  graft_remove_file b "$lib_path"
}

# MAJOR-1 (found by review, Viktor): design doc §9.2 counts on
# wordpress-importer to natively remap featured-image (_thumbnail_id) and
# post_parent references during import — but that native remap only fires
# for a reference INSIDE the same WXR import, via wordpress-importer's own
# correspondence table. graft_import_attachments (this file, Task 4.1/4.2
# fix-pack) deliberately migrates attachments OUTSIDE the WXR/`wp import`
# path entirely (see its own header comment for why) — attachments are
# never in the WXR wordpress-importer processes, so its native
# _thumbnail_id remap never runs for them. Left unfixed, every migrated
# post that had a featured image on A keeps A's OWN attachment ID in its
# `_thumbnail_id` postmeta after import — pointing at nothing (or, worse,
# at an unrelated existing attachment on B whose ID happens to collide).
# The sentinel remap (graft_remap_attachment_ids, above) does not cover
# this either: `_thumbnail_id` is stored as a bare integer in meta_value,
# not inside a `"id":X` or `wp-image-X` string pattern.
#
# Scoped to exactly the posts THIS run imported (every row of id_map_tsv,
# read directly — never a table-wide scan or search-replace): for each
# imported post, if its current `_thumbnail_id` matches an OLD attachment
# ID this same run also migrated, rewrite it to that attachment's NEW ID.
# A post whose _thumbnail_id doesn't match anything in id-map.tsv (already
# correct, unset, or pointing at content outside this run's selection) is
# left untouched — this is a targeted fix, not a blind sweep.
#
# Reads directly from the id-map.tsv FILE on fd 3 (not a process
# substitution) — no fd0-collision risk (see graft_remap_attachment_ids'
# own comment on that bug class), but the same fd-3 convention is used here
# too for consistency and because the loop body execs wp_remote either way.
#
# Other CPT-specific attachment-referencing meta keys (a "related_image_id"
# a business plugin might use, say) are explicitly out of scope here, same
# as any other module-specific internal reference (design doc §11's edge
# case table: "outside the core's generic remap — that's the job of the
# relevant module's post_import hook"). _thumbnail_id is the one universal,
# WordPress-core-defined key every post_type can carry, which is why it
# gets a generic, non-module-specific fix.
graft_remap_featured_images() {
  local id_map_tsv="$1"
  # Fix-pack bug found live (running the DDEV harness's new MAJOR-B
  # dry-run assertion, a genuinely fresh run directory never graft'd for
  # real before): `graft_fetch_id_map` deliberately never creates
  # id-map.tsv under --dry-run (its own writes are all run_or_echo-wrapped,
  # correctly — see that function's own comment), so on a first-time dry
  # run the file doesn't exist AT ALL yet, not merely empty. The `done 3<
  # "$id_map_tsv"` redirect below fails outright on a missing file
  # ("No such file or directory") under this codebase's own `set -e`,
  # aborting the whole graft. graft_remap_attachment_ids (above) already
  # guards against exactly this — id-map.tsv genuinely not existing OR
  # existing empty are the same "nothing to remap yet" case — this
  # function just never got the same guard. `-s` (exists AND non-empty),
  # matching that sibling function's own check precisely.
  [ -s "$id_map_tsv" ] || return 0
  local old_id new_id post_type
  # shellcheck disable=SC2094 # false positive for both this loop's own read (3<) and the awk call inside it below: id_map_tsv is only ever READ in this loop, never written. NOTE: this directive scopes to the WHOLE while/done block below (21 lines), not just this one line -- a directive can't precede a bare `done`, only a complete compound command, so it has to sit here instead of right above the awk call it's really about.
  # shellcheck disable=SC2034 # old_id (below) genuinely is unused in THIS loop's body -- it's read to keep the tuple destructure aligned with id-map.tsv's own old_id<TAB>new_id<TAB>post_type format (every other reader of this file in lib/graft.sh reads the same three fields), not because this function needs it. Real, pre-existing, harmless: only surfaced by shellcheck now (issue #11's media-step rewrite) because that was the last OTHER use of the name "old_id" anywhere in this file, and shellcheck's SC2034 check is not fully scope-aware across functions -- it stopped treating the name as "used elsewhere" once that last usage was removed.
  while IFS=$'\t' read -r old_id new_id post_type <&3; do
    [ "$post_type" != "attachment" ] || continue
    local current_thumb
    # MAJOR-1 fix-pack bug found live: `wp post meta get` exits non-zero
    # for a post that has no _thumbnail_id at all (the common case — most
    # migrated posts never had a featured image) — under bin/sitegraft's
    # `set -e`, an unguarded `var=$(cmd)` assignment where cmd fails aborts
    # the WHOLE graft immediately, silently (stderr already redirected to
    # /dev/null), the instant it hit the first post with no thumbnail.
    # Reproduced live: the full DDEV harness run died right after the
    # id-remap step, no error printed, no further log lines at all.
    # `|| true` keeps the (correctly empty) result and lets the `[ -n ... ]`
    # check below do its job as originally intended.
    current_thumb=$(wp_remote b post meta get "$new_id" _thumbnail_id 2>/dev/null || true)
    [ -n "$current_thumb" ] || continue
    local new_thumb
    new_thumb=$(awk -F'\t' -v old="$current_thumb" '$1==old && $3=="attachment"{print $2}' "$id_map_tsv")
    if [ -n "$new_thumb" ]; then
      run_or_echo wp_remote b post meta update "$new_id" _thumbnail_id "$new_thumb"
    fi
  done 3< "$id_map_tsv"
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
# BLOCKER (review fix-pack, reproduced live by Viktor): this used to `touch`
# the marker unconditionally, dry-run or not. Every step in phase_graft below
# is wired as `graft_step_done "$run_dir" X || { <do the step>;
# graft_mark_step "$run_dir" X; }` — a `--dry-run` graft still calls
# graft_mark_step after each step (only the step's OWN body is dry-run-aware,
# via run_or_echo), so a dry run against a run directory wrote every single
# `graft.<step>.done` marker for real. A REAL graft run against that SAME
# run directory afterward (`scan -> plan -> backup -> graft --dry-run ->
# graft`) then sees graft_step_done true for every step and skips the
# entire pipeline — a silent no-op that reports "graft complete" without
# having migrated anything. Guarded here, in the one shared function every
# call site already goes through, rather than repeating an `is_dry_run`
# check at each of the dozen `graft_mark_step` call sites (including the
# EXIT trap's own mu-plugin-cleanup marking, `_graft_exit_trap` above) —
# one fix covers all of them. Within a single dry-run pass this changes
# nothing an operator sees: `graft_step_done` still reads false for every
# step (no marker was ever written), so the `|| { ... }` on the right still
# runs each step's body exactly once and the full dry-run preview output is
# still produced — the only thing that changes is that nothing persists to
# disk afterward.
graft_mark_step() { is_dry_run && return 0; touch "${1}/graft.${2}.done"; }

# design doc §6.4 step 8 / review finding A1: this step was missing entirely from
# the previous draft — sitegraft migrated content but never the Etch/ACSS settings.
# page_on_front/page_for_posts are written to disk (for core_wp_post_import, §9.3)
# but never blind-copied here, since A's value is A's own page ID.
# graft_migrate_options <run_dir> <manifest> [domain_from] [domain_to] —
# domain_from/domain_to are optional (both default to "", meaning no
# rewrite) purely to keep this backward-compatible with every existing
# call/test that only ever passed the first two arguments.
#
# MAJOR-2 fix-pack addition: this is now also where design doc §9.4's
# "Etch stores some data as JSON blobs in certain options" case is
# handled — graft_search_replace_domain (above) deliberately stopped
# covering wp_options entirely (a table-wide search-replace there could
# reach a protected plugin's own settings). This function already only
# ever touches the manifest's explicitly-listed option_keys, one at a
# time, never a table scan — so applying the same plain-text domain
# substitution to the already-fetched VALUE here, before it's pushed to B,
# closes that gap with the exact same "only what's explicitly selected"
# safety property this function already had for everything else.
graft_migrate_options() {
  local run_dir="$1" manifest="$2" domain_from="${3:-}" domain_to="${4:-}"
  local keys key
  keys=$(echo "$manifest" | jq -r '[.migrate[].option_keys[]?] | unique[]')
  # A read loop over fd 3, not `for key in $(...)`. The old form relied on
  # UNQUOTED word splitting, so an option key containing whitespace became
  # two keys and `wp option update` ran twice against names nobody planned —
  # on B's live database. module_selection rejects such a name, but only on
  # the plan_defaults path: a SITEGRAFT_MANIFEST_PREFILLED or hand-edited
  # manifest reaches here without ever passing through it. manifest_validate
  # now applies the same rule (second entry point, same rule), and this loop
  # is the third line: a manifest edited AFTER being frozen never passes
  # through validation again either. fd 3 rather than stdin, the discipline
  # module_selection and _plan_prompt_items already follow, because the loop
  # body runs wp-cli over ssh and must leave fd 0 alone.
  while IFS= read -r key <&3; do
    [ -n "$key" ] || continue
    case "$key" in
      *,*|*[[:space:]]*)
        log_error "graft: manifest option key '${key}' contains a comma or whitespace — refusing to migrate options from a manifest that cannot be read unambiguously (such a name would word-split into two different keys and run 'wp option update' against names nobody planned, on B's live database). This manifest did not come from 'sitegraft plan' unmodified; rebuild it."
        return 1
        ;;
    esac
    local value get_rc=0
    # Fix-pack bug found live (DDEV harness, running MAJOR-B's new
    # graft --dry-run assertion end to end for the first time): wp_remote
    # (lib/inventory.sh) wraps EVERY call in run_or_echo, including a plain
    # READ from A — it has no notion of "this particular call is
    # non-destructive, run it for real". Under --dry-run this read used to
    # return the literal text "[dry-run] wp_remote a option get ..."
    # instead of A's real value, which then went straight into `jq` a few
    # lines below (the domain-rewrite pass) as if it were valid JSON — jq
    # fails on it (not valid JSON), and under this codebase's `set -euo
    # pipefail` that failure aborted the whole graft with a bare, unlogged
    # "exit 5", not even a friendly error message. `SITEGRAFT_DRY_RUN=0`
    # prefixed onto just this one call is a genuine, temporary shell
    # variable override for the duration of this single function call
    # (real bash behavior for a function invocation, not merely an
    # external-process env var) — it does not affect SITEGRAFT_DRY_RUN
    # anywhere else, including the real write below (`run_or_echo
    # wp_remote b option update ...`), which stays correctly simulated.
    # This mirrors the same principle scan's own M6 fix and verify's own
    # MAJOR-A fix already establish: reads needed to compute a correct
    # dry-run PREVIEW must run for real; only writes get simulated.
    # N3 (third review round): this used to be `... || echo 'null'`, which
    # wrote the LITERAL string `null` for any key A does not have, and then
    # pushed it to B — ERASING B's own value. Reproduced: a site A without
    # Etch's Loop Manager has no `etch_cfs`, but `etch_option_keys` is a
    # static allowlist that names it regardless, so graft ran
    # `option update etch_cfs null` on B. core_wp_option_keys_dynamic's own
    # header comment already warned about exactly this mechanism ("claiming a
    # key A does not have would BLANK B's own theme_mods") — documented
    # there, unguarded here. A key A does not have is nothing to migrate, so
    # it is skipped, out loud, and no `option-<key>.value` file is left
    # behind for a post_import hook to act on either.
    value=$(SITEGRAFT_DRY_RUN=0 wp_remote a option get "$key" --format=json 2>/dev/null) || get_rc=$?
    if [ "$get_rc" -ne 0 ]; then
      log_warn "graft: A has no '${key}' option (wp option get exited ${get_rc}) — leaving B's own value untouched. Migrating nothing is the only safe reading: writing the literal 'null' here, which is what this used to do, would have ERASED whatever B had under that key."
      continue
    fi
    if [ -n "$domain_from" ]; then
      # jq's own decode/encode round-trip, deliberately NOT a bash/sed
      # string or regex replace: `value` is valid JSON text (from
      # `--format=json`), which can spell the exact same domain string two
      # different ways depending on nesting/re-encoding (plain "https://..."
      # vs. JSON-escaped "https:\/\/..."). Walking the DECODED structure and
      # doing a plain, non-regex substring split/join on every string leaf
      # (jq's `split($x) | join($y)` idiom — never `gsub`, which IS regex
      # and would need its own dot-escaping) handles both forms in one pass
      # for free, since jq re-serializes consistently regardless of which
      # form the input used. Also sidesteps a real bug found while building
      # this: bash's `${var//pattern/replacement}` treats a LITERAL
      # backslash in `pattern` as glob escape syntax, not as a character to
      # match — a hand-rolled "plain + escaped" bash double-pass here
      # silently failed to rewrite the escaped form at all (reproduced live
      # via this function's own test).
      local rewritten
      rewritten=$(printf '%s' "$value" | jq -c --arg from "$domain_from" --arg to "$domain_to" \
        'def replace_domain: if type == "string" then split($from) | join($to) else . end; walk(replace_domain)' 2>/dev/null)
      [ -n "$rewritten" ] && value="$rewritten"
    fi
    printf '%s' "$value" > "${run_dir}/option-${key}.value"
    case "$key" in
      page_on_front|page_for_posts) continue ;; # remapped by core_wp_post_import, §9.3
    esac
    run_or_echo wp_remote b option update "$key" "$value" --format=json
  done 3<<< "$keys"
}

# design doc §9.4: two passes (plain + JSON-escaped, since Etch stores some
# data as JSON blobs inside post_content).
#
# MAJOR-2 (review, Viktor) — same fix, same reasoning as
# graft_remap_attachment_ids immediately above (read that function's own
# comment for the full explanation): rebuilt from a whole-content-tables
# `wp search-replace` to a post_content/post_excerpt-only rewrite of
# exactly the posts THIS run imported, via a pushed JSON payload + a single
# `wp eval`. A protected plugin's domain-string-shaped data sitting in
# wp_options or wp_postmeta (a real, if lower-probability, collision than
# the ID case, but the exact same class of exposure) is never in scope.
#
# Migrated OPTIONS' own values (design doc §9.4's original "Etch stores
# some data as JSON blobs in certain options" case) are handled separately
# and more narrowly by graft_migrate_options — which already only ever
# touches the manifest's explicitly-listed option_keys, never a table scan
# — see that function's own domain-rewrite step.
graft_search_replace_domain() {
  local from="$1" to="$2" id_map_tsv="$3" run_dir="$4"
  if [ -z "$from" ] || [ ! -s "$id_map_tsv" ]; then
    return 0
  fi

  local post_ids_json payload_json remote_path lib_path
  post_ids_json=$(graft_migrated_post_ids_json "$id_map_tsv")
  payload_json=$(jq -n --arg from "$from" --arg to "$to" --argjson post_ids "$post_ids_json" \
    '{from: $from, to: $to, post_ids: $post_ids}')
  remote_path=$(graft_push_remap_payload "$run_dir" "$payload_json" "sitegraft-domain-remap-payload.json")
  lib_path=$(graft_push_remap_lib "$run_dir")

  # sitegraft_remap_domain lives in lib/php/content-remap-functions.php —
  # same reasoning as graft_remap_attachment_ids' own require_once above.
  # The write-back is $wpdb->update(), NOT wp_update_post() (issue #43) —
  # see sitegraft_write_remapped_post's own docblock. This call site is the
  # one issue #43 actually reproduces on: sitegraft_remap_domain matches
  # and rewrites the JSON-escaped `https:\/\/` form, and the array form of
  # wp_update_post() silently ate that backslash on every write.
  run_or_echo wp_remote b eval '
    require_once WP_CONTENT_DIR . "/sitegraft-content-remap-functions.php";
    $payload_path = WP_CONTENT_DIR . "/sitegraft-domain-remap-payload.json";
    $payload = json_decode( file_get_contents( $payload_path ), true );
    if ( ! $payload ) { echo "sitegraft: no domain-remap payload found or unreadable\n"; return; }
    $count = 0;
    foreach ( $payload["post_ids"] as $post_id ) {
      $post_id = (int) $post_id;
      $post = get_post( $post_id );
      if ( ! $post ) { continue; }
      $content = sitegraft_remap_domain( $post->post_content, $payload["from"], $payload["to"] );
      $excerpt = sitegraft_remap_domain( $post->post_excerpt, $payload["from"], $payload["to"] );
      if ( sitegraft_write_remapped_post( $post, array( "post_content" => $content, "post_excerpt" => $excerpt ) ) ) {
        $count++;
      }
    }
    echo "sitegraft: domain-remap rewrote {$count} post(s)\n";
  '
  graft_remove_file b "$remote_path"
  graft_remove_file b "$lib_path"
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

# graft_record_module_content_rewrite <run_dir> <post_id> — issue #52 fix-
# pack, review round 2's real fix for finding B2. Called by a module's own
# post_import hook (modules/etch.sh's etch_post_import, modules/core-wp.sh's
# core_wp_post_import — the two shipped hooks that rewrite post_content
# after graft's own id/domain remap already ran) for every post ID it
# ACTUALLY rewrote, never for a whole post_type it merely COULD have
# touched.
#
# lib/verify.sh's guard 1 (verify_migrated_content_matches_source) reads
# ${run_dir}/module-content-rewrites.tsv back to exclude exactly those post
# IDs from its strict content-equality comparison, comparing every OTHER
# migrated post for real. An earlier version excluded by post_type instead
# (whether a module's hook file existed on disk at all) — on any real
# checkout that is unconditionally true (both shipped modules always exist)
# and excluded every post, always, which is worse than the false-hard-fail
# defect it replaced: it stopped detecting the one thing ADR 0008's first
# "Required regardless" item exists for (a real remap failure, a #43-shaped
# backslash corruption, a write that silently landed wrong) and reported
# PASS regardless.
#
# One post ID per line, digit-only — anything else is refused rather than
# risk a malformed line corrupting the file for every other reader of it.
# Append-only: a module hook loops over many posts and calls this once per
# post it actually changed, potentially interleaved with a second module's
# own calls in the same run (both modules always ship, so both hooks
# always run) — never overwritten mid-run.
graft_record_module_content_rewrite() {
  local run_dir="$1" post_id="$2"
  case "$post_id" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s\n' "$post_id" >> "${run_dir}/module-content-rewrites.tsv"
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
    # CLEAR the deploy marker rather than marking cleanup done. The mu-plugin
    # has just been taken off B while the run is INCOMPLETE, so the resumable
    # state has to read "not deployed" — the previous version left
    # graft.mu_plugin.done in place, so the next `sitegraft graft` skipped
    # redeploying it and ran the WXR import with NO mapper at all.
    #
    # Nothing about that is loud. The import succeeds,
    # wp-content/sitegraft-id-map.log is simply never written,
    # graft_fetch_id_map only warns, and every downstream remap then runs
    # against an id-map holding whatever the media step put there and nothing
    # else: attachment ids inside content, featured images, page_on_front,
    # and every module post_import hook are all skipped. Seen live — a graft
    # resumed twice after two unrelated failures ran to completion, reported
    # success, and left B's front page pointing at an unremapped id, with the
    # only clue a single warning in the middle of the log.
    #
    # mu_cleanup is cleared too, for coherence: the pair means "deployed" /
    # "removed after being used", and after this branch neither is true.
    #
    # dry-run-trap: this `rm -f` used to run unconditionally, dry-run or
    # not — the one mutation in this whole trap that graft_mark_step's own
    # MAJOR-B guard (above, graft_step_done/graft_mark_step) did NOT cover,
    # because it isn't a graft_mark_step call site at all, it's a raw `rm`.
    # graft_remove_mu_plugin just above is dry-run-safe on both its paths
    # (local: run_or_echo via graft_remove_file; SSH: its own direct
    # `run_or_echo ssh -- ... rm -f`), so under `--dry-run` this branch's
    # condition can still be true (a real prior graft left mu_plugin.done
    # and never reached mu_cleanup) while nothing on B actually changes —
    # yet the `rm -f` here was deleting graft.mu_plugin.done on disk for
    # real regardless. Reviewed (Viktor, MAJOR-1) and reproduced by running
    # this trap twice under --dry-run, old code vs new: under the old code
    # the SECOND dry-run pass loses the "graft interrupted or failed —
    # removing the mapping mu-plugin..." warning above AND the
    # `[dry-run] rm .../sitegraft-id-mapper.php` line — both silently,
    # because graft_step_done now (wrongly) reads mu_plugin as not-done —
    # while the mu-plugin is, in fact, still live and logging on B the
    # whole time. That's the actual damage: not a redeploy (which would be
    # a harmless idempotent push), but a dry-run that stops being
    # reproducible and quietly under-reports what's really running on B —
    # exactly CLAUDE.md's "Resumability markers, --dry-run, and cleanup
    # paths must not combine into a run that quietly does less than it
    # claims." Only one step is at risk here (mu_plugin; mu_cleanup is
    # already guaranteed absent by this branch's own `if` condition, so
    # there's no second marker to lose) — fixed the same way MAJOR-B fixed
    # graft_mark_step: guard the mutation with is_dry_run.
    is_dry_run || rm -f "${rd}/graft.mu_plugin.done" "${rd}/graft.mu_cleanup.done" 2>/dev/null || true
  fi
  # NIT-3 (review, Viktor): graft_remove_file for the id-remap/domain-remap
  # JSON payload and the pushed content-remap-functions.php only ever runs
  # AFTER a successful run_or_echo wp eval — a `wp eval` that hard-fails
  # partway through (graft_remap_attachment_ids/graft_search_replace_domain,
  # both above) would leave one or more of these behind on B indefinitely.
  # No secret in any of them (id-map.tsv values are WordPress-internal
  # integer post IDs, and the domain/from-to strings are already public in
  # the manifest), but a stray file left on a genuinely public-facing site's
  # wp-content root is still worth cleaning up rather than shrugging off.
  # Filenames are fixed/predictable (never per-run-unique), so this is safe
  # to attempt unconditionally whenever SITE_B_* is valid (same "profile_load
  # already succeeded" guard the mu-plugin cleanup above relies on) —
  # `graft_remove_file`'s underlying `rm -f` is a silent no-op if the file
  # was already removed normally or never existed.
  if [ -n "$rd" ] && [ -n "${SITE_B_WP_PATH:-}" ]; then
    graft_remove_file b "${SITE_B_WP_PATH}/wp-content/sitegraft-id-remap-payload.json" 2>/dev/null || true
    graft_remove_file b "${SITE_B_WP_PATH}/wp-content/sitegraft-domain-remap-payload.json" 2>/dev/null || true
    graft_remove_file b "${SITE_B_WP_PATH}/wp-content/sitegraft-content-remap-functions.php" 2>/dev/null || true
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
      --dry-run)
        # shellcheck disable=SC2034 # read via lib/core.sh's is_dry_run(), a different sourced file in the same bash process, not in this one -- a directive can't precede a one-line case branch (`pattern) cmd ;;`), only a plain command, hence the split
        SITEGRAFT_DRY_RUN=1
        shift
        ;;
      *) log_error "unknown flag for graft: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "graft requires --profile <name>"; return 1; }
  profile_load "$profile" || return 1
  [ -n "$run_dir" ] || run_dir=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1 || true)
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
  graft_step_done "$run_dir" remap_ids     || { graft_remap_attachment_ids "${run_dir}/id-map.tsv" "$run_dir"; graft_mark_step "$run_dir" remap_ids; }
  # MAJOR-1 fix-pack: featured images (_thumbnail_id), which never go
  # through wordpress-importer's own native remap since attachments are
  # migrated outside `wp import` entirely — see graft_remap_featured_images'
  # own comment. Runs after remap_ids (same id-map.tsv dependency, no
  # ordering requirement between the two beyond both needing it populated).
  graft_step_done "$run_dir" remap_featured_images || { graft_remap_featured_images "${run_dir}/id-map.tsv"; graft_mark_step "$run_dir" remap_featured_images; }
  local domain_from domain_to
  domain_from=$(echo "$manifest" | jq -r '.options.search_replace.from')
  domain_to=$(echo "$manifest" | jq -r '.options.search_replace.to')
  # NIT-4 (review, Viktor): `jq -r` on a manifest missing
  # .options.search_replace.from/to (a hand-written manifest — manifest_new
  # always populates this key in the normal scan/plan flow, so this never
  # happens there) prints the literal 4-character string "null", not an
  # empty string — which would pass every `[ -n "$domain_from" ]` guard
  # downstream and get search-replaced as if "null" were a real domain.
  # Normalized to "" here, same treatment as any other genuinely-missing
  # value in this codebase.
  [ "$domain_from" = "null" ] && domain_from=""
  [ "$domain_to" = "null" ] && domain_to=""
  graft_step_done "$run_dir" remap_domain  || {
    graft_search_replace_domain "$domain_from" "$domain_to" "${run_dir}/id-map.tsv" "$run_dir"
    graft_mark_step "$run_dir" remap_domain
  }
  graft_step_done "$run_dir" migrate_options || { graft_migrate_options "$run_dir" "$manifest" "$domain_from" "$domain_to"; graft_mark_step "$run_dir" migrate_options; }
  graft_step_done "$run_dir" module_hooks  || { graft_run_module_post_import "$run_dir" "${run_dir}/id-map.tsv"; graft_mark_step "$run_dir" module_hooks; }

  # MINOR-1 (review, Viktor): the plan's own literal Task 4.4 pseudocode for
  # this block only ever LOGGED "removing B's pre-existing content" and
  # marked the step done — it never actually deleted anything (§6.6's
  # clean step, which removes B's pre-existing ORIGINAL content of a
  # migrated post_type, is not implemented in v1). Dead code today (no
  # `plan.sh` path ever sets clean.enabled=true — plan_defaults/manifest_new
  # both default it to false, and nothing in this codebase flips it), but a
  # hand-written manifest with clean.enabled:true would have gotten a false
  # "clean step: removing..." success message and silently NOT had anything
  # removed. Refusing loudly instead of claiming a success that never
  # happened, until §6.6 is actually implemented.
  if [ "$(echo "$manifest" | jq -r '.clean.enabled')" = "true" ]; then
    graft_step_done "$run_dir" clean || {
      log_error "manifest.clean.enabled is true, but the clean step (design doc §6.6 — removing B's pre-existing content for a migrated post_type) is not implemented yet in this version of sitegraft. Refusing to report a false success: re-run with clean.enabled=false, or remove B's stale content by hand first."
      return 1
    }
  fi

  log_info "graft complete for run: ${run_dir}"
}
