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
#       the hook's process ancestry to the first devin process with a
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
#       bin/fm-devin-lib.sh's teardown and relaunch retire: resolves the cap
#       line when one was written, then removes the per-task directory, which
#       also ends any sentinel within one poll.
#   watch (internal; started by arm)
#       Follows the session log until this turn's token is replaced (a new
#       prompt, a Stop, a SessionEnd, or a retire) or a turn-ending rate-limit
#       error appears. On that error it parses the stated reset (60 seconds
#       when none is stated) and schedules one retry at
#         reset + BACKOFF * 2^count + random(0..JITTER)
#       where count is the number of automatic retries already sent since the
#       task's last normal Stop. When that time comes, it also waits until
#       SPACING seconds have passed since the latest retry any worker in this
#       home started or finished sending, recorded in
#       <state-dir>/devin-rate-limit-last-send, so workers that hit the limit
#       together retry apart; when another worker holds that record's lock
#       throughout, the retry goes out unstaggered. It gives up if the turn
#       token changes while it waits, and otherwise sends one ordinary steer
#       through bin/fm-send.sh, so the message lands in the task's durable
#       inbox and the doorbell submit starts the retry turn; a send that fails
#       is logged and not counted. Once count reaches MAX it sends nothing and
#       appends one `blocked [key=devin-rate-limit]` status line instead.
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
LAST_SEND="$STATE/devin-rate-limit-last-send"
SEND_LOCK="$LAST_SEND.lock"
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

# The session log belongs to the `devin` process that runs this hook, so the
# first ancestor that is a devin process with a devin_*_<pid>.log names it;
# other ancestors are skipped even when a reused pid left a log under their
# number, and when one left an older log for the devin pid itself, the most
# recently written one is the live session's.
find_session_log() {
  local pid=$PPID f newest comm _
  for _ in 1 2 3 4 5 6 7 8; do
    case "$pid" in '' | *[!0-9]* | 0 | 1) return 1 ;; esac
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=
    comm=${comm%"${comm##*[! ]}"}
    newest=
    [ "${comm##*/}" = devin ] || {
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      continue
    }
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

# Takes a mkdir lock; fails when its directory is gone. A holder that died
# leaves the lock behind, and every section these locks guard takes
# milliseconds, so one older than 5 seconds is abandoned well inside the
# 10-second wait, and only a holder re-taking it throughout can outlast that.
take_lock() {  # <lock-path>
  local held _
  for _ in $(seq 1 50); do
    mkdir "$1" 2>/dev/null && return 0
    [ -d "${1%/*}" ] || return 1
    held=$(fm_lock_path_mtime "$1") || held=
    case "$held" in '' | *[!0-9]*) ;; *) [ $(($(date +%s) - held)) -le 5 ] || rmdir "$1" 2>/dev/null || true ;; esac
    sleep 0.2
  done
  return 1
}

# The home-wide lock around the last-send record.
send_lock() {
  take_lock "$SEND_LOCK"
}

send_unlock() {
  rmdir "$SEND_LOCK" 2>/dev/null || true
}

# The epoch of the latest retry send any worker in this home started or
# finished. A send still in flight - its record names a live sender pid, for
# at most 300 seconds - counts as happening now. A real send records at most
# one second ahead, so anything later is not trusted to hold others back.
last_send() {
  local last pid now
  read -r last pid <"$LAST_SEND" 2>/dev/null || last=0
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  now=$(date +%s)
  case "${pid-}" in
  '' | *[!0-9]*) ;;
  *) ! kill -0 "$pid" 2>/dev/null || [ $((now - last)) -ge 300 ] || last=$((now + 1)) ;;
  esac
  [ "$last" -le $((now + 1)) ] || last=$((now + 1))
  printf '%s' "$last"
}

# Records a send at the current second rounded up, never moving the record
# back, marked in flight by this process until the finishing call; the
# caller holds the lock.
record_send() {  # [in-flight]
  local at last
  at=$(($(date +%s) + 1))
  last=$(last_send)
  [ "$at" -ge "$last" ] || at=$last
  printf '%s%s\n' "$at" "${1:+ $$}" >"$LAST_SEND.$$" && mv -f "$LAST_SEND.$$" "$LAST_SEND"
}

# Waits until SPACING has passed since the latest retry send in this home, then
# records this send's start under the lock so no other worker starts inside
# the gap. Fails when the turn's token is replaced first. When a live holder
# keeps the lock throughout, it goes ahead unstaggered and records nothing.
take_send_turn() {  # <token>
  while :; do
    wait_turn_until "$1" $(($(last_send) + SPACING)) || return 1
    send_lock || {
      log_event unstaggered "the retry send lock stayed held; retry sent without home-wide spacing"
      turn_is "$1"
      return
    }
    turn_is "$1" || {
      send_unlock
      return 1
    }
    if [ "$(date +%s)" -ge $(($(last_send) + SPACING)) ]; then
      record_send in-flight
      send_unlock
      return 0
    fi
    send_unlock
  done
}

