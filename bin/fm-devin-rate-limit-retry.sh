#!/usr/bin/env bash
# fm-devin-rate-limit-retry.sh - automatic retry for a Devin CLI worker whose
# turn stopped on the model rate limit. Fork-only; bin/fm-devin-lib.sh wires
# it as native Devin hooks in the worker's .devin/config.local.json.
#
# Usage: fm-devin-rate-limit-retry.sh <event> <state-dir> <task-id> <fm-home>
#   events: arm | stop | end | retire | watch (internal)
#
# Why a sentinel: when Devin's model returns "Reached free model rate limit
# ... Your limit will reset in <N> <unit>" three times in a row, Devin stops
# the turn, renders "Something went wrong ... Send a message to retry", and
# idles on an empty composer. That error path fires NO hook - not Stop, not
# any other (live-verified on devin 3000.11.3; the harness-adapters devin
# reference records the evidence) - so nothing inside Devin can react. The
# only structural record of it is Devin's own session log,
# ~/.local/share/devin/cli/logs/devin_<date>_<pid>.log, written by the
# `devin acp` process that also runs the hooks, where the failed turn ends
# with one `Sending error response ... method=session/prompt error=` line
# carrying the same message, reset time included.
#
#   arm (UserPromptSubmit)
#       Opens a new turn: records a fresh turn token under
#       <state-dir>/<task-id>.devin-retry/, finds the session log by walking
#       the hook's process ancestry to the first pid with a
#       devin_*_<pid>.log (the newest, when a reused pid left an older one),
#       and starts one detached `watch` sentinel for this
#       turn from the log's current line count. A turn whose log cannot be
#       found is logged as unarmed and gets no automatic retry.
#   stop (Stop)
#       The turn ended normally: retires the sentinel, resets the
#       consecutive-retry count, and when the cap line below was written,
#       appends `resolved [key=devin-rate-limit]` to close it.
#   end (SessionEnd)
#       Retires the sentinel without touching the count.
#   retire (not a hook)
#       bin/fm-devin-lib.sh's teardown and relaunch retire: removes the
#       per-task directory, which also ends any sentinel within one poll.
#   watch (internal; started by arm)
#       Follows the session log until this turn's token is replaced (a new
#       prompt, a Stop, a SessionEnd, or a retire) or a turn-ending rate-limit
#       error appears. On that error it parses the stated reset (60 seconds
#       when none is stated) and schedules one retry at
#         reset + BACKOFF * 2^count + random(0..JITTER)
#       where count is the number of automatic retries already sent since the
#       task's last normal Stop. The home-wide slot file
#       <state-dir>/devin-rate-limit-slot then pushes that time to at least
#       SPACING seconds after the latest retry any other worker in this home
#       scheduled, so workers that hit the limit together retry apart; when
#       another claimant holds the slot's lock throughout, the retry keeps its
#       own time unstaggered. It sleeps to the slot, gives up if the turn token changed meanwhile, and
#       sends one ordinary steer through bin/fm-send.sh, so the message lands
#       in the task's durable inbox and the doorbell submit starts the retry
#       turn; a send that fails is logged and not counted. Once count reaches MAX it sends nothing and appends one
#       `blocked [key=devin-rate-limit]` status line instead.
#
# Every arm, detection, retry, cap, and failure is one JSON line in the
# home-wide <state-dir>/devin-rate-limit-log.jsonl, the evidence for how often
# the limit is hit, e.g.
#   jq -s 'group_by(.event) | map({event: .[0].event, n: length})' state/devin-rate-limit-log.jsonl
#
# Every hook invocation exits 0 so a failure here never breaks Devin's
# lifecycle.
#
# Tuning (environment, read by the sentinel; seconds unless noted):
#   FM_DEVIN_RETRY_MAX      consecutive automatic retries before the cap (4)
#   FM_DEVIN_RETRY_BACKOFF  base extra delay, doubled per retry sent (15)
#   FM_DEVIN_RETRY_JITTER   upper bound of the random extra delay (10)
#   FM_DEVIN_RETRY_SPACING  minimum gap between two retries in one home (30)
#   FM_DEVIN_RETRY_POLL     log and token poll interval (5)
#   FM_DEVIN_RETRY_LIFETIME longest a sentinel follows one turn (21600)
#   FM_DEVIN_RETRY_LOG_DIR  Devin's log directory
#                           (~/.local/share/devin/cli/logs)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SELF" | sed '$d; s/^# \{0,1\}//'
}

case "${1-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

[ "$#" -ge 4 ] || {
  echo "usage: fm-devin-rate-limit-retry.sh <arm|stop|end|retire> <state-dir> <task-id> <fm-home>" >&2
  exit 0
}

