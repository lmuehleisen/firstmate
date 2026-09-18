#!/usr/bin/env bash
# tests/fm-agy-permission-policy.test.sh - behavior of the agy bypass-mode
# permission decision layer (bin/fm-agy-permission-policy.sh) driven through
# its public interface: agy-shaped camelCase JSON payloads on stdin, the
# per-task policy file, and the observable stdout decision, status file,
# pending markers, verdict cache, and observer-log records. Covers the armed
# heartbeat the spawn canary polls, the hard-refusal list holding under
# bypass, the read-and-build and task-local abstentions (an approval IS no
# output - agy cannot silently approve through a hook), the native file-write
# tool mapping, every judge outcome denied rather than abstained, the
# firstmate approve/decline resolution including declined-retry suppression
# and held-call retry dedup, pending closure on post-tool-use and retire but
# NOT on Stop, the grants digest pin, the workspace scoping guard, and the
# no-policy and unparseable-payload failure modes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

POLICY_SH="$ROOT/bin/fm-agy-permission-policy.sh"
HOOK_SH="$ROOT/bin/fm-agy-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-permission-policy)

command -v jq >/dev/null 2>&1 || {
  printf 'skip - fm-agy-permission-policy: jq not installed\n'
  exit 0
}

# new_case <name> [judge-script-body] [grants-json]: builds a home with a
# worktree, status, inbox, data dir, temp root, and policy file; prints the
# policy path. The judge is a fake `agy` executable: the adapter invokes it
# as `agy -p <prompt> --model <m> --disable-slash-commands --sandbox`.
new_case() {
  local name=$1 judge_body=${2-} grants=${3-} dir wt judge=''
  dir="$TMP_ROOT/$name"
  wt="$dir/wt"
  mkdir -p "$wt" "$dir/state/t1.inbox/handled" "$dir/data/t1" "$dir/tmp"
  wt=$(cd "$wt" && pwd -P)
  if [ -n "$judge_body" ]; then
    judge="$dir/bin/agy"
    mkdir -p "$dir/bin"
    printf '#!/usr/bin/env bash\n%s\n' "$judge_body" > "$judge"
    chmod +x "$judge"
  fi
  cat > "$dir/data/t1/brief.md" <<'EOF'
# Task
## Captain's intent
Fix the flaky test.

## Firstmate spec
Keep the change narrow.
EOF
  if [ -n "$grants" ]; then
    local fence
    fence=$(printf '\140\140\140')
    printf '\n%sfirstmate-grants\n%s\n%s\n' "$fence" "$grants" "$fence" >> "$dir/data/t1/brief.md"
  fi
  cat >> "$dir/data/t1/brief.md" <<'EOF'

# Setup
Not part of the excerpt.
EOF
  local sha
  sha=$("$POLICY_SH" grants-digest "$dir/data/t1/brief.md" 2>/dev/null || true)
  jq -n --arg wt "$wt" --arg d "$dir" --arg judge "$judge" --arg sha "$sha" \
    '{task:"t1", worktree:$wt, status:($d+"/state/t1.status"), inbox:($d+"/state/t1.inbox"),
      data:($d+"/data/t1"), tasktmp:($d+"/tmp"), brief:($d+"/data/t1/brief.md"),
      log:($d+"/state/agy-permission-log.jsonl"), agy:$judge,
      judge_model:(if $judge == "" then "" else "gemini-3.6-flash-low" end), judge_timeout:"5",
      grants_sha:$sha}' \
    > "$dir/state/t1.agy-permission.json"
  printf '%s\n' "$dir/state/t1.agy-permission.json"
}

