#!/bin/bash
# A report is the document the WORK needs, not one fixed shape.
#
# Every report used to be the same: a paragraph, then a "Before & after" pane whether or not anything
# visual existed — so a backend change or a piece of research was presented with two "not captured"
# placeholders and read as a failure to take screenshots. The writer now composes a document from
# blocks, and the renderer draws only what the run really has.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/media"

render() {  # stdin = report.json
  cat > "$TMP/report.json"
  NS_REPORT_DIR="$TMP" NS_MEDIA_DIR="$TMP/media" python3 "$BIN_DIR/report-render.py" >/dev/null 2>&1
  cat "$TMP/report.html" 2>/dev/null
}

facts() {  # $1 = blocks json  $2 = media json (default none)
  jq -nc --argjson blocks "$1" --argjson media "${2:-[]}" \
    '{generated_human:"now", project_name:"p", project_dir:"/x", session_id:"s", branch:"main",
      base_sha:"aaaaaaaa", head_sha:"bbbbbbbb", language:"English", task:"t", narrative:"",
      diffstat:" 1 file changed", files_changed:1, insertions:1, deletions:0,
      commits:[{sha:"a1b2c3d",subject:"did a thing"}], media:$media, evidence:null,
      stacks:[], format:"notes", items:[], findings:[], blocks:$blocks, writer:"codex"}'
}

echo "===== a run with nothing visual shows no visual section ====="

out="$(facts '[{"type":"prose","heading":"What changed","text":"Moved sync to an endpoint."},{"type":"commits"}]' | render)"
case "$out" in *"What changed"*) ok "the prose block is rendered" ;; *) bad "prose block missing" ;; esac
case "$out" in *"not captured"*) bad "a placeholder pane is still drawn" ;; *) ok "no placeholder pane" ;; esac
case "$out" in *"Before &amp; after"*) bad "before/after appeared with no frames" ;; *) ok "no phantom before/after" ;; esac
case "$out" in *"did a thing"*) ok "the commits block is rendered where asked" ;; *) bad "commits missing" ;; esac

echo "===== a block asking for a frame that does not exist renders nothing ====="

out="$(facts '[{"type":"beforeAfter","caption":"should not appear"},{"type":"media","label":"after"},{"type":"video"}]' | render)"
case "$out" in *"should not appear"*) bad "beforeAfter rendered without frames" ;; *) ok "beforeAfter refuses without frames" ;; esac
case "$out" in *"<video"*) bad "a video element with no recording" ;; *) ok "video refuses without a recording" ;; esac

echo "===== with real frames, the visual blocks DO render ====="

# Real files, because a manifest entry for a file that is not there must not render either.
python3 - "$TMP/media" <<'PYFRAMES'
import sys, struct, zlib, pathlib
def png(path, rgb):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))
    raw = b"".join(b"\x00" + bytes(rgb) * 8 for _ in range(8))
    pathlib.Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
d = sys.argv[1]
png(d + "/b.png", (30, 30, 40)); png(d + "/a.png", (40, 30, 30))
PYFRAMES

out="$(facts '[{"type":"beforeAfter","caption":"the header"}]' \
             '[{"kind":"screenshot","label":"before","file":"b.png"},{"kind":"screenshot","label":"after","file":"a.png"}]' | render)"
case "$out" in *"the header"*) ok "beforeAfter renders when both frames exist" ;; *) bad "beforeAfter did not render with frames" ;; esac
case "$out" in *"<img"*) ok "and the frames are embedded" ;; *) bad "no image was embedded" ;; esac

# A manifest that names a file which is not on disk must render nothing.
out="$(facts '[{"type":"media","label":"after","caption":"ghost"}]' \
             '[{"kind":"screenshot","label":"after","file":"missing.png"}]' | render)"
case "$out" in *ghost*) bad "rendered a frame for a file that does not exist" ;; *) ok "a named-but-missing file renders nothing" ;; esac

echo "===== the free-form vocabulary ====="

out="$(facts '[{"type":"steps","heading":"How","items":["one","two"]},{"type":"bullets","heading":"Notes","items":["a"]},{"type":"table","heading":"Contract","columns":["Field","Was"],"rows":[["x","y"]]},{"type":"code","heading":"Excerpt","text":"def f(): pass"}]' | render)"
for want in "How" "<ol class=\"doc\">" "Notes" "<ul class=\"doc\">" "Contract" "<table class=\"doc\">" "Excerpt" "<pre class=\"doc\">"; do
  case "$out" in *"$want"*) ok "renders $want" ;; *) bad "missing $want" ;; esac
done

echo "===== empty blocks are dropped, not drawn as empty cards ====="

out="$(facts '[{"type":"prose","heading":"Nothing","text":""},{"type":"bullets","heading":"Also nothing","items":[]},{"type":"table","heading":"None","columns":["a"],"rows":[]}]' | render)"
for gone in "Nothing" "Also nothing" "None"; do
  case "$out" in *"$gone"*) bad "an empty block was drawn: $gone" ;; *) ok "an empty block is dropped ($gone)" ;; esac
done

echo "===== no document at all still produces an honest report ====="

out="$(jq -nc '{generated_human:"now", project_name:"p", project_dir:"/x", session_id:"s",
                branch:"main", base_sha:"aaaaaaaa", head_sha:"bbbbbbbb", language:"English",
                task:"t", narrative:"Did the thing.", diffstat:"", files_changed:1, insertions:1,
                deletions:0, commits:[{sha:"a1b2c3d",subject:"did a thing"}], media:[],
                evidence:null, stacks:[], format:"notes", items:[], findings:[], blocks:[]}' | render)"
case "$out" in *"Did the thing."*) ok "prose-only output is still shown" ;; *) bad "the narrative was lost" ;; esac
case "$out" in *"not captured"*) bad "the fallback still draws a placeholder" ;; *) ok "and no placeholder with it" ;; esac

echo "===== a writer can be chosen, and codex is the default ====="

grep -q 'WRITER="${SUPERVISOR_REPORT_WRITER:-codex}"' "$BIN_DIR/report.sh" \
  && ok "codex writes the report unless told otherwise" || bad "no writer selection in report.sh"
grep -q 'claude -p --tools' "$BIN_DIR/report.sh" \
  && ok "claude is available as the alternative" || bad "there is no claude path"

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
