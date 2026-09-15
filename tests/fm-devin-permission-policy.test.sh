#!/usr/bin/env bash
# tests/fm-devin-permission-policy.test.sh - behavior of the Devin permission
# decision layer (bin/fm-devin-permission-policy.sh) driven through its public
# hook interface: Devin-shaped JSON payloads on stdin, the per-task policy file,
# and the observable stdout decision, exit code, status file, pending markers,
# and log records. Covers the refusal list, the read-and-build approvals, the
# first judge (a fake devin executable standing in for SWE-2 High), escalation
# and its closure on PostToolUse, Stop, and relaunch retirement, symlink-aware
# recursive rm resolution, and the no-policy-file fallback.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

POLICY_SH="$ROOT/bin/fm-devin-permission-policy.sh"
TMP_ROOT=$(fm_test_tmproot fm-devin-permission-policy)

command -v jq >/dev/null 2>&1 || {
  printf 'skip - fm-devin-permission-policy: jq not installed\n'
  exit 0
}

# new_case <name> [judge-script-body]: builds a home with a worktree, status,
# inbox, data dir, temp root, and policy file; prints the policy path.
new_case() {
  local name=$1 judge_body=${2-} dir wt judge=''
  dir="$TMP_ROOT/$name"
  wt="$dir/wt"
  mkdir -p "$wt" "$dir/state/t1.inbox/handled" "$dir/data/t1" "$dir/tmp"
  wt=$(cd "$wt" && pwd -P)
  if [ -n "$judge_body" ]; then
    judge="$dir/bin/devin"
    mkdir -p "$dir/bin"
    printf '#!/usr/bin/env bash\n%s\n' "$judge_body" > "$judge"
    chmod +x "$judge"
  fi
  cat > "$dir/data/t1/brief.md" <<'EOF'
# Task
## Captain's intent
Fix the flaky test.

# Setup
Not part of the excerpt.
EOF
  jq -n --arg wt "$wt" --arg d "$dir" --arg judge "$judge" \
    '{task:"t1", worktree:$wt, status:($d+"/state/t1.status"), inbox:($d+"/state/t1.inbox"),
      data:($d+"/data/t1"), tasktmp:($d+"/tmp"), brief:($d+"/data/t1/brief.md"),
      log:($d+"/state/devin-permission-log.jsonl"), devin:$judge,
      judge_model:(if $judge == "" then "" else "swe-2-high" end), judge_timeout:"5"}' \
    > "$dir/state/t1.devin-permission.json"
  printf '%s\n' "$dir/state/t1.devin-permission.json"
}

