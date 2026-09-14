#!/usr/bin/env bash
# Behavior tests for the devin (Devin CLI) harness adapter: harness
# detection, ancestry anchoring, session-lock classification, approval-mode
# mapping and refusals, launch template shape, model and effort handling,
# lifecycle hooks generation, exclude registration, and control mechanics.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Drop foreign markers that could mask the signals under test.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT \
  CURSOR_INVOKED_AS GEMINI_CLI JETSKI_APP_DATA_DIR ATLASSIAN_AGENT_TYPE \
  FM_DEVIN_HARNESS FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-devin-harness)

# --- detection & ancestry ---------------------------------------------------

test_devin_marker_requires_ancestry() {
  local out
  # FM_DEVIN_HARNESS=devin without a real devin process in ancestry must NOT
  # detect devin. It fails closed to prevent an inherited env var from hijacking
  # identity.
  out=$(env FM_DEVIN_HARNESS=devin "$HARNESS")
  [ "$out" != devin ] \
    || fail "FM_DEVIN_HARNESS=devin without devin ancestry must not detect devin"
  pass "fm-harness.sh: FM_DEVIN_HARNESS requires real devin ancestry"
}

test_devin_ancestry_detection_and_anchoring() {
  local dir="$TMP_ROOT/ancestry" out clean probe
  mkdir -p "$dir"
  command -v cc >/dev/null 2>&1 || {
    printf 'skip - fm-harness.sh: devin ancestry needs cc to build a named process\n'
    return 0
  }
  cat > "$dir/run.c" <<'C'
#include <stdlib.h>
int main(int argc, char **argv) { if (argc < 2) return 1; return system(argv[1]) == 0 ? 0 : 1; }
C
  clean="env -u JETSKI_APP_DATA_DIR -u CLAUDECODE -u CURSOR_AGENT"
  clean="$clean -u CURSOR_INVOKED_AS -u GEMINI_CLI -u PI_CODING_AGENT"
  clean="$clean -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE"
  probe="$clean $HARNESS"

  cc -o "$dir/devin" "$dir/run.c" 2>/dev/null \
    || fail "could not build the devin ancestry probe"
  # Exact devin ancestor alone detects devin via comm match.
  out=$("$dir/devin" "$probe" | tr -d '\n')
  [ "$out" = devin ] || fail "an exact devin ancestor must detect devin, got '$out'"

  # FM_DEVIN_HARNESS=devin with exact devin ancestor also detects devin.
  out=$("$dir/devin" "env FM_DEVIN_HARNESS=devin $probe" | tr -d '\n')
  [ "$out" = devin ] || fail "FM_DEVIN_HARNESS + devin ancestor must detect devin, got '$out'"

  # Anchored match: devin-other or mydevin must NOT detect devin.
  cc -o "$dir/devin-other" "$dir/run.c" 2>/dev/null \
    || fail "could not build the devin-other probe"
  out=$("$dir/devin-other" "$probe" | tr -d '\n')
  [ "$out" != devin ] || fail "devin-other must not be detected as devin"

  cc -o "$dir/mydevin" "$dir/run.c" 2>/dev/null \
    || fail "could not build the mydevin probe"
  out=$("$dir/mydevin" "$probe" | tr -d '\n')
  [ "$out" != devin ] || fail "mydevin must not be detected as devin"

  pass "fm-harness.sh: devin ancestry detects devin and is strictly anchored"
}

# --- session lock & process classification ----------------------------------

test_devin_agent_process_classification() {
  local res
  res=$(fm_agent_process_classify_name "devin")
  [ "$res" = agent ] || fail "devin command must classify as agent, got '$res'"

  res=$(fm_agent_process_classify_name "/opt/homebrew/bin/devin")
  [ "$res" = agent ] || fail "/opt/homebrew/bin/devin must classify as agent, got '$res'"

  res=$(fm_agent_process_classify_name "devin-worker")
  [ "$res" != agent ] || fail "devin-worker must not classify as agent"

  # FM_HARNESS_RE matches devin
  printf '%s\n' "devin" | grep -qE "$FM_HARNESS_RE" \
    || fail "FM_HARNESS_RE must match devin"

  # FM_HARNESS_NAMES contains devin
  case " ${FM_HARNESS_NAMES[*]} " in
    *" devin "*) ;;
    *) fail "FM_HARNESS_NAMES must contain devin" ;;
  esac

  # fm_harness_path_name recognizes devin in path
  res=$(fm_harness_path_name "/opt/homebrew/bin/devin") || fail "fm_harness_path_name must match /opt/homebrew/bin/devin"
  [ "$res" = devin ] || fail "fm_harness_path_name must return devin, got '$res'"

  pass "fm-agent-process-lib: devin process and path classification match agent"
}