cmd_arm() {
  local token log start locked=
  cat >/dev/null 2>&1 || true
  token="$(date +%s).$$.$RANDOM"
  # The turn is replaced even without the lock, because keeping the old token
  # would let the previous turn's sentinel send its retry into this one.
  ! task_lock || locked=1
  set_turn "$token" || {
    [ -z "$locked" ] || task_unlock
    return 0
  }
  [ -z "$locked" ] || task_unlock
  if ! log=$(find_session_log); then
    log_event unarmed "no Devin session log found in $LOG_DIR for the hook's process ancestry"
    return 0
  fi
  start=$(line_count "$log")
  nohup "$SELF" watch "$STATE" "$TASK" "$HOME_DIR" "$token" "$log" "$start" \
    </dev/null >/dev/null 2>&1 &
  return 0
}

# The per-task lock that orders the cap line against a new prompt, Stop, and
# retire, so a sentinel publishes a cap only for a turn that is still current
# and whichever hook retires that turn sees the cap and resolves it. Only these
# short sections take it, never a send.
task_lock() {
  take_lock "$DIR/.lock"
}

task_unlock() {
  rmdir "$DIR/.lock" 2>/dev/null || true
}

cmd_stop() {
  local locked=
  cat >/dev/null 2>&1 || true
  [ -d "$DIR" ] || return 0
  ! task_lock || locked=1
  set_turn "ended.$(date +%s)" || true
  rm -f "$DIR/count"
  if [ -e "$DIR/capped" ]; then
    rm -f "$DIR/capped"
    status_append "resolved [at=$(date +%s)] [key=$KEY]: Devin finished a turn normally again after the rate limit"
    log_event resolved "a normal turn ended after the retry cap"
  fi
  [ -z "$locked" ] || task_unlock
}

cmd_end() {
  cat >/dev/null 2>&1 || true
  [ -d "$DIR" ] || return 0
  set_turn "ended.$(date +%s)" || true
}

cmd_retire() {
  [ -d "$DIR" ] || return 0
  # The lock goes with the directory, so it is never released here.
  task_lock || true
  if [ -e "$DIR/capped" ]; then
    status_append "resolved [at=$(date +%s)] [key=$KEY]: the rate-limited Devin worker was relaunched or retired"
    log_event resolved "the retry state was retired after the retry cap"
  fi
  rm -rf -- "$DIR"
}

# Sleeps until <epoch>; fails as soon as this turn's token is replaced.
wait_turn_until() {  # <token> <epoch>
  local now
  while :; do
    turn_is "$1" || return 1
    now=$(date +%s)
    [ "$now" -lt "$2" ] || return 0
    if [ $(($2 - now)) -lt "$POLL" ]; then sleep $(($2 - now)); else sleep "$POLL"; fi
  done
}

cmd_watch() {
  local token=$1 log=$2 seen=$3 started now total segment line reset count \
    delay due
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
    # Published only while this turn is still current, under the lock a new
    # prompt, Stop, and retire take, so the turn's end always sees the cap.
    task_lock || {
      [ ! -d "$DIR" ] || log_event failed "the task's retry lock stayed held; the retry cap was not published"
      return 0
    }
    if turn_is "$token"; then
      if [ ! -e "$DIR/capped" ]; then
        : >"$DIR/capped"
        status_append "blocked [at=$(date +%s)] [key=$KEY]: Devin stopped on its model rate limit again after $count automatic retries; send it a message to retry, or move the work to another harness"
      fi
      log_event capped "rate limit after $count automatic retries; reset ${reset}s; no retry sent"
    fi
    task_unlock
    return 0
  fi
  delay=$((reset + BACKOFF * (1 << count) + RANDOM % (JITTER + 1)))
  due=$(($(date +%s) + delay))
  log_event detected "reset ${reset}s; retry $((count + 1)) of $MAX due at $due"
  # Spacing is taken only once this retry is due and measured from real
  # sends, so a longer reset detected first, or a retry later superseded,
  # never delays another worker's.
  if ! wait_turn_until "$token" "$due" || ! take_send_turn "$token"; then
    log_event superseded "a new prompt or turn end arrived before retry $((count + 1))"
    return 0
  fi
  # Accepted residual race: a prompt submitted between the turn check above
  # and fm-send's enqueue still receives this retry, a harmless extra "continue"
  # steer. Holding a lock across the send that the arm hook waits on would
  # instead stall the retry's own doorbell, whose submit fires that hook while
  # fm-send is still ringing.
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
  # The gap to the next worker's retry counts from when this send finished.
  if send_lock; then
    record_send
    send_unlock
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
