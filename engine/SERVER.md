# Running the engine on a server

The engine was built to run beside the Bulava app on a Mac. It also runs unattended on a Linux VM
(Ubuntu 24.04, x86_64 or arm64), fed by a bridge that reads tasks from a tracker and publishes the
reviewed result. This file is the contract between the engine and such a bridge.

Everything here is switched on by one variable, set by whoever runs the service:

```
SUPERVISOR_PROFILE=server
```

Without it nothing in this file applies, and a terminal or the Mac app behaves exactly as before.

## What the profile changes

| | Off a server | `SUPERVISOR_PROFILE=server` |
|---|---|---|
| Somebody at the machine | assumed | never (`SUPERVISOR_UNATTENDED=1`) |
| CLI settings file `~/.config/night-shift/config.json` | read | **not read** — it is a file the agent can write |
| Skills fetched from the internet on a start | after an audit | **never** (`SUPERVISOR_SKILL_AUTONOMOUS=0`, forced) |
| Write fence (`SUPERVISOR_SCOPE_GATE`) | can be switched off | **always on** |
| `bypassPermissions` | allowed | becomes `auto` |
| Codex out of quota for long | a card in the app | operator's policy, see below |
| A question only a person can answer | held for up to an hour | the attempt ends as `needs_input` |
| Uncommitted tree at start (code 77) | the app asks | refused (`--dirty=fail` by default) |
| Settled attempt | session stays at its prompt | session is stopped; the task lives on |
| Reading `~/.ssh`, `~/.codex/auth.json`, `~/.claude/.credentials.json`, glab/gh config | allowed | denied (permission rules + a Bash check) |
| `git push`, `glab`, `gh` from inside a run | allowed | denied — the bridge publishes |
| tmux server | the user's default | its own socket (`SUPERVISOR_TMUX_SOCKET=bulava`) |

The bridge's own secrets on the same machine are added to both layers with
`SUPERVISOR_SERVER_EXTRA_SECRET_PATHS` — paths separated by spaces, each starting with `~/` or `/`
(a file or a folder; globs and `..` are ignored), set in the service's environment:

```
SUPERVISOR_SERVER_EXTRA_SECRET_PATHS="~/runner/secrets.env ~/runner/bulava.env ~/runner/runner.db"
```

These are layers, not a sandbox. The agent runs as the same user as the engine, so the isolation
boundary is the VM itself: keep the GitLab token out of the agent's reach (the bridge pushes), keep
outbound traffic on an allowlist, and protect `main` on the GitLab side.

## Preparing a VM

```bash
# engine — the current main branch of the public repository (run it again to update):
curl -fsSL https://bulava.app/install.sh | bash
# …or the same main as a checkout, updated with `git pull` and install.sh again:
git clone https://github.com/Stepanokdev/bulava ~/bulava && bash ~/bulava/engine/install.sh
# A checkout can also stay on one commit (`git checkout <commit>`) when a server must not move.

# a browser for runs that need one (x86_64: Google Chrome; arm64: the distribution's Chromium)
sudo apt install ./google-chrome-stable_current_amd64.deb      # or: sudo snap install chromium
npm install -g chrome-devtools-mcp@1.10.1                       # so nothing is fetched on a start

# sign-in, once per machine
claude setup-token          # long-lived subscription token → CLAUDE_CODE_OAUTH_TOKEN
codex login --device-auth

# every repository a task may touch: trusted by Claude, MCP servers decided
night-shift trust /work/acme/api /work/acme/web
night-shift mcp-decide /work/acme/api skip
```

Point the headless browser at the installed server instead of `npx`:

```json
{"mcpServers": {"browser": {"command": "chrome-devtools-mcp",
  "args": ["--headless", "--isolated", "--executablePath", "/usr/bin/google-chrome-stable"]}}}
```

```
SUPERVISOR_AUTOMATION_MCP_CONFIG=/etc/bulava/browser-mcp.json
```

Without that file the engine uses `npx -y chrome-devtools-mcp@1.10.1` and, on Linux, adds
`--executablePath` for the Chrome or Chromium it finds when Google's own path is empty.

## A service for the engine's tmux server

Workers run in tmux, and a tmux session inherits the environment of the tmux *server*, not of the
process that asked for the session. Start that server from systemd so every worker gets the service's
environment, the sign-in token among it:

