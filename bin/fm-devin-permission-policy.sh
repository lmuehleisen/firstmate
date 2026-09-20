#!/usr/bin/env bash
# fm-devin-permission-policy.sh - firstmate's permission decision layer for
# Devin CLI workers. bin/fm-spawn.sh installs it as native Devin lifecycle
# hooks in the worker's .devin/config.local.json; the script itself and its
# per-task policy file (state/<id>.devin-permission.json) live outside the
# worktree, and Devin reads hooks once at session start, so a worker cannot
# rewrite the policy mid-session.
#
# Usage: fm-devin-permission-policy.sh <event> <policy-file>
#   events: pre-tool-use | permission-request | post-tool-use | stop | retire |
#           repin-grants | judge-probe
#        fm-devin-permission-policy.sh grants-digest <brief-file>
# The Devin hook payload arrives as JSON on stdin (the last three read none).
#
#   pre-tool-use (matcher ^exec$)
#       Refuses the hard-line list for the whole command string, including
#       every && / ; / | segment, $(...) and backtick bodies, bash -c / sh -c /
#       eval strings, find -exec commands, and env / xargs / nohup / timeout
#       wrappers: sudo, launchctl, a git push force in any argument position
#       (--force, --force-with-lease, --force-if-includes, a short-flag
#       cluster containing f, a +refspec, or any push option not on the exact
#       list of known non-force spellings, since git accepts abbreviated long
#       options), a recursive rm whose target, with its existing directory
#       components resolved physically through symlinks, is not strictly
#       inside the worktree or cannot be resolved, any gh repo
#       command, and gh pr create without an explicit --repo / -R.
#       A refusal prints {"decision":"block"} and exits 2; anything else exits
#       0 silently so Devin's own permission layer decides.
#
#   permission-request (every tool)
#       Fires only when Devin would otherwise prompt. Refused commands are
#       blocked here too. A command whose every segment is in the read-and-build
#       set below is approved with {"decision":"approve"}, silently. The
#       residue goes to a cheap first judge on the policy's judge TIER, which
#       for this adapter is the Devin tier unless the policy names another:
#       a headless `devin -p` call on the policy's judge model (SWE-2 High by
#       default), run from an empty directory under the task temp root with the
#       task instructions excerpt and the tool call as data, bounded by the
#       policy's judge timeout. A
#       judge line starting APPROVE approves silently. Anything the judge
#       declines, or a judge that fails, times out, or is disabled, is
#       escalated: a pending marker is written and one needs-decision line
#       naming the exact command and the judge's reason (key
#       devin-permission-<tool-use-slug>) is appended to the task status file,
#       then the hook exits 0 with no output so Devin shows its normal prompt.
#
#   post-tool-use (every tool)
#       When the finished tool call has a pending escalation marker, the call
#       was approved at the prompt: the marker is retired, the outcome logged,
#       and a resolved line closes the decision key.
#
#   stop (Stop, SessionEnd, and UserPromptSubmit)
#       Any escalation still pending when the turn or session ends, or when a
#       new prompt arrives, was not run (declined at the prompt, or cancelled by
#       an interrupt, which fires no Stop): each is logged and closed.
#
#   repin-grants / grants-digest (not Devin hooks)
#       Both belong to the digest pin described under Task grants below.
#       grants-digest prints the digest of a brief's grants block, which
#       bin/fm-spawn.sh records in the policy file at launch. repin-grants
#       rewrites that recorded digest from the brief's current block, which is
#       how FIRSTMATE re-pins grants after editing them on purpose; nothing a
#       worker can reach runs it. Each exits 1 when it cannot do its job.
#
#   judge-probe (not a Devin hook)
#       The measurement seam. Reads the same payload and runs the same static
#       analysis and judge call as permission-request, then prints one line -
#       tier, model, static class, verdict, reason - and writes NOTHING: no
#       verdict cache entry, no pending marker, no status line, no log record.
#       It exists because the judge disagrees with itself often enough that a
#       tier has to be comparable on identical inputs before it is chosen; a
#       harness replays captured payloads through it once per tier and diffs.
#
#   retire (not a Devin hook)
#       bin/fm-spawn.sh runs this when a relaunch retires the Devin wiring, so
#       an escalation left by a worker that died at the prompt is logged and
#       closed as not-run and the pending directory removed while the policy
#       file still names the status file; no later hook could close it.
#       Exits 1 when the pending directory cannot be retired.
#
# The command-policy contract this layer enforces - the hard-refusal list,
# the read-and-build approval set, the protected task briefs, the
# never-approve outward-action class, fetch classification, the recursive-rm
# roots, task grants and their digest pin, the judge retry skeleton, and the
# per-task verdict cache - is owned by bin/fm-command-policy-lib.sh, which
# this adapter sources below; its header holds the shared prose. The judge
# prompt, budget, retry, and verdict parser live there too, and
# bin/fm-judge-tier-lib.sh owns the `devin -p` invocation itself. This file
# owns only the Devin payload schema, the Devin tool-name mapping, the judge
# tier this adapter defaults to, and the Devin decision surface: a refusal
# prints {"decision":"block"} and exits 2, an approval prints
# {"decision":"approve"}, and everything else exits 0 with no output so
# Devin's own permission prompt decides.
#
# Non-exec tools: read / grep / glob / notebook_read are approved unless an
# argument names credential material; write / edit / notebook_edit are
# approved for a file strictly inside the worktree (outside .git/, .devin/,
# and .claude/), the task data directory, the task temp root, a granted write
# directory, or /tmp / $TMPDIR scratch space. Every other tool escalates.
#
# Policy file (written by bin/fm-spawn.sh): JSON object with string fields
# task, worktree, status, inbox, data, tasktmp, brief, log, devin (absolute
# judge executable), judge_model (a `devin models list` id, which encodes the
# effort level, e.g. swe-2-high or swe-2-medium; read on every call, so
# editing it retargets a running worker's judge; empty disables the judge),
# judge_timeout (seconds, the bound on ONE judge attempt), optional judge_tier
# and judge_bin (the judge tier this task runs and its executable; absent
# means this adapter's own Devin tier on the `devin` field above, and a tier
# this build does not know denies rather than falling back), and grants_sha
# (the digest pin the shared library describes). Pending escalation
# markers live in the sibling directory <policy-file minus .json>-pending/,
# and the per-task verdict cache in <policy-file minus .json>-cache/.
# bin/fm-teardown.sh removes both with the policy file.
# With no readable policy file the refusal list still applies (every
# recursive rm is then unresolvable and refused), and permission-request
# falls through to Devin's prompt. Without jq the hook is inert; fm-spawn
# refuses to launch a devin worker when jq is missing.
#
# Exit codes: 0 no objection / approved / recorded; 2 refused (Devin blocks
# the tool call). Any other failure is swallowed so the harness lifecycle
# continues.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

