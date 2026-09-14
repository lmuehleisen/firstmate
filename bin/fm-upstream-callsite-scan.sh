#!/usr/bin/env bash
# fm-upstream-callsite-scan.sh - flag fork-only callers of helpers upstream redefined.
#
# Usage: fm-upstream-callsite-scan.sh <previous-upstream> <upstream> <fork>
#   <previous-upstream>  the upstream commit the last integration merged
#   <upstream>           the upstream commit this integration merges
#   <fork>               the fork commit before this integration (usually origin/main)
#
# A clean textual merge can still break a fork-only caller when upstream changes
# a shared helper's calling convention without renaming it (the task_show
# stdout-to-variable change is the recorded case). Run this after every upstream
# merge, before tests, and account for every reported call site in the PR body.
#
# The scan is read-only and runs in the current repository:
#   1. Redefined helpers: function definition lines under bin/ that
#      `git diff <previous-upstream> <upstream>` both removes and adds, matched
#      at line start as `name() {`.
#   2. Fork-only call sites: lines under bin/ that
#      `git diff <previous-upstream> <fork>` adds and that mention a redefined
#      name as a whole word, excluding the fork's own definition lines.
# A convention change confined to a helper's body is not detected, so this
# complements the full suite rather than replacing it.
#
# Output: one `REDEFINED: <name>` line per redefined helper, one
# `CALLSITE: <name> <path>: <added line>` line per fork-only call site, then a
# `SUMMARY:` line. Exit 0 when no fork-only call site exists, 1 when at least
# one does, 2 on usage or git errors.
set -u

usage() {
  sed -n '3,6s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

case "${1:-}" in -h|--help) sed -n '2,29s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;; esac
[ "$#" -eq 3 ] || usage
base=$1 upstream=$2 fork=$3
for ref in "$base" "$upstream" "$fork"; do
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || {
    echo "error: not a commit in this repository: $ref" >&2
    exit 2
  }
done

upstream_diff=$(git diff --no-color --no-ext-diff "$base" "$upstream" -- bin) || exit 2
fork_diff=$(git diff --no-color --no-ext-diff "$base" "$fork" -- bin) || exit 2

names=$(printf '%s\n' "$upstream_diff" | awk '
  match($0, /^[-+][A-Za-z_][A-Za-z0-9_]*\(\) \{/) {
    side = substr($0, 1, 1)
    name = substr($0, 2, RLENGTH - 5)
    seen[name] = seen[name] side
  }
  END { for (n in seen) if (seen[n] ~ /-/ && seen[n] ~ /\+/) print n }
' | LC_ALL=C sort)

hits=0
for name in $names; do
  printf 'REDEFINED: %s\n' "$name"
done
for name in $names; do
  found=$(printf '%s\n' "$fork_diff" | awk -v name="$name" '
    /^\+\+\+ / { path = substr($0, 5); sub(/^b\//, "", path); next }
    /^\+/ {
      line = substr($0, 2)
      if (line ~ ("^[[:space:]]*" name "\\(\\)")) next
      rest = line
      while ((i = index(rest, name)) > 0) {
        before = (i > 1) ? substr(rest, i - 1, 1) : ""
        after = substr(rest, i + length(name), 1)
        if (before !~ /[A-Za-z0-9_-]/ && after !~ /[A-Za-z0-9_-]/) {
          printf "CALLSITE: %s %s: %s\n", name, path, line
          break
        }
        rest = substr(rest, i + length(name))
      }
    }
  ')
  [ -z "$found" ] || { printf '%s\n' "$found"; hits=$((hits + $(printf '%s\n' "$found" | wc -l))); }
done
count=$(printf '%s\n' "$names" | grep -c . || true)
printf 'SUMMARY: %s redefined helper(s), %s fork-only call site(s)\n' "$count" "$hits"
[ "$hits" -eq 0 ]
