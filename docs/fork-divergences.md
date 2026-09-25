# Fork divergences

This fork-only ledger owns which differences between this fork and upstream [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate) are deliberate.
README "Personal fork: what differs" stays the owner of user-visible fork behavior; an entry here names its README bullet rather than restating it, and adds the class, seam, guard, and upstream position.
The [upstream integration checklist](upstream-integration.md) runs every guard named here and classifies each shared-file difference against these entries.

Divergence from upstream is a cost to weigh, not a hard gate.
A divergence is justified when it serves reliable local use, familiar tools, or less prescriptive workflows and no upstream option achieves it, taking the upstreamable shape wherever that shape is free.
A divergence should be resisted when an upstream mechanism or option already covers it, or when a free upstreamable shape was not taken; alignment never justifies contorting a design.
A fork PR that adds or widens a difference in a shared file names the entry it adds or extends here, or says why the difference is incidental, and states its upstream cost.

Classes:

- `intended`: kept indefinitely; an upstream change that breaks its guard is adapted to keep this behavior, never the reverse.
- `carried`: a fork fix or port kept only until upstream ships an equivalent; each integration run checks whether it can be dropped.
- `incidental`: no reason to differ; realign when convenient.

A difference in a file shared with upstream that no entry's `Seam:` claims is unclassified, and the integration run reports it as incidental.
An entry whose convergence is still under investigation says so in its `Class:` line and is not a decision.

Each entry has these one-line fields: `Intent:` with its source, `Class:`, `Seam:` naming the files (fork-only or shared), `Guard:` naming the test that fails if the divergence is lost (or `none`, which is itself a finding), and `Upstream:` with what upstream does instead and, for carried entries, what would let the fork drop it.

## Intended

### gh-not-gh-axi

- Intent: GitHub operations use plain `gh`; README "No required `gh-axi`".
- Class: intended.
- Seam: `bin/fm-pr-merge.sh` and the bootstrap tool list (shared); upstream's optional, inert `gh-axi` fallback in `fm_pr_github_read_record` is deliberately kept.
- Guard: `tests/fm-bootstrap.test.sh` `test_dropped_tools_are_not_required`.
- Upstream: requires `gh-axi`.

### no-chrome-devtools-axi

- Intent: browser work uses harness browser tools or Playwright; README "No required `chrome-devtools-axi`".
- Class: intended.
- Seam: bootstrap tool list (shared).
- Guard: `tests/fm-bootstrap.test.sh` `test_dropped_tools_are_not_required`.
- Upstream: requires `chrome-devtools-axi`.

### no-lavish-axi

- Intent: decisions and reports use chat, and `/bearings lavish` is a read-only snapshot; README "No required `lavish-axi`".
- Class: intended.
- Seam: `bin/fm-bearings-board.sh`, `.agents/skills/bearings/assets/board-template.html`, and the scout-brief Lavish line (shared); upstream's `tests/fm-bearings-board-lavish-live-e2e.test.sh` is deleted.
- Guard: `tests/fm-bearings-board.test.sh` `test_build_does_not_invoke_lavish`; `tests/fm-bootstrap.test.sh` `test_dropped_tools_are_not_required`.
- Upstream: requires `lavish-axi` and drives an interactive board.

### no-mistakes-optional

- Intent: no required pipeline; `no-mistakes` delivery tokens ship as `direct-PR` unless `config/no-mistakes` opts in; README "No required `no-mistakes`".
- Class: intended.
- Seam: `bin/fm-dod-lib.sh`, `bin/fm-brief.sh`, `bin/fm-promote.sh`, `bin/fm-spawn.sh`, the `CONTRIBUTING.md` required-checks line, and the `VISION.md` Scope line (shared); upstream's `.github/workflows/no-mistakes-required.yml` is deleted.
- Guard: `tests/fm-brief.test.sh` `test_no_mistakes_*`; `tests/fm-task-delivery.test.sh` `test_no_mistakes_*`; `tests/fm-bootstrap.test.sh` `test_no_mistakes_opt_in_reports_unavailable_cli`.
- Upstream: requires the no-mistakes pipeline for every ship.

### reviewed-worker-permissions

- Intent: `config/crew-permissions` (automatic review by default, manual review as an option) replaces upstream's `config/claude-permission-mode`, and no worker launch bypasses permissions; README "Reviewed worker permissions".
- Class: intended.
- Seam: permission resolution and `launch_template` in `bin/fm-spawn.sh`, and `docs/configuration.md` (shared).
- Guard: `tests/fm-spawn-dispatch-profile.test.sh` `test_worker_permission_modes`, `test_invalid_worker_permissions_refuse`, and `test_upstream_claude_permission_mode_file_cannot_select_bypass`; the negative bypass assertions in `tests/fm-claude-trust.test.sh`.
- Upstream: bypasses permissions by default, with automatic review as a Claude-only opt-in through `config/claude-permission-mode`.