# hook <policy> <event> <tool> <arg> [step-idx] [extra-args-json]: sets OUT and
# RC. <arg> is the command line for run_command and the file path or query for
# the other tools.
hook() {
  local policy=$1 event=$2 tool=$3 arg=$4 step=${5:-1} extra=${6-} payload
  payload=$(jq -nc --arg t "$tool" --arg a "$arg" --argjson s "$step" \
    --argjson x "${extra:-null}" --arg wt "$(jq -r .worktree "$policy")" '
    {conversationId:"c1", stepIdx:$s, modelName:"fake-model",
     workspacePaths:[$wt],
     toolCall:{name:$t, args:(
       (if $t == "run_command" then {CommandLine:$a, Cwd:$wt}
        elif $t == "write_to_file" or $t == "replace_file_content" or $t == "view_file"
          then {AbsolutePath:$a, Content:"x"}
        elif $t == "search_web" or $t == "read_url_content" then {Query:$a}
        else {Input:$a} end)
       + (if $x == null then {} else $x end))}}')
  OUT=$(printf '%s' "$payload" | "$POLICY_SH" "$event" "$policy" 2>/dev/null)
  RC=$?
}

case_dir() { dirname "$(dirname "$1")"; }

denied() {  # <out> [reason-fragment]
  [ "$(printf '%s' "$1" | jq -r .decision 2>/dev/null)" = deny ] || return 1
  [ $# -lt 2 ] || printf '%s' "$1" | jq -r .reason 2>/dev/null | grep -qF "$2"
}

abstained() { [ -z "$1" ]; }

test_armed_heartbeat_proves_wiring() {
  local policy dir log
  policy=$(new_case armed)
  dir=$(case_dir "$policy")
  log="$dir/state/agy-permission-log.jsonl"
  jq -nc --arg wt "$(jq -r .worktree "$policy")" \
    '{conversationId:"c1",workspacePaths:[$wt]}' \
    | "$POLICY_SH" armed "$policy" >/dev/null 2>&1
  [ "$(jq -r 'select(.event == "armed") | .task' "$log" 2>/dev/null)" = t1 ] \
    || fail "the armed heartbeat must land on the observer log: $(cat "$log" 2>/dev/null)"
  jq -nc --arg wt "$(jq -r .worktree "$policy")" \
    '{conversationId:"c1",workspacePaths:[$wt]}' \
    | "$POLICY_SH" armed "$policy" >/dev/null 2>&1
  [ "$(jq -s 'map(select(.event == "armed")) | length' "$log")" = 1 ] \
    || fail "the armed heartbeat must write exactly once per generation: $(cat "$log")"
  pass "fm-agy-permission-policy: the armed heartbeat proves live wiring exactly once"
}

test_refusal_list_denies() {
  local policy cmd
  policy=$(new_case refuse)
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use run_command "$cmd"
    denied "$OUT" || fail "pre-tool-use must deny '$cmd' even under bypass, got rc=$RC out=$OUT"
  done <<'EOF'
sudo ls
ls && sudo rm x
env FOO=1 sudo id
bash -c "sudo true"
echo $(sudo id)
launchctl list
git push origin --force
git push --force-with-lease origin fm/x
git push -fu origin fm/x
git push origin +HEAD:fm/x
rm -rf /tmp/elsewhere
rm -rf .
rm -r ../sibling
find . -exec rm -rf / \;
gh repo view
gh pr create --title x --body y
EOF
  pass "fm-agy-permission-policy: pre-tool-use denies the hard-refusal list"
}

test_refusal_leaves_safe_commands_alone() {
  local policy dir cmd
  policy=$(new_case not-refused)
  dir=$(case_dir "$policy")
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use run_command "$cmd"
    abstained "$OUT" || fail "pre-tool-use must abstain on '$cmd', got rc=$RC out=$OUT"
  done <<'EOF'
git push -u origin fm/x
gh pr create --repo a/b --title x
command -v sudo
grep -rn sudo tests
cat README.md
git log --oneline -5
bin/fm-lint.sh
mkdir -p build/out
EOF
  pass "fm-agy-permission-policy: read-and-build commands abstain so the bypassed call runs"
}

test_non_command_tool_mapping() {
  local policy dir wt
  policy=$(new_case tools)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  mkdir -p "$wt/sub" "$dir/data/t1"
  local tool arg
  while IFS='|' read -r tool arg; do
    [ -n "$tool" ] || continue
    hook "$policy" pre-tool-use "$tool" "$arg"
    abstained "$OUT" || fail "$tool on '$arg' must abstain, got rc=$RC out=$OUT"
  done <<EOF
view_file|$wt/README.md
view_file|README.md
grep_search|needle
list_dir|$wt/sub
search_web|firstmate agy permission hooks
read_url_content|https://example.com/docs
write_to_file|$wt/src/new.txt
write_to_file|src/relative.txt
replace_file_content|$wt/src/edit.txt
EOF
  # A write outside every write root is refused outright - under bypass no
  # native prompt survives to catch it.
  hook "$policy" pre-tool-use write_to_file "/etc/hosts"
  denied "$OUT" "outside the task write roots" \
    || fail "a write outside the task roots must be denied, got: $OUT"
  hook "$policy" pre-tool-use replace_file_content "/usr/bin/env"
  denied "$OUT" || fail "a replace outside the task roots must be denied, got: $OUT"
  # The task's own brief is refused to every writer.
  hook "$policy" pre-tool-use write_to_file "$dir/data/t1/brief.md"
  denied "$OUT" "own instructions" \
    || fail "writing the task's own brief must be denied, got: $OUT"
  # Credential material is never auto-approved.
  hook "$policy" pre-tool-use view_file "$HOME/.ssh/id_rsa"
  denied "$OUT" "held for firstmate" \
    || fail "a credential read must escalate to firstmate, got: $OUT"
  pass "fm-agy-permission-policy: non-command tools map onto the shared policy's file and read rules"
}

test_unlisted_tool_escalates_to_firstmate() {
  local policy dir
  policy=$(new_case residue)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use some_mcp_tool "do a thing" 5
  denied "$OUT" "held for firstmate" \
    || fail "an unlisted tool must deny as held for firstmate, got: $OUT"
  [ -f "$dir/state/t1.agy-permission-pending/c1-s5.pending" ] \
    || fail "the held call must write a pending marker: $(ls "$dir/state/t1.agy-permission-pending" 2>/dev/null)"
  grep -qF 'needs-decision [key=agy-permission-c1-s5]: ' "$dir/state/t1.status" \
    || fail "the held call must append a keyed needs-decision line: $(cat "$dir/state/t1.status")"
  hook "$policy" pre-tool-use run_command "rm -rf build" 8
  denied "$OUT" "held for firstmate" \
    || fail "an in-worktree recursive delete is residue and must deny, got: $OUT"
  hook "$policy" pre-tool-use run_command "npm install" 9
  denied "$OUT" "held for firstmate" \
    || fail "a residue command must deny as held for firstmate, got: $OUT"
  grep -qF 'first judge disabled): npm install' "$dir/state/t1.status" \
    || fail "the escalation line must name the exact command and judge outcome: $(cat "$dir/state/t1.status")"
  hook "$policy" pre-tool-use run_command "git push origin main" 10
  denied "$OUT" || fail "an outward action must deny, got: $OUT"
  grep -qF 'firstmate policy: git push names the default branch): git push origin main' "$dir/state/t1.status" \
    || fail "an outward action must name the policy reason, not the judge: $(cat "$dir/state/t1.status")"
  pass "fm-agy-permission-policy: residue denies as held for firstmate with a keyed marker and status line"
}

test_held_call_retry_dedupes() {
  local policy dir
  policy=$(new_case dedup)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "npm install" 5
  denied "$OUT" "held for firstmate" || fail "the first hold must deny, got: $OUT"
  # The same call retried at a new stepIdx is denied against the existing
  # marker - no second marker, no second needs-decision line.
  hook "$policy" pre-tool-use run_command "npm install" 7
  denied "$OUT" "still held for firstmate as agy-permission-c1-s5" \
    || fail "a retry of the held call must deny against the first marker, got: $OUT"
  [ "$(grep -c '^needs-decision ' "$dir/state/t1.status")" = 1 ] \
    || fail "a retried hold must not append a second needs-decision: $(cat "$dir/state/t1.status")"
  [ "$(find "$dir/state/t1.agy-permission-pending" -name '*.pending' | wc -l | tr -d ' ')" = 1 ] \
    || fail "a retried hold must not write a second marker"
  pass "fm-agy-permission-policy: a held call's retry is denied against its existing marker"
}

test_post_tool_use_closes_the_marker_that_ran() {
  local policy dir
  policy=$(new_case closure)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "npm install" 5
  [ -f "$dir/state/t1.agy-permission-pending/c1-s5.pending" ] || fail "the escalation must open"
  hook "$policy" post-tool-use run_command "ls" 6
  [ -f "$dir/state/t1.agy-permission-pending/c1-s5.pending" ] \
    || fail "an unrelated call must not close the marker"
  # The retry arrives at a NEW stepIdx: the marker is matched by the call's
  # input, not its key.
  hook "$policy" post-tool-use run_command "npm install" 9
  [ ! -e "$dir/state/t1.agy-permission-pending/c1-s5.pending" ] \
    || fail "the held call running must close its marker"
  [ -z "$(status_open_decisions "$dir/state/t1.status")" ] \
    || fail "a run call must close its decision: $(cat "$dir/state/t1.status")"
  pass "fm-agy-permission-policy: post-tool-use closes the escalation for the call that ran"
}

test_stop_preserves_pending_for_firstmate() {
  local policy dir
  policy=$(new_case stop-keeps)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "npm install" 5
  [ -n "$(status_open_decisions "$dir/state/t1.status")" ] || fail "the escalation must open"
  hook "$policy" stop run_command "" 6
  [ -f "$dir/state/t1.agy-permission-pending/c1-s5.pending" ] \
    || fail "Stop must NOT close a held marker - firstmate's decision is still owed"
  [ -n "$(status_open_decisions "$dir/state/t1.status")" ] \
    || fail "the decision must stay open across turn end: $(cat "$dir/state/t1.status")"
  pass "fm-agy-permission-policy: Stop keeps held markers open for firstmate's answer"
}

test_approve_caches_the_verdict_and_retry_abstains() {
  local policy dir key
  policy=$(new_case approve-flow)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "npm install" 5
  denied "$OUT" || fail "the residue call must first be held, got: $OUT"
  key="agy-permission-c1-s5"
  "$POLICY_SH" approve "$policy" "$key" </dev/null >/dev/null 2>&1 \
    || fail "approve must succeed for an open key"
  [ -z "$(status_open_decisions "$dir/state/t1.status")" ] \
    || fail "approve must close the decision: $(cat "$dir/state/t1.status")"
  grep -qF "resolved [key=$key]: firstmate approved the held call" "$dir/state/t1.status" \
    || fail "approve must append its resolved line: $(cat "$dir/state/t1.status")"
  [ ! -e "$dir/state/t1.agy-permission-pending/c1-s5.pending" ] \
    || fail "approve must remove the marker"
  # The cached verdict approves the retry without a judge or a new marker.
  hook "$policy" pre-tool-use run_command "npm install" 8
  abstained "$OUT" || fail "a firstmate-approved call must abstain on retry, got: $OUT"
  [ ! -e "$dir/state/t1.agy-permission-pending/c1-s8.pending" ] \
    || fail "the approved retry must not open a new escalation"
  "$(command -v jq)" -e 'select(.decision == "approve" and (.decider | startswith("cache")))' \
    "$dir/state/agy-permission-log.jsonl" >/dev/null 2>&1 \
    || fail "the cached approval must be logged: $(cat "$dir/state/agy-permission-log.jsonl")"
  # Approving a key that is not open fails.
  "$POLICY_SH" approve "$policy" agy-permission-absent </dev/null >/dev/null 2>&1 \
    && fail "approve of a missing key must fail"
  pass "fm-agy-permission-policy: firstmate approve caches the verdict so the retry runs"
}

test_decline_denies_the_retry_without_reescalating() {
  local policy dir key
  policy=$(new_case decline-flow)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "npm install" 5
  denied "$OUT" || fail "the residue call must first be held, got: $OUT"
  key="agy-permission-c1-s5"
  "$POLICY_SH" decline "$policy" "$key" </dev/null >/dev/null 2>&1 \
    || fail "decline must succeed for an open key"
  grep -qF "resolved [key=$key]: firstmate declined the held call" "$dir/state/t1.status" \
    || fail "decline must append its resolved line: $(cat "$dir/state/t1.status")"
  [ "$(find "$dir/state/t1.agy-permission-cache" -name '*.declined' | wc -l | tr -d ' ')" = 1 ] \
    || fail "decline must record the declined-call marker"
  # A retry of the declined call is denied outright - never cached, never
  # re-escalated.
  hook "$policy" pre-tool-use run_command "npm install" 8
  denied "$OUT" "firstmate declined this call" \
    || fail "a retry of a declined call must be denied, got: $OUT"
  [ "$(grep -c '^needs-decision ' "$dir/state/t1.status")" = 1 ] \
    || fail "a declined retry must not open a second needs-decision: $(cat "$dir/state/t1.status")"
  pass "fm-agy-permission-policy: firstmate decline denies the exact retry without re-escalating"
}

test_judge_approve_abstains_and_caches() {
  local policy dir
  # The fake judge answers from the prompt carried on -p.
  # shellcheck disable=SC2016 # the body is the fake judge script's own source
  policy=$(new_case judge '
prompt=
while [ $# -gt 0 ]; do [ "$1" = -p ] && prompt=$2; shift; done
printf "%s\n" "judge-called" >> "$JUDGE_CALLS"
case "$prompt" in
  *"npm install"*) echo "REASON: rule 3, routine project-local install"; echo "APPROVE: project-local install" ;;
  *"pip install --user"*) echo "REASON: rule 4"; echo "DECLINE: machine-wide install" ;;
  *sleep-forever*) sleep 30 ;;
esac
exit 0')
  dir=$(case_dir "$policy")
  export JUDGE_CALLS="$dir/judge-calls"
  : > "$JUDGE_CALLS"
  hook "$policy" pre-tool-use run_command "npm install" 1
  abstained "$OUT" || fail "a judge APPROVE must abstain, got: $OUT ($(tail -1 "$dir/state/agy-permission-log.jsonl"))"
  [ ! -e "$dir/state/t1.status" ] || fail "a judge approval must not wake firstmate"
  [ "$(tail -1 "$dir/state/agy-permission-log.jsonl" | jq -r '.decider + ":" + .decision')" = judge:approve ] \
    || fail "a judge approval must be logged with decider judge"
  # The verdict is cached: the same call again never re-invokes the judge.
  hook "$policy" pre-tool-use run_command "npm install" 2
  abstained "$OUT" || fail "a cached verdict must abstain, got: $OUT"
  [ "$(wc -l < "$JUDGE_CALLS" | tr -d ' ')" = 1 ] \
    || fail "the second call must hit the cache without the judge"
  hook "$policy" pre-tool-use run_command "pip install --user requests" 3
  denied "$OUT" "held for firstmate" \
    || fail "a judge DECLINE must deny as held for firstmate, got: $OUT"
  grep -qF '(first judge: machine-wide install): pip install --user requests' "$dir/state/t1.status" \
    || fail "a judge decline must escalate with the judge reason: $(cat "$dir/state/t1.status")"
  pass "fm-agy-permission-policy: the judge approves into the cache and declines to firstmate"
}

test_judge_failures_always_deny() {
  local policy dir
  # shellcheck disable=SC2016 # the body is the fake judge script's own source
  policy=$(new_case judge-fail '
prompt=
while [ $# -gt 0 ]; do [ "$1" = -p ] && prompt=$2; shift; done
case "$prompt" in
  *crash-me*) exit 1 ;;
  *no-verdict*) echo "unparseable judge chatter" ;;
  *sleep-forever*) sleep 30 ;;
esac
exit 0')
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "crash-me" 1
  denied "$OUT" "held for firstmate" \
    || fail "a crashed judge must deny, never abstain, got: $OUT"
  grep -qF 'first judge failed' "$dir/state/t1.status" \
    || fail "a crashed judge must escalate with the failure: $(cat "$dir/state/t1.status")"
  hook "$policy" pre-tool-use run_command "no-verdict" 2
  denied "$OUT" || fail "a no-verdict judge must deny, got: $OUT"
  grep -qF 'first judge gave no verdict' "$dir/state/t1.status" \
    || fail "a no-verdict judge must escalate: $(cat "$dir/state/t1.status")"
  jq '.judge_timeout = "1"' "$policy" > "$policy.new" && mv "$policy.new" "$policy"
  hook "$policy" pre-tool-use run_command "sleep-forever" 3
  denied "$OUT" || fail "a timed-out judge must deny, got: $OUT"
  grep -qF 'first judge timed out after 1s' "$dir/state/t1.status" \
    || fail "a hung judge must be bounded and escalate: $(cat "$dir/state/t1.status")"
  [ -z "$(find "$dir/tmp/agy-permission-judge" -name 'prompt.*' 2>/dev/null)" ] \
    || fail "judge prompt files must be removed after each call"
  pass "fm-agy-permission-policy: every judge failure mode denies rather than abstains"
}