# hook <policy> <event> <tool> <command-or-file> [tool-use-id]: sets OUT and RC.
hook() {
  local policy=$1 event=$2 tool=$3 arg=$4 id=${5-exec_1#abc} payload
  if [ "$tool" = exec ]; then
    payload=$(jq -nc --arg t "$tool" --arg c "$arg" --arg id "$id" \
      '{hook_event_name:"x", tool_name:$t, tool_input:{command:$c}, tool_use_id:$id, session_id:"s1", prompt_id:"p1"}')
  else
    payload=$(jq -nc --arg t "$tool" --arg f "$arg" --arg id "$id" \
      '{hook_event_name:"x", tool_name:$t, tool_input:{file_path:$f, content:"x"}, tool_use_id:$id, session_id:"s1"}')
  fi
  OUT=$(printf '%s' "$payload" | "$POLICY_SH" "$event" "$policy" 2>/dev/null)
  RC=$?
}

case_dir() { dirname "$(dirname "$1")"; }

test_refusal_list() {
  local policy cmd
  policy=$(new_case refuse)
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use exec "$cmd"
    [ "$RC" = 2 ] || fail "pre-tool-use must refuse '$cmd' with exit 2, got rc=$RC out=$OUT"
    [ "$(printf '%s' "$OUT" | jq -r .decision)" = block ] \
      || fail "refusal of '$cmd' must print decision block, got: $OUT"
  done <<'EOF'
sudo ls
ls && sudo rm x
/usr/bin/sudo -n true
env FOO=1 sudo id
bash -c "sudo true"
echo $(sudo id)
launchctl list
git push origin --force
git push --force-with-lease origin fm/x
git push --force-if-includes
git push -fu origin fm/x
git push --force-with-l origin fm/x
git push --forc origin fm/x
git push origin fm/x --force-if
git push --receive-pack=/tmp/x origin fm/x
git push -uz origin fm/x
git push origin +HEAD:fm/x
git -C /elsewhere push origin HEAD --force
rm -rf /tmp/elsewhere
rm -rf .
rm -rf "$HOME/x"
cd /tmp && rm -rf build
find . -exec rm -rf / \;
rm -r ../sibling
gh repo view
gh repo delete a/b --yes
gh pr create --title x --body y
EOF
  pass "fm-devin-permission-policy: pre-tool-use refuses the hard-line list in every argument position"
}

test_refusal_leaves_safe_commands_alone() {
  local policy cmd
  policy=$(new_case not-refused)
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use exec "$cmd"
    [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "pre-tool-use must not object to '$cmd', got rc=$RC out=$OUT"
  done <<'EOF'
rm -rf build
rm -rf build/*
rm -f /tmp/one-file
git push -u origin fm/x
git push --set-upstream --no-verify origin fm/x
git push -o ci.skip --dry-run origin fm/x
git push -- origin fm/x
gh pr create --repo a/b --title x
command -v sudo
grep -rn sudo tests
git log --grep=force
EOF
  hook "$policy" pre-tool-use exec "cat <<'DOC'
sudo rm -rf /
DOC"
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "heredoc body text must not be read as commands, got rc=$RC out=$OUT"
  hook "$policy" pre-tool-use write "/etc/hosts"
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "pre-tool-use must ignore non-exec tools, got rc=$RC out=$OUT"
  pass "fm-devin-permission-policy: pre-tool-use leaves in-worktree deletes, normal pushes, and quoted mentions alone"
}

test_recursive_rm_resolves_symlinked_components() {
  local policy dir wt cmd
  policy=$(new_case rm-symlink)
  dir=$(case_dir "$policy")
  wt=$(jq -r .worktree "$policy")
  mkdir -p "$dir/outside/victim" "$wt/real/sub"
  ln -s "$dir/outside" "$wt/link"
  ln -s "$dir/outside/victim" "$wt/victim-link"
  ln -s "$dir/absent" "$wt/dangling"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use exec "$cmd"
    [ "$RC" = 2 ] || fail "pre-tool-use must refuse the symlink-escaping delete '$cmd', got rc=$RC out=$OUT"
  done <<'EOF'
rm -rf link/victim
rm -rf victim-link/
rm -rf link/.
rm -rf real/../link/victim
rm -rf link/../outside
cd link && rm -rf victim
rm -rf link/*
rm -rf */victim
rm -rf dangling/x
EOF
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" pre-tool-use exec "$cmd"
    [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "pre-tool-use must not object to the in-worktree delete '$cmd', got rc=$RC out=$OUT"
  done <<'EOF'
rm -rf link
rm -rf victim-link
rm -rf real/sub
rm -rf real/../build
rm -rf not-yet/created
rm -rf real/*
EOF
  [ -d "$dir/outside/victim" ] || fail "the policy must never delete anything itself"
  pass "fm-devin-permission-policy: a recursive rm through a symlinked component is judged by where it physically lands"
}

test_retire_closes_orphaned_escalations() {
  local policy dir
  policy=$(new_case retire)
  dir=$(case_dir "$policy")
  hook "$policy" permission-request exec "npm install" "exec_1#orphan"
  [ -n "$(status_open_decisions "$dir/state/t1.status")" ] || fail "the escalation must open"
  "$POLICY_SH" retire "$policy" </dev/null >/dev/null 2>&1 || fail "retire must succeed"
  [ ! -e "$dir/state/t1.devin-permission-pending" ] || fail "retire must remove the pending directory"
  [ -z "$(status_open_decisions "$dir/state/t1.status")" ] || fail "retire must close the orphaned decision"
  [ "$(tail -1 "$dir/state/devin-permission-log.jsonl" | jq -r '.decider + ":" + .decision')" = prompt:not-run ] \
    || fail "retire must log the orphaned escalation as not-run"
  "$POLICY_SH" retire "$policy" </dev/null >/dev/null 2>&1 || fail "retire with nothing pending must be a no-op success"
  pass "fm-devin-permission-policy: retire closes escalations a dead worker left open"
}

test_read_and_build_approvals_are_silent() {
  local policy dir cmd
  policy=$(new_case approve)
  dir=$(case_dir "$policy")
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    hook "$policy" permission-request exec "$cmd"
    [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | jq -r .decision 2>/dev/null)" = approve ] \
      || fail "permission-request must approve '$cmd', got rc=$RC out=$OUT"
  done <<EOF
cat README.md
head -50 bin/fm-spawn.sh | grep -n devin
grep -rn "a|b" bin; echo done
find . -name "*.sh" -type f
git merge-base HEAD origin/main
git -C . log --oneline -5
git rev-parse --show-toplevel
git diff --stat main...HEAD
git branch -a
gh run view 123 --log-failed
gh pr checks 29 --repo a/b
gh api repos/a/b/pulls/1
bin/fm-test-run.sh tests/fm-devin-harness.test.sh
bash tests/fm-devin-harness.test.sh 2>&1 | tail -20
git add -A && git commit -m "subject line"
git checkout -b fm/new-branch
git push -u origin fm/new-branch
sed -n 10,40p bin/fm-spawn.sh
mkdir -p build/out
cd tests && ls
echo "done: finished" >> '$dir/state/t1.status'
mv '$dir/state/t1.inbox/001.msg' '$dir/state/t1.inbox/handled/'
EOF
  hook "$policy" permission-request exec "git commit -F- <<'MSG'
subject

body \$(not expanded)
MSG"
  [ "$(printf '%s' "$OUT" | jq -r .decision)" = approve ] \
    || fail "a quoted-delimiter heredoc commit must be approved, got: $OUT"
  hook "$policy" permission-request write "$dir/data/t1/report.md"
  [ "$(printf '%s' "$OUT" | jq -r .decision)" = approve ] \
    || fail "a write into the task data directory must be approved, got: $OUT"
  [ ! -e "$dir/state/t1.status" ] || fail "approvals must never wake firstmate: $(cat "$dir/state/t1.status")"
  [ ! -d "$dir/state/t1.devin-permission-pending" ] || fail "approvals must not leave pending markers"
  [ "$(jq -s 'map(select(.decision == "approve" and .decider == "policy")) | length' "$dir/state/devin-permission-log.jsonl")" -ge 24 ] \
    || fail "every approval must be logged with decider policy"
  pass "fm-devin-permission-policy: read-and-build set approves silently and logs each request"
}

test_residue_escalates_without_judge() {
  local policy dir cmd open
  policy=$(new_case residue)
  dir=$(case_dir "$policy")
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    rm -rf "$dir/state/t1.devin-permission-pending"
    hook "$policy" permission-request exec "$cmd"
    [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "residue '$cmd' must fall through to the prompt, got rc=$RC out=$OUT"
  done <<'EOF'
find . -delete
git push origin main
git checkout -- file.txt
git branch -D old
sed -i s/a/b/ file
cat ~/.ssh/id_rsa
cat .env
mkdir -p /etc/firstmate
echo hi > out.txt
FOO=1 bin/fm-lint.sh
ls $(pwd)
npm install
gh api -X POST repos/a/b/issues
git -C /elsewhere status
EOF
  rm -rf "$dir/state/t1.devin-permission-pending"
  # shellcheck disable=SC2016 # the expansion is the command under test
  hook "$policy" permission-request exec 'cat <<DOC
$(id)
DOC'
  [ -z "$OUT" ] || fail "an expanding heredoc must escalate, got: $OUT"
  [ "$(grep -c '^needs-decision \[key=devin-permission-exec_1-abc\]: ' "$dir/state/t1.status")" = 15 ] \
    || fail "each residue request must append one keyed needs-decision line: $(cat "$dir/state/t1.status")"
  grep -qF 'first judge disabled): git push origin main' "$dir/state/t1.status" \
    || fail "the escalation line must name the exact command and judge outcome: $(cat "$dir/state/t1.status")"
  hook "$policy" permission-request write "/etc/hosts"
  [ -z "$OUT" ] || fail "a write outside the task roots must escalate, got: $OUT"
  hook "$policy" permission-request webfetch "https://example.com"
  [ -z "$OUT" ] || fail "an unlisted tool must escalate, got: $OUT"
  open=$(status_open_decisions "$dir/state/t1.status" | cut -f1)
  [ "$open" = devin-permission-exec_1-abc ] || fail "the escalation must read as an open decision, got '$open'"
  pass "fm-devin-permission-policy: residue escalates with a keyed decision naming the command"
}

test_escalation_closes_on_post_tool_use_and_stop() {
  local policy dir
  policy=$(new_case closure)
  dir=$(case_dir "$policy")
  hook "$policy" permission-request exec "npm install" "exec_1#one"
  [ -f "$dir/state/t1.devin-permission-pending/exec_1-one.pending" ] || fail "escalation must write a pending marker"
  hook "$policy" permission-request exec "npm install" "exec_1#one"
  [ "$(grep -c needs-decision "$dir/state/t1.status")" = 1 ] || fail "a repeated request for one tool call must not re-escalate"
  hook "$policy" post-tool-use exec "ls" "exec_2#other"
  [ -f "$dir/state/t1.devin-permission-pending/exec_1-one.pending" ] || fail "an unrelated tool call must not close the escalation"
  hook "$policy" post-tool-use exec "npm install" "exec_1#one"
  [ ! -e "$dir/state/t1.devin-permission-pending/exec_1-one.pending" ] || fail "the escalated call finishing must retire its marker"
  [ -z "$(status_open_decisions "$dir/state/t1.status")" ] || fail "an approved-at-prompt call must close its decision"

  hook "$policy" permission-request exec "git branch -D old" "exec_3#declined"
  [ -n "$(status_open_decisions "$dir/state/t1.status")" ] || fail "second escalation must open"
  printf '{"hook_event_name":"Stop"}' | "$POLICY_SH" stop "$policy" >/dev/null 2>&1
  [ -z "$(status_open_decisions "$dir/state/t1.status")" ] || fail "Stop must close escalations that never ran"
  [ "$(jq -s -r 'map(select(.decider == "prompt")) | map(.decision) | join(",")' "$dir/state/devin-permission-log.jsonl")" = "approved-at-prompt,not-run" ] \
    || fail "escalation outcomes must be logged: $(cat "$dir/state/devin-permission-log.jsonl")"
  pass "fm-devin-permission-policy: escalations close when the call runs or the turn ends"
}

test_first_judge_approves_and_declines() {
  local policy dir
  # The fake judge answers from the tool input embedded in its prompt file.
  # shellcheck disable=SC2016 # the body is the fake judge script's own source
  policy=$(new_case judge '
prompt=
while [ $# -gt 0 ]; do [ "$1" = --prompt-file ] && prompt=$2; shift; done
[ -n "$FM_DEVIN_HARNESS" ] && { echo "DECLINE: harness marker leaked"; exit 0; }
case "$PWD" in */tmp/devin-permission-judge) ;; *) echo "DECLINE: wrong cwd $PWD"; exit 0 ;; esac
grep -q "Fix the flaky test" "$prompt" || { echo "DECLINE: no brief excerpt"; exit 0; }
grep -q "Not part of the excerpt" "$prompt" && { echo "DECLINE: excerpt too long"; exit 0; }
call=$(sed -n "/^Tool input:/,\$p" "$prompt")
case "$call" in
  *"npm install"*) echo "**APPROVE: project-local install**" ;;
  *"reset --hard"*) echo "DECLINE: discards work" ;;
  *sleep-forever*) sleep 30 ;;
