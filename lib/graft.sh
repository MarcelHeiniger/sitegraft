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

# graft_ssh_host <alias> — SITE_<ALIAS>_SSH_HOST, or empty for a local
# alias. The single point graft_push_dir/graft_push_file/graft_remove_file
# below consult FIRST, before graft_local_prefix, so ssh-remote can never
# again be a shape a caller has to remember to check for itself (issue #77:
# three of six graft_push_file call sites never did, and broke the first
# real migration onto a genuine remote B — see this file's own top-of-file
# header comment and the PR that added this function for the full story).
#
# NOT consulted by graft_pull_dir or graft_remove_dir — both still branch
# only on graft_local_prefix, the exact pre-#77 shape this function exists
# to retire. Both are safe TODAY only because every one of their call
# sites already checks SITE_*_SSH_HOST itself before ever calling them
# (verified while fixing #77) — not because either function guards it
# internally. A future caller of either that skips that check reintroduces
# #77 through a door this comment used to claim didn't exist. Left
# unconverted deliberately (out of scope for this fix-pack — see the PR's
# own "flagged, not addressed" section), not by oversight.
#
# Deliberately does NOT also resolve SITE_<ALIAS>_SSH_KEY — that is issue
# #75 (a dedicated key only ever reaches wp_remote, lib/inventory.sh), a
# real but separate gap. This is nonetheless the right place for that fix
# to land later: whatever ssh/rsync invocation it needs to add (-i/
# IdentityFile) belongs here, once, rather than re-diverging across every
# caller a second time.
graft_ssh_host() {
  local alias_lc="$1"
  local alias_uc; alias_uc=$(printf '%s' "$alias_lc" | tr '[:lower:]' '[:upper:]')
  local host_var="SITE_${alias_uc}_SSH_HOST"
  printf '%s' "${!host_var:-}"
}

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
  local ssh_host; ssh_host=$(graft_ssh_host "$alias_lc")
  if [ -n "$ssh_host" ]; then
    run_or_echo ssh -- "$ssh_host" "mkdir -p $(sq "$dest_dir")"
    if [ "$mode" = "--keep-existing" ]; then
      run_or_echo rsync -avz -s --ignore-existing "${host_src_dir%/}/" "${ssh_host}:${dest_dir%/}/"
    else
      run_or_echo rsync -avz -s "${host_src_dir%/}/" "${ssh_host}:${dest_dir%/}/"
    fi
    return
  fi
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
# a single file. Every real (non-mocked) caller today pushes onto B: the
# mapping mu-plugin, the media-import and content-remap PHP libraries, and
# the id-remap/domain-remap JSON payloads.
graft_push_file() {
  local alias_lc="$1" host_file="$2" dest_dir="$3" dest_name="$4"
  local ssh_host; ssh_host=$(graft_ssh_host "$alias_lc")
  if [ -n "$ssh_host" ]; then
    run_or_echo ssh -- "$ssh_host" "mkdir -p $(sq "$dest_dir")"
    run_or_echo rsync -avz -s "$host_file" "${ssh_host}:${dest_dir}/${dest_name}"
    return
  fi
  local prefix; prefix=$(graft_local_prefix "$alias_lc")
  if [ -n "$prefix" ]; then
    run_or_echo bash -c "${prefix} mkdir -p '${dest_dir}' && ${prefix} tee '${dest_dir}/${dest_name}' >/dev/null < '${host_file}'"
  else
    run_or_echo mkdir -p "$dest_dir"
    run_or_echo rsync -avz "$host_file" "${dest_dir}/${dest_name}"
  fi
}

