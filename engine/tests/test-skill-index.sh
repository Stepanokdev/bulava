#!/bin/bash
# The index says what exists in the world. It grants nothing.
#
# «Give me a link to this skills marketplace… and think through what to do about updates.»
#
# One file is fetched per allowed source: `.claude-plugin/marketplace.json`. It is DATA — names
# and descriptions to match a need against — and it never reaches an agent as text to act on,
# which is the whole prompt-injection surface this avoids. Installing a skill still goes through
# fetch → quarantine → static audit → agent review; being in the index is not a step towards that,
# it is only knowledge that the thing exists.
#
# No suite may depend on the network, so the fetch is stubbed. What is tested is the allowlist,
# the caching, the parsing of manifests that differ, and the refusal to damage a good cache.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_ORCH_HOME="$TMP/orch"; mkdir -p "$TMP/orch"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$TMP/state"
INDEX="$TMP/orch/skill-index.json"

# A manifest that lists a plugin's skills, and one that lists only the plugin.
# All THREE shapes that real catalogues use. The third — skills as bare path strings — was found
# only by running the index against the live catalogues: jq errors on `.name` applied to a string,
# which silently emptied that entire source and reported success.
cat > "$TMP/good.json" <<'J'
{"name":"m","plugins":[
 {"name":"ios-pack","description":"iOS helpers","skills":[
   {"name":"storekit-subscriptions","description":"StoreKit 2 end to end","source":"./skills/storekit"},
   {"name":"push-notifications","description":"APNs"}]},
 {"name":"doc-pack","description":"paths, not objects","skills":["./skills/xlsx","./skills/pdf"]},
 {"name":"bare-plugin","description":"lists no skills"}]}
J
printf 'not json at all\n' > "$TMP/bad.json"
cat > "$TMP/fetch.sh" <<'F'
#!/bin/bash
case "$1" in
  *good*) cat "$MFIX/good.json" ;;
  *bad*)  cat "$MFIX/bad.json" ;;
  *)      exit 1 ;;      # everything else — including the shipped official sources — is offline
esac
F
chmod +x "$TMP/fetch.sh"
export MFIX="$TMP" SUPERVISOR_SKILL_FETCH_CMD="$TMP/fetch.sh"
src() { printf '{"sources":[%s]}\n' "$1" > "$TMP/orch/skill-sources.json"; }
GOOD='{"name":"good-market","repo":"https://example.invalid/good","manifest":"https://example.invalid/good.json"}'
BAD='{"name":"bad-market","repo":"https://example.invalid/bad","manifest":"https://example.invalid/bad.json"}'
idx() { bash "$BIN/skill-resolver.sh" index "$@" 2>&1; }

echo "===== a manifest becomes rows, whatever shape it is in ====="
src "$GOOD"; idx --refresh >/dev/null
jq -e '.skills | length == 5' "$INDEX" >/dev/null 2>&1 \
  && ok "object skills, path-string skills, and the plugin that lists none" \
  || bad "wrong row count: $(jq -c '[.skills[].name]' "$INDEX")"
jq -e '[.skills[].name] | index("xlsx")' "$INDEX" >/dev/null 2>&1 \
  && ok "a skill listed as a bare path is named by its last segment" \
  || bad "the path-string shape was dropped — this is how a whole catalogue goes silently empty"
# WHERE inside the repo, when the manifest says. Without it the installer knows only the
# catalogue, and a catalogue is a monorepo of many skills.
jq -e '[.skills[] | select(.name == "xlsx")][0].path == "skills/xlsx"' "$INDEX" >/dev/null 2>&1 \
  && ok "and its path inside the repository is kept" || bad "the in-repo path was discarded"
jq -e '[.skills[] | select(.name == "push-notifications")][0].path == ""' "$INDEX" >/dev/null 2>&1 \
  && ok "an entry whose manifest gives no path claims none" \
  || bad "invented a path the manifest never stated"
