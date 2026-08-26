# sitegraft Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build sitegraft, a portable bash CLI that grafts the design/content layer of
a freshly built WordPress site (A) onto a live target site (B) without touching B's
plugin data, in six independently shippable steps matching the phase model
(`scan → plan → backup → graft → verify → restore`).

**Architecture:** A thin `bin/sitegraft` dispatcher sources, per phase, only the
`lib/*.sh` files that phase needs, plus a convention-based module registry
(`modules/*.sh`). Every phase writes to a per-run state directory on the
orchestrating machine and is independently re-runnable. No code touches A or B
outside of read-only `wp-cli` introspection until `backup.complete` exists for a
run. The DDEV integration harness is **not** a Step 5 afterthought: a minimal
skeleton (two disposable sites, fixtures, teardown) ships in Step 1, and each
later step grows its assertions — see the revision note below.

**Tech Stack:** bash (3.2-compatible), `wp-cli`, `jq`, `rsync`, `ssh`, `gum`
(fallback `fzf`, fallback plain prompts), `bats-core` for unit tests, `ddev` for the
integration harness.

**Spec:** `docs/superpowers/specs/2026-08-19-sitegraft-design.md` — this plan argues
from that document; every task below cites the design doc section it implements.
Read the design doc first — this plan does not repeat its rationale, only its
translation into buildable steps.

**Revision note (2026-08-19):** this plan was rewritten after an independent review
(`docs/plans/2026-08-19-sitegraft-plan-review.md`) found 7 concrete code defects
(A1-A7) and 3 scope gaps (B1-B3) in the first draft, plus a sequencing
recommendation (C1). Every finding is resolved in the tasks below; the review file
records one resolution line per finding. If you read an older copy of this plan,
discard it — this version supersedes it entirely, not incrementally.

## Global Constraints

- Bash 3.2 compatible: no `declare -A`, no `mapfile`, no `${var,,}` (design doc ADR 0003).
- Never `scp` — always `rsync` for file transfer.
- Never raw SQL filtered by hand for content — WXR (`wp export`/`wp import`) only;
  options via `wp option get/update --format=json`; plugin-owned tables via
  `wp db export --tables=`.
- Never `sed`/raw regex on WordPress DB content — always `wp search-replace`.
- **Every `wp search-replace` call is scoped with `--tables=` to content tables
  only** (`{$prefix}posts,{$prefix}postmeta,{$prefix}options`) — never run
  unscoped, which would reach into a protected plugin's own tables (design doc
  §9.1/§9.4, review finding A6).
- **Every checksum of protected data uses the exact same normalization function**
  (`backup_checksum` in `lib/backup.sh`, strips `mysqldump`'s `-- ` comment lines
  before hashing) in `backup`, `verify`, and the DDEV harness — never three
  separate implementations (design doc §6.3, review finding A5).
- Any file transfer whose source is A is routed **A → orchestrator → B**, through
  the run directory, never assumed to flow directly between A and B (design doc
  §6.4 step 1/step 5, review finding A4).
- Any script generated as an artifact for later standalone use (`restore.sh`)
  bakes in literal, resolved commands and never calls back into a sitegraft bash
  function (design doc §6.3, review finding A2).
- Every script starts with `set -euo pipefail` and a `mktemp -d` + `trap cleanup EXIT`
  pattern for any local temp directory it creates.
- Every phase that writes must support `--dry-run` (wired incrementally per task,
  finished in Step 6).
- Zero secrets, zero real hosts/IPs, zero client names anywhere — including in test
  fixtures and example output. Use `example.com`, `user@host`, `<profile>` only.
- All code, comments, and docs in US English — the whole repo is public (see
  project `CLAUDE.md`).

---

## Step 1 — Core + profiles/credentials + scan + DDEV harness skeleton

Delivers: `sitegraft scan --profile <name>` runs end-to-end against two real (or
DDEV) WordPress sites and produces valid `scan-a.json` / `scan-b.json` — plus a
running DDEV harness skeleton that later steps grow instead of writing from
scratch in Step 5 (design doc §10, review finding C1).

### Task 1.1: `lib/core.sh` + `bin/sitegraft` — logging, dependency checks, safe temp/trap, dry-run helper, per-phase dispatch

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

- [ ] **Step 5: Write `bin/sitegraft` — dispatches to a phase, sourcing only what that phase needs**

Each phase sources only the `lib/*.sh` files it actually depends on, rather than
sourcing every file for every phase. This matters in practice: within Step 1, only
`scan` can run at all (the other phases' `lib/*.sh` files don't exist yet), and a
harness that tries `sitegraft scan` as soon as Step 1 lands (see Task 1.5) would
fail on a missing `lib/manifest.sh` if the dispatcher tried to source it
unconditionally for every phase.

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
    scan)
      . "${SITEGRAFT_ROOT}/lib/profile.sh"
      . "${SITEGRAFT_ROOT}/lib/modules.sh"
      . "${SITEGRAFT_ROOT}/lib/inventory.sh"
      phase_scan "$@"
      ;;
    plan)
      . "${SITEGRAFT_ROOT}/lib/profile.sh"
      . "${SITEGRAFT_ROOT}/lib/modules.sh"
      . "${SITEGRAFT_ROOT}/lib/inventory.sh"
      . "${SITEGRAFT_ROOT}/lib/manifest.sh"
      . "${SITEGRAFT_ROOT}/lib/plan.sh"
      phase_plan "$@"
      ;;
    backup)
      . "${SITEGRAFT_ROOT}/lib/profile.sh"
      . "${SITEGRAFT_ROOT}/lib/inventory.sh"
      . "${SITEGRAFT_ROOT}/lib/backup.sh"
      phase_backup "$@"
      ;;
    graft)
      . "${SITEGRAFT_ROOT}/lib/profile.sh"
      . "${SITEGRAFT_ROOT}/lib/modules.sh"
      . "${SITEGRAFT_ROOT}/lib/inventory.sh"
      . "${SITEGRAFT_ROOT}/lib/graft.sh"
      phase_graft "$@"
      ;;
    verify)
      . "${SITEGRAFT_ROOT}/lib/profile.sh"
      . "${SITEGRAFT_ROOT}/lib/inventory.sh"
      . "${SITEGRAFT_ROOT}/lib/backup.sh"
      . "${SITEGRAFT_ROOT}/lib/graft.sh"
      . "${SITEGRAFT_ROOT}/lib/verify.sh"
      phase_verify "$@"
      ;;
    restore)
      . "${SITEGRAFT_ROOT}/lib/profile.sh"
      . "${SITEGRAFT_ROOT}/lib/backup.sh"
      phase_restore "$@"
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

> **SUPERSEDED — corrected in the post-review fix-pack (B2, verified live):**
> the `grep -vE` shape check above has no end-of-line anchor, so
> `SITE_A_ALIAS="a"; touch /tmp/PWNED` matches as a valid *prefix* and is
> accepted; a double-quoted value can contain anything except a literal `"`,
> so `SITE_A_ALIAS="$(touch /tmp/PWNED)"` also passes the shape check —
> either payload then executes on `. "$file"`. The actual `lib/profile.sh`
> no longer sources the file at all: it parses it itself line by line
> (`profile_parse_file`, replacing `profile_validate_file`), anchors the
> assignment regex at both ends via `[[ =~ ^KEY="value"$ ]]`, restricts keys
> to a fixed whitelist (`SITEGRAFT_PROFILE_KEYS`: `SITE_A_*`/`SITE_B_*`/
> `SITEGRAFT_*`), and only ever does a plain `export "key=value"` of the
> literal captured text — never `eval`, never `source`. It also unsets every
> whitelisted key before parsing (a stale `SITEGRAFT_CREDS_FILE` from an
> earlier `profile_load` call in the same shell must not leak into a later
> one, m10) and requires the `.creds` file to be mode 600 (M4/§5.2). See
> `lib/profile.sh` and `tests/unit/test_profile.bats` for the real,
> current implementation.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_profile.bats`
Expected: PASS (3 tests)

- [ ] **Step 5: Write `profiles/example.conf`** (exact content from design doc §5.1,
      copied verbatim so the repo ships a real, working example):

```sh
# profiles/example.conf — sitegraft profile template. No secrets here, but a
# real profile holds real hosts and paths, so profiles/*.conf are gitignored.

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
# "name" matches wp-cli's own `plugin list` field (which is also the plugin's
# real folder name) — the same field inventory_stack_diff resolves against
# (design doc §3.2, §12).
# my_plugin_detect() { jq -e '.plugins[] | select(.name == "my-plugin")' "$1" >/dev/null 2>&1; }

# At least one of the three below must exist.
# my_plugin_post_types() { printf 'my_cpt\n'; }
# my_plugin_option_keys() { printf 'my_plugin_settings\n'; }
# my_plugin_option_keys_exclude() { printf 'my_plugin_license_*\n'; }
# my_plugin_tables() { printf 'my_plugin_data\n'; }

# Optional: run after WXR import + generic remaps, for module-specific fixups.
# my_plugin_post_import() { local state_dir="$1" id_map_tsv="$2" wp_cmd_b="$3"; }

# Optional: this module's plugin is also a §12 stack-sync component (like etch
# or acss) — one candidate slug per line, most-preferred/current first. A
# plugin's real folder name can change across versions (see the ACSS v4 case,
# design doc §3.4) — detection may match multiple candidate slugs; paths
# always come from scan resolution, never from the module. Omit this function
# entirely if the module isn't a stack-syncable plugin (most won't be).
# my_plugin_stack_candidates() { printf 'my-plugin\nmy-plugin-legacy-slug\n'; }
```

- [ ] **Step 6: Commit**

```bash
git add lib/modules.sh modules/_template.sh tests/unit/test_modules.bats
git commit -m "feat(modules): add convention-based module discovery and registry"
```

### Task 1.4: DDEV integration harness skeleton + fixtures

**Files:**
- Create: `tests/integration/fixtures/site-a-seed.sh`
- Create: `tests/integration/fixtures/site-b-fake-plugin/fake-plugin.php`
- Create: `tests/integration/ddev-harness.sh` (skeleton only — spins up, seeds, tears
  down; every later step appends to this same file rather than writing a new one)
- Test: none (integration-only; run manually, see step 4)

**Interfaces:**
- Produces: two disposable DDEV projects (`sitegraft-test-a`, `sitegraft-test-b`)
  seeded with fixture content, torn down unconditionally on exit. This is the
  review's finding C1: the harness exists from Step 1 onward instead of being
  written as a single monolithic script in what used to be Step 5, so every later
  task gets real integration feedback the moment it lands.

> **Corrected during Step 1 implementation, verified against a real DDEV
> install (v1.25.2):** the version of this task below has three fixes the
> original draft got wrong. (1) `ddev --project <name> wp ...` is not valid
> syntax at all — `ddev` has no such flag, `wp` only exists as a
> project-scoped custom command resolved from the current directory. The
> fix is `ddev exec --raw -p <name> -- wp ...`, which works from anywhere;
> `--raw` is required or `ddev exec` reparses the command through an inner
> shell that mangles PHP `$variable`s. (2) A one-off `wp eval
> register_post_type(...)` does not persist across separate wp-cli process
> invocations — site A needs a real mu-plugin fixture, exactly like site B's,
> or a later `wp post-type list` (including sitegraft's own `scan`) never
> sees the type. (3) `fakebooking_reservation` (23 chars) exceeds
> WordPress's 20-character post_type slug limit and floods every request
> with a notice — renamed to `fake_reservation` (16 chars).

- [ ] **Step 1: Write `tests/integration/fixtures/site-b-fake-plugin/fake-plugin.php`**

A minimal fake plugin standing in for a real business plugin (design doc §10): its
own CPT, its own SQL table via `dbDelta`, its own option — everything sitegraft
must treat as protected data.

```php
<?php
/**
 * Plugin Name: sitegraft Test Fixture — Fake Booking Plugin
 * Description: Simulates a live business plugin for the sitegraft DDEV integration
 * harness. Not a real plugin — do not use outside tests/integration/.
 */