EVENT=$1 STATE=$2 TASK=$3 HOME_DIR=$4
shift 4
DIR="$STATE/$TASK.devin-retry"
EVENT_LOG="$STATE/devin-rate-limit-log.jsonl"
STATUS="$STATE/$TASK.status"
SLOT="$STATE/devin-rate-limit-slot"
LOG_DIR=${FM_DEVIN_RETRY_LOG_DIR:-$HOME/.local/share/devin/cli/logs}
MAX=${FM_DEVIN_RETRY_MAX:-4}
BACKOFF=${FM_DEVIN_RETRY_BACKOFF:-15}
JITTER=${FM_DEVIN_RETRY_JITTER:-10}
SPACING=${FM_DEVIN_RETRY_SPACING:-30}
POLL=${FM_DEVIN_RETRY_POLL:-5}
LIFETIME=${FM_DEVIN_RETRY_LIFETIME:-21600}
KEY=devin-rate-limit
RETRY_MESSAGE="Automatic retry: your last turn stopped on Devin's model rate limit, which has now reset. Continue the task from where it stopped."

log_event() {  # <event> <detail>
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg task "$TASK" \
    --arg event "$1" --arg detail "$2" \
    '{ts:$ts, task:$task, event:$event, detail:$detail}' \
    >>"$EVENT_LOG" 2>/dev/null || true
}

status_append() {  # <line>
  [ -f "$STATUS" ] || return 0
  printf '%s\n' "$1" >>"$STATUS" 2>/dev/null || true
}

set_turn() {  # <token>
  mkdir -p "$DIR" 2>/dev/null || return 1
  printf '%s\n' "$1" >"$DIR/turn.$$" && mv -f "$DIR/turn.$$" "$DIR/turn"
}

turn_is() {  # <token>
  [ "$(cat "$DIR/turn" 2>/dev/null)" = "$1" ]
}

retry_count() {
  local n
  n=$(cat "$DIR/count" 2>/dev/null) || n=0
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# The session log belongs to the `devin acp` process that runs this hook, so
# the first ancestor with a devin_*_<pid>.log names it; when a reused pid left
# an older log behind, the most recently written one is the live session's.
find_session_log() {
  local pid=$PPID f newest _
  for _ in 1 2 3 4 5 6 7 8; do
    case "$pid" in '' | *[!0-9]* | 0 | 1) return 1 ;; esac
    newest=
    for f in "$LOG_DIR"/devin_*_"$pid".log; do
      [ -f "$f" ] || continue
      if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi
    done
    [ -z "$newest" ] || {
      printf '%s\n' "$newest"
      return 0
    }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}

line_count() {  # <file>
  local n
  n=$(wc -l <"$1" 2>/dev/null | tr -d ' ') || n=0
  printf '%s' "${n:-0}"
}

# Seconds named by "reset in <N> <second|minute|hour>[s]"; 60 when absent.
reset_seconds() {  # <error-line>
  local parsed n unit
  parsed=$(printf '%s' "$1" | sed -nE 's/.*[Rr]eset in ([0-9]+) (second|minute|hour)s?.*/\1 \2/p' | head -1)
  n=${parsed%% *}
  unit=${parsed#* }
  case "$n" in '' | *[!0-9]*) printf '60' && return 0 ;; esac
  case "$unit" in
  minute) printf '%s' $((n * 60)) ;;
  hour) printf '%s' $((n * 3600)) ;;
  *) printf '%s' "$n" ;;
  esac
}

# Claims the home-wide retry slot at or after <epoch>, at least SPACING after
# the latest slot any worker in this home claimed; prints the claimed epoch.
# When the lock stays held by a live claimant, it prints <epoch> unstaggered
# and leaves the slot and the lock alone.
claim_slot() {  # <epoch>
  local want=$1 last lock="$SLOT.lock" held acquired='' _
  for _ in $(seq 1 50); do
    mkdir "$lock" 2>/dev/null && {
      acquired=1
      break
    }
    # A holder that died leaves the lock behind; the section below takes
    # milliseconds, so a lock older than 30 seconds is abandoned.
    held=$(fm_lock_path_mtime "$lock") || held=
    case "$held" in '' | *[!0-9]*) ;; *) [ $(($(date +%s) - held)) -le 30 ] || rmdir "$lock" 2>/dev/null || true ;; esac
    sleep 0.2
  done
  [ -n "$acquired" ] || {
    log_event unstaggered "the retry slot lock stayed held; retry scheduled without home-wide spacing"
    printf '%s' "$want"
    return 0
  }
  last=$(cat "$SLOT" 2>/dev/null) || last=0
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ "$want" -ge $((last + SPACING)) ] || want=$((last + SPACING))
  printf '%s\n' "$want" >"$SLOT.$$" && mv -f "$SLOT.$$" "$SLOT"
  rmdir "$lock" 2>/dev/null || true
  printf '%s' "$want"
}

