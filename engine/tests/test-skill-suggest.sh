#!/bin/bash
# What a project needs, read off the project — not guessed, not fetched.
#
# «And now let's think about picking skills.»
#
# `detect_stacks` answers "iOS", which picks build commands well and recommends skills badly: an app
# that sells subscriptions and one that does not are the same stack and need different help. These
# are feature signals — evidence in the repo that a kind of work is present.
#
# The split that matters: deciding WHAT is needed is deterministic and happens here; deciding
# WHERE to get it touches the network and stays behind the quarantine pipeline. So `suggest`
# records needs and installs nothing.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_ORCH_HOME="$TMP/orch"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
sug() { bash "$BIN/skill-resolver.sh" suggest "$@" 2>&1; }

# A catalogue that HAS the skills these signals ask for.
#
# It exists in the fixture because a name that cannot be resolved is no longer named: the mapping
# used to print five skills that no catalogue on earth carries, so `suggest` said "not in the index"
# for every project and filed needs nobody could satisfy — eight of them had piled up on the real
# machine. The obtainable path is what this file tests; the unobtainable one is tested at the end.
mkdir -p "$TMP/orch"
cat > "$TMP/orch/skill-index.json" <<'IDX'
{"updated_at":"2026-09-04T00:00:00Z",
 "sources":[{"name":"fixture","repo":"https://example.invalid/skills","fetched_at":"2026-09-04T00:00:00Z"}],
 "skills":[
  {"name":"storekit-subscriptions","description":"","plugin":"","path":"skills/storekit-subscriptions","source":"fixture","repo":"https://example.invalid/skills"},
  {"name":"push-notifications","description":"","plugin":"","path":"skills/push-notifications","source":"fixture","repo":"https://example.invalid/skills"},
  {"name":"localization-workflow","description":"","plugin":"","path":"skills/localization-workflow","source":"fixture","repo":"https://example.invalid/skills"}
 ]}
IDX

echo "===== a signal is only reported when the repo actually says so ====="
mkdir -p "$TMP/plain"; printf 'print("hi")\n' > "$TMP/plain/main.py"
out="$(sug "$TMP/plain")"
case "$out" in *"жодного сигналу"*) ok "a project with no signals suggests nothing" ;;
  *) bad "invented a signal for a plain script: $out" ;; esac

echo "===== the signals that change what the work is ====="
APP="$TMP/app"; mkdir -p "$APP/uk.lproj" "$APP/en.lproj"
printf 'import StoreKit\nlet p = SKProduct()\n' > "$APP/Store.swift"
printf 'UNUserNotificationCenter.current().requestAuthorization()\n' > "$APP/Push.swift"
out="$(sug "$APP")"
case "$out" in *in-app-purchase*)     ok "selling something is seen" ;;      *) bad "StoreKit missed: $out" ;; esac
case "$out" in *push-notifications*)  ok "notifications are seen" ;;         *) bad "push missed: $out" ;; esac
case "$out" in *localization*)        ok "more than one language is seen" ;; *) bad "locales missed: $out" ;; esac
case "$out" in *storekit-subscriptions*) ok "and each maps to a named skill" ;; *) bad "no skill named: $out" ;; esac

echo "===== a dependency tree is not the project ====="
# Run against a real iOS repository, the first version scanned SEVENTY-THREE THOUSAND files and
# reported HealthKit, Stripe and media capture for a meeting recorder. All of it came from
# dependency trees: a Python `.venv` shipping a syntax highlighter whose keyword list names every
# Cocoa framework, and Xcode's `.derivedData` holding a generated RevenueCat header.
DEP="$TMP/withdeps"
mkdir -p "$DEP/src" "$DEP/.venv/lib/python3.12/site-packages/pygments/lexers"          "$DEP/.derivedData/Build/Intermediates.noindex" "$DEP/node_modules/some-pkg"          "$DEP/Pods/RevenueCat"
printf 'let x = 1
'                              > "$DEP/src/App.swift"
printf "COCOA = ['HealthKit', 'StoreKit', 'AVFoundation']
"        > "$DEP/.venv/lib/python3.12/site-packages/pygments/lexers/_cocoa_builtins.py"
printf '#import <HealthKit/HealthKit.h>
PaymentIntent
'        > "$DEP/.derivedData/Build/Intermediates.noindex/RevenueCat-Swift.h"
printf 'import StoreKit
UNUserNotificationCenter
'  > "$DEP/node_modules/some-pkg/index.js"
printf 'import StoreKit
'                            > "$DEP/Pods/RevenueCat/Purchases.swift"
out="$(sug "$DEP")"
case "$out" in *"жодного сигналу"*) ok "nothing in a dependency tree counts as the project's own" ;;
  *) bad "dependencies produced signals: $out" ;; esac