esac
exit 0')
  dir=$(case_dir "$policy")
  FM_DEVIN_HARNESS=devin hook "$policy" permission-request exec "npm install" "exec_1#a"
  [ "$(printf '%s' "$OUT" | jq -r .decision 2>/dev/null)" = approve ] \
    || fail "a judge APPROVE must approve, got: $OUT ($(tail -1 "$dir/state/devin-permission-log.jsonl"))"
  [ ! -e "$dir/state/t1.status" ] || fail "a judge approval must not wake firstmate"
  [ "$(tail -1 "$dir/state/devin-permission-log.jsonl" | jq -r '.decider + ":" + .decision')" = judge:approve ] \
    || fail "a judge approval must be logged with decider judge"

  hook "$policy" permission-request exec "git reset --hard origin/main" "exec_2#b"
  [ -z "$OUT" ] || fail "a judge DECLINE must fall through to the prompt, got: $OUT"
  grep -qF '(first judge: discards work): git reset --hard origin/main' "$dir/state/t1.status" \
    || fail "a judge decline must escalate with the judge reason: $(cat "$dir/state/t1.status")"

  hook "$policy" permission-request exec "make deploy" "exec_3#c"
  grep -qF 'first judge gave no verdict' "$dir/state/t1.status" \
    || fail "a judge without a verdict must escalate: $(cat "$dir/state/t1.status")"

  jq '.judge_timeout = "1"' "$policy" > "$policy.new" && mv "$policy.new" "$policy"
  hook "$policy" permission-request exec "sleep-forever" "exec_4#d"
  grep -qF 'first judge timed out after 1s' "$dir/state/t1.status" \
    || fail "a hung judge must be bounded and escalate: $(cat "$dir/state/t1.status")"
  [ -z "$(find "$dir/tmp/devin-permission-judge" -name 'prompt.*' 2>/dev/null)" ] \
    || fail "judge prompt files must be removed after each call"
  pass "fm-devin-permission-policy: the first judge approves silently and escalates only what it declines"
}

