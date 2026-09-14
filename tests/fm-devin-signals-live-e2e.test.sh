#!/usr/bin/env bash
# Live guard for the real, installed Devin CLI (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping, isolated on a private
# tmux socket so it never touches the host's own sessions.
#
# It proves the harness-dependent facts recorded for devin:
#   1. Binary presence and version reporting.
#   2. The launch shape with `--permission-mode smart --respect-workspace-trust false`
#      reaches a usable composer with NO workspace-trust dialog.
#   3. Process classification reports `devin` as the running command.
#   4. Double Escape (repeat 2 at 0.2s spacing) cancels execution and prints
#      `✱ Canceled. What should Devin do?`.
#   5. `/exit` cleanly terminates the session.
#   6. The delivery busy regex matches the rendered thinking tokens.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVIN_BIN=$(command -v devin 2>/dev/null || true)
LAB=
SOCKET="fm-devin-signals-$$"
SESSION=devin-signals
TARGET="$SESSION:devin"
DEVIN_VERSION=

cleanup() {
  local rc=$?
  [ -z "${REAL_TMUX:-}" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ "$rc" -ne 0 ] && [ -n "$LAB" ]; then
    printf 'Devin worker failure evidence retained: %s\n' "$LAB" >&2
  else
    [ -z "$LAB" ] || rm -rf -- "$LAB"
  fi
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s (devin %s)\n' "$1" "${DEVIN_VERSION:-unknown}" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_DEVIN_SIGNALS_LIVE tmux

REAL_TMUX=$(command -v tmux)
[ -x "${DEVIN_BIN:-}" ] \
  || fail "FM_DEVIN_SIGNALS_LIVE=1 but no real devin executable is installed in PATH"
DEVIN_VERSION=$("$DEVIN_BIN" version 2>/dev/null | tr -d '\n')
[ -n "$DEVIN_VERSION" ] || fail "the installed devin did not report a version"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-devin-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
WORKSPACE="$LAB/workspace"
mkdir -p "$WORKSPACE"

git init -q "$WORKSPACE" || fail "could not initialize workspace fixture"
git -C "$WORKSPACE" -c user.name=Test -c user.email=test@example.invalid \
  commit --allow-empty -m "Initial commit" -q || fail "could not create initial commit"

# Start isolated tmux server
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n devin -c "$WORKSPACE" || fail "could not start tmux session"

# 1. Launch Devin in smart mode with workspace trust bypass
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "env -u CLAUDECODE FM_DEVIN_HARNESS=devin \"$DEVIN_BIN\" --permission-mode smart --respect-workspace-trust false -- 'Reply with the single word READY.'"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter

# Wait for Devin to launch and render its composer
started=0
for _ in $(seq 1 60); do
  sleep 1
  capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$capture" in
    *'smart mode on'*|*'Ask Devin'*|*'READY'*|*'Thinking'*)
      started=1
      break
      ;;
  esac
  # Check if blocked on trust prompt (must not happen)
  case "$capture" in
    *'Do you trust the authors of this directory'*|*'1 Yes, trust'*)
      fail "Devin blocked on workspace trust despite --respect-workspace-trust false"
      ;;
  esac
done
[ "$started" = 1 ] || fail "Devin did not start within 60s (capture: $capture)"

pass "devin: launches in smart mode without workspace trust prompt"

# 2. Process classification
pane_cmd=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}')
[ "$pane_cmd" = devin ] || fail "pane current command must be devin, got '$pane_cmd'"
pass "devin: #{pane_current_command} reports devin"

# 3. Wait for the initial turn to finish or ready prompt
ready=0
for _ in $(seq 1 60); do
  capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$capture" in
    *READY*|*'Ask Devin to build features'*)
      ready=1
      break
      ;;
  esac
  sleep 1
done
[ "$ready" = 1 ] || fail "Devin did not complete initial prompt within 60s"
pass "devin: initial turn completed"

# 4. Test interrupt on a long essay turn
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Write an extremely detailed, comprehensive 5000-word historical essay comparing the Roman Republic to the Athenian democracy, with full analysis of legal systems."
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter

# Wait for busy thinking to appear
thinking=0
for _ in $(seq 1 30); do
  sleep 1
  capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$capture" in
    *'esc twice to interrupt'*|*'esc again to interrupt'*|*'Thinking'*)
      thinking=1
      break
      ;;
  esac
done
[ "$thinking" = 1 ] || fail "Devin did not enter thinking state for essay prompt"

# Send double Escape with 0.2s spacing (the fm-control interrupt key sequence)
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape
sleep 0.2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape

# Wait for cancellation message
canceled=0
for _ in $(seq 1 30); do
  sleep 1
  capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$capture" in
    *'Canceled'*|*'What should Devin do'*)
      canceled=1
      break
      ;;
  esac
done
[ "$canceled" = 1 ] || fail "double Escape did not cancel execution (capture: $capture)"
pass "devin: double Escape cancels running turn and prints Canceled"

# 5. Clean exit via /exit
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/exit"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter

exited=0
for _ in $(seq 1 30); do
  sleep 1
  pane_cmd=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$pane_cmd" in
    zsh|bash|sh)
      exited=1
      break
      ;;
  esac
done
[ "$exited" = 1 ] || fail "Devin did not exit after /exit (pane command: $pane_cmd)"
pass "devin: /exit cleanly terminates process to shell"

# 6. Delivery busy regex
printf '%s\n' "⠀⠸ Thinking · 1s (esc twice to interrupt)" | bash -c '. "$1/bin/fm-composer-lib.sh"; fm_busy_lines_match devin' _ "$ROOT" \
  || fail "fm_busy_lines_match devin failed on (esc twice to interrupt)"
printf '%s\n' "Thinking · 4s (esc again to interrupt)" | bash -c '. "$1/bin/fm-composer-lib.sh"; fm_busy_lines_match devin' _ "$ROOT" \
  || fail "fm_busy_lines_match devin failed on (esc again to interrupt)"
pass "devin: delivery busy regex matches thinking tokens"

printf '# all devin signals live checks passed (%s)\n' "$DEVIN_VERSION"
