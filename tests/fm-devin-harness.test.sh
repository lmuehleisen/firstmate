#!/usr/bin/env bash
# Behavior tests for the devin (Devin CLI) harness adapter: harness
# detection, ancestry anchoring, session-lock classification, approval-mode
# mapping and refusals, launch template shape, model and effort handling,
# lifecycle hooks generation, exclude registration, control mechanics,
# collision refusal, teardown and relaunch wiring, raw launch, dispatch
# validation, and composer classification.
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
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-devin-harness)

# --- detection & ancestry ---------------------------------------------------

test_devin_marker_requires_ancestry() {
  local out
  # FM_DEVIN_HARNESS=devin without a real devin process in ancestry must NOT
  # detect devin. It fails closed to prevent an inherited env var from hijacking
  # identity. That premise is false when the suite itself runs under devin, so
  # ask fm-harness.sh's public ancestry walk first and skip when it already
  # finds a devin ancestor above this test process.
  case $("$HARNESS" ancestry) in
    *" devin")
      printf 'skip - fm-harness.sh: devin marker case needs a non-devin ancestry, running under devin\n'
      return 0
      ;;
  esac
  out=$(env FM_DEVIN_HARNESS=devin "$HARNESS")
  [ "$out" != devin ] \
    || fail "FM_DEVIN_HARNESS=devin without devin ancestry must not detect devin"
  pass "fm-harness.sh: FM_DEVIN_HARNESS requires real devin ancestry"
}