add_action( 'init', function () {
    // Post type slugs are capped at 20 characters by WordPress core
    // (register_post_type() triggers a _doing_it_wrong() notice past that,
    // which floods wp-cli's output on every request — verified against a
    // real install). "fakebooking_reservation" (23 chars) was too long;
    // "fake_reservation" (16 chars) stays under the limit.
    register_post_type( 'fake_reservation', [
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

Note the table name (`fakebooking_reservations`) and option name
(`fakebooking_settings`) are unaffected — only the post_type slug had the
20-character problem; a DB table/option name has no such limit.

- [ ] **Step 2: Write `tests/integration/fixtures/site-a-fake-etch/fake-etch-cpts.php`**

Site A needs the exact same treatment as site B: a real mu-plugin, not a
one-off `wp eval`, so `etch_cfs`/`etch_cpts` are visible to every later
wp-cli invocation, including sitegraft's own `scan`.

```php
<?php
/**
 * Plugin Name: sitegraft Test Fixture — Fake Etch CPTs
 * Description: Registers the CPTs the sitegraft DDEV integration harness seeds
 * on site A, so they persist across every wp-cli invocation (a one-off
 * `wp eval register_post_type(...)` only registers it for that single process —
 * verified against a real install: a later `wp post-type list` in a fresh
 * process never sees it). Mirrors how site B's fake-plugin.php works. No real
 * Etch license required — only the shape of the data (the CPT slugs) matters
 * for testing sitegraft's mechanics. Not a real plugin — do not use outside
 * tests/integration/.
 */

add_action( 'init', function () {
    register_post_type( 'etch_cfs', [
        'label' => 'Etch CFS',
        'public' => false,
        'show_ui' => true,
        'supports' => [ 'title', 'custom-fields' ],
    ] );
    register_post_type( 'etch_cpts', [
        'label' => 'Etch CPTs',
        'public' => false,
        'show_ui' => true,
        'supports' => [ 'title' ],
    ] );
} );
```

- [ ] **Step 3: Write `tests/integration/fixtures/site-a-seed.sh`**

Seeds a "Home" page and points `page_on_front`/`show_on_front` at it — this is
what later lets the harness assert `page_on_front` was remapped to the **correct**
page on B, not merely to *some* existing page (design doc §10, review finding B3).
Assumes the mu-plugin from step 2 is already dropped into place by the harness
(step 4) before this runs.

```bash
#!/usr/bin/env bash
# tests/integration/fixtures/site-a-seed.sh — seed fake Etch-shaped content on
# site A for the DDEV harness. No real Etch license required — only the shape of
# the data (CPTs + options) matters for testing sitegraft's mechanics.
#
# The etch_cfs/etch_cpts post types must already be registered by the time
# this runs (see fixtures/site-a-fake-etch/fake-etch-cpts.php, dropped into
# site A's mu-plugins/ by the harness before calling this script) — a one-off
# `wp eval register_post_type(...)` only registers a post type for that single
# process; it is invisible to every later wp-cli invocation, including the
# `wp post create --post_type=etch_cfs` call below and sitegraft's own `scan`
# (verified against a real install).
set -euo pipefail
DDEV_PROJECT="$1" # e.g. sitegraft-test-a

HOME_ID=$(ddev exec --raw -p "$DDEV_PROJECT" -- wp post create --post_type=page --post_title="Home" --post_status=publish --porcelain)
ddev exec --raw -p "$DDEV_PROJECT" -- wp post create --post_type=etch_cfs --post_title="Hero CFS" --post_status=publish
ddev exec --raw -p "$DDEV_PROJECT" -- wp option update show_on_front page
ddev exec --raw -p "$DDEV_PROJECT" -- wp option update page_on_front "$HOME_ID"
ddev exec --raw -p "$DDEV_PROJECT" -- wp option update etch_settings '{"theme_mode":"dark"}' --format=json
ddev exec --raw -p "$DDEV_PROJECT" -- wp option update etch_styles '{"primary_color":"#111"}' --format=json
ddev exec --raw -p "$DDEV_PROJECT" -- wp option update automatic_css_settings '{"spacing_scale":"1.25"}' --format=json
```

- [ ] **Step 4: Write the harness skeleton, `tests/integration/ddev-harness.sh`**

No sitegraft phases run yet — that's added incrementally in Tasks 1.5, 3.2, and 5.2.
`SITEGRAFT_HARNESS_STOP_AFTER` lets each later task validate its own increment
without needing every later phase to exist yet.

```bash
#!/usr/bin/env bash
# tests/integration/ddev-harness.sh — the real safety proof of sitegraft.
# Grows incrementally as each phase lands (design doc §10, review finding C1).
# Spins up two disposable DDEV sites, seeds fixtures, and tears down unconditionally.
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
mkdir -p "/tmp/${PROJECT_A}/wp-content/mu-plugins"
cp "${ROOT}/tests/integration/fixtures/site-a-fake-etch/fake-etch-cpts.php" "/tmp/${PROJECT_A}/wp-content/mu-plugins/fake-etch-cpts.php"
"${ROOT}/tests/integration/fixtures/site-a-seed.sh" "$PROJECT_A"
mkdir -p "/tmp/${PROJECT_B}/wp-content/mu-plugins"
cp "${ROOT}/tests/integration/fixtures/site-b-fake-plugin/fake-plugin.php" "/tmp/${PROJECT_B}/wp-content/mu-plugins/fake-plugin.php"
ddev exec --raw -p "$PROJECT_B" -- wp eval 'do_action("activate_fake-plugin.php");' # dbDelta + seed via activation hook logic, invoked directly since it's an mu-plugin (no real activation event)

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "seed" ]; then
  echo "SEED OK (SITEGRAFT_HARNESS_STOP_AFTER=seed)"
  exit 0
fi

echo "no later phase wired yet — see Task 1.5 (scan), 3.2 (backup), 5.2 (graft/verify/restore)"
```

Note site A's mu-plugin only needs to register on `init` — unlike site B's
fixture, it has no activation-hook logic (no table to create, no rows to
seed), so no `do_action("activate_...")` trick is needed for it.

- [ ] **Step 5: Run the skeleton manually**

Run: `SITEGRAFT_HARNESS_STOP_AFTER=seed tests/integration/ddev-harness.sh`
Expected: `SEED OK (SITEGRAFT_HARNESS_STOP_AFTER=seed)`, then both DDEV projects
torn down (`ddev list` shows neither afterward).

- [ ] **Step 6: Commit**

```bash
git add tests/integration/
git commit -m "test(integration): add DDEV harness skeleton and fixtures (grown incrementally per step)"
```

### Task 1.5: `lib/inventory.sh` + wired `scan` phase — post_types/options/tables/plugins, rendering stack, classic menus

**Files:**
- Create: `lib/inventory.sh`
- Modify: `tests/integration/ddev-harness.sh` (add the `scan` call + its assertions)
- Test: `tests/unit/test_inventory.bats`

**Interfaces:**
- Consumes: `run_or_echo`, `log_info` (Task 1.1); `SITE_A_*`/`SITE_B_*` env vars
  (Task 1.2); `SITEGRAFT_MODULES`, `module_has_fn`, `module_call` (Task 1.3) —
  `inventory_stack_diff` depends on the module registry, so `modules_discover`
  must have run before it's called (already true in `phase_plan`/`phase_graft`,
  both of which source `lib/modules.sh` and call `modules_discover` early).
- Produces: `wp_remote <alias> <wp-cli args...>` (dispatches to SSH+wp-cli or local
  `$SITE_*_WP_CMD` depending on whether `SITE_*_SSH_HOST` is set); `inventory_scan_site
  <alias> <out_json_path>` (writes the JSON shape consumed by `module_call <mod>
  detect <path>` and by `inventory_stack_diff` below — see design doc §6.1);
  `inventory_resolve_slug <scan_json> <candidates_newline_list>` (pure — returns
  the first candidate actually present in that site's own `plugin list`, or
  empty; **the only** place a candidate slug is ever turned into a "real" slug —
  design doc §3.2's rule); `inventory_stack_diff <scan_a_json> <scan_b_json>`
  (pure, but needs the module registry loaded — returns a JSON object keyed by
  `theme` plus every module declaring `<mod>_stack_candidates` [`etch`, `acss`],
  one entry per component where A's and B's *resolved* slug or version differ,
  each `{slug_a, slug_b, version_a, version_b}` with `slug_b: null` meaning
  absent on B; components already matching are omitted — design doc §12,
  Marcel's revision of review finding B1, further amended for the case where
  the resolved slug itself differs between sites, e.g. ACSS's v4 plugin-folder
  rename, design doc §3.4); `inventory_stack_matches <scan_a_json> <scan_b_json>`
  (exit 0/1 — a convenience wrapper: true iff `inventory_stack_diff` is empty);
  `phase_scan` (the function `bin/sitegraft` dispatches to for the `scan` phase).

- [ ] **Step 1: Write the failing test for `wp_remote` dispatch and `inventory_stack_diff`**

This test only checks the *dispatch decision* (SSH vs local) and the pure
stack-comparison logic, not a real wp-cli call — that is covered by the DDEV
integration harness (step 5 below). The stack-diff tests fabricate a throwaway
module (never a real one from `modules/`) declaring `_stack_candidates`, the
same isolation pattern Task 1.3's module-registry tests already use — real
module files don't need to exist yet for this task's tests to be meaningful.

```bash
# tests/unit/test_inventory.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  load '../../lib/inventory.sh'
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/acss.sh" <<'EOF'
acss_stack_candidates() { printf 'automatic-css\nacss-legacy-slug\n'; }
EOF
  modules_discover
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

@test "inventory_resolve_slug returns the first candidate actually present, never an absent one" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"plugins":[{"name":"acss-legacy-slug","version":"3.9"}]}' > "$scan"
  run inventory_resolve_slug "$scan" "$(printf 'automatic-css\nacss-legacy-slug\n')"
  [ "$output" = "acss-legacy-slug" ]
}

@test "inventory_resolve_slug returns empty when no candidate is present" {
  local scan="$BATS_TEST_TMPDIR/scan.json"
  echo '{"plugins":[]}' > "$scan"
  run inventory_resolve_slug "$scan" "$(printf 'automatic-css\nacss-legacy-slug\n')"
  [ -z "$output" ]
}

@test "inventory_stack_diff is empty when everything resolves the same on both sites" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"etch-theme","version":"1.0"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"etch-theme","version":"1.0"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$b"
  run inventory_stack_diff "$a" "$b"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "0" ]
}

@test "inventory_stack_diff reports theme as a mismatch with both resolved values when they differ" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"etch-theme","version":"1.0"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"divi","version":"4.2"},"plugins":[]}' > "$b"
  run inventory_stack_diff "$a" "$b"
  echo "$output" | jq -e '.theme.slug_a == "etch-theme" and .theme.slug_b == "divi"' >/dev/null
}

@test "inventory_stack_diff reports slug_b as null when the component is absent on B (the common case, §13)" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$b"
  run inventory_stack_diff "$a" "$b"
  echo "$output" | jq -e '.acss.slug_a == "automatic-css" and .acss.slug_b == null' >/dev/null
}

@test "inventory_stack_diff resolves each site's own real slug — the ACSS v4 plugin-folder-rename case (design doc §3.4)" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"acss-legacy-slug","version":"3.9"}]}' > "$b"
  run inventory_stack_diff "$a" "$b"
  echo "$output" | jq -e \
    '.acss.slug_a == "automatic-css" and .acss.slug_b == "acss-legacy-slug" and .acss.version_a == "4.1" and .acss.version_b == "3.9"' \
    >/dev/null
}

@test "inventory_stack_matches wraps inventory_stack_diff (true iff it's empty)" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"etch-theme"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"some-other-theme"},"plugins":[]}' > "$b"
  run inventory_stack_matches "$a" "$b"
  [ "$status" -eq 1 ]
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
# wp command (plain `wp`, or a wrapper like `ddev exec --raw -p <project> -- wp`
# — see §5.1 of the design doc) directly against SITE_<ALIAS>_WP_PATH.
wp_remote() {
  local alias_lc="$1"; shift
  local alias_uc; alias_uc=$(printf '%s' "$alias_lc" | tr '[:lower:]' '[:upper:]')
  local host_var="SITE_${alias_uc}_SSH_HOST"
  local path_var="SITE_${alias_uc}_WP_PATH"
  local cmd_var="SITE_${alias_uc}_WP_CMD"
  local host="${!host_var:-}"
  # Deliberately NOT `${!path_var:?missing ${path_var}}`. That looks like a
  # safe guard but is not one here: on bash 3.2 (Apple's /bin/bash, verified
  # live) a fatal parameter-expansion error raised *inside a function* under
  # `set -e` exits the whole process reporting $?=0 to any EXIT trap, despite
  # printing its message — so a profile missing this key would look like a
  # clean success. Always use `${!var:-}` plus an explicit check and
  # `return 1`, which propagates correctly. See lib/inventory.sh (wp_remote)
  # and lib/backup.sh (backup_wp_cmd_literal) for the shipped form.
  local path="${!path_var:-}"
  if [ -z "$path" ]; then
    log_error "missing ${path_var}"
    return 1
  fi
  local wp_cmd="${!cmd_var:-wp}"

  if [ -n "$host" ]; then
    run_or_echo ssh "$host" "$wp_cmd --path='$path' $*"
  else
    # $wp_cmd is deliberately UNQUOTED here — it may be a multi-word wrapper
    # like "ddev exec --raw -p sitegraft-test-a -- wp", and quoting it would
    # make the shell try to exec a single (nonexistent) binary literally
    # named with spaces, failing with exit 127. Verified against a real
    # install: this bug is invisible to dry-run-only unit tests since
    # run_or_echo never actually execs in dry-run mode.
    run_or_echo $wp_cmd --path="$path" "$@"
  fi
}

# graft/verify also need B's live table prefix (design doc §9.1/§9.4, finding A6) —
# defined here since it's a read-only wp-cli query, alongside the rest of scan.
inventory_table_prefix() {
  local alias_lc="$1"
  wp_remote "$alias_lc" eval 'global $wpdb; echo $wpdb->prefix;'
}

inventory_scan_site() {
  local alias_lc="$1" out_json="$2"
  log_info "scanning site '${alias_lc}' -> ${out_json}"
  local post_types options tables plugins active_theme menus
  post_types=$(wp_remote "$alias_lc" post-type list --format=json)
  options=$(wp_remote "$alias_lc" option list --format=json)
  # wp-cli's `db tables` only supports --format=list or --format=csv, not json
  # (verified via `wp db tables --help` against a real install) — request a
  # plain list and build the JSON array ourselves.
  local tables_list
  tables_list=$(wp_remote "$alias_lc" db tables --format=list --all-tables-with-prefix)
  tables=$(printf '%s' "$tables_list" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  plugins=$(wp_remote "$alias_lc" plugin list --format=json)
  active_theme=$(wp_remote "$alias_lc" theme list --status=active --format=json | jq '.[0] // {}')
  menus=$(wp_remote "$alias_lc" menu list --format=json 2>/dev/null || echo '[]')

  jq -n \
    --argjson post_types "$post_types" \
    --argjson options "$options" \
    --argjson tables "$tables" \
    --argjson plugins "$plugins" \
    --argjson active_theme "$active_theme" \
    --argjson menus "$menus" \
    '{
      post_types: $post_types,
      options: $options,
      tables: $tables,
      plugins: $plugins,
      active_theme: $active_theme,
      classic_menus_detected: ($menus | length > 0),
      classic_menu_names: [$menus[]?.name]
    }' \
    > "$out_json"
}

# design doc §3.2's rule: the ONLY function allowed to turn a module's
# candidate-slug list into a "this is the real slug" answer, by checking which
# candidate the site's own `plugin list` actually contains. Preference order
# from the module's list is respected — first match wins.
inventory_resolve_slug() {
  local scan_json="$1" candidates="$2"
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if jq -e --arg c "$c" '.plugins[]? | select(.name == $c)' "$scan_json" >/dev/null 2>&1; then
      echo "$c"
      return 0
    fi
  done <<< "$candidates"
}

# design doc §12 (Marcel's revision of review finding B1, amended for the ACSS
# v4 plugin-folder-rename case, §3.4): per-component diff between A's and B's
# rendering stack. `theme` is compared directly (a site has exactly one active
# theme, no candidate-slug ambiguity). Every other component comes from a
# module declaring <mod>_stack_candidates (§3.2) — never a slug hardcoded here.
# A component's real slug can legitimately differ between A and B (that's
# exactly what "absent on B" and "renamed folder on B" both look like); this
# function resolves each site's own real slug independently via
# inventory_resolve_slug before comparing, so it correctly flags a mismatch
# even when both sites DO have the plugin, just under different real names.
inventory_stack_diff() {
  local scan_a="$1" scan_b="$2"
  local diff='{}'

  local theme_a theme_b theme_ver_a theme_ver_b
  theme_a=$(jq -r '.active_theme.stylesheet // ""' "$scan_a")
  theme_b=$(jq -r '.active_theme.stylesheet // ""' "$scan_b")
  theme_ver_a=$(jq -r '.active_theme.version // ""' "$scan_a")
  theme_ver_b=$(jq -r '.active_theme.version // ""' "$scan_b")
  if [ "$theme_a" != "$theme_b" ] || [ "$theme_ver_a" != "$theme_ver_b" ]; then
    diff=$(echo "$diff" | jq \
      --arg sa "$theme_a" --arg sb "$theme_b" --arg va "$theme_ver_a" --arg vb "$theme_ver_b" \
      '.theme = {
        slug_a: ($sa | if length > 0 then . else null end),
        slug_b: ($sb | if length > 0 then . else null end),
        version_a: $va, version_b: $vb
      }')
  fi

  local mod
  for mod in $SITEGRAFT_MODULES; do
    module_has_fn "$mod" stack_candidates || continue
    local candidates slug_a slug_b ver_a ver_b
    candidates=$(module_call "$mod" stack_candidates)
    slug_a=$(inventory_resolve_slug "$scan_a" "$candidates")
    slug_b=$(inventory_resolve_slug "$scan_b" "$candidates")
    ver_a=""; [ -n "$slug_a" ] && ver_a=$(jq -r --arg s "$slug_a" '.plugins[]? | select(.name==$s) | .version // ""' "$scan_a")
    ver_b=""; [ -n "$slug_b" ] && ver_b=$(jq -r --arg s "$slug_b" '.plugins[]? | select(.name==$s) | .version // ""' "$scan_b")
    if [ "$slug_a" = "$slug_b" ] && [ "$ver_a" = "$ver_b" ]; then
      continue
    fi
    diff=$(echo "$diff" | jq \
      --arg m "$mod" --arg sa "$slug_a" --arg sb "$slug_b" --arg va "$ver_a" --arg vb "$ver_b" \
      '.[$m] = {
        slug_a: ($sa | if length > 0 then . else null end),
        slug_b: ($sb | if length > 0 then . else null end),
        version_a: $va, version_b: $vb
      }')
  done

  echo "$diff"
}

# Convenience wrapper for call sites that only need a yes/no answer.
inventory_stack_matches() {
  local scan_a="$1" scan_b="$2"
  [ "$(inventory_stack_diff "$scan_a" "$scan_b" | jq 'length')" = "0" ]
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

  if jq -e '.classic_menus_detected == true' "${run_dir}/scan-a.json" >/dev/null 2>&1; then
    log_warn "site A has classic nav menu(s) with items: $(jq -r '.classic_menu_names | join(", ")' "${run_dir}/scan-a.json") — sitegraft v1 does not migrate classic menu assignments (design doc §13)"
  fi

  log_info "scan complete: ${run_dir}"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_inventory.bats`
Expected: PASS (9 tests)

- [ ] **Step 5: Grow the DDEV harness — add the `scan` call and its assertions**

```bash
# Insert into tests/integration/ddev-harness.sh, replacing the
# "no later phase wired yet" placeholder line from Task 1.4:

echo "==> writing a local sitegraft profile for this harness run"
# SITE_*_WP_CMD uses "ddev exec --raw -p <project> -- wp", which runs INSIDE
# the web container regardless of the orchestrator's current directory
# (verified against a real DDEV install — "ddev --project <name> wp ..." is
# not valid: "ddev" has no such flag on "wp", since "wp" only exists as a
# project-scoped custom command). --raw is required: without it, "ddev exec"
# re-parses the command through an inner shell before running it in the
# container, which silently mangles any PHP snippet containing a
# "$variable" (bash expands it to empty before PHP ever sees it) — this is
# exactly what breaks `wp eval` calls used later (Task 1.6). Because this
# command executes inside the container, SITE_*_WP_PATH must be the
# CONTAINER-internal docroot ("/var/www/html", DDEV's default for
# --docroot=.), never the orchestrator's host path.
cat > "${ROOT}/profiles/ddev-test.conf" <<EOF
SITE_A_ALIAS="a"
SITE_A_WP_PATH="/var/www/html"
SITE_A_WP_CMD="ddev exec --raw -p ${PROJECT_A} -- wp"
SITE_A_URL="https://a.example.com"
SITE_B_ALIAS="b"
SITE_B_WP_PATH="/var/www/html"
SITE_B_WP_CMD="ddev exec --raw -p ${PROJECT_B} -- wp"
SITE_B_URL="https://b.example.com"
SITEGRAFT_STATE_DIR="/tmp/sitegraft-ddev-test-runs"
EOF

echo "==> running scan"
"${ROOT}/bin/sitegraft" scan --profile ddev-test
RUN_DIR=$(ls -dt /tmp/sitegraft-ddev-test-runs/ddev-test-* | head -1)

echo "==> asserting fixtures are visible in the scan output"
jq -e '.post_types[] | select(.name=="etch_cfs")' "${RUN_DIR}/scan-a.json" >/dev/null
jq -e '.post_types[] | select(.name=="fake_reservation")' "${RUN_DIR}/scan-b.json" >/dev/null
jq -e '.classic_menus_detected == false' "${RUN_DIR}/scan-a.json" >/dev/null

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "scan" ]; then
  echo "SCAN OK (SITEGRAFT_HARNESS_STOP_AFTER=scan)"
  exit 0
fi

echo "no later phase wired yet — see Task 3.2 (backup), 5.2 (graft/verify/restore)"
```

- [ ] **Step 6: Run the harness through the scan step**

Run: `SITEGRAFT_HARNESS_STOP_AFTER=scan tests/integration/ddev-harness.sh`
Expected: `SCAN OK (SITEGRAFT_HARNESS_STOP_AFTER=scan)`.

- [ ] **Step 7: Commit**

```bash
git add lib/inventory.sh tests/unit/test_inventory.bats tests/integration/ddev-harness.sh
git commit -m "feat(scan): add site introspection and module-driven stack-slug resolution (never hardcoded — design doc §3.2/§3.4) and wire the scan phase"
```

### Task 1.6: custom-code-on-B signals — child theme, `functions.php`, mu-plugins, snippet plugins

**Files:**
- Modify: `lib/inventory.sh` (add `inventory_custom_code_signals`,
  `inventory_custom_code_detected`; extend `inventory_scan_site` and `phase_scan`)
- Test: `tests/unit/test_inventory_custom_code.bats`

New task, added per Marcel's third guardrail (design doc §14): before `graft`
replaces B's design layer, `scan` collects a small set of shallow heuristic
signals **on B only** — deliberately no code parsing, no static analysis
(YAGNI) — so `plan` (Task 2.5) can gate on them instead of the tool silently
discarding custom PHP nobody remembered was tied to the old theme.

**Interfaces:**
- Consumes: `wp_remote` (Task 1.5).
- Produces: `inventory_custom_code_signals <alias>` (live wp-cli calls — child
  theme, `functions.php` presence/size/line-count, `mu-plugins/` file listing,
  known snippet-plugin slugs found in the existing `plugin list` dump; returns
  the JSON shape from design doc §4/§6.1); `inventory_custom_code_detected
  <signals_json>` (pure — exit 0/1, true iff any signal is non-empty/`true`,
  this is the half that's actually unit-testable).

- [ ] **Step 1: Write the failing test for `inventory_custom_code_detected`**

```bash
# tests/unit/test_inventory_custom_code.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
}

@test "inventory_custom_code_detected is false when every signal is empty" {
  local signals='{"child_theme":false,"functions_php":{"exists":false},"mu_plugins":[],"snippet_plugins_detected":[]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 1 ]
}

@test "inventory_custom_code_detected is true when the active theme is a child theme" {
  local signals='{"child_theme":true,"functions_php":{"exists":false},"mu_plugins":[],"snippet_plugins_detected":[]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 0 ]
}

@test "inventory_custom_code_detected is true when functions.php exists" {
  local signals='{"child_theme":false,"functions_php":{"exists":true,"bytes":100,"lines":10},"mu_plugins":[],"snippet_plugins_detected":[]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 0 ]
}

@test "inventory_custom_code_detected is true when any mu-plugin file is present" {
  local signals='{"child_theme":false,"functions_php":{"exists":false},"mu_plugins":["custom-redirects.php"],"snippet_plugins_detected":[]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 0 ]
}

@test "inventory_custom_code_detected is true when a known snippet plugin is active" {
  local signals='{"child_theme":false,"functions_php":{"exists":false},"mu_plugins":[],"snippet_plugins_detected":["code-snippets"]}'
  run inventory_custom_code_detected "$signals"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_inventory_custom_code.bats`
Expected: FAIL — `inventory_custom_code_detected` does not exist.

- [ ] **Step 3: Add the functions to `lib/inventory.sh`**

```bash
# Appended to lib/inventory.sh

# design doc §6.1/§14: shallow, B-only signals — no code parsing, no static
# analysis. The extensible slug list lives here, in one place, so adding a
# newly-encountered snippet plugin later is a one-line change.
inventory_custom_code_signals() {
  local alias_lc="$1"
  local name template child_theme fn_php mu_plugins plugins_json snippet_plugins

  name=$(wp_remote "$alias_lc" theme list --status=active --field=name)
  template=$(wp_remote "$alias_lc" theme get "$name" --field=template 2>/dev/null || echo "$name")
  if [ "$template" != "$name" ]; then child_theme=true; else child_theme=false; fi

  fn_php=$(wp_remote "$alias_lc" eval 'if (file_exists($f = get_stylesheet_directory()."/functions.php")) { echo json_encode(["exists"=>true,"bytes"=>filesize($f),"lines"=>count(file($f))]); } else { echo json_encode(["exists"=>false]); }')
  mu_plugins=$(wp_remote "$alias_lc" eval 'echo json_encode(array_map("basename", glob(WP_CONTENT_DIR."/mu-plugins/*.php") ?: []));')

  plugins_json=$(wp_remote "$alias_lc" plugin list --format=json)
  snippet_plugins=$(echo "$plugins_json" | jq -c \
    '[.[] | select(.name as $n | ["code-snippets","wpcode","insert-headers-and-footers"] | index($n)) | .name]')

  jq -n \
    --argjson child_theme "$child_theme" \
    --argjson fn_php "$fn_php" \
    --argjson mu_plugins "$mu_plugins" \
    --argjson snippet_plugins "$snippet_plugins" \
    '{child_theme: $child_theme, functions_php: $fn_php, mu_plugins: $mu_plugins, snippet_plugins_detected: $snippet_plugins}'
}

# Pure: given a custom_code_signals object (live or fabricated), is any signal
# raised? This is the half of the feature that's actually unit-testable.
inventory_custom_code_detected() {
  local signals="$1"
  [ "$(echo "$signals" | jq '
    (.child_theme == true)
    or (.functions_php.exists == true)
    or ((.mu_plugins // []) | length > 0)
    or ((.snippet_plugins_detected // []) | length > 0)
  ')" = "true" ]
}
```

- [ ] **Step 4: Extend `inventory_scan_site` and `phase_scan` to use them (both in `lib/inventory.sh`, from Task 1.5)**

```bash
# Modify inventory_scan_site (Task 1.5) to compute these on B only, and fold
# them into scan-b.json:

inventory_scan_site() {
  local alias_lc="$1" out_json="$2"
  log_info "scanning site '${alias_lc}' -> ${out_json}"
  local post_types options tables plugins active_theme menus
  post_types=$(wp_remote "$alias_lc" post-type list --format=json)
  options=$(wp_remote "$alias_lc" option list --format=json)
  # wp-cli's `db tables` only supports --format=list or --format=csv, not json
  # (verified via `wp db tables --help` against a real install) — request a
  # plain list and build the JSON array ourselves.
  local tables_list
  tables_list=$(wp_remote "$alias_lc" db tables --format=list --all-tables-with-prefix)
  tables=$(printf '%s' "$tables_list" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  plugins=$(wp_remote "$alias_lc" plugin list --format=json)
  active_theme=$(wp_remote "$alias_lc" theme list --status=active --format=json | jq '.[0] // {}')
  menus=$(wp_remote "$alias_lc" menu list --format=json 2>/dev/null || echo '[]')

  local custom_code_signals='{}' custom_code_detected=false
  if [ "$alias_lc" = "b" ]; then
    custom_code_signals=$(inventory_custom_code_signals "$alias_lc")
    inventory_custom_code_detected "$custom_code_signals" && custom_code_detected=true
  fi

  jq -n \
    --argjson post_types "$post_types" \
    --argjson options "$options" \
    --argjson tables "$tables" \
    --argjson plugins "$plugins" \
    --argjson active_theme "$active_theme" \
    --argjson menus "$menus" \
    --argjson custom_code_signals "$custom_code_signals" \
    --argjson custom_code_detected "$custom_code_detected" \
    '{
      post_types: $post_types,
      options: $options,
      tables: $tables,
      plugins: $plugins,
      active_theme: $active_theme,
      classic_menus_detected: ($menus | length > 0),
      classic_menu_names: [$menus[]?.name],
      custom_code_signals: $custom_code_signals,
      custom_code_detected: $custom_code_detected
    }' \
    > "$out_json"
}
```

`phase_scan` (Task 1.5) needs no change — it already just calls
`inventory_scan_site` for both aliases; the new fields ride along in
`scan-b.json` for `plan` (Task 2.5) to read.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/unit/test_inventory_custom_code.bats`
Expected: PASS (5 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/inventory.sh tests/unit/test_inventory_custom_code.bats
git commit -m "feat(scan): detect custom-code signals on B (child theme, functions.php, mu-plugins, snippet plugins) — design doc §14"
```

**Step 1 done when:** `bats tests/unit/` is all green, and
`SITEGRAFT_HARNESS_STOP_AFTER=scan tests/integration/ddev-harness.sh` prints
`SCAN OK`.

> **Flag for whoever implements Step 3 (Task 3.2) and Step 5 (Task 5.2):**
> the harness code blocks in those tasks still use the old, invalid
> `ddev --project <name> wp ...` invocation and the over-length
> `fakebooking_reservation` post_type slug (e.g. the `b_table`/
> `b_protected_checksum` helpers in Task 3.2, and the `graft`/`verify`
> assertions in Task 5.2). Both need the identical fix already applied and
> verified in Task 1.4/1.5 above: `ddev --project X wp ...` →
> `ddev exec --raw -p X -- wp ...`, and `fakebooking_reservation` →
> `fake_reservation` (the table name `fakebooking_reservations` is
> unaffected — only the post_type slug hit WordPress's 20-character limit).
> Left as-is here since fixing them is out of scope for Step 1, but do not
> copy this syntax verbatim when those tasks are implemented.

---

## Step 2 — Manifest + interactive plan

Delivers: `sitegraft plan --profile <name>` reads the two scan files, proposes
defaults per module, warns on a rendering-stack or classic-menu mismatch, lets the
operator adjust selection, and writes a frozen, validated `manifest.json`.

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

### Task 2.2: `plan` phase logic — module dispatch, defaults, `_unclaimed` bucket, classic-menu warning

**Files:**
- Modify: `lib/manifest.sh` (add `manifest_compute_unclaimed`)
- Create: `lib/plan.sh`
- Test: `tests/unit/test_plan.bats`

**Interfaces:**
- Consumes: `SITEGRAFT_MODULES`, `module_call` (Task 1.3); `manifest_new`,
  `manifest_add_migrate`, `manifest_add_protect` (Task 2.1).
- Produces: `manifest_compute_unclaimed <manifest_json> <scan_b_json>` (adds a
  `protect._unclaimed` bucket per design doc §3.6, pure function); `plan_defaults
  <scan_a_json> <scan_b_json>` (builds the default migrate/protect selections by
  calling `module_call <mod> detect` against both scans — not a pure function, reads
  from disk via the scan file paths, so tested separately from the pure manifest
  functions above); `plan_warn_scope_gaps <scan_a_json> <scan_b_json>` (design doc
  §13, review finding B2 — the classic-menu warning, **on A only**, per Marcel's
  clarification: B having a classic menu is normal and never warned about, see
  §13). This task does **not** cover the rendering-stack mismatch — that warning
  was folded into Task 2.4's interactive per-component resolution instead of being
  a separate blanket warning here (Marcel's revision of finding B1: a generic
  "stack doesn't match" warning would be actively misleading once `plan` can
  offer to fix the specific mismatch on the spot).

- [ ] **Step 1: Write the failing test for `manifest_compute_unclaimed` and `plan_warn_scope_gaps`**

```bash
# tests/unit/test_plan.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
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

@test "plan_warn_scope_gaps warns about A's classic menus but never about B's, and always exits 0" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"classic_menus_detected":true,"classic_menu_names":["Main Menu"]}' > "$a"
  echo '{"classic_menus_detected":true,"classic_menu_names":["Legacy Menu"]}' > "$b"
  run plan_warn_scope_gaps "$a" "$b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Main Menu"* ]]
  [[ "$output" != *"Legacy Menu"* ]]
}

@test "plan_warn_scope_gaps says nothing when A has no classic menus" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"classic_menus_detected":false}' > "$a"
  echo '{"classic_menus_detected":true,"classic_menu_names":["Legacy Menu"]}' > "$b"
  run plan_warn_scope_gaps "$a" "$b"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
  # `$claimed | index(.)` rebinds `.` to $claimed before index runs, so it
  # always searches $claimed for $claimed and unclaimed is always [] — silently
  # defeating default-deny. Bind the element with `as $x` so index searches for
  # the right thing. (Bug caught via TDD in Step 2; see lib/manifest.sh.)
  unclaimed_pt=$(jq -n --argjson all "$all_pt" --argjson claimed "$claimed_pt" \
    '[$all[] as $x | select(($claimed | index($x)) | not) | $x]')
  echo "$manifest" | jq --argjson u "$unclaimed_pt" \
    '.protect._unclaimed = {post_types: $u, tables: [], option_keys: [],
      note: "found on B, unclaimed by any module — protected by default-deny"}'
}
```

- [ ] **Step 4: Write `lib/plan.sh`**

```bash
#!/usr/bin/env bash
# lib/plan.sh — phase: plan. Builds default selections from module detection,
# warns on scope gaps (design doc §12/§13), drives interactive adjustment
# (Task 2.3), freezes the manifest.

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

# design doc §13 (review finding B2): plan only ever builds a manifest, it
# never touches B, so this is a warning, never a hard failure. The rendering-
# stack mismatch has its own, more useful per-component treatment now
# (plan_resolve_stack, Task 2.4) instead of a generic warning here — offering
# a fix beats restating that something doesn't match.
plan_warn_scope_gaps() {
  local scan_a_json="$1" scan_b_json="$2"
  if jq -e '.classic_menus_detected == true' "$scan_a_json" >/dev/null 2>&1; then
    log_warn "A has classic nav menu(s) with items ($(jq -r '.classic_menu_names | join(", ")' "$scan_a_json")) — sitegraft v1 does not migrate classic menu assignments (design doc §13). Migrate them by hand or write a module."
  fi
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/unit/test_plan.bats`
Expected: PASS (4 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/manifest.sh lib/plan.sh tests/unit/test_plan.bats
git commit -m "feat(plan): compute default migrate/protect selections, default-deny bucket, and A-only classic-menu warning"
```

### Task 2.3: interactive selection (`gum`/`fzf`/plain fallback) + `phase_plan`

**Files:**
- Modify: `lib/plan.sh` (add `plan_select_interactive`, `phase_plan`)
- Test: manual (interactive UI is not unit-testable — covered end-to-end by the
  DDEV harness, Task 3.2 onward, using a pre-filled, non-interactive manifest)

**Interfaces:**
- Consumes: `plan_defaults`, `plan_warn_scope_gaps` (Task 2.2), `manifest_freeze` (Task 2.1).
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
  # manual-QA item, not unit-testable — verified against the DDEV harness (Task
  # 3.2 onward) via a non-interactive manifest path (SITEGRAFT_MANIFEST_PREFILLED=<path>).
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
  plan_warn_scope_gaps "${run_dir}/scan-a.json" "${run_dir}/scan-b.json"

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

Run against the DDEV harness pair once Task 3.2's fixtures/manifest exist (forward
reference — acceptable here since interactive UI genuinely cannot be unit tested):
`bin/sitegraft plan --profile ddev-test`, confirm a `manifest.json` is written and
`jq -e '.frozen == true'` on it succeeds.

- [ ] **Step 3: Commit**

```bash
git add lib/plan.sh
git commit -m "feat(plan): wire interactive selection (gum/fzf/plain fallback), scope-gap warnings, and freeze the manifest"
```

### Task 2.4: interactive stack resolution — offer to copy a missing/mismatched component from A

**Files:**
- Modify: `lib/plan.sh` (add `plan_resolve_stack`, `_plan_confirm`,
  `_plan_confirm_strong`; wire into `phase_plan`)
- Test: `tests/unit/test_plan_stack.bats`

New task, added per Marcel's revision of review finding B1 (§12): the original
resolution was refuse-or-override only. The revised behavior is that `plan` — not
`graft` — is where the operator gets offered a fix: **copy the missing or
mismatched component from A**, never install from anywhere else. This is
deliberately its own task rather than folded into Task 2.2, since it is new
scope Marcel asked for after that task was already written, not a revision of it.

**Interfaces:**
- Consumes: `inventory_stack_diff` (Task 1.5) — and transitively the module
  registry it resolves candidate slugs against (`modules_discover` already runs
  earlier in `phase_plan`, Task 2.2/2.3, before this is ever called).
- Produces: `plan_resolve_stack <manifest_json> <scan_a_json> <scan_b_json>`
  (interactive — for every component `inventory_stack_diff` reports, prompts and
  writes the decision into `manifest.stack.<component>` per design doc §4; prints
  the updated manifest JSON); `_plan_confirm <prompt>` / `_plan_confirm_strong
  <prompt>` (the two confirmation strengths §12 requires — a plain yes/no for
  "absent on B," and a distinct, harder-to-trigger confirmation whenever B
  already has *something* under that module — same slug at a different
  version, or a different resolved slug entirely (the ACSS v4 legacy-slug
  case, §3.4) — a heavier decision than filling a plain absence).

- [ ] **Step 1: Write the failing test**

The interactive prompts themselves aren't unit-testable (same reasoning as Task
2.3's `plan_select_interactive`), but the **decision-recording** half of
`plan_resolve_stack` is — by stubbing the two confirm functions to always answer
yes or no, the test can assert the manifest ends up with the right
`stack.<component>.resolution` regardless of which UI path (`gum`/`fzf`/plain)
would have asked the question.

```bash
# tests/unit/test_plan_stack.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/modules.sh'
  load '../../lib/inventory.sh'
  load '../../lib/manifest.sh'
  load '../../lib/plan.sh'
  export SITEGRAFT_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$SITEGRAFT_MODULES_DIR"
  cat > "$SITEGRAFT_MODULES_DIR/acss.sh" <<'EOF'
acss_stack_candidates() { printf 'automatic-css\nacss-legacy-slug\n'; }
EOF
  cat > "$SITEGRAFT_MODULES_DIR/etch.sh" <<'EOF'
etch_stack_candidates() { printf 'etch\n'; }
EOF
  modules_discover
}

@test "plan_resolve_stack records resolution=copy for an absent component when confirmed" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"etch","version":"2.0"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$b"
  _plan_confirm() { return 0; }        # simulate the operator accepting
  _plan_confirm_strong() { return 1; } # not exercised in this case
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run plan_resolve_stack "$manifest" "$a" "$b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.stack.etch.resolution == "copy" and .stack.etch.slug_a == "etch" and .stack.etch.slug_b == null' >/dev/null
}

@test "plan_resolve_stack records resolution=skip for an absent component when declined" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"etch","version":"2.0"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$b"
  _plan_confirm() { return 1; }
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run plan_resolve_stack "$manifest" "$a" "$b"
  echo "$output" | jq -e '.stack.etch.resolution == "skip"' >/dev/null
}

@test "plan_resolve_stack uses the STRONG confirm (not the plain one) when B already has the plugin under a different slug — the ACSS v4 case" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"automatic-css","version":"4.1"}]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[{"name":"acss-legacy-slug","version":"3.9"}]}' > "$b"
  _plan_confirm() { echo "PLAIN CONFIRM CALLED — WRONG PATH FOR A MISMATCH WHERE B ALREADY HAS SOMETHING" >&2; return 1; }
  _plan_confirm_strong() { return 0; } # simulate the operator explicitly accepting the overwrite
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run plan_resolve_stack "$manifest" "$a" "$b"
  echo "$output" | jq -e '.stack.acss.resolution == "copy" and .stack.acss.slug_a == "automatic-css" and .stack.acss.slug_b == "acss-legacy-slug"' >/dev/null
  [[ "$output" != *"WRONG PATH"* ]]
}

