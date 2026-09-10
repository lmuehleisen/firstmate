#!/usr/bin/env bash
# Agy native-hook transport and worker installation.
# Usage: fm-agy-hook.sh install-worker <state> <id> <gen> <worktree>
#        fm-agy-hook.sh retire-worker <state> <id>
#        fm-agy-hook.sh worker <PreInvocation|Stop> <state> <id> <gen> <worktree>
#        fm-agy-hook.sh primary <PreInvocation|PreToolUse|Stop>
#
# Hook calls consume Agy's camelCase JSON on stdin and always return one JSON
# object with exit 0. Invalid payloads are inert. Primary scope, startup nudges,
# turn-end predicates, and pre-tool decisions remain with their existing owners.
# Stop executionNum > 0 maps to the shared one-continuation loop guard.
# Agy's Stop does not fire on manual interruption; neither a key nor a rendered
# footer manufactures idle. PreInvocation opens busy and fullyIdle Stop closes.
#
# install-worker writes ONLY state/<id>.agy-hooks/.agents/hooks.json and an
# ownership marker. Spawn grants that directory separately, so the project's
# own .agents/hooks.json is never rewritten. Each generation latches the first
# PreInvocation conversation id; subagent callbacks cannot settle its parent.
# A retired generation can write only its own session binding and is refused by
# fm-busy-event.sh before publishing state or a turn-ended wake.
# retire-worker removes only that marked, non-symlink adapter directory.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MODE=${1:-}
shift || exit 2

usage() {
  sed -n '3,6s/^# *//p' "$SCRIPT_DIR/fm-agy-hook.sh" >&2
  exit 2
}
token_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

case "$MODE" in
  install-worker|retire-worker)
    [ "$#" -ge 2 ] || usage
    state=$1 id=$2
    token_valid "$id" && [ -d "$state" ] || usage
    state=$(cd "$state" && pwd -P) || exit 1
    dir="$state/$id.agy-hooks"
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      [ ! -L "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir/.firstmate-owned" ] \
        && [ "$(cat "$dir/.firstmate-owned" 2>/dev/null)" = "$id" ] || {
        echo "error: refusing unowned agy hook directory: $dir" >&2
        exit 1
      }
    fi
    if [ "$MODE" = retire-worker ]; then
      [ "$#" -eq 2 ] || usage
      rm -rf -- "$dir"
      exit
    fi
    [ "$#" -eq 4 ] || usage
    gen=$3 wt=$4
    token_valid "$gen" && [ -d "$wt" ] || usage
    command -v jq >/dev/null 2>&1 || { echo 'error: agy hooks require jq' >&2; exit 1; }
    wt=$(cd "$wt" && pwd -P) || exit 1
    [ ! -L "$dir/.agents" ] && [ ! -L "$dir/.agents/hooks.json" ] || exit 1
    mkdir -p "$dir/.agents" || exit 1
    printf '%s\n' "$id" > "$dir/.firstmate-owned" || exit 1
    prefix="$(shell_quote "$SCRIPT_DIR/fm-agy-hook.sh") worker"
    suffix="$(shell_quote "$state") $(shell_quote "$id") $(shell_quote "$gen") $(shell_quote "$wt")"
    tmp=$(mktemp "$dir/.agents/.hooks.XXXXXX") || exit 1
    if ! jq -n --arg open "$prefix PreInvocation $suffix" --arg close "$prefix Stop $suffix" \
      '{"firstmate-worker":{PreInvocation:[{command:$open}],Stop:[{command:$close}]}}' > "$tmp"; then
      rm -f "$tmp"; exit 1
    fi
    mv -- "$tmp" "$dir/.agents/hooks.json" || { rm -f "$tmp"; exit 1; }
    exit 0
    ;;
  worker|primary) ;;
  -h|--help) sed -n '3,6s/^# *//p' "$SCRIPT_DIR/fm-agy-hook.sh"; exit 0 ;;
  *) usage ;;
esac

event=${1:-}
shift || usage
payload=$(cat 2>/dev/null || true)
empty() {
  if [ "$event" = PreToolUse ]; then
    printf '{"decision":"ask"}\n'
  else
    printf '{}\n'
  fi
  exit 0
}
command -v jq >/dev/null 2>&1 || empty
conversation=$(printf '%s' "$payload" | jq -er '.conversationId | select(type == "string")' 2>/dev/null) || empty
token_valid "$conversation" || empty

