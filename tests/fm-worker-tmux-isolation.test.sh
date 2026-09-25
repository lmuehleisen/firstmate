#!/usr/bin/env bash
# tests/fm-worker-tmux-isolation.test.sh - a ship or scout worker's bare tmux
# must reach only its private per-task server, never the fleet server hosting
# its pane (bin/fm-worker-tmux-lib.sh).
#
# Every tmux server here is real and private. A lab "fleet" server runs on a
# socket this test creates, and each launch is executed in a synthetic pane
# whose TMUX and TMUX_PANE name that lab fleet, exactly as a worker pane
# inherits them. The harness binary is replaced by a probe that records its
# environment and then runs the incident command, a bare `tmux kill-server`.
# Nothing reads bin/fm-spawn.sh's source: the assertions are what the probe saw
# and whether the lab fleet survived.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

REAL_TMUX=$(command -v tmux 2>/dev/null || true)
if [ -z "$REAL_TMUX" ]; then
  echo "skip: tmux not found (worker tmux isolation)"
  exit 0
fi

CONTROL="$ROOT/bin/fm-control.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-tmux)
# The lab fleet's socket lives under a short /tmp directory, because a socket
# path is capped (103 bytes on macOS) and TMPDIR can be long.
FLEET_DIR=$(mktemp -d /tmp/fmwti.XXXXXX)
FLEET_SOCK="$FLEET_DIR/fleet"
PRIVATE_DIRS=()

ltmux() { env -u TMUX -u TMUX_PANE "$REAL_TMUX" "$@"; }

# The private directories spawn creates live under /tmp, outside TMP_ROOT, so
# each one a case derives is retired here with the same exact-socket stop.
cleanup_worker_tmux() {
  local d
  for d in "${PRIVATE_DIRS[@]+"${PRIVATE_DIRS[@]}"}"; do
    fm_worker_tmux_retire "$d" >/dev/null 2>&1 || true
  done
  ltmux -S "$FLEET_SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$FLEET_DIR"
  fm_test_cleanup
}
trap cleanup_worker_tmux EXIT

# shellcheck source=bin/fm-worker-tmux-lib.sh
. "$ROOT/bin/fm-worker-tmux-lib.sh"

# Sets PRIVATE_DIR rather than printing it, so the cleanup list is extended in
# this shell and not in a command substitution's subshell.
private_dir_for() {  # <home> <id>
  PRIVATE_DIR=$(fm_worker_tmux_dir "$1" "$2") || return 1
  PRIVATE_DIRS+=("$PRIVATE_DIR")
}

# (Re)start the lab fleet with a captain window and one worker window, and set
# FLEET_TMUX and FLEET_PANE to what a pane on it inherits.
start_fleet() {
  ltmux -S "$FLEET_SOCK" kill-server >/dev/null 2>&1 || true
  ltmux -S "$FLEET_SOCK" new-session -d -s firstmate -n captain 'sleep 600' || return 1
  ltmux -S "$FLEET_SOCK" new-window -d -t firstmate -n fm-worker 'sleep 600' || return 1
  FLEET_TMUX=$(ltmux -S "$FLEET_SOCK" display-message -p -t firstmate:fm-worker '#{socket_path},#{pid},0')
  FLEET_PANE=$(ltmux -S "$FLEET_SOCK" display-message -p -t firstmate:fm-worker '#{pane_id}')
}

fleet_windows() {
  ltmux -S "$FLEET_SOCK" list-windows -t firstmate -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' '
}

assert_fleet_intact() {  # <label>
  assert_equals "captain fm-worker " "$(fleet_windows)" \
    "$1: the lab fleet server and both of its windows must survive the worker's bare tmux kill-server"
}

