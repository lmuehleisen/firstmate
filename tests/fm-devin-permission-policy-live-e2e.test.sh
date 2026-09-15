#!/usr/bin/env bash
# Live guard for firstmate's Devin permission policy hooks against the real,
# installed Devin CLI (bin/fm-test-run.sh's live-harness-optin family).
# Opt-in because it submits prompts; isolated on a private tmux socket.
#
# It proves the harness-dependent facts bin/fm-devin-permission-policy.sh
# relies on, with the same hook shapes bin/fm-spawn.sh writes:
#   1. PreToolUse receives the exec command and a block decision refuses it.
#   2. PermissionRequest fires for a smart-mode prompt with tool_name exec and
#      tool_input.command, and an approve decision runs it with no prompt.
#   3. A silent PermissionRequest falls through to Devin's approval menu while
#      the escalation names the command in the status file, and approving at
#      the prompt fires PostToolUse for the same tool_use_id, closing it.
#   4. A headless `devin -p` first judge returns a parseable one-line verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVIN_BIN=$(command -v devin 2>/dev/null || true)
LAB=
SOCKET="fm-devin-permission-$$"
TARGET="devin-permission:devin"
DEVIN_VERSION=

cleanup() {
  local rc=$?
  [ -z "${REAL_TMUX:-}" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ "$rc" -ne 0 ] && [ -n "$LAB" ]; then
    printf 'Devin permission policy failure evidence retained: %s\n' "$LAB" >&2
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

fm_live_gate opt-in FM_DEVIN_PERMISSION_LIVE tmux jq

REAL_TMUX=$(command -v tmux)
[ -x "${DEVIN_BIN:-}" ] \
  || fail "FM_DEVIN_PERMISSION_LIVE=1 but no real devin executable is installed in PATH"
DEVIN_VERSION=$("$DEVIN_BIN" version 2>/dev/null | tr -d '\n')
[ -n "$DEVIN_VERSION" ] || fail "the installed devin did not report a version"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-devin-permission-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
WS="$LAB/ws"
STATUS="$LAB/state/t1.status"
LOG="$LAB/state/devin-permission-log.jsonl"
POLICY="$LAB/state/t1.devin-permission.json"
mkdir -p "$WS/.devin" "$LAB/state/t1.inbox" "$LAB/data/t1" "$LAB/tmp"
git init -q "$WS" || fail "could not initialize workspace fixture"
git -C "$WS" -c user.name=Test -c user.email=test@example.invalid \
  commit --allow-empty -qm "Initial commit" || fail "could not create initial commit"
: > "$WS/probe.txt"

jq -n --arg wt "$WS" --arg d "$LAB" --arg devin "$DEVIN_BIN" \
  '{task:"t1", worktree:$wt, status:($d+"/state/t1.status"), inbox:($d+"/state/t1.inbox"),
    data:($d+"/data/t1"), tasktmp:($d+"/tmp"), brief:"", log:($d+"/state/devin-permission-log.jsonl"),
    devin:$devin, judge_model:"", judge_timeout:"90"}' > "$POLICY"
policy_cmd() { printf "'%s' %s '%s'" "$ROOT/bin/fm-devin-permission-policy.sh" "$1" "$POLICY"; }
jq -n --arg pre "$(policy_cmd pre-tool-use)" --arg perm "$(policy_cmd permission-request)" \
  --arg post "$(policy_cmd post-tool-use)" --arg stop "$(policy_cmd stop)" \
  '{hooks:{
     UserPromptSubmit:[{hooks:[{type:"command", command:$stop, timeout:30}]}],
     Stop:[{hooks:[{type:"command", command:$stop, timeout:30}]}],
     SessionEnd:[{hooks:[{type:"command", command:$stop, timeout:30}]}],
     PreToolUse:[{matcher:"^exec$", hooks:[{type:"command", command:$pre, timeout:30}]}],
     PermissionRequest:[{matcher:"", hooks:[{type:"command", command:$perm, timeout:120}]}],
     PostToolUse:[{matcher:"", hooks:[{type:"command", command:$post, timeout:30}]}]}}' \
  > "$WS/.devin/config.local.json"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s devin-permission -n devin -c "$WS" \
  || fail "could not start tmux session"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "env -u CLAUDECODE \"$DEVIN_BIN\" --permission-mode smart --respect-workspace-trust false -- 'Run each of these shell commands with the shell tool, one tool call each, in order, even if one fails: 1) sudo -n true 2) git config --get core.bare 3) rm -f probe.txt . Then reply with the single word FINISHED.'"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter

escalated=0
for _ in $(seq 1 120); do
  if grep -q '^needs-decision \[key=devin-permission-[A-Za-z0-9._-]*\]: .*rm -f probe.txt' "$STATUS" 2>/dev/null; then
    escalated=1
    break
  fi
  sleep 1
done
capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
[ "$escalated" = 1 ] || fail "rm -f probe.txt did not escalate to the status file (capture: $capture)"

jq -e -s 'map(select(.event == "pre-tool-use" and .decision == "refuse" and .input == "sudo -n true")) | length == 1' "$LOG" >/dev/null \
  || fail "PreToolUse did not refuse sudo -n true: $(cat "$LOG")"
pass "devin: PreToolUse delivers the exec command and a block decision refuses it"

approved=0
for _ in $(seq 1 30); do
  if jq -e -s 'map(select(.event == "permission-request" and .decision == "approve" and .input == "git config --get core.bare")) | length == 1' "$LOG" >/dev/null 2>&1; then
    approved=1
    break
  fi
  sleep 1
done
[ "$approved" = 1 ] || fail "PermissionRequest did not approve git config --get core.bare: $(cat "$LOG")"
pass "devin: PermissionRequest delivers tool_input.command and approve runs the call without a prompt"

prompted=0
for _ in $(seq 1 30); do
  capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$capture" in
    *'Approve once'*) prompted=1; break ;;
  esac
  sleep 1
done
[ "$prompted" = 1 ] || fail "a silent PermissionRequest did not fall through to Devin's approval menu (capture: $capture)"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
closed=0
for _ in $(seq 1 60); do
  if grep -q '^resolved \[key=devin-permission-[A-Za-z0-9._-]*\]: the escalated exec call was approved at the prompt and ran' "$STATUS" 2>/dev/null; then
    closed=1
    break
  fi
  sleep 1
done
[ "$closed" = 1 ] || fail "approving at the prompt did not close the escalation through PostToolUse: $(cat "$STATUS")"
[ ! -e "$WS/probe.txt" ] || fail "the approved rm did not run"
pass "devin: an escalation falls through to the prompt and PostToolUse closes it once approved"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l exit
sleep 0.5
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter

jq '.judge_model = "swe-2-max"' "$POLICY" > "$POLICY.new" && mv "$POLICY.new" "$POLICY"
jq -nc '{hook_event_name:"PermissionRequest", tool_name:"exec", tool_input:{command:"npm install --save-dev left-pad"}, tool_use_id:"judge_1", session_id:"live"}' \
  | "$ROOT/bin/fm-devin-permission-policy.sh" permission-request "$POLICY" >/dev/null
reason=$(jq -s -r 'map(select(.tool_use_id == "judge_1")) | last | .decider + "|" + .reason' "$LOG")
case "$reason" in
  judge\|*'first judge'*|judge\|) fail "the headless swe-2-max judge gave no usable verdict: $reason" ;;
  judge\|*) ;;
  *) fail "the judge call was not logged: $reason" ;;
esac
pass "devin: the headless swe-2-max first judge returns a parseable verdict ($reason)"

printf '# all devin permission policy live checks passed (%s)\n' "$DEVIN_VERSION"
