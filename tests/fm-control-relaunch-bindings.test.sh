#!/usr/bin/env bash
# tests/fm-control-relaunch-bindings.test.sh - relaunch keeps a task's durable
# bindings intact (bin/fm-control.sh relaunch and bin/fm-spawn.sh --relaunch).
#
# A relaunch that rewrites task metadata keeps an armed merge poll bound, and a
# relaunch reuses its own worktree claim while refusing another task's claim on
# the same copy. The shared relaunch transaction cases live in
# tests/fm-control-relaunch.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch-bindings)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap relaunch_cleanup EXIT

# The lifecycle-modelling tmux stub from tests/fm-control-relaunch.test.sh,
# without its race and failure-injection hooks: the harness's exit command
# stops the agent, and a launch-brief literal starts the harness in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), and a relaunch reaches it through
  # fm-control.sh, so this runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

# fm-control.sh relaunch rewrites metadata with control_relaunch_tx= after the
# preserved pr= / pr_head= block. That used to fail the poll identity parse.
test_relaunch_does_not_disarm_an_armed_merge_poll() {
  local dir out rc url
  dir=$(new_case poll-identity rl-poll)
  add_ship_task "$dir" rl-poll claude
  url=https://github.com/o/r/pull/10
  {
    printf '%s\n' "pr=$url"
    printf '%s\n' 'pr_head=0123456789abcdef0123456789abcdef01234567'
  } >> "$dir/home/state/rl-poll.meta"
  fm_pr_poll_prepare "$dir/home/state" rl-poll github "$url" github.com o/r 10 \
    "$ROOT/bin/fm-pr-poll.sh" \
    || fail "could not prepare the armed poll before relaunch"
  fm_pr_poll_publish_prepared || fail "could not publish the armed poll before relaunch"
  fm_pr_poll_artifacts_valid "$dir/home/state" rl-poll "$ROOT/bin/fm-pr-poll.sh" \
    || fail "the armed poll was not valid before relaunch"
  out=$(run_control "$dir" rl-poll relaunch --note "keep the merge poll armed"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed with an armed merge poll"$'\n'"$out"
  [ -n "$(meta_field "$dir" rl-poll control_relaunch_tx)" ] \
    || fail "relaunch did not record control_relaunch_tx="
  fm_pr_poll_artifacts_valid "$dir/home/state" rl-poll "$ROOT/bin/fm-pr-poll.sh" \
    || fail "fm-control.sh relaunch disarmed the armed merge poll"
  pass "fm-control relaunch: an armed merge poll stays bound after control_relaunch_tx="
}

test_spawn_relaunch_refuses_another_tasks_worktree_claim() {
  local dir out rc
  dir=$(new_case shared-claim rl43)
  add_ship_task "$dir" rl43 claude
  printf 'zsh' > "$dir/fake/command"
  fm_write_meta "$dir/home/state/other-claim.meta" \
    "project=$dir/proj" "worktree=$dir/wt" "kind=ship"
  if out=$(run_spawn "$dir" rl43 --relaunch --harness claude); then rc=0; else rc=$?; fi
  expect_code 1 "$rc" "relaunch must refuse another task's claim"
  assert_contains "$out" other-claim "relaunch refusal must name the other claimant"
  assert_present "$dir/home/state/rl43.meta" "relaunch refusal lost its own record"
  assert_present "$dir/home/state/other-claim.meta" "relaunch refusal lost the competing record"
  assert_no_grep 'encode launch-brief' "$dir/fake/literal" "relaunch started a worker in a contested copy"
  pass "fm-spawn --relaunch: reuses its own claim but refuses a competing task's claim"
}

test_relaunch_does_not_disarm_an_armed_merge_poll
test_spawn_relaunch_refuses_another_tasks_worktree_claim