### codex-reviewed-launch

- Intent: Codex workers launch with `--approve-for-me`, or with manual review when `config/crew-permissions` is `manual`, never with approvals and sandbox bypassed; README "Reviewed worker permissions".
- Class: intended.
- Seam: the Codex arms of `launch_template` in `bin/fm-spawn.sh` (shared) print the selected permission flags in place of upstream's `--dangerously-bypass-approvals-and-sandbox`; https://github.com/lmuehleisen/firstmate/pull/51 proposes keeping the template lines byte-identical to upstream and substituting the flags at launch time instead.
- Guard: `tests/fm-spawn-dispatch-profile.test.sh` `test_worker_permission_modes` and `test_codex_secondmate_launch_keeps_the_hook_layer`.
- Upstream: launches Codex with `--dangerously-bypass-approvals-and-sandbox` and has no Codex permission option; an equivalent upstream option would reduce this entry to a default value.

### agy-permission-posture

- Intent: agy workers default to `--mode accept-edits` rather than a blanket skip, and bypass runs only with `--agy-bypass` under the policed permission hook and judge tier; fork PRs 35 and 39.
- Class: intended.
- Seam: fork-only `bin/fm-agy-lib.sh`, `bin/fm-agy-permission-policy.sh`, `bin/fm-command-policy-lib.sh`, and `bin/fm-judge-tier-lib.sh`, plus small spawn hooks in `bin/fm-spawn.sh` (shared).
- Guard: `tests/fm-agy-permission-policy.test.sh`; `tests/fm-agy-harness.test.sh`.
- Upstream: its own agy adapter has no fork permission layer.

### devin-permission-layer

- Intent: Devin workers run in reviewed mode behind firstmate's permission hook, never in bypass; fork PRs 30, 32, 34, and 46.
- Class: intended.
- Seam: fork-only `bin/fm-devin-permission-policy.sh` and `bin/fm-devin-lib.sh`, plus small spawn hooks in `bin/fm-spawn.sh` (shared).
- Guard: `tests/fm-devin-permission-policy.test.sh`.
- Upstream: its own Devin adapter launches with `--permission-mode dangerous`.

### read-only-web-lookups

- Intent: the agy and Devin permission layers approve GET-shaped fetches for any host; captain decision 2026-09-17, fork PR 34.
- Class: intended.
- Seam: the fork-only agy and Devin policy libraries listed above.
- Guard: `tests/fm-agy-permission-policy.test.sh`; `tests/fm-devin-permission-policy.test.sh`.
- Upstream: no equivalent layer.

### no-global-harness-settings-writes

- Intent: never write the captain's global `~/.gemini` settings.
- Class: intended.
- Seam: upstream's `bin/fm-agy-trust.sh`, which pre-registers worktrees in `~/.gemini/antigravity-cli/settings.json`, is deleted.
- Guard: none.
- Upstream: pre-registers each agy worktree in the global settings file.

### remote-less-local-only

- Intent: explicit `local-only` ships start from local `main` or `master` with no remote, refusing dirty or divergent bases; README "Remote-less local work".
- Class: intended.
- Seam: pool-base handling in `bin/fm-spawn.sh` (shared).
- Guard: `tests/fm-spawn-pool-base-freshen.test.sh` `test_originless_pool_launches_without_a_freshness_fetch` and `test_originless_dirty_pool_refuses_without_discarding_work`.
- Upstream: requires a remote to freshen the pool base.

### durable-approval-waits

- Intent: completed ship work awaiting merge stays tracked, visible in Bearings, and quietly supervised after its worker is verified stopped; README "Durable approval waits".
- Class: intended.
- Seam: `bin/fm-captain-hold.sh` and the watcher (shared).
- Guard: fork-only `tests/fm-captain-hold-completed-ship.test.sh`, `tests/fm-watch-completed-ship-hold.test.sh`, and `tests/fm-fleet-snapshot-captain-hold.test.sh`.
- Upstream: no completed-ship hold.

### upstream-integration-tooling

- Intent: upstream arrives through real-merge integration runs and the updater only fast-forwards; README upstream integration paragraph.
- Class: intended.
- Seam: fork-only `docs/upstream-integration.md` and `bin/fm-upstream-callsite-scan.sh`, plus the updater skill (shared).
- Guard: fork-only `tests/fm-upstream-callsite-scan.test.sh`.
- Upstream: not applicable.

### devin-and-agy-first-class

