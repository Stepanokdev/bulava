<p align="center">
  <img src="site/assets/mark.svg" width="64" height="64" alt="">
</p>

<h1 align="center">Bulava</h1>

<p align="center">
  <b>Stop babysitting AI.</b><br>
  Claude Code writes, Codex reviews, and neither of them asks you to press continue.
</p>

<p align="center">
  <a href="https://bulava.app"><b>Download for macOS</b></a> ·
  <a href="#run-it-from-the-terminal-instead">Install the CLI</a> ·
  <a href="#build-it-yourself">Build it</a>
</p>

---

Bulava runs Claude Code and the Codex CLI on your Mac, on the subscriptions you already pay for.
You describe the work; Claude does it, Codex reviews it independently and sends it back until it is
actually done. There is no account to create, no API key to paste, and no server of ours in the
path: everything happens on your machine, in your folders.

It started as a shell script whose whole purpose was to stop a model announcing "I have done 30% of
the work — shall we leave it here?" and then asking a human to say no. Ninety-odd days later it is
the application that writes itself.

## What is in this repository

| | |
|---|---|
| `Night Shift/` | the macOS app — SwiftUI, `NavigationSplitView`, a native `.inspector` |
| `engine/` | the work engine: sessions, the review gate, the verifier, the queue, the watchdog |
| `site/` | the source of [bulava.app](https://bulava.app) and the CLI installer it serves |
| `Night ShiftTests/`, `Night ShiftUITests/` | what proves it |

The app does not fork the engine's brain. It reads the engine's state from `~/.claude/supervisor`
and drives the same `night-shift` / `night-queue` commands you can run by hand. One source of
truth, whichever way you come at it.

## How the work goes

**You write it the way you would say it.** No ticket form and no estimate. Both engines read the
message and form a position on it separately; what they disagree about is written down before a
line of code is touched.

**It runs whether or not you are there.** A run lives in its own session and survives quitting the
app, closing the lid, a dropped network and a usage limit — it waits for the reset and carries on.
What reaches you is only what the agents genuinely cannot move without, and it arrives as a
question with buttons.

**And it has to prove it finished.** Codex reviews the result against the run it came from: the
real diff, the tests that actually ran, the build that compiled, screenshots of the thing on
screen. A finding sends the work back. Nothing arrives as done on the strength of an agent saying
so.

## What it refuses to do

Each of these was built first, and each is now checked by something that runs.

- **No invented progress.** No percentage, no progress bar. A model usually knows what it has done
  and almost never knows what the next step will open; an invented 60% would be the most dishonest
  pixel in the app. A stage is marked when something on disk says so.
- **No memory of you.** Bulava kept a long-term memory of the director's decisions and it was the
  most expensive thing ever removed from it. A situational request becomes a permanent law far too
  easily, and the rules go stale and duplicate what the models already read from your `CLAUDE.md`.
  Search over past sessions stayed; the system's opinion of you did not.
- **No silent reach.** Connecting a folder is not consent to change it. A resource is read-only
  unless you mark it writable, and that is enforced when work is dispatched, not merely displayed.
- **No servers of ours.** The only thing the app fetches from us is the update feed.

## What you need

- **macOS 15.6 or newer**, Apple Silicon or Intel. Building it needs Xcode 26.
- **Claude Code** and the **Codex CLI** on your `PATH`, signed in on your own subscriptions.
- `tmux`, `jq`, `git`, `python3`. The app checks for these on first launch and offers to install
  them through Homebrew, with a button.

## Run it from the terminal instead

The engine works on its own, with no app and no checkout:

```bash
curl -fsSL https://bulava.app/install.sh | bash
night-shift status
```

It installs into `~/.night-shift`, links seven commands into `~/.local/bin`, writes three slash
commands into `~/.claude/commands`, and sets Claude Code's status line and worker hooks. It backs
up `~/.claude/settings.json` before touching it. To take all of that back out:

```bash
night-shift uninstall
```

which leaves `~/.claude/supervisor` — your queue, your run state, your reports — alone.

**The app is still the recommendation**, and not for marketing reasons. macOS grants screen
recording and accessibility to a signed application, not to a shell script, so runs that have to
photograph a user interface in order to prove they worked need Bulava running. Everything else
works either way.

## Build it yourself

```bash
open "Night Shift.xcodeproj"     # scheme: Night Shift
# or
xcodebuild build -scheme "Night Shift" -destination 'platform=macOS'
./.night-verify.sh               # build and the whole test suite
```

The app is not sandboxed. It has to spawn `bash`, `git` and `tmux` and read `~/.claude`, which a
sandboxed app cannot do. This is a local tool that drives local CLIs, so that is the correct trade
rather than a corner cut.

### Where it keeps things

The engine owns `~/.claude/supervisor`. The app keeps its own layer — your product registry,
captures, work items and conversations — in `~/Library/Application Support/NightShift`. Deleting
that folder resets the app without touching the engine.

Each project folder maps to an engine instance by the slug the engine uses: the sanitized folder
name plus the first 12 hex characters of the SHA-1 of its canonical path. That is how a project you
added links to the worker running against it, its queue entries and its verifier evidence. It is
reproduced in `Night Shift/Engine/Slug.swift` and checked against live instances.

## The website

`site/index.template.html` is the source; the page itself is **generated** by `site/render.sh`
and never edited by hand. `site/render.sh` fills in the version, the size and the minimum macOS — all read off the
built artefact, never typed — and rewrites each picture's name to carry a hash of its contents.

`site/demo/` is how the screenshots are taken: it launches a second, isolated Bulava with invented
products and an English interface, so no frame of the real desktop is ever published and no blur
has to be trusted. `site/analytics/check-screenshots.py` reads the published captures with Vision
and fails if any of them shows a real project name.

## Honestly

This is a beta. It runs every day and it built itself, but the number of people using it who are
not its author is small. Found a bug: [stepanokdev@gmail.com](mailto:stepanokdev@gmail.com).

## Licence

**FSL-1.1-ALv2** — the Functional Source License with an Apache 2.0 future grant. See
[LICENSE](LICENSE).

In plain words: read it, change it, run it, use it inside your company, teach and research with
it. The one thing you may not do is sell a competing product or service built on it — another
Bulava, under another name. Two years after each version is published, that version becomes
Apache 2.0 and even that restriction lapses, which is the point: nothing here is locked away
forever, and nobody gets to ship it as their own next week.

It is deliberately **source-available rather than OSI open source**, and it is worth being honest
about the difference: an OSI-approved licence cannot forbid a competing rebrand, only require it
to share its source. If that trade matters to you, the Apache-licensed versions are dated and
coming.

The name **Bulava**, the mace mark and bulava.app are not covered by the licence. Fork the code,
not the identity.

Third-party notices, including Sparkle's, are in [NOTICE.md](NOTICE.md).
Claude Code and the Codex CLI are not bundled, vendored or redistributed here; Bulava runs whatever
copies are already on your machine.

Further reading in this repository: [`engine/ENGINE-README.md`](engine/ENGINE-README.md) — what
the engine does between your message and the report, stage by stage. The three arrangements the
current one replaced are drawn out at [bulava.app/pipeline/](https://bulava.app/pipeline/).