make_case() {  # <name> <harness> <id>...
  local name=$1 harness=$2 case_dir home proj wt fakebin id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# install_probe <bin-dir> <harness> <out> <mode>
# mode kill: record the environment, start a lab server with a bare tmux, record
# its socket, then run the incident's bare `tmux kill-server`.
# mode leak: the same, but leave that bare-tmux server running.
# mode observe: record the environment only (a secondmate keeps the fleet).
# Paths are baked in because an allowlisted launch clears the environment.
install_probe() {
  local bin=$1 harness=$2 out=$3 mode=$4
  cat > "$bin/$harness" <<SH
#!/bin/sh
{
  printf 'TMUX=%s\n' "\${TMUX-unset}"
  printf 'TMUX_PANE=%s\n' "\${TMUX_PANE-unset}"
  printf 'TMUX_TMPDIR=%s\n' "\${TMUX_TMPDIR-unset}"
} > '$out'
[ '$mode' != observe ] || exit 0
'$REAL_TMUX' new-session -d -s lab 'sleep 600' || printf 'lab=failed\n' >> '$out'
printf 'socket=%s\n' "\$('$REAL_TMUX' display-message -p -t lab '#{socket_path}')" >> '$out'
[ '$mode' != leak ] || exit 0
'$REAL_TMUX' kill-server >/dev/null 2>&1
printf 'kill=%s\n' "\$?" >> '$out'
SH
  chmod +x "$bin/$harness"
}

probe_value() { sed -n "s/^$1=//p" "$2" | tail -1; }

# Execute the pane's exports and launch in a synthetic pane on the lab fleet.
run_emitted_launch() {  # <fakebin> <launch> <preamble>
  env -i HOME="$TMP_ROOT/pane-home" PATH="$1:$PATH" TERM=xterm \
    TMUX="$FLEET_TMUX" TMUX_PANE="$FLEET_PANE" \
    /bin/sh -c "$3
$2"
}

# The probe's view of one worker launch, checked against its recorded directory.
assert_private_worker() {  # <label> <out> <home> <id>
  local label=$1 out=$2 home=$3 id=$4 dir real
  private_dir_for "$home" "$id" || fail "could not derive the private tmux directory"
  dir=$PRIVATE_DIR
  assert_equals "worker_tmux_dir=$dir" "$(grep '^worker_tmux_dir=' "$home/state/$id.meta")" \
    "$label: the task record should name the worker's private tmux directory"
  assert_equals unset "$(probe_value TMUX "$out")" "$label: the worker must not inherit the fleet's TMUX"
  assert_equals unset "$(probe_value TMUX_PANE "$out")" "$label: the worker must not inherit the fleet pane's TMUX_PANE"
  assert_equals "$dir" "$(probe_value TMUX_TMPDIR "$out")" \
    "$label: the worker's TMUX_TMPDIR must be its recorded private directory"
  real=$(cd "$dir" && pwd -P)
  assert_contains "$(probe_value socket "$out")" "$real/tmux-" \
    "$label: the worker's bare tmux must start its server inside the private directory"
  [ -z "$(find "$dir" -prune \( -perm -g=rwx -o -perm -o=rwx \) -print)" ] ||
    fail "$label: the private directory must be private to this user"
}

test_ship_and_scout_launches() {
  local setting kind id rec out status out_file args
  for setting in absent enabled; do
    for kind in ship scout; do
      id="$kind-$setting-t1"
      rec=$(make_case "$kind-$setting" codex "$id")
      read_case "$rec"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$kind" = ship ]; then
        args=("$id" "$PROJ_DIR" --mode direct-PR --yolo off)
      else
        args=("$id" "$PROJ_DIR" --scout)
      fi
      out=$(run_case_spawn "${args[@]}")
      status=$?
      expect_code 0 "$status" "$kind spawn with allowlist=$setting should succeed: $out"
      out_file="$CASE_DIR/probe.out"
      install_probe "$FAKEBIN_DIR" codex "$out_file" kill
      start_fleet || fail "could not start the lab fleet"
      run_emitted_launch "$FAKEBIN_DIR" "$(cat "$LAUNCH_LOG")" "$(grep '^export ' "$PANE_LOG")" \
        || fail "$kind, allowlist $setting: the emitted launch failed to run"
      assert_private_worker "$kind, allowlist $setting" "$out_file" "$HOME_DIR" "$id"
      assert_equals 0 "$(probe_value kill "$out_file")" \
        "$kind, allowlist $setting: the bare kill-server should have stopped the worker's own private server"
      assert_fleet_intact "$kind, allowlist $setting"
    done
  done
  pass "ship and scout launches, with and without an allowlist, reach only a private tmux server"
}

# A compound raw launch still starts its agent on the private server.
test_raw_compound_launch() {
  local rec out status out_file probe_dir id=raw-compound-t1
  rec=$(make_case raw-compound claude "$id")
  read_case "$rec"
  probe_dir="$CASE_DIR/agent-cwd"
  mkdir -p "$probe_dir"
  out_file="$CASE_DIR/probe.out"
  install_probe "$probe_dir" probe "$out_file" kill
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off "cd $probe_dir && ./probe")
  status=$?
  expect_code 0 "$status" "raw compound spawn should succeed: $out"
  start_fleet || fail "could not start the lab fleet"
  run_emitted_launch "$FAKEBIN_DIR" "$(cat "$LAUNCH_LOG")" "" \
    || fail "raw compound: the emitted launch failed to run"
  assert_private_worker "raw compound" "$out_file" "$HOME_DIR" "$id"
  assert_fleet_intact "raw compound"
  pass "a compound raw launch still starts its agent on the private tmux server"
}

