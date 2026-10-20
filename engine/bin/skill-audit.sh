#!/bin/bash
set -u
DIR="${1:?usage: skill-audit.sh <skill-dir>}"
[ -d "$DIR" ] || { echo '{"verdict":"REJECT","findings":[{"category":"missing","severity":"CRITICAL","detail":"skill dir not found"}]}'; exit 1; }

FINDINGS=""
# Every finding names the first file that tripped it. Without the file, "curl|bash" in a catalogue's
# documentation and "curl|bash" in the skill's own installer read the same: the frontend-design
# alarm of 8 Oct listed nine critical findings and not one of them was in frontend-design.
add(){ FINDINGS="${FINDINGS:+$FINDINGS,}$(jq -n --arg c "$1" --arg s "$2" --arg d "$3" --arg f "${4:-}" \
  '{category:$c,severity:$s,detail:$d} + (if $f != "" then {file:$f} else {} end)')"; }
HIT_FILE=""
hit(){ local f; f="$(grep -rEIil --exclude-dir=.git -- "$1" "$DIR" 2>/dev/null | LC_ALL=C sort | head -1)"
       [ -n "$f" ] || return 1; HIT_FILE="${f#"$DIR"/}"; }

hit '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|python3?|node|ruby|perl)\b' && add C1-rce CRITICAL "curl|bash-style remote code execution" "$HIT_FILE"
hit '\|[[:space:]]*(bash|sh)[[:space:]]+-s\b' && add C1-rce CRITICAL "pipe to shell -s" "$HIT_FILE"
hit '\.ssh/|id_rsa|id_ed25519|\.aws/(credentials|config)|\.netrc|(^|/)\.npmrc|(^|/)\.pypirc|dump-keychain|\.(bash|zsh)_history' && add C2-secret CRITICAL "reads secrets/credentials" "$HIT_FILE"
hit 'ANTHROPIC_API_KEY|OPENAI_API_KEY|GITHUB_TOKEN|AWS_SECRET|printenv|process\.env|os\.environ|\$\{?[A-Z_]*(TOKEN|SECRET|KEY|PASSWORD)' && add C2-env HIGH "harvests environment secrets" "$HIT_FILE"
hit 'rm[[:space:]]+-[rf]{1,2}[[:space:]]+(/|~|\$HOME|\*)|mkfs|dd[[:space:]]+if=|:\(\)\{[[:space:]]*:\|:&|>[[:space:]]*/dev/sd' && add C3-destructive CRITICAL "destructive filesystem command" "$HIT_FILE"
hit 'base64[[:space:]]+(-d|-D|--decode)|\|[[:space:]]*base64|atob\(|\beval\b|new[[:space:]]+Function|child_process|subprocess|os\.system|execSync|spawn\(' && add C4-obfusc CRITICAL "obfuscation / dynamic code execution" "$HIT_FILE"
hit 'ignore[[:space:]]+(all[[:space:]]+)?(previous|prior|above)[[:space:]]+(instructions|prompts)|disregard[[:space:]]+.*(instructions|rules)|do[[:space:]]+not[[:space:]]+(tell|inform|mention|alert)[[:space:]]+.*(user|human|reviewer|auditor)|you[[:space:]]+are[[:space:]]+now|new[[:space:]]+instructions|system[[:space:]]+prompt|jailbreak|bypass[[:space:]]+permissions' && add C5-injection CRITICAL "prompt-injection / hidden instructions" "$HIT_FILE"
# A byte-order mark opening a file is how the file says its encoding, not text anyone could hide
# an instruction in: every ECMA Office schema starts with one. A binary file is not read as text
# here at all — a font's bytes decode into "zero-width characters" by chance — and has its own
# finding below.
hidden="$(find "$DIR" -type f -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
     grep -Iq . "$f" 2>/dev/null || continue
     perl -CSD -ne 's/\A\x{feff}// if $. == 1; exit 1 if /[\x{200b}\x{200c}\x{200d}\x{feff}\x{202e}\x{2066}-\x{2069}]/' "$f" 2>/dev/null \
       || { printf '%s' "${f#"$DIR"/}"; break; }
   done)"
[ -n "$hidden" ] && add C5-hidden CRITICAL "zero-width / bidi hidden characters" "$hidden"
hit '\b(npx|npm[[:space:]]+install|pip[[:space:]]+install|gem[[:space:]]+install|brew[[:space:]]+install|go[[:space:]]+install|cargo[[:space:]]+install)\b|git[[:space:]]+clone|/dev/tcp/|urllib|requests\.|http\.client|XMLHttpRequest|net\.Socket' && add C6-installer HIGH "installer / outbound network in scripts" "$HIT_FILE"
hit 'allowed-tools:.*(Bash\(\*\)|"\*")|--dangerously|bypassPermissions' && add C7-perms HIGH "over-broad tool permissions" "$HIT_FILE"

bin_hit=""
while IFS= read -r f; do
  case "$f" in *.png|*.jpg|*.jpeg|*.gif|*.webp|*.svg|*.ico) continue;; esac  # benign images ok
  file --mime "$f" 2>/dev/null | grep -qiE 'charset=binary' && { bin_hit="${f#"$DIR"/}"; break; }
done < <(find "$DIR" -type f -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort)
[ -n "$bin_hit" ] && add C8-binary HIGH "opaque binary file present" "$bin_hit"

has_script=false
find "$DIR" -type f \( -name '*.sh' -o -name '*.mjs' -o -name '*.js' -o -name '*.py' -o -name '*.rb' -o -name '*.command' -o -name 'Makefile' -o -iname 'install*' -o -iname 'setup*' \) -not -path '*/.git/*' 2>/dev/null | grep -q . && has_script=true

verdict="PASS"; rc=0
crit_high="$(printf '[%s]' "$FINDINGS" | jq '[.[]|select(.severity=="CRITICAL" or .severity=="HIGH")]|length' 2>/dev/null || echo 0)"
if [ "${crit_high:-0}" -gt 0 ]; then verdict="REJECT"; rc=1
elif [ "$has_script" = true ] || [ -n "$FINDINGS" ]; then verdict="PROPOSE"; rc=2; fi

jq -n --arg v "$verdict" --argjson hs "$has_script" --argjson f "[${FINDINGS}]" \
  '{verdict:$v, has_script:$hs, findings:$f}'
exit $rc