```ini
# /etc/systemd/system/bulava-engine.service
[Unit]
Description=Bulava engine (tmux server for workers)
After=network-online.target

[Service]
Type=forking
User=agent
Environment=SUPERVISOR_PROFILE=server
Environment=SUPERVISOR_CODEX_UNAVAILABLE=fail
Environment=SUPERVISOR_CODEX_UNAVAILABLE_AFTER_HOURS=3
# CLAUDE_CODE_OAUTH_TOKEN, HTTPS_PROXY, … — mode 600, never on a command line
EnvironmentFile=/etc/bulava/env
ExecStart=/usr/bin/tmux -L bulava new-session -d -s keeper 'sleep infinity'
ExecStop=/usr/bin/tmux -L bulava kill-server
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

The bridge's own unit sets the same `SUPERVISOR_PROFILE` and `EnvironmentFile`, and
`KillMode=process`, so restarting the bridge does not take the watchdogs it started with it. A
watchdog that died is started again by the next `dispatch.sh` for that folder.

## Tasks

A task is named by the bridge (`PRJ-123`) and outlives every session it runs in:

```
$SUPERVISOR_STATE_DIR/tasks/index.json           task id → key
$SUPERVISOR_STATE_DIR/tasks/<key>/task.json      the record
$SUPERVISOR_STATE_DIR/tasks/<key>/material/      runspec, plan, research of the first attempt
$SUPERVISOR_STATE_DIR/tasks/<key>/events.jsonl   the task's own event stream
```

The folder is a hash of the id; the id is never used as a path. Session cleanup (`stop`, the idle
timers) removes instance directories only, never a task.

States: `queued` → `running` → one of the states below. `queued` lasts only from the moment the record
is created to the moment its first attempt is written, inside one `dispatch.sh` call; read it as
`running`. A follow-up moves it back to `running`.

| state | comes from | what the bridge does |
|---|---|---|
| `running`, `attempt_live: true` | an attempt is working | wait; follow-ups get `busy` |
| `running`, `attempt_live: false` | the session died under the attempt (reboot, crash) | send the work on: `worker-send --relation continue` |
| `waiting_review` | Codex passed, the worker declared `succeeded_changes` | push `receipt.repos[].reviewed_sha`, open or update the MR, wait for review |
| `done` | Codex passed, the worker declared `succeeded_no_change` or `succeeded_research` | comment the result, nothing to push |
| `needs_input` | a question only a person can answer (`question.id` may be `null` when the worker asked in its own words) | put `question` on the ticket; send the answer with `--answers <id>` when there is one, plain `continue` otherwise |
| `blocked` | the worker declared `blocked`: missing access or an external wall, named in `outcome.summary` | put the summary on the ticket; continue once a person has acted |
| `failed` | anything else: `debt`, round limits, uncommitted work, `failed`, `reason: codex_unavailable` | put `state_reason` and the summary on the ticket; a later `continue` starts a new attempt |

`state_reason` is the outcome's `reason` when the engine wrote one (`codex_unavailable`), `stalled`
when the watchdog parked the run, otherwise the gate's disposition.

**Stalled.** The watchdog parks a run that sits at its prompt for `SUPERVISOR_STALL_PARK_SECS`
(900 s) with no turn running and nothing settled; its task becomes `failed`, `state_reason: stalled`.
"No turn running" is the Claude CLI's own busy/idle status, so a long build or test is never idle.
Nothing parks while a result is declared, a usage pause holds (including `CODEX_UNAVAILABLE=wait`),
a question is open, a review is running, or the network is down.

**Continuing a `failed` task** — stalled, debt, Codex away — is an ordinary follow-up: `worker-send
--relation continue` returns 0 with `TIER=dispatched` and starts a fresh attempt; only a `running`
task with a live session answers `busy`.

### Starting a task

```bash
dispatch.sh --task-id PRJ-123 --message-id yt-PRJ-123 \
            --source youtrack --author alice \
            --branch agent/PRJ-123-health --base origin/main \
            [--runspec spec.json] [--dirty fail] \
            /work/acme/api "Task text from the tracker"
```

Other repositories the task may change go in `SUPERVISOR_EXTRA_DIRS_FILE` (one path per line), with
the writable ones listed in `writable-directories.txt` beside it. Create the task branch in each of
them before dispatching.

| exit | stdout | meaning |
|---|---|---|
| 0 | `TIER=dispatched` + `{"task_id","dispatch_id","attempt","message_id"}` | accepted |
| 0 | `TIER=duplicate` + the earlier acceptance | this message id was already taken |
| 2 | — | bad arguments, empty task, unreadable runspec, or an existing task id |
| 4 | `TIER=conflict` | same message id, different text — the only meaning of 4 here |
| 6 | `TIER=busy` | an attempt of this task, or another task in this folder, is running |
| 76–79 | — | start refused: no git, dirty tree, undecided MCP servers, oversized checkpoint |

Text that came from people is framed as `<<UNTRUSTED_TRACKER_TEXT source=… author=…>>` for the worker
and the reviewer.

### Follow-ups: review comments, answers, red CI

```bash
worker-send.sh --task-id PRJ-123 --relation continue --message-id mr-881-note-5 \
               --source mr --author bob [--answers q-…] \
               /work/acme/api - - - "Rename the endpoint to /healthz"
