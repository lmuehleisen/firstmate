#!/usr/bin/env bash
# Behavior tests for the agy (Antigravity CLI) harness adapter: harness
# detection, the approval-mode mapping and its refusals, the mandatory
# worktree grant, the effort ceiling and the model-id/--effort conflict, the
# secondmate launch, native hook transports, and the control mechanics.
#
# The facts pinned here are the ones an Antigravity release could silently
# change and the ones a wrong guess would make dangerous:
#   1. --dangerously-skip-permissions must be unreachable from every
#      config/crew-permissions value. It is agy's only blanket approval switch,
#      the captain's standing preference forbids routing routine work through
#      it, and it would be the tempting "fix" the first time an agy worker
#      parks on an approval prompt.
#   2. --add-dir for the task worktree is load-bearing, not cosmetic. Verified
#      on agy 1.2.0: with the pane cwd already inside the worktree but no
#      --add-dir, a file write landed in agy's own scratch directory while the
#      model reported success. A launch missing it changes nothing in the task's
#      local copy and still looks healthy.
#   3. agy publishes reasoning effort TWICE - as a suffix inside model ids and
#      as --effort - and passing both is a launch-refusing conflict, so the
#      adapter must emit at most one of them.
#   4. Worker hooks bind generation and conversation before closing busy;
#      primary hooks compose the shared guard without bypassing review.
#
# Detection and launch shape are harness-dependent facts, so this portable
# suite pins the classifier and the rendered command with real processes and no
# agy installed, while tests/fm-agy-signals-live-e2e.test.sh proves the same
# facts against the real binary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry, so an
# inherited marker from whichever harness launched this suite would outrank the
# agy signals these cases assert. Drop the ambient markers first.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT \
  CURSOR_INVOKED_AS GEMINI_CLI JETSKI_APP_DATA_DIR ATLASSIAN_AGENT_TYPE

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

# --- detection --------------------------------------------------------------