test_retire_closes_open_escalations() {
  local policy dir
  policy=$(new_case retire)
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command "npm install" 5
  [ -n "$(status_open_decisions "$dir/state/t1.status")" ] || fail "the escalation must open"
  "$POLICY_SH" retire "$policy" </dev/null >/dev/null 2>&1 || fail "retire must succeed"
  [ ! -e "$dir/state/t1.agy-permission-pending" ] || fail "retire must remove the pending directory"
  [ -z "$(status_open_decisions "$dir/state/t1.status")" ] \
    || fail "retire must close the orphaned decision: $(cat "$dir/state/t1.status")"
  "$POLICY_SH" retire "$policy" </dev/null >/dev/null 2>&1 \
    || fail "retire with nothing pending must be a no-op success"
  pass "fm-agy-permission-policy: retire closes escalations a dead worker left open"
}

test_grants_digest_pins_the_block() {
  local policy dir tampered
  policy=$(new_case grants '' '{"credential_env_files": ["~/.config/acme/acme.env"]}')
  dir=$(case_dir "$policy")
  hook "$policy" pre-tool-use run_command 'set -a; source ~/.config/acme/acme.env; set +a' 1
  abstained "$OUT" || fail "a granted credential env file must be sourceable, got: $OUT"
  hook "$policy" pre-tool-use run_command 'cat ~/.config/acme/acme.env' 2
  denied "$OUT" "held for firstmate" \
    || fail "the granted file must never be printed, got: $OUT"
  # A block the worker edits no longer matches the recorded digest.
  tampered=$(new_case grants-tampered '' '{"credential_env_files": ["~/.config/acme/acme.env"]}')
  local fence tdir
  tdir=$(case_dir "$tampered")
  fence=$(printf '\140\140\140')
  cat > "$tdir/data/t1/brief.md" <<EOF
# Task
## Captain's intent
Fix the flaky test.

## Firstmate spec
Keep the change narrow.

${fence}firstmate-grants
{"credential_env_files": ["~/.config/other/self.env"]}
${fence}
EOF
  hook "$tampered" pre-tool-use run_command 'set -a; source ~/.config/other/self.env; set +a' 1
  denied "$OUT" "held for firstmate" \
    || fail "a tampered grants block must grant nothing, got: $OUT"
  grep -qF 'grants block does not match the digest' "$tdir/state/agy-permission-log.jsonl" \
    || fail "the tampered block must be logged as ignored: $(cat "$tdir/state/agy-permission-log.jsonl")"
  pass "fm-agy-permission-policy: grants are honored only while their digest matches"
}