jq -e '[.skills[].name] | index("storekit-subscriptions")' "$INDEX" >/dev/null 2>&1 \
  && ok "a named skill is indexed" || bad "skill missing"
jq -e '.sources | type == "array" and length == 1' "$INDEX" >/dev/null 2>&1 \
  && ok "the sources it actually reached are recorded as a list" \
  || bad "sources is not a list: $(jq -c '.sources' "$INDEX")"
jq -e '.skills[] | select(.repo != "" and .source != "")' "$INDEX" >/dev/null 2>&1 \
  && ok "every row carries where it came from" || bad "provenance missing from rows"

echo "===== the allowlist is the whole boundary ====="
# The stub refuses anything but good/bad, so an unlisted host cannot appear by any path.
jq -e '[.skills[].source] | unique == ["good-market"]' "$INDEX" >/dev/null 2>&1 \
  && ok "nothing outside the allowed source got in" || bad "an unlisted source appeared"
shipped="$(cd "$BIN/../supervisor" && pwd)/skill-sources.json"
if jq -e '[.sources[].manifest] | all(startswith("https://"))' "$shipped" >/dev/null 2>&1; then
  ok "every shipped source is fetched over https"
else bad "a shipped source is not https"; fi
if jq -e '[.sources[].manifest] | all(endswith("/.claude-plugin/marketplace.json"))' "$shipped" >/dev/null 2>&1; then
  ok "and only the manifest file, never a clone"
else bad "a shipped source points at something other than a manifest"; fi

echo "===== updates: fresh is left alone, stale is refetched ====="
out="$(idx)"
case "$out" in *"свіжий"*) ok "a fresh cache is not refetched" ;; *) bad "refetched a fresh cache: $out" ;; esac
before="$(jq -r '.updated_at' "$INDEX")"
sleep 1
SUPERVISOR_SKILL_INDEX_TTL=0 idx >/dev/null
[ "$(jq -r '.updated_at' "$INDEX")" != "$before" ] && ok "an expired cache is refetched" \
  || bad "a stale cache was kept"
out="$(idx --refresh)"
case "$out" in *"good-market"*) ok "--refresh forces it regardless of age" ;; *) bad "--refresh did nothing: $out" ;; esac

echo "===== a bad day must not damage a good index ====="
src "$BAD"
out="$(idx --refresh 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "a source that answers with nonsense fails loudly" || bad "unparseable manifest reported success"
jq -e '.skills | length == 5' "$INDEX" >/dev/null 2>&1 \
  && ok "and the previous good cache survives untouched" || bad "the good cache was overwritten by a failure"

echo "===== a need learns its candidate, and still installs nothing ====="
src "$GOOD"; idx --refresh >/dev/null
APP="$TMP/app"; mkdir -p "$APP"; printf 'import StoreKit\n' > "$APP/S.swift"
out="$(bash "$BIN/skill-resolver.sh" suggest "$APP" --record 2>&1)"
case "$out" in *"є в індексі"*) ok "a missing skill is matched to an allowed source" ;;
  *) bad "no candidate offered: $out" ;; esac
need="$TMP/orch/skill-needs/storekit-subscriptions.need"
# The need is structured so `resolve` can act on it without re-deriving anything, and it carries
# the EXACT source: the repository plus the path inside it, because a catalogue is a monorepo.
if jq -e '.skill == "storekit-subscriptions" and .repo != "" and .path != ""' "$need" >/dev/null 2>&1; then
  ok "the candidate is carried into the need, as an exact address"
else bad "the need does not name a candidate: $(cat "$need" 2>/dev/null)"; fi
[ -n "$(ls -A "$TMP/orch/skill-quarantine" 2>/dev/null)" ] && bad "something was fetched into quarantine" \
  || ok "and nothing was fetched or installed"

echo
if [ "$fails" -eq 0 ]; then echo "✅ the index knows what exists and grants nothing"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