test_agy_marker_outranks_inherited_claudecode() {
  local out
  # agy was not verified to scrub an inherited CLAUDECODE, so the adapter is
  # ordered before it. Pin that order rather than the hope that agy clears it.
  out=$(CLAUDECODE=1 JETSKI_APP_DATA_DIR=antigravity-cli "$HARNESS")
  [ "$out" = agy ] || fail "CLAUDECODE + agy marker must detect agy, got '$out'"
  # Drive the signals apart so the case above cannot go quietly vacuous: each
  # marker alone must still produce its own verdict.
  out=$(env -u CLAUDECODE JETSKI_APP_DATA_DIR=antigravity-cli "$HARNESS")
  [ "$out" = agy ] || fail "the agy marker alone must detect agy, got '$out'"
  out=$(env -u JETSKI_APP_DATA_DIR CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE alone must still detect claude, got '$out'"
  # Cursor's marker still outranks agy's, preserving the documented order.
  out=$(CURSOR_AGENT=1 JETSKI_APP_DATA_DIR=antigravity-cli "$HARNESS")
  [ "$out" = cursor ] || fail "CURSOR_AGENT must still outrank the agy marker, got '$out'"
  pass "fm-harness.sh: agy's marker outranks an inherited CLAUDECODE"
}

test_agy_marker_is_the_cli_not_the_ide() {
  local out
  # The Antigravity IDE keeps its state under ~/.gemini/antigravity, so its app
  # data dir is `antigravity`. Only the CLI's exact value is agy.
  out=$(JETSKI_APP_DATA_DIR=antigravity "$HARNESS")
  [ "$out" != agy ] \
    || fail "the IDE's app data dir must not be read as the agy CLI, got '$out'"
  out=$(JETSKI_APP_DATA_DIR=antigravity-cli-other "$HARNESS")
  [ "$out" != agy ] \
    || fail "a non-exact app data dir must not claim agy, got '$out'"
  pass "fm-harness.sh: only the CLI's exact app data dir claims agy"
}

test_agy_does_not_claim_the_gemini_identity() {
  local out
  # agy shares the ~/.gemini config root with Google's separate gemini adapter
  # but does NOT set GEMINI_CLI (verified in an agy tool process environment).
  # A GEMINI_CLI session must stay gemini, and an agy session must not be
  # reported as gemini.
  out=$(GEMINI_CLI=1 "$HARNESS")
  [ "$out" = gemini ] || fail "GEMINI_CLI must still detect gemini, got '$out'"
  out=$(JETSKI_APP_DATA_DIR=antigravity-cli "$HARNESS")
  [ "$out" = agy ] || fail "an agy session must not be read as gemini, got '$out'"
  pass "fm-harness.sh: agy and the Gemini CLI keep separate identities"
}

test_agy_ancestry_matches_only_the_exact_command_name() {
  local dir="$TMP_ROOT/ancestry" out clean probe
  mkdir -p "$dir"
  # The verdict has to come from a live process tree rather than a string this
  # test also wrote, so each case runs a real executable under the name being
  # checked. It must be a locally BUILT executable: copying a system binary
  # under a new name is SIGKILLed by macOS code signing (exit 137), and a
  # symlink does not work either because `ps -o comm=` resolves it back to the
  # real binary's name. A tiny C launcher that runs the probe as a CHILD keeps
  # the tested name in the ancestry the walk reads.
  command -v cc >/dev/null 2>&1 || {
    printf 'skip - fm-harness.sh: agy ancestry needs cc to build a named process\n'
    return 0
  }
  cat > "$dir/run.c" <<'C'
#include <stdlib.h>
int main(int argc, char **argv) { if (argc < 2) return 1; return system(argv[1]) == 0 ? 0 : 1; }
C
  # The marker layer outranks ancestry, so every foreign marker is dropped -
  # otherwise these cases would assert a marker's verdict, not the ancestry
  # match they exist to pin.
  clean="env -u JETSKI_APP_DATA_DIR -u CLAUDECODE -u CURSOR_AGENT"
  clean="$clean -u CURSOR_INVOKED_AS -u GEMINI_CLI -u PI_CODING_AGENT"
  clean="$clean -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE"
  probe="$clean $HARNESS"

  cc -o "$dir/agy" "$dir/run.c" 2>/dev/null \
    || fail "could not build the agy ancestry probe"
  out=$("$dir/agy" "$probe" | tr -d '\n')
  [ "$out" = agy ] || fail "an exact agy ancestor must detect agy, got '$out'"

  # Anchored, never *agy*: both of these would match a careless glob. They must
  # not merely fail to say agy - they must fall THROUGH to whatever really
  # launched this suite, which is what proves the arm did not fire.
  cc -o "$dir/legacy" "$dir/run.c" 2>/dev/null \
    || fail "could not build the legacy ancestry probe"
  out=$("$dir/legacy" "$probe" | tr -d '\n')
  [ "$out" != agy ] || fail "a 'legacy' command must not be misread as agy"
  cc -o "$dir/agyrate" "$dir/run.c" 2>/dev/null \
    || fail "could not build the agyrate ancestry probe"
  out=$("$dir/agyrate" "$probe" | tr -d '\n')
  [ "$out" != agy ] || fail "an 'agyrate' command must not be misread as agy"
  pass "fm-harness.sh: agy ancestry is anchored to the exact command name"
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
  has-session|new-session|new-window) exit 0 ;;
  kill-window)
    printf 'kill-window %s\n' "$*" >> "$FM_FAKE_LAUNCH_LOG.kills"
    exit 0
    ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        case "$arg" in
          *.agy-hooks*)
            printf '%s\n' "$arg" | grep -o "[^' ]*\.agy-hooks" | head -n 1 \
              > "$FM_FAKE_LAUNCH_LOG.agy-hooks"
            ;;
        esac
        exit 0
      fi
      prev=$arg
    done
    # Stand-in for agy starting its brief: the Enter that submits the launch
    # line runs the installed worker PreInvocation hook with the payload agy
    # sends, unless the case models a launch that never reaches the model.
    if [ "${*: -1}" = Enter ] && [ "${FM_FAKE_AGY_START:-1}" = 1 ] \
       && [ -s "$FM_FAKE_LAUNCH_LOG.agy-hooks" ]; then
      hooks="$(cat "$FM_FAKE_LAUNCH_LOG.agy-hooks")/.agents/hooks.json"
      cmd=$(jq -r '."firstmate-worker".PreInvocation[0].command' "$hooks" 2>/dev/null) || exit 0
      wt=$(cd "$FM_FAKE_PANE_PATH" 2>/dev/null && pwd -P) || exit 0
      jq -n --arg wt "$wt" '{conversationId:"fake-conversation",workspacePaths:[$wt]}' \
        | bash -c "$cmd"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # A stand-in `agy` on PATH: the spawn resolves the executable to an absolute
  # path before launching, and refuses when none exists, so the resolver needs
  # something executable to find. It is never run by these cases.
  fm_fake_exit0 "$fakebin" agy gh-axi gh
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
  id="agy-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise agy dispatch.

