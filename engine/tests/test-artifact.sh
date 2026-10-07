#!/bin/bash
# The artefact: one folder in the project, openable without anything else.
#
# The director asked for this by name — the work and its screenshots in `artifacts/`, git-ignored,
# buildable from the console as well as from the app. So this checks the properties that make it worth
# having: it answers his items in his numbers, the frames travel with it, nothing points at a file that
# is not there, git does not see it, and building twice does not corrupt the first one.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d -t artifact-test)" || exit 1
trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/proj"; REPORT="$TMP/report"
mkdir -p "$PROJ" "$REPORT"
git -C "$PROJ" init -q . 2>/dev/null
printf 'build/\n' > "$PROJ/.gitignore"

# A tiny valid PNG, so an <img> points at something real.
python3 - "$REPORT" <<'PY'
import base64, os, sys
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")
for n in ("before-1.png", "after-1.png"):
    open(os.path.join(sys.argv[1], n), "wb").write(png)
open(os.path.join(sys.argv[1], "notes.log"), "w").write("a log that travels along\n")
open(os.path.join(sys.argv[1], "report.json.bak"), "w").write("{}")
PY

cat > "$REPORT/report.json" <<'JSON'
{"format":"photos","language":"Ukrainian","title":"Директорський фідбек",
 "summary":"Коротко про зміну.",
 "attention":["Потрібен ASC-ключ, щоб побачити ціни"],
 "sections":[
   {"ref":"5","title":"PDF і Word","status":"закрито",
    "body":"**Вирівнювання по ширині** зроблено (`w:jc`).\n\n| Магазин | Ціна |\n|---|---|\n| Play | 390 |",
    "items":[{"caption":"пункт 5","before":"before-1.png","after":"after-1.png"}]},
   {"ref":"10","title":"Синхронізація","status":"заблоковано","body":"Роут віддає 404."},
   {"ref":"11","title":"Ціни","status":"хтозна","body":"Незрозумілий статус."}],
 "body":"## Як перевіряли\n\n7. Сьомий пункт лишається сьомим.",
 "items":[{"caption":"кадр, що не належить пункту","after":"missing-file.png"}]}
JSON

out="$("$BIN_DIR/artifact.sh" "$REPORT" "$PROJ" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the artefact builds" || { bad "artifact.sh failed: $out"; echo "$out"; }
index="$(printf '%s' "$out" | sed -n 's/^✅ артефакт: //p' | head -1)"
[ -f "$index" ] && ok "index.html is where it said" || bad "no index.html at [$index]"
DIR="$(dirname "$index")"

echo
echo "===== it answers HIS items, with his numbers and a visible verdict ====="
for want in '>5. PDF і Word<' '>10. Синхронізація<' 'answer closed' 'answer blocked'; do
  grep -q -- "$want" "$index" && ok "$want" || bad "missing: $want"
done
grep -q 'answer unknown' "$index" && ok "an unrecognised status stays «без вердикту»" \
  || bad "a status nobody understood was given a verdict"
grep -q 'Без вердикту' "$index" && ok "and it says so in words" || bad "the unknown verdict has no label"

echo
echo "===== the document renders, not the markup ====="
grep -q '<strong>Вирівнювання по ширині</strong>' "$index" && ok "bold" || bad "bold markers left on the page"
grep -q '<code>w:jc</code>' "$index" && ok "inline code" || bad "code markers left on the page"
grep -q '<table class="doc">' "$index" && ok "a table is a table" || bad "the table came out as prose"
grep -q '<ol start="7">' "$index" && ok "a numbered item keeps its number" || bad "the list restarted at 1"
grep -q 'class="attn"' "$index" && ok "what needs him is on the page" || bad "the attention block is missing"

echo
echo "===== it opens with the logo, and speaks the report's language ====="
grep -q '<a class="brand" href="https://bulava.app">' "$index" && ok "bulava.app and its mark at the top, a link" \
  || bad "no lockup at the top of the artefact"
grep -q '<span class="plate"><svg' "$index" && ok "the mark is drawn, not named" || bad "the lockup has no mark"
grep -q '<html lang="uk">' "$index" && ok "a Ukrainian report is marked Ukrainian" || bad "wrong lang on a Ukrainian report"
grep -q '>Було<' "$index" && ok "and its frames say Було / Стало" || bad "the Ukrainian frame labels are gone"

