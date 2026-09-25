#!/usr/bin/env bash
# tests/fm-worker-tmux-live-e2e.test.sh - live guard for the private worker tmux
# boundary (bin/fm-worker-tmux-lib.sh; live-harness-optin family).
#
# tests/fm-worker-tmux-isolation.test.sh proves the launch removes TMUX and
# TMUX_PANE and sets TMUX_TMPDIR, using a probe in place of the harness. That
# only holds for a real worker if the harness's own shell tool passes the
# process environment through to the commands it runs, which is vendor
# behavior. For each of claude, codex, and devin that is installed, this
# starts the REAL harness non-interactively, from a process whose TMUX and
# TMUX_PANE name a lab "fleet" server, behind the exact launch statements
# fm-spawn adds, and asks it to run one probe script through its own shell
# tool. The probe records the socket its bare `tmux` reaches; it must be the
# private server, never the lab fleet. An absent harness is reported and
# skipped; a run that checked nothing fails.
#
# The composer and liveness classifiers read what a harness renders, and a
# harness may render differently without TMUX. With FM_WORKER_TMUX_LIVE_GUARDS=1
# this also re-runs tests/fm-composer-matrix-live-e2e.test.sh and
# tests/fm-harness-liveness-drift-live-e2e.test.sh with every installed harness
# binary wrapped on PATH in the same boundary, and reports which harnesses the
# wrappers actually launched.
#
# Every tmux server here is private: the lab fleet is an explicit -S socket and
# the worker's server lives under a private directory.
#
# This submits one short prompt per harness, so it is opt-in: run it with
# FM_WORKER_TMUX_LIVE=1 (or FM_LIVE=1) after a harness upgrade, and refresh
# docs/verification/runtime-backends-fork.md ("Worker tmux isolation") from it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_WORKER_TMUX_LIVE tmux

# shellcheck source=bin/fm-worker-tmux-lib.sh
. "$ROOT/bin/fm-worker-tmux-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

REAL_TMUX=$(command -v tmux)
LAB=$(mktemp -d /tmp/fmwtl.XXXXXX)
FLEET_SOCK="$LAB/fleet"
PRIVATE="$LAB/private"
CHECKED=0
FAILED=0
TIMEOUT=${FM_WORKER_TMUX_LIVE_TIMEOUT:-300}