EVENT=${1-}
POLICY=${2-}
case "$EVENT" in
  pre-tool-use|permission-request|post-tool-use|stop|retire|repin-grants|grants-digest|judge-probe) ;;
  *)
    sed -n '9,11s/^# *//p' "${BASH_SOURCE[0]}" >&2
    exit 0
    ;;
esac

# The shared command policy (tokenizer, path helpers, segment and command
# analysis, refusal list, read-and-build set, fetch classification, grants,
# judge skeleton, verdict cache, pending markers).
# shellcheck source=bin/fm-command-policy-lib.sh
. "$SCRIPT_DIR/fm-command-policy-lib.sh"
# The judge budget is pinned per adapter so an inherited JUDGE_BUDGET cannot
# stretch a hook invocation past the timeout the harness grants it; 100s fits
# inside this adapter's 120s permission-hook timeout.
JUDGE_BUDGET=100
# This adapter's identity in the shared judge: the scratch directory the judge
# runs from, the word the prompt uses for the worker it is supervising, and the
# judge tier a per-task policy that names none falls back to.
FM_POLICY_ADAPTER=devin
FM_POLICY_WORKER_LABEL=Devin
FM_JUDGE_TIER_NATIVE=devin

if [ "$EVENT" = grants-digest ]; then
  # fm-spawn asks for the digest of a brief's grants block at launch.
  fm_grants_digest_of_file "$POLICY"
  exit 0
