#!/usr/bin/env bash
# fm-private-tmux-lib.sh - retire a private tmux directory (docs/tmux-backend.md
# "Worker isolation from the fleet server").
#
# One owner of stopping the tmux servers socketed inside a private directory and
# removing it, shared by teardown, spawn rollback, and the test runner.
# A socket file inside the directory proves nothing about which server answers
# it: a hardlink or rename of a live foreign socket, or a file name containing a
# newline, can hand `tmux -S` another server. So a server is stopped only when
# its own #{socket_path} is inside the directory too.
# Callers decide whether the directory is the one they own; this helper refuses
# anything that is not a real directory private to this user.

# fm_private_tmux_retire <dir>: stop every tmux server whose socket is inside
# <dir>, each by its exact socket, then remove <dir>.
# Returns 1 and touches nothing when <dir> is not a non-symlink directory owned
# by this user and closed to group and others.
fm_private_tmux_retire() {
  local dir=${1:-} real sock owned
  if [ -z "$dir" ] || [ -L "$dir" ] || [ ! -d "$dir" ] || [ ! -O "$dir" ] ||
    [ -n "$(find "$dir" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ] ||
    ! real=$(cd "$dir" && pwd -P); then
    return 1
  fi
  while IFS= read -r -d '' sock; do
    case "$sock" in "$dir"/*) ;; *) continue ;; esac
    owned=$(env -u TMUX -u TMUX_PANE tmux -S "$sock" display-message -p '#{socket_path}' 2>/dev/null) || continue
    case "$owned" in "$dir"/* | "$real"/*) ;; *) continue ;; esac
    env -u TMUX -u TMUX_PANE tmux -S "$sock" kill-server >/dev/null 2>&1 || true
  done < <(find "$dir" -type s -print0 2>/dev/null)
  rm -rf "$dir"
}
