#!/usr/bin/env bash
# Regression tests for the endpoint proof fm-spawn.sh's pre-launch abort
# requires before it returns a leased slot on a non-tmux backend.
#
# `treehouse return --force` resets the slot, so it is safe only once the
# pane shell sitting in that slot is proven gone. Herdr proves that only with
# a structured pane_not_found; any other failed read is unknown. Zellij and
# cmux have no structured absence read at all. An unknown endpoint keeps the
# lease and its receipt, the rule teardown uses.
#
# Each case drives the abort cleanup functions extracted from fm-spawn.sh
# against the real backend adapters, with a fake backend CLI and a fake
# treehouse on PATH. No real Herdr, Zellij, or cmux server is started, and no
# tmux server is touched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh" || exit 1

SPAWN="$ROOT/bin/fm-spawn.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found; the herdr presence read needs it"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-prelaunch-endpoint-proof)
trap fm_test_cleanup EXIT

FUNCS="$TMP_ROOT/abort-cleanup.sh"
for fn in spawn_endpoint_absent spawn_endpoint_proven_absent spawn_endpoint_close_confirmed \
  spawn_slot_holds_only_spawn_wiring spawn_prelaunch_abort_cleanup; do
  awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) *\\{" {on=1} on {print} on && /^}/ {exit}' "$SPAWN"
done > "$FUNCS"
for fn in spawn_endpoint_proven_absent spawn_prelaunch_abort_cleanup; do
  grep -q "^$fn()" "$FUNCS" || fail "could not extract $fn from bin/fm-spawn.sh"
done

# The driver runs the abort cleanup the EXIT trap runs, for a fresh spawn
# that created its endpoint and leased its slot but wired nothing. The close
# itself is a no-op, as when Herdr skips a close it could not lock.
DRIVER="$TMP_ROOT/driver.sh"
cat > "$DRIVER" <<'SH'
#!/usr/bin/env bash
set -u
. "$FM_TEST_ROOT/bin/fm-backend.sh"
. "$FM_TEST_FUNCS"
fm_backend_kill() { printf 'kill %s\n' "$*" >> "$FM_TEST_CASE/kill-calls"; return 0; }
fm_control_harness_family() { printf 'claude\n'; }
fm_control_harness_wiring_paths() { :; }
BACKEND=$FM_TEST_BACKEND T=$FM_TEST_TARGET W=fm-$FM_TEST_ID ID=$FM_TEST_ID
HARNESS=claude WT=$FM_TEST_WT PROJ_ABS=$FM_TEST_PROJ STATE_REAL=$FM_TEST_CASE
SPAWN_TREEHOUSE_RECEIPT=$FM_TEST_CASE/$FM_TEST_ID.treehouse-lease
SPAWN_TREEHOUSE_PROJECT_LOCK= SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=1
SPAWN_PRELAUNCH_ENDPOINT=1 SPAWN_PRELAUNCH_WIRING=0 SPAWN_PRELAUNCH_LEASE=1
spawn_prelaunch_abort_cleanup
SH

make_case() {  # <name> -> case_dir|proj|wt|fakebin
  local name=$1 case_dir proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  fm_fake_treehouse_lease "$fakebin"
  fm_git_worktree "$proj" "$wt" "fm/$name"
  printf 'lease\n' > "$case_dir/pe-$name.treehouse-lease"
  printf '%s\n' "$case_dir|$proj|$wt|$fakebin"
}

# A backend CLI stub that fails every call, printing <body> when given.
fake_cli() {  # <fakebin> <tool> [body]
  printf '%s' "${3:-}" > "$1/$2-body"
  cat > "$1/$2" <<'SH'
#!/usr/bin/env bash
tool=$(basename "$0")
printf '%s\n' "$*" >> "$(dirname "$0")/$tool-calls"
[ ! -s "$(dirname "$0")/$tool-body" ] || { cat "$(dirname "$0")/$tool-body"; printf '\n'; }
exit 1
SH
  chmod +x "$1/$2"
}

run_cleanup() {  # <backend> <target> <case_dir> <proj> <wt> <fakebin> <name>
  FM_TEST_ROOT="$ROOT" FM_TEST_FUNCS="$FUNCS" FM_TEST_BACKEND=$1 FM_TEST_TARGET=$2 \
    FM_TEST_CASE=$3 FM_TEST_PROJ=$4 FM_TEST_WT=$5 FM_TEST_ID="pe-$7" \
    PATH="$6:$PATH" bash "$DRIVER" 2>&1
}

# An unknown endpoint keeps the lease and receipt and reports why.
assert_lease_kept() {  # <label> <case_dir> <fakebin> <name> <output>
  local label=$1 case_dir=$2 fakebin=$3 name=$4 out=$5
  ! grep -q '^return ' "$fakebin/treehouse-calls" 2>/dev/null ||
    fail "$label: the slot was returned while its pane was not proven gone: $out"
  [ -f "$case_dir/pe-$name.treehouse-lease" ] || fail "$label: the retained lease lost its receipt: $out"
  case "$out" in
    *'because its endpoint may still be open'*) ;;
    *) fail "$label: the retention must be reported, got: $out" ;;
  esac
}