# --- control mechanics ------------------------------------------------------

test_devin_control_contract() {
  local id="devin-test-ctrl" wt="/tmp/fake-wt" state="/tmp/fake-state" paths

  fm_control_harness_supported devin || fail "devin must be a supported control harness"
  [ "$(fm_control_harness_family devin)" = devin ] || fail "devin family must be devin"

  fm_control_harness_supports_kind devin crew || fail "devin must support crew"
  fm_control_harness_supports_kind devin scout || fail "devin must support scout"
  ! fm_control_harness_supports_kind devin secondmate || fail "devin must refuse secondmate"

  [ "$(fm_control_interrupt_key devin)" = Escape ] || fail "devin interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat devin)" = 2 ] || fail "devin interrupt repeat must be 2"
  [ -z "$(fm_control_interrupt_clear_key devin)" ] || fail "devin interrupt clear key must be empty"
  [ "$(fm_control_interrupt_ack_source devin)" = none ] || fail "devin interrupt ack source must be none"
  [ "$(fm_control_exit_command devin)" = '/exit' ] || fail "devin exit command must be /exit"

  paths=$(fm_control_harness_wiring_paths devin "$wt" "$state" "$id")
  [ "$paths" = "$wt/.devin/hooks.v1.json" ] || fail "devin wiring path must be hooks.v1.json, got '$paths'"

  pass "fm-control-lib: devin control mechanics match specification"
}

# --- spawn scaffolding ------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" devin gh-axi gh
  fm_fake_treehouse_lease "$fakebin"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="devin-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise devin dispatch.

## Firstmate spec
Verify the devin harness behavior under test.
EOF
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_devin_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" devin "$@" 2>&1
}

# --- permissions & launch template ------------------------------------------

test_devin_auto_uses_smart_and_never_bypass() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case auto)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'auto\n' > "$home/config/crew-permissions"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--permission-mode smart'*) ;;
    *) fail "auto must launch devin with --permission-mode smart, got: $launch" ;;
  esac
  case "$launch" in
    *dangerous*|*bypass*|*autonomous*|*--yolo*)
      fail "auto must never reach blanket approval bypass: $launch" ;;
  esac
  pass "fm-spawn.sh: devin auto selects --permission-mode smart, never bypass"
}

test_devin_manual_uses_normal_and_never_bypass() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case manual)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'manual\n' > "$home/config/crew-permissions"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--permission-mode normal'*) ;;
    *) fail "manual must launch devin with --permission-mode normal, got: $launch" ;;
  esac
  case "$launch" in
    *dangerous*|*bypass*|*autonomous*|*--yolo*)
      fail "manual must never reach blanket approval bypass: $launch" ;;
  esac
  pass "fm-spawn.sh: devin manual selects --permission-mode normal"
}

test_devin_absent_setting_defaults_to_smart() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case absent)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--permission-mode smart'*) ;;
    *) fail "absent crew-permissions must default to --permission-mode smart, got: $launch" ;;
  esac
  pass "fm-spawn.sh: absent crew-permissions defaults devin to --permission-mode smart"
}

test_devin_invalid_setting_refuses() {
  local fields case_dir home proj wt fakebin id out
  fields=$(make_spawn_case invalid)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'yolo\n' > "$home/config/crew-permissions"
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
    fail "an invalid permission setting must refuse the devin launch"
  case "$out" in
    *'invalid config/crew-permissions'*) ;;
    *) fail "refusal must name config/crew-permissions, got: $out" ;;
  esac
  [ ! -s "$home/launch.log" ] || fail "refused launch must not reach pane"
  pass "fm-spawn.sh: invalid crew-permissions refuses devin launch"
}

