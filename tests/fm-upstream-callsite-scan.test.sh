#!/usr/bin/env bash
# Behavior tests for bin/fm-upstream-callsite-scan.sh: a fork-only caller of a
# helper whose definition upstream rewrote is reported by name and fails the
# scan, while callers of unchanged helpers, longer names that merely contain a
# redefined one, fork redefinitions, and upstream's own call sites stay quiet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-upstream-callsite-scan.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-callsite-scan)

commit_all() {  # <repo> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.invalid commit -qm "$2"
}

# B: the previous integration point. U: upstream rewrote task_show's definition
# (stdout to a variable) and kept pr_for_task byte-identical. F: the fork added
# callers of both, a longer name containing task_show, and its own redefinition
# of a separate helper.
make_history() {  # <repo>
  local repo=$1
  mkdir -p "$repo/bin"
  git -C "$repo" init -q
  cat > "$repo/bin/lib.sh" <<'SH'
task_show() {
  printf '%s\n' "row"
}
pr_for_task() {
  printf '%s\n' "pr"
}
helper_kept() { :; }
SH
  commit_all "$repo" base
  git -C "$repo" branch -q base
  git -C "$repo" checkout -q -b upstream
  cat > "$repo/bin/lib.sh" <<'SH'
task_show() {  # sets TASK_SHOW_OUTPUT
  TASK_SHOW_OUTPUT=row
}
pr_for_task() {
  printf '%s\n' "pr"
}
helper_kept() { :; }
SH
  # shellcheck disable=SC2016  # literal fixture source, expanded by nothing
  printf '%s\n' 'task_show "$id"' > "$repo/bin/upstream-caller.sh"
  commit_all "$repo" upstream
  git -C "$repo" checkout -q -b fork base
  cat > "$repo/bin/fork-caller.sh" <<'SH'
show=$(task_show "$id") || exit 1
out=$(pr_for_task "$id")
task_show_legacy "$id"
helper_kept
SH
  commit_all "$repo" fork
}

test_fork_caller_of_redefined_helper_is_reported() {
  local repo="$TMP_ROOT/history" out status
  make_history "$repo"
  out=$(cd "$repo" && "$SCAN" base upstream fork)
  status=$?
  expect_code 1 "$status" "a fork caller of a redefined helper must fail the scan: $out"
  assert_contains "$out" 'REDEFINED: task_show' 'the rewritten definition was not listed'
  # shellcheck disable=SC2016  # the reported fixture line, verbatim
  assert_contains "$out" 'CALLSITE: task_show bin/fork-caller.sh: show=$(task_show "$id") || exit 1' \
    'the fork-only caller was not reported with its path and line'
  assert_contains "$out" 'SUMMARY: 1 redefined helper(s), 1 fork-only call site(s)' 'wrong summary'
  assert_not_contains "$out" 'REDEFINED: pr_for_task' 'an unchanged definition was reported as redefined'
  assert_not_contains "$out" 'task_show_legacy' 'a longer name containing a redefined one was reported'
  assert_not_contains "$out" 'upstream-caller.sh' "upstream's own caller was reported as fork-only"
  pass 'fm-upstream-callsite-scan: a fork-only caller of a redefined helper is reported and fails the scan'
}

test_no_fork_caller_passes() {
  local repo="$TMP_ROOT/history" out status
  out=$(cd "$repo" && "$SCAN" base upstream base)
  status=$?
  expect_code 0 "$status" "a fork with no added callers must pass: $out"
  assert_contains "$out" 'REDEFINED: task_show' 'redefinitions must still be listed when nothing calls them'
  assert_contains "$out" 'SUMMARY: 1 redefined helper(s), 0 fork-only call site(s)' 'wrong clean summary'
  pass 'fm-upstream-callsite-scan: a fork with no affected callers passes while still listing redefinitions'
}

test_invalid_refs_refuse() {
  local repo="$TMP_ROOT/history" out status
  out=$(cd "$repo" && "$SCAN" base upstream no-such-ref 2>&1)
  status=$?
  expect_code 2 "$status" "an unknown ref must refuse: $out"
  assert_contains "$out" 'not a commit in this repository: no-such-ref' 'the refusal did not name the ref'
  out=$(cd "$repo" && "$SCAN" base upstream 2>&1)
  status=$?
  expect_code 2 "$status" "a missing argument must print usage: $out"
  pass 'fm-upstream-callsite-scan: unknown refs and missing arguments refuse without a verdict'
}

test_fork_caller_of_redefined_helper_is_reported
test_no_fork_caller_passes
test_invalid_refs_refuse