test_devin_ancestry_detection_and_anchoring() {
  local dir="$TMP_ROOT/ancestry" out clean probe blind_fakebin blind_probe
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

  # Anchored match: devin-other or mydevin must NOT detect devin. Their probes
  # must see no devin ancestor at all, so the walk is cut only above this test
  # shell's own pid (fm_fake_blind_ancestry_above) - a real devin process above
  # the suite is exactly what they would otherwise detect. The decoy layer
  # below the cut is still examined under its real name, proven by the
  # exact-name probe under the same cut so the anchored asserts cannot pass
  # vacuously.
  blind_fakebin=$(fm_fakebin "$dir/blind-ancestry")
  fm_fake_blind_ancestry_above "$blind_fakebin" "$$"
  blind_probe="$clean PATH='$blind_fakebin:$PATH' $HARNESS"
  out=$("$dir/devin" "$blind_probe" | tr -d '\n')
  [ "$out" = devin ] \
    || fail "an exact devin ancestor must still detect under the ancestry cut, got '$out'"
  cc -o "$dir/devin-other" "$dir/run.c" 2>/dev/null \
    || fail "could not build the devin-other probe"
  out=$("$dir/devin-other" "$blind_probe" | tr -d '\n')
  [ "$out" != devin ] || fail "devin-other must not be detected as devin"

  cc -o "$dir/mydevin" "$dir/run.c" 2>/dev/null \
    || fail "could not build the mydevin probe"
  out=$("$dir/mydevin" "$blind_probe" | tr -d '\n')
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

  # Devin cannot own primary session lock: not in FM_HARNESS_RE or FM_HARNESS_NAMES
  ! printf '%s\n' "devin" | grep -qE "$FM_HARNESS_RE" \
    || fail "FM_HARNESS_RE must not match devin (cannot own primary session lock)"

  case " ${FM_HARNESS_NAMES[*]} " in
    *" devin "*) fail "FM_HARNESS_NAMES must not contain devin" ;;
    *) ;;
  esac

  # fm_harness_path_name does not recognize devin (excluded from primary session lock)
  ! fm_harness_path_name "/opt/homebrew/bin/devin" >/dev/null \
    || fail "fm_harness_path_name must not match devin (excluded from primary lock candidates)"

  pass "fm-agent-process-lib: devin process classification matches agent (excluded from primary session lock)"
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
  [ "$paths" = "$wt/.devin/config.local.json
$wt/.devin/rules/firstmate-attribution.md" ] || fail "devin wiring paths must cover config.local.json and the attribution rule, got '$paths'"

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
  local harness=${DEVIN_HARNESS_ARG:-devin}
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    PATH="${FM_TEST_PATH_OVERRIDE:-$fakebin:$PATH}" \
    "$SPAWN" "$id" "$proj" "$harness" "$@" 2>&1
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

test_devin_missing_binary_refuses() {
  local fields case_dir home proj wt fakebin id out
  fields=$(make_spawn_case missing-bin)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  rm -f "$fakebin/devin"
  ln -sf "$(command -v git)" "$fakebin/git"
  out=$(FM_TEST_PATH_OVERRIDE="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
    fail "devin spawn must refuse when binary is missing from PATH"
  case "$out" in
    *'devin executable not found on PATH'*) ;;
    *) fail "refusal must name devin not installed/executable, got: $out" ;;
  esac
  pass "fm-spawn.sh: missing devin binary refuses before spawn"
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

# --- hooks generation, validation & execution -------------------------------

test_devin_hooks_generation_validation_and_execution() {
  local fields case_dir home proj wt fakebin id hook_file exclude_file
  local out cmd_submit cmd_stop cmd_end
  fields=$(make_spawn_case hooks-exec)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  hook_file="$wt/.devin/config.local.json"
  [ -f "$hook_file" ] || fail "hooks file was not created at $hook_file"

  # Validate JSON syntax
  jq . "$hook_file" >/dev/null 2>&1 || fail "hooks file is not valid JSON: $(cat "$hook_file")"

  # Attribution pinned to false
  [ "$(jq -r '.attribution' "$hook_file")" = "false" ] || fail "attribution must be false"

  # Pre-allowed permissions: the captain-approved non-destructive Exec set
  # (D1 extended 2026-09-14), checked through the generated config.
  local entry
  for entry in \
    "Exec(git commit)" "Exec(git push)" "Exec(git checkout)" "Exec(git remote)" \
    "Exec(git fetch)" "Exec(git status)" "Exec(git log)" "Exec(git diff)" \
    "Exec(ls)" \
    "Exec(gh pr create)" "Exec(gh pr view)" "Exec(gh pr list)" "Exec(gh pr checks)" \
    "Exec(bin/fm-lint.sh)" "Exec(./bin/fm-lint.sh)" "Exec(bash bin/fm-lint.sh)" \
    "Exec(bin/fm-test-run.sh)" "Exec(./bin/fm-test-run.sh)" "Exec(bash bin/fm-test-run.sh)" \
    "Exec(bin/fm-install-shellcheck.sh)" "Exec(./bin/fm-install-shellcheck.sh)" "Exec(bash bin/fm-install-shellcheck.sh)" \
    "Exec(bin/fm-install-actionlint.sh)" "Exec(./bin/fm-install-actionlint.sh)" "Exec(bash bin/fm-install-actionlint.sh)"; do
    jq -e --arg e "$entry" '.permissions.allow | index($e)' "$hook_file" >/dev/null \
      || fail "permissions.allow must contain $entry"
  done

  # Force-push spellings are denied back out of the allowed Exec(git push)
  # prefix; rm, gh repo, and blanket bypass stay unallowed.
  for entry in \
    "Exec(git push --force)" "Exec(git push --force-with-lease)" \
    "Exec(git push --force-if-includes)" "Exec(git push -f)"; do
    jq -e --arg e "$entry" '.permissions.deny | index($e)' "$hook_file" >/dev/null \
      || fail "permissions.deny must contain $entry"
  done
  ! jq -e '.permissions.allow | map(select(test("Exec\\(rm[ )]|gh repo|git push.*force|Exec\\(git\\)|Exec\\(gh\\)|Exec\\(bash\\)|\\*"))) | length > 0' "$hook_file" >/dev/null \
    || fail "permissions.allow must not contain rm, gh repo, force-push, or blanket entries"

  # The no-attribution policy is also installed as an always-on project rule.
  local rule_file="$wt/.devin/rules/firstmate-attribution.md"
  [ -f "$rule_file" ] || fail "attribution rule was not created at $rule_file"
  grep -q 'trigger: always_on' "$rule_file" \
    || fail "attribution rule must be always_on, got: $(cat "$rule_file")"
  grep -q 'Co-Authored-By' "$rule_file" \
    || fail "attribution rule must forbid Co-Authored-By attribution"
  grep -q 'Generated with' "$rule_file" \
    || fail "attribution rule must forbid Generated with attribution"

  # Hooks events: UserPromptSubmit, Stop, SessionEnd present; SessionStart absent
  jq -e '.hooks.UserPromptSubmit and .hooks.Stop and .hooks.SessionEnd' "$hook_file" >/dev/null \
    || fail "hooks missing expected lifecycle events in .hooks"
  ! jq -e '.hooks.SessionStart' "$hook_file" >/dev/null \
    || fail "SessionStart hook must be absent to prevent false busy on resume"

  # Verify git exclude
  exclude_file=$(git -C "$wt" rev-parse --git-path info/exclude)
  grep -qxF '.devin/config.local.json' "$exclude_file" \
    || fail ".devin/config.local.json must be in git info/exclude"
  grep -qxF '.devin/rules/firstmate-attribution.md' "$exclude_file" \
    || fail ".devin/rules/firstmate-attribution.md must be in git info/exclude"

  # Verify busy generation was armed
  [ -f "$home/state/$id.busy-gen" ] || fail "busy generation was not armed: missing $id.busy-gen"
  [ -f "$home/state/$id.busy-state" ] || fail "busy state missing: $id.busy-state"

  # Initial classification after spawn seed is 'busy fm-spawn'
  out=$(fm_busy_classify tmux fake:w devin "$id" "$home/state")
  [ "$out" = "busy fm-spawn" ] || fail "initial state after spawn must be 'busy fm-spawn', got '$out'"

  # Extract hook commands
  cmd_submit=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$hook_file")
  cmd_stop=$(jq -r '.hooks.Stop[0].hooks[0].command' "$hook_file")
  cmd_end=$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$hook_file")

  # Execute UserPromptSubmit hook
  sh -c "$cmd_submit" || fail "UserPromptSubmit hook command failed: $cmd_submit"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$home/state")
  [ "$out" = "busy devin-hook" ] || fail "after UserPromptSubmit state must be 'busy devin-hook', got '$out'"

  # Execute Stop hook: touches turn-ended and transitions to idle
  rm -f "$home/state/$id.turn-ended"
  sh -c "$cmd_stop" || fail "Stop hook command failed: $cmd_stop"
  [ -f "$home/state/$id.turn-ended" ] || fail "Stop hook did not touch turn-ended file"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$home/state")
  [ "$out" = "idle devin-hook" ] || fail "after Stop state must be 'idle devin-hook', got '$out'"

  # Execute SessionEnd hook: closes turn (idle)
  sh -c "$cmd_end" || fail "SessionEnd hook command failed: $cmd_end"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$home/state")
  [ "$out" = "idle devin-hook" ] || fail "after SessionEnd state must be 'idle devin-hook', got '$out'"

  pass "fm-spawn.sh: devin hooks generated, verified, and executed with correct busy transitions"
}

# --- collision refusal ------------------------------------------------------

test_devin_collision_refusal() {
  local fields case_dir home proj wt fakebin id out exclude_file
  fields=$(make_spawn_case collision-untracked)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"

  # Case 1: .devin/config.local.json already exists untracked (excluded so pool refresh is clean)
  mkdir -p "$wt/.devin"
  echo '{"existing":true}' > "$wt/.devin/config.local.json"
  exclude_file=$(git -C "$wt" rev-parse --git-path info/exclude)
  echo '.devin/config.local.json' >> "$exclude_file"
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
    fail "spawn must refuse when .devin/config.local.json already exists"
  case "$out" in
    *'.devin/config.local.json already exists or is tracked'*) ;;
    *) fail "refusal must mention .devin/config.local.json, got: $out" ;;
  esac

  # Case 2: .devin/config.local.json is tracked on the project's default branch.
  # Spawn refreshes the leased worktree to origin's tip, so the file must be on
  # origin/main rather than only on the pre-created worktree branch.
  fields=$(make_spawn_case collision-tracked)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  mkdir -p "$proj/.devin"
  echo '{"tracked":true}' > "$proj/.devin/config.local.json"
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' add .devin/config.local.json
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "Track devin config"
  git -C "$proj" push origin main >/dev/null 2>&1
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
    fail "spawn must refuse when .devin/config.local.json is tracked"
  case "$out" in
    *'.devin/config.local.json already exists or is tracked'*) ;;
    *) fail "refusal must mention tracked .devin/config.local.json, got: $out" ;;
  esac

  # Case 3: .devin/rules/firstmate-attribution.md already exists (excluded so the
  # pooled worktree refreshes clean, same as case 1).
  fields=$(make_spawn_case collision-rule)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  mkdir -p "$wt/.devin/rules"
  echo 'existing rule' > "$wt/.devin/rules/firstmate-attribution.md"
  exclude_file=$(git -C "$wt" rev-parse --git-path info/exclude)
  echo '.devin/rules/firstmate-attribution.md' >> "$exclude_file"
  out=$(run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
    fail "spawn must refuse when .devin/rules/firstmate-attribution.md already exists"
  case "$out" in
    *'firstmate-attribution.md already exists or is tracked'*) ;;
    *) fail "refusal must mention the attribution rule path, got: $out" ;;
  esac

  pass "fm-spawn.sh: devin spawn refuses when .devin/config.local.json exists or is tracked"
}

