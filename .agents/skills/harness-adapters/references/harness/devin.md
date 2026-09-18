# devin (Devin CLI)

Cognition's Devin CLI, verified on 2026-09-14 with devin-cli 3000.10.21 on macOS.
Verified for crewmate and scout work only, never a secondmate or primary.
`../../../../../bin/fm-spawn.sh` owns the concrete launch and hook mechanics.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `devin` resolved from `PATH` (e.g. `/opt/homebrew/bin/devin`, installed via Homebrew cask `devin-cli`). A single arm64 Mach-O binary. Refused at spawn when missing. |
| Launch | Positional prompt `-- "<prompt>"` starts the interactive session. `--print` / `-p` is headless and never used for a worker. |
| Directory grants | None needed; Devin CLI operates in the working directory. `--respect-workspace-trust false` bypasses the workspace trust prompt. |
| Approvals | Reviewed mode via `--permission-mode smart` for `auto` and `--permission-mode normal` for `manual`. Unconditional bypass (`dangerous`) is never emitted. The captain-approved non-destructive command set is pre-allowed in `.devin/config.local.json`, and firstmate's permission policy hooks refuse, approve, judge, or escalate the rest (see Approvals and permissions). |
| Busy state | `devin-hook`: `UserPromptSubmit` opens a turn (busy); `Stop` and `SessionEnd` close it (idle). `SessionStart` is omitted to avoid false busy on resume. Double-Escape interruption leaves the record busy. |
| Rendered tail | Delivery guard only via `(esc (twice\|again) to interrupt)`. Not a worker-state source. |
| Turn end | Native `Stop` hook in `$WT/.devin/config.local.json` touches `$TURNEND`. |
| Exit | Firstmate sends plain `exit`, one Enter (`fm_control_exit_command`). `/exit` is documented as an equivalent alias but is ambiguous against Devin's `/revert <step>` fuzzy slash-command search and was live-observed opening that menu instead of exiting; plain `exit` has no such ambiguity. |
| Interrupt | Double `Escape` (repeat 2) cancels the running turn. A single `Escape` displays `(esc again to interrupt)` for under 5 seconds. Devin prints `✱ Canceled. What should Devin do?` and leaves the composer empty. Interruption emits no `Stop` event and leaves the busy record unchanged. |
| Resume | `devin -c` / `--continue` for the most recent session, or `devin -r <SESSION_ID>` / `--resume <SESSION_ID>`. Session IDs are hyphenated word pairs (e.g. `aloud-powder`, `booming-flute`). |
| Models | `--model <model>`. |
| Effort | Interactive thinking levels (`Alt+T`) in TUI only; no CLI launch flag. Requested effort is recorded in task metadata only (record-and-omit). |
| Marker | `FM_DEVIN_HARNESS=devin` established at launch boundary by `bin/fm-spawn.sh` and verified against ancestry (`comm=devin`) in `bin/fm-harness.sh`. |
| Composer | Structured composer between a top mode rule (`──── (smart mode on) ─`), prompt row with `❭` (U+276D), and a solid bottom `─` rule, followed by a model and context footer (`Context: ... tokens`). Idle placeholder is `Ask Devin to build features, fix bugs, or work on your code`; busy placeholder is `Guide Devin while it works`. |
| Skill | Skills discovered in `.devin/skills/` and `.claude/skills/`. |
| Config | User config at `~/.config/devin/config.json`. Project local override at `.devin/config.local.json`. Passing `--config <path>` replaces the user config, while `.devin/config.local.json` merges with project and user settings. |
| Attribution | Defaults to `true` in Devin CLI, emitting `Generated with [Devin]` and `Co-Authored-By: Devin`. Firstmate pins `"attribution": false` in `.devin/config.local.json` and installs the same policy as the always-on rule `.devin/rules/firstmate-attribution.md`, because the vendor documents `attribution` as user-scope only. |

## Approvals and permissions

Devin CLI provides multiple permission modes: `normal` (alias `auto`), `accept-edits`, `smart`, and `dangerous` (alias `yolo`, `bypass`).
`config/crew-permissions` maps onto reviewed modes and never onto blanket bypass:

