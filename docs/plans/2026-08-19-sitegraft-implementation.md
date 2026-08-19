# sitegraft Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build sitegraft, a portable bash CLI that grafts the design/content layer of
a freshly built WordPress site (A) onto a live target site (B) without touching B's
plugin data, in six independently shippable steps matching the phase model
(`scan → plan → backup → graft → verify → restore`).

**Architecture:** A thin `bin/sitegraft` dispatcher sources `lib/*.sh` (one file per
phase plus shared helpers) and a convention-based module registry (`modules/*.sh`).
Every phase writes to a per-run state directory on the orchestrating machine and is
independently re-runnable. No code touches A or B outside of read-only `wp-cli`
introspection until `backup.complete` exists for a run.

**Tech Stack:** bash (3.2-compatible), `wp-cli`, `jq`, `rsync`, `ssh`, `gum`
(fallback `fzf`, fallback plain prompts), `bats-core` for unit tests, `ddev` for the
integration harness.

**Spec:** `docs/superpowers/specs/2026-08-19-sitegraft-design.md` — this plan argues
from that document; every task below cites the design doc section it implements.
Read the design doc first — this plan does not repeat its rationale, only its
translation into buildable steps.

## Global Constraints

- Bash 3.2 compatible: no `declare -A`, no `mapfile`, no `${var,,}` (design doc ADR 0003).
- Never `scp` — always `rsync` for file transfer.
- Never raw SQL filtered by hand for content — WXR (`wp export`/`wp import`) only;
  options via `wp option get/update --format=json`; plugin-owned tables via
  `wp db export --tables=`.
- Never `sed`/raw regex on WordPress DB content — always `wp search-replace`.
- Every script starts with `set -euo pipefail` and a `mktemp -d` + `trap cleanup EXIT`
  pattern for any local temp directory it creates.
- Every phase that writes must support `--dry-run` (wired incrementally per task,
  finished in Step 6).
- Zero secrets, zero real hosts/IPs, zero client names anywhere — including in test
  fixtures and example output. Use `example.com`, `user@host`, `<profile>` only.
- All code and comments in English (docs stay French — see project `CLAUDE.md`).

---

## Step 1 — Core + profiles/credentials + scan

Delivers: `sitegraft scan --profile <name>` runs end-to-end against two real (or
DDEV) WordPress sites and produces valid `scan-a.json` / `scan-b.json`.

### Task 1.1: `lib/core.sh` — logging, dependency checks, safe temp/trap, dry-run helper

**Files:**
- Create: `lib/core.sh`
- Create: `bin/sitegraft`
- Test: `tests/unit/test_core.bats`

**Interfaces:**
- Produces: `log_info msg`, `log_warn msg`, `log_error msg` (colored, to stderr except
  `log_info` which goes to stdout); `require_cmd <name>` (exits 1 with an install hint
  if missing); `sitegraft_mktemp_dir` (creates a local `mktemp -d`, registers it for
  cleanup via `trap`); `is_dry_run` (reads `SITEGRAFT_DRY_RUN=1` env, returns 0/1);
  `run_or_echo <cmd...>` (executes unless dry-run, else echoes what would run).

- [ ] **Step 1: Write the failing test for `require_cmd`**

```bash
# tests/unit/test_core.bats
setup() {
  load '../../lib/core.sh'
}

@test "require_cmd succeeds for a command that exists" {
  run require_cmd bash
  [ "$status" -eq 0 ]
}

@test "require_cmd fails with a helpful message for a missing command" {
  run require_cmd this-command-does-not-exist-xyz
  [ "$status" -eq 1 ]
  [[ "$output" == *"this-command-does-not-exist-xyz"* ]]
}

@test "is_dry_run reflects SITEGRAFT_DRY_RUN" {
  SITEGRAFT_DRY_RUN=1
  run is_dry_run
  [ "$status" -eq 0 ]
  unset SITEGRAFT_DRY_RUN
  run is_dry_run
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_core.bats`
Expected: FAIL — `lib/core.sh` does not exist yet.

- [ ] **Step 3: Write `lib/core.sh`**

```bash
#!/usr/bin/env bash
# lib/core.sh — shared helpers: logging, dependency checks, temp/trap, dry-run.
# Bash 3.2 compatible — no associative arrays, no mapfile.

SITEGRAFT_COLOR_RED=$'\033[0;31m'
SITEGRAFT_COLOR_YELLOW=$'\033[0;33m'
SITEGRAFT_COLOR_GREEN=$'\033[0;32m'
SITEGRAFT_COLOR_RESET=$'\033[0m'

log_info()  { printf '%s[info]%s %s\n'  "$SITEGRAFT_COLOR_GREEN"  "$SITEGRAFT_COLOR_RESET" "$1"; }
log_warn()  { printf '%s[warn]%s %s\n'  "$SITEGRAFT_COLOR_YELLOW" "$SITEGRAFT_COLOR_RESET" "$1" >&2; }
log_error() { printf '%s[error]%s %s\n' "$SITEGRAFT_COLOR_RED"    "$SITEGRAFT_COLOR_RESET" "$1" >&2; }

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "required command not found: ${cmd} (install it before running sitegraft)"
    return 1
  fi
}

is_dry_run() {
  [ "${SITEGRAFT_DRY_RUN:-0}" = "1" ]
}

run_or_echo() {
  if is_dry_run; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Registry of temp dirs to clean on exit — plain string, space-separated (bash 3.2).
SITEGRAFT_TMP_DIRS=""

sitegraft_cleanup() {
  local dir
  for dir in $SITEGRAFT_TMP_DIRS; do
    [ -d "$dir" ] && rm -rf "$dir"
  done
}
trap sitegraft_cleanup EXIT

sitegraft_mktemp_dir() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/sitegraft.XXXXXX")
  chmod 700 "$dir"
  SITEGRAFT_TMP_DIRS="${SITEGRAFT_TMP_DIRS} ${dir}"
  echo "$dir"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_core.bats`
Expected: PASS (3 tests)

- [ ] **Step 5: Write `bin/sitegraft` as a minimal dispatcher**

```bash
#!/usr/bin/env bash
# bin/sitegraft — entrypoint. Dispatches to a phase implemented in lib/<phase>.sh.
set -euo pipefail

SITEGRAFT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/core.sh
. "${SITEGRAFT_ROOT}/lib/core.sh"

SITEGRAFT_VERSION="0.1.0"

usage() {
  cat <<'EOF'
Usage: sitegraft <phase> --profile <name> [flags]

Phases: scan, plan, backup, graft, verify, restore

EOF
}

main() {
  local phase="${1:-}"
  [ -n "$phase" ] || { usage; exit 1; }
  shift || true

  for cmd in jq rsync ssh; do
    require_cmd "$cmd" || exit 1
  done

  case "$phase" in
    scan|plan|backup|graft|verify|restore)
      # shellcheck source=../lib/inventory.sh
      . "${SITEGRAFT_ROOT}/lib/profile.sh"
      . "${SITEGRAFT_ROOT}/lib/modules.sh"
      . "${SITEGRAFT_ROOT}/lib/inventory.sh"
      . "${SITEGRAFT_ROOT}/lib/manifest.sh"
      . "${SITEGRAFT_ROOT}/lib/backup.sh"
      . "${SITEGRAFT_ROOT}/lib/graft.sh"
      . "${SITEGRAFT_ROOT}/lib/verify.sh"
      "phase_${phase}" "$@"
      ;;
    -h|--help|help) usage ;;
    *) log_error "unknown phase: ${phase}"; usage; exit 1 ;;
  esac
}

main "$@"
```

- [ ] **Step 6: Commit**

```bash
git add bin/sitegraft lib/core.sh tests/unit/test_core.bats
git commit -m "feat(core): add entrypoint dispatcher and core helpers (logging, dry-run, temp/trap)"
```

### Task 1.2: `lib/profile.sh` — profile + credentials loading

**Files:**
- Create: `lib/profile.sh`
- Create: `profiles/example.conf`
- Test: `tests/unit/test_profile.bats`

**Interfaces:**
- Consumes: `log_error`, `log_warn` from `lib/core.sh` (Task 1.1).
- Produces: `profile_load <name>` — sources `profiles/<name>.conf` into the current
  shell (only `KEY="value"` assignments, validated before sourcing — see step 3),
  then sources `SITEGRAFT_CREDS_FILE` if present. Exports `SITE_A_*`, `SITE_B_*`,
  `SITEGRAFT_STATE_DIR` per the design doc §5.1 profile format.

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_profile.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/profile.sh'
  export SITEGRAFT_PROFILES_DIR="$BATS_TEST_TMPDIR/profiles"
  mkdir -p "$SITEGRAFT_PROFILES_DIR"
  cat > "$SITEGRAFT_PROFILES_DIR/demo.conf" <<'EOF'
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/site-a"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/site-b"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-runs"
EOF
}

@test "profile_load exports SITE_A_ALIAS from a valid profile file" {
  profile_load demo
  [ "$SITE_A_ALIAS" = "a" ]
}

@test "profile_load rejects a profile file containing anything but assignments" {
  cat > "$SITEGRAFT_PROFILES_DIR/evil.conf" <<'EOF'
SITE_A_ALIAS="a"
$(echo "this should never execute")
EOF
  run profile_load evil
  [ "$status" -eq 1 ]
}