test_workspace_scope_and_unparseable_payloads() {
  local policy out
  policy=$(new_case scope)
  # A payload whose workspace does not include this task's worktree is not
  # this task's to police: abstain, no marker, no status line.
  out=$(jq -nc --arg wt "$(jq -r .worktree "$policy")" \
    '{conversationId:"c9", stepIdx:1, workspacePaths:["/somewhere/else"],
      toolCall:{name:"run_command", args:{CommandLine:"sudo true", Cwd:"/somewhere/else"}}}' \
    | "$POLICY_SH" pre-tool-use "$policy" 2>/dev/null)
  [ -z "$out" ] || fail "a foreign-workspace payload must abstain, got: $out"
  [ ! -e "$(case_dir "$policy")/state/t1.status" ] \
    || fail "a foreign payload must never touch this task's status"
  # A payload that cannot be read cannot be judged; under bypass abstaining
  # would run it, so it denies.
  out=$(printf 'not json at all' | "$POLICY_SH" pre-tool-use "$policy" 2>/dev/null)
  denied "$out" "unparseable" \
    || fail "an unparseable payload must deny, got: $out"
  pass "fm-agy-permission-policy: foreign payloads abstain and unparseable ones deny"
}

test_missing_policy_file_fails_closed() {
  local out
  out=$(jq -nc '{conversationId:"c1", stepIdx:1, workspacePaths:[],
      toolCall:{name:"run_command", args:{CommandLine:"rm -rf /tmp/x", Cwd:"/tmp"}}}' \
    | "$POLICY_SH" pre-tool-use "$TMP_ROOT/absent/t9.agy-permission.json" 2>/dev/null)
  denied "$out" || fail "without a policy file a recursive rm is unresolvable and must deny, got: $out"
  out=$(jq -nc '{conversationId:"c1", stepIdx:1, workspacePaths:[],
      toolCall:{name:"run_command", args:{CommandLine:"cat README.md", Cwd:"/tmp"}}}' \
    | "$POLICY_SH" pre-tool-use "$TMP_ROOT/absent/t9.agy-permission.json" 2>/dev/null)
  abstained "$out" || fail "without a policy file the refusal list still applies and the rest abstains, got: $out"
  pass "fm-agy-permission-policy: a missing policy file keeps the refusal list and never judges"
}