# And the project's OWN code still counts, next to all of that.
printf 'import HealthKit
let s = HKHealthStore()
' > "$DEP/src/Health.swift"
out="$(sug "$DEP")"
case "$out" in *healthkit*) ok "the project's own file is still seen" ;;
  *) bad "pruning went too far: $out" ;; esac
case "$out" in *payments*) bad "a generated header still reads as Stripe" ;;
  *) ok "and the generated header beside it still does not" ;; esac

echo "===== a document that DISCUSSES an API is not a use of it ====="
# The first version also detected itself: this repository's research documents describe StoreKit
# and HealthKit, and the resolver's own source contains the patterns it searches for.
DOC="$TMP/docs"; mkdir -p "$DOC"
printf 'let x = 1
' > "$DOC/App.swift"
printf '# Notes
We considered StoreKit and HealthKit and Stripe.
' > "$DOC/RESEARCH.md"
printf '<p>StoreKit, HealthKit, PaymentIntent</p>
' > "$DOC/report.html"
case "$(sug "$DOC")" in *"жодного сигналу"*) ok "prose about an API is not an API" ;;
  *) bad "a document produced a signal: $(sug "$DOC")" ;; esac

echo "===== a skill already reachable is not asked for again ====="
mkdir -p "$APP/.claude/skills/storekit-subscriptions"
printf -- '---\nname: storekit-subscriptions\n---\n' > "$APP/.claude/skills/storekit-subscriptions/SKILL.md"
out="$(sug "$APP")"
case "$out" in *"storekit-subscriptions (вже є)"*) ok "an installed skill reads as present" ;;
  *) bad "project-local install not noticed: $out" ;; esac
case "$out" in *"storekit-subscriptions (бракує)"*) bad "still asked for a skill that is installed" ;;
  *) ok "and is not asked for" ;; esac

echo "===== recording goes to the quarantine channel, and nothing is fetched ====="
sug "$APP" --record >/dev/null
needs="$TMP/orch/skill-needs"
[ -f "$needs/push-notifications.need" ] && ok "a missing skill is filed as a need" \
  || bad "nothing filed in $needs"
[ -f "$needs/storekit-subscriptions.need" ] && bad "filed a need for an installed skill" \
  || ok "an installed skill is never filed"
before=$(ls -1 "$needs" | wc -l | tr -d ' ')
sug "$APP" --record >/dev/null
after=$(ls -1 "$needs" | wc -l | tr -d ' ')
[ "$before" = "$after" ] && ok "recording twice queues once — the channel is a set, not a log" \
  || bad "duplicated needs: $before → $after"
# The standing rule: the resolver's quarantine is the single point that touches the network.
[ -d "$TMP/orch/skill-quarantine" ] && [ -n "$(ls -A "$TMP/orch/skill-quarantine" 2>/dev/null)" ] \
  && bad "suggest fetched something" || ok "suggest fetched nothing"

echo "===== and it survives the text it prints ====="
# `«$f»` read as the variable name `f»` and died with "unbound variable" the first time this ran.
case "$(cat "$needs/push-notifications.need")" in
  *"push-notifications"*) ok "the need line is written whole" ;;
  *) bad "the need line is mangled: $(cat "$needs/push-notifications.need")" ;; esac
case "$(sug "$APP" --record)" in *"unbound variable"*) bad "still breaks on the quoted feature name" ;;
  *) ok "no shell error in the recorded path" ;; esac

echo "===== a signal with no obtainable skill is SAID, not filed ====="
# The bug this closes: the mapping named skills no catalogue carries, so every project printed
# "not in the index" and filed a need that nothing could ever pick up. A signal must still be
# reported — it is real — but as a sentence for a person, not as a queued download.
BARE="$TMP/bare-index"; mkdir -p "$BARE/orch"
printf '%s' '{"updated_at":"x","sources":[],"skills":[]}' > "$BARE/orch/skill-index.json"
out="$(SUPERVISOR_ORCH_HOME="$BARE/orch" sug "$APP" --record)"
case "$out" in *"скіла в каталозі немає"*) ok "the signal is reported in words" ;;
  *) bad "a signal vanished in silence: $out" ;; esac
case "$out" in *"в індексі немає"*) bad "still offers a skill it cannot get: $out" ;;
  *) ok "and no unobtainable skill is offered" ;; esac
if [ -d "$BARE/orch/skill-needs" ] && [ -n "$(ls -A "$BARE/orch/skill-needs" 2>/dev/null)" ]; then
  bad "filed a need nobody can satisfy: $(ls -1 "$BARE/orch/skill-needs" | tr '\n' ' ')"
else
  ok "nothing is queued that cannot be fetched"
fi

echo
if [ "$fails" -eq 0 ]; then echo "✅ needs are read off the project and filed, never fetched"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