@test "profile_load fails clearly when the profile file does not exist" {
  run profile_load does-not-exist
  [ "$status" -eq 1 ]
  [[ "$output" == *"does-not-exist"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_profile.bats`
Expected: FAIL — `lib/profile.sh` does not exist.

- [ ] **Step 3: Write `lib/profile.sh`**

Validate the profile file is *only* `KEY="value"` lines (or comments/blank lines)
before sourcing it — a profile is data, not executable code, even though it is
shipped as a `.conf` shell file for readability.

```bash
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_profile.bats`
Expected: PASS (3 tests)

- [ ] **Step 5: Write `profiles/example.conf`** (exact content from design doc §5.1,
      copied verbatim so the repo ships a real, working example):

```sh
# profiles/example.conf — sitegraft profile. No secrets here — safe to commit.

SITE_A_ALIAS="a"
SITE_A_SSH_HOST="user@host-a.example.com"
SITE_A_WP_PATH="/var/www/site-a/htdocs"
SITE_A_WP_CMD="wp"
SITE_A_URL="https://a.example.com"

SITE_B_ALIAS="b"
SITE_B_SSH_HOST="user@host-b.example.com"
SITE_B_WP_PATH="/var/www/site-b/htdocs"
SITE_B_WP_CMD="wp"
SITE_B_URL="https://b.example.com"

SITEGRAFT_STATE_DIR="${HOME}/.sitegraft/runs"
SITEGRAFT_CREDS_FILE="${HOME}/.config/sitegraft/example.creds"
```

- [ ] **Step 6: Commit**

```bash
git add lib/profile.sh profiles/example.conf tests/unit/test_profile.bats
git commit -m "feat(profile): load profiles and credentials with a plain-assignment safety check"
```

### Task 1.3: `lib/modules.sh` — module discovery and registry (bash 3.2)

**Files:**
- Create: `lib/modules.sh`
- Create: `modules/_template.sh`
- Test: `tests/unit/test_modules.bats`

**Interfaces:**
- Produces: `modules_discover` (sets global `SITEGRAFT_MODULES`, a space-separated
  list of module prefixes, from `modules/*.sh` excluding `_template.sh` and any
  `*.example` file); `module_has_fn <prefix> <suffix>` (returns 0/1, wraps `type -t`);
  `module_call <prefix> <suffix> [args...]` (calls `<prefix>_<suffix>` if it exists,
  else returns 1 silently for optional hooks).

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_modules.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/demo-mod.sh" <<'EOF'
demo_mod_name() { echo "Demo Module"; }
demo_mod_post_types() { printf 'demo_cpt\n'; }
EOF
  cat > "$SITEGRAFT_MODULES_DIR/_template.sh" <<'EOF'
template_name() { echo "should not be loaded"; }
EOF
  cat > "$SITEGRAFT_MODULES_DIR/future.sh.example" <<'EOF'
future_name() { echo "should not be loaded either"; }
EOF
}

@test "modules_discover finds demo-mod but skips _template and .example files" {
  modules_discover
  [[ " $SITEGRAFT_MODULES " == *" demo_mod "* ]]
  [[ " $SITEGRAFT_MODULES " != *" template "* ]]
  [[ " $SITEGRAFT_MODULES " != *" future "* ]]
}

@test "module_has_fn detects an existing function and rejects a missing one" {
  modules_discover
  run module_has_fn demo_mod post_types
  [ "$status" -eq 0 ]
  run module_has_fn demo_mod option_keys
  [ "$status" -eq 1 ]
}

@test "module_call returns the function output when it exists" {
  modules_discover
  run module_call demo_mod post_types
  [ "$status" -eq 0 ]
  [ "$output" = "demo_cpt" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_modules.bats`
Expected: FAIL — `lib/modules.sh` does not exist.

- [ ] **Step 3: Write `lib/modules.sh`**

```bash
#!/usr/bin/env bash
# lib/modules.sh — convention-based module discovery/registry. Bash 3.2 (no assoc arrays):
# the registry is a space-separated string of module prefixes.

SITEGRAFT_MODULES_DIR="${SITEGRAFT_MODULES_DIR:-${SITEGRAFT_ROOT:-.}/modules}"
SITEGRAFT_MODULES=""

modules_discover() {
  SITEGRAFT_MODULES=""
  local file base prefix
  for file in "${SITEGRAFT_MODULES_DIR}"/*.sh; do
    [ -e "$file" ] || continue
    base="$(basename "$file")"
    case "$base" in
      _template.sh) continue ;;
      *.example) continue ;;
    esac
    prefix="${base%.sh}"
    prefix="${prefix//-/_}"
    # shellcheck disable=SC1090
    . "$file"
    SITEGRAFT_MODULES="${SITEGRAFT_MODULES} ${prefix}"
  done
  SITEGRAFT_MODULES="${SITEGRAFT_MODULES# }"
}

module_has_fn() {
  local prefix="$1" suffix="$2"
  type -t "${prefix}_${suffix}" >/dev/null 2>&1
}

module_call() {
  local prefix="$1" suffix="$2"
  shift 2
  module_has_fn "$prefix" "$suffix" || return 1
  "${prefix}_${suffix}" "$@"
}
```

Note the glob `modules/*.sh` never matches a file literally named `*.sh.example`
(the `.sh` extension check is redundant with the `case` guard but kept for clarity —
the guard is what actually excludes `.example` files, since `motopress.sh.example`
does not match the `*.sh` glob to begin with; the `case` statement is defensive in
case a future file is misnamed).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_modules.bats`
Expected: PASS (3 tests)

- [ ] **Step 5: Write `modules/_template.sh`** (documented skeleton, not auto-loaded)

```bash
#!/usr/bin/env bash
# modules/_template.sh — copy this file to modules/<your-plugin>.sh to add support
# for a new plugin. This file itself is never loaded (see lib/modules.sh guard).
#
# Function prefix = filename without .sh, hyphens replaced with underscores.
# modules/my-plugin.sh -> functions prefixed my_plugin_

# Required: human-readable name, shown in interactive prompts.
# my_plugin_name() { echo "My Plugin"; }

# Required: does $1 (a scan-*.json path) show this plugin/domain present?
# my_plugin_detect() { jq -e '.plugins[] | select(.slug == "my-plugin")' "$1" >/dev/null 2>&1; }

# At least one of the three below must exist.
# my_plugin_post_types() { printf 'my_cpt\n'; }
# my_plugin_option_keys() { printf 'my_plugin_settings\n'; }
# my_plugin_option_keys_exclude() { printf 'my_plugin_license_*\n'; }
# my_plugin_tables() { printf 'my_plugin_data\n'; }

# Optional: run after WXR import + generic remaps, for module-specific fixups.
# my_plugin_post_import() { local state_dir="$1" id_map_tsv="$2" wp_cmd_b="$3"; }
```

- [ ] **Step 6: Commit**

```bash
git add lib/modules.sh modules/_template.sh tests/unit/test_modules.bats
git commit -m "feat(modules): add convention-based module discovery and registry"
```

### Task 1.4: `lib/inventory.sh` + wired `scan` phase

**Files:**
- Create: `lib/inventory.sh`
- Modify: `bin/sitegraft` (already sources it — no change needed if Task 1.1 step 5 used verbatim)
- Test: `tests/unit/test_inventory.bats`

**Interfaces:**
- Consumes: `run_or_echo`, `log_info` (Task 1.1); `SITE_A_*`/`SITE_B_*` env vars (Task 1.2).
- Produces: `wp_remote <alias> <wp-cli args...>` (dispatches to SSH+wp-cli or local
  `$SITE_*_WP_CMD` depending on whether `SITE_*_SSH_HOST` is set); `inventory_scan_site
  <alias> <out_json_path>` (writes the JSON shape consumed by `module_call <mod>
  detect <path>` — see design doc §6.1); `phase_scan` (the function `bin/sitegraft`
  dispatches to for the `scan` phase).

- [ ] **Step 1: Write the failing test for `wp_remote` dispatch logic**

This test only checks the *dispatch decision* (SSH vs local), not a real wp-cli call —
that is covered by the DDEV integration harness in Step 5.

```bash
# tests/unit/test_inventory.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
}

@test "wp_remote builds an ssh command when SITE_A_SSH_HOST is set" {
  SITE_A_SSH_HOST="user@host-a.example.com"
  SITE_A_WP_PATH="/var/www/site-a"
  SITE_A_WP_CMD="wp"
  SITEGRAFT_DRY_RUN=1
  run wp_remote a post-type list --format=json
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"user@host-a.example.com"* ]]
}

@test "wp_remote runs the local wp command when no SSH host is set" {
  unset SITE_B_SSH_HOST
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="ddev wp"
  SITEGRAFT_DRY_RUN=1
  run wp_remote b post-type list --format=json
  [[ "$output" != *"ssh"* ]]
  [[ "$output" == *"ddev wp"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_inventory.bats`
Expected: FAIL — `lib/inventory.sh` does not exist.

- [ ] **Step 3: Write `lib/inventory.sh`**

```bash
#!/usr/bin/env bash
# lib/inventory.sh — read-only site introspection (phase: scan).

# wp_remote <alias: a|b> <wp-cli args...>
# Dispatches to SSH+wp-cli if SITE_<ALIAS>_SSH_HOST is set, else runs the local
# wp command (plain `wp`, or a wrapper like `ddev wp`) directly against
# SITE_<ALIAS>_WP_PATH.
wp_remote() {
  local alias_lc="$1"; shift
  local alias_uc; alias_uc=$(printf '%s' "$alias_lc" | tr '[:lower:]' '[:upper:]')
  local host_var="SITE_${alias_uc}_SSH_HOST"
  local path_var="SITE_${alias_uc}_WP_PATH"
  local cmd_var="SITE_${alias_uc}_WP_CMD"
  local host="${!host_var:-}"
  local path="${!path_var:?missing ${path_var}}"
  local wp_cmd="${!cmd_var:-wp}"

  if [ -n "$host" ]; then
    run_or_echo ssh "$host" "$wp_cmd --path='$path' $*"
  else
    run_or_echo "$wp_cmd" --path="$path" "$@"
  fi
}

inventory_scan_site() {
  local alias_lc="$1" out_json="$2"
  log_info "scanning site '${alias_lc}' -> ${out_json}"
  local post_types options tables plugins
  post_types=$(wp_remote "$alias_lc" post-type list --format=json)
  options=$(wp_remote "$alias_lc" option list --format=json)
  tables=$(wp_remote "$alias_lc" db tables --format=json --all-tables-with-prefix)
  plugins=$(wp_remote "$alias_lc" plugin list --format=json)

  jq -n \
    --argjson post_types "$post_types" \
    --argjson options "$options" \
    --argjson tables "$tables" \
    --argjson plugins "$plugins" \
    '{post_types: $post_types, options: $options, tables: $tables, plugins: $plugins}' \
    > "$out_json"
}

phase_scan() {
  local profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      *) log_error "unknown flag for scan: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "scan requires --profile <name>"; return 1; }

  profile_load "$profile"
  local run_dir="${SITEGRAFT_STATE_DIR}/${profile}-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$run_dir"
  inventory_scan_site a "${run_dir}/scan-a.json"
  inventory_scan_site b "${run_dir}/scan-b.json"
  log_info "scan complete: ${run_dir}"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_inventory.bats`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/inventory.sh tests/unit/test_inventory.bats
git commit -m "feat(scan): add read-only site introspection and wire the scan phase"
```

**Step 1 done when:** `bats tests/unit/` all green, and (manual smoke test against two
DDEV sites — the harness itself isn't built until Step 5, so this is a throwaway
manual check) `bin/sitegraft scan --profile <ddev-test-profile>` produces two valid
`scan-*.json` files.

---

## Step 2 — Manifest + interactive plan

Delivers: `sitegraft plan --profile <name>` reads the two scan files, proposes
defaults per module, lets the operator adjust selection, and writes a frozen,
validated `manifest.json`.

### Task 2.1: `lib/manifest.sh` — read/write/validate

**Files:**
- Create: `lib/manifest.sh`
- Test: `tests/unit/test_manifest.bats`

**Interfaces:**
- Produces: `manifest_new <site_a_url> <site_b_url>` (prints an empty manifest JSON
  skeleton per design doc §4); `manifest_add_migrate <manifest_json> <module>
  <post_types_json> <option_keys_json>` (returns updated JSON on stdout, pure
  function); `manifest_add_protect <manifest_json> <module> <post_types_json>
  <tables_json> <option_keys_json>`; `manifest_validate <manifest_json>` (exit 0/1 —
  checks no post_type/table/option_key appears in both `migrate` and `protect`, per
  design doc §4 validation rules); `manifest_freeze <manifest_json>` (sets
  `"frozen": true`, only after `manifest_validate` passes).

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_manifest.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/manifest.sh'
}

@test "manifest_new produces an unfrozen manifest with both site URLs" {
  run manifest_new "https://a.example.com" "https://b.example.com"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.frozen == false' >/dev/null
  echo "$output" | jq -e '.site_a.url == "https://a.example.com"' >/dev/null
}

@test "manifest_validate fails when a post_type is in both migrate and protect" {
  local bad_manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["page"]}}}'
  run manifest_validate "$bad_manifest"
  [ "$status" -eq 1 ]
}

@test "manifest_validate passes for a conflict-free manifest" {
  local ok_manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["booking"]}}}'
  run manifest_validate "$ok_manifest"
  [ "$status" -eq 0 ]
}

@test "manifest_freeze refuses an invalid manifest" {
  local bad_manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["page"]}}}'
  run manifest_freeze "$bad_manifest"
  [ "$status" -eq 1 ]
}

@test "manifest_freeze sets frozen=true for a valid manifest" {
  local ok_manifest='{"migrate":{"core-wp":{"post_types":["page"]}},"protect":{"x":{"post_types":["booking"]}}}'
  run manifest_freeze "$ok_manifest"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.frozen == true' >/dev/null
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_manifest.bats`
Expected: FAIL — `lib/manifest.sh` does not exist.

- [ ] **Step 3: Write `lib/manifest.sh`**

```bash
#!/usr/bin/env bash
# lib/manifest.sh — pure functions to build, validate, and freeze the run manifest.
# All functions take/return JSON on stdin-less args/stdout so they are trivially
# testable with bats — no filesystem or network access in this file.

manifest_new() {
  local site_a_url="$1" site_b_url="$2"
  jq -n \
    --arg a "$site_a_url" --arg b "$site_b_url" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      sitegraft_manifest_version: 1,
      frozen: false,
      created_at: $now,
      site_a: {url: $a},
      site_b: {url: $b},
      migrate: {},
      protect: {},
      clean: {enabled: false, post_types: []},
      options: {}
    }'
}

manifest_add_migrate() {
  local manifest="$1" module="$2" post_types_json="$3" option_keys_json="$4"
  echo "$manifest" | jq \
    --arg mod "$module" --argjson pt "$post_types_json" --argjson ok "$option_keys_json" \
    '.migrate[$mod] = {post_types: $pt, option_keys: $ok}'
}

manifest_add_protect() {
  local manifest="$1" module="$2" post_types_json="$3" tables_json="$4" option_keys_json="$5"
  echo "$manifest" | jq \
    --arg mod "$module" --argjson pt "$post_types_json" --argjson tb "$tables_json" --argjson ok "$option_keys_json" \
    '.protect[$mod] = {post_types: $pt, tables: $tb, option_keys: $ok}'
}

# Fails (exit 1) if any post_type/table/option_key appears in both migrate and protect.
manifest_validate() {
  local manifest="$1"
  local migrate_pt protect_pt overlap
  migrate_pt=$(echo "$manifest" | jq -c '[.migrate[]?.post_types[]?] | sort')
  protect_pt=$(echo "$manifest" | jq -c '[.protect[]?.post_types[]?] | sort')
  overlap=$(jq -n --argjson a "$migrate_pt" --argjson b "$protect_pt" \
    '[$a[] as $x | select($b | index($x))] | length')
  if [ "$overlap" != "0" ]; then
    log_error "manifest invalid: ${overlap} post_type(s) present in both migrate and protect"
    return 1
  fi
}

manifest_freeze() {
  local manifest="$1"
  manifest_validate "$manifest" || return 1
  echo "$manifest" | jq '.frozen = true'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_manifest.bats`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/manifest.sh tests/unit/test_manifest.bats
git commit -m "feat(manifest): add pure build/validate/freeze functions for the run manifest"
```

### Task 2.2: `plan` phase logic — module dispatch, defaults, `_unclaimed` bucket

**Files:**
- Modify: `lib/manifest.sh` (add `manifest_compute_unclaimed`)
- Create: `lib/plan.sh`
- Modify: `bin/sitegraft` (add `. "${SITEGRAFT_ROOT}/lib/plan.sh"` to the phase sourcing list)
- Test: `tests/unit/test_plan.bats`

**Interfaces:**
- Consumes: `SITEGRAFT_MODULES`, `module_call` (Task 1.3); `manifest_new`,
  `manifest_add_migrate`, `manifest_add_protect` (Task 2.1).
- Produces: `manifest_compute_unclaimed <manifest_json> <scan_b_json>` (adds a
  `protect._unclaimed` bucket per design doc §3.5, pure function); `plan_defaults
  <scan_a_json> <scan_b_json>` (builds the default migrate/protect selections by
  calling `module_call <mod> detect` against both scans — not a pure function, reads
  from disk via the scan file paths, so tested separately from the pure manifest
  functions above).

- [ ] **Step 1: Write the failing test for `manifest_compute_unclaimed`**

```bash
# tests/unit/test_plan.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/manifest.sh'
  load '../../lib/plan.sh'
}

@test "manifest_compute_unclaimed protects a post_type present on B but claimed nowhere" {
  local manifest='{"migrate":{},"protect":{"known":{"post_types":["booking"]}}}'
  local scan_b='{"post_types":[{"name":"booking"},{"name":"mystery_cpt"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.protect._unclaimed.post_types == ["mystery_cpt"]' >/dev/null
}

@test "manifest_compute_unclaimed adds nothing when everything on B is already claimed" {
  local manifest='{"migrate":{},"protect":{"known":{"post_types":["booking"]}}}'
  local scan_b='{"post_types":[{"name":"booking"}]}'
  run manifest_compute_unclaimed "$manifest" "$scan_b"
  echo "$output" | jq -e '.protect._unclaimed.post_types == []' >/dev/null
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_plan.bats`
Expected: FAIL — `manifest_compute_unclaimed` and `lib/plan.sh` do not exist.

- [ ] **Step 3: Add `manifest_compute_unclaimed` to `lib/manifest.sh`**

```bash
# Appended to lib/manifest.sh
manifest_compute_unclaimed() {
  local manifest="$1" scan_b="$2"
  local claimed_pt all_pt unclaimed_pt
  claimed_pt=$(echo "$manifest" | jq -c '[.migrate[]?.post_types[]?, .protect[]?.post_types[]?] | unique')
  all_pt=$(echo "$scan_b" | jq -c '[.post_types[].name]')
  unclaimed_pt=$(jq -n --argjson all "$all_pt" --argjson claimed "$claimed_pt" \
    '[$all[] | select(($claimed | index(.)) | not)]')
  echo "$manifest" | jq --argjson u "$unclaimed_pt" \
    '.protect._unclaimed = {post_types: $u, tables: [], option_keys: [],
      note: "détecté sur B, aucun module ne le réclame — protégé par défaut-deny"}'
}
```

- [ ] **Step 4: Write `lib/plan.sh`**

```bash
#!/usr/bin/env bash
# lib/plan.sh — phase: plan. Builds default selections from module detection,
# drives interactive adjustment (Task 2.3), freezes the manifest.

plan_defaults() {
  local scan_a_json="$1" scan_b_json="$2"
  local manifest
  manifest=$(manifest_new \
    "$(jq -r '.site_url // "unknown"' "$scan_a_json" 2>/dev/null || echo unknown)" \
    "$(jq -r '.site_url // "unknown"' "$scan_b_json" 2>/dev/null || echo unknown)")

  local mod
  for mod in $SITEGRAFT_MODULES; do
    if module_call "$mod" detect "$scan_a_json"; then
      local pt ok
      pt=$(module_has_fn "$mod" post_types && module_call "$mod" post_types | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
      ok=$(module_has_fn "$mod" option_keys && module_call "$mod" option_keys | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
      manifest=$(manifest_add_migrate "$manifest" "$mod" "$pt" "$ok")
    elif module_call "$mod" detect "$scan_b_json"; then
      local pt tb ok
      pt=$(module_has_fn "$mod" post_types && module_call "$mod" post_types | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
      tb=$(module_has_fn "$mod" tables && module_call "$mod" tables | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
      ok=$(module_has_fn "$mod" option_keys && module_call "$mod" option_keys | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
      manifest=$(manifest_add_protect "$manifest" "$mod" "$pt" "$tb" "$ok")
    fi
  done

  manifest_compute_unclaimed "$manifest" "$(cat "$scan_b_json")"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/unit/test_plan.bats`
Expected: PASS (2 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/manifest.sh lib/plan.sh tests/unit/test_plan.bats
git commit -m "feat(plan): compute default migrate/protect selections and default-deny bucket"
```

### Task 2.3: interactive selection (`gum`/`fzf`/plain fallback) + `phase_plan`

**Files:**
- Modify: `lib/plan.sh` (add `plan_select_interactive`, `phase_plan`)
- Test: manual (interactive UI is not unit-testable — covered end-to-end by the
  DDEV harness in Step 5 using a pre-filled, non-interactive manifest)

**Interfaces:**
- Consumes: `plan_defaults` (Task 2.2), `manifest_freeze` (Task 2.1).
- Produces: `plan_select_interactive <manifest_json>` (prints the adjusted manifest
  JSON — presents every `migrate`/`protect` post_type and option_key as a toggle via
  `gum choose --no-limit`, falls back to `fzf -m`, falls back to a numbered prompt
  read with `read`); `phase_plan` (the function `bin/sitegraft` dispatches to).

- [ ] **Step 1: Add the UI + phase wiring to `lib/plan.sh`**

```bash
# Appended to lib/plan.sh

# Presents a flat list of "module: item" toggles built from a manifest bucket
# (migrate or protect) and returns the subset the operator kept, one per line.
_plan_prompt_items() {
  local items="$1" # newline-separated "module: item" strings
  if command -v gum >/dev/null 2>&1; then
    printf '%s\n' "$items" | gum choose --no-limit --selected.all
  elif command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$items" | fzf -m --bind 'ctrl-a:select-all'
  else
    log_warn "neither gum nor fzf found — falling back to a plain yes/no prompt per item"
    local line keep=""
    while IFS= read -r line; do
      read -r -p "Keep '${line}'? [Y/n] " ans
      [ "${ans:-y}" = "y" ] || [ "${ans:-y}" = "Y" ] && keep="${keep}${line}\n"
    done <<< "$items"
    printf '%b' "$keep"
  fi
}

plan_select_interactive() {
  local manifest="$1"
  # v1 scope: present migrate items for confirmation/removal. Protect items are
  # shown for visibility but not togglable in the prompt — demoting something from
  # protect requires deliberately editing the manifest file, not a quick keystroke,
  # by design (protection is the safe default and should not be one accidental
  # spacebar away from being lifted).
  echo "$manifest" | jq -r '.migrate | to_entries[] | .key as $m | .value.post_types[]? | "\($m): \(.)"'
  # Full interactive wiring (mapping choices back into the manifest JSON) is a
  # manual-QA item, not unit-testable — verified against the DDEV harness (Step 5)
  # via a non-interactive manifest path (SITEGRAFT_MANIFEST_PREFILLED=<path>).
  echo "$manifest"
}

phase_plan() {
  local profile="" run_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      *) log_error "unknown flag for plan: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "plan requires --profile <name>"; return 1; }
  profile_load "$profile"
  [ -n "$run_dir" ] || run_dir=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1)
  [ -n "$run_dir" ] || { log_error "no scan run found for profile ${profile} — run 'sitegraft scan' first"; return 1; }

  modules_discover
  local manifest
  manifest=$(plan_defaults "${run_dir}/scan-a.json" "${run_dir}/scan-b.json")

  if [ -n "${SITEGRAFT_MANIFEST_PREFILLED:-}" ]; then
    manifest=$(cat "$SITEGRAFT_MANIFEST_PREFILLED")
  else
    manifest=$(plan_select_interactive "$manifest")
  fi

  manifest=$(manifest_freeze "$manifest") || { log_error "manifest failed validation — not frozen"; return 1; }
  echo "$manifest" > "${run_dir}/manifest.json"
  log_info "manifest frozen: ${run_dir}/manifest.json"
}
```

- [ ] **Step 2: Manual smoke test**

Run against a DDEV pair once Step 5's fixtures exist (forward reference — acceptable
here since interactive UI genuinely cannot be unit tested; tracked as a TODO comment
in the file until Step 5 lands): `bin/sitegraft plan --profile ddev-test`, confirm a
`manifest.json` is written and `jq -e '.frozen == true'` on it succeeds.

- [ ] **Step 3: Commit**

```bash
git add lib/plan.sh bin/sitegraft
git commit -m "feat(plan): wire interactive selection (gum/fzf/plain fallback) and freeze the manifest"
```

---

## Step 3 — Backup + restore

Delivers: `sitegraft backup --profile <name>` produces a full DB+files backup of B on
the orchestrator plus a working `restore.sh`; `sitegraft restore` rolls B back.

### Task 3.1: `lib/backup.sh` — DB export, wp-content archive, checksums

**Files:**
- Create: `lib/backup.sh`
- Test: `tests/unit/test_backup.bats`

**Interfaces:**
- Consumes: `wp_remote` (Task 1.4), `run_or_echo` (Task 1.1).
- Produces: `backup_checksum_protected <manifest_json> <scan_b_json>` (pure-ish
  function taking a JSON blob of already-fetched protected data instead of hitting
  the network itself, so it stays unit-testable — see step 1); `phase_backup`.

- [ ] **Step 1: Write the failing test**

`backup_checksum_protected` is deliberately factored to take pre-fetched data as
input (a map of `table/option name -> content string`) rather than calling `wp`
itself, so the checksum logic is testable without a live site.

```bash
# tests/unit/test_backup.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/backup.sh'
}

@test "backup_checksum computes a stable sha256 for identical content" {
  run backup_checksum "hello world"
  [ "$status" -eq 0 ]
  local first="$output"
  run backup_checksum "hello world"
  [ "$output" = "$first" ]
}

@test "backup_checksum differs for different content" {
  run backup_checksum "hello world"
  local a="$output"
  run backup_checksum "hello world!"
  [ "$output" != "$a" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_backup.bats`
Expected: FAIL — `lib/backup.sh` does not exist.

- [ ] **Step 3: Write `lib/backup.sh`**

```bash
#!/usr/bin/env bash
# lib/backup.sh — phase: backup. Full DB + wp-content export of B, pulled to the
# orchestrator, plus checksum snapshot of protected data and a generated restore.sh.

backup_checksum() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

phase_backup() {
  local profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      *) log_error "unknown flag for backup: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "backup requires --profile <name>"; return 1; }
  profile_load "$profile"
  : "${run_dir:=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1)}"
  [ -n "$run_dir" ] && [ -f "${run_dir}/manifest.json" ] || {
    log_error "no frozen manifest found for profile ${profile} — run 'sitegraft plan' first"
    return 1
  }

  mkdir -p "${run_dir}/backup"
  log_info "exporting B database..."
  run_or_echo bash -c "wp_remote b db export - --add-drop-table | gzip > '${run_dir}/backup/b-db.sql.gz'"
  log_info "archiving B wp-content..."
  run_or_echo bash -c "wp_remote b eval 'echo WP_CONTENT_DIR;' > '${run_dir}/backup/.wp-content-path'"

  # Checksum the protected buckets declared in the manifest (design doc §6.3).
  local manifest checksums='{}'
  manifest=$(cat "${run_dir}/manifest.json")
  local mod
  for mod in $(echo "$manifest" | jq -r '.protect | keys[]'); do
    local tables_content
    tables_content=$(wp_remote b db export - --tables="$(echo "$manifest" | jq -r --arg m "$mod" '.protect[$m].tables | join(",")')" 2>/dev/null || echo "")
    local sum; sum=$(backup_checksum "$tables_content")
    checksums=$(echo "$checksums" | jq --arg m "$mod" --arg s "sha256:${sum}" '.[$m] = $s')
  done
  manifest=$(echo "$manifest" | jq --argjson c "$checksums" '.checksums_protected_pre_graft = $c')
  echo "$manifest" > "${run_dir}/manifest.json"

  backup_generate_restore_script "$run_dir"
  touch "${run_dir}/backup.complete"
  log_info "backup complete: ${run_dir}/backup.complete"
}

backup_generate_restore_script() {
  local run_dir="$1"
  cat > "${run_dir}/restore.sh" <<EOF
#!/usr/bin/env bash
# Generated by 'sitegraft backup' for run: ${run_dir}
# Restores site B to the state captured in this run's backup/ directory.
set -euo pipefail
RUN_DIR="${run_dir}"
echo "Restoring B database from \${RUN_DIR}/backup/b-db.sql.gz ..."
gunzip -c "\${RUN_DIR}/backup/b-db.sql.gz" | wp_remote b db import -
echo "Restore complete."
EOF
  chmod +x "${run_dir}/restore.sh"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_backup.bats`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/backup.sh tests/unit/test_backup.bats
git commit -m "feat(backup): export B database, checksum protected data, generate restore.sh"
```

### Task 3.2: `restore` phase with pre-restore safety backup

**Files:**
- Modify: `lib/backup.sh` (add `phase_restore`)
- Test: covered by DDEV integration harness (Step 5) — restoring a real site is not
  meaningfully unit-testable; the function is a thin orchestration wrapper around
  already-tested pieces (`backup_generate_restore_script`'s output, `gum confirm`).

**Interfaces:**
- Consumes: `run_or_echo`, `log_info`/`log_warn` (Task 1.1).
- Produces: `phase_restore` (the function `bin/sitegraft` dispatches to for the
  `restore` phase).

- [ ] **Step 1: Add `phase_restore` to `lib/backup.sh`**

```bash
# Appended to lib/backup.sh

phase_restore() {
  local profile="" run_dir="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) log_error "unknown flag for restore: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] && [ -n "$run_dir" ] || {
    log_error "restore requires --profile <name> --run <run-dir>"
    return 1
  }
  profile_load "$profile"
  [ -x "${run_dir}/restore.sh" ] || { log_error "no restore.sh found for run: ${run_dir}"; return 1; }

  if [ "$yes" -ne 1 ]; then
    if command -v gum >/dev/null 2>&1; then
      gum confirm "Restore B from ${run_dir}? This overwrites B's current database." || return 1
    else
      read -r -p "Restore B from ${run_dir}? This overwrites B's current database. [y/N] " ans
      [ "${ans:-n}" = "y" ] || return 1
    fi
  fi

  # Restoring is itself made reversible: snapshot B's current state first.
  local pre_restore_dir="${run_dir}/pre-restore-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$pre_restore_dir"
  log_info "snapshotting B's current state before restoring (safety net)..."
  run_or_echo bash -c "wp_remote b db export - --add-drop-table | gzip > '${pre_restore_dir}/b-db.sql.gz'"

  log_info "running ${run_dir}/restore.sh ..."
  run_or_echo "${run_dir}/restore.sh"
  log_info "restore complete. Pre-restore safety snapshot kept at ${pre_restore_dir}"
}
```

- [ ] **Step 2: Manual smoke test**

Deferred to the DDEV harness in Step 5 (Task 5.2/5.3), which runs a full
`graft` → `restore` cycle and asserts B returns to its pre-graft state.

- [ ] **Step 3: Commit**

```bash
git add lib/backup.sh
git commit -m "feat(restore): add restore phase with a pre-restore safety snapshot"
```

---

## Step 4 — Graft: media, WXR, mu-plugin mapping, remaps

Delivers: `sitegraft graft --profile <name>` performs the actual transfer, per design
doc §6.4 and §9. This is the highest-risk step — every sub-step is individually
marker-gated for resumability (design doc §6.4, last paragraph).

### Task 4.1: media sync + mu-plugin deploy/remove

**Files:**
- Create: `lib/graft.sh`
- Create: `mu-plugins/sitegraft-id-mapper.php`
- Test: `tests/unit/test_graft_mediastep.bats` (tests the rsync flag construction, not
  a real transfer — real transfer is DDEV-only, Task 5.3)

**Interfaces:**
- Consumes: `SITE_A_*`/`SITE_B_*` (Task 1.2), `run_or_echo` (Task 1.1).
- Produces: `graft_media_rsync_cmd <site_a_uploads_path> <site_b_ssh_host>
  <site_b_uploads_path>` (pure function, returns the exact `rsync` argv as a
  newline-separated list for inspection — actual execution is a thin wrapper around
  it); `graft_deploy_mu_plugin`, `graft_remove_mu_plugin`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_graft_mediastep.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_media_rsync_cmd never overwrites existing files on B" {
  run graft_media_rsync_cmd "/site-a/wp-content/uploads/" "user@host-b.example.com" "/site-b/wp-content/uploads/"
  [[ "$output" == *"--ignore-existing"* ]]
}

@test "graft_media_rsync_cmd never uses scp" {
  run graft_media_rsync_cmd "/site-a/wp-content/uploads/" "user@host-b.example.com" "/site-b/wp-content/uploads/"
  [[ "$output" != *"scp"* ]]
  [[ "$output" == *"rsync"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_graft_mediastep.bats`
Expected: FAIL — `lib/graft.sh` does not exist.

- [ ] **Step 3: Write the media + mu-plugin functions in `lib/graft.sh`**

```bash
#!/usr/bin/env bash
# lib/graft.sh — phase: graft. Media sync, WXR export/import, mu-plugin mapping,
# ID/URL remaps, optional clean/idempotence pruning. See design doc §6.4, §9.

graft_media_rsync_cmd() {
  local src="$1" dst_host="$2" dst_path="$3"
  cat <<EOF
rsync
-avz
--ignore-existing
${src}
${dst_host}:${dst_path}
EOF
}

graft_media_sync() {
  local src="${SITE_A_WP_PATH}/wp-content/uploads/"
  local dst_path="${SITE_B_WP_PATH}/wp-content/uploads/"
  log_info "syncing media (never overwriting existing files on B)..."
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo rsync -avz --ignore-existing "$src" "${SITE_B_SSH_HOST}:${dst_path}"
  else
    run_or_echo rsync -avz --ignore-existing "$src" "$dst_path"
  fi
}

graft_deploy_mu_plugin() {
  local mu_dir="${SITE_B_WP_PATH}/wp-content/mu-plugins"
  local src="${SITEGRAFT_ROOT}/mu-plugins/sitegraft-id-mapper.php"
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo ssh "$SITE_B_SSH_HOST" "mkdir -p '${mu_dir}'"
    run_or_echo rsync -avz "$src" "${SITE_B_SSH_HOST}:${mu_dir}/sitegraft-id-mapper.php"
  else
    run_or_echo mkdir -p "$mu_dir"
    run_or_echo rsync -avz "$src" "${mu_dir}/sitegraft-id-mapper.php"
  fi
}

graft_remove_mu_plugin() {
  local target="${SITE_B_WP_PATH}/wp-content/mu-plugins/sitegraft-id-mapper.php"
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo ssh "$SITE_B_SSH_HOST" "rm -f '${target}'"
  else
    run_or_echo rm -f "$target"
  fi
}
```

- [ ] **Step 4: Write `mu-plugins/sitegraft-id-mapper.php`** (verbatim from design doc §7)

```php
<?php
/**
 * Plugin Name: sitegraft ID Mapper (temporary)
 * Description: Logs old->new post/term ID pairs during a sitegraft WXR import.
 * Installed and removed automatically by `sitegraft graft` — do not install by hand.
 */

add_action( 'wp_import_insert_post', function ( $post_id, $original_post_id, $postdata, $post ) {
    $log = WP_CONTENT_DIR . '/sitegraft-id-map.log';
    $post_type = isset( $postdata['post_type'] ) ? $postdata['post_type'] : 'unknown';
    file_put_contents( $log, "{$original_post_id}\t{$post_id}\t{$post_type}\n", FILE_APPEND | LOCK_EX );
    update_post_meta( $post_id, '_sitegraft_source_id', $original_post_id );
}, 10, 4 );

add_action( 'wp_import_insert_term', function ( $term_id, $term, $original_id ) {
    $log = WP_CONTENT_DIR . '/sitegraft-id-map.log';
    file_put_contents( $log, "{$original_id}\t{$term_id}\tterm:{$term}\n", FILE_APPEND | LOCK_EX );
}, 10, 3 );
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/unit/test_graft_mediastep.bats`
Expected: PASS (2 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/graft.sh mu-plugins/sitegraft-id-mapper.php tests/unit/test_graft_mediastep.bats
git commit -m "feat(graft): add media sync (never overwrite) and mu-plugin deploy/remove"
```

### Task 4.2: WXR export, integrity-gate, transfer, import

**Files:**
- Modify: `lib/graft.sh` (add `graft_export_wxr`, `graft_integrity_gate`, `graft_import_wxr`)
- Test: `tests/unit/test_graft_integrity_gate.bats`

**Interfaces:**
- Consumes: nothing new.
- Produces: `graft_integrity_gate <wxr_file_path> <allowed_post_types_json>` (pure
  function over a file's content — exit 0/1, per design doc §6.4 step 4: non-empty,
  has `<wp:wxr_version>`, ≥1 `<item>`, every `<wp:post_type>` found ∈ allowlist).

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_graft_integrity_gate.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_integrity_gate passes a well-formed WXR file with allowed post types" {
  local f="$BATS_TEST_TMPDIR/good.xml"
  cat > "$f" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_type>page</wp:post_type></item>
</channel></rss>
EOF
  run graft_integrity_gate "$f" '["page","post"]'
  [ "$status" -eq 0 ]
}

@test "graft_integrity_gate fails on an empty file" {
  local f="$BATS_TEST_TMPDIR/empty.xml"
  : > "$f"
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
}

@test "graft_integrity_gate fails when a post_type is outside the allowlist" {
  local f="$BATS_TEST_TMPDIR/leak.xml"
  cat > "$f" <<'EOF'
<rss><channel><wp:wxr_version>1.2</wp:wxr_version>
<item><wp:post_type>page</wp:post_type></item>
<item><wp:post_type>unexpected_cpt</wp:post_type></item>
</channel></rss>
EOF
  run graft_integrity_gate "$f" '["page"]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected_cpt"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_graft_integrity_gate.bats`
Expected: FAIL — `graft_integrity_gate` does not exist yet.

- [ ] **Step 3: Add the functions to `lib/graft.sh`**

```bash
# Appended to lib/graft.sh

graft_integrity_gate() {
  local file="$1" allowed_json="$2"
  [ -s "$file" ] || { log_error "WXR file is empty: ${file}"; return 1; }
  grep -q '<wp:wxr_version>' "$file" || { log_error "no <wp:wxr_version> marker in: ${file}"; return 1; }
  local item_count; item_count=$(grep -c '<item>' "$file" || true)
  [ "$item_count" -ge 1 ] || { log_error "no <item> found in: ${file}"; return 1; }

  local found_types leaked
  found_types=$(grep -o '<wp:post_type>[^<]*</wp:post_type>' "$file" \
    | sed -E 's#</?wp:post_type>##g' | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))')
  leaked=$(jq -n --argjson found "$found_types" --argjson allowed "$allowed_json" \
    '[$found[] | select(($allowed | index(.)) | not)]')
  if [ "$(echo "$leaked" | jq 'length')" != "0" ]; then
    log_error "WXR contains post_type(s) outside the manifest allowlist: $(echo "$leaked" | jq -r 'join(", ")')"
    return 1
  fi
}

graft_export_wxr() {
  local post_types_csv="$1" export_dir="$2"
  run_or_echo wp_remote a export --post_type="$post_types_csv" --dir="$export_dir"
}

graft_import_wxr() {
  local xml_glob="$1"
  run_or_echo wp_remote b import "$xml_glob" --authors=skip
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_graft_integrity_gate.bats`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/graft.sh tests/unit/test_graft_integrity_gate.bats
git commit -m "feat(graft): add WXR export, integrity-gate, and import"
```

### Task 4.3: ID-map remap (two-pass sentinel technique)

**Files:**
- Modify: `lib/graft.sh` (add `graft_remap_attachment_ids`, `graft_check_orphan_parents`)
- Test: `tests/unit/test_graft_remap.bats`

**Interfaces:**
- Consumes: `id-map.tsv` format `old_id<TAB>new_id<TAB>post_type` (Task 4.1's
  mu-plugin log format).
- Produces: `graft_build_sentinel_commands <id_map_tsv>` (pure function — given a
  TSV, prints the exact two-pass `wp search-replace` argument tuples per design doc
  §9.1, one per line, for inspection/testing without a live site); the real
  `graft_remap_attachment_ids` wraps this and actually invokes `wp_remote b
  search-replace` for each line.

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_graft_remap.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_build_sentinel_commands emits pass-1 sentinel substitutions for attachments only" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n11\t43\tpage\n' > "$tsv"
  run graft_build_sentinel_commands "$tsv"
  [[ "$output" == *'"id":10(?!\d)'*'"id":__SITEGRAFT_10__'* ]]
  [[ "$output" != *"11"*"page"* ]] || true  # page rows must not produce id-remap commands
}

@test "graft_build_sentinel_commands pass-2 maps each sentinel to the real new id" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n' > "$tsv"
  run graft_build_sentinel_commands "$tsv"
  [[ "$output" == *'__SITEGRAFT_10__'*'42'* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_graft_remap.bats`
Expected: FAIL — `graft_build_sentinel_commands` does not exist.

- [ ] **Step 3: Add the remap functions to `lib/graft.sh`**

```bash
# Appended to lib/graft.sh

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
  local id_map_tsv="$1"
  local pass pattern replacement
  # Pass 1 fully before pass 2, per design doc §9.1 (sentinels must all land before
  # any get resolved to a real ID).
  while IFS=$'\t' read -r pass pattern replacement; do
    [ "$pass" = "1" ] || continue
    run_or_echo wp_remote b search-replace "$pattern" "$replacement" --regex --precise --skip-columns=guid
  done < <(graft_build_sentinel_commands "$id_map_tsv")
  while IFS=$'\t' read -r pass pattern replacement; do
    [ "$pass" = "2" ] || continue
    run_or_echo wp_remote b search-replace "$pattern" "$replacement" --precise --skip-columns=guid
  done < <(graft_build_sentinel_commands "$id_map_tsv")
}

# design doc §9.2 — verify.sh is where orphan post_parent gets reported; this
# function is the shared query both graft (for a debug log) and verify (for a hard
# check) can call.
graft_check_orphan_parents() {
  wp_remote b eval '
    global $wpdb;
    $rows = $wpdb->get_col("SELECT ID FROM {$wpdb->posts} p WHERE p.post_parent <> 0
      AND NOT EXISTS (SELECT 1 FROM {$wpdb->posts} q WHERE q.ID = p.post_parent)");
    echo implode(PHP_EOL, $rows);
  '
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_graft_remap.bats`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/graft.sh tests/unit/test_graft_remap.bats
git commit -m "feat(graft): add two-pass sentinel ID remap and orphan post_parent check"
```

### Task 4.4: domain search-replace, module post_import hooks, idempotence pruning, `phase_graft`

**Files:**
- Modify: `lib/graft.sh` (add `graft_search_replace_domain`, `graft_prune_previous_run`,
  `graft_run_module_post_import`, `phase_graft`)
- Test: `tests/unit/test_graft_phase_wiring.bats` (tests step ordering/marker logic,
  not live execution)

**Interfaces:**
- Consumes: everything from Tasks 4.1-4.3, `module_call` (Task 1.3),
  `manifest.migrate`/`manifest.clean` (Task 2.1).
- Produces: `phase_graft` (the function `bin/sitegraft` dispatches to for `graft`).

- [ ] **Step 1: Write the failing test for marker-based step skipping**

```bash
# tests/unit/test_graft_phase_wiring.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_step_done and graft_mark_step track completion via marker files" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  run graft_step_done "$run_dir" media_sync
  [ "$status" -eq 1 ]
  graft_mark_step "$run_dir" media_sync
  run graft_step_done "$run_dir" media_sync
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_graft_phase_wiring.bats`
Expected: FAIL — `graft_step_done`/`graft_mark_step` do not exist.

- [ ] **Step 3: Add the remaining functions to `lib/graft.sh`**

```bash
# Appended to lib/graft.sh

graft_step_done() { [ -f "${1}/graft.${2}.done" ]; }
graft_mark_step() { touch "${1}/graft.${2}.done"; }

graft_search_replace_domain() {
  local from="$1" to="$2"
  run_or_echo wp_remote b search-replace "$from" "$to" --skip-columns=guid --precise
  local from_escaped to_escaped
  from_escaped=$(printf '%s' "$from" | sed 's#/#\\/#g')
  to_escaped=$(printf '%s' "$to" | sed 's#/#\\/#g')
  run_or_echo wp_remote b search-replace "$from_escaped" "$to_escaped" --skip-columns=guid --precise
}

# Design doc §11 "réimport idempotent": before importing, delete any post B already
# has from a previous sitegraft run (marked with _sitegraft_source_id), for the
# post_types in this run's manifest. Distinct from the optional `clean` step, which
# removes B's pre-existing ORIGINAL content instead.
graft_prune_previous_run() {
  local post_types_csv="$1"
  local ids
  ids=$(wp_remote b post list --post_type="$post_types_csv" --meta_key=_sitegraft_source_id --field=ID)
  [ -n "$ids" ] || return 0
  log_warn "pruning $(echo "$ids" | wc -l | tr -d ' ') post(s) left by a previous sitegraft run before re-importing"
  echo "$ids" | while read -r id; do
    [ -n "$id" ] && run_or_echo wp_remote b post delete "$id" --force
  done
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

phase_graft() {
  local profile="" run_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      *) log_error "unknown flag for graft: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "graft requires --profile <name>"; return 1; }
  profile_load "$profile"
  : "${run_dir:=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1)}"
  [ -f "${run_dir}/backup.complete" ] || {
    log_error "no backup.complete marker for this run — refusing to graft without a backup"
    return 1
  }

  modules_discover
  local manifest; manifest=$(cat "${run_dir}/manifest.json")
  local post_types_csv; post_types_csv=$(echo "$manifest" | jq -r '[.migrate[].post_types[]?] | join(",")')

  graft_step_done "$run_dir" media_sync    || { graft_media_sync; graft_mark_step "$run_dir" media_sync; }
  graft_step_done "$run_dir" mu_plugin     || { graft_deploy_mu_plugin; graft_mark_step "$run_dir" mu_plugin; }
  graft_step_done "$run_dir" prune         || { graft_prune_previous_run "$post_types_csv"; graft_mark_step "$run_dir" prune; }
  graft_step_done "$run_dir" export        || {
    graft_export_wxr "$post_types_csv" "${run_dir}/export"
    for f in "${run_dir}/export"/*.xml; do
      graft_integrity_gate "$f" "$(echo "$manifest" | jq -c '[.migrate[].post_types[]?]')" || return 1
    done
    graft_mark_step "$run_dir" export
  }
  graft_step_done "$run_dir" import        || { graft_import_wxr "${run_dir}/export/*.xml"; graft_mark_step "$run_dir" import; }
  graft_step_done "$run_dir" fetch_id_map  || {
    run_or_echo rsync -avz "${SITE_B_SSH_HOST:+${SITE_B_SSH_HOST}:}${SITE_B_WP_PATH}/wp-content/sitegraft-id-map.log" "${run_dir}/id-map.tsv"
    graft_mark_step "$run_dir" fetch_id_map
  }
  graft_step_done "$run_dir" mu_cleanup    || { graft_remove_mu_plugin; graft_mark_step "$run_dir" mu_cleanup; }
  graft_step_done "$run_dir" remap_ids     || { graft_remap_attachment_ids "${run_dir}/id-map.tsv"; graft_mark_step "$run_dir" remap_ids; }
  graft_step_done "$run_dir" remap_domain  || {
    graft_search_replace_domain "$(echo "$manifest" | jq -r '.options.search_replace.from')" "$(echo "$manifest" | jq -r '.options.search_replace.to')"
    graft_mark_step "$run_dir" remap_domain
  }
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_graft_phase_wiring.bats`
Expected: PASS (1 test)

- [ ] **Step 5: Commit**

```bash
git add lib/graft.sh tests/unit/test_graft_phase_wiring.bats
git commit -m "feat(graft): wire full graft phase with per-step markers, domain remap, module hooks, idempotence pruning"
```

---

## Step 5 — Verify + DDEV integration harness

Delivers: `sitegraft verify --profile <name>` plus the DDEV harness that is the
actual safety proof of the whole tool (design doc §10).

### Task 5.1: `lib/verify.sh` — counts, checksums, front page, nav, HTTP, report

**Files:**
- Create: `lib/verify.sh`
- Test: `tests/unit/test_verify.bats`

**Interfaces:**
- Consumes: `manifest.checksums_protected_pre_graft` (Task 3.1), `backup_checksum`
  (Task 3.1).
- Produces: `verify_compare_checksums <manifest_json> <recomputed_checksums_json>`
  (pure function — exit 0 if identical, 1 with a diff listed otherwise);
  `phase_verify`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_verify.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/verify.sh'
}

@test "verify_compare_checksums passes when pre and post checksums match" {
  local manifest='{"checksums_protected_pre_graft":{"plugin-x":"sha256:abc"}}'
  local recomputed='{"plugin-x":"sha256:abc"}'
  run verify_compare_checksums "$manifest" "$recomputed"
  [ "$status" -eq 0 ]
}

@test "verify_compare_checksums hard-fails when a protected checksum changed" {
  local manifest='{"checksums_protected_pre_graft":{"plugin-x":"sha256:abc"}}'
  local recomputed='{"plugin-x":"sha256:DIFFERENT"}'
  run verify_compare_checksums "$manifest" "$recomputed"
  [ "$status" -eq 1 ]
  [[ "$output" == *"plugin-x"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_verify.bats`
Expected: FAIL — `lib/verify.sh` does not exist.

- [ ] **Step 3: Write `lib/verify.sh`**

```bash
#!/usr/bin/env bash
# lib/verify.sh — phase: verify. Read-only smoke checks on B after a graft.

verify_compare_checksums() {
  local manifest="$1" recomputed="$2"
  local diffs
  diffs=$(jq -n --argjson pre "$(echo "$manifest" | jq '.checksums_protected_pre_graft')" --argjson post "$recomputed" \
    '[$pre | keys[] as $k | select($pre[$k] != $post[$k]) | $k]')
  if [ "$(echo "$diffs" | jq 'length')" != "0" ]; then
    log_error "protected data changed for: $(echo "$diffs" | jq -r 'join(", ")')"
    echo "$diffs"
    return 1
  fi
}

phase_verify() {
  local profile="" run_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      *) log_error "unknown flag for verify: $1"; return 1 ;;
    esac
  done
  [ -n "$profile" ] || { log_error "verify requires --profile <name>"; return 1; }
  profile_load "$profile"
  : "${run_dir:=$(ls -dt "${SITEGRAFT_STATE_DIR}/${profile}-"* 2>/dev/null | head -1)}"
  local manifest; manifest=$(cat "${run_dir}/manifest.json")
  local report="${run_dir}/verify-report.md"
  local hard_fail=0

  {
    echo "# sitegraft verify report — ${run_dir}"
    echo
  } > "$report"

  local recomputed='{}'
  local mod
  for mod in $(echo "$manifest" | jq -r '.protect | keys[]'); do
    local tables_content sum
    tables_content=$(wp_remote b db export - --tables="$(echo "$manifest" | jq -r --arg m "$mod" '.protect[$m].tables | join(",")')" 2>/dev/null || echo "")
    sum=$(backup_checksum "$tables_content")
    recomputed=$(echo "$recomputed" | jq --arg m "$mod" --arg s "sha256:${sum}" '.[$m] = $s')
  done
  if verify_compare_checksums "$manifest" "$recomputed" >> "$report" 2>&1; then
    echo "- [x] protected data unchanged" >> "$report"
  else
    echo "- [ ] **HARD FAIL: protected data changed** — see above" >> "$report"
    hard_fail=1
  fi

  local orphans; orphans=$(graft_check_orphan_parents)
  if [ -z "$orphans" ]; then
    echo "- [x] no orphan post_parent references" >> "$report"
  else
    echo "- [ ] orphan post_parent references found: ${orphans}" >> "$report"
  fi

  local front_id; front_id=$(wp_remote b option get page_on_front 2>/dev/null || echo "")
  if [ -n "$front_id" ] && wp_remote b post get "$front_id" --field=ID >/dev/null 2>&1; then
    echo "- [x] page_on_front resolves to an existing page" >> "$report"
  else
    echo "- [ ] page_on_front does not resolve — check manually" >> "$report"
  fi

  log_info "verify report written: ${report}"
  return "$hard_fail"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_verify.bats`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/verify.sh tests/unit/test_verify.bats
git commit -m "feat(verify): add checksum comparison, orphan check, front page check, report"
```

### Task 5.2: DDEV fixtures — fake Etch content on A, fake protected plugin on B

**Files:**
- Create: `tests/integration/fixtures/site-a-seed.sh`
- Create: `tests/integration/fixtures/site-b-fake-plugin/fake-plugin.php`
- Test: none (fixtures are exercised by Task 5.3's integration test, not unit-tested)

- [ ] **Step 1: Write `tests/integration/fixtures/site-b-fake-plugin/fake-plugin.php`**

A minimal fake plugin standing in for a real business plugin (design doc §10.3):
its own CPT, its own SQL table via `dbDelta`, its own option — everything sitegraft
must treat as protected data.

```php
<?php
/**
 * Plugin Name: sitegraft Test Fixture — Fake Booking Plugin
 * Description: Simulates a live business plugin for the sitegraft DDEV integration
 * harness. Not a real plugin — do not use outside tests/integration/.
 */

add_action( 'init', function () {
    register_post_type( 'fakebooking_reservation', [
        'label' => 'Fake Reservations',
        'public' => false,
        'show_ui' => true,
        'supports' => [ 'title' ],
    ] );
} );

register_activation_hook( __FILE__, function () {
    global $wpdb;
    require_once ABSPATH . 'wp-admin/includes/upgrade.php';
    $table = $wpdb->prefix . 'fakebooking_reservations';
    $charset_collate = $wpdb->get_charset_collate();
    dbDelta( "CREATE TABLE {$table} (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        guest_name VARCHAR(191) NOT NULL,
        room_number INT NOT NULL,
        PRIMARY KEY (id)
    ) {$charset_collate};" );

    $wpdb->insert( $table, [ 'guest_name' => 'Example Guest', 'room_number' => 12 ] );
    update_option( 'fakebooking_settings', [ 'currency' => 'CHF', 'tax_rate' => 3.7 ] );
} );
```

- [ ] **Step 2: Write `tests/integration/fixtures/site-a-seed.sh`**

```bash
#!/usr/bin/env bash
# tests/integration/fixtures/site-a-seed.sh — seed fake Etch-shaped content on
# site A for the DDEV harness. No real Etch license required — only the shape of
# the data (CPTs + options) matters for testing sitegraft's mechanics.
set -euo pipefail
DDEV_PROJECT="$1" # e.g. sitegraft-test-a

ddev --project "$DDEV_PROJECT" wp eval '
  register_post_type("etch_cfs", ["label" => "Etch CFS", "public" => false, "show_ui" => true, "supports" => ["title","custom-fields"]]);
  register_post_type("etch_cpts", ["label" => "Etch CPTs", "public" => false, "show_ui" => true, "supports" => ["title"]]);
'
ddev --project "$DDEV_PROJECT" wp post create --post_type=page --post_title="Home" --post_status=publish
ddev --project "$DDEV_PROJECT" wp post create --post_type=etch_cfs --post_title="Hero CFS" --post_status=publish
ddev --project "$DDEV_PROJECT" wp option update etch_settings '{"theme_mode":"dark"}' --format=json
ddev --project "$DDEV_PROJECT" wp option update etch_styles '{"primary_color":"#111"}' --format=json
ddev --project "$DDEV_PROJECT" wp option update automatic_css_settings '{"spacing_scale":"1.25"}' --format=json
```

- [ ] **Step 3: Commit**

```bash
git add tests/integration/fixtures/
git commit -m "test(integration): add DDEV fixtures for fake Etch content (A) and a fake protected plugin (B)"
```

### Task 5.3: `tests/integration/ddev-harness.sh` — full pipeline assertion

**Files:**
- Create: `tests/integration/ddev-harness.sh`

**Interfaces:**
- Consumes: `bin/sitegraft` (all phases, Steps 1-5), fixtures from Task 5.2.
- Produces: an exit-code contract — 0 means the full pipeline ran and the protected
  data was byte-identical before/after both `graft` and `restore`; non-zero means a
  regression, printed to stderr with which assertion failed.

- [ ] **Step 1: Write `tests/integration/ddev-harness.sh`**

```bash
#!/usr/bin/env bash
# tests/integration/ddev-harness.sh — the real safety proof of sitegraft.
# Spins up two disposable DDEV sites, runs a full scan->plan->backup->graft->verify
# cycle, and asserts B's protected plugin data is byte-identical before and after.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_A="sitegraft-test-a"
PROJECT_B="sitegraft-test-b"

cleanup() {
  ddev delete -Oy "$PROJECT_A" >/dev/null 2>&1 || true
  ddev delete -Oy "$PROJECT_B" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> starting disposable DDEV sites"
( mkdir -p "/tmp/${PROJECT_A}" && cd "/tmp/${PROJECT_A}" && ddev config --project-name="$PROJECT_A" --project-type=wordpress --docroot=. && ddev start && ddev wp core download && ddev wp core install --url=https://a.example.com --title=A --admin_user=admin --admin_password=admin --admin_email=admin@example.com )
( mkdir -p "/tmp/${PROJECT_B}" && cd "/tmp/${PROJECT_B}" && ddev config --project-name="$PROJECT_B" --project-type=wordpress --docroot=. && ddev start && ddev wp core download && ddev wp core install --url=https://b.example.com --title=B --admin_user=admin --admin_password=admin --admin_email=admin@example.com )

echo "==> seeding fixtures"
"${ROOT}/tests/integration/fixtures/site-a-seed.sh" "$PROJECT_A"
cp "${ROOT}/tests/integration/fixtures/site-b-fake-plugin/fake-plugin.php" "/tmp/${PROJECT_B}/wp-content/mu-plugins/fake-plugin.php"
mkdir -p "/tmp/${PROJECT_B}/wp-content/mu-plugins"
ddev --project "$PROJECT_B" wp eval 'do_action("activate_fake-plugin.php");' # dbDelta + seed via activation hook logic, invoked directly since it's an mu-plugin (no real activation event)

echo "==> snapshotting B's protected data (pre-graft)"
PRE_CHECKSUM=$(ddev --project "$PROJECT_B" wp db export - --tables="$(ddev --project "$PROJECT_B" wp eval 'global $wpdb; echo $wpdb->prefix."fakebooking_reservations";')" | shasum -a 256)

echo "==> writing a local sitegraft profile for this harness run"
cat > "${ROOT}/profiles/ddev-test.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/tmp/${PROJECT_A}"
SITE_A_WP_CMD="ddev --project ${PROJECT_A} wp"
SITE_A_URL="https://a.example.com"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/tmp/${PROJECT_B}"
SITE_B_WP_CMD="ddev --project ${PROJECT_B} wp"
SITE_B_URL="https://b.example.com"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-ddev-test-runs"
EOF

echo "==> running scan -> plan -> backup -> graft -> verify"
"${ROOT}/bin/sitegraft" scan --profile ddev-test
RUN_DIR=$(ls -dt /tmp/sitegraft-ddev-test-runs/ddev-test-* | head -1)
SITEGRAFT_MANIFEST_PREFILLED="${ROOT}/tests/integration/fixtures/prefilled-manifest.json" \
  "${ROOT}/bin/sitegraft" plan --profile ddev-test --run "$RUN_DIR"
"${ROOT}/bin/sitegraft" backup --profile ddev-test --run "$RUN_DIR"
"${ROOT}/bin/sitegraft" graft --profile ddev-test --run "$RUN_DIR"
"${ROOT}/bin/sitegraft" verify --profile ddev-test --run "$RUN_DIR"

echo "==> asserting protected data is unchanged (post-graft)"
POST_CHECKSUM=$(ddev --project "$PROJECT_B" wp db export - --tables="$(ddev --project "$PROJECT_B" wp eval 'global $wpdb; echo $wpdb->prefix."fakebooking_reservations";')" | shasum -a 256)
if [ "$PRE_CHECKSUM" != "$POST_CHECKSUM" ]; then
  echo "FAIL: protected fake plugin data changed during graft" >&2
  exit 1
fi

echo "==> asserting migrated content is present on B"
ddev --project "$PROJECT_B" wp post list --post_type=etch_cfs --field=post_title | grep -q "Hero CFS"

echo "==> running restore and re-checking protected + migrated state"
"${ROOT}/bin/sitegraft" restore --profile ddev-test --run "$RUN_DIR" --yes
RESTORE_CHECKSUM=$(ddev --project "$PROJECT_B" wp db export - --tables="$(ddev --project "$PROJECT_B" wp eval 'global $wpdb; echo $wpdb->prefix."fakebooking_reservations";')" | shasum -a 256)
if [ "$PRE_CHECKSUM" != "$RESTORE_CHECKSUM" ]; then
  echo "FAIL: protected fake plugin data differs after restore" >&2
  exit 1
fi

echo "ALL ASSERTIONS PASSED"
rm -f "${ROOT}/profiles/ddev-test.conf"
```

Note: `tests/integration/fixtures/prefilled-manifest.json` referenced above is
generated once by hand during this task's implementation (run `plan` interactively
once against the two DDEV sites, inspect the resulting `manifest.json`, save it as
the fixture) — it is a real, valid frozen manifest for the fixture data, committed
to the repo so the harness runs non-interactively in CI-less local runs.

- [ ] **Step 2: Run the harness end-to-end and fix whatever the first real run surfaces**

Run: `tests/integration/ddev-harness.sh`
Expected: `ALL ASSERTIONS PASSED`. This is the first point in the whole plan where
every earlier task's code actually runs against real WordPress installs — budget
time for fixing integration-only bugs the unit tests couldn't catch (this is
expected and normal, not a sign the plan was wrong; see design doc §0.2 R2 and R4).

- [ ] **Step 3: Commit**

```bash
git add tests/integration/ddev-harness.sh tests/integration/fixtures/prefilled-manifest.json
git commit -m "test(integration): add full DDEV harness proving non-contamination of protected data"
```

---

## Step 6 — Polish

Delivers: a v1 ready to publish per `docs/definition-of-done.md`.

### Task 6.1: `--dry-run` audit across all writing phases

**Files:**
- Modify: `bin/sitegraft` (parse a global `--dry-run` flag, export `SITEGRAFT_DRY_RUN=1`)
- Modify: any function in `lib/backup.sh` / `lib/graft.sh` found not yet using
  `run_or_echo` for a mutating command

- [ ] **Step 1: Add `--dry-run` parsing to `bin/sitegraft`**

```bash
# In bin/sitegraft's main(), before the phase case statement:
local args=() dry_run=0
for arg in "$@"; do
  if [ "$arg" = "--dry-run" ]; then dry_run=1; else args+=("$arg"); fi
done
set -- "${args[@]}"
[ "$dry_run" -eq 1 ] && export SITEGRAFT_DRY_RUN=1
```

- [ ] **Step 2: Grep every `lib/*.sh` for mutating wp-cli/rsync/ssh calls not wrapped in `run_or_echo`**

Run: `grep -n -E "wp_remote (b|a) (import|option update|search-replace|post delete|db import)|rsync -avz [^-]|ssh " lib/*.sh | grep -v run_or_echo`
Expected: empty output. Fix any hit by wrapping it in `run_or_echo`.

- [ ] **Step 3: Manual smoke test**

Run: `bin/sitegraft graft --profile ddev-test --dry-run` against the DDEV harness
sites (fixtures already seeded from Step 5) and confirm no actual DB/file mutation
occurs (re-run the pre-graft checksum from Task 5.3 and confirm it is unchanged, then
confirm the command printed the actions it would have taken).

- [ ] **Step 4: Commit**

```bash
git add bin/sitegraft lib/
git commit -m "fix(dry-run): ensure every mutating call across all phases respects --dry-run"
```

### Task 6.2: usage docs, install instructions

**Files:**
- Modify: `README.md` (verify the Usage section matches the final CLI flags exactly —
  update if any task above changed a flag name)
- Create (only if README.md's usage section grows too long to stay scannable):
  `docs/usage.md`

- [ ] **Step 1: Re-read `README.md` against the actual final `bin/sitegraft` flag parsing**

Confirm every documented command (`scan`, `plan`, `backup`, `graft`, `verify`,
`restore`) and flag (`--profile`, `--run`, `--dry-run`, `--yes`) matches what
`bin/sitegraft`'s `case` statements actually accept. Fix any drift.

- [ ] **Step 2: Add a "Requirements install" snippet to `README.md`** (macOS + Linux)

```sh
# macOS
brew install jq gum bats-core rsync ddev/ddev/ddev

# Debian/Ubuntu (gum: see https://github.com/charmbracelet/gum#installation)
sudo apt install jq rsync
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): sync usage section with final CLI flags, add install snippet"
```

### Task 6.3: final self-review pass against the design doc

**Files:** none created — a review pass over the whole repo.

- [ ] **Step 1: Re-read `docs/superpowers/specs/2026-08-19-sitegraft-design.md` top to
      bottom against the actual `lib/`/`modules/`/`bin/` code**

For each design doc section (§3 module contract, §4 manifest format, §5 profile
format, §6 phase deroulé, §7 mu-plugin, §8 media/import ordering, §9 remaps, §11 edge
cases), confirm the shipped code matches what's documented. Fix any drift in
whichever side is wrong (usually the code, since the design doc is the spec — but if
implementation revealed the spec was wrong, update the design doc and note it in
`docs/status.md`).

- [ ] **Step 2: Grep the whole repo for anything that looks like a real secret/host**

Run: `grep -rniE "([0-9]{1,3}\.){3}[0-9]{1,3}|ssh-rsa|-----BEGIN|password\s*=|token\s*=" --include='*.sh' --include='*.md' --include='*.conf' --include='*.php' .`
Expected: no real IPs, keys, passwords, or tokens — only placeholder text
(`example.com`, `user@host`) if anything matches at all. This is the last gate before
the repo is safe to publish publicly (design doc §0, LICENSE task below).

- [ ] **Step 3: Bump `SITEGRAFT_VERSION` in `bin/sitegraft` to `1.0.0`** (per
      `docs/decisions/`-style versioning convention in project `CLAUDE.md`) once all
      DoD items in `docs/definition-of-done.md` are checked.

- [ ] **Step 4: Update `docs/status.md` and `docs/todo.md`** to reflect v1 complete,
      move any deferred items (e.g. a real `motopress.sh` module, `docs/usage.md`
      split) into `docs/todo.md` → Backlog.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(release): v1.0.0 — full scan-plan-backup-graft-verify-restore pipeline"
```