@test "plan_resolve_stack touches nothing when the stack already matches" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$b"
  local manifest; manifest=$(manifest_new "https://a.example.com" "https://b.example.com")
  run plan_resolve_stack "$manifest" "$a" "$b"
  echo "$output" | jq -e '.stack == null or (.stack | length) == 0' >/dev/null
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_plan_stack.bats`
Expected: FAIL — `plan_resolve_stack` does not exist.

- [ ] **Step 3: Add the functions to `lib/plan.sh`, and wire them into `phase_plan`**

```bash
# Appended to lib/plan.sh

_plan_confirm() {
  local prompt="$1"
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt"
  else
    read -r -p "${prompt} [y/N] " ans
    [ "${ans:-n}" = "y" ]
  fi
}

# Deliberately a different, harder-to-trigger confirmation than _plan_confirm —
# design doc §12: overwriting something already installed on B is a heavier
# decision than filling an absence, and must never be one accidental keystroke
# away, let alone automatic.
_plan_confirm_strong() {
  local prompt="$1"
  if command -v gum >/dev/null 2>&1; then
    gum confirm --affirmative="Overwrite" --negative="Skip" "$prompt"
  else
    read -r -p "${prompt} Type OVERWRITE (all caps) to confirm: " ans
    [ "$ans" = "OVERWRITE" ]
  fi
}

