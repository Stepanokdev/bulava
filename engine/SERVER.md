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
| Codex's final code review by a team of three specialists | off (`SUPERVISOR_REVIEW_TEAM="contract security state"` turns it on) | **on** (`=off` turns it off) |

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

**Did Codex take part.** `codex` on the task and on every attempt (and in `last_receipt.codex`) says
whether Codex did every step he was meant to do in that attempt:

```json
{"status": "partial",
 "gaps": [{"stage": "preflight", "reason": "codex зупинився з помилкою (код 1) …", "by": "claude", "count": 1}]}
```

`status` is `full` (nothing missed), `partial` (a step before the review went ahead with Claude
alone — `preflight`, `align`, `consultation`, `part`, `question`) or `review_by_claude` (the final
review itself was Claude's, which on a server never happens without a signed answer from the app)
or `unreviewed` (nobody reviewed it: a `succeeded_no_change` with an empty diff is settled by the
gate as `debt`, and `review.json` names `gate`, not `codex`, as the reviewer). On a server a
`succeeded_research` is reviewed by Codex: the report the worker names in `artifacts/`, or else its
declared summary and last message — what the ticket gets — judged also on what data it changed, how,
and how that was checked (`SUPERVISOR_SERVER_RESEARCH_REVIEW=0` turns this off). It gets
`SUPERVISOR_REPORT_REVIEW_ROUNDS` rounds (5) unless the task says otherwise (see "Review budget of a
task" below); at the limit the task ends `failed` / `needs-user`, or `done` with the reviewer's notes
when the task was sent with `--report-at-limit accept`. A
`waiting_review` or `done` task with `status` other than `full` is still a pass — Codex reviewed the
result — but put the gaps on the ticket next to it, so nobody reads it as an ordinary run.

A review call the Codex CLI refuses outright (exit 2 from its argument parser: an argument that is
not UTF-8, a flag this version no longer knows) is not treated as Codex being away. Waiting cannot fix
it, so there is no pause and no retry loop: the attempt ends `failed` once, with the CLI's own words
in `last_receipt.review_why`.

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

### Review budget of a task

Four optional flags of `dispatch.sh` set how much review this one task gets. They are kept with the
task, so its later attempts (`worker-send --relation continue`) and follow-ups are reviewed by the
same budget; a task sent without them gets the engine's defaults, never a previous task's.

| flag | what it sets | default |
|---|---|---|
| `--max-rounds N` | the most code-review rounds this task gets; not bounded by `SUPERVISOR_MAX_ROUNDS_HARD`, and it wins over a pipeline's own loop. A scoped task (runspec mode `patch`/`remediation`/`audit`) gets N−1 fixes, inside the same scope fence. Without it a scoped task gets its pipeline's number of rounds less one, none at all with no ceiling, else `SUPERVISOR_MAX_REMEDIATIONS` | that ceiling (20); scoped: 4 fixes (5 reviews) |
| `--report-max-rounds N` | the most rounds a `succeeded_research` report gets; its own budget, not cut by the code-review ceiling or by `--max-rounds` | `SUPERVISOR_REPORT_REVIEW_ROUNDS` (5) |
| `--report-criteria FILE` | what the report is judged by; **replaces** the server's rule about data changes rather than adding to it. Copied when the task is accepted: editing the file later changes nothing for it | the server's rule |
| `--report-at-limit accept\|ask` | `accept`: a report still failing at its last round is accepted with the reviewer's notes: the task ends `done`, `review.json` keeps `verdict: FAIL` and the findings, with `disposition: passed` and `accepted_with_notes: true`; the receipt (`last_receipt`) says `review: passed`, `accepted_with_notes: true` and the notes in `review_why`, for the ticket. Only a readable verdict (`STATE: COMPLETE`, `VERDICT: FAIL`) is let through; an answer without one ends `needs-user`, recorded as `UNREADABLE`. `ask`: the task ends `failed` / `needs-user` | `ask` |

A report is read in full once. Its first FAIL becomes the report's own ledger (`report-ledger-<task key>`,
the run's id for a run with no task,
apart from a code review's), with the same stable ids as code review: each later round answers
those ids against the report as it now is (FIXED / OPEN / SAME AS), and a new defect blocks only when
tagged `[acceptance_failure]` or `[regression_from_patch]`. A PASS with an id still open is a FAIL.
An item tagged `REACH: rare` does not hold the report back. `SUPERVISOR_STALL_LIMIT` rounds in which
the open count did not fall end the review as its limit would: `needs-user`
with `open_items` in `review.json`, or accepted with notes under `--report-at-limit accept`. Read from
scratch every round, one report came back 10, 10, 10, 8 findings and reached its limit every attempt.

`0` for either count means no limit. A run that stops making progress is still parked after
`SUPERVISOR_STALL_LIMIT` rounds without progress (code review, scoped fixes included), and every run still ends after
`SUPERVISOR_MAX_RUN_SECONDS` of review rounds (8 h), so `0` is safe to try. Any `--report-*` flag
also asks for the report to be reviewed. A criteria file that cannot be read, or a count that is not
a whole number, is refused with exit 2 before anything starts.

```bash
dispatch.sh --task-id QA-42 --message-id yt-QA-42 --source youtrack --author alice \
            --report-max-rounds 3 --report-criteria /srv/runner/criteria/test-run.md \
            --report-at-limit accept \
            /work/acme/api "Run the regression suite on the test stand and report"
```

An engine that predates these flags reads the first of them as the folder and refuses the task
(exit 1, «Нема такої теки»): update the engine before the runner sends them.

### No main repository: the workspace layout

A task has no main repository. Start the engine in a workspace folder that is a small git repository
of its own — a `.gitignore` ignoring every clone, an `AGENTS.md` describing the folder — with every
repository of the group cloned inside it and listed, all writable, in `SUPERVISOR_EXTRA_DIRS_FILE`.
The worker decides which ones a task needs. The engine accepts that start (its clones are ignored,
so it is not "a folder of projects"), shows each changed clone to the reviewer once, verifies it
inside itself, notices an uncommitted clone the home repository ignores, and lists every repository
in `receipt.repos` — the untouched home repository with `base_sha == reviewed_sha`. To keep the
worker out of the home repository, give a runspec whose `write_paths` name only the clones
(`["api/**", "web/**"]`). Pinned by `tests/test-server-workspace.sh`.

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

The connected repositories are measured the same way. Each keeps, in `task.json`, the base it had
when it first appeared in the task (`repo_bases`) and the commit the last passing review saw in it
(`repo_reviewed`). An attempt has work to review in a repository while its HEAD is not that reviewed
commit (or the base, before any review passed), so what an attempt committed before a question or a
blocker is reviewed by the attempt after it, and a review comment that needs no code costs no Codex
round. `receipt.repos[].base_sha` is the task's base. Either commit counts only while it is an
ancestor of HEAD: after a rebase the repository is measured from where the attempt found it. A
`blocked` or `needs_input` attempt is not reviewed; publish only what a `waiting_review` receipt
names. Pinned by `tests/test-server-task-repos.sh`.

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
An extra repository that one of the worker's registered checks is about (registered while standing in
it, or naming its path in the command) is verified by that check alone, so a raw `pytest` without the
repository's venv or services cannot fail work the worker proved another way.
`SUPERVISOR_EXTRA_REPO_AUTOVERIFY=0` turns the detection in extra repositories off entirely.

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

## Server settings

```
SUPERVISOR_SERVER_RESEARCH_REVIEW=1            # Codex reviews a research result (and the data it changed); 0: settled unreviewed
SUPERVISOR_MAX_ROUNDS=5                        # code-review rounds always allowed before a stall can park a run
SUPERVISOR_MAX_ROUNDS_HARD=20                  # code-review ceiling per task; 0: none (the stall limit still stops a loop)
SUPERVISOR_REPORT_REVIEW_ROUNDS=5              # rounds a research report gets when its task names none; 0: no limit
SUPERVISOR_SERVER_UNDECLARED_MAX=4             # stops with nothing declared (or a DRAFT) sent back before a review is spent
SUPERVISOR_BG_WAIT_SECONDS=5400                # how long the Stop hook waits, per run, for the worker's background subagents
SUPERVISOR_BULAVA_REPORT=1                     # workers get the bulava-report MCP tool (bin/bulava-report-mcp.py); 0: not
```

## Codex's review by a team of specialists

The final code review is three Codex reviews of the same change instead of one, each with a focus of
its own — requirements and business logic, security and data integrity, state transitions and
integrations — side by side, so the round takes as long as the slowest of them and costs three calls.
On the bench of planted defects (8–9 Nov, 23 snapshots of the factory's own MRs) one ordinary review
found 61.8% of them on Astra medium and three specialists 72.5%; on Sol high 67.1% and 72.4%. The
focus lines are the ones measured, word for word (`bin/lib/review-team.sh`).

Their findings are joined, not voted on: any member that fails the work sends it back, each list
under its reviewer's name — also when another member is blocked or hands off. Without a FAIL, a
blocked member parks the run, then one that hands off; only every member passing is a pass. A
member that does not answer, or answers COMPLETE with no verdict, is named and the others decide;
none with a usable answer is a reviewer that did not answer, as before. A member the CLI refused parks the run like a
single refusal. The Claude stand-in, when the director allows one, reads alone.

```
SUPERVISOR_REVIEW_TEAM="contract security state"   # default on a server; empty everywhere else
                                                    # members: contract security state general
                                                    #          negative legacy outcome (the last three
                                                    #          are proposals from the bench, not measured)
                                                    # off, empty or one member: the single review
```

A pipeline whose review step chose a team ("Who reviews", e.g. the built-in `review-team`, "Claude + a
Codex team") is reviewed by that team; one that chose "one reviewer" is reviewed by one, here too. A
review step that did not choose leaves it to this setting.

The team reads the change once. When its round goes back to the worker (a FAIL, or a pass the
verifier overturned), what it found becomes a ledger: each blocking defect with a stable id (T1, T2,
...). The rounds after it are one Codex review that answers every open id, FIXED or OPEN, checks
what the fixes broke (`git diff` since the last review), and lists new defects as N1, N2, ... A new
defect blocks only if a person meets it on the ordinary path or it loses data, and that holds for
what a fix introduced too; anything else is `[related_improvement]`. Read on every round, the team
kept finding the next rare case, the earlier items mostly closed, and a run never stalled.

- **REACH.** Every blocking item ends with `REACH: ordinary`, `REACH: data-loss` or `REACH: rare`.
  The gate re-tags a rare one `[related_improvement]` whatever its class: it does not block, does not
  join the ledger, and the worker is not sent to fix it. An item with no REACH blocks as before.
- **The task's own decisions.** A reviewer that disagrees with something the task states explicitly
  ("every role can still open the form", "no migration") tags it `[spec_conflict]` with
  the task's words quoted. The worker gets no FAIL for it: the run is parked, the task goes to
  `needs_input` with `state_reason: spec_conflict` and a question (`question.text` quotes the
  reviewer's line, two options: keep the task as written, or change it). The answer comes back as a
  continuation and the ledger is still there.
- **One ledger per task.** A task a bridge named keeps its ledger across attempts
  (`review-ledger-<task key>`), so a continuation after a stop or a timeout is a fix check of the same
  ids, not the team reading from scratch; its brief lists them under «Що лишилось відкритим з рев'ю».
  A ledger an earlier attempt left under its run id is taken over on the first review. A pass, or
  debt with nothing open, clears it.
- **Attempts on the record.** One attempt is open at a time. `night-shift stop` closes the open one
  with `result: stopped`; an attempt still open when the next begins (a second continuation before
  the first got its verdict) is closed with `result: superseded`. A verdict settles an attempt only
  if it is still that run's (dispatch id, run id) and was not stopped, checked under the task's lock
  in the same step as the write; any other is recorded as a `stale-verdict` event and changes nothing.
  The gate takes the attempt's ids when it starts; if the folder has gone to another attempt by the
  time it would write (a continuation during a long final check), it writes nothing at all — no
  verdict, no done mark, no cleared review list. The gate works on a private copy of the review list: the shared file, which a
  continuation's brief reads, changes only when the gate ends and only if the attempt is still its
  own, so ids an answer closed during a long final check are still open for a continuation. A folder
  with no git, reviewed through its copy, is fingerprinted before the review and again before
  acceptance: an edit in between is not accepted and the copy's base does not move onto it.
- **Final checks.** A check registered with `add-check --final` runs once per gate run, before
  anything is accepted: a PASS, a FAIL whose every item is advisory, a report, a plain folder's
  declared outcome, a round limit or a tool failure banked as debt — the first of these in a gate run
  runs them, and any later one in the same run takes that result. Each check has its own log. The work is accepted only when every
  final check exited 0 and left its log. A check that failed or ran out of time sends the work back
  as a blocking defect; one that could not start or left nothing to read parks the run for a person.
  It is never debt: any way to `passed` or `debt` — a round limit, a tool failure — with a final check
  registered and not passed in that gate run is settled as needs-user. While they run, `gate.verify running` is repeated every minute, so a runner that
  measures silence sees a check at work. Acceptance compares the commits and the working trees with
  what the reviewer read, every repository both ways: one gone, one new, or a state that cannot be
  read is not accepted.
- **Research reports.** The same rules apply to a report's review: a report whose only items are
  advisory (or `REACH: rare`) is accepted, and a `[spec_conflict]` parks it with the question.

- An id the answer does not mention stays open. A PASS with ids still open is asked again once, and
  then counts as a FAIL with those ids sent back.
- Progress is the open count going down. A round that closes one id and gains a new blocker is
  not progress, and two such rounds in a row park the run saying that every fix opens a new blocker
  (on a server one task went 6 → 4 → 2 → 2 open items, "progress" every round, for eight hours). Two
  members may describe one defect twice; the first fix check is asked
  to name such pairs (`T2: SAME AS T1`, or `DUPLICATES: NONE`), and until an answer has done that a
  closed id is not counted as progress. After that two ids for one defect close together or not at
  all, so duplicates cannot look like progress. No extra call: the team's round is 3 calls, every
  round after it 1. No fall in the open count for `SUPERVISOR_STALL_LIMIT` rounds
  parks the run for a person, without waiting for the base patience (`SUPERVISOR_MAX_ROUNDS`), and
  with the open ids in `review.json`. At the round ceiling with ids still open it is `needs-user`,
  not debt.
- Outside a fix check, progress is counted on blocking findings only: advisory ones
  (`[related_improvement]`, `[pre_existing]`) and the tooling's (`[harness_failure]`) do not count.
- A new request, `task-boundary new`, the next piece of a long project, or a piece judged by changed
  rules clears the ledger and the review budget; the whole team reads again.

The verdict belongs to the commits the reviewer read: they are taken before the call, a commit that
lands during it voids the answer (twice in a row asks a person), so does a repository that joined
the run during it — nothing is written, passed or accepted before it is read — and the receipt's `reviewed_sha` is
the commit read, not `HEAD` at the time the receipt is written.

`doctor --server --json` reports it as `engine.review_team`, with the calls the first round costs
(`calls_per_round`) and the rounds after it (`calls_later_rounds`, 1). The team round's members and
who answered are in the run's `review-team.json`; the supervisor log says "fix check after the
team's review" for each round after it and "fix check: closed … · new … · open …".

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
