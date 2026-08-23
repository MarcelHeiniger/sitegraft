#!/usr/bin/env bash
# lib/profile.sh — load a profile (profiles/<name>.conf) and its credentials.
#
# Deliberately does NOT `source`/`.` the profile or credentials file (that was
# the previous implementation, and it was unsafe: a "does this line look like
# an assignment" shape check is not equivalent to "this file only contains
# assignments" — verified live with two payloads that both passed the old
# check and then executed on source: (1) trailing shell code after a
# valid-looking assignment, since the old regex had no end-of-line anchor,
# e.g. `SITE_A_ALIAS="a"; touch /tmp/PWNED`; (2) a command substitution
# embedded in a double-quoted value, e.g. `SITE_A_ALIAS="$(touch /tmp/PWNED)"`
# — a double-quoted value can contain anything except a literal `"`, so this
# matched the shape check fine and then executed on source). Instead this
# parses the file itself, line by line, and only ever performs a plain bash
# variable assignment of a literal string — never eval, never source.

SITEGRAFT_PROFILES_DIR="${SITEGRAFT_PROFILES_DIR:-${SITEGRAFT_ROOT:-.}/profiles}"

# Every key this parser is allowed to set. SITE_A_*/SITE_B_* because those are
# the only two aliases wp_remote and the rest of the codebase ever use
# (design doc §5.1); SITEGRAFT_* for the two global settings (§5.1/§5.2).
# Anything else in a profile/.creds file is rejected outright.
SITEGRAFT_PROFILE_KEYS="SITE_A_ALIAS SITE_A_SSH_HOST SITE_A_SSH_KEY SITE_A_WP_PATH SITE_A_WP_CMD SITE_A_URL SITE_B_ALIAS SITE_B_SSH_HOST SITE_B_SSH_KEY SITE_B_WP_PATH SITE_B_WP_CMD SITE_B_URL SITEGRAFT_STATE_DIR SITEGRAFT_CREDS_FILE"

# Of the keys above, these must actually be present after parsing — not just
# "allowed if given" but "the profile is broken without it". Everything else
# (SSH_HOST, SSH_KEY, WP_CMD, URL, CREDS_FILE) has a safe default elsewhere
# (wp_remote's own "${!cmd_var:-wp}", the derived creds_file path below, or is
# forward-declared/unused today) or is genuinely optional (a purely local
# site has no SSH_HOST at all, by design). A missing required key used to
# surface as a raw bash "unbound variable" crash deep inside inventory.sh —
# with the class of bug this whole review round is about: under this bash
# version, that specific error class reports $?=0 to *any* EXIT trap
# regardless of what it does (verified live, including with a `${VAR:?msg}`
# guard, which does NOT help either), so the process appeared to succeed.
# Checking with `${!k:-}` here is safe — it never touches that fatal path,
# it just reads "" for anything unset — and turns a missing key into a
# normal, fully-propagated `return 1` before any code downstream ever gets
# a chance to dereference it unguarded.
SITEGRAFT_PROFILE_REQUIRED_KEYS="SITE_A_ALIAS SITE_A_WP_PATH SITE_B_ALIAS SITE_B_WP_PATH SITEGRAFT_STATE_DIR"

profile_key_allowed() {
  local key="$1" k
  for k in $SITEGRAFT_PROFILE_KEYS; do
    [ "$k" = "$key" ] && return 0
  done
  return 1
}

profile_check_required_keys() {
  local missing="" k v
  for k in $SITEGRAFT_PROFILE_REQUIRED_KEYS; do
    v="${!k:-}"
    [ -n "$v" ] || missing="${missing} ${k}"
  done
  if [ -n "$missing" ]; then
    log_error "profile is missing required key(s):${missing}"
    return 1
  fi
}

# profile_parse_file <path> — read KEY="value" / KEY='value' lines (blank
# lines and #-comments allowed, nothing else) and export each as a literal
# bash variable. Rejects: any line that isn't exactly one of those two
# shapes (no trailing content, no missing quote), and any key not on the
# whitelist above. A value is stored character-for-character as written
# between the quotes — no eval, no re-parsing — with one deliberate
# exception: a value starting with the literal token "${HOME}" has that
# prefix expanded (used by SITEGRAFT_STATE_DIR/SITEGRAFT_CREDS_FILE in the
# example profile), nothing else in the value is ever expanded.
profile_parse_file() {
  local file="$1"
  local lineno=0 line key value

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    case "$line" in
      '') continue ;;
      '#'*) continue ;;
    esac

    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\"([^\"]*)\"$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\'([^\']*)\'$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
    else
      log_error "${file}:${lineno}: not a plain KEY=\"value\" assignment: ${line}"
      return 1
    fi

    if ! profile_key_allowed "$key"; then
      log_error "${file}:${lineno}: unknown/unsupported key (not on the SITE_*/SITEGRAFT_* whitelist): ${key}"
      return 1
    fi

    case "$value" in
      '${HOME}'*) value="${HOME}${value#\$\{HOME\}}" ;;
    esac

    export "${key}=${value}"
  done < "$file"
}

