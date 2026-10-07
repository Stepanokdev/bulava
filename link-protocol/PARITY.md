# Desktop ↔ phone parity

Every thing the director can do in Bulava on the Mac, and where it is on the phone. A row changes
in the same change as the feature — see [`docs/mobile/SYNC.md`](../docs/mobile/SYNC.md).

**Status:** ✅ on the phone · 🖥️ at the Mac by nature (it is about the Mac itself) · ⛔ not on the
phone by decision · 🔜 not yet on the phone.

## Projects and chats

| Desktop | How the phone does it | Status |
|---|---|---|
| Product list with state | Drawer: every product, its state dot, pinned first | ✅ |
| Add a product / connect a folder / add a resource | Refused by the Mac (`not_on_phone`). Folders are connected where they are | ⛔ |
| Chats of a product, pinned first | Drawer, under each product | ✅ |
| New chat | `+` beside the product, or the pencil in the top bar. The chat id is the phone's | ✅ |
| Rename, pin, archive a chat | Top bar menu | ✅ |
| Archived chats, read, unarchive | "Archived" under the product; the menu unarchives | ✅ |
| Go to a product or chat (⌘K) | Search at the top of the drawer, by chat title | ✅ |
| Rename, pin, remove a product; product icon | `…` beside the product in the drawer; the icon is the Mac's own | ✅ |
| Claude's and Codex's limits at the foot of the sidebar | At the foot of the drawer, above the settings: each engine's session and week, how much is used and when it comes back, dimmed when read long ago; folded to one line — each engine's tightest window — and the fold is kept; each meter with the tick where an even pace would be and the pace in the Mac's words | ✅ |
| The week's widgets on the Mac's desktop (without you, how runs ended, receipt, rhythm, code changes, limits, working now, the week at a glance) | The same faces on the Home Screen — iPhone (with the Lock Screen's limits, without you and working now) and Android — drawn from `home.week`, kept for when the Mac is out of reach and saying how old they are; removed when the Mac is forgotten. The demo sends no week: its widgets say to connect a Mac | ✅ |
| A tap on a week widget (`bulava://week/<face>`) opens Bulava | A tap on a widget opens the app | ✅ |
| The right-hand pane: folders and their access, changes, checks, reports, instructions | The pane button in the chat's top bar, or a tap on the chat's title — for a new chat too. The same sections in the same order, read again every four seconds while open; the lock ("Can edit" / "Ask before editing") works from the phone, a change opens its diff, a report opens, "Create report" makes one. Below them "now and next" and the pieces of work | ✅ |

## The conversation

| Desktop | How the phone does it | Status |
|---|---|---|
| Messages, answers, Codex answers | Your messages on the right; answers as full-width prose | ✅ |
| Markdown, code blocks, lists, links | Markdown renderer | ✅ |
| Tool steps | Folded into one line with a count, expandable | ✅ |
| Consultations with Codex | A card: the question and the answer, expandable | ✅ |
| Files and galleries from a run | Thumbnails (tap for full screen), file chips | ✅ |
| Links in answers to files on the Mac | Under the answer as files to open (`file.open`): the Mac shares each on its home Wi-Fi and the phone's browser shows it — a site with its own files, a note as a page. Same Wi-Fi only | ✅ |
| Status line (working, preparing, waiting for a window, frozen…) | Same words, under the last message, live | ✅ |
| The run step by step: a strip under the chat and the "Run" section at the top of the right pane, from the engine's journal (`run-events.jsonl`), with its event log | Not yet: the phone has the status line's words | 🔜 |
| Queue count | In the status line | ✅ |
| Degradation note ("working without Codex") | In the status line | ✅ |
| Earlier messages | Scroll to the top, or "Show earlier messages" | ✅ |
| Find in this chat (⌘F) | Chat menu → Find in chat: matches counted, newest first, up and down | ✅ |
| Explain an answer | Under the answer: the short explanation, "step by step", and a fresh one when it went stale | ✅ |

## Sending

| Desktop | How the phone does it | Status |
|---|---|---|
| Write and send | Composer. Sent into the chat on the phone's screen, whatever the Mac shows | ✅ |
| Attach files, paste or drop images | `+`: a photo (sent as JPEG) or any file, up to 50 MB | ✅ |
| Voice dictation (Whisper on the Mac) | The mic beside Send records a voice note — a timer and a level while it runs — and sends it to the Mac, whose Whisper writes it down in the Mac's dictation language; the words land in this chat's field, never sent by themselves. The note stays on the phone until then: Mac asleep or out of reach, its model still downloading, too slow, nothing made out — it says so, with "Try again" (the same request, so the words never go in twice) and "Discard". A Mac too old for it says so on the mic; the keyboard's own dictation is always there | ✅ |
| Model and depth for Claude and for Codex | The chip under the field says what this chat's pill on the Mac says — the Mac keeps them per chat, and a choice on the phone is this chat's (an older Mac: its one default); behind it a page per engine — the model as a menu with the Mac's headings, depth as a scale. Claude alone or Codex alone is not offered, as on the Mac | ✅ |
| Stop the current answer | The send button turns into Stop while a run is busy | ✅ |
| Edit (take a message back) | "Edit" under your last message; the words come back to the phone's composer | ✅ |
| Send again after "not delivered" | Under the message | ✅ |
| Copy an answer | Copy under the answer | ✅ |
| A message the phone could not deliver | Stays in the thread as "not sent", with Edit and Send again. Never sent later on its own | ✅ |
| Slash command suggestions | "/" at the start of the field lists the commands the Mac's composer offers for this product | ✅ |
| Pipeline the chat's messages go through (pill beside the models; built-in and your own) | Not yet: the phone sends through whatever the chat has chosen on the Mac | 🔜 |

## Things that need the director

| Desktop | How the phone does it | Status |
|---|---|---|
| Trust a folder for Claude Code | Card under the message: "Trust and send" | ✅ |
| Finish Claude Code's first-run setup | Card: "Finish setup and send" | ✅ |
| Create git in a folder | Card: "Create git and send" | ✅ |
| MCP servers in a project | Card: "Enable and send" / "Send without them" | ✅ |
| Uncommitted work | Card with the file list: leave the changes, commit as me, not now. «Commit as me…» opens the Mac's own sheet: the author, the message, the branch, every file it takes, and no commit when git does not know who you are | ✅ |
| Files too big for the checkpoint | Card with the files, their sizes and an «in git» mark: leave them out of the checkpoint and send, add them to .gitignore and send, not now. A file git already tracks is explained, not offered. The Mac sends the generic ask (`largeFiles`), so the phone needed no change | ✅ |
| A task that did not start: uncommitted work, MCP servers, a folder with no git | On the Mac a dialog; on the phone the same dialog, coming up by itself, with its own buttons — and a notification. Answered on either side, it goes from both | ✅ |
| Another chat holds the project | Card: "Stop … and send", with a confirmation | ✅ |
| Codex out of quota | Card: "Answer with Claude" | ✅ |
| Claude asks to sign in again | Card that says to sign in on the Mac. A login happens in a terminal there | 🖥️ |
| A worker's question with options | Question card: options, several allowed where so, own words, the context rows | ✅ |
| A decision about Codex | Same question card; the Mac signs and sends it | ✅ |
| Notification when something needs you | Android: a system notification even with the app closed (foreground service). iPhone: the same while the app is open; with the app closed, a push through the relay — see below | ✅ |
| Answer a request from its notification | "Trust and send", "Yes, do it" and the like are on the notification itself, after Face ID / fingerprint / the code; a button that asks "are you sure?" stays in the app. A tap on the relay's push opens what it is about — the newest request's chat, the report's chat or its product's details, the settings for the Mac's setup — the app closed or not | ✅ |
| Readiness (engine, Claude Code, permissions) | Settings → Mac readiness, with the fixes a phone can make; system permissions say "on your Mac" | ✅ / 🖥️ |

## Work and reports

| Desktop | How the phone does it | Status |
|---|---|---|
| Report card in a chat, with its buttons | Card with the same buttons; "Ask for changes" puts the cursor in the composer | ✅ |
| Open a report | Full-screen report, pictures fetched from the Mac and inlined | ✅ |
| "Ready to read" in the menu bar | Each report is in its chat as a card and in the chat's details; one with no chat is in the product's details. A report that comes in is a notification with a sound, taken back once it is read on the Mac; a tap opens its chat, or the product's details for one with no chat | ✅ |
| Menu bar: what is going on right now | iPhone: a Live Activity on the Lock Screen and in the Dynamic Island — each piece of work by name with how long it has run, then how it ended — kept up by the relay while the app is closed, the names sealed. Android: the same names in the connection notification | ✅ |
| A chat's answer is in | A notification with the chat's name (Android, iPhone with the app open); with the iPhone's app closed, the relay's "The work is done" push, which opens the chat | ✅ |
| Save a report as PDF | The share button on the report: A4 pages in its print styles, searchable text, its pictures — iPhone's share sheet, Android's print dialog ("Save as PDF") | ✅ |
| Make a report of a chat / open it | In the status row under the chat | ✅ |
| Merge / open a pull request / "that answers it" from the report | Under the report: the report window's own buttons. Merge and pull request ask first and report the Mac's verdict | ✅ |
| Decide on a report's questions (`decisions.json` beside it; the Mac draws them beside the report; it is listed as "Questions for you", not as a report) | The page and its questions a tap apart, with the platform's own segmented control at the bottom ("Document · Questions 2/3"); the page keeps its place while the questions are open. The questions are drawn by the phone itself, not by the page: each question with its options and the agent's advice marked, a comment where offered, an overall comment, then "Send", which first lists every question with what was chosen or that it stays undecided. What is ticked is kept on the phone until it is sent; a send that lost the connection is sent again by itself, under the same id, so it lands once. Questions that changed meanwhile, or an answer from the Mac in between, are said in words and the report is read again (`report.decide`). Opened again, they show the answer already sent, and "Send a correction" stays off until something in it changes — on the Mac as on the phone | ✅ |
| What happened (worker trail), open in editor, Finder, terminal | They open things on the Mac | 🖥️ |
| Product report ("everything done so far") | The chat's details → Everything done so far | ✅ |
| Variant gallery and several streams of one piece of work | The chat's details → Work: each variant with its buttons, and their one combined report | ✅ |
| Links inside a report | The page cannot load or open anything. A link the reader taps asks "Leave the report?" with the address, then opens the browser | ✅ |

## Settings and the rest

| Desktop | How the phone does it | Status |
|---|---|---|
| Chat engine, Claude model and depth, Codex model and depth | Composer chip | ✅ |
| Appearance, interface language | The phone follows its own system settings | 🖥️ |
| Engine paths, ask-user wait, polling, driving apps | Mac settings | 🖥️ |
| Keep the Mac awake while work runs | A Mac setting (on by default). It holds the Mac up only while work goes on by itself, and the menu bar says when it is on battery or a closed lid would still stop it | 🖥️ |
| Skills and MCP inventory | Settings → Skills and MCP servers, or from a project's context (only its skills). Counting use, updating and deleting a skill work from the phone | ✅ |
| Pipelines: library, canvas editor, prompts, the chat that changes a pipeline, import from GitHub, share | Building a pipeline is a canvas and a quarantine on the Mac | 🖥️ |
| An automation's pipeline | Chosen in the automation's form on the Mac | 🔜 |
| Diagnostics | Mac only | 🖥️ |
| Pair / remove a phone | Pairing is started on the Mac; the phone can unpair itself in Settings | ✅ |
| Updates (Sparkle, "Check for Updates…") | A banner at the top: a newer phone app is out — the Mac reads bulava.app for it, the phone opens nothing on the internet — with Download / Open TestFlight and "Not now", put off per build. When one side is too old for the other, the banner names it — this phone or the Mac by its name — with both versions and what to do; chats and drafts stay readable under it | ✅ |
| — (phone only) Try without a Mac | "Try it without a Mac" on the first screen: sample projects answered by a Mac simulated on the phone, under a "Demo" bar. Nothing of the real pairing, drafts or notifications is touched | ✅ |

## Notifications on an iPhone

iOS does not let an app keep a connection open in the background, and only Apple's push service
can wake an app that is not running. So when an iPhone is paired and its app is not on screen, the
Mac asks a small relay (`bulava-mobile/push-relay/`, `https://bulava-push.stepanok.com`) to send a
push. The relay is told the phone's device token and which of three fixed sentences from the
phone's own strings to show — "Your Mac is waiting for your answer", "A task is done. Its report is
ready to read", "The work is done. The answer is in the chat" — and what is waiting is read over
the local link when the phone opens.

The Live Activity is kept up through the same relay: three counts, and the names of the work sealed
with a key the phone made, which the relay cannot open.