note() { printf '# %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }

cleanup_all() {
  fm_worker_tmux_retire "$PRIVATE" >/dev/null 2>&1 || true
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$FLEET_SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup_all EXIT

ltmux() { env -u TMUX -u TMUX_PANE "$REAL_TMUX" "$@"; }

ltmux -S "$FLEET_SOCK" new-session -d -s firstmate -n fm-worker 'sleep 3600' ||
  fail "could not start the lab fleet"
FLEET_TMUX=$(ltmux -S "$FLEET_SOCK" display-message -p -t firstmate:fm-worker '#{socket_path},#{pid},0')
FLEET_PANE=$(ltmux -S "$FLEET_SOCK" display-message -p -t firstmate:fm-worker '#{pane_id}')
fm_worker_tmux_prepare "$PRIVATE" || fail "could not prepare the private worker directory"
PREFIX=$(fm_worker_tmux_launch_prefix "$PRIVATE") || fail "could not build the launch prefix"
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$PRIVATE" "$REAL_TMUX" new-session -d -s private 'sleep 3600' ||
  fail "could not start the private worker server"
PRIVATE_SOCK=$(env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$PRIVATE" "$REAL_TMUX" display-message -p '#{socket_path}')
FLEET_SOCK_REAL=${FLEET_TMUX%%,*}

# run_harness <name> <out> <cmd...>: run the harness from a process holding the
# lab fleet's TMUX, behind fm-spawn's launch statements.
run_harness() {
  local name=$1 out=$2 cwd="$LAB/$1"
  shift 2
  mkdir -p "$cwd"
  (
    cd "$cwd" || exit 1
    unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_SANDBOX CODEX_THREAD_ID
    export TMUX="$FLEET_TMUX" TMUX_PANE="$FLEET_PANE"
    fm_run_timed "$TIMEOUT" /bin/sh -c "$PREFIX"'exec "$@"' _ "$@" < /dev/null
  ) > "$out" 2>&1
}

check_harness() {  # <name> <binary> <args-before-prompt...> -- <args-after-prompt...>
  local name=$1 bin=$2 version probe result prompt rc
  shift 2
  if ! command -v "$bin" >/dev/null 2>&1; then
    note "$name: not installed; skipped"
    return 0
  fi
  version=$("$bin" --version 2>/dev/null | head -1)
  probe="$LAB/$name-probe.sh"
  result="$LAB/$name-result"
  cat > "$probe" <<SH
#!/bin/sh
{
  printf 'TMUX=%s\n' "\${TMUX-unset}"
  printf 'TMUX_TMPDIR=%s\n' "\${TMUX_TMPDIR-unset}"
  printf 'socket=%s\n' "\$(tmux display-message -p '#{socket_path}' 2>&1)"
} > '$result'
SH
  chmod +x "$probe"
  prompt="Use your shell tool to run exactly this one command, then reply with the single word done: sh $probe"
  local -a before=() after=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do before+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  after=("$@")
  run_harness "$name" "$LAB/$name.log" "$bin" "${before[@]+"${before[@]}"}" "$prompt" "${after[@]+"${after[@]}"}"
  rc=$?
  if [ ! -s "$result" ]; then
    bad "$name ($version): the harness never ran the probe (exit $rc); log tail: $(tail -3 "$LAB/$name.log" | tr '\n' ' ')"
    return 0
  fi
  if grep -qx "socket=$PRIVATE_SOCK" "$result" && grep -qx 'TMUX=unset' "$result" &&
    grep -qx "TMUX_TMPDIR=$PRIVATE" "$result" && ! grep -qF "$FLEET_SOCK_REAL" "$result"; then
    CHECKED=$((CHECKED + 1))
    printf 'ok - %s (%s): its shell tool reaches only the private tmux server\n' "$name" "$version"
  else
    bad "$name ($version): its shell tool escaped the boundary: $(tr '\n' ' ' < "$result")"
  fi
}

check_harness claude claude -p --dangerously-skip-permissions --
check_harness codex codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox --
check_harness devin devin --permission-mode dangerous --respect-workspace-trust false -p --

[ "$(ltmux -S "$FLEET_SOCK" list-windows -t firstmate -F '#{window_name}' 2>/dev/null)" = fm-worker ] ||
  bad "the lab fleet did not survive the harness runs"

if [ "${FM_WORKER_TMUX_LIVE_GUARDS:-0}" = 1 ]; then
  SHIMS="$LAB/shims"
  mkdir -p "$SHIMS"
  for h in claude codex opencode pi pi-signed grok kimi cursor-agent agy gemini muse omp devin acli; do
    real=$(command -v "$h" 2>/dev/null) || continue
    cat > "$SHIMS/$h" <<SH
#!/bin/sh
printf '%s\n' '$h' >> '$LAB/shim.log'
unset TMUX TMUX_PANE
TMUX_TMPDIR='$PRIVATE' exec '$real' "\$@"
SH
    chmod +x "$SHIMS/$h"
  done
  for guard in fm-composer-matrix-live-e2e:FM_COMPOSER_MATRIX_LIVE fm-harness-liveness-drift-live-e2e:FM_HARNESS_LIVENESS_DRIFT; do
    gate=${guard#*:}
    guard=${guard%%:*}
    note "re-running $guard with every installed harness behind the worker boundary"
    if env -u FM_LIVE PATH="$SHIMS:$PATH" "$gate=1" bash "$ROOT/tests/$guard.test.sh"; then
      printf 'ok - %s passes behind the worker boundary\n' "$guard"
    else
      bad "$guard fails behind the worker boundary"
    fi
  done
  note "harnesses launched through the boundary: $(sort -u "$LAB/shim.log" 2>/dev/null | tr '\n' ' ')"
fi

[ "$FAILED" -eq 0 ] || exit 1
[ "$CHECKED" -gt 0 ] || fail "no installed harness was checked"