## Firstmate spec
Verify the agy harness behavior under test.
EOF
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_agy_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" agy "$@" 2>&1
}

# --- approvals --------------------------------------------------------------

test_agy_auto_uses_accept_edits_and_never_bypass() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case auto)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'auto\n' > "$home/config/crew-permissions"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--mode accept-edits'*) ;;
    *) fail "auto must launch agy with --mode accept-edits, got: $launch" ;;
  esac
  case "$launch" in
    *--dangerously-skip-permissions*)
      fail "auto must never reach agy's blanket approval bypass: $launch" ;;
  esac
  pass "fm-spawn.sh: agy auto selects accept-edits, never the approval bypass"
}

test_agy_manual_reviews_everything_and_never_bypass() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case manual)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'manual\n' > "$home/config/crew-permissions"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *--mode*) fail "manual must leave agy in its default review mode: $launch" ;;
  esac
  case "$launch" in
    *--dangerously-skip-permissions*)
      fail "manual must never reach agy's blanket approval bypass: $launch" ;;
  esac
  pass "fm-spawn.sh: agy manual keeps every action under review"
}

test_agy_absent_setting_defaults_to_accept_edits() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case absent)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  # No config/crew-permissions at all: the documented default is auto, matching
  # claude and codex, so the file's absence must not silently disable approvals
  # OR silently reach the bypass.
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--mode accept-edits'*) ;;
    *) fail "an absent setting must default to accept-edits, got: $launch" ;;
  esac
  case "$launch" in
    *--dangerously-skip-permissions*)
      fail "an absent setting must never reach the approval bypass: $launch" ;;
  esac
  pass "fm-spawn.sh: an absent permission setting defaults agy to accept-edits"
}

test_agy_invalid_setting_refuses_without_bypass() {
  local fields case_dir home proj wt fakebin id out setting
  # Every non-{auto,manual} shape must refuse: an unknown word, and an empty
  # file, which is the one a truncated write leaves behind.
  for setting in wide-open ''; do
    fields=$(make_spawn_case "invalid-${setting:-empty}")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
    : "$case_dir"
    printf '%s' "$setting" > "$home/config/crew-permissions"
    out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
      fail "an invalid permission setting ('$setting') must refuse the agy launch"
    case "$out" in
      *'invalid config/crew-permissions'*) ;;
      *) fail "the refusal must name config/crew-permissions, got: $out" ;;
    esac
    [ ! -s "$home/launch.log" ] \
      || fail "a refused agy launch must not reach the pane: $(cat "$home/launch.log")"
  done
  pass "fm-spawn.sh: an invalid permission setting refuses the agy launch"
}

# --- the mandatory worktree grant -------------------------------------------

test_agy_launch_grants_the_task_worktree() {
  local fields case_dir home proj wt fakebin id launch wt_real state_real brief_real
  fields=$(make_spawn_case adddir)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  # Without the worktree grant agy writes into its own scratch directory and
  # reports success, so its absence is a silent no-op rather than a visible
  # failure. fm_test_tmproot already hands back a resolved path, so the three
  # assertions here would pass with or without resolution: the resolution rule
  # itself is pinned by the symlink case below, which is where a real
  # divergence is constructed.
  wt_real=$(cd "$wt" && pwd -P)
  state_real=$(cd "$home/state" && pwd -P)
  brief_real=$(cd "$home/data/$id" && pwd -P)
  case "$launch" in
    *"--add-dir '$wt_real'"*) ;;
    *) fail "the agy launch must grant the resolved task worktree, got: $launch" ;;
  esac
  case "$launch" in
    *"--add-dir '$state_real'"*) ;;
    *) fail "the agy launch must grant this home's resolved state directory, got: $launch" ;;
  esac
  case "$launch" in
    *"--add-dir '$brief_real'"*) ;;
    *) fail "the agy launch must grant the brief's resolved directory, got: $launch" ;;
  esac
  # -i keeps the interactive session after the opening prompt; -p would run one
  # headless turn and exit, leaving no pane to supervise or steer.
  case "$launch" in
    *' -i '*) ;;
    *) fail "the agy launch must use -i to keep the session, got: $launch" ;;
  esac
  pass "fm-spawn.sh: an agy launch grants the worktree, state, and brief directories"
}

