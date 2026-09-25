#!/usr/bin/env bash
# tests/fm-worker-tmux-isolation.test.sh - a ship worker's bare
# `tmux kill-server` must not reach the fleet server hosting its pane
# (docs/tmux-backend.md "Worker isolation from the fleet server").
#
# A stand-in fleet runs on a private -S socket. The real spawn's launch is
# executed in a synthetic pane whose TMUX and TMUX_PANE name that stand-in, the
# way a worker pane inherits them, with the harness replaced by a probe that
# records its environment and runs the bare kill-server. Nothing reads
# bin/fm-spawn.sh's source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

REAL_TMUX=$(command -v tmux 2>/dev/null || true)
if [ -z "$REAL_TMUX" ]; then
  echo "skip: tmux not found (worker tmux isolation)"
  exit 0
fi
REAL_SLEEP=$(command -v sleep)

TMP_ROOT=$(fm_test_tmproot fm-worker-tmux)
# Short, because a socket path is capped (103 bytes on macOS).
FLEET_DIR=$(mktemp -d /tmp/fmwti.XXXXXX)
FLEET_SOCK="$FLEET_DIR/fleet"
PRIVATE_DIRS=()

ltmux() { env -u TMUX -u TMUX_PANE "$REAL_TMUX" "$@"; }

cleanup_worker_tmux() {
  local d sock
  for d in "${PRIVATE_DIRS[@]+"${PRIVATE_DIRS[@]}"}"; do
    case "$d" in /tmp/fmwt-*) ;; *) continue ;; esac
    while IFS= read -r sock; do
      ltmux -S "$sock" kill-server >/dev/null 2>&1 || true
    done < <(find "$d" -type s -print 2>/dev/null)
    rm -rf "$d"
  done
  ltmux -S "$FLEET_SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$FLEET_DIR"
  fm_test_cleanup
}
trap cleanup_worker_tmux EXIT

start_fleet() {
  ltmux -S "$FLEET_SOCK" kill-server >/dev/null 2>&1 || true
  ltmux -S "$FLEET_SOCK" new-session -d -s firstmate -n captain "$REAL_SLEEP 600" || return 1
  ltmux -S "$FLEET_SOCK" new-window -d -t firstmate -n fm-worker "$REAL_SLEEP 600" || return 1
  FLEET_TMUX=$(ltmux -S "$FLEET_SOCK" display-message -p -t firstmate:fm-worker '#{socket_path},#{pid},0')
  FLEET_PANE=$(ltmux -S "$FLEET_SOCK" display-message -p -t firstmate:fm-worker '#{pane_id}')
}

fleet_windows() {
  ltmux -S "$FLEET_SOCK" list-windows -t firstmate -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' '
}

# install_probe <bin-dir> <out>: records the environment, starts a lab server
# with a bare tmux, records its socket, then runs the bare kill-server. Paths
# are baked in because an allowlisted launch clears the environment.
install_probe() {
  cat > "$1/codex" <<SH
#!/bin/sh
{
  printf 'TMUX=%s\n' "\${TMUX-unset}"
  printf 'TMUX_PANE=%s\n' "\${TMUX_PANE-unset}"
  printf 'TMUX_TMPDIR=%s\n' "\${TMUX_TMPDIR-unset}"
} > '$2'
'$REAL_TMUX' new-session -d -s lab '$REAL_SLEEP 600'
printf 'socket=%s\n' "\$('$REAL_TMUX' display-message -p -t lab '#{socket_path}')" >> '$2'
'$REAL_TMUX' kill-server >/dev/null 2>&1
SH
  chmod +x "$1/codex"
}

probe_value() { sed -n "s/^$1=//p" "$2" | tail -1; }

test_ship_worker_cannot_reach_the_fleet() {
  local setting id case_dir home proj wt fakebin out status dir real result
  for setting in absent enabled; do
    id="ship-$setting-t1"
    case_dir="$TMP_ROOT/$setting"
    home="$case_dir/home"
    proj="$case_dir/project"
    wt="$case_dir/wt"
    fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
    fm_test_spawn_home "$home" codex
    fm_git_worktree "$proj" "$wt" "wt-$setting"
    fm_test_spawn_brief "$home" "$id"
    [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
    out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_FAKE_PANE_LOG="$case_dir/pane.log" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode direct-PR --yolo off)
    status=$?
    expect_code 0 "$status" "ship spawn with allowlist=$setting should succeed: $out"
    dir=$(sed -n 's/^worker_tmux_dir=//p' "$home/state/$id.meta")
    PRIVATE_DIRS+=("$dir")
    [ -n "$dir" ] || fail "allowlist=$setting: the task record should name the private tmux directory"

    result="$case_dir/probe.out"
    install_probe "$fakebin" "$result"
    start_fleet || fail "could not start the stand-in fleet"
    env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
      TMUX="$FLEET_TMUX" TMUX_PANE="$FLEET_PANE" \
      /bin/sh -c "$(grep '^export ' "$case_dir/pane.log")
$(cat "$case_dir/launch.log")" || fail "allowlist=$setting: the emitted launch failed to run"

    assert_equals "captain fm-worker " "$(fleet_windows)" \
      "allowlist=$setting: the stand-in fleet must survive the worker's bare tmux kill-server"
    assert_equals unset "$(probe_value TMUX "$result")" "allowlist=$setting: the worker must not inherit TMUX"
    assert_equals unset "$(probe_value TMUX_PANE "$result")" "allowlist=$setting: the worker must not inherit TMUX_PANE"
    assert_equals "$dir" "$(probe_value TMUX_TMPDIR "$result")" \
      "allowlist=$setting: the worker's TMUX_TMPDIR must be its private directory"
    real=$(cd "$dir" && pwd -P)
    assert_contains "$(probe_value socket "$result")" "$real/tmux-" \
      "allowlist=$setting: the worker's bare tmux must reach a server in its private directory"
  done
  pass "a ship worker's bare tmux kill-server reaches only its private server, with and without an allowlist"
}

# Without the boundary, the same probe with the fleet's TMUX inherited does stop
# the stand-in fleet even though TMUX_TMPDIR is private, so the case above is
# not passing vacuously.
test_control_inherited_tmux_reaches_the_fleet() {
  local bin="$TMP_ROOT/control-bin" dir="$TMP_ROOT/control-private"
  mkdir -p "$bin"
  (umask 077 && mkdir -p "$dir")
  install_probe "$bin" "$TMP_ROOT/control.out"
  start_fleet || fail "could not start the stand-in fleet"
  env -i HOME="$TMP_ROOT/pane-home" PATH="$PATH" TERM=xterm \
    TMUX="$FLEET_TMUX" TMUX_PANE="$FLEET_PANE" TMUX_TMPDIR="$dir" "$bin/codex"
  [ -z "$(fleet_windows)" ] ||
    fail "control: an inherited TMUX should have let a bare kill-server stop the stand-in fleet"
  pass "control: without the launch boundary an inherited TMUX outranks TMUX_TMPDIR"
}

test_ship_worker_cannot_reach_the_fleet
test_control_inherited_tmux_reaches_the_fleet