one_language() {   # $1=name $2=manifest → prints the index path
  mkdir -p "$TMP/$1"; cp "$REPORT/after-1.png" "$REPORT/before-1.png" "$TMP/$1/"
  printf '%s' "$2" > "$TMP/$1/report.json"
  python3 "$BIN_DIR/artifact.py" "$TMP/$1" "$TMP/$1-out"
}
en="$(one_language en '{"language":"Ukrainian","title":"Export fix","summary":"The export button waits for the transcript.",
  "attention":["Pick the release date"],
  "sections":[{"ref":"1","title":"Export","status":"done","body":"It works.",
               "items":[{"caption":"one frame","after":"after-1.png"}]}]}')"
grep -q '<html lang="en">' "$en" && ok "written in English, marked English — whatever the setting said" \
  || bad "an English report was marked as another language"
for want in '>After<' '>Closed<' '>Needs your decision<' 'Work finished'; do
  grep -q -- "$want" "$en" && ok "English: $want" || bad "English report is missing: $want"
done
grep -q 'Було\|Стало\|Закрито\|Потребує' "$en" && bad "Ukrainian words around an English report" \
  || ok "no Ukrainian words around an English report"
grep -q 'class="pair one"' "$en" && ok "a frame on its own is laid out alone" || bad "a single frame was not marked as one"
grep -q '\.pair\.one \.shot img { width:auto; max-width:100%; max-height:' "$en" \
  && ok "and it is never taller than the view" || bad "a single frame can still stand two windows tall"

ru="$(one_language ru '{"title":"Экспорт","summary":"Кнопка ждёт расшифровку, это было неочевидно.",
  "sections":[{"ref":"2","title":"Экспорт","status":"закрыто","body":"Работает.",
               "items":[{"before":"before-1.png","after":"after-1.png"}]}]}')"
grep -q '<html lang="ru">' "$ru" && ok "written in Russian, marked Russian" || bad "a Russian report was marked as another language"
grep -q 'answer closed' "$ru" && grep -q '>Закрыто<' "$ru" && ok "«закрыто» is read as closed, and said in Russian" \
  || bad "a Russian status was not understood"
grep -q '>Было<' "$ru" && ok "Russian: Было / Стало" || bad "the Russian frame labels are missing"

echo
echo "===== it stands alone ====="
for asset in before-1.png after-1.png notes.log; do
  [ -f "$DIR/$asset" ] && ok "$asset travelled with it" || bad "$asset was left behind"
done
[ -f "$DIR/report.json.bak" ] && bad "a stray backup was copied in" || ok "workshop leftovers stayed behind"
grep -q 'missing-file.png' "$index" && bad "renders an <img> for a file that does not exist" \
  || ok "a named-but-missing frame renders nothing"
if grep -oE '(src|href)="[^"]+"' "$index" | grep -v 'https\?://' | sed 's/.*="//; s/"//' \
   | while read -r ref; do [ -f "$DIR/$ref" ] || { echo "$ref"; }; done | grep -q .; then
  bad "the page points at something that is not in the folder"
else
  ok "every local reference resolves inside the folder"
fi
grep -q '<link' "$index" && bad "an external stylesheet — it would not open offline" \
  || ok "the stylesheet is inlined"

echo
echo "===== git does not see it ====="
git -C "$PROJ" check-ignore -q artifacts/x && ok "artifacts/ is ignored" || bad "artifacts/ is not ignored"
grep -q '^build/$' "$PROJ/.gitignore" && ok "and the existing .gitignore was kept" \
  || bad "the project's own .gitignore was clobbered"
[ "$(git -C "$PROJ" status --porcelain | grep -c 'artifacts')" = 0 ] \
  && ok "git status stays clean of it" || bad "the artefact shows up as untracked"

echo
echo "===== twice is safe, and .gitignore gains one line, not two ====="
"$BIN_DIR/artifact.sh" "$REPORT" "$PROJ" >/dev/null 2>&1
n="$(grep -c '^artifacts/$' "$PROJ/.gitignore")"
[ "$n" = 1 ] && ok "the ignore rule is written once" || bad "artifacts/ appears $n times in .gitignore"
[ -L "$PROJ/artifacts/latest" ] && ok "artifacts/latest points at the newest" || bad "no latest pointer"
[ -f "$PROJ/artifacts/latest/index.html" ] && ok "and it resolves" || bad "latest does not resolve"

echo
echo "===== a run with no manifest is refused, not faked ====="
mkdir -p "$TMP/empty"
if "$BIN_DIR/artifact.sh" "$TMP/empty" "$PROJ" >/dev/null 2>&1; then
  bad "it built an artefact out of nothing"
else
  ok "no manifest, no artefact"
fi

echo
[ "$fails" = 0 ] && echo "✅ artifact: one folder, openable, ignored by git" || echo "❌ $fails problem(s)"
exit "$fails"