fi
PENDING_DIR='' CACHE_DIR=''
case "$POLICY" in
  *.json) PENDING_DIR="${POLICY%.json}-pending" CACHE_DIR="${POLICY%.json}-cache" ;;
esac
if ! command -v jq >/dev/null 2>&1; then
  # retire cannot close a pending escalation without jq, so it must not
  # report the wiring retired while one is still open.
  [ "$EVENT" = retire ] && [ -n "$PENDING_DIR" ] && [ -d "$PENDING_DIR" ] && exit 1
  exit 0
fi
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# post-tool-use fires for every tool call; stay cheap when nothing is pending.
if [ "$EVENT" = post-tool-use ] || [ "$EVENT" = stop ]; then
  [ -n "$PENDING_DIR" ] && [ -d "$PENDING_DIR" ] || { cat >/dev/null; exit 0; }
  set -- "$PENDING_DIR"/*.pending
  [ -e "${1-}" ] || { cat >/dev/null; exit 0; }
fi
if [ "$EVENT" = retire ]; then
  [ -n "$PENDING_DIR" ] && [ -d "$PENDING_DIR" ] || exit 0
fi

PAYLOAD=
case "$EVENT" in retire|repin-grants) ;; *) PAYLOAD=$(cat) ;; esac

TASK='' WORKTREE='' STATUS='' INBOX='' DATA_DIR='' TASKTMP='' BRIEF='' LOG='' DEVIN='' JUDGE_MODEL='' JUDGE_TIMEOUT='' GRANTS_SHA='' FM_POLICY_JUDGE_TIER='' FM_POLICY_JUDGE_BIN=''
if [ -n "$POLICY" ] && [ -r "$POLICY" ]; then
  {
    IFS= read -r -d '' TASK
    IFS= read -r -d '' WORKTREE
    IFS= read -r -d '' STATUS
    IFS= read -r -d '' INBOX
    IFS= read -r -d '' DATA_DIR
    IFS= read -r -d '' TASKTMP
    IFS= read -r -d '' BRIEF
    IFS= read -r -d '' LOG
    IFS= read -r -d '' DEVIN
    IFS= read -r -d '' JUDGE_MODEL
    IFS= read -r -d '' JUDGE_TIMEOUT
    IFS= read -r -d '' GRANTS_SHA
    IFS= read -r -d '' FM_POLICY_JUDGE_TIER
    IFS= read -r -d '' FM_POLICY_JUDGE_BIN
  } < <(jq -j '[.task, .worktree, .status, .inbox, .data, .tasktmp, .brief, .log, .devin, .judge_model, .judge_timeout, .grants_sha, .judge_tier, .judge_bin]
    | map((. // "") | tostring | gsub("\u0000"; "")) | join("\u0000") + "\u0000"' "$POLICY" 2>/dev/null)
fi
# Which judge answers this task, and the executable it runs. Devin judges Devin
# by default: a policy that names no tier keeps this adapter's own tier on the
# binary above, which is the posture every Devin task has always had.
fm_judge_tier_bind "$FM_JUDGE_TIER_NATIVE" "$DEVIN"

TOOL='' TOOL_USE_ID='' SESSION_ID='' CMD='' FILE_PATH='' INPUT_JSON='' INPUT_STRINGS='' CACHE_INPUT=''
{
  IFS= read -r -d '' TOOL
  IFS= read -r -d '' TOOL_USE_ID
  IFS= read -r -d '' SESSION_ID
  IFS= read -r -d '' CMD
  IFS= read -r -d '' FILE_PATH
  IFS= read -r -d '' INPUT_JSON
  IFS= read -r -d '' INPUT_STRINGS
  IFS= read -r -d '' CACHE_INPUT
} < <(printf '%s' "$PAYLOAD" | jq -j '
  def s: (. // "") | tostring | gsub("\u0000"; "");
  [ (.tool_name | s), (.tool_use_id | s), (.session_id | s),
    (.tool_input.command | s),
    ((.tool_input.file_path // .tool_input.path // .tool_input.notebook_path) | s),
    ((.tool_input // {}) | del(.content?, .new_string?, .old_string?) | tojson | .[0:2000] | s),
    ([(.tool_input // {}) | del(.content?, .new_string?, .old_string?) | .. | strings] | join("\n") | s),
    ((.tool_input // {}) | tojson | s)
  ] | join("\u0000") + "\u0000"' 2>/dev/null)

evaluate_tool() {  # non-exec tools: sets NOT_APPROVABLE
  REFUSE_REASON='' NOT_APPROVABLE='' NEVER_APPROVE=''
  case "$TOOL" in
    read|grep|glob|notebook_read)
      sensitive_text "$INPUT_STRINGS" && no_approve "$TOOL of credential material"
      granted_env_file_text "$INPUT_STRINGS" \
        && no_approve "$TOOL of a credential file this task may only source"
      ;;
    write|edit|notebook_edit)
      local abs rel wt_abs
      [ -n "$FILE_PATH" ] || { no_approve "$TOOL without a file path"; return 0; }
      wt_abs=$(CWD=$WORKTREE write_target_path "$FILE_PATH" 0 2>/dev/null) || wt_abs=''
      if [ -n "$wt_abs" ] && brief_protected "$wt_abs"; then
        refuse "writing this task's own instructions ($FILE_PATH) is refused by firstmate policy"
        return 0
      fi
      sensitive_text "$FILE_PATH" && { no_approve "$TOOL of credential material"; return 0; }
      granted_env_file_text "$FILE_PATH" \
        && { no_approve "$TOOL of a credential file this task may only source"; return 0; }
      abs=$(resolve_path "$FILE_PATH" "$WORKTREE") || { no_approve "$TOOL path unresolvable"; return 0; }
      if strictly_inside "$abs" "$WORKTREE"; then
        rel=${abs#"$(norm_abs "$WORKTREE")"/}
        case "$rel" in
          .git|.git/*|.devin|.devin/*|.claude|.claude/*) no_approve "$TOOL of agent or git configuration" ;;
        esac
      elif ! inside_scratch_write_roots "$abs"; then
        no_approve "$TOOL outside the task write roots"
      fi
      ;;
    *) no_approve "$TOOL is not auto-approved" ;;
  esac
}
case "$EVENT" in
  judge-probe)
    # The measurement seam (not a Devin hook). Same payload, same static
    # analysis, same prompt as a real permission-request - but nothing is
    # written, so a tier comparison leaves no trace in the task's cache,
    # markers, status file, or observer log.
    if [ "$TOOL" = exec ]; then
      evaluate_exec "$CMD"
    else
      evaluate_tool
    fi
    if [ -n "$REFUSE_REASON" ]; then judge_probe refuse
    elif [ -z "$NOT_APPROVABLE" ]; then judge_probe read-and-build
    elif [ -n "$NEVER_APPROVE" ]; then judge_probe never-approve
    else judge_probe residue
    fi
    exit 0
    ;;
  pre-tool-use)
    [ "$TOOL" = exec ] || exit 0
    evaluate_exec "$CMD"
    if [ -n "$REFUSE_REASON" ]; then
      log_record refuse policy "$REFUSE_REASON"
      json_reason block "Blocked by firstmate policy: $REFUSE_REASON"
      exit 2
    fi
    exit 0
    ;;
  permission-request)
    if [ "$TOOL" = exec ]; then
      evaluate_exec "$CMD"
    else
      evaluate_tool
    fi
    if [ -n "$REFUSE_REASON" ]; then
      log_record refuse policy "$REFUSE_REASON"
      json_reason block "Blocked by firstmate policy: $REFUSE_REASON"
      exit 2
    fi
    [ -n "$POLICY" ] && [ -r "$POLICY" ] || exit 0
    if [ -z "$NOT_APPROVABLE" ]; then
      log_record approve policy "read-and-build set"
      json_reason approve "Approved by firstmate policy: read-and-build set"
      exit 0
    fi
    escalate_reason='' escalate_source='first judge'
    if [ -n "$NEVER_APPROVE" ]; then
      # Outward actions skip the judge and the cache entirely, and are never
      # cached at the prompt either, so approving one stays a one-off.
      escalate_reason=$NEVER_APPROVE escalate_source='firstmate policy'
      log_record escalate policy "$NEVER_APPROVE"
    elif cache_lookup; then
      log_record approve cache "$CACHE_REASON (static: $NOT_APPROVABLE)"
      json_reason approve "Approved by firstmate policy cache: $CACHE_REASON"
      exit 0
    else
      run_judge
      if [ "$JUDGE_VERDICT" = approve ]; then
        cache_store "first judge: $JUDGE_REASON"
        log_record approve judge "$JUDGE_REASON (judge: $(fm_judge_attribution), static: $NOT_APPROVABLE)"
        json_reason approve "Approved by firstmate first judge: $JUDGE_REASON"
        exit 0
      fi
      escalate_reason=$JUDGE_REASON
      log_record escalate judge "$JUDGE_REASON (judge: $(fm_judge_attribution), static: $NOT_APPROVABLE)"
    fi
    slug=$(tool_slug)
    key="devin-permission-$slug"
    if [ -n "$PENDING_DIR" ] && mkdir -p "$PENDING_DIR" 2>/dev/null; then
      marker="$PENDING_DIR/$slug.pending"
      if [ ! -e "$marker" ]; then
        ckey=''
        [ -n "$NEVER_APPROVE" ] || ckey=$(cache_key 2>/dev/null || true)
        printf '%s\n%s\n%s\n' "$key" "$(one_line "$(input_summary)" 2000)" "$ckey" \
          > "$marker" 2>/dev/null || true
        status_append "needs-decision [key=$key]: Devin is waiting at a permission prompt for $TOOL ($escalate_source: $(one_line "$escalate_reason" 160)): $(one_line "$(input_summary)" 300)"
      fi
    fi
    exit 0
    ;;
  post-tool-use)
    marker="$PENDING_DIR/$(tool_slug).pending"
    [ -n "$TOOL_USE_ID" ] && [ -f "$marker" ] || exit 0
    close_pending "$marker" approved-at-prompt "the escalated $TOOL call was approved at the prompt and ran"
    exit 0
    ;;
  stop)
    for marker in "$PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      close_pending "$marker" not-run "the escalated call did not run (declined or cancelled at the prompt)"
    done
    exit 0
    ;;
  repin-grants)
    # Firstmate edits a live brief's grants on purpose; this records the new
    # digest so the block is honored again. Nothing a worker can reach runs it.
    [ -n "$POLICY" ] && [ -r "$POLICY" ] && [ -w "$POLICY" ] || {
      echo "fm-devin-permission-policy: cannot repin grants: $POLICY is not writable" >&2
      exit 1
    }
    new_sha=$(grants_digest "$(grants_block)" 2>/dev/null || true)
    if ! jq --arg sha "$new_sha" '.grants_sha = $sha' "$POLICY" > "$POLICY.repin" 2>/dev/null \
      || ! mv "$POLICY.repin" "$POLICY"; then
      rm -f "$POLICY.repin"
      echo "fm-devin-permission-policy: cannot repin grants: $POLICY could not be rewritten" >&2
      exit 1
    fi
    echo "repinned grants digest for ${TASK:-this task}: ${new_sha:-(no grants block)}"
    exit 0
    ;;
  retire)
    for marker in "$PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      close_pending "$marker" not-run "the escalated call did not run (the worker was relaunched)"
    done
    rm -rf -- "$PENDING_DIR" || exit 1
    exit 0
    ;;
esac
exit 0
