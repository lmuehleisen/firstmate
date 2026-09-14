# devin (Devin CLI)

Cognition's Devin CLI, verified on 2026-09-14 with devin-cli 3000.10.21 on macOS.
Verified for crewmate and scout work only, never a secondmate or primary.
`../../../../../bin/fm-spawn.sh` owns the concrete launch and hook mechanics.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `devin` from `PATH` (e.g. `/opt/homebrew/bin/devin`, installed via Homebrew cask `devin-cli`). A single arm64 Mach-O binary. |
| Launch | Positional prompt `-- "<prompt>"` starts the interactive session. `--print` / `-p` is headless and never used for a worker. |
| Directory grants | None needed; Devin CLI operates in the working directory. |
| Approvals | Reviewed mode via `--permission-mode smart` for `auto` and `--permission-mode normal` for `manual`. Unconditional bypass (`dangerous`) is never emitted. |
| Busy state | `devin-hook`: `SessionStart` and `UserPromptSubmit` open a turn (busy); `Stop` and `SessionEnd` close it (idle). |
| Rendered tail | Not a state source. |
| Turn end | Native `Stop` hook in `$WT/.devin/hooks.v1.json` touches `$TURNEND`. |
| Exit | `/exit`, one Enter. |
| Interrupt | Double `Escape` (repeat 2) cancels the running agent; Devin prints `Canceled. What should Devin do?` and leaves composer empty, so no clear key is needed. |
| Resume | `devin -c` / `--continue` for the most recent session, or `devin -r <SESSION_ID>` / `--resume <SESSION_ID>`. |
| Models | `--model <model>`. |
| Effort | Interactive thinking levels (`Alt+T`) in TUI only; no CLI launch flag. Requested effort is recorded in task metadata only (record-and-omit). |
| Marker | `FM_DEVIN_HARNESS=devin` established at launch boundary by `bin/fm-spawn.sh` and verified against ancestry (`comm=devin`) in `bin/fm-harness.sh`. |
| Composer | Interactive TUI composer. |
| Skill | Skills discovered in `.devin/skills/` and `.claude/skills/`. |
| Config | Global config at `~/.config/devin/config.json`. Project hooks at `.devin/hooks.v1.json`. |

## Approvals

Devin CLI provides multiple permission modes: `normal`, `accept-edits`, `smart`, and `dangerous`.
`config/crew-permissions` maps onto reviewed modes and never onto the blanket bypass:

| Setting | Devin launch | Effect |
|---|---|---|
| `auto` (or absent) | `--permission-mode smart` | Fast model judges safety, auto-approving routine dev work (build, test, lint) while mutating git commands prompt. |
| `manual` | `--permission-mode normal` | Prompts for all writes and bash commands. |
| anything else | refused | The launch stops; there is no fallback onto bypass. |

`--permission-mode dangerous` is emitted by neither setting and is never used.
This matches Firstmate's non-negotiable safety policy against unconditional bypass.

## Workspace trust

Every task worktree is a fresh path created for that task.
Passing `--respect-workspace-trust false` ensures workspace trust prompts do not block unattended startup on fresh worktrees.

## Lifecycle hooks

Firstmate installs task lifecycle hooks into `$WT/.devin/hooks.v1.json`.
In `.devin/hooks.v1.json`, the hooks object is the entire file with no top-level wrapper key.
The installed hooks cover:
- `SessionStart`: fires when a new session begins, applying `busy` with event `session-start`.
- `UserPromptSubmit`: fires when a user submits a prompt, applying `busy` with event `user-prompt-submit`.
- `Stop`: fires when the agent stops its turn, touching `$TURNEND` and applying `idle` with event `stop`.
- `SessionEnd`: fires when the session terminates, applying `idle` with event `session-end`.

Each hook command appends `>/dev/null 2>&1 || true` so a refused event cannot break Devin CLI's lifecycle.
The hook file is excluded from git tracking via the worktree's `info/exclude` and cleaned up at teardown.

## Crewmate and scout only

Devin CLI has no primary supervision protocol in `docs/supervision-protocols/`.
`bin/fm-spawn.sh` explicitly refuses `--secondmate` launches on `devin`.
`bin/fm-control-lib.sh` restricts `fm_control_harness_supports_kind` so `devin` only supports `crew` and `scout` tasks.

## Model and effort

`bin/fm-spawn.sh` passes `--model <model>` when an explicit model is configured or requested.
Devin CLI does not provide a CLI flag for reasoning effort (thinking levels are interactive via `Alt+T` in the TUI).
Requested effort is recorded in task metadata and omitted from the launch command, following the record-and-omit contract.

## Live verification evidence

Live verification was performed on macOS with Devin CLI 3000.10.21 in a throwaway git repository.
The environment was authenticated with a Devin Pro subscription.

1. Binary execution and authentication:
   `devin version` printed `devin 3000.10.21 (611c1cba)`.
   `devin auth status` confirmed `Logged in (via Devin)`.

2. Hook execution sequence:
   A test session with `.devin/hooks.v1.json` verified that lifecycle hooks fire in exact sequence:
   `session-start` -> `user-prompt-submit` -> `stop` -> `session-end`.
   The `Stop` event touched the turn-ended notification marker file as specified.

3. Interactive TUI launch:
   Launching with `devin --permission-mode smart --respect-workspace-trust false -- "<prompt>"` in tmux rendered the TUI with smart mode active (`(smart mode on)`).
   The prompt was received without blocking on workspace trust.

4. Interrupt mechanics:
   The TUI indicated `(esc twice to interrupt)` while thinking.
   A single `Escape` key displayed `(esc again to interrupt)`.
   A second `Escape` key delivered within 0.2s successfully interrupted execution, printing `✱ Canceled. What should Devin do?` and returning to an empty composer.
   `fm_control_interrupt_repeat` was accordingly configured to `2`.

5. Exit mechanics:
   Typing `/exit` followed by `Enter` fired the `SessionEnd` hook and terminated the process cleanly.
