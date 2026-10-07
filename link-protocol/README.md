# Bulava Link — the protocol between the Mac and the phone

Bulava on the phone runs nothing. It is a window onto Bulava on the Mac: the Mac owns every
product, chat, run and decision, and the phone shows what the Mac sends and asks the Mac to act.
This folder is the contract between the two. It lives outside both apps on purpose: the Mac
(`Night Shift/MobileLink/`) and the phone (`bulava-mobile/shared/.../link/`) are two independent
implementations of what is written here, and the tests on both sides read the same files.

- [`contract.json`](contract.json) — the protocol version and the capabilities a Mac offers.
- [`fixtures/v1/`](fixtures/v1) — what the Mac sends, byte for byte. Written by the Mac's tests.
- [`fixtures/future/`](fixtures/future) — what a newer Mac might send. Hand-written; the phone must
  read it without failing.
- [`PARITY.md`](PARITY.md) — every desktop capability and where it is on the phone.
- How to keep the two in step while developing: [`docs/mobile/SYNC.md`](../docs/mobile/SYNC.md).

## Transport

- **TLS 1.3 + WebSocket**, served by the Mac with `NWListener` on port `47291` (any free port when
  that one is taken), path `/link`, text frames of UTF-8 JSON, at most 4 MB each.
- **The Mac's identity** is a P-256 key and a self-signed certificate over it, kept in
  `~/Library/Application Support/NightShift/mobile-link/identity.json` (mode 0600). It is built in
  memory with `SecIdentityCreate`; the Keychain is not involved.
- **The phone trusts one key.** The pairing code carries the SHA-256 of the certificate's
  SubjectPublicKeyInfo (base64url, no padding). The phone checks it inside the TLS handshake and
  sends nothing to a server that does not match. No certificate authority is consulted.
- **Local network only.** The listener refuses cellular and "other" interfaces (VPN tunnels), and a
  peer whose address is not private IPv4 (RFC 1918), link-local, loopback or IPv6 unique-local is
  dropped before anything is read. Carrier-grade NAT space (`100.64/10`, where VPN overlays live) is
  refused. Nothing of the work travels through bulava.app or any other server; the one exception
  is an iPhone's wake-up, which carries a device token and no content (see below).
- **Found again by Bonjour.** The Mac advertises `_bulava-link._tcp` with TXT `id=<desktopID>` and
  `v=<protocol>`. A phone that cannot reach the addresses it remembers browses for that id.
- **Listening only when needed.** The Mac opens the port once a phone is paired, or when the pairing
  panel is opened. A Mac that never met a phone never listens (and never asks for Local Network
  access). The XCTest host never listens unless a test asks for it.

## Pairing

The phone icon in the Mac's toolbar opens a panel with a QR code. It encodes

```
https://bulava.app/pair#<base64url(JSON)>
```

with `{"v":1,"n":macName,"k":pin,"p":port,"h":[hosts…],"t":token}`. It is kept short because every
character makes the code denser on screen; the desktop id is not in it (it is the first 22
characters of `k`).
The fragment never reaches a server, so scanning the code with the phone's own camera opens the
download page without handing the page anything; the page offers `bulava://pair#…` to open the
app. Inside the app the scanner reads the same string.

- The **token** is 32 random bytes, valid for five minutes, and spent at its first use — a second
  phone presenting it is told `pairing_used`. Opening the panel again replaces it.
- A successful pairing answers with a **credential**: a device id and a 32-byte secret. The Mac
  keeps only the SHA-256 of the secret (`mobile-link/devices.json`, mode 0600). The phone keeps
  the secret in the Keychain (iOS, this device only) or encrypted with an Android Keystore key.
- **Removing a phone** on the Mac deletes its record and closes its socket with a `revoked`
  event. The phone forgets the pairing and says so.

## Handshake

The first frame from the phone is `hello`; nothing else is read before it, and it must arrive
within ten seconds.

```json
{"type":"hello","protocolVersion":1,"minimumVersion":1,
 "app":{"platform":"android","version":"1.0","deviceName":"Pixel 9","osVersion":"Android 17"},
 "pairing":{"token":"…"}}            // or "credential":{"deviceID":"…","secret":"…"}
```

