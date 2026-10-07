#!/bin/bash
# The live inbox answers as it should, without writing anything: it is up, it refuses a report with
# a field outside the list, it refuses an unauthenticated read, and the push relay it shares a host
# with still answers on its own route. The same for the weekly usage summaries beside it — a real
# summary is never sent from here, so the owner's figures hold only what Macs sent.
#
#   bash server/report-inbox/check-live.sh [base-url]
#
# The refused body is sent from a file. Written inline inside a quoted command substitution, the
# shell read `{"v":1,"project":"x"}` as a brace expansion and sent two requests with broken halves.
set -u
U="${1:-https://bulava-push.stepanok.com}"
fails=0
code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@"; }
expect() {  # $1 = what, $2 = wanted code, $3 = got
  if [ "$3" = "$2" ]; then printf '  ✅ %s (%s)\n' "$1" "$3"
  else printf '  ❌ %s: wanted %s, got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
BODY="$(mktemp)"; trap 'rm -f "$BODY"' EXIT
printf '%s' '{"v":1,"project":"x"}' > "$BODY"

expect "the inbox is up"                          204 "$(code "$U/v1/reports/healthz")"
expect "a field outside the list is refused"      400 "$(code -H 'Content-Type: application/json' --data-binary "@$BODY" "$U/v1/reports")"
expect "reading without the token is refused"     401 "$(code "$U/v1/reports")"
expect "the push relay still answers beside it"   204 "$(code "$U/healthz")"
expect "the usage summaries are taken"            204 "$(code "$U/v1/usage/healthz")"
expect "a summary with a field outside the list is refused" 400 "$(code -H 'Content-Type: application/json' --data-binary "@$BODY" "$U/v1/usage")"
expect "reading summaries without the token is refused"     401 "$(code "$U/v1/usage")"
[ "$fails" = 0 ]
