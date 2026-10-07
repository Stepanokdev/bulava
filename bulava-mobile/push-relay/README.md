# push-relay

Reaches an iPhone that has Bulava installed while its app is closed. The Mac posts a device token
here when something starts waiting for the director, a report comes in, or a chat's answer is in,
and this service sends Apple a push that always says one of three fixed things — "Your Mac is
waiting for your answer", "A task is done. Its report is ready to read", "The work is done. The
answer is in the chat" — in the phone's language. It also keeps the iPhone's Live Activity in step:
what is running and how it ended, on the Lock Screen.

It exists only because iOS lets nothing but Apple's push service reach an app that is not running,
and Apple accepts pushes only from a holder of Bulava's APNs key. That key cannot ship inside the
Mac app, so it lives here.

## What it sees

- In: `POST /v1/notify` with `{"token": "<hex>", "environment": "development" | "production",
  "kind": "attention" | "finished" | "done", "sealed": "<base64>"}` (`kind` may be left out; it
  means `attention`; `sealed` is optional). `sealed` is an AES-GCM box the Mac made with a key only
  the phone and the Mac hold — which chat a tap should open. It is passed on as it came, and this
  service cannot read it.
- Out: to APNs, `{"aps":{"alert":{"title-loc-key":"PUSH_TITLE","loc-key":…},"sound":"default","thread-id":…},"sealed":…}`,
  one collapse id per kind, so several requests in a row are one banner: `PUSH_BODY` for attention,
  `PUSH_BODY_DONE` for a report, `PUSH_BODY_REPLIED` for a chat's answer. Every kind is heard: a
  finished piece of work is what the director is waiting for.
- In: `POST /v1/activity` with `{"token", "environment", "event": "start" | "update" | "end",
  "state": {"working", "waiting", "ready", "sealed"}}` — three counts, 0 to 9999, and optionally the
  names of the work sealed the same way (at most 3000 characters of base64).
- Out: an ActivityKit push (`apns-push-type: liveactivity`, topic `<bundle>.push-type.liveactivity`)
  with the state as the content state and the time it was read. A start names the app's
  `ShiftAttributes` with empty attributes and a fixed alert (`LIVE_START_TITLE`, `LIVE_START_BODY`)
  and asks for the new activity's update token; updates go at priority 5 and go stale 25 minutes
  on; an end leaves the activity on the Lock Screen for an hour. A push over Apple's 4 KB is
  refused with `413` before it is sent.
- `GET /v1/features` answers `{"kinds": [...], "sealed": true}`: what it takes beyond the first
  version. The Mac asks before sending a newer kind or a sealed box; an older relay answers `404`
  and is sent only counts and the first two kinds.
- It keeps nothing: no database, no log of tokens. One token is woken at most once every 30 s per
  kind; a Live Activity is started at most once a minute and updated at most once every 5 s
  (`429` otherwise). A token APNs no longer knows is answered `410`, and the Mac forgets it.

## Running it

```sh
docker build -t bulava-push-relay .
docker run -p 8080:8080 \
  -e APNS_KEY_FILE=/keys/AuthKey.p8 -e APNS_KEY_ID=<key id> -e APNS_TEAM_ID=KHU94Q2JSS \
  -e APNS_TOPIC=com.stepanok.bulava -v /secure/keys:/keys:ro bulava-push-relay
```

It must be reachable over HTTPS (put it behind the host's TLS). `GET /healthz` answers `204`.
The Mac uses `https://bulava-push.stepanok.com` unless told otherwise:
`defaults write stepanok.com.Night-Shift BulavaPushRelayURL https://…` points it at another relay,
and `off` turns pushes off.

## Tests

```sh
go test ./...
```

They run against a stand-in APNs and check the provider token, every payload, the sealed boxes
passed on unread, the Live Activity push, the rate limits and the `410` path.
