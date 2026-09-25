#!/usr/bin/env bash
# tests/tmproot-guard.sh - the one guard every test cleanup path uses before it
# removes a fixture temp root.
#
# tests/lib.sh sources this, so every test that sources the library already has
# it; the few tests that deliberately avoid the library source this file alone.
#
#   fm_test_rm_tmproot <path>...      remove each path only when it is a safe temp root
#   fm_test_require_tmproot <path>    end the test unless <path> is a safe temp root
#
# A path is a safe temp root only when it is non-empty, not `/`, strictly below
# a temporary base (the TMPDIR in force when this file was sourced, the current
# TMPDIR, or /tmp, each canonicalized), and neither the firstmate checkout this
# file lives in nor an ancestor of it. Trailing slashes are dropped and the
# final path component is not followed, so a symlinked root is judged - and
# removed - as the link itself, never as the directory it points at.
#
# The guard exists because a root variable that came back empty - a failed
# fm_test_tmproot, an unset optional directory - and was then canonicalized
# through `cd "$root" && pwd` silently becomes the caller's working directory,
# which for a test is the checkout; an EXIT trap removing that root then deletes
# the whole checkout. An empty or already-absent path is a silent no-op, so an
# optional cleanup variable that was never set needs no check of its own; every
# other refusal names the path and the reason on stderr and returns non-zero.

if [ -n "${FM_TEST_TMPROOT_GUARD_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_TMPROOT_GUARD_SOURCED=1

fm_test_tmproot_guard_canonical_dir() {  # <dir> -> canonical path, or non-zero
  [ -n "${1:-}" ] || return 1
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

FM_TEST_TMPROOT_GUARD_CHECKOUT=$(fm_test_tmproot_guard_canonical_dir "$(dirname "${BASH_SOURCE[0]}")/..") || {
  printf 'tests/tmproot-guard.sh: precondition unmet: cannot resolve the checkout containing %s\n' \
    "${BASH_SOURCE[0]}" >&2
  exit 1
}
FM_TEST_TMPROOT_GUARD_SOURCE_TMPDIR=${TMPDIR:-/tmp}

# fm_test_tmproot_guard_resolve <path>: print the canonical path that removing
# <path> would act on - trailing slashes dropped and the parent resolved, the
# final component left unfollowed - or return non-zero when there is none (an
# empty path, the filesystem root, a `.`/`..` final component, or an
# unresolvable parent). Removal acts on this path, never on the caller's
# spelling, so `link/` cannot make rm descend through a symlink the check did
# not follow.
fm_test_tmproot_guard_resolve() {
  local base=${1-} parent
  while :; do
    case "$base" in
      */) base=${base%/} ;;
      *) break ;;
    esac
  done
  [ -n "$base" ] || return 1
  case "${base##*/}" in
    . | ..) return 1 ;;
  esac
  case "$base" in
    */*) parent=${base%/*} ;;
    *) parent=. ;;
  esac
  [ -n "$parent" ] || parent=/
  parent=$(fm_test_tmproot_guard_canonical_dir "$parent") || return 1
  printf '%s/%s\n' "${parent%/}" "${base##*/}"
}

# fm_test_tmproot_guard_reason <path>: print why <path> must not be removed and
# return 0, or print nothing and return 1 when it is a safe temp root. An absent
# path yields the reason "absent" so callers can treat it as nothing to do.
fm_test_tmproot_guard_reason() {
  local path=${1-} base canon base_dir under=0
  if [ -z "$path" ]; then
    printf 'empty path\n'
    return 0
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'absent\n'
    return 0
  fi
  if ! canon=$(fm_test_tmproot_guard_resolve "$path"); then
    base=${path%"${path##*[!/]}"}
    if [ -z "$base" ]; then
      printf 'the filesystem root\n'
    else
      case "${base##*/}" in
        . | ..) printf 'a relative directory component\n' ;;
        *) printf 'its parent directory cannot be resolved\n' ;;
      esac
    fi
    return 0
  fi
  case "$FM_TEST_TMPROOT_GUARD_CHECKOUT/" in
    "$canon"/*)
      printf 'it is or contains the checkout %s\n' "$FM_TEST_TMPROOT_GUARD_CHECKOUT"
      return 0
      ;;
  esac
  for base_dir in "$FM_TEST_TMPROOT_GUARD_SOURCE_TMPDIR" "${TMPDIR:-/tmp}" /tmp; do
    base_dir=$(fm_test_tmproot_guard_canonical_dir "$base_dir") || continue
    [ "$base_dir" != / ] || continue
    case "$canon" in
      "$base_dir"/?*) under=1; break ;;
    esac
  done
  if [ "$under" -ne 1 ]; then
    printf 'it is not strictly below a temporary directory\n'
    return 0
  fi
  return 1
}

fm_test_rm_tmproot() {  # <path>...
  local path reason canon rc=0
  for path in "$@"; do
    if reason=$(fm_test_tmproot_guard_reason "$path"); then
      case "$reason" in
        'empty path' | absent) continue ;;
      esac
      printf 'fm_test_rm_tmproot: refusing to remove %s: %s\n' "$path" "$reason" >&2
      rc=1
      continue
    fi
    canon=$(fm_test_tmproot_guard_resolve "$path") || { rc=1; continue; }
    rm -rf -- "$canon" || rc=1
  done
  return "$rc"
}

fm_test_require_tmproot() {  # <path>
  local reason canon
  if reason=$(fm_test_tmproot_guard_reason "${1-}"); then
    printf 'not ok - fixture temp root is unusable (%s): %s\n' "${1-}" "$reason" >&2
    exit 1
  fi
  canon=$(fm_test_tmproot_guard_resolve "$1") || canon=
  if [ -z "$canon" ] || [ ! -d "$canon" ] || [ -L "$canon" ]; then
    printf 'not ok - fixture temp root is not a real directory: %s\n' "$1" >&2
    exit 1
  fi
}