# design doc §12 (Marcel's revision of review finding B1, amended for the ACSS
# v4 plugin-folder-rename case, §3.4): for each stack component
# inventory_stack_diff reports, offer to copy A's resolved slug to B, using a
# stronger confirmation whenever B already has *something* under that module
# (slug_b not null) — whether that's literally the same slug at a different
# version, or a different slug entirely (the legacy-vs-current ACSS case).
# Never installs from anywhere but A. Declining leaves the component "skip" —
# graft's hard precondition (Task 4.1) picks it up from there.
plan_resolve_stack() {
  local manifest="$1" scan_a_json="$2" scan_b_json="$3"
  local diff; diff=$(inventory_stack_diff "$scan_a_json" "$scan_b_json")
  local component
  for component in $(echo "$diff" | jq -r 'keys[]'); do
    local slug_a slug_b ver_a ver_b resolution
    slug_a=$(echo "$diff" | jq -r --arg c "$component" '.[$c].slug_a')
    slug_b=$(echo "$diff" | jq -r --arg c "$component" '.[$c].slug_b')
    ver_a=$(echo "$diff" | jq -r --arg c "$component" '.[$c].version_a')
    ver_b=$(echo "$diff" | jq -r --arg c "$component" '.[$c].version_b')
    if [ "$slug_b" = "null" ]; then
      log_warn "${component} is on A (${slug_a} v${ver_a}) but not on B."
      if _plan_confirm "Copy ${component} from A and activate it on B?"; then
        resolution="copy"
      else
        resolution="skip"
      fi
    else
      log_warn "B already has ${component} installed as '${slug_b}' (v${ver_b}) — A has it as '${slug_a}' (v${ver_a}). Copying A's version will add A's folder alongside B's existing one and activate it."
      if _plan_confirm_strong "Copy A's ${component} ('${slug_a}' v${ver_a}) to B and activate it, leaving B's existing '${slug_b}' folder in place but inactive?"; then
        resolution="copy"
      else
        resolution="skip"
      fi
    fi
    manifest=$(echo "$manifest" | jq \
      --arg c "$component" --arg sa "$slug_a" --arg sb "$slug_b" --arg va "$ver_a" --arg vb "$ver_b" --arg r "$resolution" \
      '.stack[$c] = {
        slug_a: $sa,
        slug_b: (if $sb == "null" then null else $sb end),
        version_a: $va, version_b: $vb,
        resolution: $r
      }')
  done
  echo "$manifest"
}
```

Now wire `plan_resolve_stack` into `phase_plan` (Task 2.3), skipped on the
non-interactive `SITEGRAFT_MANIFEST_PREFILLED` path exactly like
`plan_select_interactive` — a prefilled manifest is expected to already carry
whatever `stack` decisions its scenario needs:

```bash
# Replace this block inside phase_plan (lib/plan.sh, from Task 2.3):
#
#   if [ -n "${SITEGRAFT_MANIFEST_PREFILLED:-}" ]; then
#     manifest=$(cat "$SITEGRAFT_MANIFEST_PREFILLED")
#   else
#     manifest=$(plan_select_interactive "$manifest")
#   fi
#
# with:

  if [ -n "${SITEGRAFT_MANIFEST_PREFILLED:-}" ]; then
    manifest=$(cat "$SITEGRAFT_MANIFEST_PREFILLED")
  else
    manifest=$(plan_resolve_stack "$manifest" "${run_dir}/scan-a.json" "${run_dir}/scan-b.json")
    manifest=$(plan_select_interactive "$manifest")
  fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_plan_stack.bats`
Expected: PASS (4 tests)

- [ ] **Step 5: Manual smoke test**

Run `bin/sitegraft plan --profile ddev-test` against the DDEV harness pair
(Task 3.2 onward) once B has neither Etch nor ACSS installed — confirm the copy
offer appears, accepting it writes `manifest.stack.etch.resolution == "copy"`.
Note: the DDEV fixtures (Task 1.4) don't actually install a real Etch/ACSS
plugin on either site (they only register the CPTs sitegraft needs to see) — so
`inventory_stack_diff` naturally finds **no** mismatch in the harness's
default run, and this interactive path never triggers automatically inside
`tests/integration/ddev-harness.sh`. That's an acceptable coverage gap for v1:
the mechanics are unit-tested above; a real end-to-end exercise of the copy path
happens on a real A/B pair, which is exactly what the pre-`1.0.0` gate in
`docs/definition-of-done.md` already requires for other reasons (closing R2/R4).

- [ ] **Step 6: Commit**

```bash
git add lib/plan.sh tests/unit/test_plan_stack.bats
git commit -m "feat(plan): offer to copy a missing/mismatched stack component from A (design doc §12, B1 revision)"
```

### Task 2.5: custom-code-on-B blocking gate

**Files:**
- Modify: `lib/plan.sh` (add `plan_custom_code_gate`; wire into `phase_plan`,
  ahead of everything else)
- Test: `tests/unit/test_plan_custom_code.bats`

New task, added per Marcel's third guardrail (design doc §14) alongside B1/B2.
Unlike every other check in `plan` (which warns or offers a fix but still
produces a manifest), this one is a genuine hard stop: if
`scan-b.json.custom_code_detected` is `true`, `plan` **does not write a
manifest at all** until the operator explicitly acknowledges. This is
deliberately as heavy as `--allow-stack-mismatch`'s override, not a warning
that scrolls past with everything else.

**Interfaces:**
- Consumes: `inventory_custom_code_detected` is not called here — the boolean
  is already sitting in `scan-b.json` from Task 1.6; this task just reads it
  and gates on it.
- Produces: `plan_custom_code_gate <manifest_json> <scan_b_json>` (prints the
  updated manifest with `custom_code_review` set on acknowledgment; **returns
  exit 1 and prints nothing usable on decline** — `phase_plan` must treat that
  as a hard abort, not merely skip a step).

- [ ] **Step 1: Write the failing test**

Like Task 2.4, the confirmation prompt itself isn't unit-testable, but the
gating logic is, by stubbing the confirm function.

```bash
# tests/unit/test_plan_custom_code.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/plan.sh'
}

