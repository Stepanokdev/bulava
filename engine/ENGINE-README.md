# Night Shift Supervisor

Codex (on a ChatGPT subscription) supervises Claude Code (on a Claude subscription) as a strict
reviewer, on behalf of whoever owns the work. No API tokens: both sides run on subscriptions you
already pay for.

## What it does

- **Answers Claude's questions at night.** When Claude asks "I've done 30%, is that enough?", a
  PreToolUse hook intercepts the question and hands it to Codex under a reviewer contract
  (`supervisor/SUPERVISOR.md` — the same for every user and every product; it remembers nobody's
  past decisions and is not supposed to). The answer goes back to Claude as the final word.
- **Does not let it stop with the work unfinished.** A Stop hook runs a Codex review against
  SPEC.md / the requirements. `VERDICT: FAIL` → Claude gets the list of defects and carries on.
  Three rounds per session by default; what is left over goes to `REVIEW-DEBT.md`.
- **Understands the phase (it does not block pauses).** If Claude is handing the turn back to
  you — asking a question, waiting for a login or a decision, in a validation or planning phase —
  the gate recognises that and **lets the stop through without a FAIL** (the cheap pre-check does
  not even call Codex).
- **Reviews the current task only.** Codex compares the result against the RunSpec or the most
  recent human messages. An old backlog and the general state of the product cannot turn a local
  fix into a new autonomous list of work.
- **A full audit happens only when asked.** You can ask for it in words or run `/deep-audit`;
  finishing an ordinary task never escalates into one by itself.
- **Git insurance.** `night-shift.sh start` commits the current state and moves the work onto a
  `night/<date>` branch. In the morning: read it, then merge the branch or throw it away.
- **Watches the limits of BOTH subscriptions, separately.** Claude: the statusline writes
  `rate_limits` into `~/.claude/supervisor/usage.json`. Codex: `bin/codex-usage.sh` asks the CLI
  itself (`account/rateLimits/read`), with the session files as a fallback source. A window at
  ≥90% means a pause — but a **named** one: `paused-for-limit.json` records whose quota it is,
  which run, and which piece of work. A spent Codex stops reviews and consultations, not Claude:
  the work goes on, and the brief says so — but it **cannot finish without Codex**. The run is
  parked, and only two things lift the pause: the window coming back, or the director's answer
  (see the next point).
  If Claude asked a question and only Codex is out of quota, the question is held just long enough
  for the window to turn over (`SUPERVISOR_CONSULT_WAIT_MAX`, 3 minutes by default), and then the
  real Codex answers it. No longer than that: the question is asked inside Claude's turn, so
  waiting for a window froze the worker for half a day. After that the card goes to the director,
  but also for a limited time (`SUPERVISOR_ASK_USER_WAIT_DEGRADED`, 3 minutes instead of an hour)
  — because the question reached him through the absence of a Codex decision rather than through
  one, and that does not turn a reversible choice into something only a human may make. With no
  answer, control returns to Claude: it takes the reversible decision itself, and anything that
  looks irreversible is not done at all — the run ends as `blocked`, naming the one action that
  would unblock it. The status bar shows both: `5h: 42% | Cx: 5%`.