# graft_remove_file <alias> <path_on_alias> — remove a single file on A/B
# (the mapping mu-plugin's own removal, and the media-import/content-remap
# libraries' and id-remap/domain-remap payloads' own cleanup, right after
# graft_push_file above put them there).
graft_remove_file() {
  local alias_lc="$1" path="$2"
  local ssh_host; ssh_host=$(graft_ssh_host "$alias_lc")
  if [ -n "$ssh_host" ]; then
    run_or_echo ssh -- "$ssh_host" "rm -f $(sq "$path")"
    return
  fi
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

  # graft_push_dir itself now handles all three shapes (ssh-remote,
  # wrapped-local, bare-local) — see its own header comment.
  graft_push_dir b "$staging" "${SITE_B_WP_PATH}/${rel_dir}"
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
# Every step below guards its own exit status with `|| return $?` rather
# than relying on `set -e`. That is not belt-and-braces, it is required:
# phase_graft's call site puts this function on the LHS of a `||` (so it can
# print an operator message about B's state on failure), and bash disables
# -e for the whole of a function invoked there, INCLUDING its body. Without
# these guards a mid-body failure -- the pull from A dying on a network drop
# or a full disk (rsync exit 23) -- fell through to the push, which happily
# shipped an EMPTY staging tree to B, returned 0, and let phase_graft mark
# the step done and carry on importing against a B whose media never
# arrived. Measured: rc 23 before that call-site change, rc 0 after, message
# never reached. That is issue #36's own failure mode re-entering by another
# door, and "never report success that was not earned" broken by the very
# commit meant to improve this failure path. Caught in review of PR #90.
#
# `return $?` normalizes nothing on purpose except through phase_graft's own
# 1/2 contract at the call site; rsync's 23 propagating as a non-zero is
# what matters here.
graft_media_sync() {
  local run_dir="$1"
  local staging="${run_dir}/media-staging"
  mkdir -p "$staging" || return $?
  log_info "pulling A's media to the orchestrator..."
  if [ -n "${SITE_A_SSH_HOST:-}" ]; then
    run_or_echo rsync -avz "${SITE_A_SSH_HOST}:${SITE_A_WP_PATH}/wp-content/uploads/" "${staging}/" || return $?
  else
    graft_pull_dir a "${SITE_A_WP_PATH}/wp-content/uploads" "$staging" || return $?
  fi
  log_info "pushing media to B (never overwriting existing files)..."
  # graft_push_dir itself now handles all three shapes (ssh-remote,
  # wrapped-local, bare-local) — see its own header comment.
  graft_push_dir b "$staging" "${SITE_B_WP_PATH}/wp-content/uploads" --keep-existing || return $?
}

graft_deploy_mu_plugin() {
  local mu_dir="${SITE_B_WP_PATH}/wp-content/mu-plugins"
  local src="${SITEGRAFT_ROOT}/mu-plugins/sitegraft-id-mapper.php"
  # graft_push_file itself now handles all three shapes (ssh-remote,
  # wrapped-local, bare-local) — see its own header comment.
  graft_push_file b "$src" "$mu_dir" "sitegraft-id-mapper.php"
}

# Recommended (Marcel's nightshift mandate): callers wrap this in a trap so
# the mu-plugin is removed even when graft fails partway through — see
# phase_graft's own trap below. Leaving a temporary logging mu-plugin behind
# on a failed run would be a silent, ongoing side effect on B.
graft_remove_mu_plugin() {
  local target="${SITE_B_WP_PATH}/wp-content/mu-plugins/sitegraft-id-mapper.php"
  # graft_remove_file itself now handles all three shapes (ssh-remote,
  # wrapped-local, bare-local) — see its own header comment.
  graft_remove_file b "$target"
}

# --- Task 4.2: WXR export/import, integrity gate, importer provisioning ---

graft_integrity_gate() {
  local file="$1" allowed_json="$2"
  [ -s "$file" ] || { log_error "WXR file is empty: ${file}"; return 1; }
  grep -q '<wp:wxr_version>' "$file" || { log_error "no <wp:wxr_version> marker in: ${file}"; return 1; }
  # A cheap, line-oriented LOWER BOUND, not an exact count (issue #72 --
  # see this function's own header below for the full story): `grep -c`
  # counts matching LINES, and two <item>s sharing one physical line (the
  # exact shape issue #70/#72 both exist because of) still count as one
  # line here. Kept as-is, deliberately: it is used ONLY for the "does at
  # least one <item> exist at all" fast-fail immediately below (still
  # correct for that purpose -- a real <item> anywhere in the file always
  # makes at least one line match) and for a diagnostic number in the
  # fail-closed message further down. NEVER for the actual security
  # decision, which now runs entirely through the structural parser below
  # -- unlike the post_type extraction this same imprecision used to also
  # drive, which is exactly what issue #72 closes.
  local item_count; item_count=$(grep -c '<item>' "$file" || true)
  [ "$item_count" -ge 1 ] || { log_error "no <item> found in: ${file}"; return 1; }

  # issue #72: this used to be its own `grep -o '<wp:post_type>.*</wp:post_type>'
  # | sed` scan -- a THIRD independent reader of the same WXR file format
  # in this codebase (graft_verify_import_completeness, lib/graft.sh, and
  # lib/php/wxr-content-functions.php's own two production callers already
  # made two; this made three), and a greedy one: `grep -o` matches
  # per LINE, so two <item>s sharing one physical line (exactly
  # graft_verify_import_completeness's own former BLOCKER-2 shape, closed
  # by switching THAT function to the driver below) let `.*` span across
  # BOTH items' tags, extracting one garbled "type" string covering
  # everything between the FIRST `<wp:post_type>` and the LAST
  # `</wp:post_type>` on the line. Not theoretical -- measured live: a
  # manifest allowing only "page" against two real, valid, allowed
  # `<item>` elements (each a genuine `<wp:post_type>page</wp:post_type>`)
  # aborted the whole graft with "WXR contains post_type(s) outside the
  # manifest allowlist: page</item><item><wp:post_id>102</wp:post_id>page"
  # -- BEFORE graft_verify_import_completeness's own gate, several steps
  # later in phase_graft, ever got a chance to run, for a reason that had
  # nothing to do with what the WXR actually did or didn't contain.
  #
  # Replaced with lib/php/wxr-item-ids-cli.php -- the SAME structural,
  # namespace-aware driver graft_verify_import_completeness already uses
  # (issue #53/#54's own fix-pack). One WXR reader for "what post_types
  # does this file's items carry" now, in the one place that still needed
  # its own answer to it, not three that can silently disagree on the same
  # bytes -- see that driver's own header for why this specific sentence
  # is finally true (an earlier draft of it, in this same fix-pack, said
  # so before this function was fixed, and was wrong until now).
  # -d display_errors=stderr (review — reviewer's own BLOCKER, measured on
  # this machine): sitegraft does not control the orchestrator's own
  # php.ini, and `display_errors => STDOUT` is a common default -- ANY
  # startup warning/notice/deprecation lands ahead of the driver's real
  # NDJSON on stdout, silently corrupting $ndjson below. Belt: reduce the
  # noise at its source.
  local ndjson rc stderr_file tmp_dir
  tmp_dir=$(sitegraft_mktemp_dir)
  stderr_file="${tmp_dir}/stderr"
  ndjson=$(php -d display_errors=stderr "${SITEGRAFT_ROOT}/lib/php/wxr-item-ids-cli.php" "$file" 2>"$stderr_file") && rc=0 || rc=$?
  local err_text=""
  [ -s "$stderr_file" ] && err_text=$(cat "$stderr_file")
  if [ "$rc" -ne 0 ]; then
    log_error "could not parse WXR file to check its post_type(s) against the manifest allowlist: ${file}: ${err_text}"
    return 1
  fi

  # Suspenders (review, reviewer's own BLOCKER, MINOR-1): `-d
  # display_errors=stderr` above cannot silence a wrapper's own banner or
  # any other noise this codebase does not control, so $ndjson is
  # validated as genuinely well-formed NDJSON -- via `jq -s` (slurp), same
  # pattern lib/verify.sh's own _verify_wxr_items_remapped already uses
  # for the identical php-driver-output-trust problem (issue #52's own
  # guard) -- before anything below is allowed to trust it. Measured, not
  # theoretical: the previous version parsed $ndjson with `jq -R -s -c
  # 'split("\n") | map(... | fromjson ...)'`, which does not fail cleanly
  # on one bad line -- a single stray non-JSON line made `found_types`
  # become an EMPTY STRING (not the empty array `[]`), which then made
  # BOTH the "zero found" fail-closed check below AND the leak comparison
  # further down fail for the WRONG reason: `[ "" = "0" ]` is false (the
  # fail-closed guard is skipped), then the leak comparison's own
  # `[ "" != "0" ]` happens to read true anyway (MINOR-1) -- so this gate
  # still aborted, by accident, with a message describing a leaked
  # post_type that never existed, plus raw `jq: error` text on the
  # operator's terminal. Explicit validation replaces that accident with
  # an honest failure and message.
  local result
  result=$(printf '%s' "$ndjson" | jq -s -c '.' 2>/dev/null)
  if [ -z "$result" ] || ! echo "$result" | jq -e . >/dev/null 2>&1; then
    log_error "the WXR integrity-check driver did not return valid NDJSON for ${file}: ${ndjson}"
    return 1
  fi

  local found_types
  found_types=$(echo "$result" | jq -c '[.[].post_type] | unique')

  # Fail CLOSED, not open: an `<item>` count >=1 (checked above) with ZERO
  # post_type actually extracted means the driver genuinely found no
  # well-formed <item> at all (missing wp:post_id alongside wp:post_type --
  # see lib/php/wxr-content-functions.php's own _sitegraft_wxr_item_
  # from_node, which requires BOTH before recognizing an item), or hit a
  # future export-format change this parser doesn't understand yet --
  # exactly the silent "leaked is always []" failure mode commit 770e4c1's
  # jq fix (below) exists to prevent, just one layer up (a parsing gap
  # instead of a comparison-logic gap). This guard predates issue #72's own
  # fix and is UNCHANGED by it on purpose -- moving to a different
  # extraction mechanism must not lose the fail-closed behavior that was
  # the whole point of BLOCKER-1 in the first place. Refusing here means a
  # future export-format change this driver doesn't understand aborts
  # loudly instead of this gate quietly rubber-stamping everything.
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
  local allowed_plus_skipped leaked
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

# graft_verify_import_completeness <run_dir> <wxr_post_types_csv> — issue
# #53. wordpress-importer INSERTS, never updates. Verified directly against
# the shipped version (0.9.5, what `wp plugin install wordpress-importer`
# pulls from wp.org — fetched from
# https://plugins.svn.wordpress.org/wordpress-importer/tags/0.9.5/class-wp-import.php
# and cross-checked against wp-cli/import-command's own Import_Command.php,
# which wraps it): WP_Import::process_posts() runs WordPress's own
# post_exists( post_title, '', post_date, post_type ) for every item; on a
# match it prints "<type> "<title>" already exists.", sets
# $this->processed_posts[old_id] = $existing_post_id in PHP-process memory
# ONLY, and moves on — it never calls wp_insert_post and never fires
# wp_import_insert_post for that item, so the mapping mu-plugin
# (mu-plugins/sitegraft-id-mapper.php, hooked on exactly that action) logs
# no row for it at all. There is also no separate "this was skipped" signal
# a caller could hook instead: the similarly-named wp_import_post_exists
# action fires only from process_posts()'s UNRELATED "invalid post_type"
# branch, never from the already-exists branch.
#
# CORRECTION (issue #58, filed against this PR's own first draft — the
# error being corrected here never shipped on `main`): the two avenues
# issue #53 itself names for instead COMPLETING the map for a skipped item
# do not work —
#   - wp_import_post_data_raw fires for every item, but before the skip
#     decision is made and with no post-existence information at all — it
#     cannot distinguish a skip from a normal insert.
#   - $this->processed_posts (which DOES carry old_id -> existing_post_id
#     for a skipped item) is declared `public` (class-wp-import.php:35, NOT
#     "private-in-effect" as an earlier draft of this comment claimed), and
#     wp-cli's own Import_Command DOES read it
#     ($this->processed_posts += $wp_import->processed_posts;,
#     Import_Command.php:353) — but only to accumulate an internal count,
#     never to print or hand old_id/new_id pairs back to the CLI
#     invocation's caller. The conclusion (nothing surfaces it usably from
#     here) is right; the reasoning an earlier draft gave for it (that the
#     property is inaccessible) was not.
# That earlier draft generalized from those two to "no completion path
# exists at all", which is FALSE: process_posts() applies a THIRD,
# documented filter immediately before the skip decision —
# `apply_filters( 'wp_import_existing_post', $post_exists, $post )`,
# `@since 0.6.2` — and its two arguments are exactly the old->new pair a
# remap needs: $post_exists is B's existing post ID, $post['post_id'] is
# A's old ID. wp-cli does NOT occupy this filter (Import_Command::
# add_wxr_filters() hooks wp_import_posts, wp_import_post_comments and
# wp_import_post_data_raw — not this one), and sitegraft already has an
# mu-plugin loaded on B for the entire duration of the import
# (mu-plugins/sitegraft-id-mapper.php) — somewhere to hook it from already
# exists. Three lines in that mu-plugin would both surface the skip AND
# complete the map for it.
#
# This does NOT change what issue #53 itself requires: ADR 0008 asks for a
# loud failure on a skipped item, and that stays correct regardless —
# silently completing the map would hide a real title/date/type collision
# the operator needs to know about, not make it safe to ignore. What it
# changes is scope: `wp_import_existing_post` is the old->new pairing
# signal ADR 0008 step 2 (the in_place write path) will need, and building
# that hookup is real, separable work — tracked as issue #58, not done
# here. This function keeps failing loudly, on purpose, until step 2 exists
# to consume the pairing instead.
#
# What this checks, and deliberately NOT via wp-cli's own log text: WP-CLI's
# import-command DOES hook wp_import_post_data_raw to print a per-item
# "Processing post #<id> (...)" progress line (Import_Command::
# add_wxr_filters(), same source), which would make a text-based check
# possible in principle — but that text is one wp-cli version's choice of
# wording, wp-cli's global --quiet suppresses WP_CLI::log entirely (silently
# defeating a check built on it), and the already-exists message itself
# passes through WordPress's own __() (wordpress-importer ships its own
# translations) — parsing it would make this check's correctness depend on
# the operator's locale. None of that data is trustworthy input for a
# security/correctness gate.
#
# Instead this cross-references two things this codebase already computes
# from STRUCTURE: the old post_ids actually present in the WXR this run
# staged for import, against the old_ids that actually landed in
# id-map.tsv (written by the mu-plugin's own hook, fetched by
# graft_fetch_id_map just before this runs). `attachment` is excluded from
# "expected" by name, for the identical reason graft_integrity_gate already
# exempts it: WordPress's own exporter unions every migrated post's
# attachments into this WXR regardless of --post_type, graft_import_wxr
# passes --skip=attachment, and graft_import_attachments migrates them
# through a completely separate path that writes its OWN id-map.tsv rows
# (tagged "attachment") outside wordpress-importer entirely — those items
# were never supposed to insert through this path, so their absence from a
# wordpress-importer-sourced row is not the defect this function exists to
# catch. `nav_menu_item` is excluded the same way, by name, alongside it
# (review, MINOR-2): process_posts() (0.9.5, line ~782) special-cases it
# BEFORE the generic insert path, dispatching to process_menu_item() ->
# wp_update_nav_menu_item() instead of wp_insert_post() — wp_import_
# insert_post is never fired for a nav_menu_item at all, imported or not,
# so the mu-plugin logs no row for one regardless of success. Nothing in
# this codebase migrates nav_menu_item today (no module declares it — see
# modules/menus.sh's own absence), so this exemption is currently inert;
# it exists so that the day a menus module ships, every menu item does not
# read as a false "skipped".
#
# The WXR itself is parsed by lib/php/wxr-item-ids-cli.php (`php`, one
# `wp_remote`-free local invocation, same "run entirely on the
# orchestrator, no round-trip to A or B" shape graft_integrity_gate's own
# checks already have) — NOT the line-oriented awk scan an earlier version
# of this function used. That awk scan was itself BOTH review blockers in
# this fix-pack: it read whatever text happened to sit on a line matching
# `/<wp:post_id>/` or `/<wp:post_type>/`, with no notion of "this line is
# actually inside a DIFFERENT element's own CDATA body" (a post_content
# value containing the literal text `<wp:post_type>attachment</wp:post_type>`
# silently exempted that item, last-assignment-wins) or of a single item's
# OWN two tags sharing one physical line (demonstrated live, this fix-pack's
# own test fixture — whether wp-cli's REAL exporter routinely produces
# that specific shape is NOT independently verified here; every `gsub` ran
# against the WHOLE line regardless of cause and clobbered that item's own
# values with a garbled fragment of its own markup). XMLReader parses
# actual document STRUCTURE — an <item>'s own direct children, resolved by
# namespace URI — so neither shape is reachable here by construction; see
# lib/php/wxr-item-ids-cli.php's own header for the full accounting
# (including a REAL, confirmed structural gap this parser still has,
# tracked as issue #70 — not fixed in this file, see that header), and
# lib/php/wxr-content-functions.php's header for the streaming/entity-
# safety properties both callers of it now share.
#
# Three-valued (review, BLOCKER-B, added this fix-pack): 0 = genuinely
# complete, or nothing was ever expected; 1 = wordpress-importer skipped
# a real, present, parseable item (issue #53's own defect) — RETRYABLE,
# the WXR staged for this run is trustworthy and prune-then-reimport can
# fix it; 2 = this run's own staged data is not trustworthy right now (no
# .xml file where post_types were selected, or one present but unparseable)
# — NOT retryable the same way, since neither prune nor reimport can
# regenerate a missing/corrupt local file, and blindly running them anyway
# would delete B's already-migrated content for nothing. See phase_graft's
# own call site for how the two are handled differently.
graft_verify_import_completeness() {
  local run_dir="$1" wxr_post_types_csv="${2:-}"
  is_dry_run && return 0
  local staging="${run_dir}/export"
  local id_map_tsv="${run_dir}/id-map.tsv"

  local wxr_files=() f
  for f in "${staging}"/*.xml; do
    [ -e "$f" ] && wxr_files+=("$f")
  done
  if [ "${#wxr_files[@]}" -eq 0 ]; then
    # Two genuinely different situations share "no .xml file in staging",
    # and only $wxr_post_types_csv tells them apart (review, BLOCKER-1's
    # third manifestation): nothing was ever selected for a WXR import at
    # all (attachment-only, or an empty manifest — legitimate, matches
    # lib/verify.sh's own _verify_wxr_items_remapped guard for the
    # identical case) versus post_types WERE selected but the export this
    # run staged is missing right now (an interrupted run resumed past a
    # step that never actually produced its file, or the file was removed
    # from underneath this run) — which must fail loudly, not read as
    # "nothing to check". Called with no 2nd argument at all (a handful of
    # this function's own unit tests, and any future caller that
    # genuinely doesn't know), the ambiguity resolves to the SAFER of the
    # two only when that's also consistent with there being no work to do:
    # empty $wxr_post_types_csv, like an explicit "".
    if [ -n "$wxr_post_types_csv" ]; then
      # Returns 2, not 1 (review, BLOCKER-B): a missing export is a
      # DIFFERENT failure than issue #53's own "wordpress-importer skipped
      # an item" (which returns 1, below) — the WXR this run staged is
      # simply not there to check against anymore (an operator cleared
      # run_dir/export/*.xml between runs — a real run dir's largest
      # files — or an interrupted run resumed past a step that never
      # produced it). Reported mechanically: phase_graft's own MAJOR-3
      # marker-clearing (its call site of this function) treated EVERY
      # nonzero return the same, and cleared import_attachments.done/
      # import.done/fetch_id_map.done here too — a resume then found
      # graft_safety_step_done false, reran graft_prune_previous_run
      # (deleting every post this tool had migrated onto B, for real),
      # and STILL failed afterward, because graft.export.done was never
      # touched, so the (now-empty) export step stayed marked done and
      # never regenerated the file this whole retry needed. Net effect: a
      # successfully migrated B gets its content destroyed by a resume
      # that could never have succeeded. A distinct return code lets the
      # caller refuse to run that retry at all instead of guessing from
      # this function's own return value alone.
      log_error "post_type(s) ${wxr_post_types_csv} were selected for migration but no WXR export was found under ${staging} to verify import completeness against — the export step never produced (or no longer has) a file here. Refusing to report success."
      return 2
    fi
    return 0
  fi

  # Temp files live under sitegraft_mktemp_dir (lib/core.sh), not under
  # $run_dir (review, NIT-2 — including the php driver's own stderr
  # capture just below, the other half of NIT-2 a previous pass at this
  # fix left under $run_dir): $run_dir is a long-lived, resumable run
  # directory an operator inspects between invocations, and a
  # `${run_dir}/.import-completeness-*` file was only ever cleaned up on
  # this function's own normal-return paths — an interruption (kill -9, a
  # crash) between its creation and that cleanup left it behind
  # indefinitely. sitegraft_mktemp_dir registers its directory in
  # SITEGRAFT_TMP_REGISTRY, which bin/sitegraft's own sitegraft_cleanup
  # EXIT trap sweeps on every exit, interrupted or not — this is that
  # mechanism's first production caller in this file.
  local tmp_dir; tmp_dir=$(sitegraft_mktemp_dir)

  # lib/php/wxr-item-ids-cli.php: one `php` invocation, NDJSON on stdout,
  # hard failure (never a silent empty result) the moment ANY listed file
  # is unreadable or fails to parse at all — see that file's own header.
  # stderr captured separately, same discipline lib/verify.sh's own
  # _verify_wxr_items_remapped uses for its identical php-driver call, for
  # the identical reason: stdout on success must never be contaminated by
  # a diagnostic line the driver also happened to print. A file that
  # fails to parse partway through a MULTI-file argv can still have
  # streamed real NDJSON to stdout for the file(s) before it (review,
  # MINOR-D — the driver's own header used to claim "NOTHING on stdout" on
  # any failure, which is not quite true of that specific case; corrected
  # there too) — harmless here specifically because $ndjson is never read
  # for real unless $rc is 0, checked immediately below.
  # -d display_errors=stderr (review — the reviewer's own BLOCKER,
  # measured on this machine): sitegraft does not control the
  # orchestrator's own php.ini, and `display_errors => STDOUT` is a common
  # default -- ANY startup warning/notice/deprecation (a stale PECL entry,
  # an auto_prepend_file, an Xdebug banner) lands ahead of the driver's
  # real NDJSON on stdout, silently corrupting $ndjson below. Belt: reduce
  # the noise at its source.
  local ndjson rc stderr_file
  stderr_file="${tmp_dir}/stderr"
  ndjson=$(php -d display_errors=stderr "${SITEGRAFT_ROOT}/lib/php/wxr-item-ids-cli.php" "${wxr_files[@]}" 2>"$stderr_file") && rc=0 || rc=$?
  local err_text=""
  [ -s "$stderr_file" ] && err_text=$(cat "$stderr_file")
  if [ "$rc" -ne 0 ]; then
    # Also 2, not 1 (review, BLOCKER-B) — same reasoning as the missing-
    # file branch above: a WXR this run staged that fails to parse at all
    # is exactly as untrustworthy as one that is not there, and a caller
    # must not attempt the same prune-and-reimport retry issue #53's own
    # skipped-item failure (still 1, below) invites.
    # Enriched (review — coordinator's own harness run): the driver's own
    # $err_text already names the specific offending file and, for a
    # count-mismatch, the exact <item>-vs-parsed numbers (see lib/php/
    # wxr-item-ids-cli.php's own header). What it can't tell an operator is
    # WHY that file is there -- "corrupt" implies THIS run's own export
    # step produced something bad, but the identical symptom follows from
    # ANY .xml under ${staging} this run didn't produce at all (a
    # hand-added file, a leftover test artifact, anything left behind by
    # an earlier experiment against this same run_dir) -- this glob has no
    # way to tell "ours" from "not ours" apart, by design (see this
    # function's own header on why item-by-item structural parsing, not
    # provenance tracking, is the fix issue #73 chose). Naming that
    # explicitly here, not just at phase_graft's own wrapping message
    # (BLOCKER-B), matters because `sitegraft verify` calls this function
    # directly too, without that wrapper ever running.
    log_error "could not parse the staged WXR export to verify import completeness: ${err_text} — if every .xml under ${staging} was written by THIS run's own export step, that points at real corruption; if anything else was ever added to that directory (by hand, or left over from an earlier run/experiment against this same run_dir), removing it is the fix instead."
    return 2
  fi

  # Suspenders (review, reviewer's own BLOCKER — the same finding applies
  # here as at graft_integrity_gate's identical call, see that function's
  # own comment for the full mechanism and measurement): `-d
  # display_errors=stderr` above cannot silence a wrapper's own banner or
  # any other noise this codebase does not control, so $ndjson is
  # validated as genuinely well-formed NDJSON — via `jq -s` (slurp), same
  # pattern lib/verify.sh's own _verify_wxr_items_remapped already uses
  # for the identical php-driver-output-trust problem (issue #52's own
  # guard) — before anything below is allowed to trust it. Without this,
  # a single stray non-JSON line made `expected_tmp` end up EMPTY
  # (`printf | jq -r 'select(...)'` on a line `fromjson`/parsing can't
  # handle simply produces nothing for it), so `expected_count` read 0 and
  # this function returned 0 — "nothing was expected, PASS" — for a run
  # that had staged real items and never actually verified a single one of
  # them. `rc=2`, matching the "this run's own data is not trustworthy
  # right now" contract this function's own header documents, not `rc=1`
  # ("wordpress-importer skipped a real item") — a driver/toolchain output
  # failure is not that.
  local result
  result=$(printf '%s' "$ndjson" | jq -s -c '.' 2>/dev/null)
  if [ -z "$result" ] || ! echo "$result" | jq -e . >/dev/null 2>&1; then
    log_error "the WXR completeness-check driver did not return valid NDJSON: ${ndjson}"
    return 2
  fi

  local expected_tmp="${tmp_dir}/expected.tsv"
  echo "$result" | jq -r '
    .[] | select(.post_type != "attachment" and .post_type != "nav_menu_item")
    | "\(.post_id)\t\(.post_type)"
  ' > "$expected_tmp"

  local expected_count
  expected_count=$(wc -l < "$expected_tmp" | tr -d ' ')
  if [ "$expected_count" -eq 0 ]; then
    return 0
  fi

  # old_ids that actually got a REAL insert through wordpress-importer:
  # rows the mu-plugin logged (3rd column is a real post_type — attachment
  # rows come from graft_import_attachments, never the mu-plugin; term rows
  # are tagged "term:<name>" and are a different ID space entirely). Written
  # to its own temp file, not passed via `awk -v` — BSD/macOS awk (verified
  # live: the awk this reaches on macOS by default) rejects a `-v` value
  # containing a literal newline outright ("newline in string"), which a
  # multi-row id-map with more than one actual id always is. id-map.tsv is
  # this codebase's OWN generated TSV, never untrusted third-party markup —
  # line-oriented awk is the right tool for it, unlike the WXR file above.
  local actual_tmp="${tmp_dir}/actual.tsv"
  : > "$actual_tmp"
  [ -s "$id_map_tsv" ] && awk -F'\t' '$3 != "attachment" && $3 !~ /^term:/ {print $1}' "$id_map_tsv" > "$actual_tmp"

  # NOT the classic `awk 'NR==FNR{...}'` two-file join — verified live: when
  # the FIRST file (actual_tmp) has genuinely zero records (a fresh graft
  # with no id-map.tsv at all yet, exactly the case an interrupted import
  # produces), NR and FNR both start at 1 on the very first line of the
  # SECOND file too, so `NR==FNR` reads true there as well and every
  # "expected" row is wrongly swallowed as if it were an "actual" row —
  # silently reporting a run that imported NOTHING as complete, the exact
  # failure this function exists to catch. A plain per-row `grep -Fx`
  # lookup has no such edge case.
  local missing_tmp="${tmp_dir}/missing.tsv"
  : > "$missing_tmp"
  local eid etype
  while IFS=$'\t' read -r eid etype <&3; do
    [ -n "$eid" ] || continue
    grep -qxF "$eid" "$actual_tmp" 2>/dev/null || printf '%s\t%s\n' "$eid" "$etype" >> "$missing_tmp"
  done 3< "$expected_tmp"

  local missing
  missing=$(cat "$missing_tmp")

  [ -n "$missing" ] || return 0

  local missing_count
  missing_count=$(printf '%s\n' "$missing" | wc -l | tr -d ' ')
  local missing_sample missing_suffix
  missing_sample=$(printf '%s\n' "$missing" | head -20 | awk -F'\t' '{print $2"#"$1}' | paste -sd, -)
  missing_suffix=""
  [ "$missing_count" -gt 20 ] && missing_suffix=" (first 20 of ${missing_count} shown)"
  log_error "wordpress-importer reported ${missing_count} of ${expected_count} item(s) as already existing on B (or otherwise never inserted) instead of migrating A's content: ${missing_sample}${missing_suffix} — per ADR 0008, every downstream remap (attachment ids inside content, featured images, page_on_front, module post_import hooks) has silently done nothing for these. Refusing to report success."
  return 1
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

# graft_safety_step_done <run_dir> <safety_step> <consumer_step...> — issue
# #54: a "safety" step (prune today; clean and the option-3 pairing once
# ADR 0008's step-2 paths land) exists purely to make one or more LATER
# "consumer" steps safe to run — prune deletes every post this tool
# previously left on B (marked _sitegraft_source_id) so the WXR re-import
# that follows never collides with its own past output. Its own marker
# being present is NOT sufficient grounds to skip it on resume: that only
# tells you prune ran once, not that its guarantee still holds for whatever
# the consumer step is about to attempt now.
#
# Concretely, this is issue #54: `graft_prune_previous_run` runs before
# `graft_import_wxr` and, before this function existed, was gated by
# `graft_step_done` exactly like every other step. If prune completes and
# import is then interrupted partway, a resume sees prune's raw marker as
# "done" and skips straight to re-running import — against a B that now
# already holds the partial import's own posts, which collide with
# themselves on the second attempt (wordpress-importer's `post_exists()`
# reports them "already exists" — see graft_verify_import_completeness's
# header comment for why that's exactly issue #53's defect, reproduced
# inside a single interrupted run). Rerunning prune first, every time
# import has not yet actually completed, closes that: prune deletes the
# partial run's own posts (it can't distinguish "leftover from a previous
# separate graft" from "leftover from this run's own earlier attempt" —
# both carry the identical _sitegraft_source_id meta, and for THIS purpose
# that's exactly the right thing to delete), and graft_prune_previous_run's
# own reset of B's mapping log (see that function's header) discards the
# now-orphaned id-map rows those deleted posts had already logged, so
# id-map.tsv can never end up holding two rows for the same old_id — one
# live, one pointing at a post prune just removed.
#
# Three shapes were possible here (issue #54 asks for the choice to be
# argued, not just picked): (a) explicitly DELETE/invalidate prune's marker
# file the moment import fails, e.g. from _graft_exit_trap, mirroring how
# that trap already clears the mu-plugin markers on an interrupted run; (b)
# merge prune and import under one shared marker so there is only ever one
# boolean to ask; (c) keep both steps' own markers exactly as they are, and
# make the GATE itself express "prune is only truly done once whatever it
# protects has also completed" — what this function does. (c) was chosen
# over (a) because invalidating on the way OUT (in an EXIT trap) only
# covers the graceful-failure path; a `kill -9`, a lost SSH connection, or
# the operator's laptop losing power mid-import never runs any trap at
# all, and a marker that was never invalidated would silently reproduce
# the exact bug this closes. Checking the dependency on the way IN, every
# time, working "is it still safe *right now*" — has no such gap: it needs
# nothing to have run cleanly on the way out. (c) was chosen over (b)
# because collapsing two steps that log and are reasoned about separately
# into one marker would lose the per-step "which one, of possibly several,
# actually ran" visibility the rest of this file's `graft_step_done`
# convention gives every other step — and it does not generalize as
# cleanly: ADR 0008's step 2 needs ONE safety step (prune, or clean+pairing
# together) to gate potentially several later consumers (import, and
# eventually the in-place writer), which a single merged marker can't
# express but a small list of consumer names can.
graft_safety_step_done() {
  local run_dir="$1" safety_step="$2"; shift 2
  graft_step_done "$run_dir" "$safety_step" || return 1
  local consumer
  for consumer in "$@"; do
    graft_step_done "$run_dir" "$consumer" || return 1
  done
  return 0
}

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

  # Issue #73, belt-and-braces (MAJOR-1, second review round): this
  # function had NO guard of its own before this fix-pack — it received
  # the same domain_from/domain_to pair as graft_search_replace_domain,
  # unchecked. phase_graft (below) now runs
  # graft_domain_remap_unusable_reason unconditionally before any
  # consumer, which is the real fix (see phase_graft's own comment); this
  # is the second line of defense for any future direct call to this
  # function that skips phase_graft.
  if [ -n "$domain_from" ]; then
    local options_unusable_reason
    options_unusable_reason=$(graft_domain_remap_unusable_reason "$domain_from" "$domain_to")
    if [ -n "$options_unusable_reason" ]; then
      log_error "graft: refusing to migrate options — ${options_unusable_reason}. Pushing a migrated option's value through this remap anyway would write a broken domain string into B's LIVE options and report success (issue #73). Rebuild the manifest: set SITE_A_URL/SITE_B_URL in the profile to each site's real public domain and re-run 'sitegraft plan' -- plan_defaults reads those in PREFERENCE to scan's own home_url guess, which a proxied/tunneled/local-dev site (DDEV's own *.ddev.site, an SSH tunnel, a reverse proxy) can get wrong in a way no re-scan fixes. Failing that: re-run 'sitegraft scan' if a value is genuinely missing, or hand-edit scan-a.json/scan-b.json's home_url yourself if scan ran cleanly but simply recorded the wrong domain."
      return 1
    fi
  fi

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
    _graft_migrate_one_option_key "$run_dir" "$key" "$domain_from" "$domain_to" || return 1
  done 3<<< "$keys"
}

# _graft_migrate_one_option_key <run_dir> <key> [domain_from] [domain_to] —
# the actual per-key body graft_migrate_options ran inline until issue
# #16's fix-pack pulled it out. Now shared with
# graft_migrate_post_type_defining_options (just below), which needs the
# EXACT same guarded behaviour — the "A has no such key, don't blank B"
# check (N3, third review round), the domain-remap of the option's own
# VALUE (MAJOR-2 fix-pack, design doc §9.4), and the page_on_front/
# page_for_posts redirect to core_wp_post_import (§9.3) — for the handful
# of keys it pre-migrates before the WXR import runs. One function means
# neither call site can drift from the other's guards; the caller is
# still the one responsible for checking graft_domain_remap_unusable_reason
# ONCE before its own loop starts (issue #73) — this function does not
# repeat that check per key.
#
# Returns 1 only for a key shape that cannot be migrated at all (comma or
# whitespace — see the case block below). "A has no such key" is a
# legitimate, logged skip, not a failure — it returns 0.
_graft_migrate_one_option_key() {
  local run_dir="$1" key="$2" domain_from="${3:-}" domain_to="${4:-}"
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
    return 0
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
    page_on_front|page_for_posts) return 0 ;; # remapped by core_wp_post_import, §9.3
  esac
  run_or_echo wp_remote b option update "$key" "$value" --format=json
}

# graft_migrate_post_type_defining_options <run_dir> <manifest>
# [domain_from] [domain_to] — issue #16's actual fix.
#
# Migrating an option that DEFINES a post type (etch_cpts, for a module
# like Etch that registers post types dynamically from its own settings)
# is only half the job if it lands on B no earlier than
# graft_migrate_options does — which runs AFTER graft_import_wxr. B's
# WordPress never re-boots between "the option arrives" and "wp import
# reads the WXR", so the type stays unregistered for the entire import,
# wordpress-importer treats every post of it as belonging to an unknown
# type, and issue #53's completeness gate (the only reason this was ever
# NOTICED — before it existed, `verify` reported PASS on a partial import)
# is what actually catches the resulting skip.
#
# The fix is ordering, not content selection (issue #16's OWN dynamic
# post-type selection, etch_post_types_dynamic, already worked correctly —
# see that function's own header). Called from phase_graft BEFORE
# graft_import_wxr, this migrates ONLY the option keys a module names via
# its own optional <mod>_post_type_defining_option_keys() hook (etch.sh's
# own comment on that function has the full contract) — never a module's
# entire option_keys claim, and never by guessing from a key's name. Every
# key it touches goes through _graft_migrate_one_option_key, so it is
# bound by the identical guards graft_migrate_options itself enforces:
# the #73 domain-remap usability gate (checked once, below, before this
# function's own loop — same discipline graft_migrate_options uses before
# ITS loop), the "A has no such key" skip, and the domain rewrite of the
# option's own value. graft_migrate_options still runs this same key
# again later, as always — writing an identical value twice is a
# harmless no-op, and keeping ONE post-import pass that migrates every
# selected option key (rather than subtracting the pre-migrated ones from
# it) means there is only ever one place that decides "is this option
# selected", not two that could disagree.
#
# A key a module names here that plan's operator deselected (the option
# is not actually in this module's manifest.migrate[mod].option_keys) is
# skipped with a note, not an error — deselecting the option while
# keeping the post type selected is the operator's own call, and issue
# #53's completeness gate still fails loud if that leaves the type
# unregistered and its content unimportable, exactly as it would for any
# other cause of the same failure.
graft_migrate_post_type_defining_options() {
  local run_dir="$1" manifest="$2" domain_from="${3:-}" domain_to="${4:-}"

  # Same belt-and-braces reasoning as graft_migrate_options' own guard
  # just above: phase_graft already runs graft_verify_domain_remap_usable
  # unconditionally before this function is ever called, but a future
  # direct call that skips phase_graft must not be able to bypass it.
  if [ -n "$domain_from" ]; then
    local options_unusable_reason
    options_unusable_reason=$(graft_domain_remap_unusable_reason "$domain_from" "$domain_to")
    if [ -n "$options_unusable_reason" ]; then
      log_error "graft: refusing to pre-migrate post-type-defining options — ${options_unusable_reason}. Pushing a migrated option's value through this remap anyway would write a broken domain string into B's LIVE options and report success (issue #73). Rebuild the manifest: set SITE_A_URL/SITE_B_URL in the profile to each site's real public domain and re-run 'sitegraft plan' -- plan_defaults reads those in PREFERENCE to scan's own home_url guess, which a proxied/tunneled/local-dev site (DDEV's own *.ddev.site, an SSH tunnel, a reverse proxy) can get wrong in a way no re-scan fixes. Failing that: re-run 'sitegraft scan' if a value is genuinely missing, or hand-edit scan-a.json/scan-b.json's home_url yourself if scan ran cleanly but simply recorded the wrong domain."
      return 1
    fi
  fi

  local mods mod
  mods=$(echo "$manifest" | jq -r '.migrate | keys[]?')
  while IFS= read -r mod <&3; do
    [ -n "$mod" ] || continue
    module_has_fn "$mod" post_type_defining_option_keys || continue
    local declared_keys rc=0
    declared_keys=$("${mod}_post_type_defining_option_keys") || {
      rc=$?
      log_error "module '${mod}': ${mod}_post_type_defining_option_keys() exited ${rc} — refusing to continue without knowing which of its option keys must reach B before the WXR import runs (an error is not an empty list)"
      return 1
    }
    local selected_keys key
    selected_keys=$(echo "$manifest" | jq -r --arg m "$mod" '.migrate[$m].option_keys[]?')
    while IFS= read -r key <&4; do
      [ -n "$key" ] || continue
      # NIT (review, Viktor): `-- "$key"`, not a bare `"$key"` -- a key
      # beginning with a dash (e.g. "-v") would otherwise be read by grep
      # as one of ITS OWN flags rather than the pattern to match, and this
      # branch would always take the "not selected" path regardless of
      # what selected_keys actually contains -- an operator would be told
      # the plan never selected a key that, in fact, was right there.
      # Nothing upstream (module_selection, manifest_validate) rejects a
      # leading dash in an option-key name, so this cannot be assumed away.
      if printf '%s\n' "$selected_keys" | grep -qxF -- "$key"; then
        _graft_migrate_one_option_key "$run_dir" "$key" "$domain_from" "$domain_to" || return 1
      else
        log_info "graft: '${mod}' names '${key}' as post-type-defining, but this plan does not have it selected among that module's option keys — not pre-migrating it. If that leaves a post type this plan DOES migrate content for still unregistered on B, the import-completeness gate (issue #53) will fail loud rather than let the content vanish silently."
      fi
    done 4<<< "$declared_keys"
  done 3<<< "$mods"
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
# graft_domain_remap_unusable_reason <from> <to> — issue #73's BLOCKER-1
# fix (second review round): the SHARED definition of "this domain remap
# can never do anything", used by phase_graft's own top-level gate (see
# that function's own comment for why it needed one), by
# graft_search_replace_domain's belt-and-braces check just below, by
# graft_migrate_options' identical belt-and-braces check, and by
# verify_domain_absent (lib/verify.sh — `verify` loads this file too, see
# bin/sitegraft's `require_lib graft 4` under both the `graft` and
# `verify` cases). One definition, four call sites, so "unusable" cannot
# drift between them the way it drifted the first time: the original #73
# defect was two independently-blind guards (graft's own `-z` check,
# verify's own domain search) that each happened to miss the same
# "unknown" value for different reasons.
#
# Deliberately does NOT treat an empty `from` as unusable — every caller
# already special-cases "no domain configured for this migration" as
# legitimate with its own guard BEFORE ever reaching this function
# (graft_search_replace_domain's `[ -z "$from" ]`, graft_migrate_options'
# `[ -n "$domain_from" ]`, verify_domain_absent's `[ -n "$domain" ] ||
# return 0`, phase_graft's own `[ -n "$domain_from" ]` below) — this
# function is only ever consulted once a caller has decided `from` is
# meant to be a real value. `to` is checked unconditionally once that
# point is reached, because BLOCKER-1's actual reproduction is exactly a
# REAL, non-empty `from` paired with a broken `to` (A's scan succeeded,
# B's failed) — nothing upstream of this function guards `to` on its own,
# and the first version of this fix-pack didn't either.
graft_domain_remap_unusable_reason() {
  local from="$1" to="$2"
  if [ "$from" = "unknown" ]; then
    echo "from is the literal placeholder 'unknown' (scan could not determine A's home URL)"
  elif [ -z "$to" ]; then
    echo "to is empty (scan could not determine B's home URL)"
  elif [ "$to" = "unknown" ]; then
    echo "to is the literal placeholder 'unknown' (scan could not determine B's home URL)"
  elif [ "$from" = "$to" ]; then
    echo "from equals to ('${from}') — A and B's own recorded home URLs are identical, so this remap would replace the domain with itself"
  fi
}

# graft_verify_domain_remap_usable <domain_from> <domain_to> — MAJOR-1
# (issue #73, second review round): phase_graft's own top-level gate,
# pulled out into a named, independently-testable function rather than an
# inline `if` in phase_graft's body, but still called unconditionally from
# there (see phase_graft's own call site) — never from inside a
# `graft_step_done ... || { ... }` block, which is exactly what let the
# original in-function guards get skipped.
#
# The defect this closes: graft_search_replace_domain's own belt-and-
# braces check (below) sits INSIDE phase_graft's `graft_step_done
# "$run_dir" remap_domain || { ... }` gate — a run_dir carrying a
# `graft.remap_domain.done` marker from an EARLIER release (before that
# guard existed) skips the whole block, guard included, on resume, and
# never re-evaluates it. graft_migrate_options runs immediately after
# with the identical domain_from/domain_to and, before this fix, carried
# no guard of its own at all. Reproduced live against a real rc10 run
# directory: with only the in-function guards, graft_search_replace_domain's
# check never ran (its marker pre-dated this fix), and graft_migrate_options
# pushed A's literal domain string straight into B's live options,
# unrewritten, reporting success.
#
# Calling this ONCE, unconditionally, before either consumer, is what
# actually closes it — markers only ever skip the individual STEPS in
# phase_graft, never a plain function call in its body. The in-function
# checks inside graft_search_replace_domain/graft_migrate_options stay as
# belt-and-braces for any future direct call to either that doesn't go
# through phase_graft.
#
# Returns 0 (usable, or nothing to check) when domain_from is itself
# empty — "no domain configured for this migration" is the existing,
# legitimate no-op case every consumer already special-cases on its own
# (graft_search_replace_domain's `[ -z "$from" ]`, graft_migrate_options'
# `[ -n "$domain_from" ]`). Logs and returns 1 otherwise.
graft_verify_domain_remap_usable() {
  local domain_from="$1" domain_to="$2"
  [ -n "$domain_from" ] || return 0
  local reason
  reason=$(graft_domain_remap_unusable_reason "$domain_from" "$domain_to")
  if [ -n "$reason" ]; then
    log_error "graft: refusing to run at all — this manifest's domain remap is unusable (${reason}). Both the content search-replace and the migrated-options rewrite would otherwise write a broken domain string into B's live content/options and report success (issue #73). Rebuild the manifest: set SITE_A_URL/SITE_B_URL in the profile to each site's real public domain and re-run 'sitegraft plan' -- plan_defaults reads those in PREFERENCE to scan's own home_url guess, which a proxied/tunneled/local-dev site (DDEV's own *.ddev.site, an SSH tunnel, a reverse proxy) can get wrong in a way no re-scan fixes. Failing that: re-run 'sitegraft scan' if a value is genuinely missing, or hand-edit scan-a.json/scan-b.json's home_url yourself if scan ran cleanly but simply recorded the wrong domain."
    return 1
  fi
  return 0
}

graft_search_replace_domain() {
  local from="$1" to="$2" id_map_tsv="$3" run_dir="$4"
  if [ -z "$from" ] || [ ! -s "$id_map_tsv" ]; then
    return 0
  fi

  # Issue #73, belt-and-braces: phase_graft (below) now runs the SAME
  # graft_domain_remap_unusable_reason check unconditionally, before this
  # function is ever called — see phase_graft's own comment for why that
  # became necessary (MAJOR-1, second review round: a resume marker from
  # an older release could skip a check that lived only inside this
  # function). Kept here too, for any future direct call to this function
  # that doesn't go through phase_graft. Fails LOUD (log_error + return 1)
  # rather than the silent-success this issue is entirely about — a
  # caller that ignored this return value would be exactly the bug being
  # fixed, so it must not be possible to "succeed" here on an unusable
  # value.
  local unusable_reason
  unusable_reason=$(graft_domain_remap_unusable_reason "$from" "$to")
  if [ -n "$unusable_reason" ]; then
    log_error "graft: refusing the domain search-replace — ${unusable_reason}. This remap could never rewrite anything, and running it anyway would report success while some domain string stays wrong on every migrated page (issue #73). Rebuild the manifest: set SITE_A_URL/SITE_B_URL in the profile to each site's real public domain and re-run 'sitegraft plan' -- plan_defaults reads those in PREFERENCE to scan's own home_url guess, which a proxied/tunneled/local-dev site (DDEV's own *.ddev.site, an SSH tunnel, a reverse proxy) can get wrong in a way no re-scan fixes. Failing that: re-run 'sitegraft scan' if a value is genuinely missing, or hand-edit scan-a.json/scan-b.json's home_url yourself if scan ran cleanly but simply recorded the wrong domain."
    return 1
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

# graft_reset_id_map_log — removes B's cumulative mapping log
# (wp-content/sitegraft-id-map.log, written by the mu-plugin's
# wp_import_insert_post/wp_import_insert_term hooks). Nothing else ever
# clears this file: the mu-plugin only appends (FILE_APPEND — see its own
# header), and graft_fetch_id_map only ever reads it, never truncates it.
# That is fine as long as every post it has a row for still exists — but
# issue #54's fix makes graft_prune_previous_run rerun on a resume whenever
# import has not yet completed, and prune's whole job is deleting posts.
# Without this, a stale row for a post prune just deleted would survive in
# the log, get pulled into id-map.tsv by the eventual successful
# graft_fetch_id_map, and hand every downstream remap (attachment ids in
# content, featured images, page_on_front, module post_import hooks) an
# old_id -> new_id pair pointing at a post that no longer exists — the same
# class of silent, wrong mapping issue #53 exists to catch, reintroduced
# through prune's own resume path instead of the importer's. Called
# unconditionally from graft_prune_previous_run, including on a completely
# fresh run (where it is a harmless no-op — `rm -f` on a file that was
# never written), so there is exactly one code path to reason about rather
# than a "first run vs. resume" branch.
graft_reset_id_map_log() {
  local target="${SITE_B_WP_PATH}/wp-content/sitegraft-id-map.log"
  # graft_remove_file itself now handles all three shapes (ssh-remote,
  # wrapped-local, bare-local) — see its own header comment.
  graft_remove_file b "$target"
}

# design doc §11 "idempotent reimport": before importing, delete any post B already
# has from a previous sitegraft run (marked with _sitegraft_source_id), for the
# post_types in this run's manifest. Distinct from the optional `clean` step, which
# removes B's pre-existing ORIGINAL content instead.
#
# Issue #54: this is also the "safety step" graft_safety_step_done's own
# header comment describes — phase_graft now gates it on BOTH its own
# marker and import's, so a resume that finds import incomplete reruns
# this function again rather than trusting a marker written before import
# ever started. Safe to rerun: a post this run's own earlier, interrupted
# import attempt already inserted carries the identical
# _sitegraft_source_id meta as one from a genuinely separate prior graft,
# so the query below finds and removes it exactly the same way, clearing
# the way for a clean full reimport — paired with graft_reset_id_map_log
# above so the mapping log agrees with what is left on B afterward.
#
# `run_dir` (2nd arg, optional — every existing caller/test that only
# passes post_types_csv keeps working, with this half simply skipped) is
# review MAJOR-2's other half of the same fix: graft_reset_id_map_log above
# only ever clears B's own cumulative log, never ${run_dir}/id-map.tsv
# itself — the file graft_fetch_id_map has already appended INTO on any
# earlier pass through this run. graft_import_attachments REPLACES that
# file's attachment rows from B's own ground truth on every call (its own
# header comment), but nothing did the same for the mu-plugin-sourced
# (non-attachment) rows — so a prune rerun deleted the posts those rows
# pointed at, on B, while leaving the STALE rows themselves sitting in
# run_dir/id-map.tsv. Reachable exactly where issue #54's resume path lives:
# an operator (or a future automated retry — see MAJOR-3's fix, below in
# phase_graft) deletes graft.import.done by hand, or this fix-pack's own new
# marker-clearing on a verify failure does it automatically, and prune
# reruns against a run_dir that already has id-map.tsv rows from the FIRST
# attempt. Without this, graft_verify_import_completeness would then read
# those stale rows back as "already landed" for old_ids B just had deleted
# out from under it — passing a gate it exists to fail. Stripped to
# attachment-only rows (kept, since those are still valid — attachments are
# never in prune's post_types-driven deletion scope by row, they're
# separately re-verified/replaced by graft_import_attachments' own rerun),
# same is_dry_run discipline every other real mutation in this function
# already follows.
graft_prune_previous_run() {
  local post_types_csv="$1" run_dir="${2:-}"
  [ -n "$post_types_csv" ] || return 0
  graft_reset_id_map_log
  if [ -n "$run_dir" ] && [ -s "${run_dir}/id-map.tsv" ]; then
    is_dry_run || {
      local kept; kept=$(awk -F'\t' '$3 == "attachment"' "${run_dir}/id-map.tsv")
      # `[ -n "$kept" ]` guards against `printf '%s\n' ""` writing a single
      # empty LINE (a genuinely non-empty, 1-byte file) when this run_dir's
      # id-map.tsv held no attachment rows at all — a caller downstream
      # checking `[ -s id-map.tsv ]` (graft_verify_import_completeness,
      # this same function's next run) must still read "nothing here".
      if [ -n "$kept" ]; then
        printf '%s\n' "$kept" > "${run_dir}/id-map.tsv.tmp"
      else
        : > "${run_dir}/id-map.tsv.tmp"
      fi
      mv "${run_dir}/id-map.tsv.tmp" "${run_dir}/id-map.tsv"
    }
  fi
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
  # issue #52 fix-pack, review round 3 (MAJOR): create the record file
  # UNCONDITIONALLY (dry-run excepted, matching every other real write in
  # this codebase) before any hook runs, even if no hook ends up rewriting
  # a single post. Without this, the file's mere ABSENCE was ambiguous
  # between three cases lib/verify.sh's guard 1 could not tell apart: this
  # run genuinely predates the file (an upgrade path — graft ran under an
  # older sitegraft, verify runs later as its own separate phase against
  # that same run dir); a graft killed mid-hook (the append happens in
  # bash AFTER a hook's whole `wp eval` returns, so a kill during that
  # eval leaves posts already rewritten on B with nothing recorded); or
  # nothing was legitimately rewritten at all. Guard 1 read "file absent"
  # exactly like "file empty, hooks ran and rewrote nothing" and excluded
  # nothing — the first two cases then read a genuinely correct graft's
  # own module-rewritten content as a false HARD FAIL. Now: file present
  # (even empty) means "this run's hooks were given the chance to
  # record", file ABSENT means the run predates that guarantee and guard 1
  # reports INCOMPLETE instead of guessing — the same has()-style
  # distinction manifest.content_checksums_pre_graft's own absence already
  # gets. A resume that skips a partially-run hook can still lose some IDs
  # (case two, above) — that specific gap is issue #54's resume-ordering
  # problem in a narrower window, not something this file alone can close.
  is_dry_run || : >> "${run_dir}/module-content-rewrites.tsv"
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

  # BLOCKER (issue #16 fix-pack review, Viktor): this arm/trap pair MUST be
  # installed before the domain block just below it, not after. The domain
  # block ends in `graft_verify_domain_remap_usable ... || return 1` — a
  # real, reachable refusal (issue #73: a stale remap_domain marker plus a
  # broken domain_to, or simply an operator re-running against a run_dir
  # whose B briefly went unreachable mid-scan). On `main`, that guard sat
  # AFTER this trap was armed, so a refusal there still ran
  # _graft_exit_trap on the way out and cleaned up the mapping mu-plugin
  # (issue #54) if a previous pass had left it deployed and live on B. This
  # fix-pack originally moved the domain block up ahead of the trap
  # (needed so graft_migrate_post_type_defining_options, the new pre-import
  # consumer below, has domain_from/domain_to ready) but left the trap
  # itself behind it — reproduced live (Viktor, fixture): with the trap
  # below the guard, a refusal here left the mu-plugin on B UNWATCHED,
  # exactly what issue #54's trap exists to prevent. No such regression
  # exists once the trap is armed first: _graft_exit_trap is itself a
  # no-op unless graft.mu_plugin.done is already on disk (its own `if`
  # guard, above), so arming it here changes nothing for a fresh run —
  # only a resumed one that has something worth cleaning up.
  SITEGRAFT_GRAFT_RUN_DIR="$run_dir"
  trap _graft_exit_trap EXIT

  # Issue #16 fix-pack: moved up from immediately before the old
  # remap_domain/migrate_options block (further down) to right after the
  # manifest is available, and computed BEFORE either of those two AND
  # before graft_migrate_post_type_defining_options — the new consumer
  # this fix-pack adds, which runs much earlier (before graft_import_wxr,
  # so a post type etch_cpts declares is registered on B in time for the
  # WXR import that follows). The two values themselves are unchanged.
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

  # MAJOR-1 (issue #73, second review round) — see
  # graft_verify_domain_remap_usable's own header comment (just above its
  # definition) for the full reasoning. Called unconditionally, before
  # ANY of its three consumers now (graft_migrate_post_type_defining_options,
  # graft_search_replace_domain, graft_migrate_options), so no resume
  # marker can ever skip it. The trap above is ALREADY armed by the time
  # this can refuse, so a refusal here still runs mu-plugin cleanup — see
  # this block's own comment above the trap for why that ordering matters.
  graft_verify_domain_remap_usable "$domain_from" "$domain_to" || return 1

  # design doc §6.4 step 0a/0b (Marcel's revision of finding B1): sync whatever
  # plan approved for copying, THEN enforce the hard precondition on whatever
  # is left unresolved — never the other order, or the precondition would
  # refuse components graft_sync_stack was about to fix anyway.
  graft_step_done "$run_dir" stack_sync || { graft_sync_stack "$run_dir" "$manifest"; graft_mark_step "$run_dir" stack_sync; }
  graft_check_stack_precondition "${run_dir}/scan-a.json" "${run_dir}/scan-b.json" "$manifest" "$allow_mismatch" || return 1

  # Issue #36: media_sync used to run HERE, before mu_plugin — i.e. before
  # prune, several steps below. graft_media_sync pushes A's uploads onto B
  # with rsync --ignore-existing (never overwrite a file already there);
  # graft_prune_previous_run's `wp post delete --force` on a previously-
  # migrated attachment deletes that attachment's underlying FILE as a side
  # effect of deleting the post (verified live — see the issue's own DDEV
  # reproduction). Run in that order, a SECOND graft against a target that
  # already carries a first graft's attachments was silently destructive:
  # media_sync saw every file already present and skipped all of them,
  # prune then deleted every one of those same files for real, and
  # import_attachments found nothing left on disk to register — a full
  # media wipe on the single most ordinary case sitegraft exists for (an
  # iterative regraft onto the same B). Moved below the prune block instead
  # (see prune's own comment for why it still runs before import_attachments,
  # unchanged): prune deletes the stale files first, then media_sync
  # re-pushes A's uploads onto the now-empty slots --ignore-existing was
  # skipping, THEN import_attachments finds them again. The cheaper of the
  # two fixes the issue names (moving the step vs. dropping
  # --ignore-existing entirely, which would cost a full media re-transfer
  # on every single run — exactly what #11's batching fix-pack just made
  # fast for the opposite reason).
  #
  # Scope, named rather than implied (issue #36 fix-pack review): this
  # fixes the PRUNED-ATTACHMENT case only — a file whose owning post
  # graft_prune_previous_run deletes. It does NOT touch the class
  # docs/findings/2026-08-22-first-real-pair.md's F9 describes: a
  # plugin-generated file under uploads/ (e.g. ACSS's compiled CSS) that
  # no pruned post owns at all, so prune never removes it and this
  # reordering never gets a chance to re-sync it — --ignore-existing keeps
  # B's stale copy forever, regardless of step order. Nor does it touch a
  # FIRST graft onto a B that already shares files with A (e.g. B cloned
  # from A): nothing to prune, so every colliding filename is kept exactly
  # as --ignore-existing/--keep-existing already documents above
  # (graft_push_dir's own header) — A's version of a same-named-but-
  # different-bytes file never lands. Both are pre-existing, unfixed by
  # this PR; see its own PR description for what that means for an
  # operator.
  graft_step_done "$run_dir" mu_plugin     || { graft_deploy_mu_plugin; graft_mark_step "$run_dir" mu_plugin; }
  # Issue #16: must run before graft_import_wxr (several steps down) —
  # any later than that and the WXR import runs against a B whose
  # WordPress boot has not yet seen the option that registers this
  # content's own post type, and wordpress-importer treats the type as
  # unknown for the whole import (see graft_migrate_post_type_defining_
  # options' own header for the full mechanism and why issue #53's
  # completeness gate is what actually caught this on a real site).
  # Placed right after mu_plugin, ahead of prune/import_attachments, for
  # the same reason mu_plugin sits here: "prepare B" steps that have to
  # land before B's content changes, not steps that themselves depend on
  # run_dir/id-map.tsv state (this one only needs the manifest, already
  # parsed above, and domain_from/domain_to, already computed and verified
  # above). media_sync used to be named here too and no longer is -- issue
  # #36 moved it BELOW prune, because prune deletes an attachment's file
  # from disk and so undid the sync on a re-graft.
  graft_step_done "$run_dir" register_post_type_options || {
    graft_migrate_post_type_defining_options "$run_dir" "$manifest" "$domain_from" "$domain_to"
    graft_mark_step "$run_dir" register_post_type_options
  }
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
  #
  # Issue #54: gated on graft_safety_step_done (see its own header comment
  # for the three options weighed and why this one), not on prune's own
  # raw marker — a resume where import_attachments and/or import have not
  # BOTH completed must rerun prune, not trust a marker written before
  # either of them ran. import_attachments is listed as a consumer here
  # for the SAME reason the ordering comment above gives: prune's own
  # deletion scope ($post_types_csv, which — unlike $wxr_post_types_csv —
  # includes "attachment") reaches posts import_attachments creates, so a
  # prune rerun can invalidate its work exactly as it can invalidate a
  # partial WXR import's.
  #
  # The marker clears below are the companion half of that: entering this
  # block means prune is ABOUT to (re)run and may delete posts
  # import_attachments and/or import already created in an earlier,
  # interrupted pass. Their own markers (checked independently, a few
  # lines below and above this comment) must not go on claiming "done"
  # against posts that no longer exist — cleared here, unconditionally,
  # rather than only from _graft_exit_trap's own marker-clearing (which
  # only ever runs on a graceful `set -e` exit, never on a `kill -9`, a
  # dropped SSH connection, or the operator's machine losing power
  # mid-import — exactly the interruption shapes issue #54 is written
  # against). `is_dry_run ||` guards the actual removal, mirroring
  # graft_mark_step's own guard just above: under --dry-run this whole
  # block's `graft_prune_previous_run` call only ever echoes what it would
  # do (run_or_echo), so deleting REAL marker files here regardless would
  # corrupt a genuine prior run's resumability state for nothing — the
  # inverse of the exact bug graft_mark_step's own dry-run guard already
  # exists to prevent. That guard has NO direct test of its own (review,
  # MAJOR-4) — the dry-run acceptance test below (phase_graft's own
  # end-to-end dry-run test, tests/unit/test_graft_resume_safety.bats)
  # covers it: removing `is_dry_run ||` here makes that test fail red.
  #
  # `fetch_id_map` is ALSO a consumer here now (review, MAJOR-2, alongside
  # import_attachments/import): graft_fetch_id_map only ever APPENDS
  # ${run_dir}/id-map.tsv (its own header comment), and until this fix
  # nothing ever stripped that file's non-attachment rows back out when
  # prune reran — a prune rerun deletes those rows' posts on B while the
  # STALE rows themselves stayed in id-map.tsv, so a later
  # graft_verify_import_completeness could read them back as "already
  # landed" against old_ids B no longer has anything for. Listing
  # fetch_id_map as a consumer forces prune (and the run_dir id-map.tsv
  # stripping graft_prune_previous_run's own `run_dir` argument now does,
  # see that function's header) to rerun whenever fetch_id_map has not
  # ALSO completed since the last prune — and clearing its own marker
  # below (alongside import_attachments'/import's) means a resume that
  # only got as far as fetch_id_map reruns it too, against a fresh id-map
  # this prune pass just cleaned.
  #
  # Issue #36: graft.media_sync.done is now cleared here too, for the SAME
  # reason as the three markers already listed — prune's own `wp post
  # delete --force` deletes an attachment's underlying FILE, and
  # media_sync is the ONLY step that puts those files back. media_sync now
  # runs AFTER this block (below), so on this run's very first pass
  # through here its marker is not set yet and this is a no-op — but on a
  # RESUME whose earlier pass got as far as media_sync (marker set) and
  # then failed partway through import_attachments, THIS block reruns
  # (import_attachments is a consumer, above) and deletes the very files
  # that earlier media_sync run placed, for exactly the same reason it
  # deletes a partially-imported run's own posts. Without clearing
  # media_sync's marker here too, the resumed pass below would see it as
  # "already done", skip re-running it, and import_attachments would fail
  # to find files this prune pass just removed — the issue #36 bug,
  # reproduced a second time inside a single interrupted run instead of
  # across two separate ones.
  # BLOCKER-2 (issue #36 fix-pack review): `local` alongside the
  # assignment it guards, not split across two statements — `local x;
  # x=$(cmd)` is this file's own usual style for capturing a real exit
  # code, but this is a plain flag with no command substitution to
  # protect, so the split gains nothing here and only adds a line.
  local prune_will_rerun=""
  graft_safety_step_done "$run_dir" prune import_attachments import fetch_id_map || {
    # BLOCKER-2 (issue #36 fix-pack review): set the instant this block is
    # entered — dry-run or not — because media_sync's own gate (below)
    # needs to know prune is ABOUT TO rerun before it can decide whether
    # to show/perform its own rerun. See that gate's own comment for what
    # this flag fixes: without it, a dry-run preview against a run_dir
    # whose earlier REAL pass already completed media_sync (marker on
    # disk) silently omitted media_sync from the preview even though the
    # matching REAL run — hitting this exact block — clears the marker
    # and reruns it for real. Same bug class MAJOR-B (this file's own
    # comment on graft_mark_step) already fixed once, in the opposite
    # direction: that one was dry-run OVER-reporting (writing markers for
    # real); this one was dry-run UNDER-reporting (silently skipping a
    # step the real run performs).
    prune_will_rerun=1
    # `|| true` on the `rm -f` itself, not just the `is_dry_run ||` in
    # front of it (review, MINOR-E): this whole block is the RHS of a
    # `||` tested against graft_safety_step_done, which is what exempts
    # THAT command from `set -euo pipefail` — it does NOT extend to every
    # command sequentially inside this `{ }` group. A real `rm -f` failure
    # here (a read-only run_dir, e.g.) would abort phase_graft on the
    # spot, skipping graft_prune_previous_run entirely with a bare,
    # undiagnosed nonzero exit — silently worse than the marker simply
    # staying set. Logged, not swallowed: losing the ability to clear a
    # resumability marker is itself worth telling the operator about.
    #
    # This `rm -f` itself STAYS guarded by `is_dry_run` (unlike the four
    # step gates below it — media_sync, import_attachments, import,
    # fetch_id_map — which now no longer trust their own on-disk marker
    # once prune_will_rerun is set): the marker FILES are real state that
    # must not be mutated for real during a preview, exactly like every
    # other marker-clearing site in this function. prune_will_rerun is
    # what lets the preview stay accurate without mutating any of those
    # four marker files. It does not make the preview a no-op on disk in
    # general — graft_media_sync's own `mkdir -p "$staging"` (and
    # graft_pull_dir's own, inside it) are not gated by run_or_echo and so
    # still create `${run_dir}/media-staging` under --dry-run once this
    # forces the step to run; harmless, and the same pre-existing class as
    # every other real-but-benign directory `mkdir -p` this codebase's
    # dry-run steps already leave behind, not something this flag adds.
    if ! is_dry_run; then
      rm -f "${run_dir}/graft.media_sync.done" "${run_dir}/graft.import_attachments.done" "${run_dir}/graft.import.done" "${run_dir}/graft.fetch_id_map.done" \
        || log_warn "could not clear one or more resumability markers under ${run_dir} before prune — a later resume may not rerun the steps prune is about to invalidate"
    fi
    graft_prune_previous_run "$post_types_csv" "$run_dir"
    graft_mark_step "$run_dir" prune
  }
  # Issue #36: media_sync runs HERE now — after prune, before
  # import_attachments — not near the top of this function where it used
  # to sit (see the comment on its old call site, above, for the full
  # mechanism/reasoning). Prune has just deleted the files it deletes (if
  # any); this re-pushes A's uploads onto whatever gap that left, so
  # import_attachments (next) finds every file it expects, whether this is
  # a first graft or the twentieth onto the same B.
  #
  # BLOCKER-2 (issue #36 fix-pack review): gated on `[ -z "$prune_will_rerun" ]
  # && graft_step_done ...`, not a bare `graft_step_done "$run_dir"
  # media_sync` — when prune_will_rerun is set, this step runs (or, under
  # --dry-run, shows itself running) UNCONDITIONALLY, ignoring whatever
  # the on-disk marker currently says. This is what keeps a --dry-run
  # preview honest: the real run's `rm -f` above only fires when NOT
  # dry-run, so under a dry-run preview the on-disk marker from an earlier
  # completed pass would otherwise still read "done" and this step would
  # silently vanish from the preview — see prune_will_rerun's own comment,
  # above, for the full reasoning. Cost, not free: on a wrapped-local
  # (e.g. DDEV) site, graft_pull_dir streams a full, non-incremental
  # `tar -c -z` of A's entire uploads tree (see that function's own
  # header) — every prune rerun now re-pays that full transfer, not just
  # an ssh/bare-local rsync's cheap incremental delta. Accepted
  # deliberately: it is the exact cost the issue itself named as the more
  # expensive of its two proposed fixes, arriving here through the resume
  # path rather than every single run.
  # Second reviewer (independent, on PR #90) measured the blast radius this
  # PR's reorder moved, and it is worth telling the operator about rather
  # than leaving them to infer it. media_sync now runs AFTER prune, so if it
  # fails on a re-graft, prune has already deleted the previous run's
  # attachments AND their files, and A's have not been pushed yet: B is
  # briefly without either. That window is strictly better than what it
  # replaces -- the old order lost B's media on the SUCCESS path (issue #36)
  # -- and it is recoverable: resuming the same run_dir re-enters the prune
  # block, which clears media_sync's marker again, and the step reruns
  # (measured end to end by that reviewer: status 0, file restored). But a
  # bare rsync error says none of that, so say it here.
  { [ -z "$prune_will_rerun" ] && graft_step_done "$run_dir" media_sync; } || {
    graft_media_sync "$run_dir" || {
      log_error "media sync failed. B right now: the previous graft's attachments and their files were already deleted by prune, and A's have not been pushed yet. Nothing is lost that a resume cannot restore -- rerun the same command with --run ${run_dir} and this step will run again. If you would rather go back, the pre-graft backup is in ${run_dir}/backup."
      return 1
    }
    graft_mark_step "$run_dir" media_sync
  }
  # NIT (issue #36 fix-pack, second review round): the SAME `rm -f` above
  # clears FOUR markers, not just media_sync.done — import_attachments.done,
  # import.done and fetch_id_map.done too (all three pre-date this fix-pack;
  # see graft_safety_step_done's own header for why THOSE three are cleared
  # here in the first place). Only media_sync's own gate got the
  # prune_will_rerun treatment in the first pass of this fix-pack, which
  # left a dry-run preview honest about ONE of the four markers this same
  # `rm -f` invalidates and silently wrong about the other three — an
  # asymmetry with no reason behind it, worse than the uniform (if
  # incomplete) gap that existed before media_sync was added to the list.
  # A dry-run preview exists to say what a real run will do; it says so
  # correctly for all four of this `rm -f`'s markers now, or none of them —
  # not one arbitrarily singled out. Same mechanism, same reasoning as
  # media_sync's own gate: prune_will_rerun forces the step whenever prune
  # is about to (re)run, dry-run or not, ignoring the on-disk marker in
  # that case only.
  { [ -z "$prune_will_rerun" ] && graft_step_done "$run_dir" import_attachments; } || { graft_import_attachments "$run_dir"; graft_mark_step "$run_dir" import_attachments; }
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
  { [ -z "$prune_will_rerun" ] && graft_step_done "$run_dir" import; } || { graft_import_wxr "$run_dir"; graft_mark_step "$run_dir" import; }
  { [ -z "$prune_will_rerun" ] && graft_step_done "$run_dir" fetch_id_map; } || { graft_fetch_id_map "$run_dir"; graft_mark_step "$run_dir" fetch_id_map; }
  # Issue #53: unconditional, no marker of its own. This is a correctness
  # gate, not an expensive side-effecting step — it only reads the WXR files
  # and id-map.tsv this run already staged/fetched, both still sitting in
  # $run_dir regardless of how many times phase_graft has been invoked
  # against it — so it re-verifies on every single call, including a resume
  # where fetch_id_map's own marker is already set from an earlier pass.
  # Same "always recheck, never trust a marker for a plain read-only
  # assertion" shape graft_check_stack_precondition already uses above.
  # $wxr_post_types_csv passed through (review, part of BLOCKER-1's fix) so
  # the gate can tell "nothing was ever selected for a WXR import" apart
  # from "post_types WERE selected but the export is missing right now" —
  # see graft_verify_import_completeness's own header for why only this
  # call site (not every unit test of it) needs to pass it.
  # Captured via `if`, not `graft_verify_import_completeness ... || { ... }`
  # (review, BLOCKER-B): the two failure modes below need genuinely
  # DIFFERENT handling, which requires the real exit code, not merely
  # "was it zero" — an `if CMD; then ... else ...; fi` is the `set -e`-safe
  # way to capture `$?` from a tested command (same exemption `||` gives,
  # applied to an if/else instead) without a second, untested statement
  # that `set -euo pipefail` could abort on before `$?` is ever read.
  # NOT `if ! graft_verify_import_completeness ...; then local verify_rc=$?`
  # (caught by direct testing, not assumed): `!` negates the CONDITION's
  # own exit status, so `$?` inside a negated `if`'s `then` branch is 0 (the
  # negated/true status), never the tested command's REAL exit code — the
  # exact class of bug this rewrite exists to avoid elsewhere in this file.
  # Un-negated `if CMD; then :; else verify_rc=$?; fi` does not have that
  # problem: `$?` in the `else` branch is CMD's own real status.
  if graft_verify_import_completeness "$run_dir" "$wxr_post_types_csv"; then
    :
  else
    local verify_rc=$?
    if [ "$verify_rc" -eq 2 ]; then
      # BLOCKER-B (review): rc=2 means the run's own staged data is not
      # trustworthy right now (no .xml where post_types were selected, or
      # one that failed to parse — see graft_verify_import_completeness's
      # own header) — NOT the same thing as issue #53's "wordpress-importer
      # skipped a real, present item" (rc=1, below). Reproduced
      # mechanically end to end: a run that finished SUCCESSFULLY, whose
      # operator later deleted run_dir/export/*.xml (a real run dir's
      # largest files, and an unremarkable cleanup action), then reran
      # `sitegraft graft` against that same run_dir. The rc=1 branch below
      # clears import_attachments.done/import.done/fetch_id_map.done and
      # tells the operator a retry WILL work — which is true for rc=1
      # (the staged WXR is fine; only B's import state was wrong) and
      # actively DESTRUCTIVE for rc=2: a retry would trip
      # graft_safety_step_done, rerun graft_prune_previous_run for real
      # (deleting every post/attachment this tool had already correctly
      # migrated onto B), and STILL fail afterward, because
      # graft.export.done is untouched by either branch and the (now
      # permanently empty) export step stays marked done, never
      # regenerating the file the retry needed. No marker is touched
      # here, on purpose: the run_dir's own resumability state is still
      # accurate (every step it claims complete really did complete) —
      # only its later, externally-removed DATA is missing, which
      # clearing steps this tool did nothing wrong in cannot fix.
      # Enriched (review — a real occurrence, not hypothetical: the
      # DDEV harness's own assertion (e) wrote a test fixture straight
      # into run_dir/export/ and left it there; the NEXT `graft`
      # invocation against that same run_dir hit exactly this branch,
      # for exactly this reason — see tests/integration/ddev-harness.sh's
      # own comment on that assertion for the fix on the harness side).
      # "missing (or has an unreadable/corrupt) staged WXR export" was
      # true but incomplete: an operator reading only that would assume
      # THIS run's own export somehow got damaged, worrying (backup/
      # import corruption) and pointing at the wrong fix (restore from
      # backup) — when the far more likely real cause, given fail-closed
      # rejects the WHOLE glob on ANY single bad file, is that something
      # was ADDED to export/ that this run never produced: a hand-copied
      # WXR, a leftover test artifact, anything from an earlier
      # experiment against this same run_dir. Named explicitly, with the
      # cheap recovery path (remove it, re-run) stated before the
      # expensive ones.
      log_error "run directory ${run_dir} is missing its staged WXR export, or has one that fails to parse, even though its own markers say every earlier step already completed. Before assuming real data loss: check ${run_dir}/export for anything that was NOT produced by this run's own export step (a hand-added file, a leftover test artifact, or anything left behind by an earlier experiment against this same run_dir) — every .xml found there is treated as part of this run's own export, and a single foreign or malformed one is enough to trigger this exact message. This cannot self-heal via a simple retry of 'sitegraft graft' — a retry would delete the content this run already migrated onto B while never regenerating (or removing) whatever is actually wrong in export/, per issue #53/#54's own fix-pack (see graft_verify_import_completeness's header). No resumability marker was changed by this failure. Once export/ genuinely holds only this run's own file(s) again, re-running 'sitegraft verify' (or graft) will re-check correctly with no further action needed; if it still fails, start a fresh run (scan -> plan -> backup -> graft) against a clean run directory, or restore B from the pre-graft backup if you suspect real data loss."
      return 1
    fi

    # MAJOR-3 (review): rc=1 — a gate failure used to be a dead end — the
    # SAME markers phase_graft already trusts for resumability
    # (import_attachments.done, import.done, fetch_id_map.done) were all
    # still sitting there from the run that just failed THIS check, so a
    # second `sitegraft graft` against the same run directory skipped
    # straight back to this exact same failing check and reprinted the
    # identical message — reproduced live: infinitely re-runnable, never
    # actually retrying anything. Cleared here (guarded by is_dry_run for
    # symmetry with every other marker-clearing site in this function,
    # even though graft_verify_import_completeness's own `is_dry_run &&
    # return 0` makes this branch unreachable under --dry-run today — kept
    # so a future change to that short-circuit can't silently reintroduce
    # a real mutation under dry-run here) so a repeat invocation actually
    # DOES something: graft_safety_step_done's own "prune import_attachments
    # import fetch_id_map" gate (above) reads all three as incomplete
    # again, so prune reruns first — deleting every post/attachment this
    # run left on B and resetting both mapping logs (graft_prune_previous_run's
    # own header) — before import is re-attempted from a clean slate,
    # rather than colliding with itself the way issue #53 originally
    # described. Correct ONLY because rc=1 here means the staged WXR
    # itself is fine (BLOCKER-B, above, is exactly the case where it is
    # NOT, and takes a different branch instead).
    #
    # The message states what is actually true on B right now, not what
    # would be nice to claim (review, MAJOR-3): a partially migrated set of
    # posts from THIS run (each carrying _sitegraft_source_id — prune's own
    # marker for "mine to delete"), the attachment(s) this run already
    # imported, and the mapping mu-plugin still active until this process
    # exits — _graft_exit_trap removes it automatically on the way out
    # (mu_plugin.done is set, mu_cleanup.done is not, since this return
    # happens before the mu_cleanup step below ever runs), so that part IS
    # restored. wordpress-importer's own installed/active state on B is
    # NOT restored by this failure path — importer_cleanup, like
    # mu_cleanup, sits after this gate and is simply never reached; a known,
    # separate, narrower gap than the one this fix-pack closes, called out
    # here rather than silently claimed away.
    #
    # `|| log_warn ...`, not a bare `is_dry_run || rm -f ...` (review,
    # MINOR-E): this whole branch runs inside an `if`, which is what
    # exempts the OUTER `graft_verify_import_completeness` test from
    # `set -euo pipefail` — it does not extend to every command
    # sequentially inside this branch. An `rm -f` that fails for real (a
    # read-only run_dir, e.g.) would otherwise abort phase_graft right
    # here, before `log_error` below ever runs, with a bare undiagnosed
    # nonzero exit instead of the message this whole fix exists to show.
    #
    # Issue #36: graft.media_sync.done cleared here too, same reasoning as
    # the matching addition above the prune block — the retry this message
    # describes reruns prune first (its own comment, above), which deletes
    # the attachment(s) this run already imported AND their underlying
    # files; media_sync's marker must not keep claiming "already placed"
    # against files prune is about to remove out from under it.
    if ! is_dry_run; then
      rm -f "${run_dir}/graft.media_sync.done" "${run_dir}/graft.import_attachments.done" "${run_dir}/graft.import.done" "${run_dir}/graft.fetch_id_map.done" \
        || log_warn "could not clear one or more resumability markers under ${run_dir} — a retry may not behave as described below"
    fi
    log_error "B right now: a partially migrated set of posts from this run (each still carrying _sitegraft_source_id), plus the attachment(s) this run already imported. The mapping mu-plugin is removed automatically as this process exits; wordpress-importer's own plugin state on B has NOT been restored yet — that only happens once this gate passes. Re-running 'sitegraft graft' against this SAME run directory WILL retry: prune deletes everything this run left on B, then the WXR import runs again from scratch. If the same item(s) get skipped again, this will keep failing the same way — restore B from the pre-graft backup recorded under ${run_dir} instead, or resolve why wordpress-importer considers them pre-existing on B before retrying."
    return 1
  fi
  graft_step_done "$run_dir" mu_cleanup    || { graft_remove_mu_plugin; graft_mark_step "$run_dir" mu_cleanup; }
  graft_step_done "$run_dir" importer_cleanup || { graft_restore_importer_state "$run_dir"; graft_mark_step "$run_dir" importer_cleanup; }
  graft_step_done "$run_dir" remap_ids     || { graft_remap_attachment_ids "${run_dir}/id-map.tsv" "$run_dir"; graft_mark_step "$run_dir" remap_ids; }
  # MAJOR-1 fix-pack: featured images (_thumbnail_id), which never go
  # through wordpress-importer's own native remap since attachments are
  # migrated outside `wp import` entirely — see graft_remap_featured_images'
  # own comment. Runs after remap_ids (same id-map.tsv dependency, no
  # ordering requirement between the two beyond both needing it populated).
  graft_step_done "$run_dir" remap_featured_images || { graft_remap_featured_images "${run_dir}/id-map.tsv"; graft_mark_step "$run_dir" remap_featured_images; }
  # domain_from/domain_to were computed, normalized and verified usable
  # (graft_verify_domain_remap_usable) once, near the top of this
  # function — before graft_migrate_post_type_defining_options, the
  # earliest of this manifest's three domain-remap consumers, ever ran.
  # Reused as-is here for the other two.
  graft_step_done "$run_dir" remap_domain  || {
    graft_search_replace_domain "$domain_from" "$domain_to" "${run_dir}/id-map.tsv" "$run_dir"
    graft_mark_step "$run_dir" remap_domain
  }
  # Issue #16 fix-pack (review, Viktor): every key
  # graft_migrate_post_type_defining_options already pushed to B, well
  # above, is migrated AGAIN here — graft_migrate_options still reads the
  # manifest's full, unfiltered option_keys list, deliberately not
  # subtracting the ones the earlier pass already handled (see that
  # function's own header for why: one place decides "is this option
  # selected", not two that could disagree). Writing an unchanged value
  # twice is a no-op TODAY, measured: `wp option update` on an identical
  # value still exits 0, and nothing between the two writes touches the
  # option again — not wordpress-importer (WXR carries no wp_options
  # rows), not Etch (etch_cpts is only written from its own admin/REST
  # actions, never read-modify-written by anything graft or its mu-plugin
  # runs), not any `_post_import` hook (etch_post_import rewrites
  # `post_content`/`post_excerpt`, never `wp_options`). But that is a
  # property of what happens to run between the two calls, not of this
  # function pair itself — nothing here forces it to stay true. A future
  # step inserted between graft_migrate_post_type_defining_options and
  # this line that writes to one of the SAME option keys (a new module
  # hook, a new remap pass) would have its own write silently overwritten
  # by this second, later pass reading A's value again from scratch.
  # Worth remembering if this file grows a new step in that gap.
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