| Setting | Devin launch | Effect |
|---|---|---|
| `auto` (or absent) | `--permission-mode smart` | Smart mode auto-approves workspace file edits and shell appends outside the workspace. Prompts on commands outside smart model confidence and outside the pre-allowed set. |
| `manual` | `--permission-mode normal` | Prompts for all writes and shell commands. |
| anything else | refused | The launch stops; there is no fallback onto bypass. |

`--permission-mode dangerous` is emitted by neither setting and is never used.
This matches Firstmate's non-negotiable safety policy against unconditional bypass.
In smart mode, prompts for non-git commands present an 8-option menu:
`1 Yes (Approve once)`, `2 Yes, allow <command>`, `3 Yes, always allow ... in wt`, `4 Yes, always allow ... in all projects`, `5 Yes, switch to bypass mode`, `6 Edit command`, `7 Describe change to command`, `8 No`.
The worker may block on approvals for in-repo scripts; Firstmate delegates prompts or answers option 1 or 2, and must never choose options 3, 4, or 5 on the captain's behalf.
Under captain decision D1, Firstmate pre-allows `Exec(git commit)` and `Exec(git push)` in `.devin/config.local.json` so unattended worker ship turns do not park on git mutations.
The captain's 2026-09-14 extension of D1 widens `permissions.allow` to the rest of the routine command surface: `Exec(git checkout)`, `Exec(git remote)`, `Exec(git fetch)`, `Exec(git status)`, `Exec(git log)`, `Exec(git diff)`, `Exec(ls)`, `Exec(gh pr create)`, `Exec(gh pr view)`, `Exec(gh pr list)`, `Exec(gh pr checks)`, and the firstmate repo scripts `bin/fm-lint.sh`, `bin/fm-test-run.sh`, `bin/fm-install-shellcheck.sh`, `bin/fm-install-actionlint.sh` (each in its `bin/x`, `./bin/x`, and `bash bin/x` spellings).
`permissions.deny` holds `Exec(git push --force)`, `Exec(git push --force-with-lease)`, `Exec(git push --force-if-includes)`, and `Exec(git push -f)`, which override the allowed `Exec(git push)` prefix for those first-position spellings.

`Exec(...)` rules match each command segment by whitespace-token prefix: a segment must equal the rule text or begin with the rule text followed by a space, a compound command (`&&`, `;`, pipes) is split so each segment is judged on its own, and `*` is literal rather than a glob.
Two consequences follow: force flags in later argument positions (`git push origin --force`) and combined short flags (`git push -fv`) evade the deny list, and `bash tests/<name>.test.sh` cannot be pattern-allowed because the token after `tests` varies; the covered test path is `bin/fm-test-run.sh tests/<name>.test.sh`.
Not pre-allowed by design: `rm`, anything under `gh repo`, and any unconditional bypass.

### Permission policy hooks

