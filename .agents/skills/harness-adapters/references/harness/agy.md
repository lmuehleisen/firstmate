# agy (Antigravity CLI)

Google's Antigravity CLI, verified end to end on 2026-09-10 with agy 1.2.0 on macOS.
Verified for interactive primary, secondmate, crewmate, and scout work.
`../../../../../bin/fm-spawn.sh` owns the concrete launch and grant mechanics.
agy self-updates aggressively and without asking - it moved 1.1.25 -> 1.1.28 -> 1.2.0 during the session that verified it - so treat every version-scoped fact here as refreshable rather than settled, and re-run the live guard after an upgrade.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `agy` from `PATH`, resolved once and refused if absent. A single self-updating Go binary; the installed path is the real executable, not a launcher. |
| Launch | `-i "<prompt>"` runs the opening prompt and KEEPS the interactive session. `-p` is a one-shot headless run and is never used for a worker. |
| Directory grants | `--add-dir`, repeatable, and MANDATORY - see "The worktree grant" below. |
| Approvals | No reviewed-auto mode. `--mode accept-edits` covers file edits only; shell commands always prompt. See "Approvals" below. |
| Busy state | `agy-hook`: PreInvocation opens; fullyIdle Stop closes. The worker binds its generation and main conversation; interruption emits no Stop and conservatively leaves busy. |
| Spawn start | A ship or scout spawn reports success only after the worker hook's PreInvocation record replaces spawn's seed; otherwise it records a failure and closes the endpoint, so an agy launch parked before its first model call never looks dispatched. `../../../../../bin/fm-spawn.sh` owns the bound. |
| Rendered tail | Not a state source, but the running turn's footer is the one ASCII busy token: `esc to cancel` while a turn runs, `? for shortcuts` when idle. The right of the footer names the active mode and model, e.g. `accept-edits · Gemini 3.8 Flash · medium`. |
| Turn end | Native Stop; see "Native hooks and primary integration" below. |
| Exit | `/exit` (alias `quit`), one Enter; prints `Resume with -c (or command below): agy --conversation=<uuid>`. |
| Interrupt | Single `Escape`, which prints `Interrupted · What should Antigravity CLI do instead?` and leaves the composer EMPTY, so no clear key is needed. |
| Resume | `agy -c` / `--continue` for the most recent conversation, or `agy --conversation=<uuid>` from the id printed at exit. |
| Models | `--model <model>`; `agy models` lists the account's ids. Effort is also encoded as a model-id suffix - see "Model and effort". |
| Effort | `--effort low|medium|high` ONLY; anything above is refused. See "Model and effort". |
| Marker | `JETSKI_APP_DATA_DIR=antigravity-cli` on tool subprocesses, alongside `ANTIGRAVITY_LS_VERSION=cli-<version>`, `ANTIGRAVITY_PROJECT_ID`, `ANTIGRAVITY_TRAJECTORY_ID`, `ANTIGRAVITY_LS_ADDRESS`, and `ANTIGRAVITY_SOURCE_METADATA`. agy does NOT set `GEMINI_CLI`. |
| Composer | `>` between solid rules and the native footer; `../../../../../bin/fm-composer-lib.sh` owns shape and placeholder classification. |
| Skill | `/<skill>`; typing `/` opens a filtered command menu and ONE Enter selects and submits. |
| Config | Global user settings at `~/.gemini/antigravity-cli/settings.json`; shared customization (hooks, skills, plugins, per-project settings) under `~/.gemini/config/`. Firstmate writes none of it. |

## Not the Gemini CLI

agy shares the `~/.gemini` configuration root with Google's separate `gemini` adapter and is a different tool with a different launch, approval model, and hook story.
Detection keeps them apart on their own markers: agy publishes `JETSKI_APP_DATA_DIR=antigravity-cli` and no `GEMINI_CLI`, and the value is the CLI's exact app-data directory, which the Antigravity IDE does not share (the IDE keeps state under `~/.gemini/antigravity`).
`JETSKI_APP_DATA_DIR` is tested before the `CLAUDECODE` line because whether agy scrubs an inherited Claude marker was NOT verified; ordering it first is correct either way, and the launch clears the foreign markers as defense in depth.

## The worktree grant

Every launch must pass `--add-dir` for the task worktree, and every granted path must be PHYSICALLY RESOLVED.