test_agy_grants_resolve_a_symlinked_worktree() {
  local fields case_dir home proj wt fakebin id launch link wt_real
  fields=$(make_spawn_case adddir-symlink)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  # The real regression: bin/fm-spawn.sh records the pane's RAW path as the
  # worktree, so a pane reached through a symlink yields an unresolved WT. agy
  # resolves a path before testing it against the granted workspace, so granting
  # the unresolved form made agy treat a write inside its own worktree as
  # non-workspace access and park on "Allow creation of this file? Reason:
  # outside workspace" (verified on agy 1.2.0). The two paths must genuinely
  # differ, or this case proves nothing.
  link="$case_dir/wt-link"
  ln -s "$wt" "$link"
  wt_real=$(cd "$wt" && pwd -P)
  [ "$link" != "$wt_real" ] \
    || fail "the symlink case needs a path that differs from the resolved worktree"
  run_agy_spawn "$home" "$proj" "$link" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *"--add-dir '$wt_real'"*) ;;
    *) fail "a symlinked worktree must be granted resolved, got: $launch" ;;
  esac
  case "$launch" in
    *"--add-dir '$link'"*)
      fail "the unresolved symlink path must never be the grant: $launch" ;;
  esac
  pass "fm-spawn.sh: agy grants a symlinked worktree by its resolved path"
}

# --- effort -----------------------------------------------------------------

test_agy_effort_caps_at_high() {
  local fields case_dir home proj wt fakebin id launch level
  for level in xhigh max; do
    fields=$(make_spawn_case "effort-$level")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
    : "$case_dir"
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout \
      --model gemini-3.8-flash --effort "$level" >/dev/null
    launch=$(cat "$home/launch.log")
    # agy refuses anything above high, so the intent is capped rather than
    # dropped: an omitted flag would silently leave agy on its own default.
    case "$launch" in
      *"--effort 'high'"*) ;;
      *) fail "$level must cap onto agy's high, got: $launch" ;;
    esac
    case "$launch" in
      *"--effort '$level'"*) fail "$level must never reach agy verbatim: $launch" ;;
    esac
  done
  pass "fm-spawn.sh: agy caps xhigh and max onto its supported high"
}

test_agy_effort_passes_supported_levels_through() {
  local fields case_dir home proj wt fakebin id launch level
  for level in low medium high; do
    fields=$(make_spawn_case "effort-pass-$level")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
    : "$case_dir"
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout \
      --model gemini-3.8-flash --effort "$level" >/dev/null
    launch=$(cat "$home/launch.log")
    case "$launch" in
      *"--effort '$level'"*) ;;
      *) fail "$level must pass through to agy, got: $launch" ;;
    esac
  done
  pass "fm-spawn.sh: agy's supported effort levels pass through unchanged"
}

test_agy_suffixed_model_id_suppresses_the_effort_flag() {
  local fields case_dir home proj wt fakebin id launch model
  # `--model gemini-3.8-flash-high --effort low` is a launch-refusing conflict
  # on agy 1.2.0, so a model id that already carries a level must win alone.
  for model in gemini-3.8-flash-high gemini-3.8-flash-medium gemini-3.8-flash-low; do
    fields=$(make_spawn_case "model-${model##*-}")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
    : "$case_dir"
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout \
      --model "$model" --effort low >/dev/null
    launch=$(cat "$home/launch.log")
    case "$launch" in
      *"--model '$model'"*) ;;
      *) fail "the selected model id must reach agy, got: $launch" ;;
    esac
    case "$launch" in
      *--effort*) fail "a suffixed model id must suppress --effort: $launch" ;;
    esac
  done
  # Divergence: the unsuffixed base id must still compose with --effort, or the
  # cases above would pass for a rule that simply never emits the flag.
  fields=$(make_spawn_case model-base)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout \
    --model gemini-3.8-flash --effort low >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *"--effort 'low'"*) ;;
    *) fail "an unsuffixed model id must still carry --effort, got: $launch" ;;
  esac
  pass "fm-spawn.sh: agy emits a suffixed model id or --effort, never both"
}