- Intent: Devin and agy are routine worker runtimes.
- Class: intended.
- Seam: fork-only `bin/fm-devin-lib.sh` and `bin/fm-agy-lib.sh`, plus shared adapter-list and composer lines.
- Guard: `tests/fm-devin-harness.test.sh`; `tests/fm-agy-harness.test.sh`; `tests/fm-composer-agy.test.sh`.
- Upstream: ships its own Devin and agy adapters; how much of the fork's mechanics to keep is the open question in the carried entries below.

## Carried

### devin-adapter-mechanics

- Intent: the fork's own Devin adapter, fork PRs 25 to 28, which predates upstream's; the fork deleted upstream's `bin/fm-devin-config.sh`.
- Class: carried, open convergence question under investigation; not decided.
- Seam: fork-only `bin/fm-devin-lib.sh`, and the large fork diff in shared `tests/fm-devin-harness.test.sh`.
- Guard: `tests/fm-devin-harness.test.sh`.
- Upstream: now ships its own Devin adapter (upstream #5380); converging onto it while keeping `devin-permission-layer` would shrink the largest shared test diff.

### agy-adapter-mechanics

- Intent: the fork's first-class agy adapter, fork PRs 2, 3, 23, 33, and 38.
- Class: carried, open convergence question under investigation; not decided.
- Seam: fork-only `bin/fm-agy-lib.sh`, and the large fork diff in shared `tests/fm-agy-harness.test.sh`.
- Guard: `tests/fm-agy-harness.test.sh`.
- Upstream: ships its own agy adapter; converging onto it while keeping `agy-permission-posture` is the open question.

### worktree-leases

- Intent: durable Treehouse task leases, fork PRs 8 and 17; the fork dropped upstream's slot-claim files.
- Class: carried, open convergence question; not decided.
- Seam: fork-only `bin/fm-worktree-claims-lib.sh`, plus its shared callers.
- Guard: none identified.
- Upstream: has its own slot-owner claims, with further work in open PRs; which design is better is unresolved.

### claude-trust-escape

- Intent: decline Claude's external-import prompt correctly; fork PR 12.
- Class: carried.
- Seam: Claude trust handling (shared).
- Guard: `tests/fm-claude-trust.test.sh`.
- Upstream: still refuses on an Escape dismissal; drop once upstream adopts the fork's rule.

### pr-poll-identity

- Intent: inode-only identity where upstream admits a gap; fork PR 13.
- Class: carried.
- Seam: PR poll identity (shared); a small remainder after the last integration took upstream's stricter rule elsewhere.
- Guard: none identified.
- Upstream: drop once upstream closes the gap.

### doorbell-stranded-enter

- Intent: recover a stranded steering doorbell; fork PR 14.
- Class: carried.
- Seam: steering doorbell delivery (shared).
- Guard: none identified.
- Upstream: overlaps upstream PR #4485; drop once that lands equivalently.

### tmux-presence

- Intent: exact tmux session inventory, fork PR 15, now routed through upstream's window inventory (fork PR 47).
- Class: carried.
- Seam: the remainder in the tmux backend (shared).
- Guard: none identified.
- Upstream: drop the remainder once upstream's inventory covers it.

### rehold-reason

- Intent: preserve a captain-hold reason on re-hold; fork PR 10.
- Class: carried.
- Seam: `bin/fm-captain-hold.sh` (shared).
- Guard: fork-only `tests/fm-captain-hold-rehold.test.sh`.
- Upstream: not upstream; a candidate first contribution.

### stow-audit

- Intent: stow-pass before-state snapshot and verification; fork PR 9.
- Class: carried.
- Seam: `bin/fm-stow-audit.sh` and the stow skill.
- Guard: fork-only `tests/fm-stow-audit.test.sh`.
- Upstream: not upstream.

### claude-stop-fixes

- Intent: Claude StopFailure recovery, auto-arm timeout, away-digest integrity, and a dropped Enter on spawn; fork PRs 40, 41, 43, and 44.
- Class: carried.
- Seam: `bin/fm-claude-stop-autoarm.sh` (shared).
- Guard: `tests/fm-claude-stop-autoarm.test.sh`.
- Upstream: equivalence unknown; check each run.

### markless-op-header

- Intent: port of upstream #5149; fork PR 42.
- Class: carried.
- Seam: `bin/fm-operational-input.sh` (shared).
- Guard: `tests/fm-operational-input.test.sh`.
- Upstream: merged; the fork diff should now be zero, so verify and drop this entry.

## Incidental

- `codex-animation-port`: the fork's port of upstream #4297 (`tests/fixtures/codex-animation/`), which upstream replaced with #4532; kept for now at a known cost.
- `ci-shard-timeout`: a small `.github/workflows/ci.yml` difference awaiting CI samples.
- `muse-fixture-symlink`: fork PR 7, which upstream PR #3539 duplicates.
- Test adaptations in upstream-owned suites are not entries of their own; they ride under the entry whose behavior they pin, and the classification step flags any that pin nothing.