test_missing_policy_file_still_refuses() {
  local out rc
  out=$(jq -nc '{tool_name:"exec", tool_input:{command:"rm -rf build"}, tool_use_id:"e1"}' \
    | "$POLICY_SH" pre-tool-use "$TMP_ROOT/absent/t9.devin-permission.json" 2>/dev/null)
  rc=$?
  [ "$rc" = 2 ] || fail "without a policy file a recursive rm is unresolvable and must be refused, got rc=$rc out=$out"
  out=$(jq -nc '{tool_name:"exec", tool_input:{command:"sudo true"}, tool_use_id:"e1"}' \
    | "$POLICY_SH" pre-tool-use "$TMP_ROOT/absent/t9.devin-permission.json" 2>/dev/null)
  rc=$?
  [ "$rc" = 2 ] || fail "without a policy file sudo must still be refused, got rc=$rc"
  out=$(jq -nc '{tool_name:"exec", tool_input:{command:"cat README.md"}, tool_use_id:"e1"}' \
    | "$POLICY_SH" permission-request "$TMP_ROOT/absent/t9.devin-permission.json" 2>/dev/null)
  rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] || fail "without a policy file permission-request must fall through, got rc=$rc out=$out"
  pass "fm-devin-permission-policy: a missing policy file keeps the refusal list and never approves"
}

test_refusal_list
test_refusal_leaves_safe_commands_alone
test_recursive_rm_resolves_symlinked_components
test_retire_closes_orphaned_escalations
test_read_and_build_approvals_are_silent
test_residue_escalates_without_judge
test_escalation_closes_on_post_tool_use_and_stop
test_first_judge_approves_and_declines
test_missing_policy_file_still_refuses
