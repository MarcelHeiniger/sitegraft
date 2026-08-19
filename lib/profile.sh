#!/usr/bin/env bash
# lib/profile.sh — load a profile (profiles/<name>.conf) and its credentials.

SITEGRAFT_PROFILES_DIR="${SITEGRAFT_PROFILES_DIR:-${SITEGRAFT_ROOT:-.}/profiles}"

profile_validate_file() {
  local file="$1"
  # Only allow: blank lines, comments, and KEY="value" / KEY='value' assignments.
  if grep -vE '^[[:space:]]*($|#|[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'))' "$file" >/dev/null; then
    log_error "profile file contains something other than plain assignments: ${file}"
    return 1
  fi
}

profile_load() {
  local name="$1"
  local file="${SITEGRAFT_PROFILES_DIR}/${name}.conf"

  if [ ! -f "$file" ]; then
    log_error "profile not found: ${name} (expected ${file})"
    return 1
  fi

  profile_validate_file "$file" || return 1
  # shellcheck disable=SC1090
  . "$file"

  local creds_file="${SITEGRAFT_CREDS_FILE:-${HOME}/.config/sitegraft/${name}.creds}"
  if [ -f "$creds_file" ]; then
    profile_validate_file "$creds_file" || return 1
    # shellcheck disable=SC1090
    . "$creds_file"
  else
    log_warn "no credentials file at ${creds_file} — interactive prompt not wired until Task 2.3"
  fi
}