@test "plan_custom_code_gate passes through untouched when no signal was raised" {
  local manifest='{"frozen":false}'
  local scan_b='{"custom_code_detected":false}'
  run plan_custom_code_gate "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -e '.custom_code_review // "absent"')" = "\"absent\"" ]
}

@test "plan_custom_code_gate records acknowledged=true and a copy of the signals when confirmed" {
  local manifest='{"frozen":false}'
  local scan_b='{"custom_code_detected":true,"custom_code_signals":{"child_theme":true,"functions_php":{"exists":false},"mu_plugins":[],"snippet_plugins_detected":[]}}'
  _plan_confirm_strong() { return 0; } # simulate the operator acknowledging
  run plan_custom_code_gate "$manifest" "$scan_b"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.custom_code_review.acknowledged == true and .custom_code_review.signals.child_theme == true' >/dev/null
}

@test "plan_custom_code_gate exits 1 and writes nothing usable when declined" {
  local manifest='{"frozen":false}'
  local scan_b='{"custom_code_detected":true,"custom_code_signals":{"child_theme":true}}'
  _plan_confirm_strong() { return 1; } # simulate the operator declining
  run plan_custom_code_gate "$manifest" "$scan_b"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_plan_custom_code.bats`
Expected: FAIL — `plan_custom_code_gate` does not exist.

- [ ] **Step 3: Add `plan_custom_code_gate` to `lib/plan.sh`, and wire it into `phase_plan`**

```bash
# Appended to lib/plan.sh

# design doc §14 (Marcel's third guardrail): the only truly blocking gate in
# `plan` — no manifest gets written past this point without an explicit
# acknowledgment. Uses _plan_confirm_strong (Task 2.4) — the same weight as
# --allow-stack-mismatch's override, never the plain confirm used elsewhere.
plan_custom_code_gate() {
  local manifest="$1" scan_b_json="$2"
  if [ "$(echo "$scan_b_json" | jq -r '.custom_code_detected // false')" != "true" ]; then
    echo "$manifest"
    return 0
  fi
  log_warn "B has custom-code signal(s): $(echo "$scan_b_json" | jq -c '.custom_code_signals')"
  if ! _plan_confirm_strong "Did you review B's theme for custom code (functions.php, code snippets, mu-plugins) before replacing the theme? Custom code living in the old theme will be LOST."; then
    log_error "custom-code review not acknowledged — refusing to write a manifest. Re-run 'sitegraft plan' once you've reviewed B's theme."
    return 1
  fi
  echo "$manifest" | jq --argjson signals "$(echo "$scan_b_json" | jq '.custom_code_signals')" \
    '.custom_code_review = {acknowledged: true, signals: $signals}'
}
```

Wire it into `phase_plan` (Task 2.3) right after `plan_defaults` builds the
manifest, and **before** the stack resolution or interactive-selection branch —
its failure aborts the whole phase immediately, no manifest ever gets written:

```bash
# Replace this block inside phase_plan (lib/plan.sh, from Task 2.3):
#
#   local manifest
#   manifest=$(plan_defaults "${run_dir}/scan-a.json" "${run_dir}/scan-b.json")
#
#   if [ -n "${SITEGRAFT_MANIFEST_PREFILLED:-}" ]; then
#
# with:

  local manifest
  manifest=$(plan_defaults "${run_dir}/scan-a.json" "${run_dir}/scan-b.json")
  manifest=$(plan_custom_code_gate "$manifest" "$(cat "${run_dir}/scan-b.json")") || return 1

  if [ -n "${SITEGRAFT_MANIFEST_PREFILLED:-}" ]; then
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_plan_custom_code.bats`
Expected: PASS (3 tests)

- [ ] **Step 5: Manual smoke test**

Run `bin/sitegraft plan --profile ddev-test` against a DDEV B fixture with a
child theme active (temporarily activate one of WordPress's bundled child-theme
pairs, or any theme with a non-matching `template`) — confirm `plan` refuses to
write `manifest.json` until the strong confirmation is accepted, and that
declining leaves no `manifest.json` in the run directory at all.

- [ ] **Step 6: Commit**

```bash
git add lib/plan.sh tests/unit/test_plan_custom_code.bats
git commit -m "feat(plan): add the custom-code-on-B blocking gate (design doc §14)"
```

---

## Step 3 — Backup + restore

Delivers: `sitegraft backup --profile <name>` produces a full DB **and files**
backup of B on the orchestrator plus a genuinely self-contained `restore.sh`;
`sitegraft restore` rolls B back completely, including its files. Resolves review
findings A2 (restore.sh self-containment), A3 (missing wp-content backup), and A5
(unstable checksums).

### Task 3.1: `lib/backup.sh` — DB export, wp-content archive, normalized checksums, literal `restore.sh`

**Files:**
- Create: `lib/backup.sh`
- Test: `tests/unit/test_backup.bats`

**Interfaces:**
- Consumes: `wp_remote`, `inventory_table_prefix` (Task 1.5), `run_or_echo` (Task 1.1).
- Produces: `backup_checksum <content>` (pure function — sha256 of `<content>` with
  every `mysqldump`-style `-- ` comment line stripped first, so pre/post-graft
  checksums of identical data are stable regardless of dump timestamps — design doc
  §6.3, review finding A5; this exact function is reused, unmodified, by `verify`
  and by the DDEV harness, so the three call sites can never drift);
  `backup_wp_cmd_literal <alias>` (prints the literal, resolved ssh/wp-cli command
  prefix for `<alias>` — e.g. `ssh user@host "wp --path=/var/www/site"` or
  `wp --path=/var/www/site` — with no reference to any sitegraft function, for
  baking into `restore.sh`); `phase_backup`.

- [ ] **Step 1: Write the failing tests**

`backup_checksum`'s normalization is the crux of finding A5 — test it directly
against a fabricated mysqldump-shaped string with a fake timestamp comment.

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

@test "backup_checksum ignores mysqldump comment lines (timestamp instability, finding A5)" {
  local dump1="INSERT INTO t VALUES (1);
-- Dump completed on 2026-08-19 10:00:00"
  local dump2="INSERT INTO t VALUES (1);
-- Dump completed on 2026-08-19 10:00:07"
  run backup_checksum "$dump1"
  local sum1="$output"
  run backup_checksum "$dump2"
  [ "$output" = "$sum1" ]
}

@test "backup_wp_cmd_literal builds a literal ssh-wrapped command for a remote site" {
  SITE_B_SSH_HOST="user@host-b.example.com"
  SITE_B_WP_PATH="/var/www/site-b"
  SITE_B_WP_CMD="wp"
  run backup_wp_cmd_literal b
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"user@host-b.example.com"* ]]
  [[ "$output" != *"wp_remote"* ]]
}

@test "backup_wp_cmd_literal builds a plain local command with no ssh for a local site" {
  unset SITE_B_SSH_HOST
  SITE_B_WP_PATH="/var/www/site-b"
  # Multi-word wrapper — "ddev wp" alone is NOT a valid real-world value (see
  # §5.1 / Step 1's ddev exec --raw fix); this only exercises word-splitting
  # of an arbitrary multi-word SITE_*_WP_CMD.
  SITE_B_WP_CMD="ddev exec --raw -p test-b -- wp"
  run backup_wp_cmd_literal b
  [[ "$output" != *"ssh"* ]]
  [[ "$output" == *"ddev exec"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_backup.bats`
Expected: FAIL — `lib/backup.sh` does not exist.

- [ ] **Step 3: Write `lib/backup.sh`**

```bash
#!/usr/bin/env bash
# lib/backup.sh — phase: backup. Full DB + wp-content export of B, pulled to the
# orchestrator, plus a normalized checksum snapshot of protected data and a
# genuinely self-contained restore.sh (design doc §6.3; review findings A2, A3, A5).

# Strips every mysqldump "-- " comment line (including the "Dump completed on ..."
# timestamp) before hashing, so two exports of byte-identical data always produce
# the same checksum. Used identically by backup, verify, and the DDEV harness.
backup_checksum() {
  printf '%s' "$1" | grep -v '^-- ' | shasum -a 256 | awk '{print $1}'
}

# Prints a literal command prefix for <alias> with no reference to any sitegraft
# function — safe to bake into a generated script that must run standalone.
backup_wp_cmd_literal() {
  local alias_lc="$1"
  local alias_uc; alias_uc=$(printf '%s' "$alias_lc" | tr '[:lower:]' '[:upper:]')
  local host_var="SITE_${alias_uc}_SSH_HOST"
  local path_var="SITE_${alias_uc}_WP_PATH"
  local cmd_var="SITE_${alias_uc}_WP_CMD"
  local host="${!host_var:-}"
  # Deliberately NOT `${!path_var:?missing ${path_var}}`. That looks like a
  # safe guard but is not one here: on bash 3.2 (Apple's /bin/bash, verified
  # live) a fatal parameter-expansion error raised *inside a function* under
  # `set -e` exits the whole process reporting $?=0 to any EXIT trap, despite
  # printing its message — so a profile missing this key would look like a
  # clean success. Always use `${!var:-}` plus an explicit check and
  # `return 1`, which propagates correctly. See lib/inventory.sh (wp_remote)
  # and lib/backup.sh (backup_wp_cmd_literal) for the shipped form.
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

backup_db_export() {
  local run_dir="$1"
  log_info "exporting B database..."
  mkdir -p "${run_dir}/backup"
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo bash -c "ssh '${SITE_B_SSH_HOST}' \"${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db export - --add-drop-table\" | gzip > '${run_dir}/backup/b-db.sql.gz'"
  else
    run_or_echo bash -c "${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db export - --add-drop-table | gzip > '${run_dir}/backup/b-db.sql.gz'"
  fi
}

# design doc §6.3 / review finding A3: without this, restore.sh can never return
# B's files (media uploaded by graft, any theme/plugin file changes) to their
# pre-graft state — only the database.
backup_wp_content() {
  local run_dir="$1"
  log_info "archiving B wp-content..."
  mkdir -p "${run_dir}/backup/b-wp-content"
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo rsync -avz "${SITE_B_SSH_HOST}:${SITE_B_WP_PATH}/wp-content/" "${run_dir}/backup/b-wp-content/"
  else
    run_or_echo rsync -avz "${SITE_B_WP_PATH}/wp-content/" "${run_dir}/backup/b-wp-content/"
  fi
}

phase_backup() {
  local profile="" run_dir=""
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

  backup_db_export "$run_dir"
  backup_wp_content "$run_dir"

  # Checksum the protected buckets declared in the manifest (design doc §6.3),
  # using the exact same normalized function verify and the harness will use later.
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

# design doc §6.3 / review finding A2: every command below is resolved and baked in
# literally at generation time. restore.sh never sources any sitegraft lib file and
# never calls a sitegraft function — it needs only ssh, rsync, and gzip to run.
backup_generate_restore_script() {
  local run_dir="$1"
  local wp_cmd_b restore_db_cmd restore_wp_content_cmd
  wp_cmd_b="$(backup_wp_cmd_literal b)"

  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    restore_db_cmd="gunzip -c '${run_dir}/backup/b-db.sql.gz' | ssh '${SITE_B_SSH_HOST}' \"${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db import -\""
    restore_wp_content_cmd="ssh '${SITE_B_SSH_HOST}' \"mkdir -p '${SITE_B_WP_PATH}/wp-content'\" && rsync -avz --delete '${run_dir}/backup/b-wp-content/' '${SITE_B_SSH_HOST}:${SITE_B_WP_PATH}/wp-content/'"
  else
    restore_db_cmd="gunzip -c '${run_dir}/backup/b-db.sql.gz' | ${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db import -"
    restore_wp_content_cmd="rsync -avz --delete '${run_dir}/backup/b-wp-content/' '${SITE_B_WP_PATH}/wp-content/'"
  fi

  cat > "${run_dir}/restore.sh" <<EOF
#!/usr/bin/env bash
# Generated by 'sitegraft backup' for run: ${run_dir}
# Self-contained: every command below is a literal, baked-in ssh/rsync/wp-cli
# invocation (wp-cli literal prefix: ${wp_cmd_b}). This script never calls a
# sitegraft function and never sources a sitegraft lib file — it runs standalone
# with nothing but ssh, rsync, and gzip.
set -euo pipefail
echo "Restoring B wp-content from ${run_dir}/backup/b-wp-content/ ..."
${restore_wp_content_cmd}
echo "Restoring B database from ${run_dir}/backup/b-db.sql.gz ..."
${restore_db_cmd}
echo "Restore complete."
EOF
  chmod +x "${run_dir}/restore.sh"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_backup.bats`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/backup.sh tests/unit/test_backup.bats
git commit -m "feat(backup): export B database and wp-content, normalize checksums, generate a literal self-contained restore.sh"
```

### Task 3.2: `restore` phase with pre-restore safety backup + grow the DDEV harness through `backup`

**Files:**
- Modify: `lib/backup.sh` (add `phase_restore`)
- Modify: `tests/integration/ddev-harness.sh` (add the `backup` call + its assertions)
- Test: covered by DDEV integration harness — restoring a real site is not
  meaningfully unit-testable; the function is a thin orchestration wrapper around
  already-tested pieces (`backup_generate_restore_script`'s output, `gum confirm`).

**Interfaces:**
- Consumes: `run_or_echo`, `log_info`/`log_warn` (Task 1.1); `backup_checksum`
  (Task 3.1).
- Produces: `phase_restore` (the function `bin/sitegraft` dispatches to for the
  `restore` phase); a DDEV harness that now runs `scan → plan → backup` and asserts
  the backup is complete and checksum-stable (design doc §10, review finding C1).

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
      gum confirm "Restore B from ${run_dir}? This overwrites B's current database and wp-content." || return 1
    else
      read -r -p "Restore B from ${run_dir}? This overwrites B's current database and wp-content. [y/N] " ans
      [ "${ans:-n}" = "y" ] || return 1
    fi
  fi

  # Restoring is itself made reversible: snapshot B's current state first. Uses
  # the same literal-command pattern as backup_db_export (Task 3.1) — never
  # `wp_remote` inside a `bash -c "..."` string, since that spawns a fresh shell
  # where the function isn't defined (this was the same class of bug as finding
  # A2, just in a second spot the original review didn't call out by name).
  local pre_restore_dir="${run_dir}/pre-restore-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$pre_restore_dir"
  log_info "snapshotting B's current state before restoring (safety net)..."
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    run_or_echo bash -c "ssh '${SITE_B_SSH_HOST}' \"${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db export - --add-drop-table\" | gzip > '${pre_restore_dir}/b-db.sql.gz'"
  else
    run_or_echo bash -c "${SITE_B_WP_CMD} --path='${SITE_B_WP_PATH}' db export - --add-drop-table | gzip > '${pre_restore_dir}/b-db.sql.gz'"
  fi

  log_info "running ${run_dir}/restore.sh ..."
  run_or_echo "${run_dir}/restore.sh"
  log_info "restore complete. Pre-restore safety snapshot kept at ${pre_restore_dir}"
}
```

Note: `phase_restore` itself does not need `lib/inventory.sh` sourced (`bin/sitegraft`
only loads `lib/profile.sh` + `lib/backup.sh` for the `restore` phase) — the snapshot
above uses the same literal `ssh`/`$SITE_B_WP_CMD` construction as
`backup_db_export`, not `wp_remote`, so it never needed it in the first place.

- [ ] **Step 2: Grow the DDEV harness — add the `plan` and `backup` calls and their assertions**

```bash
# Insert into tests/integration/ddev-harness.sh, replacing the
# "no later phase wired yet" placeholder line from Task 1.5:

echo "==> running plan (non-interactive, pre-filled manifest)"
SITEGRAFT_MANIFEST_PREFILLED="${ROOT}/tests/integration/fixtures/prefilled-manifest.json" \
  "${ROOT}/bin/sitegraft" plan --profile ddev-test --run "$RUN_DIR"

echo "==> running backup"
"${ROOT}/bin/sitegraft" backup --profile ddev-test --run "$RUN_DIR"

echo "==> asserting the backup is complete and checksum-stable"
[ -f "${RUN_DIR}/backup/b-db.sql.gz" ]
[ -d "${RUN_DIR}/backup/b-wp-content" ] && [ -n "$(ls -A "${RUN_DIR}/backup/b-wp-content")" ]
[ -x "${RUN_DIR}/restore.sh" ]

# shellcheck source=../../lib/backup.sh
. "${ROOT}/lib/backup.sh"   # reuse the exact same normalized checksum (finding A5)
b_table() { ddev --project "$PROJECT_B" wp eval "global \$wpdb; echo \$wpdb->prefix.'$1';"; }
b_protected_checksum() { backup_checksum "$(ddev --project "$PROJECT_B" wp db export - --tables="$(b_table fakebooking_reservations)")"; }

CHECKSUM_1=$(b_protected_checksum)
CHECKSUM_2=$(b_protected_checksum)
[ "$CHECKSUM_1" = "$CHECKSUM_2" ]  # same data, re-hashed immediately: must be stable

if [ "${SITEGRAFT_HARNESS_STOP_AFTER:-}" = "backup" ]; then
  echo "BACKUP OK (SITEGRAFT_HARNESS_STOP_AFTER=backup)"
  exit 0
fi

echo "no later phase wired yet — see Task 5.2 (graft/verify/restore)"
```

Note: `tests/integration/fixtures/prefilled-manifest.json` referenced above is
generated once by hand as part of this task (run `plan` interactively once against
the two DDEV sites, inspect the resulting `manifest.json`, save it as the fixture)
— it is a real, valid frozen manifest for the fixture data, committed to the repo
so the harness runs non-interactively.

- [ ] **Step 3: Run the harness through the backup step**

Run: `SITEGRAFT_HARNESS_STOP_AFTER=backup tests/integration/ddev-harness.sh`
Expected: `BACKUP OK (SITEGRAFT_HARNESS_STOP_AFTER=backup)`.

- [ ] **Step 4: Commit**

```bash
git add lib/backup.sh tests/integration/ddev-harness.sh tests/integration/fixtures/prefilled-manifest.json
git commit -m "feat(restore): add restore phase with a pre-restore safety snapshot; grow the DDEV harness through backup"
```

---

## Step 4 — Graft: stack precondition, media, WXR, mu-plugin mapping, remaps, options

Delivers: `sitegraft graft --profile <name>` performs the actual transfer, per
design doc §6.4, §9, §12. This is the highest-risk step — every sub-step is
individually marker-gated for resumability, and this rewrite resolves review
findings A1 (missing options migration), A4 (remote-A transfers), A6 (unscoped
search-replace), A7 (missing wordpress-importer provisioning), and B1 (the
rendering-stack hard precondition).

### Task 4.1: rendering-stack sync + revised precondition + media sync (routed through the orchestrator) + mu-plugin deploy/remove

**Files:**
- Create: `lib/graft.sh`
- Create: `mu-plugins/sitegraft-id-mapper.php`
- Test: `tests/unit/test_graft_mediastep.bats`, `tests/unit/test_graft_precondition.bats`,
  `tests/unit/test_graft_stack_sync.bats`

**Interfaces:**
- Consumes: `SITE_A_*`/`SITE_B_*` (Task 1.2), `run_or_echo` (Task 1.1),
  `inventory_stack_diff` (Task 1.5).
- Produces: `graft_sync_stack <run_dir> <manifest_json>` (design doc §6.4 step 0a,
  Marcel's revision of finding B1, further amended for the ACSS v4
  plugin-folder-rename case (§3.4) — for every `stack.<component>` in the
  manifest with `"resolution": "copy"`, `rsync`s **`slug_a`, read directly from
  the manifest** (never a hardcoded name, never re-derived — design doc §3.2's
  rule) A → orchestrator → B, then activates that same slug; the **only** place
  `graft` ever writes to B's `wp-content/themes/` or `wp-content/plugins/`, and
  it only ever copies from A); `graft_check_stack_precondition <scan_a_json>
  <scan_b_json> <manifest_json> <allow_mismatch: 0|1>` (design doc §6.4 step 0b
  — **revised signature**: takes the manifest now, so it never re-litigates a
  mismatch `graft_sync_stack` already resolved; exit 0 if every remaining
  mismatch is resolved or `allow_mismatch=1`, exit 1 otherwise); a two-hop
  media sync:
  `graft_media_pull_cmd`/`graft_media_push_cmd` (pure functions returning argv for
  inspection) wrapping the real `graft_media_sync`, which routes A → orchestrator
  (into the run directory) → B instead of assuming A is directly reachable from B
  (design doc §6.4 step 1, review finding A4); `graft_deploy_mu_plugin`,
  `graft_remove_mu_plugin`.

- [ ] **Step 1: Write the failing tests**

```bash
# tests/unit/test_graft_stack_sync.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_sync_stack copies and activates every component marked resolution=copy, skipping resolution=skip" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"etch":{"slug_a":"etch","slug_b":null,"version_a":"2.0","version_b":null,"resolution":"copy"},"theme":{"slug_a":"etch-theme","slug_b":"divi","version_a":"1.0","version_b":"4.2","resolution":"skip"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp-content/plugins/etch"* ]]
  [[ "$output" == *"plugin activate etch"* ]]
  [[ "$output" != *"divi"* ]]  # resolution=skip must never be touched here
}

@test "graft_sync_stack uses slug_a from the manifest, never a hardcoded name — the ACSS v4 legacy-slug case" {
  # This is the exact bug Marcel caught: an earlier draft hardcoded "automatic-css"
  # for the acss component instead of reading the manifest's resolved slug_a. A
  # plugin under a legacy folder name on B must still be correctly synced FROM
  # A's real (possibly different) resolved path — never guessed from the
  # component's internal key name.
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"acss":{"slug_a":"automatic-css","slug_b":"acss-legacy-slug","version_a":"4.1","version_b":"3.9","resolution":"copy"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp-content/plugins/automatic-css/"* ]]  # pulled FROM A under A's resolved slug
  [[ "$output" == *"plugin activate automatic-css"* ]]      # activated under that same resolved slug
  [[ "$output" != *"wp-content/plugins/acss/"* ]]            # never the internal component key "acss"
  [[ "$output" != *"acss-legacy-slug"* ]]                    # never B's old slug either — A's is authoritative
}

@test "graft_sync_stack reads theme's slug_a the same way as any other component (no special-casing)" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"stack":{"theme":{"slug_a":"etch-theme","slug_b":null,"version_a":"1.0","version_b":null,"resolution":"copy"}}}'
  SITE_A_WP_PATH="/site-a"; SITE_B_WP_PATH="/site-b"; SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" "$manifest"
  [[ "$output" == *"wp-content/themes/etch-theme"* ]]
  [[ "$output" == *"theme activate etch-theme"* ]]
}

@test "graft_sync_stack does nothing when the manifest has no stack key" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  SITEGRAFT_DRY_RUN=1
  run graft_sync_stack "$run_dir" '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

```bash
# tests/unit/test_graft_precondition.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/inventory.sh'
  load '../../lib/graft.sh'
}