# --- task kinds -------------------------------------------------------------

test_agy_secondmate_launch_is_supported() {
  local fields case_dir home proj wt fakebin id out
  fields=$(make_spawn_case secondmate)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir" "$proj" "$wt"
  local sm="$case_dir/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/.agents"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$sm" agy --secondmate 2>&1) || fail "agy secondmate: $out"
  case "$out" in
    *'harness=agy kind=secondmate'*) ;;
    *) fail "secondmate launch did not complete: $out" ;;
  esac
  [ ! -e "$home/state/$id.agy-hooks" ] || fail "secondmate must use primary hooks, never worker hooks"
  pass "fm-spawn.sh: agy secondmate launches without worker wiring"
}

# --- start confirmation -----------------------------------------------------

test_agy_spawn_confirms_the_brief_started() {
  local fields case_dir home proj wt fakebin id out record
  fields=$(make_spawn_case started)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) \
    || fail "agy spawn whose worker hook reported the brief failed: $out"
  case "$out" in
    *"spawned $id harness=agy kind=scout"*) ;;
    *) fail "a confirmed agy start did not report success: $out" ;;
  esac
  record=$(bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_record_read "$2" "$3"' _ "$ROOT" "$home/state" "$id") \
    || fail "confirmed agy start left no valid busy record: $record"
  case "$record" in
    'busy agy-hook pre-invocation '*) ;;
    *) fail "spawn reported success without the worker hook's own record, got: $record" ;;
  esac
  [ -f "$home/state/$id.meta" ] || fail "a confirmed agy start did not keep its task record"
  [ ! -e "$home/launch.log.kills" ] || fail "a confirmed agy start closed its endpoint: $(cat "$home/launch.log.kills")"
  pass "fm-spawn.sh: agy spawn succeeds only after the worker hook reports the brief started"
}

test_agy_spawn_fails_and_closes_when_the_brief_never_starts() {
  local fields case_dir home proj wt fakebin id out status record
  fields=$(make_spawn_case never-started)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  # The launch is typed and submitted, and spawn's own seed record is busy the
  # whole time, but agy never invokes the model (an auth prompt, a trust dialog,
  # a refused model id). The seed must not pass for a started brief.
  out=$(FM_FAKE_AGY_START=0 FM_AGY_READY_POLLS=4 FM_AGY_POLL_INTERVAL=0.1 \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn reported success though its brief never started: $out"
  grep -Fq '.agy-hooks' "$home/launch.log" || fail "the case never delivered the agy launch: $out"
  case "$out" in
    *'agy did not report starting its brief'*) ;;
    *) fail "the refusal must say the brief never started, got: $out" ;;
  esac
  grep -q '^failed: agy did not report starting its brief' "$home/state/$id.status" \
    || fail "a never-started agy spawn did not record a failure: $(cat "$home/state/$id.status" 2>/dev/null)"
  grep -Fq "fm-$id" "$home/launch.log.kills" 2>/dev/null \
    || fail "a never-started agy spawn left its endpoint running: $(cat "$home/launch.log.kills" 2>/dev/null)"
  [ ! -e "$home/state/$id.meta" ] || fail "a never-started agy spawn kept its task record"
  [ ! -e "$home/state/$id.agy-hooks" ] || fail "a never-started agy spawn left its worker hooks installed"
  if record=$(bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_record_read "$2" "$3"' _ "$ROOT" "$home/state" "$id"); then
    fail "a never-started agy spawn left a live busy record: $record"
  fi
  pass "fm-spawn.sh: agy spawn fails, records it, and closes the endpoint when the brief never starts"
}

# --- control mechanics ------------------------------------------------------