```

`--relation` is required on a server; nothing guesses whether a message is a new task. A follow-up
is a new attempt in a fresh session, briefed from the record: the original goal and criteria, the
branches and their commits, the question it answers, and the new text. It is reviewed against the
original runspec and plan, as the whole branch from the task's first base.

| exit | stdout | meaning |
|---|---|---|
| 0 | `TIER=dispatched` + JSON | the next attempt started |
| 0 | `TIER=duplicate` + JSON | already taken |
| 2 | — | `continue` for an unknown task, `new` for an existing one, bad arguments |
| 4 | `TIER=conflict` | same message id with other text, or `--answers` for a question that is not open (stale, answered, or of another attempt). On a server nothing else returns 4: the live-session run conflicts of the app's chat path are never reached |
| 6 | `TIER=busy` | an attempt is running — keep the message and send it after the verdict |

### Reading the result

```bash
night-shift task show --task-id PRJ-123 --json
night-shift task events --task-id PRJ-123 --after <seq>
night-shift task list --json
```

`task show` returns the state, `attempt_live` (false for a `running` record whose session is gone,
e.g. after a reboot), the question for `needs_input`, the attempts, and the last receipt and outcome.

Publish only when `receipt.review == "passed"`. For each entry in `receipt.repos`:

```json
{"path": "/work/acme/api", "branch": "agent/PRJ-123-health",
 "base_sha": "…", "reviewed_sha": "…", "clean": true}
```

push `reviewed_sha` when it differs from `base_sha` and the repository's `HEAD` still equals it.
`debt` is not accepted. A run that declares `succeeded_changes` with uncommitted work is sent back to
commit before Codex reviews it — the same attempt, no Codex call — and after three such stops it ends
as `failed`. Whatever path a pass takes, a pass over any uncommitted repository is settled as
`needs-user` instead, so `review: "passed"` with `clean: false` never happens.

Verification follows the work: every extra repository that changed (HEAD ≠ base, or uncommitted) is
checked inside itself with the same plain detection as the main folder (`verify.sh`, `make verify` or
`test`, `pytest`, `npm test`), and checks the worker registered with `add-check` count as
verification — "no automated verification available" is reported only when nothing at all ran.

Extra repositories are in `receipt.repos` already, with their own base and reviewed commit; tasks that
touch several repositories work today, as long as `SUPERVISOR_EXTRA_DIRS_FILE` names them on every
`dispatch.sh` and `worker-send.sh` call and their branches exist.

Outcome reasons the engine writes itself: `codex_unavailable` with `codex_reason` one of `quota`,
`auth`, `network`, `timeout`, `unknown`.

### Being told instead of polling

```
SUPERVISOR_ON_OUTCOME=/usr/local/bin/bridge-notify
```

Run detached with the path to `task.json` as its argument and `TASK_ID`, `TASK_STATE` in its
environment, ten seconds at most, whenever an attempt ends. The state is on disk before the call. It
is a hint: a crash between the two means no call, and one change can be announced twice — keep
reconciling with `task show`.

## Codex unavailable

```
SUPERVISOR_CODEX_UNAVAILABLE=wait|fail      # default on a server: fail
SUPERVISOR_CODEX_UNAVAILABLE_AFTER_HOURS=3
```

`fail` ends the task as `failed` (reason `codex_unavailable`) once Codex has been away that long,
counted from the first time it was found away and kept in a file, so a restart does not start the
clock again. The work stays on its branch. `wait` waits as long as it takes. There is no setting that
finishes without the reviewer.

## Questions for a person

When Codex judges that a question needs a person, a server does not hold the turn. The question is
recorded with an id and its options, the worker is told to end with `needs_input`, and the task's
`question` carries `{id, text, options}`. Send the answer as a follow-up with `--answers <id>`.

## Health

```bash
night-shift doctor --server --json [project-dir] [--network]
```

```json
{"ok": false, "schema": 1, "checks": [{"name": "auth.claude", "status": "ok", "detail": {…}}, …]}
```

Stable English names, `status` one of `ok`, `warn`, `fail`, exit 1 on any `fail`. It starts nothing
and writes nothing. Checks: programs, profile, Codex policy, Claude and Codex sign-in, the last
usage readings (stale ones are reported as unknown, never as 0%), installed hooks, hook protocol,
`degraded.md`, runs waiting on a question or a pause, free disk, the browser, and — with a project
directory — git, a clean tree, trust, MCP decisions and whether the folder is a project at all, for
the project and every extra repository. `--network` adds reachability of Anthropic and OpenAI. `--probe` sends one
shortest real request to each model (`probe.claude`, `probe.codex`): a token that is present but
revoked or expired passes `auth status` and fails here. It costs a few tokens — run it before taking
work, not on every poll.

## Telemetry

Claude Code's own OpenTelemetry export carries `task_id` as a resource attribute
(`OTEL_RESOURCE_ATTRIBUTES`) for a task's workers; point its exporter at your collector. The engine's
older per-run journals (`run-events.jsonl`, `decisions.jsonl`, …) live in the instance directory and
go with it; the task's `events.jsonl` is the durable stream.