- **Nothing finishes without Codex — and a threshold decides who waits.** A spent window no
  longer writes the work off into `REVIEW-DEBT.md`: the gate parks the run and leaves the review
  as debt (`review-pending`). Less than a day to the reset — we wait in silence and the watchdog
  resumes the work itself. A day or more, an unknown reset, or a pause already over a day in total
  — and a `codex-decision.json` card comes up with two buttons: keep waiting, or carry on with
  Claude in place of Codex. **That card has no timeout**: an unanswered one leaves the run paused
  for as long as it takes — unlike `ask-user.json`, which is deliberately a different file
  precisely because that one answers itself after an hour. The permission must name the `id` of
  the open request, is consumed once, and belongs to one specific run and dispatch.
  **The question is withdrawn together with the wall:** the moment the window returns, the
  reviewer becomes reachable, or the preparation hold ends (there is no pause there, so
  `pause_reconcile` never sees it), the card disappears — otherwise it would sit on screen
  offering to wait for a Codex that is already reading the diff.
  After "carry on with Claude", every Codex call is replaced by a separate fresh Claude session
  with the same task and no conversation history; read-only is enforced by the tool set
  (`--tools 'Read,Grep,Glob' --strict-mcp-config`, no Bash and no MCP) **and** by comparing the
  tree before and after — a review that changed a single byte is thrown away.
  `SUPERVISOR_CODEX_ASK_AFTER` (86400 by default) is that same threshold;
  `SUPERVISOR_MAX_UNREACHABLE` (5 by default) is how many times in a row the reviewer may be
  unreachable before the run goes to a person as `needs-user`.
- **Preparation does not start "without a hand".** Both the chat pump and the dispatch from the
  application keep a task whole in the queue while Codex is spent and no permission has been
  given — and while the installed Stop hook is older than the library. They hold it there on
  purpose: a failed pipeline stage would have stopped nothing, it parks the original and hands it
  over unready. An ordinary chat message (`plain`) is not held — it asks Codex nothing. The reason
  is visible in the application: `codex` or `engine-mismatch`.
  **The hold has no time limit.** The first version gave up after eight hours and prepared the
  work anyway — an automatic workaround, which is exactly what this removes. A hold ends together
  with its cause, with the director's answer, or with the work itself being replaced. It is
  recorded in `dispatch-held.json`, so a restart does not lose it: the watchdog restarts a hold
  whose process died.
  **The night queue is held the same way.** At first it was made an exception — so that one spent
  window would not leave an empty morning — but an exception the director never chose is not his
  "by default". The hold comes first here, and the card gives the same single press; the hold is
  read on every poll, so freeing one project does not free the rest, while a returning window
  frees all of them with no presses at all.
- **The hook protocol has a version.** The engine is installed by copying, and the hooks are named
  by absolute path in `worker-settings.json` — two copies on one machine is a normal state.
  `GATE_PROTOCOL` inside `hooks/review-gate.sh` is compared against the library's
  `SUPERVISOR_PROTOCOL`; preflight writes the mismatch into `degraded.md`, and the pump stops
  preparation on it.
- **The permission to substitute is signed, and checked EVERY time.** The file by itself proves
  nothing: a worker can write files too. The director's answer carries an ECDSA signature over
  `<request-id>|<choice>|<run>|<dispatch>` — the work is inside the signature, so an answer given
  for another run or another task simply does not add up. The private key lives in the
  application's keychain (another binary that comes for it gets a system prompt), the public one
  in `~/.claude/supervisor/decision-key.pem`, verified through `openssl`. The point: the signature
  is checked every time the permission is USED, not once when it is accepted. Otherwise
  `codex-fallback.json` itself would stay an ordinary unsigned file, and whoever wrote it later —
  a background process that outlived the call — would be trusted forever.
- **Control state is not editable from Bash.** `write-gate.sh` also stands on `Bash`: these files
  can be read, not changed. That is a cheap first fence, not the boundary: a text filter is a
  guess, and `&>` or a name assembled at runtime gets around it. The boundary is the signature
  above, which does not care how or when the file appeared.
- **Turning the review off is signed too.** `review-off` used to be an empty marker, and an empty
  marker proves nothing: anything able to write a file would have ended the night without a
  review, and the journal would have recorded that as the director's decision. The marker now
  carries a signature over `review-off|<slug>`; an unverified one is deleted and ignored, and the
  run goes to the usual review.