test_agy_control_mechanics_are_the_verified_ones() {
  local out
  fm_control_harness_supported agy || fail "agy must be a supported control harness"
  out=$(fm_control_harness_family agy-1.2.0)
  [ "$out" = agy ] || fail "a recorded agy* harness must resolve to agy, got '$out'"
  out=$(fm_control_interrupt_key agy)
  [ "$out" = Escape ] || fail "agy interrupts on Escape, got '$out'"
  out=$(fm_control_interrupt_repeat agy)
  [ "$out" = 1 ] || fail "agy interrupts on a single press, got '$out'"
  out=$(fm_control_interrupt_clear_key agy)
  [ -z "$out" ] || fail "agy leaves an empty composer and needs no clear key, got '$out'"
  out=$(fm_control_interrupt_ack_source agy)
  [ "$out" = none ] || fail "agy has no recorded cancellation source, got '$out'"
  out=$(fm_control_exit_command agy)
  [ "$out" = /exit ] || fail "agy exits with /exit, got '$out'"
  pass "fm-control-lib.sh: agy carries its verified interrupt and exit mechanics"
}

test_agy_supports_all_task_kinds() {
  fm_control_harness_supports_kind agy ship || fail "agy must be verified for ship work"
  fm_control_harness_supports_kind agy scout || fail "agy must be verified for scout work"
  fm_control_harness_supports_kind agy secondmate || fail "agy must support secondmate work"
  pass "fm-control-lib.sh: agy supports worker, scout, and secondmate"
}

test_agy_wiring_has_a_cleanup_owner() {
  local out
  # Flat wiring cleanup and owned-directory retirement share this adapter path.
  out=$(fm_control_harness_wiring_paths agy /wt /state task-1)
  [ "$out" = /state/task-1.agy-hooks/.agents/hooks.json ] || fail "wrong agy wiring path: $out"
  out=$(fm_control_harness_turnend_token_path agy /state task-1)
  [ -z "$out" ] || fail "agy mints no turn-end registry token, got '$out'"
  pass "fm-control-lib.sh: agy hook file has a cleanup path and no global token"
}

test_agy_worker_hooks() {
  local dir="$TMP_ROOT/worker hooks" state wt gen next out hook
  state="$dir/state" wt="$dir/worktree"
  hook="$ROOT/bin/fm-agy-hook.sh"
  mkdir -p "$state" "$wt/.agents"
  printf '{"project-owned":{}}\n' > "$wt/.agents/hooks.json"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" agy-worker) || fail 'arm agy'
  "$hook" install-worker "$state" agy-worker "$gen" "$wt" || fail 'install agy hooks'
  out=$(cat "$wt/.agents/hooks.json")
  [ "$out" = '{"project-owned":{}}' ] || fail 'worker installation changed project hooks'
  agy_worker_event() {
    jq -n --arg conv "$2" --arg wt "$wt" --argjson idle "${3:-true}" \
      '{conversationId:$conv,workspacePaths:[$wt],fullyIdle:$idle}' \
      | "$hook" worker "$1" "$state" agy-worker "$gen" "$wt"
  }
  agy_worker_state() {
    bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux pane agy agy-worker "$2"' _ "$ROOT" "$state"
  }
  [ -z "$(agy_worker_event PreInvocation main)" ] || fail 'worker start must return an inert response'
  [ "$(agy_worker_state)" = 'busy agy-hook' ] || fail 'PreInvocation did not open busy'
  [ -z "$(agy_worker_event PreToolUse main)" ] || fail 'unsupported worker event must be inert, never request primary review'
  [ -z "$(agy_worker_event Stop child)" ] || fail 'rejected child Stop must return an inert response'
  [ "$(agy_worker_state)" = 'busy agy-hook' ] || fail 'child Stop settled parent'
  [ -z "$(agy_worker_event Stop main false)" ] || fail 'partial worker Stop must return an inert response'
  [ "$(agy_worker_state)" = 'busy agy-hook' ] || fail 'background work settled before fullyIdle'
  [ ! -e "$state/agy-worker.turn-ended" ] || fail 'partial Stop emitted completion'
  [ -z "$(agy_worker_event Stop main)" ] || fail 'worker completion must return an inert response'
  [ "$(agy_worker_state)" = 'idle agy-hook' ] || fail 'fullyIdle Stop did not close busy'
  [ -e "$state/agy-worker.turn-ended" ] || fail 'fullyIdle Stop did not notify watcher'
  rm "$state/agy-worker.turn-ended"
  next=$("$ROOT/bin/fm-busy-event.sh" arm "$state" agy-worker) || fail 'rearm agy'
  [ -z "$(agy_worker_event Stop main)" ] || fail 'stale worker generation must return an inert response'
  [ "$(agy_worker_state)" = 'busy fm-spawn' ] || fail 'stale hook changed replacement state'
  [ ! -e "$state/agy-worker.turn-ended" ] || fail 'stale hook woke replacement'
  "$hook" retire-worker "$state" agy-worker || fail 'retire agy'
  [ ! -e "$state/agy-worker.agy-hooks" ] || fail 'retire left hook directory'
  mkdir "$state/agy-worker.agy-hooks"
  if "$hook" retire-worker "$state" agy-worker 2>/dev/null; then fail 'retired an unowned directory'; fi
  : "$next"
  pass 'agy worker hooks bind generation and conversation, preserve project hooks, and retire safely'
}