# --- teardown & relaunch wiring ---------------------------------------------

test_devin_teardown_and_relaunch() {
  local fields case_dir home proj wt fakebin id dirty
  fields=$(make_spawn_case teardown-relaunch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  [ -f "$wt/.devin/config.local.json" ] || fail "expected .devin/config.local.json to exist"
  [ -f "$wt/.devin/rules/firstmate-attribution.md" ] || fail "expected .devin/rules/firstmate-attribution.md to exist"

  # Test that fm_control_harness_wiring_paths covers .devin/config.local.json and the
  # attribution rule so relaunch clears them
  local p
  for p in $(fm_control_harness_wiring_paths devin "$wt" "$home/state" "$id"); do
    [ -n "$p" ] && rm -f -- "$p"
  done
  [ ! -f "$wt/.devin/config.local.json" ] || fail "fm_control_harness_wiring_paths must cover .devin/config.local.json"
  [ ! -f "$wt/.devin/rules/firstmate-attribution.md" ] || fail "fm_control_harness_wiring_paths must cover .devin/rules/firstmate-attribution.md"

  # Teardown safety: ensure teardown uncommitted changes check does NOT ignore untracked .devin/ content
  # Create an actual untracked file in .devin/
  mkdir -p "$wt/.devin/skills/foo"
  touch "$wt/.devin/skills/foo/SKILL.md"
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -1 || true)
  [ -n "$dirty" ] || fail "teardown dirty check must NOT ignore untracked .devin/ files (hard rule 3)"
  case "$dirty" in
    *'.devin/'*) ;;
    *) fail "dirty must detect untracked .devin/ content, got: $dirty" ;;
  esac

  pass "fm-teardown / fm-control: relaunch wiring cleared and teardown protects unlanded .devin content"
}

