#!/usr/bin/env bash
# fm-worker-tmux-lib.sh - the fork's private per-task tmux server for ship and
# scout workers, for bin/fm-spawn.sh, bin/fm-teardown.sh, and bin/fm-test-run.sh.
# Sourced, never executed.
#
# Kept out of the upstream-owned spawn, teardown, and runner scripts so a weekly
# upstream merge meets one-line call sites there instead of the whole mechanism.
#
# tmux picks a client's server from an explicit -S path, then an explicit -L
# label under TMUX_TMPDIR, then the socket named by an inherited TMUX, and only
# then the default label under TMUX_TMPDIR. TMUX_TMPDIR never outranks an
# inherited TMUX, so a worker holding its fleet pane's TMUX reaches the fleet
# server with a bare `tmux kill-server` even after it sets TMUX_TMPDIR.
# Every ship and scout launch - fresh spawn and relaunch, on every backend, and
# inside config/launch-env-allowlist's cleared environment - therefore starts
# its agent with TMUX and TMUX_PANE unset and TMUX_TMPDIR exported to a private
# per-task directory. A worker's bare tmux, tmux -L <label>, and Firstmate's own
# bare-tmux scripts run in a worker's lab home all reach a private server there.
# The launch carries these as shell statements rather than pane exports or an
# env prefix, so they cover a compound raw launch and survive the cleared
# environment, whose floor still forwards TMUX for the wrapping shell alone.
# Secondmates are untouched: a secondmate is a firstmate that places its own
# crew on the fleet server through its inherited TMUX, and its ship and scout
# workers get this treatment when it spawns them.
#
# The directory is /tmp/fmwt-<first 12 hex of sha256(home realpath, id)>.
# Its length is independent of the id because a Unix socket path is capped
# (103 bytes on macOS) and tmux resolves /tmp to /private/tmp there, which
# leaves about 60 bytes for a socket label under <dir>/tmux-<uid>/.
# It is created 0700, and an existing one is reused only as a real directory
# owned by this user that nobody else can write; anything else refuses the
# spawn. A relaunch reuses it, so a worker's private server survives a relaunch.
# Teardown stops every tmux server whose socket lives in it and removes it.
#
# This is an environment boundary, not a sandbox: a worker that names the fleet
# socket with -S, kills tmux by process name, or wipes its environment before
# running tmux still reaches the fleet. The worker rule in bin/fm-brief.sh
# covers the first two; docs/tmux-backend.md owns the operator-facing summary.
#
#   fm_worker_tmux_dir <home> <id>
#       prints the task's private directory, or fails without a sha256 tool
#   fm_worker_tmux_prepare <dir>
#       creates the directory 0700, or verifies an existing one is private
#   fm_worker_tmux_launch_prefix <dir>
#       prints the launch statements that move a process onto <dir>
#   fm_worker_tmux_retire <dir>
#       stops only the tmux servers whose sockets live anywhere under <dir>,
#       then removes it
#   fm_worker_tmux_spawn_wire
#       bin/fm-spawn.sh: sets FM_WORKER_TMUX_DIR for a ship or scout ($KIND,
#       $FM_HOME, $ID) and prepares it; empty for every other kind
#   fm_worker_tmux_launch_wrap
#       bin/fm-spawn.sh: prefixes $LAUNCH when FM_WORKER_TMUX_DIR is set
#   fm_worker_tmux_meta_lines
#       bin/fm-spawn.sh: prints the task-record line worker_tmux_dir=
#   fm_worker_tmux_teardown_retire <home> <id>
#       bin/fm-teardown.sh: retires the task's directory; warns, never fails

FM_WORKER_TMUX_DIR=

fm_worker_tmux_dir() {
  local home=$1 id=$2 root hash
  root=$(cd "$home" 2>/dev/null && pwd -P) || root=$home
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s\n%s' "$root" "$id" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s\n%s' "$root" "$id" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  hash=${hash:0:12}
  case "$hash" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#hash}" -eq 12 ] || return 1
  printf '/tmp/fmwt-%s\n' "$hash"
}

fm_worker_tmux_private_dir() {
  local dir=$1
  [ ! -L "$dir" ] && [ -d "$dir" ] && [ -O "$dir" ] &&
    [ -z "$(find "$dir" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ]
}

fm_worker_tmux_prepare() {
  local dir=$1
  if ! (umask 077 && mkdir "$dir") 2>/dev/null; then
    if ! fm_worker_tmux_private_dir "$dir" || ! chmod 700 "$dir"; then
      echo "error: private worker tmux directory $dir already exists and is not a private directory owned by this user; refusing to launch a worker that could reach another tmux server; inspect and remove it, then retry" >&2
      return 1
    fi
  fi
}

fm_worker_tmux_launch_prefix() {
  local dir=$1
  case "$dir" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$dir" in
    *"'"*) return 1 ;;
  esac
  printf "unset TMUX TMUX_PANE; export TMUX_TMPDIR='%s'; " "$dir"
}

fm_worker_tmux_retire() {
  local dir=$1 sock
  [ -n "$dir" ] || return 0
  [ -e "$dir" ] || [ -L "$dir" ] || return 0
  if ! fm_worker_tmux_private_dir "$dir"; then
    echo "warning: private worker tmux directory $dir is not a private directory owned by this user; leaving it and any server under it untouched" >&2
    return 1
  fi
  # Every socket anywhere under the directory is stopped: the default and -L
  # sockets under tmux-<uid>/ and any a worker named with -S. find does not
  # follow symlinks, so nothing outside the directory is visited. Each server
  # is addressed by its exact socket path, which outranks an inherited TMUX,
  # and the caller's own TMUX is dropped as well.
  while IFS= read -r sock; do
    env -u TMUX -u TMUX_PANE tmux -S "$sock" kill-server >/dev/null 2>&1 || true
  done < <(find "$dir" -type s -print 2>/dev/null)
  rm -rf "$dir"
}

fm_worker_tmux_spawn_wire() {
  FM_WORKER_TMUX_DIR=
  case "$KIND" in
    ship | scout) ;;
    *) return 0 ;;
  esac
  FM_WORKER_TMUX_DIR=$(fm_worker_tmux_dir "$FM_HOME" "$ID") || {
    echo "error: could not derive the private worker tmux directory for $ID (needs shasum or sha256sum); refusing to launch a worker that would share the fleet's tmux server" >&2
    return 1
  }
  fm_worker_tmux_prepare "$FM_WORKER_TMUX_DIR"
}

fm_worker_tmux_launch_wrap() {
  local prefix
  [ -n "$FM_WORKER_TMUX_DIR" ] || return 0
  prefix=$(fm_worker_tmux_launch_prefix "$FM_WORKER_TMUX_DIR") || {
    echo "error: private worker tmux directory '$FM_WORKER_TMUX_DIR' is not a plain absolute path" >&2
    return 1
  }
  LAUNCH="$prefix$LAUNCH"
}

fm_worker_tmux_meta_lines() {
  [ -z "$FM_WORKER_TMUX_DIR" ] || printf 'worker_tmux_dir=%s\n' "$FM_WORKER_TMUX_DIR"
}

fm_worker_tmux_teardown_retire() {
  local dir
  dir=$(fm_worker_tmux_dir "$1" "$2") || return 0
  fm_worker_tmux_retire "$dir" || true
}