test_agy_primary_hooks() {
  local dir="$TMP_ROOT/primary" out payload filter
  mkdir -p "$dir/bin" "$dir/state" "$dir/projects/project"
  git -C "$dir" init -q
  git -C "$dir" config user.name Test
  git -C "$dir" config user.email test@example.invalid
  printf '# Firstmate\n' > "$dir/AGENTS.md"
  primary_call() {
    FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
      JETSKI_APP_DATA_DIR=antigravity-cli "$ROOT/bin/fm-agy-hook.sh" primary "$1"
  }
  payload=$(jq -n --arg root "$dir" '{conversationId:"primary",workspacePaths:[$root],invocationNum:0,executionNum:0,fullyIdle:true}')
  out=$(printf '%s' "$payload" | primary_call PreInvocation)
  printf '%s' "$out" | jq -e '.injectSteps[0].ephemeralMessage | contains("fm-session-start.sh")' >/dev/null \
    || fail "startup nudge missing: $out"
  out=$(printf '%s' "$payload" | jq '.invocationNum=1' | primary_call PreInvocation)
  [ -z "$out" ] || fail 'startup nudge preempted a pending tool on a later invocation'
  out=$(printf '%s' "$payload" | jq 'del(.invocationNum)' | primary_call PreInvocation)
  [ -z "$out" ] || fail 'malformed invocation number injected startup'
  out=$(printf '%s' "$payload" | primary_call Stop)
  [ -z "$out" ] || fail "empty fleet forced a continuation: $out"
  touch "$dir/state/worker.meta"
  out=$(printf '%s' "$payload" | primary_call Stop)
  printf '%s' "$out" | jq -e '.decision == "continue" and (.reason | contains("run_command"))' >/dev/null \
    || fail "missing watcher did not force Agy recovery: $out"
  out=$(printf '%s' "$payload" | jq '.executionNum=1' | primary_call Stop)
  [ -z "$out" ] || fail 'continuation guard did not bound the follow-up'
  out=$(printf '%s' "$payload" | jq '.executionNum="0"' | primary_call Stop)
  [ -z "$out" ] || fail 'malformed execution number forced continuation'
  out=$(printf '%s' "$payload" | jq '.workspacePaths=["/elsewhere"]' | primary_call Stop)
  [ -z "$out" ] || fail 'foreign workspace forced continuation'
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"run_command",args:{CommandLine:"bin/fm-watch-arm.sh &"}}' | primary_call PreToolUse)
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null || fail "unsafe watcher accepted: $out"
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"run_command",args:{CommandLine:"date"}}' | primary_call PreToolUse)
  printf '%s' "$out" | jq -e '.decision == "ask"' >/dev/null || fail 'ordinary command must retain native review'
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"write_to_file",args:{}}' | primary_call PreToolUse)
  printf '%s' "$out" | jq -e '.decision == "ask"' >/dev/null || fail 'allowed file tool in a primary must retain native review'
  for filter in \
    'del(.conversationId)' '.conversationId=17' '.conversationId="bad/id"' \
    'del(.workspacePaths)' '.workspacePaths="wrong type"' '.workspacePaths=["/elsewhere"]' \
    'del(.toolCall)' '.toolCall.name=17' \
    'del(.toolCall.args.CommandLine)' '.toolCall.args.CommandLine=17'; do
    out=$(printf '%s' "$payload" | jq '.toolCall={name:"run_command",args:{CommandLine:"date"}}' \
      | jq "$filter" | primary_call PreToolUse)
    [ -z "$out" ] || fail "rejected PreToolUse payload must be inert ($filter), got $out"
  done
  out=$(printf 'invalid JSON' | primary_call PreToolUse)
  [ -z "$out" ] || fail 'invalid JSON must return an inert response'
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"invoke_subagent",args:{}}' | primary_call PreToolUse)
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null || fail 'untracked delegation accepted'
  # A linked worker is outside primary scope, even with a primary hook copied
  # from Firstmate itself; the marker deliberately brings a secondmate back in.
  local child="$TMP_ROOT/primary-child"
  git -C "$dir" add AGENTS.md
  git -C "$dir" commit -qm fixture
  git -C "$dir" worktree add -qb child "$child" >/dev/null 2>&1 || fail 'make linked scope'
  mkdir -p "$child/bin" "$child/state"
  dir=$child
  payload=$(printf '%s' "$payload" | jq --arg root "$dir" '.workspacePaths=[$root]')
  touch "$dir/state/worker.meta"
  out=$(printf '%s' "$payload" | primary_call Stop)
  [ -z "$out" ] || fail 'primary hook ran in worker worktree'
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"run_command",args:{CommandLine:"date"}}' | primary_call PreToolUse)
  [ -z "$out" ] || fail "primary PreToolUse must be inert in a linked worker worktree, got $out"
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"invoke_subagent",args:{}}' | primary_call PreToolUse)
  [ -z "$out" ] || fail 'out-of-scope tools must not run primary policies'
  printf 'secondmate\n' > "$dir/.fm-secondmate-home"
  out=$(printf '%s' "$payload" | primary_call Stop)
  printf '%s' "$out" | jq -e '.decision == "continue"' >/dev/null || fail 'secondmate omitted primary guard'
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"run_command",args:{CommandLine:"date"}}' | primary_call PreToolUse)
  printf '%s' "$out" | jq -e '.decision == "ask"' >/dev/null || fail 'secondmate primary scope must retain native review'
  pass 'agy primary startup, guard, loop bound, pre-tool policies, and secondmate scope'
}

