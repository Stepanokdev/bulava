#!/bin/bash
# Everything that must be true of the pages, in one command.
#
#   site/analytics/check-site.sh
#
# One script rather than a dozen registered checks, because the run's evidence file holds ten and
# the page grew past that: four pages now (two languages × the landing page and the history of the
# arrangements), and each of them owes the same set of promises — down to the three gameplay clips,
# which are opened in a real browser here and watched until their clocks move. Exits non-zero on the first thing
# that is not true, and says which.
#
# It renders into a temporary directory and never touches the tracked pages: a check that rewrites
# what it is checking has no business reporting on it.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.7.13}"
BYTES="${2:-10854107}"
MINOS="${3:-15.6}"
PAGES="index.html pipeline/index.html uk/index.html uk/pipeline/index.html"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "===== the pages build at all ====="
if out="$(python3 site/render.py "$VERSION" "$BYTES" "$TMP" "$MINOS" 2>&1)"; then
  ok "$out"
else
  bad "the render refused:"; printf '     %s\n' "$out"
  echo; echo "❌ site: $fails problem(s)"; exit "$fails"
fi
for p in $PAGES; do
  [ -s "$TMP/$p" ] || bad "$p was not produced"
done

echo
echo "===== every page hands over the download, and says which release ====="
for p in $PAGES; do
  if out="$(python3 site/analytics/page-contract.py "$TMP/$p" "$VERSION" 2>&1)"; then
    ok "$p — $out"
  else
    bad "$p:"; printf '     %s\n' "$out"
  fi
done

echo
echo "===== neither language is half a page ====="
for pair in ":landing" "pipeline:history"; do
  route="${pair%%:*}"; what="${pair##*:}"
  if out="$(python3 site/analytics/check-languages.py "$TMP/${route:+$route/}index.html" \
              "$TMP/uk/${route:+$route/}index.html" "$route" 2>&1)"; then
    ok "$what — $out"
  else
    bad "$what:"; printf '     %s\n' "$out"
  fi
done

echo
echo "===== the benchmark on the page is the measured one ====="
if out="$(python3 site/analytics/check-benchmark.py "$TMP/index.html" "$TMP/uk/index.html" 2>&1)"; then
  ok "$out"
else
  bad "the figures do not match site/benchmark.json:"; printf '     %s\n' "$out"
fi
if out="$(python3 site/analytics/check-evidence.py --offline 2>&1)"; then
  ok "$out"
else
  bad "the manifests do not fold to their published digests:"; printf '     %s\n' "$out"
fi

echo
echo "===== the task is published whole, not summarised ====="
# The benchmark argues from one prompt, so the page has to carry that prompt. It used to carry
# four paraphrased bullets, which is a description of a prompt and not the thing itself.
if python3 - "$TMP" <<'PY'
import hashlib, html, json, os, sys
tmp = sys.argv[1]
strings = json.load(open("site/strings.json", encoding="utf-8"))
problems = []
for lang, path in (("en", "index.html"), ("uk", "uk/index.html")):
    text = strings[lang]["bm.prompt.full"]
    if len(text) < 500:
        problems.append(f"{lang}: the published prompt is {len(text)} characters — too short to be the task")
    page = open(os.path.join(tmp, path), encoding="utf-8").read()
    if text not in page and html.escape(text, quote=False) not in page:
        problems.append(f"{lang}: the page does not carry the prompt verbatim")

# …and the text on the page is the one whose digest it publishes, and every exact text published
# beside it hashes to the digest printed with it. The page says the three runs were handed texts
# that differ from it; that sentence is only worth reading if the texts are here to be compared.
bench = json.load(open("site/benchmark.json", encoding="utf-8"))
prompt = bench.get("prompt")
if not prompt:
    problems.append("site/benchmark.json publishes no prompt block — the page's claim about the"
                    " three texts has nothing behind it")
else:
    shown = strings["uk"]["bm.prompt.full"].strip()
    want = prompt["shown_on_page"]["sha256"]
    got = hashlib.sha256(shown.encode()).hexdigest()
    if got != want:
        problems.append(f"the text on the page hashes to {got[:12]}, but benchmark.json"
                        f" publishes {want[:12]} for it")
    if prompt["shown_on_page"]["chars"] != len(shown):
        problems.append("benchmark.json states the wrong length for the text on the page")
    keys = {sc["key"] for sc in bench["scenarios"]}
    for run in prompt["given_to_runs"]:
        got = hashlib.sha256(run["text"].encode()).hexdigest()
        if got != run["sha256"]:
            problems.append(f"{run['key']}: the published prompt hashes to {got[:12]},"
                            f" not the {run['sha256'][:12]} printed with it")
        if run["chars"] != len(run["text"]):
            problems.append(f"{run['key']}: the published length is not the text's length")
        keys.discard(run["key"])
    if keys:
        problems.append("no prompt published for: " + ", ".join(sorted(keys)))
    # And the stated difference for the first run is the WHOLE difference: its text is the page's
    # text plus one sentence, with nothing else moved.
    first = next((r for r in prompt["given_to_runs"] if r["key"] == "pure"), None)
    if first and not first["text"].startswith(shown):
        problems.append("pure: its published prompt is not the page's text plus a line — the"
                        " difference is bigger than the page admits")
print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
then ok "both languages carry the whole task word for word, and every published text matches its digest"
else bad "the prompt on the page is not the whole task, or a published text does not match its digest"
fi

echo
echo "===== the three results are shown being played, and the clips run ====="
if out="$(python3 site/analytics/check-video.py "$TMP" 2>&1)"; then
  ok "$out"
else
  bad "the gameplay clips do not play:"; printf '     %s\n' "$out"
fi

echo
echo "===== the application captures carry no invented frame ====="
if grep -qE 'class="(tray|stage|core)' site/index.template.html; then
  bad "a plate or a frame is back around the screenshots"
else
  grep -q 'class="shot' site/index.template.html \
    && ok "frameless: the captures stand on the page's own background" \
    || bad "the screenshots are not marked up as frameless captures"
fi

echo
[ "$fails" = 0 ] && echo "✅ site: four pages, two languages, and every claim on them checked" \
                 || echo "❌ site: $fails problem(s)"
exit "$fails"
