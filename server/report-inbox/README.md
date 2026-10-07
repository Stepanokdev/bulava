# report-inbox

Where Bulava's anonymous error reports land. When a failure stops somebody's message, Bulava tries
to repair it (Codex in that project's folder, then the message is sent again) and reports how that
went — fixed or not — so every failure users meet reaches us and gets fixed once, in a release.

## What a report is

A closed list of fields, written by `Night Shift/Engine/IncidentReport.swift` and checked here
(`Report` in `inbox.go`); a request with any other key is refused.

| field | what |
|---|---|
| `id` | random per incident, for dropping a retried upload |
| `code` | where in Bulava it happened, e.g. `chat.start_failed`, `engine.install_failed` |
| `fingerprint` | the same failure on any Mac, in any language, groups under one value |
| `message` | the error with names, paths, addresses, links, keys and numbers taken out |
| `outcome` | `fixed` (delivery confirmed after the repair) · `unverified` (repaired, delivery not confirmed) · `not_fixed` · `needs_user` · `not_attempted` · `repair_unavailable` |
| `cause`, `product_bug` | the repair's category and, for a defect in Bulava or the engine, its scrubbed description |
| `agent`, `duration_s` | which agent repaired, how long it took |
| `app`, `engine`, `os`, `channel`, `language`, `arch` | versions and machine facts |

No install id, account, project, file, chat text or IP address. The client address is used only
for an in-memory rate limit (20 at once, then one a minute) and never written down; this service
logs no requests. Reports are kept one JSON line each in `data/YYYY-MM-DD.jsonl`, with the arrival
time to the minute, and deleted after `RETENTION_DAYS` (90).

Traefik keeps no access log on this server for it to end up in; if that ever changes, exclude this
router.

## Weekly usage summaries

Once a week a Mac whose owner keeps "Send Bulava's author a weekly summary" on sends one summary
of the week that just ended (`Night Shift/Engine/UsageReport.swift`, checked here as `Usage` in
`usage.go`). Ranges instead of counts, the ISO week instead of dates, yes or no instead of what:

| field | what |
|---|---|
| `id` | random for this one summary, for dropping a retried upload — the next week's has another |
| `week` | the ISO week it describes, `2026-W41` |
| `app`, `os`, `channel`, `language` | versions, production or dev, the interface language |
| `runs`, `agentHours` | ranges: `0`, `1–5`, `6–20`, `21–60`, `60+` runs; `0`, `<5`, `5–20`, `20–40`, `40–80`, `80+` agent-hours |
| `acceptedShare` | the share of finished runs review accepted, in steps of ten; absent with no runs |
| `activeDays` | days with any agent work, 0–7 |
| `nightWork`, `codexReview`, `phone`, `automations` | whether each was used that week |
| `widgets` | which of the week's widgets are on that Mac's desktop |

No install id, account, project, path, chat text, time of day or IP address. Summaries are kept one
JSON line each in `data/usage/YYYY-Www.jsonl`, with the day they arrived, and deleted after
`USAGE_RETENTION_DAYS` (730). `scripts/usage-report.sh` reads them back and adds them up.

## Endpoints

- `POST /v1/reports` — one report. `202` kept, `400/413/415/422` wrong shape (Bulava drops those),
  `429` too many from one client.
- `GET /v1/reports?since=YYYY-MM-DD` with `Authorization: Bearer $REPORTS_ADMIN_TOKEN` — every
  report since that day, one JSON line each. Default: since yesterday.
- `GET /v1/reports/healthz` — `204`.
- `POST /v1/usage` — one weekly summary. `202` kept, `400/413/415/422` wrong shape (Bulava does not
  send that week again), `429` too many from one client.
- `GET /v1/usage?since=YYYY-Www` with the admin token — every summary since that week, one JSON line
  each. Default: the last eight weeks.
- `GET /v1/usage/healthz` — `204`.

## Deploy

On the server, beside the relay:

```sh
mkdir -p /opt/bulava-reports/data && cd /opt/bulava-reports
# copy Dockerfile, docker-compose.yml, go.mod, *.go here
printf 'REPORTS_ADMIN_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env && chmod 600 .env
chown -R 65532:65532 data
docker compose up -d --build
curl -s -o /dev/null -w '%{http_code}\n' https://bulava-push.stepanok.com/v1/reports/healthz   # 204
```

The same token goes into `~/.config/bulava/reports-token` on the Mac that collects the reports
(`scripts/bug-reports.sh`).

## Collecting them

`scripts/bug-reports.sh` pulls a day's reports and groups them by fingerprint — most frequent and
unrepaired first, with the versions they came from and the repair's description of the defect.