test_secondmate_keeps_the_fleet() {
  local setting rec sm out status out_file
  for setting in absent enabled; do
    rec=$(make_case "secondmate-$setting" codex "sm-$setting")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    sm="$CASE_DIR/secondmate-home"
    mkdir -p "$sm/bin" "$sm/data"
    printf '# Firstmate\n' > "$sm/AGENTS.md"
    printf '%s\n' "sm-$setting" > "$sm/.fm-secondmate-home"
    printf 'charter for sm-%s\n' "$setting" > "$sm/data/charter.md"
    out=$(run_case_spawn "sm-$setting" "$sm" --secondmate)
    status=$?
    expect_code 0 "$status" "secondmate spawn with allowlist=$setting should succeed: $out"
    out_file="$CASE_DIR/probe.out"
    install_probe "$FAKEBIN_DIR" codex "$out_file" observe
    start_fleet || fail "could not start the lab fleet"
    run_emitted_launch "$FAKEBIN_DIR" "$(cat "$LAUNCH_LOG")" "$(grep '^export ' "$PANE_LOG")" \
      || fail "secondmate, allowlist $setting: the emitted launch failed to run"
    assert_equals "$FLEET_TMUX" "$(probe_value TMUX "$out_file")" \
      "secondmate, allowlist $setting: a secondmate places its crew on the fleet server and must keep TMUX"
    assert_equals unset "$(probe_value TMUX_TMPDIR "$out_file")" \
      "secondmate, allowlist $setting: a secondmate must not be moved onto a private tmux directory"
    grep -q '^worker_tmux_dir=' "$HOME_DIR/state/sm-$setting.meta" &&
      fail "secondmate, allowlist $setting: a secondmate record must not name a private tmux directory"
  done
  pass "a secondmate launch keeps the fleet's TMUX in both allowlist postures"
}