test_herdr_unknown_presence_keeps_the_lease() {
  local fields case_dir proj wt fakebin out
  fields=$(make_case herdr-unknown)
  IFS='|' read -r case_dir proj wt fakebin <<EOF
$fields
EOF
  fake_cli "$fakebin" herdr '{"error":{"code":"server_error","message":"protocol error"}}'
  out=$(run_cleanup herdr fmtest:p7 "$case_dir" "$proj" "$wt" "$fakebin" herdr-unknown)
  grep -q '^pane get p7' "$fakebin/herdr-calls" 2>/dev/null ||
    fail "herdr-unknown: the case must read the pane, or it proves nothing: $out"
  assert_lease_kept herdr-unknown "$case_dir" "$fakebin" herdr-unknown "$out"
  pass "fm-spawn.sh: a Herdr pane whose presence reads as unknown keeps the leased slot"
}

test_herdr_silent_failure_keeps_the_lease() {
  local fields case_dir proj wt fakebin out
  fields=$(make_case herdr-silent)
  IFS='|' read -r case_dir proj wt fakebin <<EOF
$fields
EOF
  fake_cli "$fakebin" herdr
  out=$(run_cleanup herdr fmtest:p7 "$case_dir" "$proj" "$wt" "$fakebin" herdr-silent)
  assert_lease_kept herdr-silent "$case_dir" "$fakebin" herdr-silent "$out"
  pass "fm-spawn.sh: a Herdr pane read that fails without a structured answer keeps the leased slot"
}

test_herdr_pane_not_found_returns_the_slot() {
  local fields case_dir proj wt fakebin out
  fields=$(make_case herdr-gone)
  IFS='|' read -r case_dir proj wt fakebin <<EOF
$fields
EOF
  fake_cli "$fakebin" herdr '{"error":{"code":"pane_not_found","message":"pane not found"}}'
  out=$(run_cleanup herdr fmtest:p7 "$case_dir" "$proj" "$wt" "$fakebin" herdr-gone)
  grep -qxF -- "return --force $wt" "$fakebin/treehouse-calls" 2>/dev/null ||
    fail "herdr-gone: a pane proven gone must return the slot; treehouse calls: $(cat "$fakebin/treehouse-calls" 2>/dev/null); output: $out"
  [ ! -e "$case_dir/pe-herdr-gone.treehouse-lease" ] || fail "herdr-gone: the returned slot kept its receipt"
  pass "fm-spawn.sh: a Herdr pane proven gone by pane_not_found returns the leased slot"
}

test_no_proof_backend_keeps_the_lease() {  # <backend> <target>
  local backend=$1 target=$2 name="$1-failed" fields case_dir proj wt fakebin out
  fields=$(make_case "$name")
  IFS='|' read -r case_dir proj wt fakebin <<EOF
$fields
EOF
  fake_cli "$fakebin" "$backend"
  out=$(run_cleanup "$backend" "$target" "$case_dir" "$proj" "$wt" "$fakebin" "$name")
  assert_lease_kept "$name" "$case_dir" "$fakebin" "$name" "$out"
  pass "fm-spawn.sh: a $backend endpoint whose existence read fails keeps the leased slot"
}

test_herdr_unknown_presence_keeps_the_lease
test_herdr_silent_failure_keeps_the_lease
test_herdr_pane_not_found_returns_the_slot
test_no_proof_backend_keeps_the_lease zellij fmtest:3
test_no_proof_backend_keeps_the_lease cmux ws-1:sf-1