@test "graft_check_stack_precondition passes when the stack matches" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"t"},"plugins":[]}' > "$b"
  run graft_check_stack_precondition "$a" "$b" '{}' 0
  [ "$status" -eq 0 ]
}

@test "graft_check_stack_precondition refuses an unresolved mismatch without the override" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"theme-a"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"theme-b"},"plugins":[]}' > "$b"
  local manifest='{"stack":{"theme":{"slug_a":"theme-a","slug_b":"theme-b","version_a":"1.0","version_b":"4.2","resolution":"skip"}}}'
  run graft_check_stack_precondition "$a" "$b" "$manifest" 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"--allow-stack-mismatch"* ]]
}

@test "graft_check_stack_precondition passes a mismatch the manifest already resolved via copy (graft_sync_stack already ran)" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"theme-a"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"theme-b"},"plugins":[]}' > "$b"
  local manifest='{"stack":{"theme":{"slug_a":"theme-a","slug_b":"theme-b","version_a":"1.0","version_b":"4.2","resolution":"copy"}}}'
  run graft_check_stack_precondition "$a" "$b" "$manifest" 0
  [ "$status" -eq 0 ]
}

@test "graft_check_stack_precondition allows a remaining mismatch with the override flag" {
  local a="$BATS_TEST_TMPDIR/a.json" b="$BATS_TEST_TMPDIR/b.json"
  echo '{"active_theme":{"stylesheet":"theme-a"},"plugins":[]}' > "$a"
  echo '{"active_theme":{"stylesheet":"theme-b"},"plugins":[]}' > "$b"
  local manifest='{"stack":{"theme":{"slug_a":"theme-a","slug_b":"theme-b","version_a":"1.0","version_b":"4.2","resolution":"skip"}}}'
  run graft_check_stack_precondition "$a" "$b" "$manifest" 1
  [ "$status" -eq 0 ]
}
```

```bash
# tests/unit/test_graft_mediastep.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_media_pull_cmd routes A's uploads to a local staging dir via ssh when A is remote" {
  run graft_media_pull_cmd "user@host-a.example.com" "/site-a/wp-content/uploads/" "/run/media-staging/"
  [[ "$output" == *"rsync"* ]]
  [[ "$output" == *"user@host-a.example.com"* ]]
  [[ "$output" != *"scp"* ]]
}

@test "graft_media_pull_cmd has no ssh hop when A is local" {
  run graft_media_pull_cmd "" "/site-a/wp-content/uploads/" "/run/media-staging/"
  [[ "$output" != *"ssh"* ]] || [[ "$output" != *"@"* ]]
}