Both halves are load-bearing, and each fails in its own quiet way:

- With no grant, agy does not refuse and does not prompt.
  It writes into its own scratch directory (`~/.gemini/antigravity-cli/scratch`) while the model reports success, so the worker looks productive and the task's local copy never changes.
- With an unresolved grant whose parent is a symlink, agy resolves the path before testing it against the granted workspace, decides its own worktree is outside it, and parks on `Allow creation of this file? ... Reason: outside workspace`.

A resolved grant also keeps agy's workspace-trust dialog off the launch path entirely.
That dialog is not merely an extra keystroke: accepting it appends the path to `trustedWorkspaces` in the operator's own global settings, so a launch that raises it grows a file Firstmate does not own, once per task worktree, forever.
Trust is not inherited from a parent directory, so every fresh worktree would raise it.

`../../../../../bin/fm-spawn.sh` owns the resolved directory grants, including the worker hook directory.

## Approvals

agy has no equivalent of Claude's reviewed `--permission-mode auto` or Codex's `--approve-for-me`.
Its three options are the default review mode, `--mode accept-edits`, and the blanket `--dangerously-skip-permissions`.

`config/crew-permissions` therefore maps onto the middle option and never onto the blanket one:

| Setting | agy launch | Effect |
|---|---|---|
| `auto` (or absent) | `--mode accept-edits` | File edits auto-approved inside the granted directories. Shell commands still prompt. |
| `manual` | no `--mode` flag | agy's default review mode; edits prompt too. |
| anything else | refused | The launch stops; there is no fallback onto the bypass. |

`--dangerously-skip-permissions` is emitted by neither setting and is never a fallback when a worker parks.
That is deliberate and matches the captain's standing preference for reviewed permissions over unconditional bypass; it is also the first thing anyone will be tempted to add the first time an agy worker blocks, so it is pinned by test.

**`accept-edits` covers file edits, not shell commands.**
Verified: under `--mode accept-edits` a write through the file tool completed with no prompt, while `date` was still denied headless and still prompted interactively.

### Expect an agy worker to block

This is the adapter's defining operating characteristic, not a defect to route around.

The prompt is a rendered, answerable choice, so the stall is visible to a supervisor rather than silent:

```
Requesting permission for:
   <command>
Run this command?
> 1. Yes, run command
  2. Yes, and always allow in this conversation for commands that start with '<prefix>'
  3. Yes, and always allow for commands that start with '<prefix>' (Persist to settings.json)
  4. No, cancel
```

Option 2 grants for the rest of that conversation without touching any file; option 3 persists into the operator's global settings and should not be chosen on their behalf.
A denial is handled cleanly - the pane prints `⎿ User declined the tool call` and stays usable.

Two consequences worth planning around, both observed in a real spawn:

- The standard brief's status protocol is an `echo ... >>` shell command, so an agy worker requests approval for **every status line it appends**, including its final `done:`.
- The model chooses its own tool.
  `gemini-3.8-flash` frequently writes files with a shell heredoc rather than the edit tool, and those writes prompt even under `accept-edits`.

There is no per-session or per-project allow-list Firstmate can set to soften this, and no hook can substitute for one.
`permissions.allow` (entries like `command(ls)`) is read only from the operator's global `settings.json`, with per-project overrides under `~/.gemini/config/projects/`; a workspace-local `.agents/settings.json` is NOT loaded, verified with the workspace trusted.
Both usable locations are the operator's own machine state, so Firstmate does not write them.
Verified on agy 1.2.4 and 1.2.5: a `PreToolUse` hook fires for every tool class and can `deny` with a reason the model reads, `force_ask` a prompt past the allowlist, or rewrite arguments through `overwrite`, but it cannot approve - `decision:"allow"` still shows the ordinary prompt and `permissionOverrides` grants nothing.
An operator who wants a quieter agy worker can add their own allow rules there deliberately.

Headless `-p` runs behave differently and are not the worker path: a tool needing approval is auto-denied with a stderr notice naming the missing rule, and the run still exits 0.

### Opt-in bypass permission layer