test_verified_versions_and_grants_digest_verbs() {
  local versions digest dir
  versions=$("$POLICY_SH" verified-versions 2>/dev/null)
  case " $versions " in
    *" 1.2.5 "*) ;;
    *) fail "verified-versions must list the live-verified agy set, got: $versions" ;;
  esac
  dir="$TMP_ROOT/verbs"
  mkdir -p "$dir"
  cat > "$dir/brief.md" <<'EOF'
# Task
```firstmate-grants
{"write_dirs": ["/tmp/x"]}
```
EOF
  digest=$("$POLICY_SH" grants-digest "$dir/brief.md" 2>/dev/null)
  case "$digest" in ''|*[!0-9a-f]*) fail "grants-digest must print a sha for a block, got: $digest" ;; esac
  [ ${#digest} -eq 64 ] || fail "grants-digest must print a 64-char sha, got: $digest"
  pass "fm-agy-permission-policy: the query verbs report the verified set and the grants pin"
}

test_install_worker_merges_and_validates() {
  local dir state id gen wt policy merged
  dir="$TMP_ROOT/install"; state="$dir/state"; id="agy-install-x1"; gen="g1"; wt="$dir/wt"
  mkdir -p "$state" "$wt"
  # Without a policy the install keeps the observer-only shape.
  "$HOOK_SH" install-worker "$state" "$id" "$gen" "$wt" >/dev/null 2>&1 \
    || fail "install-worker without a policy must succeed"
  merged="$state/$id.agy-hooks/.agents/hooks.json"
  [ "$(jq -r '."firstmate-worker".PreToolUse[0].hooks | length' "$merged")" = 1 ] \
    || fail "the observer-only install must carry one PreToolUse hook: $(cat "$merged")"
  # With a policy file the adapter rides beside the observer.
  mkdir -p "$dir/data/t1"
  cat > "$dir/data/t1/brief.md" <<'EOF'
# Task
## Captain's intent
x
EOF
  policy="$state/$id.agy-permission.json"
  jq -n --arg wt "$(cd "$wt" && pwd -P)" --arg d "$dir" \
    '{task:"t1", worktree:$wt, status:($d+"/state/t1.status"), inbox:($d+"/state/t1.inbox"),
      data:($d+"/data/t1"), tasktmp:($d+"/tmp"), brief:($d+"/data/t1/brief.md"),
      log:($d+"/state/agy-permission-log.jsonl"), agy:"/bin/true", judge_model:"x",
      judge_timeout:"60", grants_sha:""}' > "$policy"
  "$HOOK_SH" retire-worker "$state" "$id" >/dev/null 2>&1
  "$HOOK_SH" install-worker "$state" "$id" "$gen" "$wt" "$policy" >/dev/null 2>&1 \
    || fail "install-worker with a policy must succeed"
  # Eight commands total: open, close, observer pre, observer post, armed,
  # decide, policy stop, policy post.
  [ "$(jq -r '[."firstmate-worker" | .. | objects | select(has("command")) | .command] | length' "$merged")" = 8 ] \
    || fail "the policy install must carry eight hook commands: $(cat "$merged")"
  jq -e '."firstmate-worker".PreToolUse[0].hooks[1].command | test("fm-agy-permission-policy.*pre-tool-use")' \
    "$merged" >/dev/null \
    || fail "the decision hook must run second on PreToolUse: $(cat "$merged")"
  jq -e '."firstmate-worker".PreToolUse[0].hooks[1].timeout > 100' "$merged" >/dev/null \
    || fail "the decision hook timeout must sit above the judge budget: $(cat "$merged")"
  jq -e '."firstmate-worker".PreInvocation | map(.command) | any(test("armed"))' "$merged" >/dev/null \
    || fail "the armed heartbeat must join PreInvocation: $(cat "$merged")"
  jq -e '."firstmate-worker".Stop | map(.command) | any(test("fm-agy-permission-policy"))' "$merged" >/dev/null \
    || fail "the adapter must join Stop: $(cat "$merged")"
  jq -e '."firstmate-worker".PostToolUse[0].hooks[1].command | test("fm-agy-permission-policy.*post-tool-use")' \
    "$merged" >/dev/null \
    || fail "the marker-close hook must run second on PostToolUse: $(cat "$merged")"
  # A missing policy file refuses the install rather than writing dead wiring.
  rm -f "$policy"
  "$HOOK_SH" retire-worker "$state" "$id" >/dev/null 2>&1
  "$HOOK_SH" install-worker "$state" "$id" "$gen" "$wt" "$policy" >/dev/null 2>&1 \
    && fail "install-worker must refuse a missing policy file"
  pass "fm-agy-permission-policy: install-worker merges the adapter beside the observer and validates the result"
}

