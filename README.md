# ClaudeCron

A macOS menu bar app for scheduling and monitoring recurring [Claude Code](https://claude.com/claude-code) jobs - `claude -p` prompts that run unattended on a cron schedule, powered by native `launchd` under the hood. Arbitrary shell commands are supported too, so it doubles as a lightweight launchd GUI.

- **Menu bar dashboard** - every job with its status dot, last run outcome, next run time, and inline run/pause/stop buttons.
- **Manager window** - create and edit jobs, browse run history, read logs and results in place.
- **Airflow-style schedules** - plain 5-field cron expressions (`0 9,14,18 * * 1-5`) plus `@hourly` / `@daily` / `@weekly` aliases, translated into launchd `StartCalendarInterval` (including the cron day-of-month OR day-of-week rule, which launchd alone cannot express).
- **launchd does the scheduling** - jobs fire even when the app is not running. The app is a control panel, not a daemon.
- **Failure notifications** - from the app when it runs, via `osascript` fallback when it does not.
- **Import from Claude Desktop** - one click pulls your scheduled tasks (routines) out of the desktop app's local storage (`claude-code-sessions/**/scheduled-tasks.json` + their SKILL.md prompts) into ClaudeCron jobs. Imported jobs arrive paused so they never double-run while the original routine is still active.

## How it works

```
~/.config/claude-cron/jobs/<id>.json         job specs (editable by hand)
~/.config/claude-cron/jobs/<group>/<id>.json specs of grouped jobs
~/.config/claude-cron/bin/runner.zsh         runner, (re)installed by the app
~/Library/LaunchAgents/com.local.claudecron.<id>.plist   generated agents
~/Library/Logs/claude-cron/<id>/runs.jsonl               run journal
~/Library/Logs/claude-cron/<id>/<run>/run.log            stderr + diagnostics
~/Library/Logs/claude-cron/<id>/<run>/result.md          captured stdout
```

launchd starts the runner through a **login shell** (`zsh -l`), so your usual `PATH`, proxies and tokens from `~/.zshenv` / `~/.zprofile` apply - the same environment your interactive `claude` uses. The runner records start/finish events, captures the final answer of `claude -p` to `result.md`, and exits with the job's exit code.

Claude jobs run with `--dangerously-skip-permissions` by default (a toggle per job) - without it an unattended run would hang on the first permission prompt. Schedule only prompts you trust with that mode.

Overlap protection comes from launchd itself: a job whose previous run is still alive is not started again. Calendar runs missed during sleep are coalesced into one run on wake.

## Job spec

```json
{
  "id": "daily-digest",
  "name": "Daily digest",
  "kind": "claude",
  "prompt": "Summarize yesterday's work journal for my standup.",
  "workdir": "/Users/me/dev/my-repo",
  "schedule": "0 9 * * 1-5",
  "model": null,
  "extraArgs": "",
  "skipPermissions": true,
  "notifyOnSuccess": false,
  "enabled": true
}
```

`kind: "shell"` replaces `prompt` with `command` and runs it verbatim through `/bin/zsh -c`. `workdir` matters for Claude jobs: project-scoped skills, agents and MCP servers are picked up from the working directory's `.claude/`. `model` takes an alias (`opus`, `sonnet`, `haiku`) or a full model ID; `effort` is one of `low`/`medium`/`high`/`xhigh`/`max`.

## Telegram notifications

Settings (gear button in the Manager) hold a bot token and chat ID (`~/.config/claude-cron/config.json`, chmod 600). Create a bot via [@BotFather](https://t.me/BotFather), message it once, and use **Detect** to pick up your chat ID; **Send Test** verifies the pipe. An optional API base override supports self-hosted bot-api proxies.

Jobs with **Send result to Telegram** enabled post a message after every run: a status header (job name, ok/exit code, duration) plus the captured stdout - for Claude jobs that is the model's final answer, so the cleanest way to shape the message is to end the prompt with an instruction like "finish with a short summary". Failed runs attach the log tail instead. Messages are truncated to Telegram's limit. The runner does the sending, so it works with the app closed; delivery failures are recorded in the run log and never affect the job's exit code.

For full deliveries - entire reports, rendered HTML, images - use the **outbox**: the runner exposes `$CLAUDE_CRON_OUTBOX` (a per-run directory) to the job, and after a successful run everything in it goes to the chat in filename order (`01-`, `02-`, ... prefixes control it). The extension decides the shape:

| Extension | Delivery |
|---|---|
| `.md` `.txt` `.log` | appended to the status header and sent as messages, auto-split at Telegram's limit with `(i/n)` numbering |
| `.tgh` | same, but passed through as Telegram-flavoured HTML (`<b>`, `<i>`, `<a href>`); a rejected message is retried as plain text so nothing is lost |
| anything else | uploaded via `sendDocument` (up to 50 MB) |

An empty outbox falls back to the stdout summary; failed runs always use the failure format. The "template" is thus the prompt itself - tell the job what to drop into the outbox.

## Groups & colors

Jobs can be organized into groups and tagged with one of six colors (`red`, `orange`, `yellow`, `green`, `blue`, `purple`). Groups render as sections in the panel and the Manager sidebar; the color shows as an accent bar on the job row.

A group is literally a subdirectory of the jobs folder - the file's location is the source of truth, so moving `jobs/foo.json` into `jobs/work/` regroups the job on the next panel open. The Manager has shortcut buttons to open the jobs folder in Finder or to start a Claude session in Terminal right there, so you can manage job specs conversationally; the runner resolves a job by its id in any group.

## Build & install

Requires macOS 14+ and Xcode Command Line Tools (no full Xcode needed).

```sh
make test     # cron engine test suite
make install  # build, ad-hoc sign, install to ~/Applications
open ~/Applications/ClaudeCron.app
```

## Environment overrides

| Variable | Purpose |
|---|---|
| `CLAUDE_CRON_CONFIG` | config dir (default `~/.config/claude-cron`) |
| `CLAUDE_CRON_LOGS` | logs dir (default `~/Library/Logs/claude-cron`) |
| `CLAUDE_CRON_BIN` | claude binary (default `claude` from `PATH`, with common fallbacks) |

## Notes

- Saving a job re-registers its launchd agent; if a run is in progress at that moment, it is terminated.
- Deleting a job removes the agent and optionally its logs.
- The app offers itself as a login item on first launch; jobs do not depend on it either way.

## License

MIT