@test "graft_media_push_cmd never overwrites existing files on B" {
  run graft_media_push_cmd "user@host-b.example.com" "/run/media-staging/" "/site-b/wp-content/uploads/"
  [[ "$output" == *"--ignore-existing"* ]]
  [[ "$output" != *"scp"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_graft_mediastep.bats tests/unit/test_graft_precondition.bats tests/unit/test_graft_stack_sync.bats`
Expected: FAIL — `lib/graft.sh` does not exist.

- [ ] **Step 3: Write the stack-sync, precondition, media, and mu-plugin functions in `lib/graft.sh`**

```bash
#!/usr/bin/env bash
# lib/graft.sh — phase: graft. Rendering-stack sync/precondition, media sync,
# WXR export/import, mu-plugin mapping, ID/domain remaps, options migration,
# optional clean/idempotence pruning. See design doc §6.4, §9, §12.

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
    # Only this one theme/plugin's own directory is synced — never the whole
    # wp-content/themes/ or wp-content/plugins/ tree.
    run_or_echo rsync -avz ${SITE_A_SSH_HOST:+"${SITE_A_SSH_HOST}:"}"${SITE_A_WP_PATH}/${rel_dir}/" "${staging}/"
    run_or_echo rsync -avz "${staging}/" ${SITE_B_SSH_HOST:+"${SITE_B_SSH_HOST}:"}"${SITE_B_WP_PATH}/${rel_dir}/"
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
  if command -v gum >/dev/null 2>&1; then
    gum confirm "Proceed anyway? This is not the usual confirmation — B's theme/Etch/ACSS genuinely does not match A's." || return 1
  else
    read -r -p "Type EXACTLY 'proceed anyway' to continue despite the stack mismatch: " ans
    [ "$ans" = "proceed anyway" ] || return 1
  fi
}

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
graft_media_sync() {
  local run_dir="$1"
  local staging="${run_dir}/media-staging"
  mkdir -p "$staging"
  log_info "pulling A's media to the orchestrator..."
  run_or_echo rsync -avz ${SITE_A_SSH_HOST:+"${SITE_A_SSH_HOST}:"}"${SITE_A_WP_PATH}/wp-content/uploads/" "${staging}/"
  log_info "pushing media to B (never overwriting existing files)..."
  run_or_echo rsync -avz --ignore-existing "${staging}/" ${SITE_B_SSH_HOST:+"${SITE_B_SSH_HOST}:"}"${SITE_B_WP_PATH}/wp-content/uploads/"
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

> **PR #61 (2026-08-26): the `wp_import_insert_term` handler below was removed
> as dead code — it never produced a usable term id-map (see design doc §7's
> own correction, and `mu-plugins/sitegraft-id-mapper.php`, for why). Do not
> copy it verbatim from here any more.**

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

Run: `bats tests/unit/test_graft_mediastep.bats tests/unit/test_graft_precondition.bats tests/unit/test_graft_stack_sync.bats`
Expected: PASS (11 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/graft.sh mu-plugins/sitegraft-id-mapper.php tests/unit/test_graft_mediastep.bats tests/unit/test_graft_precondition.bats tests/unit/test_graft_stack_sync.bats
git commit -m "feat(graft): sync stack components using only the manifest's resolved slug, never a hardcoded name (fixes the ACSS v4 legacy-slug bug); enforce the precondition on what's left; route media sync through the orchestrator"
```

### Task 4.2: WXR export/import (routed through the orchestrator), integrity-gate, `wordpress-importer` provisioning

**Files:**
- Modify: `lib/graft.sh` (add `graft_export_wxr`, `graft_integrity_gate`,
  `graft_import_wxr`, `graft_ensure_importer`, `graft_restore_importer_state`)
- Test: `tests/unit/test_graft_integrity_gate.bats`, `tests/unit/test_graft_importer.bats`

**Interfaces:**
- Consumes: nothing new from earlier tasks besides `wp_remote`.
- Produces: `graft_integrity_gate <wxr_file_path> <allowed_post_types_json>` (pure
  function over a file's content — exit 0/1, per design doc §6.4 step 4: non-empty,
  has `<wp:wxr_version>`, ≥1 `<item>`, every `<wp:post_type>` found ∈ allowlist);
  `graft_export_wxr`/`graft_import_wxr` now route through the run directory
  (review finding A4, same as media in Task 4.1); `graft_ensure_importer
  <run_dir>` / `graft_restore_importer_state <run_dir>` (design doc §6.4 step 6,
  review finding A7 — install+activate `wordpress-importer` on B if absent,
  recording its exact prior install/active state so it can be restored afterward).

- [ ] **Step 1: Write the failing tests**

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

```bash
# tests/unit/test_graft_importer.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_restore_importer_state does nothing if no pre-state file was recorded" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  SITEGRAFT_DRY_RUN=1
  run graft_restore_importer_state "$run_dir"
  [ "$status" -eq 0 ]
}

@test "graft_restore_importer_state uninstalls the importer if it was absent before graft" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf 'absent\n' > "${run_dir}/.wordpress-importer-pre-state"
  SITEGRAFT_DRY_RUN=1
  run graft_restore_importer_state "$run_dir"
  [[ "$output" == *"plugin uninstall wordpress-importer"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_graft_integrity_gate.bats tests/unit/test_graft_importer.bats`
Expected: FAIL — the referenced functions do not exist yet.

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
  # `$allowed | index(.)` rebinds `.` to $allowed before index runs, so it
  # always searches $allowed for $allowed and `leaked` is always [] — silently
  # defeating this integrity gate. Bind the element with `as $x` so index
  # searches for the right thing. (Same trap as manifest_compute_unclaimed;
  # the leak test below fails against the buggy form, so keep it.)
  leaked=$(jq -n --argjson found "$found_types" --argjson allowed "$allowed_json" \
    '[$found[] as $x | select(($allowed | index($x)) | not) | $x]')
  if [ "$(echo "$leaked" | jq 'length')" != "0" ]; then
    log_error "WXR contains post_type(s) outside the manifest allowlist: $(echo "$leaked" | jq -r 'join(", ")')"
    return 1
  fi
}

# design doc §6.4 step 3/5 / review finding A4: export lands in the run directory
# on the orchestrator, pulled from A first if A is remote — never assumed directly
# visible to B.
graft_export_wxr() {
  local post_types_csv="$1" run_dir="$2"
  local staging="${run_dir}/export"
  mkdir -p "$staging"
  if [ -n "${SITE_A_SSH_HOST:-}" ]; then
    local remote_dir="/tmp/sitegraft-export-$$"
    run_or_echo ssh "$SITE_A_SSH_HOST" "mkdir -p '${remote_dir}'"
    run_or_echo wp_remote a export --post_type="$post_types_csv" --dir="$remote_dir"
    run_or_echo rsync -avz "${SITE_A_SSH_HOST}:${remote_dir}/" "${staging}/"
    run_or_echo ssh "$SITE_A_SSH_HOST" "rm -rf '${remote_dir}'"
  else
    run_or_echo wp_remote a export --post_type="$post_types_csv" --dir="$staging"
  fi
}

graft_import_wxr() {
  local run_dir="$1"
  local staging="${run_dir}/export"
  if [ -n "${SITE_B_SSH_HOST:-}" ]; then
    local remote_dir="/tmp/sitegraft-import-$$"
    run_or_echo ssh "$SITE_B_SSH_HOST" "mkdir -p '${remote_dir}'"
    run_or_echo rsync -avz "${staging}/" "${SITE_B_SSH_HOST}:${remote_dir}/"
    run_or_echo wp_remote b import "${remote_dir}/*.xml" --authors=skip
    run_or_echo ssh "$SITE_B_SSH_HOST" "rm -rf '${remote_dir}'"
  else
    run_or_echo wp_remote b import "${staging}/*.xml" --authors=skip
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_graft_integrity_gate.bats tests/unit/test_graft_importer.bats`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/graft.sh tests/unit/test_graft_integrity_gate.bats tests/unit/test_graft_importer.bats
git commit -m "feat(graft): route WXR export/import through the orchestrator; provision wordpress-importer with record-and-restore"
```

### Task 4.3: ID-map remap (two-pass sentinel technique), scoped to content tables

**Files:**
- Modify: `lib/graft.sh` (add `graft_content_tables_csv`, `graft_remap_attachment_ids`, `graft_check_orphan_parents`)
- Test: `tests/unit/test_graft_remap.bats`

**Interfaces:**
- Consumes: `id-map.tsv` format `old_id<TAB>new_id<TAB>post_type` (Task 4.1's
  mu-plugin log format); `inventory_table_prefix` (Task 1.5).
- Produces: `graft_content_tables_csv <alias>` (returns
  `{$prefix}posts,{$prefix}postmeta,{$prefix}options` for the given site alias —
  design doc §9.1/§9.4, review finding A6: this is the **only** table scope any
  `search-replace` call in this tool is allowed to use); `graft_build_sentinel_commands
  <id_map_tsv>` (pure function — given a TSV, prints the exact two-pass `wp
  search-replace` argument tuples, one per line, for inspection/testing without a
  live site); the real `graft_remap_attachment_ids` wraps this and actually invokes
  `wp_remote b search-replace --tables=<content_tables>` for each line.

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

@test "graft_remap_attachment_ids scopes every search-replace to content tables only (finding A6)" {
  local tsv="$BATS_TEST_TMPDIR/id-map.tsv"
  printf '10\t42\tattachment\n' > "$tsv"
  SITEGRAFT_DRY_RUN=1
  run graft_remap_attachment_ids "$tsv" "wp_prefix_posts,wp_prefix_postmeta,wp_prefix_options"
  [[ "$output" == *"--tables=wp_prefix_posts,wp_prefix_postmeta,wp_prefix_options"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_graft_remap.bats`
Expected: FAIL — `graft_build_sentinel_commands` does not exist.

- [ ] **Step 3: Add the remap functions to `lib/graft.sh`**

```bash
# Appended to lib/graft.sh

# design doc §9.1/§9.4 / review finding A6: the only table scope any
# search-replace call is allowed to use — a protected plugin's own tables are
# never in this list, so they can never be touched by a remap, even by accident.
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
  # Pass 1 fully before pass 2, per design doc §9.1 (sentinels must all land before
  # any get resolved to a real ID).
  while IFS=$'\t' read -r pass pattern replacement; do
    [ "$pass" = "1" ] || continue
    run_or_echo wp_remote b search-replace "$pattern" "$replacement" --tables="$content_tables_csv" --regex --precise --skip-columns=guid
  done < <(graft_build_sentinel_commands "$id_map_tsv")
  while IFS=$'\t' read -r pass pattern replacement; do
    [ "$pass" = "2" ] || continue
    run_or_echo wp_remote b search-replace "$pattern" "$replacement" --tables="$content_tables_csv" --precise --skip-columns=guid
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
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/graft.sh tests/unit/test_graft_remap.bats
git commit -m "feat(graft): add two-pass sentinel ID remap and orphan post_parent check, scoped to content tables only"
```

### Task 4.4: options migration, domain search-replace (scoped), module hooks, idempotence pruning, `phase_graft` assembly

**Files:**
- Modify: `lib/graft.sh` (add `graft_migrate_options`, `graft_search_replace_domain`,
  `graft_prune_previous_run`, `graft_run_module_post_import`, `phase_graft`)
- Test: `tests/unit/test_graft_options.bats`, `tests/unit/test_graft_phase_wiring.bats`

**Interfaces:**
- Consumes: everything from Tasks 4.1-4.3, `module_call` (Task 1.3),
  `manifest.migrate`/`manifest.clean` (Task 2.1).
- Produces: `graft_migrate_options <run_dir> <manifest_json>` (design doc §6.4 step
  8, review finding A1 — this step was entirely missing from the previous draft of
  this plan; it now fetches every `option_keys` entry from A via `wp option get
  --format=json`, writes each to `${run_dir}/option-<key>.value` — the exact file
  `core_wp_post_import` reads per design doc §9.3 — and pushes every key **except**
  `page_on_front`/`page_for_posts` directly onto B, leaving those two for the
  module hook to remap through `id-map.tsv`); `phase_graft` (the function
  `bin/sitegraft` dispatches to for `graft`, now gated by `graft_sync_stack`
  (Task 4.1) followed by `graft_check_stack_precondition` before anything else
  runs — sync whatever `plan` approved, then refuse on whatever is still
  unresolved).

- [ ] **Step 1: Write the failing test for `graft_migrate_options`**

```bash
# tests/unit/test_graft_options.bats
setup() {
  load '../../lib/core.sh'
  load '../../lib/graft.sh'
}

@test "graft_migrate_options writes an option file per key and skips page_on_front for direct push" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  local manifest='{"migrate":{"core-wp":{"option_keys":["show_on_front","page_on_front"]}}}'
  SITE_A_WP_PATH="/site-a"; SITE_A_WP_CMD="wp"; SITEGRAFT_DRY_RUN=1
  wp_remote() { # stub: pretend A always returns a fixed JSON value for any option
    if [ "$1" = "a" ]; then echo '"stub-value"'; fi
  }
  run graft_migrate_options "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
  [ -f "${run_dir}/option-show_on_front.value" ]
  [ -f "${run_dir}/option-page_on_front.value" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_graft_options.bats`
Expected: FAIL — `graft_migrate_options` does not exist yet.

- [ ] **Step 3: Add the remaining functions to `lib/graft.sh`**

```bash
# Appended to lib/graft.sh

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

graft_search_replace_domain() {
  local from="$1" to="$2" content_tables_csv="$3"
  run_or_echo wp_remote b search-replace "$from" "$to" --tables="$content_tables_csv" --skip-columns=guid --precise
  local from_escaped to_escaped
  from_escaped=$(printf '%s' "$from" | sed 's#/#\\/#g')
  to_escaped=$(printf '%s' "$to" | sed 's#/#\\/#g')
  run_or_echo wp_remote b search-replace "$from_escaped" "$to_escaped" --tables="$content_tables_csv" --skip-columns=guid --precise
}

# design doc §11 "idempotent reimport": before importing, delete any post B already
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
  local profile="" run_dir="" allow_mismatch=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --run) run_dir="$2"; shift 2 ;;
      --allow-stack-mismatch) allow_mismatch=1; shift ;;
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
  local content_tables_csv; content_tables_csv=$(graft_content_tables_csv b)

  # design doc §6.4 step 0a/0b (Marcel's revision of finding B1): sync whatever
  # plan approved for copying, THEN enforce the hard precondition on whatever
  # is left unresolved — never the other order, or the precondition would
  # refuse components graft_sync_stack was about to fix anyway.
  graft_step_done "$run_dir" stack_sync || { graft_sync_stack "$run_dir" "$manifest"; graft_mark_step "$run_dir" stack_sync; }
  graft_check_stack_precondition "${run_dir}/scan-a.json" "${run_dir}/scan-b.json" "$manifest" "$allow_mismatch" || return 1

  graft_step_done "$run_dir" media_sync    || { graft_media_sync "$run_dir"; graft_mark_step "$run_dir" media_sync; }
  graft_step_done "$run_dir" mu_plugin     || { graft_deploy_mu_plugin; graft_mark_step "$run_dir" mu_plugin; }
  graft_step_done "$run_dir" prune         || { graft_prune_previous_run "$post_types_csv"; graft_mark_step "$run_dir" prune; }
  graft_step_done "$run_dir" importer_setup || { graft_ensure_importer "$run_dir"; graft_mark_step "$run_dir" importer_setup; }
  graft_step_done "$run_dir" export        || {
    graft_export_wxr "$post_types_csv" "$run_dir"
    for f in "${run_dir}/export"/*.xml; do
      graft_integrity_gate "$f" "$(echo "$manifest" | jq -c '[.migrate[].post_types[]?]')" || return 1
    done
    graft_mark_step "$run_dir" export
  }
  graft_step_done "$run_dir" import        || { graft_import_wxr "$run_dir"; graft_mark_step "$run_dir" import; }
  graft_step_done "$run_dir" fetch_id_map  || {
    run_or_echo rsync -avz ${SITE_B_SSH_HOST:+"${SITE_B_SSH_HOST}:"}"${SITE_B_WP_PATH}/wp-content/sitegraft-id-map.log" "${run_dir}/id-map.tsv"
    graft_mark_step "$run_dir" fetch_id_map
  }
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
```

Note the ordering: `migrate_options` runs **after** `remap_ids`/`remap_domain` but
**before** `module_hooks` — `core_wp_post_import` (the module hook that remaps
`page_on_front`, design doc §9.3) needs `option-page_on_front.value` to already be
on disk, which `migrate_options` is what writes it.

- [ ] **Step 4: Run tests to verify they pass**

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

Run: `bats tests/unit/test_graft_options.bats tests/unit/test_graft_phase_wiring.bats`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/graft.sh tests/unit/test_graft_options.bats tests/unit/test_graft_phase_wiring.bats
git commit -m "feat(graft): add the missing options-migration step, scope domain remap, and assemble the full graft phase behind the stack precondition"
```

---

## Step 5 — Verify + full DDEV harness assertions

Delivers: `sitegraft verify --profile <name>` plus a DDEV harness that now proves
every claim the tool makes, not just "protected data unchanged" (design doc §6.5,
§10, review finding B3).

### Task 5.1: `lib/verify.sh` — normalized checksums, migrated-option values, `page_on_front` correctness, domain absence, orphan/nav/HTTP checks, report

**Files:**
- Create: `lib/verify.sh`
- Test: `tests/unit/test_verify.bats`

**Interfaces:**
- Consumes: `manifest.checksums_protected_pre_graft`, `backup_checksum` (Task 3.1);
  `graft_check_orphan_parents`, `graft_content_tables_csv` (Task 4.3).
- Produces: `verify_compare_checksums <manifest_json> <recomputed_checksums_json>`
  (pure function — exit 0 if identical, 1 with a diff listed otherwise);
  `verify_options_match <run_dir> <manifest_json>` (design doc §6.5, review
  finding B3 — spot-checks each migrated option's value on B against the
  `option-<key>.value` file `graft` wrote, exit 0/1 with a diff);
  `verify_domain_absent <alias> <content_tables_csv> <domain>` (exit 0/1 — is
  `domain` absent from B's content tables?); `phase_verify` — its report also
  lists every `manifest.stack.*` component copied from A as a re-licensing
  reminder (design doc §12/§6.5), not a pass/fail check, since licensing isn't
  something sitegraft can verify.

- [ ] **Step 1: Write the failing tests**

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

@test "verify_options_match fails when B's live value differs from the file graft wrote" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '{"theme_mode":"dark"}' > "${run_dir}/option-etch_settings.value"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}}}'
  wp_remote() { echo '{"theme_mode":"light"}'; } # stub: B's live value differs
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"etch_settings"* ]]
}

@test "verify_options_match passes when B's live value matches" {
  local run_dir="$BATS_TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  printf '{"theme_mode":"dark"}' > "${run_dir}/option-etch_settings.value"
  local manifest='{"migrate":{"etch":{"option_keys":["etch_settings"]}}}'
  wp_remote() { echo '{"theme_mode":"dark"}'; }
  run verify_options_match "$run_dir" "$manifest"
  [ "$status" -eq 0 ]
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

# design doc §6.5 / review finding B3: catches a silently-skipped or
# partially-applied options migration, which the old harness could not detect.
verify_options_match() {
  local run_dir="$1" manifest="$2"
  local key mismatched=""
  for key in $(echo "$manifest" | jq -r '[.migrate[].option_keys[]?] | unique[]'); do
    local expected actual
    [ -f "${run_dir}/option-${key}.value" ] || continue
    expected=$(cat "${run_dir}/option-${key}.value")
    actual=$(wp_remote b option get "$key" --format=json 2>/dev/null || echo 'null')
    [ "$expected" = "$actual" ] || mismatched="${mismatched}${key} "
  done
  if [ -n "$mismatched" ]; then
    log_error "migrated option value(s) do not match A's on B: ${mismatched}"
    return 1
  fi
}

# design doc §6.5 / review finding B3: catches an incomplete or broken domain
# search-replace — scoped to content tables only, same as graft's own remaps.
verify_domain_absent() {
  local domain="$1" content_tables_csv="$2"
  local hit
  hit=$(wp_remote b db query \
    "SELECT 1 FROM $(echo "$content_tables_csv" | cut -d, -f1) WHERE post_content LIKE '%${domain}%' LIMIT 1" \
    --skip-column-names 2>/dev/null || echo "")
  [ -z "$hit" ]
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

  if verify_options_match "$run_dir" "$manifest" >> "$report" 2>&1; then
    echo "- [x] migrated options match A's values on B" >> "$report"
  else
    echo "- [ ] **HARD FAIL: migrated option value mismatch** — see above" >> "$report"
    hard_fail=1
  fi

  local domain; domain=$(echo "$manifest" | jq -r '.options.search_replace.from // ""' | sed -E 's#^https?://##')
  local content_tables_csv; content_tables_csv=$(graft_content_tables_csv b)
  if [ -n "$domain" ] && verify_domain_absent "$domain" "$content_tables_csv"; then
    echo "- [x] A's domain string is absent from B's content" >> "$report"
  elif [ -n "$domain" ]; then
    echo "- [ ] **HARD FAIL: A's domain string is still present in B's content**" >> "$report"
    hard_fail=1
  fi

  local orphans; orphans=$(graft_check_orphan_parents)
  if [ -z "$orphans" ]; then
    echo "- [x] no orphan post_parent references" >> "$report"
  else
    echo "- [ ] orphan post_parent references found: ${orphans}" >> "$report"
  fi

  local front_id front_expected
  front_id=$(wp_remote b option get page_on_front 2>/dev/null || echo "")
  front_expected=$(awk -F'\t' -v old="$(cat "${run_dir}/option-page_on_front.value" 2>/dev/null | tr -d '"')" '$1==old{print $2}' "${run_dir}/id-map.tsv" 2>/dev/null || echo "")
  if [ -n "$front_id" ] && wp_remote b post get "$front_id" --field=ID >/dev/null 2>&1; then
    if [ -z "$front_expected" ] || [ "$front_id" = "$front_expected" ]; then
      echo "- [x] page_on_front resolves to the correctly remapped page" >> "$report"
    else
      echo "- [ ] **HARD FAIL: page_on_front resolves to page ${front_id}, expected the remap of A's front page (${front_expected})**" >> "$report"
      hard_fail=1
    fi
  else
    echo "- [ ] page_on_front does not resolve — check manually" >> "$report"
  fi

  # design doc §6.5/§12: not a pass/fail check — a reminder that can't be
  # automated away. A stack component graft copied from A always comes up
  # unlicensed on B (rsync copies code, never the wp_options a license lives in).
  local copied; copied=$(echo "$manifest" | jq -r '.stack // {} | to_entries[] | select(.value.resolution == "copy") | .key')
  if [ -n "$copied" ]; then
    echo "- [ ] **REMINDER: re-license on B before going live** — copied from A and activated: $(echo "$copied" | tr '\n' ' ')" >> "$report"
  fi

  log_info "verify report written: ${report}"
  return "$hard_fail"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_verify.bats`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/verify.sh tests/unit/test_verify.bats
git commit -m "feat(verify): add migrated-option and domain-absence checks, tighten page_on_front to the correct remap (finding B3)"
```

### Task 5.2: grow the DDEV harness through `graft`, `verify`, and `restore` — the full B3 assertion set

**Files:**
- Modify: `tests/integration/ddev-harness.sh` (add the `graft`, `verify`, `restore`
  calls and the full positive-assertion set from design doc §10/review finding B3)

**Interfaces:**
- Consumes: `bin/sitegraft` (all phases, Steps 1-5), fixtures from Task 1.4.
- Produces: an exit-code contract — 0 means the full pipeline ran, protected data
  was byte-identical before/after both `graft` and `restore`, **and** every B3
  positive assertion (migrated options, `page_on_front`, domain absence) held;
  non-zero means a regression, printed to stderr with which assertion failed.

- [ ] **Step 1: Grow the DDEV harness to completion**

```bash
# Insert into tests/integration/ddev-harness.sh, replacing the
# "no later phase wired yet" placeholder line from Task 3.2:

PRE_CHECKSUM="$CHECKSUM_1"

echo "==> running graft"
"${ROOT}/bin/sitegraft" graft --profile ddev-test --run "$RUN_DIR"

echo "==> asserting protected data is unchanged (post-graft) — finding A5/A6 in practice"
POST_CHECKSUM=$(b_protected_checksum)
if [ "$PRE_CHECKSUM" != "$POST_CHECKSUM" ]; then
  echo "FAIL: protected fake plugin data changed during graft" >&2
  exit 1
fi

echo "==> asserting migrated content is present on B"
ddev --project "$PROJECT_B" wp post list --post_type=etch_cfs --field=post_title | grep -q "Hero CFS"

echo "==> asserting migrated options carry A's exact seeded value (finding A1/B3)"
ddev --project "$PROJECT_B" wp option get etch_settings --format=json | grep -q '"theme_mode":"dark"'

echo "==> asserting page_on_front resolves to the correctly remapped page (finding B3)"
FRONT_ID=$(ddev --project "$PROJECT_B" wp option get page_on_front)
ddev --project "$PROJECT_B" wp post get "$FRONT_ID" --field=post_title | grep -q "Home"

echo "==> asserting A's domain is absent from B's imported content (finding B3)"
DOMAIN_HITS=$(ddev --project "$PROJECT_B" wp db query \
  "SELECT COUNT(*) FROM $(b_table posts) WHERE post_content LIKE '%a.example.com%'" \
  --skip-column-names)
[ "$DOMAIN_HITS" = "0" ]

echo "==> running verify"
"${ROOT}/bin/sitegraft" verify --profile ddev-test --run "$RUN_DIR"

echo "==> running restore and re-checking protected + migrated state"
"${ROOT}/bin/sitegraft" restore --profile ddev-test --run "$RUN_DIR" --yes
RESTORE_CHECKSUM=$(b_protected_checksum)
if [ "$PRE_CHECKSUM" != "$RESTORE_CHECKSUM" ]; then
  echo "FAIL: protected fake plugin data differs after restore" >&2
  exit 1
fi

echo "ALL ASSERTIONS PASSED"
rm -f "${ROOT}/profiles/ddev-test.conf"
```

- [ ] **Step 2: Run the full harness and fix whatever the first real end-to-end run surfaces**

Run: `tests/integration/ddev-harness.sh`
Expected: `ALL ASSERTIONS PASSED`. Every earlier task already met a real WordPress
install incrementally (Tasks 1.4, 1.5, 3.2), so this run is the first time `graft`,
`verify`, and `restore` specifically run against a live install — budget time for
fixing integration-only bugs the unit tests couldn't catch (expected and normal,
not a sign the plan was wrong; see design doc §0.2 R2 and R4, and §15.1's note
that this second pass does not close R2/R4 either — only a real dry run does, see
`docs/definition-of-done.md`).

- [ ] **Step 3: Commit**

```bash
git add tests/integration/ddev-harness.sh
git commit -m "test(integration): complete the DDEV harness with the full graft/verify/restore assertion set (finding B3)"
```

---

## Step 6 — Polish

Delivers: a v1 ready to publish per `docs/definition-of-done.md`.

### Task 6.1: `--dry-run` and `--allow-stack-mismatch` audit across all writing phases

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

Run: `grep -n -E "wp_remote (b|a) (import|option update|search-replace|post delete|db import|plugin (install|activate|deactivate|uninstall))|rsync -avz [^-]|ssh " lib/*.sh | grep -v run_or_echo`
Expected: empty output. Fix any hit by wrapping it in `run_or_echo`.

- [ ] **Step 3: Manual smoke tests**

Run: `bin/sitegraft graft --profile ddev-test --dry-run` against the DDEV harness
sites (fixtures already seeded from Step 1) and confirm no actual DB/file mutation
occurs (re-run the pre-graft checksum and confirm it is unchanged, then confirm the
command printed the actions it would have taken).

Run: `bin/sitegraft graft --profile ddev-test` against a deliberately mismatched
stack (swap B's active theme first) without `--allow-stack-mismatch` and confirm it
refuses with the expected error; re-run with `--allow-stack-mismatch` and confirm
the loud warning + confirmation prompt appear before it proceeds.

- [ ] **Step 4: Commit**

```bash
git add bin/sitegraft lib/
git commit -m "fix(dry-run): ensure every mutating call across all phases respects --dry-run; smoke-test the stack-mismatch override"
```

### Task 6.2: usage docs, install instructions

**Files:**
- Modify: `README.md` (verify the Usage section matches the final CLI flags exactly
  — including `--allow-stack-mismatch`, added in Step 4)
- Create (only if README.md's usage section grows too long to stay scannable):
  `docs/usage.md`

- [ ] **Step 1: Re-read `README.md` against the actual final `bin/sitegraft` flag parsing**

Confirm every documented command (`scan`, `plan`, `backup`, `graft`, `verify`,
`restore`) and flag (`--profile`, `--run`, `--dry-run`, `--yes`,
`--allow-stack-mismatch`) matches what `bin/sitegraft`'s `case` statements
actually accept. Fix any drift.

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
format, §6 phase walkthrough, §7 mu-plugin, §8 media/import ordering, §9 remaps,
§11 edge cases, §12 stack precondition, §13 classic-menu scope), confirm the
shipped code matches what's documented. Fix any drift in whichever side is wrong
(usually the code, since the design doc is the spec — but if implementation
revealed the spec was wrong, update the design doc and note it in
`docs/status.md`).

- [ ] **Step 2: Grep the whole repo for anything that looks like a real secret/host**

Run: `grep -rniE "([0-9]{1,3}\.){3}[0-9]{1,3}|ssh-rsa|-----BEGIN|password\s*=|token\s*=" --include='*.sh' --include='*.md' --include='*.conf' --include='*.php' .`
Expected: no real IPs, keys, passwords, or tokens — only placeholder text
(`example.com`, `user@host`) if anything matches at all. This is the last gate before
the repo is safe to publish publicly (design doc §0, LICENSE task below).

- [ ] **Step 3: Confirm the pre-v1.0.0 DoD gate is still open, and why that's correct**

`docs/definition-of-done.md` requires a real dry run against a genuine A/B pair
staging copy before any `1.0.0` tag — this is deliberate (it's how R2/R4 from
design doc §0.2 get closed, not by more DDEV-only testing). Do not check that box
as part of this task; it is Marcel's call, on a real pair, separately.

- [ ] **Step 4: Bump `SITEGRAFT_VERSION` in `bin/sitegraft`** to a pre-release marker
      (e.g. `1.0.0-rc1`, not `1.0.0`) once every other DoD item in
      `docs/definition-of-done.md` is checked — reserve the plain `1.0.0` bump for
      after the real dry run in Step 3 above has actually happened.

- [ ] **Step 5: Update `docs/status.md` and `docs/todo.md`** to reflect v1 complete
      modulo the real-dry-run gate, move any deferred items (e.g. a real
      `motopress.sh` module, `docs/usage.md` split, a classic-menus module) into
      `docs/todo.md` → Backlog.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore(release): v1.0.0-rc1 — full scan-plan-backup-graft-verify-restore pipeline, pending a real dry run before 1.0.0"
```