Under the captain's 2026-09-15 posture decision, smart mode stays the default and `../../../../../bin/fm-devin-permission-policy.sh` is firstmate's decision layer on top of it; its header owns the refuse list, the read-and-build approve set, the judge contract, and the log format.
`bin/fm-spawn.sh` wires it as `PreToolUse`, `PermissionRequest`, `PostToolUse`, `UserPromptSubmit`, `Stop`, and `SessionEnd` hooks in `.devin/config.local.json`, pointing at the script under `bin/` and the per-task policy file `state/<id>.devin-permission.json`, both outside the worktree; Devin reads hooks once at session start.
It works by full-command inspection, so it covers what `Exec(...)` prefixes cannot: force pushes in any argument position, `gh pr create` without `--repo`, and every segment of a compound command.
- Refused outright: `sudo`, `launchctl`, any git push force, a recursive `rm` not strictly inside the worktree, `gh repo`, `gh pr create` without an explicit `--repo`, and any writer reaching the task's own brief.
- Approved silently: the read-and-build set, which includes read-only web lookups - a GET-shaped `curl` or `wget` to any host whose output lands on stdout, a pipe that is not a shell or interpreter, or a file inside the task's write roots.
- Judged: the residue goes to a headless SWE-2 High first judge (the policy file's `judge_model`, where the model id carries the effort level), and its approvals are silent too.
- Escalated: the never-approve class - outward actions such as a download that does something (a fetched page piped into an interpreter, written outside the task's write roots or into agent or git configuration including through a symlink, run or made executable, or a request carrying a body, a non-GET method, or local file contents like an @file header or a certificate) - plus whatever the judge declines and every judge failure, as a `needs-decision [key=devin-permission-<tool-use>]` status line naming the exact command and its reason, then Devin shows its normal prompt.
  Approving at the prompt closes the key through `PostToolUse`; a reject or interrupt fires no hook, so the key closes at the worker's next prompt or at session end.

Every refusal, approval, judge verdict, escalation, and escalation outcome is one JSON line in the home-wide `state/devin-permission-log.jsonl`, the evidence for tuning the approve set and the posture, for example `jq -s 'group_by(.decision) | map({decision: .[0].decision, n: length})' state/devin-permission-log.jsonl`.
Firstmate answers an escalation at the prompt or steers the worker; it never picks the menu's "always allow" or bypass options on the captain's behalf.
Never move a Devin worker to `--permission-mode dangerous` behind a deny list: under bypass, project `permissions.deny` and `permissions.ask` rules were observed not to bind, and `--sandbox` forces autonomous mode regardless of `--permission-mode` (`../../../../../docs/verification/runtime-backends.md`).

## Workspace trust

Every task worktree is a fresh path created for that task.
Without trust bypass, Devin stops on `✱ Do you trust the authors of this directory?` with options `1 Yes, trust` and `2 No, exit`.
Passing `--respect-workspace-trust false` ensures workspace trust prompts do not block unattended startup on fresh worktrees.

## Lifecycle hooks and configuration layers

Devin CLI reads configuration and hooks from three layers:
1. Global user config: `~/.config/devin/config.json`.
2. Committed project hooks: `.devin/hooks.v1.json`.
3. Project local config: `.devin/config.local.json`.

Under captain decision D2, Firstmate writes its per-task configuration and lifecycle hooks to `$WT/.devin/config.local.json`.
Writing to `.devin/config.local.json` avoids overwriting a project's committed `.devin/hooks.v1.json` and avoids using `--config`, which would override and drop the captain's user config.
`bin/fm-spawn.sh` refuses to launch if `.devin/config.local.json` or `.devin/rules/firstmate-attribution.md` already exists or is tracked by git.
Both files are added to `.git/info/exclude` so git status remains clean, and they are removed during teardown together with the permission policy file and its pending-escalation markers under `state/`.
The configuration pins `"attribution": false`; because the vendor documents that key as user-scope only, Firstmate also installs `.devin/rules/firstmate-attribution.md`, an always-on rule instructing the worker never to add `Generated with Devin`, `Co-Authored-By: Devin`, or other tool attribution to commit messages or pull request bodies.
The allowed and denied `Exec(...)` sets are owned by Approvals and permissions above.
The installed hooks in `$WT/.devin/config.local.json` cover:
- `UserPromptSubmit`: fires when a user submits a prompt, applying `busy` with event `user-prompt-submit`.
- `Stop`: fires when the turn ends, touching `$TURNEND` and applying `idle` with event `stop`.
- `SessionEnd`: fires when the session terminates, applying `idle` with event `session-end`.
- The permission policy hooks owned by Approvals and permissions above.

`SessionStart` is intentionally omitted because it fires on `resume` with an empty composer, which would strand a false `busy` state.
Each busy-state hook command appends `>/dev/null 2>&1 || true` so a refused event cannot break Devin CLI's lifecycle.
Double-Escape interruption emits no `Stop` hook and leaves the busy state unchanged, matching the behavior of agy and Claude.

## Claude hook import

Devin CLI automatically imports hooks from `.claude/settings.json`, `~/.claude/settings.json`, `~/.claude/settings.local.json`, and `~/.claude.json`.
It executes Claude hooks with `CLAUDE_PROJECT_DIR` set to the worktree path.
In linked worktrees for crewmate tasks, Firstmate's primary Claude hooks stand down safely because `fm_primary_scope_matches` rejects non-primary checkouts.
Devin's `read_config_from.claude` is left at its default `true` so `.claude/skills` and `CLAUDE.md` continue to load.

## Crewmate and scout only

Devin CLI has no primary supervision protocol in `docs/supervision-protocols/`.
`bin/fm-spawn.sh` explicitly refuses `--secondmate` launches on `devin`.
`bin/fm-control-lib.sh` restricts `fm_control_harness_supports_kind` so `devin` only supports `crew` and `scout` tasks.

## Model and effort

`bin/fm-spawn.sh` passes `--model <model>` when an explicit model is configured or requested.
Devin CLI does not provide a CLI flag for reasoning effort (thinking levels are interactive via `Alt+T` in the TUI).
Requested effort is recorded in task metadata and omitted from the launch command, following the record-and-omit contract.

## Composer and delivery

Devin CLI provides an interactive TUI composer.
The composer is structured between a top mode rule (e.g. `──── (smart mode on) ─`), an agent prompt row opening with `❭` (U+276D), a solid bottom rule `────────────────────`, and a model and context footer row (`SWE-2 Max Context: 13k / 262k tokens (5%)`).
`bin/fm-composer-lib.sh` classifies this structure into `empty`, `pending`, or `unknown`.
The idle placeholder `Ask Devin to build features, fix bugs, or work on your code` and the active-work placeholder `Guide Devin while it works` are recognized as composer furniture.
While Devin is busy thinking, the delivery token `(esc twice to interrupt)` (or `(esc again to interrupt)`) appears on the status line.
`bin/fm-composer-lib.sh` defines `FM_DELIVERY_DEVIN_BUSY_REGEX_DEFAULT='\(esc (twice|again) to interrupt\)'` to confirm submitted keystrokes.
Typing `!` on an empty composer enters bash mode; typing `exit` quits the session.
`/exit` is documented as an equivalent alias, but Firstmate never sends it: it is ambiguous against Devin's `/revert <step>` fuzzy slash-command search (see Exit mechanics below), so `fm_control_exit_command` sends plain `exit` for devin.

## Live verification evidence

Live verification was performed on macOS with Devin CLI 3000.10.21 (`devin 3000.10.21 (611c1cba)`) in a throwaway git repository.
The environment was authenticated with a Devin subscription (`Logged in (via Devin)`).

1. Binary execution and authentication:
   `devin version` printed `devin 3000.10.21 (611c1cba)`.
   `devin auth status` confirmed `Logged in (via Devin)`.
   Executable presence is verified via `command -v devin` before spawn.

2. Hook execution sequence:
   A test session with `.devin/config.local.json` verified that lifecycle hooks fire in sequence:
   `UserPromptSubmit` applies busy, `Stop` touches `$TURNEND` and applies idle, and `SessionEnd` applies idle on exit.
   `SessionStart` is omitted to prevent resume from stranding a false busy state.

3. Interactive TUI launch:
   Launching with `devin --permission-mode smart --respect-workspace-trust false -- "<prompt>"` in tmux rendered the TUI with smart mode active (`(smart mode on)`).
   The positional prompt arrived intact without blocking on workspace trust.

4. Interrupt mechanics:
   The TUI indicated `(esc twice to interrupt)` while thinking.
   A single `Escape` key displayed `(esc again to interrupt)`.
   A second `Escape` key delivered within 0.2s successfully interrupted execution, printing `✱ Canceled. What should Devin do?` and returning to an empty composer.
   Interruption emitted no `Stop` event, and the busy state conservatively remained busy.
   `fm_control_interrupt_repeat` was configured to `2`.

5. Exit mechanics:
   Typing `/exit` or `exit` followed by `Enter` fired `SessionEnd` (reason `prompt_input_exit`) and terminated the process cleanly in this isolated single-command probe.

6. Exit mechanics, `/exit` ambiguity (live-observed 2026-09-15, `fm-devin-harness-morning-ready-h9`):
   In a live worker session, sending `/exit` through `fm-control.sh exit` opened Devin's `/revert <step>` fuzzy slash-command search menu instead of exiting, and the control path's verified exit then timed out waiting for the process to end.
   Devin's own docs (`essential-commands.mdx`, `reference/commands.mdx`) document plain `exit` (no `/` prefix) as an equivalent, unambiguous alias that does not open the slash-command search.
   Firstmate's `fm_control_exit_command` now returns plain `exit` for devin (`bin/fm-control-lib.sh`); every other verified harness keeps its documented exit command unchanged.