if [ "$MODE" = worker ]; then
  [ "$#" -eq 4 ] || usage
  state=$1 id=$2 gen=$3 wt=$4
  token_valid "$id" || empty
  token_valid "$gen" || empty
  dir="$state/$id.agy-hooks"
  [ ! -L "$dir" ] && [ -d "$dir" ] || empty
  [ "$(cat "$dir/.firstmate-owned" 2>/dev/null)" = "$id" ] || empty
  [ "$(cat "$state/$id.busy-gen" 2>/dev/null)" = "$gen" ] || empty
  printf '%s' "$payload" | jq -e --arg wt "$wt" \
    '.workspacePaths | type == "array" and index($wt) != null' >/dev/null 2>&1 || empty
  binding="$dir/$gen.session"
  [ ! -L "$binding" ] || empty
  if [ "$event" = PreInvocation ] && [ ! -e "$binding" ]; then
    (set -C; printf '%s\n' "$conversation" > "$binding") 2>/dev/null || true
  fi
  [ "$(cat "$binding" 2>/dev/null)" = "$conversation" ] || empty
  case "$event" in
    PreInvocation)
      "$SCRIPT_DIR/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
        --source agy-hook --event pre-invocation >/dev/null 2>&1 || true
      ;;
    Stop)
      printf '%s' "$payload" | jq -e '.fullyIdle == true' >/dev/null 2>&1 || empty
      if "$SCRIPT_DIR/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
        --source agy-hook --event stop >/dev/null 2>&1; then
        touch "$state/$id.turn-ended" 2>/dev/null || true
      fi
      ;;
  esac
  empty
fi

[ "$#" -eq 0 ] || usage
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || empty
printf '%s' "$payload" | jq -e --arg root "$(cd "$FM_ROOT" && pwd -P)" \
  '.workspacePaths | type == "array" and index($root) != null' >/dev/null 2>&1 || empty

case "$event" in
  PreInvocation)
    # Injecting on later model invocations continually preempts pending tools.
    # Nudge only the opening invocation of a user/background execution cycle.
    printf '%s' "$payload" | jq -e '.invocationNum == 0' >/dev/null 2>&1 || empty
    nudge=$("$SCRIPT_DIR/fm-sessionstart-nudge.sh" 2>/dev/null || true)
    [ -n "$nudge" ] || empty
    jq -n --arg text "$nudge" '{injectSteps:[{ephemeralMessage:$text}]}'
    ;;
  Stop)
    mapped=$(printf '%s' "$payload" | jq -ec '
      select((.executionNum | type) == "number" and .executionNum >= 0
        and .executionNum == (.executionNum | floor) and (.fullyIdle | type) == "boolean")
      | {session_id:.conversationId, stop_hook_active:(.executionNum > 0)}' 2>/dev/null) || empty
    result=$(printf '%s' "$mapped" | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>&1)
    rc=$?
    [ "$rc" -eq 2 ] || empty
    jq -n --arg reason "$result" '{decision:"continue",reason:$reason}'
    ;;
  PreToolUse)
    tool=$(printf '%s' "$payload" | jq -er '.toolCall.name | select(type == "string")' 2>/dev/null) || empty
    result=$("$SCRIPT_DIR/fm-subagent-pretool-check.sh" --tool "$tool" --claude 2>&1)
    rc=$?
    if [ "$rc" -ne 2 ] && [ "$tool" = run_command ]; then
      cmd=$(printf '%s' "$payload" | jq -er '.toolCall.args.CommandLine | select(type == "string")' 2>/dev/null) || empty
      result=$("$SCRIPT_DIR/fm-arm-pretool-check.sh" --command "$cmd" --claude 2>&1)
      rc=$?
      if [ "$rc" -ne 2 ]; then
        result=$("$SCRIPT_DIR/fm-cd-pretool-check.sh" --command "$cmd" --claude 2>&1)
        rc=$?
      fi
    fi
    if [ "$rc" -eq 2 ]; then
      jq -n --arg reason "$result" '{decision:"deny",reason:$reason}'
    else
      # The required ask decision preserves review and existing user grants.
      # Never emit decision=allow: that would bypass Agy's ordinary review.
      empty
    fi
    ;;
  *) empty ;;
esac
exit 0