test_agy_session_identity() {
  bash -c '
    . "$1/bin/fm-session-lock-lib.sh"
    fm_harness_process_matches /opt/bin/agy "/opt/bin/agy --server" || exit 1
    ! fm_harness_process_matches legacy legacy || exit 1
    ! fm_harness_process_matches agyrate agyrate || exit 1
  ' _ "$ROOT" || fail 'agy session identity must use exact command evidence'
  pass 'agy session lock recognizes the exact executable and rejects similar names'
}

test_agy_marker_outranks_inherited_claudecode
test_agy_marker_is_the_cli_not_the_ide
test_agy_does_not_claim_the_gemini_identity
test_agy_ancestry_matches_only_the_exact_command_name
test_agy_auto_uses_accept_edits_and_never_bypass
test_agy_manual_reviews_everything_and_never_bypass
test_agy_absent_setting_defaults_to_accept_edits
test_agy_invalid_setting_refuses_without_bypass
test_agy_launch_grants_the_task_worktree
test_agy_grants_resolve_a_symlinked_worktree
test_agy_effort_caps_at_high
test_agy_effort_passes_supported_levels_through
test_agy_suffixed_model_id_suppresses_the_effort_flag
test_agy_secondmate_launch_is_supported
test_agy_spawn_confirms_the_brief_started
test_agy_spawn_fails_and_closes_when_the_brief_never_starts
test_agy_control_mechanics_are_the_verified_ones
test_agy_supports_all_task_kinds
test_agy_wiring_has_a_cleanup_owner
test_agy_worker_hooks
test_agy_primary_hooks
test_agy_session_identity