- **`control-guard.sh` watches exactly one file — the verification key.** Everything else
  protects itself. The first version hashed the whole control-state directory, and that was a
  regression rather than a fence: `$IDIR/report-outcome` is a handle the worker is REQUIRED to
  call, it writes `outcome.json`, and a normal end of run was being declared an intrusion, taking
  the director's permission down with it. An answer from the application in the middle of a long
  command was punished the same way. The key, by contrast, is written only by the application —
  and not only at startup: it rewrites the key on every state update, so a substitution lives for
  seconds. Together with the permission being checked on every use and remembering the fingerprint
  of the key it was issued under, everything issued during that window dies the moment the real
  key returns. The fingerprint (`.control-fp`) going missing counts as intrusion too — otherwise
  deleting it would have been the way around.
  **The boundary here is not absolute, and that is worth knowing:** the worker runs as the same
  user, so there is no file on this disk it cannot reach. A trust anchor outside the user's write
  reach (a root-owned path through a privileged helper) is a separate product decision.
- **A question Codex never answered does not vanish.** A consultation is deliberately
  non-blocking (it sits inside Claude's turn), but the text of the question is written to
  `consult-unanswered.jsonl` and comes back with the resume once Codex is available. Whatever
  Codex never saw in this run is added to the review prompt itself — the reviewer has to know
  where the hole in the brief is.
- **It resumes after a limit by the clock, not by a timer.** The watchdog does not sleep until
  `resets_at`: on every poll it compares the marker against a fresh counter reading and against
  real time. The window reset early — the pause lifts immediately. The Mac slept through the reset
  — that shows up, because wall-clock time is compared rather than a `sleep` that ran. If the
  counter cannot be read at all, the marker holds until the recorded time, and after it ONE
  controlled attempt is allowed with a growing back-off (600 → 1200 → 2400 → 3600 s), so a run
  does not spin in an "attempt → wall" loop. And no resume goes in blind: if the marker belongs to
  another run or to work that has already finished, it is simply removed — an old watchdog cannot
  type "carry on" into somebody else's task.
- **A quality bar (anti-AI).** `supervisor/STANDARDS.md` is injected into the system prompt of
  every night session (`--append-system-prompt-file`): for UI, design skills are mandatory and a
  templated AI look is forbidden; for prose, `humanizer`. The review gate fails work that ignores
  it.
- **The engine remembers nothing between runs.** No accumulated layer of rules, taste or past
  decisions — neither its own nor the product's. Exactly two things go into the system prompt: the
  execution protocol (`supervisor/STANDARDS.md`) and the current task's context. Long-lived rules
  live where both models read them by themselves: `CLAUDE.md`, `AGENTS.md`, specifications and
  documentation in the repository. The engine does not create, maintain or synchronise those
  files.

  It was not always so. There used to be two stores — `supervisor/lessons/` in git and
  `~/.claude/supervisor/memory/` on the machine — plus self-teaching that assembled candidate
  rules out of transcripts. That is gone: a situational request became a permanent rule, rules
  aged and contradicted each other, and there was no way to see which of them had won in any
  given run. Whatever had accumulated stays on the disk untouched; nothing reads it. Deleting it
  or taking it away is the owner's decision, not the installer's.
- **The reviewer is a contract, not a profile of a person.** `supervisor/SUPERVISOR.md` describes
  how to take decisions and judge work, identically for everyone. It holds no history of past
  answers and absorbs nothing from runs.
- **Nothing but the task's contract is an acceptance criterion.** Work is accepted against the
  current contract and the absence of regressions. A practice that could have been applied is a
  `related_improvement`, not a FAIL.
- **Protection against "daytime capture".** The SessionStart hook `hooks/safety-check.sh` puts
  night mode out if it has been up for more than 10 hours — so that Codex does not answer for you
  during the day when you forgot to stop it.

During the day (without `night-mode`) every hook is a no-op: questions reach you as usual.

## Installing (once)

```bash
bash install.sh   # backs up and updates ~/.claude/settings.json; restart Claude Code
```

## Using it

Every project is a separate instance with its own tmux session `night-<slug>`, watchdog and git
branch. **Projects can run in parallel** (bear in mind they all drink from the same 5-hour Claude
window, so several at once spend it faster).

```bash
cd ~/path/to/project       # the folder is taken from the current directory
night-shift start          # creates everything and attaches you to the project's session
# give Claude the task  →  Ctrl-b d — detach (the work stays in the background)
#                       →  or exit / Ctrl-D in Claude — finish + auto-stop (review + learning)
night-shift status         # show ALL active projects + health
night-shift stop           # switch this project off by hand (+ a background morning review)
```

Auto-attach: `night-shift start` drops you into the right `tmux` session itself — there is no need
for a separate `tmux attach`. Closing the terminal means detaching (the work deliberately survives
for night mode; to end it completely, `exit` in Claude or `night-shift stop`).

Several projects in parallel:

```bash
night-shift start ~/proj-a
night-shift start ~/proj-b      # its own session, its own watchdog, its own branch
night-shift status              # both are visible
night-shift stop --all          # stop all of them
```

Commands: `start [dir]` · `stop [dir|--all]` · `status` · `attach [dir]` · `list`.
Attaching is always `night-shift attach "<project>"` (it finds the `night-<slug>` session itself;
do not rely on a fixed name `night`).

Terminal commands (symlinks in `~/.local/bin`, installed by `install.sh`):
`night-shift`, `deep-audit`, `night-queue`. Inside Claude: `/night`, `/deep-audit`, `/queue`.

**Migrating from the old single-session mode:** if an old `night` session is still around (from
before the update), it works as legacy. To move to the new model:
`night-shift stop --all` → `tmux kill-session -t night` → `night-shift start` in each project.

The best results come when the project has a `SPEC.md` (the review compares against it). In the
morning, look at: `DECISIONS.md` (decisions taken for you), `BACKLOG.md`, `BLOCKED.md`,
`REVIEW-DEBT.md` (what was not accepted after three rounds),
`~/.claude/supervisor/supervisor.log`.

## The project queue (the night pipeline)

You load several projects and go to sleep; they run **one at a time** (each gets the full 5-hour
Claude window — sequential beats parallel on one subscription). Each project runs as its own
per-project instance under the review gate; on a limit its watchdog pauses and resumes it; when
the review accepts the work, the queue takes the next one.

```bash
night-queue add ~/proj-a "Implement everything in SPEC.md, no stubs"
night-queue add ~/proj-b              # no task → the standard "do everything in SPEC.md"
night-queue add ~/proj-c "Build the landing page with the design skills, prose through humanizer"
night-queue list                      # the queue + what is running + history
night-queue run                       # starts the background runner — then go to sleep
# in the morning:
night-queue status                    # what is done / what is left
night-queue stop                      # stop after the current project
```

Commands: `add <dir> [task]` · `list` · `remove <n>` · `clear` · `run` · `stop` · `status`
(or `/queue` in Claude Code). Finished projects are archived in
`~/.claude/supervisor/queue/done/` with their result (`passed` / `debt` / `timeout`). Each project
leaves its own night branch, its `AUDIT-*.md` and its lessons, exactly like an ordinary night
shift.

**Migrate first** from the old single-session mode if it is still active:
`night-shift stop --all && tmux kill-session -t night`.

## Deep audit (a fresh pair of eyes)

Separate from the night shift: a one-off independent audit of the whole project (the UNDP
pattern). Codex starts with a clean context, first reads the requirements, then **goes out to the
internet** (the client, the tender, comparable work, the evaluators' own software), and only then
looks at the code. No code changes at all — analysis only: what is missing, what is superfluous,
how it looks to an evaluator, whether this is a service rather than a demo.

```bash
bin/deep-audit.sh ~/project "evaluators — UNDP, a tender for crisis mapping"
# or from Claude Code:  /deep-audit evaluators — UNDP, a tender for crisis mapping
```

The audit produces a separate report. Its conclusions do not become fix-it tasks without a human
decision. The prompt template is `supervisor/AUDIT-PROMPT.md`, meant to be edited to taste.

## Components

| File | Role |
|---|---|
| `supervisor/SUPERVISOR.md` | The reviewer's contract: decision rules, the same for everyone |
| `~/.claude/supervisor/qa-history.jsonl` | Raw question → answer pairs from transcripts (state, not the repo) |
| `bin/extract-qa-history.py` | Regenerate qa-history from newer transcripts |
| `bin/statusline.sh` | The statusline (Claude + Codex %) and the limits dump into usage.json |
| `bin/codex-usage.sh` | Codex limits from its session files → codex-usage.json |
| `hooks/answer-question.sh` | PreToolUse(AskUserQuestion) → Codex answers |
| `hooks/review-gate.sh` | Stop → a Codex review; blocks unfinished work |
| `bin/supervisor-lib.sh` | Shared helpers: slug, instances, scope (per project) |
| `bin/watchdog.sh` | Per-instance automatic "carry on" after a limit resets |
| `bin/night-shift.sh` | start/stop/status/attach/list (per-project instances) |
| `bin/queue.sh` | The project queue: add/list/remove/clear/run/stop/status |
| `bin/queue-runner.sh` | The background runner: pre-flight → inject → review → next |
| `supervisor/config.sh` | The single source of defaults (every tuning knob) |
| `bin/verify.sh` | **The Verifier** — deterministically runs build/tests/lint and collects evidence outside the repo |
| `bin/preflight.sh` | Classification → research → independent Claude/Codex positions → reconciliation. Called whole or stage by stage (`--stage context\|peer\|align`) |
| `bin/pipeline.sh` | The pipeline executor: walks one message through ordered stages, a parallel group, per-message artefacts, cancellation |
| `supervisor/pipelines/*.json` | Pipelines described as **data**: `adaptive-peer` (chat), `dispatch`/`dispatch-legacy` (a night task), `plain` |
| `bin/message-pump.sh` | One pump per project: takes prepared messages from the queue in turn and waits for a free worker |
| `bin/pipeline-compose.sh`, `bin/pipeline-deliver.sh` | The "assemble the prompt" and "hand it to the worker" stages |
| `bin/worker-withdraw.sh` | Take a message back — from the preparation queue, from under an active preparation, or from the retry queue |
| `bin/consult-codex.sh` | The adaptive-peer channel: precise read-only Codex consultations during implementation, with no call counter |
| `supervisor/prompts/*.md`, `supervisor/schemas/*.json` | Prompts and JSON schemas for pre-flight |
| `bin/skill-resolver.sh`, `bin/skill-audit.sh` | fetch → quarantine → audit → autonomous project-local install |
| `supervisor/SKILL-AUDIT-PROMPT.md` | The prompt for the Stage-B agentic audit of a skill |
| `bin/deep-audit.sh` | The explicitly requested one-off deep audit with web reconnaissance |
| `supervisor/STANDARDS.md` | The run protocol and the quality bar (anti-AI design, humanizer, engineering; the rule against fetching skills yourself) |
| `bin/publish-engine.sh` | Assemble the engine for somebody else's machine and check that nothing personal is in it |
| `hooks/safety-check.sh` | SessionStart: puts out a stale night mode + the handshake |
| `supervisor/AUDIT-PROMPT.md` | The auditor's prompt template (the UNDP pattern) |
| `claude-commands/deep-audit.md` | The /deep-audit slash command (copied by install.sh) |
| `tests/test-*.sh` | Isolated integration tests (pure bash; codex/claude mocked through PATH; a real tmux where it matters) |
| `docs/F13-transport-research.md` | Transport research (without a rewrite) |

Newer working cycles on top of the basic night: **adaptive-peer pre-flight** (`preflight.sh`,
before a task of any size), the **Verifier** (`verify.sh`, inside `review-gate` before the
verdict) and **skill-resolver** (`skill-resolver.sh`, an autonomous project-local install of
audited skills). Every default is in `supervisor/config.sh`.

### Pipelines: how a message reaches the worker

Between "the director wrote something" and "the worker reads it" stands a pipeline — an **ordered
list of stages, described as data** in `supervisor/pipelines/<name>.json`. Stages with the same
`group` start together and are awaited together; `optional` means a stage failing degrades the
result rather than stopping the pipeline.

```
plain           compose → deliver
adaptive-peer   context → (peer-claude ∥ peer-codex) → align → compose → deliver
                a FOLLOW-UP to the open task: context → compose → deliver
dispatch        the same, but the dispatch record belongs to the night dispatcher
```

A stage marked `skip_when_followup` in the definition is left out when the context stage has
recognised the message as the next step of an open task. Every director message used to buy both
positions and the comparison — sixty times in one week, for lines like "carry on" — while the
worker already held the context and had `consult-codex` for the moment it wanted a second opinion.
`SUPERVISOR_FOLLOWUP_PEERS=1` restores the old behaviour.

One executor (`bin/pipeline.sh`) serves both the night dispatch and Bulava's direct chat, so there
are not two different truths about what the worker receives. Each message's artefacts sit apart
(`<instance>/messages/<seq>-<id>/`), and the assembled prompt points at those — which is why
preparing one message cannot substitute another one's positions.

A chat message in Claude+Codex mode is never typed at the worker directly: it becomes an envelope
in `<instance>/pending/`, the pump (`bin/message-pump.sh`) waits until the worker is genuinely
free, and only then starts the pipeline. `worker-send.sh` answers `TIER=preparing` (code 5), and
Bulava shows "Claude and Codex are reading first" rather than "working", because nothing has been
handed to the worker yet.

A future pipeline editor edits exactly these JSON descriptions: execution, status, cancellation,
logs and the artefact contract already exist.

### The adaptive-peer flow

Before implementation, Claude and Codex independently read one task and one repository and write
short engineering positions. Both get a BYTE-FOR-BYTE identical prompt (it is kept in
`peer-prompt.txt` and read by each stage), they work in parallel, and neither sees the other's
file: the positions are published only after both processes have finished.

Reconciliation runs only when there are TWO positions. One position is not a reconciliation, and
instead of an invented comparison the journal gets an explicit line about the degradation. A
position counts only on a zero exit code and non-empty output: a fragment cut off by a timeout is
not an opinion. Codex reconciles material disagreements and acceptance checks only; it is not a
grand plan and not an order to the implementer. Claude takes the final decisions quickly and
implements the task.

The positions are formed for the FIRST message of a task. A follow-up in the same thread goes to
the worker with its context only; whether Codex is worth asking about it is the worker's call,
made through the consultation channel below.

While working, Claude has a `consult-codex` command. It is for when new facts have opened a hard
architectural fork, a lifecycle/concurrency/reachability risk or ambiguous behaviour. There is no
numeric ceiling: every consultation stores its question, answer, time and tokens separately, and
the real limit is the available Codex quota. Mechanical work should not create consultations for
ritual's sake. After implementation, the independent review gate works as before.

## Settings (environment variables)

Every default lives in **one file** — `supervisor/config.sh` (the single source of truth;
`tests/test-config.sh` checks the code against this documentation). The main ones:

- `SUPERVISOR_MAX_ROUNDS` — base patience: this many FAIL rounds are always allowed (default 3)
- `SUPERVISOR_MAX_ROUNDS_HARD` — the absolute ceiling of rounds per session, protection against a
  loop (default 12)
- `SUPERVISOR_STALL_LIMIT` — how many rounds in a row without progress (the list of findings stops
  shrinking) before we park it as "genuinely stuck, a person is needed" (default 2). While there
  is progress the gate drives the work on up to the HARD ceiling rather than stopping at a fixed
  number.
- `SUPERVISOR_PEER_IDLE_TIMEOUT` — how many seconds a position may be **silent** before it is
  stopped (default 600). This is not a ceiling on thinking: both CLIs emit events as they work
  (`claude --output-format stream-json --verbose --include-partial-messages`, `codex exec --json`),
  so a model on maximum effort works as long as it needs and only real silence is cut off.
  There used to be a fixed `SUPERVISOR_PLAN_TIMEOUT=360` here, which cut live work in half: a
  position 361 seconds short came back as zero bytes, because `claude -p` prints its answer at the
  end.

  Why ten minutes: the budget has to cover the longest pause **between events**, not the work.
  Claude emits token deltas, so its pauses are seconds long; Codex emits four events for a whole
  turn — `thread.started`, `turn.started`, the answer, `turn.completed` — so its entire thinking
  phase is one pause. Both were measured, not guessed.
- `SUPERVISOR_PEER_POLL` — how often that silence is measured (default 5 s)
- `SUPERVISOR_USAGE_GUARD` — the % of the **5-hour** window after which we pause (default 100)
- `SUPERVISOR_USAGE_WEEK_GUARD` — the % of the **weekly** window after which we pause (default 100)

  Both default to 100: quota is bought to be used, and work is stopped by the provider refusing,
  not by a reserve this code decided to keep. They used to be 90 and 97 — the weekly threshold
  switched Codex off for five days at 91% of the week while three quarters of the session window
  was free. They are still knobs: a machine that needs a reserve only has to set its own number.
- `SUPERVISOR_VERIFY_GUARD` — the % of the window above which the build/test verifier does not
  start (default 100 — that is, it always starts; turning verification off to save quota means
  trading a verified night for savings nobody asked for)
- `SUPERVISOR_MAX_CODEX_WAIT` — the maximum seconds to hold a question until Codex resets
  (default 19800)
- `SUPERVISOR_COLLABORATION_MODE` — `adaptive_peer` (default) or the previous `legacy`
- `SUPERVISOR_CONSULT_TIMEOUT` — the maximum for one Codex consultation, in seconds (default 900);
  the number of consultations is deliberately not limited
- `SUPERVISOR_PREFLIGHT_TOTAL_TIMEOUT` — the ceiling on ALL preparation of one message, in seconds
  (default 2400): classification, design, research, two positions and the reconciliation together
- `SUPERVISOR_PUMP_IDLE_WAIT` — how long the pump waits for the worker to become free
  (default 28800)
- `SUPERVISOR_KEEP_MESSAGE_ARTIFACTS` — how many `messages/<id>` directories to keep per instance
  (default 12)
- `SUPERVISOR_IDLE_KILL_HOURS` — the watchdog kills a LIVE session whose screen has not changed for
  this many hours (default 4)
- `SUPERVISOR_STALE_DISABLE_HOURS` — SessionStart puts out LEFTOVER night state older than this
  many hours (default 10)
- `SUPERVISOR_STATE_DIR` — the state directory (for isolated tests; default
  `~/.claude/supervisor`)
- `SUPERVISOR_BRANCH_MODE` — the branch on `start`: `auto` (default — reuse the current one, and
  cut a separate `night/<time>` only if you are on a protected branch) · `current` (always the
  current one) · `new` (always a new one)
- `SUPERVISOR_PROTECTED_BRANCHES` — branches that may not be worked on directly → we cut a night
  branch (default `main master`)

Those last two are TWO different ideas (killing a hung live session vs putting out state forgotten
until the next day), which is why they have different names. The deprecated
`SUPERVISOR_STALE_HOURS`, if set explicitly, overrides both (for compatibility). The remaining
knobs (verifier, pre-flight, skill-resolver, queue) are in `supervisor/config.sh` with comments.

The tmux session names are derived from the project (`night-<slug>`) automatically — there is no
separate variable for the session name.

## Updating the persona

Once a month it is worth re-running the distillation over fresh sessions:
`python3 bin/extract-qa-history.py`, then asking Claude to update SUPERVISOR.md from the new pairs.