The Mac answers `welcome` (with `credential` only when pairing) or `refused` and closes. Refusal
codes: `pairing_expired`, `pairing_used`, `unauthorized` (bad secret), `revoked` (unknown device),
`protocol_too_old` (update the phone), `protocol_too_new` (update the Mac). A refusal carries the
Mac's version so the phone can say which side to update, and — from a Mac that has read it —
`phoneApps`, the newest phone app (below), so a phone too old can name the version to get and
where. Five failed handshakes from one address within a minute close further attempts from it for
that minute.

## After the handshake

**Requests** from the phone: `{"type":"request","id":"…","op":"…","args":{…}}`.
**Responses** from the Mac: `{"type":"response","id":"…","ok":true,"result":…}` or
`{"ok":false,"error":{"code":"…","message":"…"}}`. `message` is in the Mac's interface language and
safe to show.
**Events** from the Mac: `{"type":"event","event":"…","data":…}`.

| op | args | result |
|---|---|---|
| `home.subscribe` | — | empty; then `home` events |
| `chat.open` / `chat.close` | `chatID` | empty; then `chat`, `chat.delta`, `chat.gone` events |
| `chat.history` | `chatID`, `before`?, `limit`? | `{entries, hasEarlier}` |
| `chat.create` | `productID`, `chatID` (chosen by the phone) | chat summary |
| `chat.send` | `productID`, `chatID`, `entryID` (chosen by the phone), `text`, `attachments[]` (refs) | `{entryID, duplicate}` |
| `chat.stop` | `chatID` | empty |
| `chat.rename` | `chatID`, `title` | empty |
| `chat.archive` | `chatID`, `archived` | empty |
| `chat.pin` | `chatID`, `pinned` | empty |
| `entry.retry` | `entryID` | empty |
| `entry.takeBack` | `entryID` | `{text, attachments}` — back into the phone's composer |
| `action.invoke` | `id`, `input`? `{text}` | empty |
| `question.answer` | `entryID`, `selections[[…]]`, `text` | empty |
| `upload.begin` / `upload.chunk` / `upload.finish` / `upload.cancel` | `name, kind, size` / `uploadID, offset, data(base64)` / `uploadID` | `{uploadID, chunkSize}` / `{received}` / a file ref |
| `audio.transcribe` | `requestID` (chosen by the phone), `ref`? (from `upload.finish`), `chatID`? | `{requestID, chatID, text}` — words for the phone's composer, never a message. See "Dictation" |
| `file.read` | `ref`, `offset`, `length` (≤ 512 KB) | `{ref, offset, total, data, mime, name}` |
| `report.open` | `target` | `{title, html, root}` |
| `settings.set` | `group`, `value` (one the Mac offers now; `mode` is not offered, and is `stale`), `chat`? — that chat's own choice, from a phone that was sent the chat's `composer`; without it, the Mac's default | empty |
| `product.rename` / `product.pin` / `product.remove` | `productID`, `name` / `pinned` / — | empty |
| `commands.list` | `productID` | `[{id, label, detail}]` — the composer's slash commands |
| `context.get` | `productID`, `chatID`? | the Mac's right-hand pane: folders, changes, checks, the chat's reports with "Create report" (`chatReports`), instructions, "now and next", work, the product report. A `chatID` of another product is ignored. Change refs are the same for the same file, so a phone that reads it every few seconds replaces them |
| `context.diff` | `ref` (from a change `context.get` sent) | `{text}` |
| `skills.get` | `productID`?, `full`? | skills and MCP servers; `full` counts use in the transcripts |
| `push.register` | `token` (hex), `environment` (`development` \| `production`), `seal`? (32 bytes, base64), `kinds`? | empty; an iPhone's APNs token, the key its Lock Screen reads names with, and the pushes it has words for |
| `presence.set` | `foreground` | empty; whether the app is on screen |
| `activity.register` | `kind` (`start` \| `update`), `token` (hex, or empty to forget), `environment` | empty; an iPhone's Live Activity tokens |
| `device.forget` | — | empty; the Mac removes this phone |

`product.add`, `folder.connect`, `resource.add`, `resource.remove` are refused with
`not_on_phone`: folders are connected at the Mac, where they are. Any other unknown op is
`unknown_operation`.

Buttons in `context.get`, `skills.get` and `report.open` answers are `ActionDTO`s like any other;
they are pressed with `action.invoke`, and are good for as long as the phone keeps the connection.