# profile_check_creds_permissions <path> — design doc §5.2 requires the
# credentials file to be chmod 600 (owner read/write only). Portable between
# BSD stat (macOS) and GNU stat (Linux CI/servers).
profile_check_creds_permissions() {
  local file="$1" mode
  # GNU stat first: on Linux, `stat -f` isn't "not found", it's a DIFFERENT
  # flag (filesystem info, not file mode) that dumps unrelated garbage to
  # stdout before failing — so probing `-f` first and falling back to `-c`
  # on error corrupts $mode with that garbage on real Linux instead of
  # cleanly falling through. `stat -c` first is safe on macOS: BSD stat
  # rejects the unknown `-c` flag with nothing on stdout, so the fallback
  # to `-f '%Lp'` (BSD's actual mode format) still runs cleanly there.
  mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)
  case "$mode" in
    600|400)
      return 0
      ;;
    *)
      log_error "credentials file is group/world-readable (mode ${mode:-unknown}), refusing to load it: ${file} — fix with: chmod 600 ${file} (design doc §5.2)"
      return 1
      ;;
  esac
}

profile_load() {
  local name="$1"
  local file="${SITEGRAFT_PROFILES_DIR}/${name}.conf"

  if [ ! -f "$file" ]; then
    log_error "profile not found: ${name} (expected ${file})"
    return 1
  fi

  # Unset every key this loader is allowed to set BEFORE parsing the new
  # file: without this, a key the current profile/.creds doesn't mention
  # would silently keep whatever value a PREVIOUS profile_load call left in
  # this shell (e.g. SITEGRAFT_CREDS_FILE from profile X leaking into a
  # later profile_load for Y in the same process) — a real cross-profile
  # leak, not just a theoretical one.
  #
  # Deliberate consequence, decided and documented here rather than left
  # implicit: an ambient environment variable for any of these keys (e.g.
  # `SITEGRAFT_STATE_DIR=/custom sitegraft scan --profile x`) is NOT
  # honored — it is unset here just like a stale value from a previous
  # call would be, then only ever re-set from the profile file itself. The
  # profile file is the single source of truth for these keys, on purpose:
  # the whole point of unsetting first is that nothing about a key's value
  # should depend on what happened to be sitting in the calling shell's
  # environment before profile_load ran. To use a different SITEGRAFT_STATE_DIR,
  # put it in the profile.
  local k
  for k in $SITEGRAFT_PROFILE_KEYS; do
    unset "$k" 2>/dev/null || true
  done

  profile_parse_file "$file" || return 1
  profile_check_required_keys || return 1

  local creds_file="${SITEGRAFT_CREDS_FILE:-${HOME}/.config/sitegraft/${name}.creds}"
  if [ -f "$creds_file" ]; then
    profile_check_creds_permissions "$creds_file" || return 1
    profile_parse_file "$creds_file" || return 1
  else
    # Step 6 self-review (design doc §5.2 vs. code): §5.2 documents a real
    # "(b) interactive prompt" fallback here (gum input --password, with an
    # offer to save what was entered) — never implemented in v1, and the old
    # message's "not wired until Task 2.3" was itself stale (that task
    # finished steps ago without landing this). Deliberately left as a
    # documented v1 gap rather than rushed in during this polish pass — see
    # docs/status.md and docs/todo.md. Not a broken state in practice: no
    # SSH_KEY set just means wp_remote falls back to ssh's own default
    # identity resolution (ssh-agent / ~/.ssh/config), which works fine for
    # the common case — this is a missing convenience, not a missing
    # capability.
    log_warn "no credentials file at ${creds_file} — proceeding without SITE_*_SSH_KEY (falls back to ssh's own default identity resolution). Interactive credential prompting (design doc §5.2's option (b)) is not implemented in v1 — create ${creds_file} by hand (chmod 600) if you need a specific SSH key per site."
  fi
}