test_devin_launch_shape_and_model_handling() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case shape)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --model "custom-model" --effort high >/dev/null
  launch=$(cat "$home/launch.log")

  # Launch marker and workspace trust
  case "$launch" in
    *'FM_DEVIN_HARNESS=devin'*) ;;
    *) fail "launch must set FM_DEVIN_HARNESS=devin, got: $launch" ;;
  esac
  case "$launch" in
    *'--respect-workspace-trust false'*) ;;
    *) fail "launch must pass --respect-workspace-trust false, got: $launch" ;;
  esac

  # Model is passed
  case "$launch" in
    *'--model '*'custom-model'*) ;;
    *) fail "launch must pass --model custom-model, got: $launch" ;;
  esac

  # Effort is omitted from launch command (record-and-omit)
  case "$launch" in
    *--effort*|*--thinking*|*--reasoning-effort*)
      fail "devin has no CLI effort flag; effort must be omitted from launch command: $launch" ;;
  esac

  # Positional launch brief
  case "$launch" in
    *'-- '*brief*) ;;
    *) fail "launch must include positional brief separator: $launch" ;;
  esac

  pass "fm-spawn.sh: devin launch shape, model flag, and effort omission verified"
}

test_devin_secondmate_refusal() {
  local fields case_dir home proj wt fakebin id out
  fields=$(make_spawn_case sm-refuse)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --secondmate) && \
    fail "devin must refuse secondmate launch"
  case "$out" in
    *'devin is a verified crewmate/scout adapter only and cannot run a secondmate'*) ;;
    *) fail "secondmate refusal must name devin and primary supervision protocol, got: $out" ;;
  esac
  pass "fm-spawn.sh: secondmate launch is refused on devin"
}

# --- hooks generation & git exclude -----------------------------------------

test_devin_hooks_generation_and_exclude() {
  local fields case_dir home proj wt fakebin id hook_file exclude_file
  fields=$(make_spawn_case hooks)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  hook_file="$wt/.devin/hooks.v1.json"
  [ -f "$hook_file" ] || fail "hooks file was not created at $hook_file"

  # Validate JSON syntax with jq
  jq . "$hook_file" >/dev/null 2>&1 || fail "hooks file is not valid JSON: $(cat "$hook_file")"

  # Check top-level events
  jq -e '.SessionStart and .UserPromptSubmit and .Stop and .SessionEnd' "$hook_file" >/dev/null \
    || fail "hooks file missing expected lifecycle event keys"

  # Check commands inside hooks
  local cmd_start cmd_submit cmd_stop cmd_end
  cmd_start=$(jq -r '.SessionStart[0].hooks[0].command' "$hook_file")
  cmd_submit=$(jq -r '.UserPromptSubmit[0].hooks[0].command' "$hook_file")
  cmd_stop=$(jq -r '.Stop[0].hooks[0].command' "$hook_file")
  cmd_end=$(jq -r '.SessionEnd[0].hooks[0].command' "$hook_file")

  case "$cmd_start" in
    *'fm-busy-event.sh'*' busy '*devin-hook*'--event session-start'*) ;;
    *) fail "SessionStart command unexpected: $cmd_start" ;;
  esac

  case "$cmd_submit" in
    *'fm-busy-event.sh'*' busy '*devin-hook*'--event user-prompt-submit'*) ;;
    *) fail "UserPromptSubmit command unexpected: $cmd_submit" ;;
  esac

  case "$cmd_stop" in
    *'touch '*"$id.turn-ended"*'fm-busy-event.sh'*' idle '*devin-hook*'--event stop'*) ;;
    *) fail "Stop command unexpected: $cmd_stop" ;;
  esac

  case "$cmd_end" in
    *'fm-busy-event.sh'*' idle '*devin-hook*'--event session-end'*) ;;
    *) fail "SessionEnd command unexpected: $cmd_end" ;;
  esac

  # Verify git exclude
  exclude_file=$(git -C "$wt" rev-parse --git-path info/exclude)
  grep -qxF '.devin/hooks.v1.json' "$exclude_file" \
    || fail ".devin/hooks.v1.json must be in git info/exclude"

  pass "fm-spawn.sh: devin hooks generated with valid JSON and excluded from git"
}

# --- run all tests ----------------------------------------------------------

test_devin_marker_requires_ancestry
test_devin_ancestry_detection_and_anchoring
test_devin_agent_process_classification
test_devin_control_contract
test_devin_auto_uses_smart_and_never_bypass
test_devin_manual_uses_normal_and_never_bypass
test_devin_absent_setting_defaults_to_smart
test_devin_invalid_setting_refuses
test_devin_launch_shape_and_model_handling
test_devin_secondmate_refusal
test_devin_hooks_generation_and_exclude