### What the Mac sends

- `home` — products with their chats (and archived chats), everything waiting for the director
  (`attention`), work that finished and waits to be read (`finished`, each with the button that
  opens its report — the tasks the Mac's menu bar counts as "ready to read"), the composer's
  choices, the Mac's readiness, `summary`: three counts — runs working by themselves, things
  waiting for the director, reports ready — `live`: the same work by name (below), and `limits`:
  Claude's and Codex's usage as the foot of the Mac's sidebar shows it (below). Sent whole
  whenever any of it changes.
- `limits` is the sidebar's "Limits", in the Mac's words: each engine it has heard from, with its
  `windows` — `Session` and `Weekly`, each the share `used` (0–100), `usedLabel` ("34% used"),
  `pressure` (`comfortable` \| `tight` \| `nearlyOut`) and when it comes back (`resets`, "2h 5m",
  said again as it runs down). A window shows once something is used or its reset is known, and
  not after its reset has passed; `used`/`pressure` of the engine are its tightest window, for the
  folded line; `note` stands in for the windows while none is known; `stale` dims the meters of one
  read over half an hour ago, `readAgo` says when. Absent while neither engine is known.
- `composer` is the Mac composer's run control: Claude writes, Codex reviews, and each has a model
  and a depth. Every group says its `engine` (`claude` \| `codex`) and `kind` (`model` \| `depth`);
  a model option may carry the `section` of the Mac's menu it sits under; `summary` is what the
  Mac's pill says — each engine's model and depth. Claude alone or Codex alone is not offered while
  the Mac does not offer it (`RunControlPanel`).
- `live` is "Working now", by name: `running` — each chat whose answer is being written and each
  run going on by itself, with when it started; `ended` — what stopped since the stretch began, each
  with its `outcome` (`done` \| `attention` \| `failed` \| `stopped`) and the Mac's words for it;
  `over` once nothing has run for a while. A line that drops out of `running` counts as stopped
  only once it has stayed out for 20 s — between Claude's answer and Codex's review a chat can look
  idle for a moment, and that moment is not its end.
- `chat` — the last 60 visible entries of an open chat with its header (status, activity, queue,
  buttons, and `composer`: the chat's own run control, shaped like `home.composer` — the Mac keeps
  model and depth per chat; absent from an older Mac, and then the phone reads `home.composer`).
  Then `chat.delta` — entries that changed, entries that are gone, the new header, and the
  window's order when it changed. Entries that merely scrolled out of the window are not "gone".
- `phoneApps` in `home` — the newest phone app per platform, `{android, ios}`, each
  `{version, build, url}`, as the Mac last read it from `https://bulava.app/mobile/version.json`
  (written by the release, `scripts/phone-versions.py`). The phone opens nothing on the internet
  itself, so the Mac reads it — when a phone comes to the door, at most every six hours, kept on
  disk between launches. A phone whose build is lower offers the update, put off per build. Absent
  until the Mac has read it once, and from an older Mac.
- `chat.gone` — the chat no longer exists. `revoked` — this phone was removed.

The Mac builds these inside `withObservationTracking`: whatever a projection read calls back when
it changes, so the phone hears about a new line of an answer about as fast as the Mac's own window.
A slower beat (1 s while something is running, 10 s otherwise) covers what changes with time alone.

### Buttons the Mac sends

Every button on the phone that does something to the work is one the Mac sent: an `ActionDTO`
with an opaque `id`, a `label` already in the Mac's language, a `style`, and a `kind`:

- `invoke` — send `action.invoke` with the id (and `input.text` when `input` is present);
- `compose` — put the cursor in the composer with `input.placeholder`;
- `report` — open `report.open` with `target`;
- `takeBack` — call `entry.takeBack`;
- `mac` — not a button. The label says what to do at the Mac (sign in, allow Screen Recording).

A pressed id is looked up in a projection made **at that moment**. A request answered on the Mac
a second earlier is simply not there, and the phone is told `stale` — "already handled on your
Mac" — instead of answering it twice. A kind the phone does not recognise is shown as its label and
never pressed.

### Files

A file is readable only by a `ref` some projection mentioned (`att:<attachment>`, `art:<run>/<path>`,
`icon:<product>`), or by a path under a report folder the phone opened (`rep:<token>/<relative>`,
fenced against `..` and symlinks). There is no way to name an arbitrary path.

### Dictation

The phone's mic records an M4A (AAC) and sends it up with the `upload.*` operations, `kind` `audio`.
`audio.transcribe` then has the Mac's Whisper hear it in the Mac's own dictation language — the
model and the setting its composer uses — and answers the words. The phone puts them in the
composer of the chat it recorded in; nothing is sent.

- **One request, heard once.** `requestID` is the phone's, and kept across every attempt. Asked
  again — a lost answer, a phone that gave up waiting while the model loaded — the Mac answers the
  same words from memory (for half an hour), or waits for the hearing already under way. Only
  words are remembered; a failure may be asked again.
- **The recording is spent.** Only a file that arrived from a phone and went into no message can be
  named, and the Mac deletes it once heard, whatever came of it. The phone keeps its own copy until
  the words are in its composer. A `ref` the Mac no longer has, for a request it never answered, is
  `not_found`: the phone sends the recording again.
- **Errors**: `dictation_unavailable` — no Whisper to hear with: this build has none, or its model
  is not on disk yet; the Mac then fetches it, once, and asking again in a few minutes works. The
  Mac's Apple speech fallback is not used for a phone: it asks for permission in a dialog nobody is
  in front of. `not_transcribed` — Whisper made out no words. `not_found` as above. A Mac without
  the `audio.transcribe` capability is told about on the phone's mic: update the Mac, and use the
  keyboard's dictation meanwhile.

### Staying consistent

- **Ids are chosen by the phone** for what it creates. A `chat.send` retried after a lost reply
  carries the same `entryID` and answers `duplicate: true`; a `chat.create` finds the chat the first
  attempt made. The ids live in the Mac's own stores, so this holds across a restart of either side.
- **A phone never moves the Mac's screen.** Its chats are addressed by id; creating one does not
  change the chat open on the Mac, and taking a message back hands the words to the phone's
  composer, not the Mac's.
- **Reconnect is a fresh snapshot.** After a drop the phone subscribes again and the Mac sends
  `home` and every open `chat` whole. There is no event log to replay.

## Waking an iPhone

Only an iPhone needs this; Android keeps its connection in a foreground service.

1. The iPhone registers for remote notifications and sends its token with `push.register` on every
   connection. It sends `presence.set` when it comes on screen and when it leaves.
2. When something new starts waiting for the director — a new id in `home.attention`, compared
   with what was already waiting when the Mac started — the Mac posts
   `{"token":"…","environment":"…"}` to `<relay>/v1/notify` for every iPhone with a token that is
   not on screen right now. When a report comes in — a new id in `home.finished` — it posts the
   same with `"kind":"finished"`. When a chat's answer is in — a `live.ended` line with outcome
   `done` — it posts `"kind":"done"` with `"sealed"`: which chat, sealed with the phone's key, so a
   tap opens it. `done` goes only to a phone whose `push.register` listed it, and only to a relay
   whose `GET /v1/features` lists it; a sealed box only to a relay that says `sealed`.
3. The relay (`bulava-mobile/push-relay/`) signs a provider token with Bulava's APNs key and sends
   a push that says one of the app's own fixed sentences — `PUSH_BODY`, `PUSH_BODY_DONE`,
   `PUSH_BODY_REPLIED` — with a sound, one collapse id per kind, so ten requests are one banner. It
   passes `sealed` on unread. It answers `202`, `429` (this token was woken for this kind less than
   30 s ago) or `410` (APNs says the token is gone — the Mac forgets it).
4. Tapping the push opens what it is about. A `sealed` route names its chat. Without one — every
   relay sends the sentence, only a newer one the box — the phone goes by the sentence and, once
   the Mac has said what it lists now (a round trip on a live link, else the `home` after
   reconnecting; never the list kept from before the push), opens the newest of it: `PUSH_BODY`
   the newest in `attention` — its chat, the settings for the Mac's readiness, the product's
   details for one with no chat, nothing for a task that did not start (its dialog comes up by
   itself, as on the Mac); `PUSH_BODY_DONE` the newest in `finished` — its chat, or its product's
   details; `PUSH_BODY_REPLIED` the newest `done` line in `live.ended`. A tap that launched the app
   is kept until the app's screen is up. What is waiting is read over the link, as always. Once the app has heard from the Mac, it takes the relay's pushes back: each
   thing is now told on its own.

The relay is Bulava's own, `https://bulava-push.stepanok.com`. `BulavaPushRelayURL` in the Mac's
defaults (or `BULAVA_PUSH_RELAY`) points elsewhere, HTTPS only, and `off` turns it off; then an
iPhone hears requests while the app is open and on background refresh.

### The Live Activity

The iPhone shows `live` on the Lock Screen and in the Dynamic Island: each piece of work by name,
counting up from when it started, then how each ended — started when a stretch of work begins,
ended on its last word once the stretch is `over`. What waits for the director is its own push, not
a line here. From a Mac without `live` the activity shows how many are working.

- With the app open, the phone runs the activity itself from each `home`.
- With it closed, the Mac does it through the relay. The phone hands over two tokens with
  `activity.register`: `start`, which lets a push begin an activity, and `update`, the token of the
  activity running now (empty when it ended). The Mac posts `{"token", "environment", "event",
  "state": {"working", "waiting", "ready", "sealed"}}` to `<relay>/v1/activity` — `start` when a
  stretch begins and there is no activity, `update` when what runs changes (at most one every 6 s,
  the rest folded into the next) and every 10 minutes regardless, `end` when the stretch is over.
- `sealed` is the names: an AES-GCM box (`LiveSeal`, bound to `bulava.live.v1`) of three running
  lines, the count, the last three ended lines and the chat the first is about, made with the key
  the phone gave in `push.register`. The phone keeps that key in a Keychain group only it and its
  Lock Screen widget share; the widget opens the box. The relay and Apple carry a string they
  cannot read. A phone that gave no key, or a relay that does not say `sealed`, gets counts only.
- The relay sends it as an ActivityKit push (`apns-push-type: liveactivity`): the state as the
  content state, `stale-date` 25 minutes on, so a Mac that went to sleep shows as such rather than
  as frozen lines; a start carries the empty `ShiftAttributes` and a fixed alert the app localises.
  An activity swiped away is not started again until the next stretch of work.
- Only a `202` moves what the Mac believes about the phone's activity: a start counts as started,
  an update as shown, an end spends the token. `410` forgets the token. No network, `429` and `5xx`
  are tried again after 2 s, doubling up to a minute, eight times; any other refusal changes
  nothing and is not repeated as it is. Whatever was refused or given up on goes again when what
  runs changes or at the ten-minute beat — a start included.

Three counts and a sealed box are all the relay ever learns about the work.

### Buttons on notifications

A request's own buttons come with its notification when they do something at once — `invoke`
buttons with no `confirm`, at most two, one taking a line of text when it has `input`. They are
pressed with `action.invoke` like any other, after the phone was unlocked — on iOS by
`authenticationRequired`; on Android by the app's own answer screen, which on a locked phone asks
for the PIN, pattern or fingerprint before pressing anything (Android 10 and 11 have no system
check for this; from 12 `setAuthenticationRequired` asks first as well). The app connects first
when it was closed. A button already answered comes back `stale`, and the notification says so. The relay's
pushes have no buttons: they carry nothing that could name one.

A tap on one of the phone's own notifications leads where a tap on the relay's push about the same
thing would (`AppController.place`): a request or a report into its chat; the Mac's setup into
the settings — the notification says `about: readiness`, handed back in iOS's `userInfo` and
Android's intent extras; a report with no chat into its product's details; a task that did not
start nowhere, since its dialog comes up by itself.

## Reports on the phone

A report is shown by the phone's own web view, which may reach nothing: the Mac's pictures are
fetched over the link and inlined as `data:` before the page is shown; a Content-Security-Policy
allows only `data:` and inline code; and each platform adds its own fence (a WebKit content rule
list that blocks every load but `data:`/`about:` on iOS, `blockNetworkLoads` and an interceptor on
Android). The page never navigates. A link the reader activates — or a script clicks — is offered
as "Leave the report?" with its address, and only a yes opens the browser.

## Compatibility rules

These are what the fixtures and tests enforce. They are the whole reason desktop changes do not
break phones in people's pockets.

1. **Within one protocol version, fields are only added.** A field already sent keeps its name,
   type and meaning. Nothing is removed. New fields are optional on the phone (a default in Kotlin).
2. **Every enum-like value is a string**, and the phone treats one it does not know as "something
   the Mac knows about": a status `code` it cannot place still shows its `label`; an entry `kind` it
   does not draw is shown as its text; a button `kind` it cannot perform is shown as words.
3. **Words come from the Mac.** Status labels, ask texts and button titles are the Mac's own
   localised strings, so a new status or a new kind of ask reaches an old phone already worded.
4. **Capabilities, not versions, decide what the phone shows.** A Mac lists what it offers in
   `welcome.capabilities`; the phone hides what is not there. Adding a capability is additive.
5. **A breaking change is a new protocol version.** The Mac then keeps speaking the old one for at
   least one release (`minimumVersion`), and a phone or a Mac too old for the other is told which
   one to update rather than failing without a word.
6. **The DTOs are projections.** `LinkWire.swift` types are never the app's models and are never
   decoded back into them. Renaming a property of `Chat` or `ConversationEntry` changes a projection
   function and nothing on the wire.

## Trying it by hand

Serve a Mac on an isolated state directory — no real products, chats or runs involved — and pair
an emulator with it:

```sh
S=$(mktemp -d)
TEST_RUNNER_BULAVA_LINK_HARNESS_SECONDS=1200 TEST_RUNNER_BULAVA_LINK_HARNESS_OUT=$S/pairing.txt \
  xcodebuild -project "Night Shift.xcodeproj" -scheme "Night Shift" -destination 'platform=macOS' \
  -derivedDataPath "${TMPDIR:-/tmp}/bulava-verify-dd" CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=stepanok.com.Night-Shift.verify \
  -only-testing:"Night ShiftTests/PhoneLinkLiveHarness" test &
# once $S/pairing.txt exists:
adb shell am start -a android.intent.action.VIEW -d "bulava://pair#$(cut -d'#' -f2 $S/pairing.txt)"
```

The harness seeds a product with a few chats, folders, running and finished work and a piece of
work in variants, and answers whatever the phone sends, a few words at a time, so the live stream
can be watched. Sending "ask me" puts a question into the chat ten seconds later — time to put the
app in the background and see it woken. "ask for trust" stops a message on an untrusted folder in a
chat of its own, ten seconds later: a request whose notification carries its button (pressing it
on the harness would write the real `~/.claude.json`, so look, do not press). "start work" and
"finish work" begin and end a run fifteen seconds later, the way the engine leaves one on disk — a
watchdog process and its instance folder, which the Mac reads with its own snapshot code — so the
counts, the Live Activity and the quiet "report ready" can be watched. "setup breaks" takes tmux
out of the Mac's setup ten seconds later: a request with no chat, whose notification opens the
settings.

- `BULAVA_LINK_HARNESS_PROBE=127.0.0.1:8766,10.0.2.2:8766` adds a chat whose report tries every way
  a page can reach out, at those addresses (the simulator reaches the Mac at `127.0.0.1`, the
  emulator at `10.0.2.2`). Run any server that logs requests there; opening the report must leave
  the log empty.
- `BULAVA_LINK_HARNESS_PORT=0` takes any free port — the Mac's own Bulava may hold the usual one.
- `BULAVA_LINK_HARNESS_REPORT=<report.html>` adds a chat whose report is that file, pictures beside
  it: a long one is how the phone's PDF is tried.
- "ask to commit" stops the message on uncommitted work (the engine's exit 77) and "task asks to
  commit" does the same to a new task — the Mac's commit sheet and its task dialog, on the phone.
- "start work" and "finish work" also carry the chat they were sent in through working and its
  answer, so the Lock Screen names it and "The work is done" arrives.
- `BULAVA_PUSH_RELAY=http://127.0.0.1:8787` points the Mac at a relay on this Mac. The real one,
  run locally with the APNs key from `bulava-mobile/secrets/` (`LISTEN=127.0.0.1:8787`), reaches a
  simulator through Apple's sandbox — wake-ups, the quiet "report ready" and the Live Activity,
  push-to-start included. `xcrun simctl push` covers only ordinary notifications.

Both go to `xcodebuild` with `TEST_RUNNER_` in front, like the two above.