# --- raw launch -------------------------------------------------------------

test_devin_raw_launch() {
  local fields case_dir home proj wt fakebin id
  fields=$(make_spawn_case raw)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  DEVIN_HARNESS_ARG="devin --raw-escape" run_devin_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  [ ! -f "$wt/.devin/config.local.json" ] || fail "raw launch must not generate .devin/config.local.json"
  [ ! -f "$wt/.devin/rules/firstmate-attribution.md" ] || fail "raw launch must not generate the attribution rule"
  [ ! -f "$home/state/$id.busy-gen" ] || fail "raw launch must not arm busy generation"
  pass "fm-spawn.sh: raw launch skips devin hook wiring and busy generation"
}

# --- bootstrap dispatch validation ------------------------------------------

test_devin_bootstrap_dispatch_validation() {
  local dir="$TMP_ROOT/bootstrap-dispatch" config_dir="$TMP_ROOT/bootstrap-dispatch/config" out
  mkdir -p "$config_dir"
  eval "$(sed -n '/^crew_dispatch_validate() {/,/^}/p' "$ROOT/bin/fm-bootstrap.sh")"

  cat > "$config_dir/crew-dispatch.json" <<'EOF'
{"default":{"harness":"devin","model":"claude-sonnet-4"}}
EOF
  out=$(CONFIG="$config_dir" crew_dispatch_validate 2>&1)
  [ -z "$out" ] || fail "crew_dispatch_validate must accept devin harness, got: $out"

  cat > "$config_dir/crew-dispatch.json" <<'EOF'
{"default":{"harness":"gemini","model":"gemini-2.5-flash"}}
EOF
  out=$(CONFIG="$config_dir" crew_dispatch_validate 2>&1)
  [ -z "$out" ] || fail "crew_dispatch_validate must accept gemini harness, got: $out"

  cat > "$config_dir/crew-dispatch.json" <<'EOF'
{"default":{"harness":"bogus_harness","model":"some-model"}}
EOF
  out=$(CONFIG="$config_dir" crew_dispatch_validate 2>&1)
  case "$out" in
    *'unverified harness: bogus_harness'*) ;;
    *) fail "crew_dispatch_validate must reject bogus_harness, got: $out" ;;
  esac

  cat > "$config_dir/crew-dispatch.json" <<'EOF'
{"default":{"harness":"devin","effort":"high"}}
EOF
  out=$(CONFIG="$config_dir" crew_dispatch_validate 2>&1)
  case "$out" in
    *'invalid effort: devin:high'*) ;;
    *) fail "crew_dispatch_validate must reject effort for devin, got: $out" ;;
  esac

  pass "fm-bootstrap.sh: crew_dispatch_validate accepts devin and gemini, rejects unverified harnesses and unsupported effort"
}

