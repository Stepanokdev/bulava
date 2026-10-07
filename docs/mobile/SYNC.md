# Building features for the Mac and the phone together

Bulava on the phone is a window onto Bulava on the Mac. It never decides anything about the work:
it shows what the Mac sends and asks the Mac to act. That is what keeps the two from drifting —
there is one implementation of every behaviour, on the Mac — and it is also why most desktop
changes need nothing on the phone at all.

This page is how to tell which kind of change you are making, and what each kind has to touch.

## The shape of it

```
Night Shift/ (Mac, Swift)                     bulava-mobile/ (phone, Kotlin)
  AppModel, stores, engine                      — nothing of the kind —
        │ read by
  MobileLink/LinkProjection.swift  ─────────►  link/Wire.kt          (the same shapes)
  MobileLink/LinkWire.swift        ◄───────┐   state/AppController   (what the phone holds)
  MobileLink/MobileLink.swift (ops) ◄──────┘   ui/…                  (how it looks)
                       ▲                                ▲
                       └──── link-protocol/ ────────────┘
                             contract.json, fixtures/, README.md, PARITY.md
```

- **`LinkWire.swift` / `Wire.kt`** are the wire types. They are projections, never the app's own
  models, and are never decoded back into them.
- **`LinkProjection.swift`** turns the app into those types, including every button the phone
  shows (with its label, in the Mac's language, and the handler behind its id).
- **`link-protocol/fixtures/v1/`** is what the Mac encodes, written by `LinkContractTests` and read
  by the phone's `LinkContractTest`.

## Which kind of change is this?

### 1. It changes behaviour, and the phone already shows it — nothing to do on the phone

A new reason a run waits, a new wording, a different rule about when a chat counts as busy, a new
kind of blocker message: these arrive as the Mac's own words (`StatusDTO.label`, `AskDTO.title`,
button labels) and the phone draws them as they come. Check that the projection still reads the
same function the Mac's own view reads (see the next section) and you are done.

### 2. A new button, or a new "the director has to answer this" — on the Mac only

Add it in `LinkProjection.swift` next to the others, with `register(id, label:, style:) { … }`,
calling the **same `AppModel` function** the Mac's button calls. The phone draws it as a button
the moment the Mac sends it, with no phone release. Rules:

- The id is **deterministic** (`"<what>:<chat>:<entry>"`), so pressing it after a refresh still
  finds it.
- The handler **checks the thing is still there** and returns `Builder.stale` when it is not. That
  is what turns "answered on the Mac a second ago" into "already handled" instead of a second answer.
- If the Mac's button opens a window or primes the Mac's composer, it is not an `invoke` on the
  phone: give it `kind: "compose"`, `"report"` or `"mac"` instead. `TaskPresentation` ids that do
  this are listed in `Builder.card(_:readOnly:)` — add a new one there.
- A new ask that shows under a message on the Mac (`EntryViews.swift`, `MessageEntry`) goes into
  `Builder.asks(for:chatID:readOnly:)` with the same condition, word for word.

### 3. A new field or a new kind of thing on the wire — both sides, one change

1. Add the field to the DTO in `LinkWire.swift` as **optional or with a default**, and fill it in
   the projection.
2. Add it to the matching class in `Wire.kt`, **with a default**.
3. Put it in a sample in `LinkContractTests.swift` and regenerate the fixtures:
   `TEST_RUNNER_BULAVA_UPDATE_FIXTURES=1 xcodebuild … -only-testing:"Night ShiftTests/LinkContractTests" test`.
4. Run the phone's tests: `cd bulava-mobile && ./gradlew :shared:testAndroidHostTest`. The
   contract test fails if the Mac sends a field the phone does not model — that is its job.
5. Draw it on the phone, and update `PARITY.md`.

A new request (`op`) is the same: handle it in `MobileLink.perform`, add a capability to
`LinkProtocol.capabilities` **and** to `link-protocol/contract.json` (a test checks they match),
and have the phone call it only when `controller.can("<capability>")` is true.

### 4. A breaking change — avoid it; if not, a new protocol version

Renaming a field, changing its type or meaning, or removing it breaks every phone already
installed. Do not. Add a new field next to the old one and keep filling both. If a break is truly
unavoidable, raise `LinkProtocol.version`, keep the old version working for at least one release
(`minimumVersion`), and add `fixtures/v2/` beside `v1/`.

## Where the phone reads the Mac

The projection must call the functions the Mac's own screens call, never re-derive them. If the
Mac's view has logic inline, move it into `AppModel` so both use it — `slashCommandRoots(for:)`
was moved out of the composer for exactly this reason. A few that matter:

| On the phone | Read from |
|---|---|
| Chat status line | `directPhase(for:)`, `directActivity(for:)`, `directDegradation(for:)`, `directQueueCount(for:)` |
| Which messages show | `visibleEntries(inChat:)` |
| Blockers under a message | the `trustBlocked`, `setupBlocked`, `gitConsentBlocked`, `mcpBlocked`, `dirtyTreeBlocked`, `handoffBlocked` maps, `codexWall`, `signInPromptEntryID(inChat:)` |
| Report card buttons | `TaskPresentation.cardActions(for:model:)` |
| Report window buttons | `TaskPresentation.finalActions(for:package:blocker:model:)` |
| Composer choices | `settings`, `claudeModels`, `codexModels` |
| Readiness | `readiness.checks` |
| Project context (the right-hand pane) | `resources(for:)`, `chatInspectorSnapshot(productID:chatID:)`, the chat's reports as `ProductInspector` lists them, `nowAndNext(for:)`, `workItems`, `streamTasks(of:)`, `hasFinishedWork(_:)` |
| Skills and MCP | `skillInventory(fast:)`, `mcpInventory(fast:)`, `updateSkill`, `removeSkill` |
| Limits (the foot of the sidebar) | `model.capacity`, shown by the sidebar's own rules: `UsageWindow.shownPercent`, `UsageSnapshot.tightestShown`, `isStale` — `LinkProjection.limits(_:)` |
| What wakes an iPhone | the ids in `home.attention` — the orange marks in the chat list and the task dialogs — and, quietly, those in `home.finished` |
| Ready to read | `openTasks(for:)` in `.review` — the tasks `reportsWaiting(forProductID:)` counts |
| Working (the Live Activity's first count) | `PowerKeeper.keepsAwake(_:)` over `instances`, plus `codexTurns` — the same test that keeps the Mac awake |

## The demo is a third reader of the protocol

"Try it without a Mac" runs `bulava-mobile/shared/.../demo/DemoMac.kt`: a Mac inside the phone that
answers the same ops with invented projects, so App Review and anyone without a Mac can use the real
screens. It is what the reviewer sees, so it moves with the phone:

- A new op or capability the phone calls gets an answer in `DemoMac.handle` in the same change. An op
  it does not know is answered at once with "not part of the demo" — acceptable for an edge, not for
  something on the main path.
- A new kind of entry, ask or button is shown at least once in the demo's sample chats when it is
  something a reviewer should be able to try. `home.finished` and `home.summary` are filled from the
  demo's own report cards and running work. The demo shows no system notifications and starts no
  Live Activity: both would reach the real phone.
- Its words live in `DemoText.kt`, in English, Ukrainian and Russian. `DemoTest` walks the path the
  review notes describe (`store/ios/metadata/review_information/notes.txt`); keep the two in step.

## Two things with their own rules

- **Reports reach nothing on the phone.** A report the Mac renders is shown offline: pictures next
  to it are fetched over the link and inlined, everything else the page asks for is blocked, and
  links go through "Leave the report?". A report that needs a script or a picture from the internet
  to make sense will look broken on the phone — keep reports self-contained.
- **A push carries nothing.** The request to the relay is a device token, an environment and which
  of its fixed sentences to show; for the Live Activity, three counts. Never add a title, a project
  or any text to it: the relay is a server outside the director's network, and the phone already
  has the sentences it shows. The Live Activity's attributes stay empty for the same reason.
- **A notification's buttons are the request's own.** They are chosen on the phone from the
  `ActionDTO`s the Mac sent (`NotificationButtons.from`) and pressed with `action.invoke` like any
  other, so a new blocker with an `invoke` button reaches the lock screen by itself. A button with
  a `confirm` never does — a notification cannot ask "are you sure?". On Android every press goes
  through `NotificationAnswerActivity` and `UnlockGate`: nothing reaches the Mac from a locked phone.

## The phone never moves the Mac's screen

Anything the phone does is addressed by id. Do not use `selectedProductID`, `currentChat(for:)`,
`conversationTarget` or `postForemanText` without a chat in code a phone can reach: they mean "the
chat the Mac has open", and the phone's chat may be another one. `sendDirectMessage(_:productID:chatID:entryID:)`
and `ConversationStore.adoptChat(id:for:)` exist for this.

## Before a desktop release

- `./.night-verify.sh` — includes `PhoneLinkTests` (a real TLS server and a client that behaves
  like the phone) and `LinkContractTests`.
- `cd bulava-mobile && ./gradlew :shared:testAndroidHostTest :shared:iosSimulatorArm64Test`, and
  `cd bulava-mobile/push-relay && go test ./...` when the relay changed.
- If the wire changed: the fixtures are committed in the same change, and so is the phone.
- To try it by hand against an emulator or a phone: the harness in `link-protocol/README.md`.

## Before a phone release

- Both builds: `./gradlew :androidApp:assembleRelease` (signed with the release keystore) and the
  iOS archive from `iosApp/iosApp.xcodeproj`.
- The phone must still work with the **current and the previous** Mac release: capabilities it
  needs and an older Mac does not offer must be hidden, not failing (`controller.can`).