test_observer_and_turnend_survive_the_merge() {
  local dir state id gen wt log payload
  dir="$TMP_ROOT/observe"; state="$dir/state"; id="agy-observe-x1"; gen="g1"; wt="$dir/wt"
  mkdir -p "$state" "$wt" "$dir/data/$id"
  printf 'g1\n' > "$state/$id.busy-gen"
  "$HOOK_SH" install-worker "$state" "$id" "$gen" "$wt" >/dev/null 2>&1 || fail "install must succeed"
  log="$state/agy-permission-log.jsonl"
  payload=$(jq -nc --arg wt "$(cd "$wt" && pwd -P)" \
    '{conversationId:"conv1", stepIdx:3, modelName:"m1", workspacePaths:[$wt],
      toolCall:{name:"run_command", args:{CommandLine:"ls -la", Cwd:"/tmp"}}}')
  printf '%s' "$payload" | "$HOOK_SH" worker PreToolUse "$state" "$id" "$gen" "$wt" >/dev/null 2>&1
  [ "$(jq -r 'select(.event == "pre-tool-use") | .input' "$log" 2>/dev/null)" = "ls -la" ] \
    || fail "the observer must still log the tool call: $(cat "$log" 2>/dev/null)"
  # The turn-end path: PreInvocation opens busy, a fullyIdle Stop closes it
  # and touches turn-ended.
  printf '%s' "$(jq -nc --arg wt "$(cd "$wt" && pwd -P)" \
    '{conversationId:"conv1", invocationNum:0, workspacePaths:[$wt]}')" \
    | "$HOOK_SH" worker PreInvocation "$state" "$id" "$gen" "$wt" >/dev/null 2>&1
  printf '%s' "$(jq -nc --arg wt "$(cd "$wt" && pwd -P)" \
    '{conversationId:"conv1", fullyIdle:true, executionNum:0, workspacePaths:[$wt]}')" \
    | "$HOOK_SH" worker Stop "$state" "$id" "$gen" "$wt" >/dev/null 2>&1
  [ -e "$state/$id.turn-ended" ] \
    || fail "a fullyIdle Stop must still close the turn through the worker hook"
  pass "fm-agy-permission-policy: the observer and turn-end supervision survive the merged install"
}

test_armed_heartbeat_proves_wiring
test_refusal_list_denies
test_refusal_leaves_safe_commands_alone
test_non_command_tool_mapping
test_unlisted_tool_escalates_to_firstmate
test_held_call_retry_dedupes
test_post_tool_use_closes_the_marker_that_ran
test_stop_preserves_pending_for_firstmate
test_approve_caches_the_verdict_and_retry_abstains
test_decline_denies_the_retry_without_reescalating
test_judge_approve_abstains_and_caches
test_judge_failures_always_deny
test_retire_closes_open_escalations
test_grants_digest_pins_the_block
test_workspace_scope_and_unparseable_payloads
test_missing_policy_file_fails_closed
test_verified_versions_and_grants_digest_verbs
test_install_worker_merges_and_validates
test_observer_and_turnend_survive_the_merge
