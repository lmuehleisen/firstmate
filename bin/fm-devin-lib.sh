#!/usr/bin/env bash
# fm-devin-lib.sh - the fork's Devin worker wiring for bin/fm-spawn.sh and
# bin/fm-teardown.sh. Sourced, never executed.
#
# Kept out of the upstream-owned spawn and teardown scripts so a weekly
# upstream merge meets one-line call sites there instead of the whole Devin
# arm. Each function below is the code those scripts ran inline before, moved
# unchanged; the harness-adapters devin reference owns the operating facts and
# bin/fm-devin-permission-policy.sh owns the permission policy.
#
#   resolve_devin_binary
#       prints the absolute devin executable, or refuses when none is on PATH
#   fm_devin_permission_flags <crew-permission-mode>
#       prints the launch permission flags for auto or manual
#   fm_devin_spawn_wire
#       writes the task's .devin wiring and permission policy file (spawn)
#   fm_devin_relaunch_retire_policy <harness> <state-dir> <id>
#   fm_devin_relaunch_path_kept <harness> <worktree> <path>
#   fm_devin_relaunch_retire_dirs <harness> <worktree>
#       the relaunch retire steps bin/fm-spawn.sh's clear_relaunch_harness_wiring
#       runs around its shared wiring-path removal
#   remove_devin_managed_wiring <meta> <worktree>
#       teardown's retire of the two managed worktree files
#   fm_devin_teardown_remove_state <state-dir> <id>
#       teardown's removal of the per-task permission policy state
#
# fm_devin_spawn_wire runs inside bin/fm-spawn.sh after the busy-state arm and
# reads that script's globals rather than taking them as arguments: RAW_LAUNCH,
# WT, STATE_REAL, ID, BUSY_GEN, TURNEND, TASK_TMP, BRIEF, FM_ROOT, SCRIPT_DIR,
# and DEVIN_BIN, plus its shell_quote, json_escape, and exclude_path helpers.
# It exits the spawn on a refusal, exactly as the inline arm did.
# remove_devin_managed_wiring reads the harness through bin/fm-teardown.sh's
# meta_value, and both retire paths rely on bin/fm-control-lib.sh's
# fm_control_devin_wiring_owned and fm_control_harness_wiring_dirs.

