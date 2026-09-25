#!/usr/bin/env bash
# Live guard for the real, installed Devin CLI (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping, isolated on a private
# tmux socket so it never touches the host's own sessions.
#
# It proves the harness-dependent facts recorded for devin:
#   1. Binary presence and version reporting.
#   2. The smart-mode launch reaches a usable composer with no trust or routine
#      staging/report permission prompt under the production permission shape.
#   3. Process classification reports `devin` as the running command.
#   4. Double Escape (repeat 2 at 0.2s spacing) cancels execution and prints
#      `✱ Canceled. What should Devin do?`.
#   5. The plain `exit` alias cleanly terminates the session (the `/exit`
#      slash form is ambiguous against devin's `/revert <step>` fuzzy search).
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
    fm_test_rm_tmproot "${LAB:-}"
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
fm_test_require_tmproot "$LAB"
WORKSPACE="$LAB/workspace"
TASK_TMP="$LAB/tasktmp"
REPORT="$LAB/report.md"
mkdir -p "$WORKSPACE/.devin" "$TASK_TMP"

cat > "$WORKSPACE/.devin/config.local.json" <<EOF
{"permissions":{"allow":["Exec(git add)","Write($REPORT)","Write($TASK_TMP)"]}}
EOF

git init -q "$WORKSPACE" || fail "could not initialize workspace fixture"
git -C "$WORKSPACE" -c user.name=Test -c user.email=test@example.invalid \
  commit --allow-empty -m "Initial commit" -q || fail "could not create initial commit"

# Start isolated tmux server
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n devin -c "$WORKSPACE" || fail "could not start tmux session"

# 1. Launch Devin in smart mode with workspace trust bypass
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "env -u CLAUDECODE FM_DEVIN_HARNESS=devin TMPDIR=\"$TASK_TMP\" \"$DEVIN_BIN\" --permission-mode smart --respect-workspace-trust false -- 'Use the direct write tool, not shell redirection, to create $REPORT containing REPORT. Create staged.txt containing STAGED in the workspace, run git add staged.txt, then reply with the single word READY.'"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter

# Wait for Devin to launch and render its composer. `READY` is deliberately
# excluded from this match set: it is also literal text inside the launch
# prompt itself, so it can match the shell's own echo of the not-yet-submitted
# command line before Devin has even started, racing pane_current_command
# (live-reproduced 2026-09-15: matched at pane_current_command=zsh, one second
# after Enter, well before Devin's composer painted).
started=0
for _ in $(seq 1 60); do
  sleep 1
  capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$capture" in
    *'smart mode on'*|*'Ask Devin'*|*'Thinking'*)
      started=1
      break
      ;;
  esac
  # Check if blocked on trust prompt (must not happen)
  # shellcheck disable=SC2016 # Backtick below is literal Devin prompt markup, not command substitution.
  case "$capture" in
    *'Do you trust the authors of this directory'*|*'1 Yes, trust'*)
      fail "Devin blocked on workspace trust despite --respect-workspace-trust false"
      ;;
    *'Approve once'*|*'allow `git add` commands'*)
      fail "Devin requested approval for a pre-allowed staging or report action"
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
  # shellcheck disable=SC2016 # Backtick below is literal Devin prompt markup, not command substitution.
  case "$capture" in
    *'Approve once'*|*'allow `git add` commands'*)
      fail "Devin requested approval for a pre-allowed staging or report action"
      ;;
  esac
  if [ "$(cat "$REPORT" 2>/dev/null)" = REPORT ] \
     && [ "$(cat "$WORKSPACE/staged.txt" 2>/dev/null)" = STAGED ] \
     && git -C "$WORKSPACE" diff --cached --name-only | grep -qxF staged.txt; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || fail "Devin did not complete initial prompt within 60s"
[ "$(cat "$REPORT" 2>/dev/null)" = REPORT ] || fail "Devin did not write the task-scoped report without approval"
[ "$(cat "$WORKSPACE/staged.txt" 2>/dev/null)" = STAGED ] || fail "Devin did not create staged.txt"
git -C "$WORKSPACE" diff --cached --name-only | grep -qxF staged.txt \
  || fail "Devin did not stage staged.txt with the pre-allowed git add"
pass "devin: initial turn completed with report write and git staging"

# The file-based readiness above can land a beat before Devin's own turn
# fully ends (it still prints READY and returns the composer to idle). A
# prompt sent into that tail window is queued behind the in-flight turn
# ("Press Enter to send queued messages now") instead of starting immediately,
# which would starve the next step's wait for a "Thinking" state that never
# arrives (live-reproduced 2026-09-15). Wait for the idle composer placeholder
# itself (a positive confirmation), not merely the absence of a busy marker
# that a single redraw frame could momentarily miss.
settled=0
for _ in $(seq 1 15); do
  capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$capture" in
    *'Ask Devin to build features'*)
      settled=1
      break
      ;;
  esac
  sleep 1
done
[ "$settled" = 1 ] || fail "Devin's initial turn did not settle to idle within 15s (capture: $capture)"

# 4. Test interrupt on a long essay turn. Unlike the launch prompt above
# (typed at a shell prompt, not Devin's own composer), an Enter sent
# immediately after a long literal block lands into Devin's live composer
# before it has finished registering the paste and is dropped rather than
# submitted, leaving the text sitting unsent in the composer indefinitely
# (live-reproduced 2026-09-15). A brief pause before Enter avoids the race.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Write an extremely detailed, comprehensive 5000-word historical essay comparing the Roman Republic to the Athenian democracy, with full analysis of legal systems."
sleep 0.5
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

# 5. Clean exit via the plain `exit` alias. The `/exit` slash form is
# ambiguous against devin's `/revert <step>` fuzzy command search and was
# live-observed opening that menu instead of exiting (fm-control-lib.sh's
# fm_control_exit_command is the source of truth for the command used).
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
exit_cmd=$(fm_control_exit_command devin) || fail "fm_control_exit_command devin must resolve"
# An Enter sent immediately after literal text lands in Devin's live composer
# before it finishes registering the input and can be dropped rather than
# submitted (same race as the essay prompt above; production's
# fm_backend_send_text_submit already retries past this, but this script
# drives tmux directly, so it needs the same brief pause).
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "$exit_cmd"
sleep 0.5
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter

exited=0
for _ in $(seq 1 30); do
  sleep 1
  capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$capture" in
    *'Revert'*'step'*|*'/revert'*)
      fail "devin exit command opened the revert-to-step search menu instead of exiting (capture: $capture)"
      ;;
  esac
  pane_cmd=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$pane_cmd" in
    zsh|bash|sh)
      exited=1
      break
      ;;
  esac
done
[ "$exited" = 1 ] || fail "Devin did not exit after '$exit_cmd' (pane command: $pane_cmd)"
pass "devin: plain exit cleanly terminates process to shell, unambiguous against /revert"

# 6. Delivery busy regex
printf '%s\n' "⠀⠸ Thinking · 1s (esc twice to interrupt)" | bash -c '. "$1/bin/fm-composer-lib.sh"; fm_busy_lines_match devin' _ "$ROOT" \
  || fail "fm_busy_lines_match devin failed on (esc twice to interrupt)"
printf '%s\n' "Thinking · 4s (esc again to interrupt)" | bash -c '. "$1/bin/fm-composer-lib.sh"; fm_busy_lines_match devin' _ "$ROOT" \
  || fail "fm_busy_lines_match devin failed on (esc again to interrupt)"
pass "devin: delivery busy regex matches thinking tokens"

printf '# all devin signals live checks passed (%s)\n' "$DEVIN_VERSION"