# --- composer classification ------------------------------------------------

test_devin_composer_classification() {
  local top='──── (smart mode on) ─' rule='────────────────────'
  local footer='SWE-2 Max        Context: 13k / 262k tokens (5%)'
  local screen out

  # 1. Idle composer: placeholder rendered dim under styled capture
  screen=$(printf '%s\n❭ \033[2mAsk Devin to build features, fix bugs, or work on your code\033[0m\n%s\n%s\n' "$top" "$rule" "$footer")
  out=$(fm_composer_classify_screen 'styled=1' "$screen")
  [ "$out" = empty ] || fail "styled idle devin composer must classify empty, got '$out'"

  # 1b. Idle composer without styling (styled=0)
  screen=$(printf '%s\n❭ Ask Devin to build features, fix bugs, or work on your code\n%s\n%s\n' "$top" "$rule" "$footer")
  out=$(fm_composer_classify_screen 'styled=0' "$screen")
  [ "$out" = empty ] || fail "unstyled idle devin composer must classify empty, got '$out'"

  # 2. Busy placeholder Guide Devin while it works
  screen=$(printf '%s\n❭ \033[2mGuide Devin while it works\033[0m\n%s\n%s\n' "$top" "$rule" "$footer")
  out=$(fm_composer_classify_screen 'styled=1' "$screen")
  [ "$out" = empty ] || fail "styled busy-placeholder devin composer must classify empty, got '$out'"

  # 3. Pending typed input
  screen=$(printf '%s\n❭ fix the tests\n%s\n%s\n' "$top" "$rule" "$footer")
  out=$(fm_composer_classify_screen 'styled=1' "$screen")
  [ "$out" = pending ] || fail "devin composer with typed input must classify pending, got '$out'"

  # 4. Extract selected content
  out=$(fm_composer_extract_selected_content 'styled=1' "$screen")
  [ "$out" = "fix the tests" ] || fail "fm_composer_extract_selected_content must extract 'fix the tests', got '$out'"

  # 5. Cursor on footer or top rule reads unknown
  out=$(fm_composer_classify_screen $'styled=1\ncursor=1' "$screen" 0)
  [ "$out" = unknown ] || fail "cursor on top rule must classify unknown, got '$out'"
  out=$(fm_composer_classify_screen $'styled=1\ncursor=1' "$screen" 3)
  [ "$out" = unknown ] || fail "cursor on footer must classify unknown, got '$out'"

  # 6. Cursor inside content row reads pending
  out=$(fm_composer_classify_screen $'styled=1\ncursor=1' "$screen" 1)
  [ "$out" = pending ] || fail "cursor on content row must classify pending, got '$out'"

  # 7. Delivery busy regex matches (esc twice to interrupt) and (esc again to interrupt)
  printf '%s\n' "Thinking · 1s (esc twice to interrupt)" | fm_busy_lines_match devin \
    || fail "fm_busy_lines_match devin must match '(esc twice to interrupt)'"
  printf '%s\n' "Thinking · 2s (esc again to interrupt)" | fm_busy_lines_match devin \
    || fail "fm_busy_lines_match devin must match '(esc again to interrupt)'"
  ! printf '%s\n' "Thinking · 2s" | fm_busy_lines_match devin \
    || fail "fm_busy_lines_match devin must not match generic thinking line without esc token"

  pass "fm-composer-lib: devin composer shapes classify empty, pending, and unknown correctly"
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
test_devin_missing_binary_refuses
test_devin_launch_shape_and_model_handling
test_devin_secondmate_refusal
test_devin_hooks_generation_validation_and_execution
test_devin_collision_refusal
test_devin_teardown_and_relaunch
test_devin_raw_launch
test_devin_bootstrap_dispatch_validation
test_devin_composer_classification