# The relaunch pane stub from tests/fm-spawn-compact-adviser-disable.test.sh:
# the harness exit leaves a bare shell and the launch literal restarts it.
make_relaunch_stub() {  # <case-dir>
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
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'codex' > "$D/command" ;;
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

# A relaunch rebuilds the boundary, reuses the same directory, and recreates it
# when it is gone.
test_relaunch_rebuilds_the_boundary() {
  local setting dir home proj wt id out status launch preamble out_file private
  for setting in absent enabled; do
    id="relaunch-$setting-t1"
    dir="$TMP_ROOT/relaunch-$setting"
    home="$dir/home"
    proj="$dir/proj"
    wt="$dir/wt"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake"
    touch "$home/state/.last-watcher-beat"
    [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
    make_relaunch_stub "$dir"
    fm_git_worktree "$proj" "$wt" "wt-relaunch-$setting"
    fm_test_spawn_brief "$home" "$id"
    : > "$dir/fake/literal"
    : > "$dir/fake/keys"
    printf 'codex' > "$dir/fake/command"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$wt" > "$dir/fake/cwd"
    private_dir_for "$home" "$id" || fail "could not derive the private tmux directory"
    private=$PRIVATE_DIR
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$wt"
      echo "project=$proj"
      echo "harness=codex"
      echo "kind=ship"
      echo "mode=direct-PR"
      echo "yolo=off"
      echo "tasktmp=$dir/tasktmp"
      echo "model=default"
      echo "effort=default"
      echo "worker_tmux_dir=$private"
    } > "$home/state/$id.meta"
    # A relaunch after a lost directory must recreate it rather than point the
    # replacement at a missing one.
    fm_worker_tmux_retire "$private"

    mkdir -p "$dir/user-home"
    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
    status=$?
    expect_code 0 "$status" "relaunch with allowlist=$setting should succeed: $out"
    [ "$(grep -c '^worker_tmux_dir=' "$home/state/$id.meta")" = 1 ] ||
      fail "relaunch with allowlist=$setting: the record should carry exactly one private tmux directory"
    [ -d "$private" ] || fail "relaunch with allowlist=$setting: the private directory was not recreated"
    launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
    [ -n "$launch" ] || fail "relaunch with allowlist=$setting sent no replacement launch command"
    out_file="$dir/probe.out"
    install_probe "$dir/fakebin" codex "$out_file" kill
    preamble=$(grep '^export ' "$dir/fake/keys")
    start_fleet || fail "could not start the lab fleet"
    run_emitted_launch "$dir/fakebin" "$launch" "$preamble" \
      || fail "relaunch with allowlist=$setting: the replacement launch failed to run"
    assert_private_worker "relaunch, allowlist $setting" "$out_file" "$home" "$id"
    assert_fleet_intact "relaunch, allowlist $setting"
  done
  pass "relaunch rebuilds the private tmux boundary in both allowlist postures"
}

# The directory's length does not grow with the id, and it leaves room for a
# long socket label under the macOS socket-path cap on a maximum-length id.
test_socket_budget_for_a_maximum_length_id() {
  local id rec out status out_file dir real label sockdir budget
  id=$(printf 'x%.0s' $(seq 1 64))
  rec=$(make_case budget codex "$id" "${id}x")
  read_case "$rec"
  out=$(run_case_spawn "${id}x" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a 65-character id should be refused, so 64 is the maximum: $out"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "maximum-length id spawn should succeed: $out"
  private_dir_for "$HOME_DIR" "$id" || fail "could not derive the private tmux directory"
  dir=$PRIVATE_DIR
  real=$(cd "$dir" && pwd -P)
  # Longer than the longest label a current suite uses under a runner directory.
  label="fm-sessionstart-instruction-refresh-9999999-xyz"
  sockdir="/tmux-$(id -u)/"
  budget=$(( ${#real} + ${#sockdir} + ${#label} ))
  [ "$budget" -le 103 ] || fail "a ${#label}-byte label under $real needs $budget bytes, over the 103-byte socket-path cap"
  out_file="$CASE_DIR/probe.out"
  cat > "$FAKEBIN_DIR/codex" <<SH
#!/bin/sh
'$REAL_TMUX' -L '$label' new-session -d -s lab 'sleep 600' && printf 'long=ok\n' > '$out_file'
'$REAL_TMUX' -L '$label' kill-server >/dev/null 2>&1
SH
  chmod +x "$FAKEBIN_DIR/codex"
  start_fleet || fail "could not start the lab fleet"
  run_emitted_launch "$FAKEBIN_DIR" "$(cat "$LAUNCH_LOG")" "$(grep '^export ' "$PANE_LOG")" \
    || fail "budget: the emitted launch failed to run"
  assert_equals ok "$(probe_value long "$out_file")" \
    "a worker with a maximum-length id must be able to start a server with a long label"
  assert_fleet_intact "budget"
  pass "the private directory leaves room for long socket labels on a maximum-length id"
}

test_unsafe_existing_directory_refuses() {
  local rec out status dir id=unsafe-dir-t1
  rec=$(make_case unsafe-dir codex "$id")
  read_case "$rec"
  private_dir_for "$HOME_DIR" "$id" || fail "could not derive the private tmux directory"
  dir=$PRIVATE_DIR
  ln -s "$CASE_DIR" "$dir"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  rm -f "$dir"
  [ "$status" -ne 0 ] || fail "a spawn whose private tmux directory is a symlink must refuse"
  assert_contains "$out" "private worker tmux directory" \
    "the refusal should name the private tmux directory"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must not send a launch"
  pass "a pre-existing unsafe private tmux directory refuses the spawn"
}

# Teardown stops a server the worker left running, and only that one.
test_teardown_stops_a_leaked_private_server() {
  local case_dir home id=leak-t1 dir sock fakebin out status
  case_dir="$TMP_ROOT/teardown"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  mkdir -p "$home/state" "$home/config" "$home/data" "$fakebin"
  touch "$home/state/.last-watcher-beat"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/seed" 2>/dev/null
  git -C "$case_dir/seed" commit -q --allow-empty -m baseline
  git -C "$case_dir/seed" push -q origin main
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$id" "$case_dir/wt" main
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/no-mistakes"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/gh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/gh-axi"
  # The endpoint is a fake; an exact-socket call is forwarded to the real tmux
  # so the retire's own stop is what the assertion observes.
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = -S ] || exit 0
exec '$REAL_TMUX' "\$@"
SH
  chmod +x "$fakebin"/*
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$case_dir/wt" \
    "project=$case_dir/project" "kind=ship" "mode=local-only" "spawn_gen=worker-tmux-$id"

  private_dir_for "$home" "$id" || fail "could not derive the private tmux directory"

  dir=$PRIVATE_DIR
  fm_worker_tmux_prepare "$dir" || fail "could not prepare the leak case's private directory"
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$dir" "$REAL_TMUX" new-session -d -s leaked 'sleep 600' ||
    fail "could not start the leaked private server"
  sock=$(env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$dir" "$REAL_TMUX" display-message -p '#{socket_path}')
  start_fleet || fail "could not start the lab fleet"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    TMUX="$FLEET_TMUX" TMUX_PANE="$FLEET_PANE" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "teardown of a landed task should succeed: $out"
  ltmux -S "$sock" has-session >/dev/null 2>&1 &&
    fail "teardown must stop the worker's leaked private tmux server"
  [ ! -e "$dir" ] || fail "teardown must remove the private tmux directory"
  assert_fleet_intact "teardown"
  pass "teardown stops a leaked private tmux server and leaves the fleet running"
}

# The precedence trap this guards against must hold on this tmux, or every
# assertion above would pass vacuously: with the fleet's TMUX inherited, the
# same bare kill-server stops the fleet even though TMUX_TMPDIR is private.
test_control_inherited_tmux_reaches_the_fleet() {
  local dir out_file bin
  dir="$TMP_ROOT/control-private"
  bin="$TMP_ROOT/control-bin"
  mkdir -p "$bin"
  (umask 077 && mkdir -p "$dir")
  out_file="$TMP_ROOT/control.out"
  install_probe "$bin" probe "$out_file" kill
  start_fleet || fail "could not start the lab fleet"
  env -i HOME="$TMP_ROOT/pane-home" PATH="$PATH" TERM=xterm \
    TMUX="$FLEET_TMUX" TMUX_PANE="$FLEET_PANE" TMUX_TMPDIR="$dir" "$bin/probe"
  [ -z "$(fleet_windows)" ] ||
    fail "control: an inherited TMUX should have let a bare kill-server stop the lab fleet"
  pass "control: without the launch boundary an inherited TMUX outranks TMUX_TMPDIR"
}

test_ship_and_scout_launches
test_raw_compound_launch
test_secondmate_keeps_the_fleet
test_relaunch_rebuilds_the_boundary
test_socket_budget_for_a_maximum_length_id
test_unsafe_existing_directory_refuses
test_teardown_stops_a_leaked_private_server
test_control_inherited_tmux_reaches_the_fleet