# devin ships as a standalone CLI executable. It is resolved to an absolute path
# once here so the pane launches the same executable this spawn checked, and a
# missing install refuses BEFORE any endpoint or worktree exists rather than
# leaving a pane at a "command not found" shell.
resolve_devin_binary() {
  local candidate dir
  candidate=$(command -v devin 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
    /*)
      printf '%s\n' "$candidate"
      return 0
      ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
      if [ -n "$dir" ]; then
        printf '%s/%s\n' "$dir" "$(basename "$candidate")"
        return 0
      fi
      ;;
    esac
  fi
  echo "error: devin executable not found on PATH; install the Devin CLI or select a different verified harness" >&2
  return 1
}

# devin (Devin CLI): auto selects --permission-mode smart, which uses a
# fast model to judge safety and auto-approves workspace edits while
# mutating git commands and in-repo scripts prompt. Firstmate pre-allows
# the approved routine command and task-scoped write set in
# .devin/config.local.json. manual selects --permission-mode normal,
# prompting for all writes and shell commands. Neither setting ever
# reaches dangerous / bypass or sandbox autonomous mode.
fm_devin_permission_flags() {  # <crew-permission-mode>
  case "${1-}" in
  auto) printf '%s' '--permission-mode smart' ;;
  manual) printf '%s' '--permission-mode normal' ;;
  *) return 1 ;;
  esac
}

fm_devin_spawn_wire() {
  local managed busy_cmd_prefix busy_suffix d_submit d_stop d_sessionend \
    devin_task_data d_write_status d_write_inbox d_write_tmp devin_policy \
    devin_grants_sha policy_cmd policy_file d_pre d_perm d_post d_policy_stop
  [ "$RAW_LAUNCH" -eq 0 ] || return 0
  # Semantic busy-state hooks (bin/fm-busy-lib.sh): UserPromptSubmit opens
  # a turn (busy); Stop and SessionEnd close it (idle). SessionStart is
  # omitted so resume does not leave a false busy on an idle composer.
  # Stop keeps the turn-ended NOTIFICATION touch for the watcher.
  # An interrupt leaves the record busy (same as agy and Claude).
  # Devin CLI reads .devin/config.local.json in the worktree root, which
  # merges with project and user settings without clobbering tracked hooks
  # or replacing ~/.config/devin/config.json (captain decision D2).
  # permissions.allow carries the captain-approved non-destructive Exec
  # set (decision D1, extended 2026-09-14) and permissions.deny pins the
  # git push force spellings back out of the allowed Exec(git push)
  # prefix; the harness-adapters devin reference owns the list and the
  # Exec matching limits. "attribution": false is documented user-scope
  # only, so the same no-attribution policy is also installed as the
  # always-on rule .devin/rules/firstmate-attribution.md.
  # PreToolUse, PermissionRequest, PostToolUse, UserPromptSubmit, Stop, and
  # SessionEnd also run bin/fm-devin-permission-policy.sh, firstmate's permission
  # decision layer (refuse list, read-and-build approvals, SWE-2 High first
  # judge, escalation to the status file); its header owns the policy. The
  # script and its per-task policy file under state/ live outside the
  # worktree, and Devin reads hooks once at session start.
  for managed in .devin/config.local.json .devin/rules/firstmate-attribution.md; do
    if git -C "$WT" ls-files --error-unmatch "$managed" >/dev/null 2>&1; then
      echo "error: cannot spawn devin worker: $WT/$managed is tracked by git" >&2
      exit 1
    fi
    if [ -e "$WT/$managed" ] || [ -L "$WT/$managed" ]; then
      echo "error: cannot spawn devin worker: $WT/$managed already exists as an untracked leftover" >&2
      exit 1
    fi
  done
  command -v jq >/dev/null 2>&1 || {
    echo "error: cannot spawn devin worker: jq is required by the devin permission policy hook; install jq or select a different verified harness" >&2
    exit 1
  }
  mkdir -p "$WT/.devin/rules"
  busy_cmd_prefix="$(shell_quote "$FM_ROOT/bin/fm-busy-event.sh") apply $(shell_quote "$STATE_REAL") $(shell_quote "$ID")"
  busy_suffix="--gen $(shell_quote "$BUSY_GEN") --source devin-hook"
  d_submit=$(json_escape "$busy_cmd_prefix busy $busy_suffix --event user-prompt-submit >/dev/null 2>&1 || true")
  d_stop=$(json_escape "touch $(shell_quote "$TURNEND"); $busy_cmd_prefix idle $busy_suffix --event stop >/dev/null 2>&1 || true")
  d_sessionend=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event session-end >/dev/null 2>&1 || true")
  devin_task_data=$(cd "$(dirname "$BRIEF")" && pwd -P)
  # The task data directory deliberately gets NO blanket Write allow: the
  # brief lives there, and an allow rule would let the worker rewrite its
  # own instructions and grants without the permission hook ever seeing
  # it. Data-directory writes instead reach PermissionRequest, where
  # bin/fm-devin-permission-policy.sh approves them silently and refuses
  # the brief.
  d_write_status=$(json_escape "Write($STATE_REAL/$ID.status)")
  d_write_inbox=$(json_escape "Write($STATE_REAL/$ID.inbox)")
  d_write_tmp=$(json_escape "Write($TASK_TMP)")
  devin_policy="$STATE_REAL/$ID.devin-permission.json"
  # The digest pins the grants block firstmate wrote, so a block the
  # worker adds or edits in its own brief grants nothing.
  devin_grants_sha=$("$SCRIPT_DIR/fm-devin-permission-policy.sh" grants-digest "$BRIEF" 2>/dev/null || true)
  jq -n --arg task "$ID" --arg worktree "$(cd "$WT" && pwd -P)" \
    --arg status "$STATE_REAL/$ID.status" --arg inbox "$STATE_REAL/$ID.inbox" \
    --arg data "$devin_task_data" --arg tasktmp "$TASK_TMP" --arg brief "$BRIEF" \
    --arg log "$STATE_REAL/devin-permission-log.jsonl" --arg devin "${DEVIN_BIN:-}" \
    --arg grants_sha "$devin_grants_sha" \
    '{task:$task, worktree:$worktree, status:$status, inbox:$inbox, data:$data, tasktmp:$tasktmp, brief:$brief, log:$log, devin:$devin, judge_model:"swe-2-high", judge_timeout:"60", grants_sha:$grants_sha}' \
    >"$devin_policy" || {
    echo "error: cannot spawn devin worker: could not write $devin_policy" >&2
    exit 1
  }
  policy_cmd="$(shell_quote "$FM_ROOT/bin/fm-devin-permission-policy.sh")"
  policy_file=$(shell_quote "$devin_policy")
  d_pre=$(json_escape "$policy_cmd pre-tool-use $policy_file")
  d_perm=$(json_escape "$policy_cmd permission-request $policy_file")
  d_post=$(json_escape "$policy_cmd post-tool-use $policy_file")
  d_policy_stop=$(json_escape "$policy_cmd stop $policy_file")
  cat >"$WT/.devin/config.local.json" <<EOF
{"permissions":{"allow":["Exec(git add)","Exec(git commit)","Exec(git push)","Exec(git checkout)","Exec(git remote)","Exec(git fetch)","Exec(git status)","Exec(git log)","Exec(git diff)","Exec(ls)","Exec(gh pr create)","Exec(gh pr view)","Exec(gh pr list)","Exec(gh pr checks)","Exec(bin/fm-lint.sh)","Exec(./bin/fm-lint.sh)","Exec(bash bin/fm-lint.sh)","Exec(bin/fm-test-run.sh)","Exec(./bin/fm-test-run.sh)","Exec(bash bin/fm-test-run.sh)","Exec(bin/fm-install-shellcheck.sh)","Exec(./bin/fm-install-shellcheck.sh)","Exec(bash bin/fm-install-shellcheck.sh)","Exec(bin/fm-install-actionlint.sh)","Exec(./bin/fm-install-actionlint.sh)","Exec(bash bin/fm-install-actionlint.sh)","$d_write_status","$d_write_inbox","$d_write_tmp"],"deny":["Exec(git push --force)","Exec(git push --force-with-lease)","Exec(git push --force-if-includes)","Exec(git push -f)"]},"attribution":false,"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$d_submit"},{"type":"command","command":"$d_policy_stop","timeout":30}]}],"Stop":[{"hooks":[{"type":"command","command":"$d_stop"},{"type":"command","command":"$d_policy_stop","timeout":30}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"$d_sessionend"},{"type":"command","command":"$d_policy_stop","timeout":30}]}],"PreToolUse":[{"matcher":"^exec$","hooks":[{"type":"command","command":"$d_pre","timeout":30}]}],"PermissionRequest":[{"matcher":"","hooks":[{"type":"command","command":"$d_perm","timeout":120}]}],"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"$d_post","timeout":30}]}]}}
EOF
  cat >"$WT/.devin/rules/firstmate-attribution.md" <<'EOF'
---
description: Firstmate worker attribution policy
trigger: always_on
---
Never add "Generated with Devin", "Co-Authored-By: Devin", or any other tool attribution line or trailer to commit messages or pull request bodies.
EOF
  exclude_path '.devin/config.local.json'
  exclude_path '.devin/rules/firstmate-attribution.md'
}

# Relaunch retire, before the shared wiring paths go: the policy's retire
# closes every pending escalation while the policy file still names the
# status file.
fm_devin_relaunch_retire_policy() {  # <harness> <state-dir> <id>
  [ "${1-}" = devin ] || return 0
  "$SCRIPT_DIR/fm-devin-permission-policy.sh" retire "$2/$3.devin-permission.json" </dev/null
}

# A worktree-resident devin path still needs the shared ownership proof: a
# file git tracks there is the project's own, not this incarnation's
# wiring, and a blind rm would strand a dirty worktree missing it.
# Returns 0 when the path must be kept rather than removed.
fm_devin_relaunch_path_kept() {  # <harness> <worktree> <path>
  local harness=${1-} wt=${2-} path=${3-}
  [ "$harness" = devin ] && [ "${path#"$wt"/}" != "$path" ] || return 1
  ! fm_control_devin_wiring_owned devin "$wt" "${path#"$wt"/}"
}

# Directories the retired wiring lived in go with it, but only while empty;
# rmdir's own check protects any project content sharing the path.
fm_devin_relaunch_retire_dirs() {  # <harness> <worktree>
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rmdir "$path" 2>/dev/null || true
  done <<EOF
$(fm_control_harness_wiring_dirs "$1" "$2")
EOF
}

# Retire fm-spawn's two managed .devin wiring files - config.local.json and
# rules/firstmate-attribution.md - only where they are provably firstmate's;
# bin/fm-control-lib.sh's fm_control_devin_wiring_owned owns that proof (a path
# git tracks is the project's own and never goes, whatever the recorded
# harness). The directories the files emptied still leave only while empty.
remove_devin_managed_wiring() {  # <meta> <worktree>
  local meta=$1 wt=$2 harness rel
  harness=$(meta_value "$meta" harness)
  for rel in .devin/config.local.json .devin/rules/firstmate-attribution.md; do
    if fm_control_devin_wiring_owned "$harness" "$wt" "$rel"; then
      rm -f -- "$wt/$rel"
    fi
  done
  rmdir "$wt/.devin/rules" "$wt/.devin" 2>/dev/null || true
}

# The per-task policy file, plus the permission-policy escalation markers and
# verdict cache (bin/fm-devin-permission-policy.sh).
fm_devin_teardown_remove_state() {  # <state-dir> <id>
  rm -f "$1/$2.devin-permission.json"
  rm -rf "$1/$2.devin-permission-pending" "$1/$2.devin-permission-cache"
}