cmd_arm() {
  local token log start
  cat >/dev/null 2>&1 || true
  token="$(date +%s).$$.$RANDOM"
  set_turn "$token" || return 0
  if ! log=$(find_session_log); then
    log_event unarmed "no Devin session log found in $LOG_DIR for the hook's process ancestry"
    return 0
  fi
  start=$(line_count "$log")
  nohup "$SELF" watch "$STATE" "$TASK" "$HOME_DIR" "$token" "$log" "$start" \
    </dev/null >/dev/null 2>&1 &
  return 0
}

cmd_stop() {
  cat >/dev/null 2>&1 || true
  [ -d "$DIR" ] || return 0
  set_turn "ended.$(date +%s)" || true
  rm -f "$DIR/count"
  if [ -e "$DIR/capped" ]; then
    rm -f "$DIR/capped"
    status_append "resolved [at=$(date +%s)] [key=$KEY]: Devin finished a turn normally again after the rate limit"
    log_event resolved "a normal turn ended after the retry cap"
  fi
}

cmd_end() {
  cat >/dev/null 2>&1 || true
  [ -d "$DIR" ] || return 0
  set_turn "ended.$(date +%s)" || true
}

cmd_retire() {
  rm -rf -- "$DIR"
}

cmd_watch() {
  local token=$1 log=$2 seen=$3 started now total segment line reset count \
    delay due slot
  started=$(date +%s)
  line=
  while :; do
    sleep "$POLL"
    turn_is "$token" || return 0
    now=$(date +%s)
    [ $((now - started)) -lt "$LIFETIME" ] || return 0
    total=$(line_count "$log")
    [ "$total" -gt "$seen" ] || continue
    segment=$(sed -n "$((seen + 1)),${total}p" "$log" 2>/dev/null)
    seen=$total
    line=$(printf '%s\n' "$segment" | grep -F 'method=session/prompt error=' | grep -i 'rate limit' | tail -1)
    [ -z "$line" ] || break
  done

  reset=$(reset_seconds "$line")
  count=$(retry_count)
  if [ "$count" -ge "$MAX" ]; then
    if [ ! -e "$DIR/capped" ]; then
      : >"$DIR/capped"
      status_append "blocked [at=$(date +%s)] [key=$KEY]: Devin stopped on its model rate limit again after $count automatic retries; send it a message to retry, or move the work to another harness"
    fi
    log_event capped "rate limit after $count automatic retries; reset ${reset}s; no retry sent"
    return 0
  fi
  delay=$((reset + BACKOFF * (1 << count) + RANDOM % (JITTER + 1)))
  due=$(($(date +%s) + delay))
  slot=$(claim_slot "$due")
  log_event detected "reset ${reset}s; retry $((count + 1)) of $MAX at $slot"
  while :; do
    turn_is "$token" || {
      log_event superseded "a new prompt or turn end arrived before retry $((count + 1))"
      return 0
    }
    now=$(date +%s)
    [ "$now" -lt "$slot" ] || break
    if [ $((slot - now)) -lt "$POLL" ]; then sleep $((slot - now)); else sleep "$POLL"; fi
  done
  # The count is written before the send, because the delivered retry starts
  # the next turn whose sentinel reads it, and restored when nothing was sent,
  # so the cap counts only retries the worker actually received.
  printf '%s\n' $((count + 1)) >"$DIR/count.$$" && mv -f "$DIR/count.$$" "$DIR/count"
  if FM_HOME=$HOME_DIR FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-send.sh" "$TASK" "$RETRY_MESSAGE" >/dev/null 2>&1; then
    log_event retried "retry $((count + 1)) of $MAX sent"
  else
    if [ "$count" -eq 0 ]; then
      rm -f "$DIR/count"
    else
      printf '%s\n' "$count" >"$DIR/count.$$" && mv -f "$DIR/count.$$" "$DIR/count"
    fi
    log_event failed "retry $((count + 1)) of $MAX could not be sent through fm-send"
  fi
}

case "$EVENT" in
arm) cmd_arm ;;
stop) cmd_stop ;;
end) cmd_end ;;
retire) cmd_retire ;;
watch) cmd_watch "$@" ;;
*) echo "fm-devin-rate-limit-retry.sh: unknown event '$EVENT'" >&2 ;;
esac
exit 0