`../../../../../bin/fm-spawn.sh --agy-bypass` is a separate, per-spawn opt-in path that pairs `--dangerously-skip-permissions` with a firstmate-owned policing adapter, `../../../../../bin/fm-agy-permission-policy.sh`, wired beside the observer hooks by `install-worker`'s optional policy argument.
It is never selected by default, applies to scout spawns only, and is never a fallback: an unmet gate refuses the launch rather than emitting a bare bypass, and a relaunch inherits the recorded posture only while it still resolves onto an agy scout.

Under bypass the hook decision surface collapses to two effective outcomes, verified live on agy 1.2.6: `deny` still blocks with its reason, and abstention runs the call - `allow`, `ask`, and even `force_ask` have no prompt left to act on, so they cannot surface a question.
The adapter therefore emits only `deny` or silence; every "ask the human" case denies with `held for firstmate`, writes a pending marker under `<policy>-pending/` keyed `agy-permission-<conversationId>-s<stepIdx>`, and appends a `needs-decision` status line.
A held call is binding: a retry is matched against the open marker and the declined record before any cache lookup or judge run, so the same call can never run on a re-judged verdict or a shifted step index - only a firstmate `approve` opens it, and `decline` leaves a durable record that stops the retry from re-escalating.
An approval lands in the per-task verdict cache for ordinary calls; for a never-approve class it is a one-shot token that the authorized retry consumes.
Markers deliberately survive `Stop` - nothing in a bypassed session is still waiting, so the marker means "firstmate still owes this call a decision" and closes only on approve, decline, a retried call's PostToolUse, or `retire`.

File-tool writes are checked against the resolved physical path, so a symlink cannot route a `write_to_file` outside the task roots, and a target under `.agents/`, `.git/`, or firstmate's own worker wiring is refused outright.
Under bypass a statically visible exec write or removal outside the task write roots is refused rather than judged - there is no native prompt behind the judge to correct a bad verdict - while credential reads are refused rather than escalated.
The remaining surface is inherent to a lexical policy: a refused command reached through an interpreter, encoded pipe, alias, or expansion is not statically visible, so it still reaches the judge, and no lexical layer can close that reach.

Defences that gate the launch: `jq` present, the agy version inside the adapter's live-verified set (`verified-versions`, currently `1.2.4 1.2.5 1.2.6 1.2.7`), no project-supplied `.agents/hooks.json` in the worktree or ancestors up to the git root (one malformed entry silently disables every hook in that file, firstmate's denies included), and a startup canary that closes the endpoint when the adapter's armed line for this launch's busy generation never reaches the observer log.
The judge is selected per task from the tiers `../../../../../bin/fm-judge-tier-lib.sh` owns, and agy judges agy by default: without `--agy-judge` the tier calls `agy -p` under its own sandbox on `gemini-3.6-flash-low`, with a 100-second budget pinned beside the Devin adapter's, and its prompt rides on the process argument list, so a call under review is visible in `ps` while the judge runs.
`--agy-judge <tier>[:<model>]` selects another tier - a Devin SWE-2 judge for an agy worker, for instance - and refuses the launch when the tier is unknown or its executable is not installed, rather than falling back onto the default.
The resolved tier is printed before the launch, repeated on the spawned line, recorded as `agy_judge=` in the task's metadata, and named in every judge-decided log record, so which judge adjudicated a call stays readable after teardown removes the per-task policy file.
The layer's decision log is the same `state/agy-permission-log.jsonl` the observer writes.
`judge-probe` runs the same static analysis and judge call on a payload and prints the verdict while writing nothing, so tiers can be compared on identical inputs.

## Native hooks and primary integration

The working hook schema is a named definition in `.agents/hooks.json`, with direct handlers for PreInvocation and Stop and matcher groups for PreToolUse and PostToolUse.
Hooks run from the customization directory containing that file, so the tracked primary registration addresses its executable relative to `.agents/`.
Local hooks in a separately granted directory also execute; `../../../../../bin/fm-agy-hook.sh` uses that capability to keep worker hooks in owned state without modifying project or global configuration.
The earlier no-hook conclusion is superseded by the positive live guards.
agy bundles the authoritative hook spec inside the binary itself: `strings -n 4 "$(command -v agy)"` from the `# Lifecycle Hooks` line yields the full `hooks.json` reference, byte-identical across 1.2.4 and 1.2.5 - but matcher names are the observed function names (`write_to_file`, `list_dir`), not the spec's documented step-type derivation.
One malformed entry anywhere in a `hooks.json` silently disables every hook in that file, so `fm-agy-hook.sh install-worker` validates the merged file it writes; a project-supplied `.agents/hooks.json` can still take the worker hooks down with it.
Worker hooks additionally carry a log-only observer: every tool call appends one line to `state/agy-permission-log.jsonl`, the request record agy workers otherwise lack for permission-posture review, and `../../../../../bin/fm-agy-hook.sh` owns the schema.

