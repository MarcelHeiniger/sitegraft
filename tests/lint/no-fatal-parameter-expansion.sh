#!/usr/bin/env bash
# tests/lint/no-fatal-parameter-expansion.sh — repo guard against bash's
# `${var:?msg}` / `${!var:?msg}` "required parameter" expansion.
#
# WHY THIS EXISTS
# ---------------
# That expansion reads like a safe guard and is not one on this project's
# target shell. On bash 3.2 (Apple's /bin/bash — GNU bash 3.2.57(1),
# arm64-apple-darwin25), a fatal parameter-expansion error raised *inside a
# function* under `set -euo pipefail` — which is exactly bin/sitegraft's
# line 3 — kills the whole process while reporting $?=0:
#
#     $ cat q.sh
#     set -euo pipefail
#     trap 'echo "EXIT trap saw \$?=$?" >&2' EXIT
#     f() { local pv="NOPE"; local p="${!pv:?missing $pv}"; echo unreachable; }
#     f
#     $ /bin/bash q.sh; echo "process exit code: $?"
#     q.sh: line 3: !pv: missing NOPE
#     EXIT trap saw $?=0
#     process exit code: 0
#
# The message prints, the process dies, and it reports success. An EXIT trap
# sees $?=0; a caller sees a clean run. That is the exact failure class
# CLAUDE.md's first convention exists to prevent — the safety mechanism
# fires and its bookkeeping lies.
#
# The shipped code has used the safe form for a long time and documents the
# reasoning at three sites (lib/inventory.sh, lib/backup.sh, lib/profile.sh),
# but nothing enforced it: the implementation plan kept the dangerous form in
# two of its code blocks for months, where it read as a reference to copy,
# and was only caught by a human reading the doc. This guard closes the
# class instead of waiting for that to happen a second time.
#
# THE SAFE FORM (see lib/backup.sh's backup_wp_cmd_literal):
#
#     local path="${!path_var:-}"
#     if [ -z "$path" ]; then
#       log_error "missing ${path_var}"
#       return 1
#     fi
#
# WHAT IS SCANNED
# ---------------
# Shell sources (bin/sitegraft, *.sh, *.sh.example, *.bats) and Markdown.
# In shell sources, every line except whole-line `#` comments. In Markdown,
# ONLY lines inside ```bash / ```sh / ```shell fences, again minus whole-line
# comments — because a fenced code block is what a contributor copies, while
# surrounding prose is where this pattern legitimately gets *discussed*. That
# split is what lets the three lib/ comments above, and this file's own
# header, describe the trap without tripping it.
#
# Usage: no-fatal-parameter-expansion.sh [root]   (default: the repo root)
# Exits 0 when clean, 1 when any occurrence is found (printed file:line:text).

set -euo pipefail

root="${1:-}"
if [ -z "$root" ]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

if [ ! -d "$root" ]; then
  printf 'no-fatal-parameter-expansion: not a directory: %s\n' "$root" >&2
  exit 2
fi

# Prefer git's own file list (respects .gitignore, skips .git) and fall back
# to find for a plain directory — the fixture trees the unit tests point this
# at are not git repos.
#
# `--others --exclude-standard` alongside `--cached` is load-bearing, not
# belt-and-braces: with `ls-files` alone a brand-new, not-yet-`git add`ed file
# is invisible, so the guard would wave through the exact moment it matters
# most — a contributor writing the bad line for the first time, running the
# suite, and being told they are clean. (Caught by this script failing its own
# fixture during development.) Ignored files stay excluded on purpose.
list_files() {
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" ls-files -z --cached --others --exclude-standard \
      | while IFS= read -r -d '' f; do
          printf '%s/%s\0' "$root" "$f"
        done
  else
    find "$root" -type f -print0
  fi
}

hits=0
scanned=0
while IFS= read -r -d '' file; do
  case "$file" in
    *.md)                                    is_md=1 ;;
    *.sh|*.sh.example|*.bats|*/bin/sitegraft) is_md=0 ;;
    *) continue ;;
  esac

  # Report paths relative to $root so output is stable regardless of cwd.
  rel="${file#"$root"/}"
  scanned=$((scanned + 1))

  # `[ \t]` rather than `[[:space:]]`: CI's awk is Ubuntu's mawk, not gawk,
  # and POSIX character classes are a late and uneven addition there. Leading
  # whitespace in a source file is spaces or tabs, so the two are equivalent
  # here and this form works on every awk.
  found=$(awk -v md="$is_md" -v rel="$rel" '
    # Markdown: track fenced blocks, and only look inside shell ones.
    md && /^[ \t]*```/ {
      if (in_fence) { in_fence = 0; next }
      lang = $0
      sub(/^[ \t]*```[ \t]*/, "", lang)
      sub(/[ \t]+$/, "", lang)
      if (lang == "bash" || lang == "sh" || lang == "shell") in_fence = 1
      next
    }
    md && !in_fence { next }

    # A whole-line comment is documentation, not something that executes.
    /^[ \t]*#/ { next }

    # Any `:?` inside a ${...} expansion. Deliberately broad: ${VAR:?msg},
    # ${!indirect:?msg} and ${1:?msg} are all the same fatal operator.
    /\$\{[^}]*:\?/ { printf "%s:%d:%s\n", rel, FNR, $0 }
  ' "$file") || true

  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    hits=$((hits + 1))
  fi
done < <(list_files)

# A guard that examined nothing must not report "clean" — that is the very
# failure mode it exists to prevent (CLAUDE.md: distinguish "verified true"
# from "could not verify"). Zero scannable files means a bad root, a broken
# file listing, or a moved tree, never a passing repo.
if [ "$scanned" -eq 0 ]; then
  printf 'no-fatal-parameter-expansion: scanned 0 files under %s — refusing to report a pass\n' "$root" >&2
  exit 2
fi

if [ "$hits" -gt 0 ]; then
  cat >&2 <<'EOF'

Found bash's required-parameter expansion — the `:?` form, direct or indirect
— in shell code (or in a shell code block a contributor would copy). On bash
3.2 this exits the whole process reporting $?=0: it announces success while
failing. Use the safe form instead:

    local path="${!path_var:-}"
    if [ -z "$path" ]; then
      log_error "missing ${path_var}"
      return 1
    fi

See this script's header, lib/inventory.sh's wp_remote, and lib/backup.sh's
backup_wp_cmd_literal.
EOF
  exit 1
fi

exit 0