Primary support composes the existing startup nudge, shared pre-tool policies, and turn-end predicate through the native transport.
`../../../../../docs/sessionstart-nudge.md` owns the nudge tier and unverified compaction boundary.
`../../../../../docs/turnend-guard.md` owns Stop continuation, its executionNum loop bound, and the manual-interruption gap.
`../../../../../docs/supervision-protocols/agy.md` owns the verified native background-command wake protocol.
A completed native command re-enters the model automatically.
The session-lock owner recognizes the exact agy process, including the long-lived language-server process that parents hook and tool commands.

Worker hooks report through the semantic busy owner and emit turn-ended notifications only after an accepted fullyIdle Stop.
PreInvocation may repeat during a turn, and Stop with fullyIdle=false does not clear busy while background work remains.
Escape supplies no semantic cancellation acknowledgement; lifecycle control reports delivery and endpoint liveness only.
Missing or invalid hook data never manufactures idle.

Composer delivery needs the native footer or accept-edits mode cell as well as the rule pair and prompt.
An unstyled accept-edits hint, a manual-mode row with no identifying footer, and rendered busy-only acknowledgement of a queued Enter remain unproven; the adapter does not manufacture a successful delivery for them.
Native background-task observation uses the returned log with `view_file`; delegation-shaped native tools retain the shared pre-tool guard.

Unsupported surfaces remain explicit: headless primary supervision, native SessionStart and compaction refresh, semantic interrupt completion, automatic shell approval, and a quota-provider mapping in the optional `fm-quota-choose.sh` helper are not supported by this integration.
Use the current Agy catalog and agent-side quota procedure instead of inferring its provider from another Google harness.
Runtime backend lifecycle guarantees remain those of each backend's capability table; the live verification here covers tmux on macOS.
Remote secondmate launch and relaunch remain unsupported and are refused by `../../../../../bin/fm-remote-secondmate-control.sh`; that Herdr-only path is separate from the verified local secondmate integration.

## Model and effort

`../../../../../bin/fm-spawn.sh` passes the selected model without pinning a default.

Effort is published TWICE and the two forms conflict:

- `agy models` lists effort-suffixed ids: `gemini-3.8-flash-high`, `-medium`, `-low`.
- `--effort low|medium|high` is a separate flag.

Passing both refuses the launch: `--model gemini-3.8-flash-high --effort low` exits with `--model gemini-3.8-flash-high conflicts with --effort=low`.
The unsuffixed base id is accepted even though the listing does not show it, and composes with the flag.
The adapter therefore emits at most one: a model id already carrying a level wins and no effort flag is sent.

Firstmate's `xhigh` and `max` are above agy's ceiling - `--effort xhigh` is refused with `invalid --effort "xhigh" (valid: low, medium, high)` - so both cap onto `high` rather than being dropped, per `../common/model-and-effort.md`.
The requested level stays recorded in task metadata.

## Interruptions Firstmate cannot suppress

agy periodically renders a feedback survey in the pane:

```
 How's the CLI experience so far? Help us improve:
 [1] Good  [2] Fine  [3] Bad  [0] Skip
```

It appeared mid-task during a real spawn and waits for a keypress (`0` skips).
The control is the global `showFeedbackSurvey` setting; agy exposes no launch flag or environment variable for it, so Firstmate cannot disable it per launch the way it disables Claude's feedback prompts.
Treat it as another reason an agy pane can sit idle-looking with work outstanding, and as something an operator can turn off in their own settings if it becomes a nuisance.

## Verification

`../../../../../docs/verification/runtime-backends.md` owns the dated evidence.
`tests/fm-agy-harness.test.sh` is the portable regression.
The credentialed guards are `tests/fm-agy-signals-live-e2e.test.sh` (`FM_AGY_SIGNALS_LIVE=1`) and `tests/fm-agy-primary-live-e2e.test.sh` (`FM_AGY_PRIMARY_LIVE=1`).
