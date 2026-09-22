#!/bin/bash
set -u
BIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh" 2>/dev/null || true

PROJ="$(canon_path "${1:?usage: report.sh <project-dir> <session-id> [language]}")"
SID="${2:-adhoc}"
LANG_NAME="${3:-English}"

SLUG="$(slug_for "$PROJ")"
IDIR="$(instance_dir "$SLUG")"
if [ -d "$IDIR" ]; then EVID_DIR="$IDIR/evidence/$SID"; else EVID_DIR="$SUP_STATE/evidence/$SID"; fi
REPORT_DIR="$EVID_DIR/report"; MEDIA="$REPORT_DIR/media"
rm -rf "$REPORT_DIR"; mkdir -p "$MEDIA"   # fresh each run so manifests never stack

log() { printf '[report] %s\n' "$*" >&2; }

BASE_SHA=""
BASE_SHA="$(read_base_sha "$IDIR")"
if [ -z "$BASE_SHA" ] && [ -f "$EVID_DIR/evidence.json" ]; then
  # Validated too. This evidence was written by a run whose base-sha was the word HEAD, so it holds
  # the word HEAD — and taking it unchecked put the empty diff straight back.
  BASE_SHA="$(only_object_id "$(jq -r '.base_sha // ""' "$EVID_DIR/evidence.json" 2>/dev/null)")"
fi
BRANCH="$(git -C "$PROJ" rev-parse --abbrev-ref HEAD 2>/dev/null)"
HEAD_SHA="$(resolve_base_sha "$PROJ")"
PROJ_NAME="$(basename "$PROJ")"
STACKS="$(detect_stacks "$PROJ" 2>/dev/null || echo "")"

TASK=""
for f in "$IDIR/task" "$IDIR/task.md" "$IDIR/mission.md"; do
  [ -f "$f" ] && { TASK="$(cat "$f" 2>/dev/null)"; break; }
done

RANGE=""
if [ -n "$BASE_SHA" ] && git -C "$PROJ" cat-file -e "$BASE_SHA" 2>/dev/null; then
  RANGE="$BASE_SHA..HEAD"
fi
if [ -n "$RANGE" ]; then
  COMMITS_JSON="$(git -C "$PROJ" log "$RANGE" --pretty=format:'%h%x1f%s' 2>/dev/null \
    | jq -R -s 'split("\n")|map(select(length>0))|map(split(""))|map({sha:.[0],subject:.[1]})')"
  DIFFSTAT="$(git -C "$PROJ" diff --stat "$RANGE" 2>/dev/null | tail -1)"
  NUMSTAT="$(git -C "$PROJ" diff --numstat "$RANGE" 2>/dev/null)"
else
  COMMITS_JSON="[]"; DIFFSTAT=""; NUMSTAT=""
fi
[ -z "$COMMITS_JSON" ] && COMMITS_JSON="[]"
FILES_CHANGED="$(printf '%s\n' "$NUMSTAT" | grep -c . 2>/dev/null || echo 0)"
INS="$(printf '%s\n' "$NUMSTAT" | awk '{s+=$1} END{print s+0}')"
DEL="$(printf '%s\n' "$NUMSTAT" | awk '{s+=$2} END{print s+0}')"

log "capturing after ($BRANCH)"
bash "$BIN_DIR/capture.sh" "$PROJ" "$MEDIA" "after" "$STACKS" || true

if [ -n "$RANGE" ]; then
  WT="$(mktemp -d "${TMPDIR:-/tmp}/ns-before-XXXXXX")"
  log "capturing before ($BASE_SHA) in throwaway worktree"
  if git -C "$PROJ" worktree add --detach "$WT" "$BASE_SHA" >/dev/null 2>&1; then
    bash "$BIN_DIR/capture.sh" "$WT" "$MEDIA" "before" "$STACKS" || true
    git -C "$PROJ" worktree remove --force "$WT" >/dev/null 2>&1
  else
    rmdir "$WT" 2>/dev/null
    printf '{"label":"before","kind":"none","file":"","note":"could not create worktree at base","ok":false}\n' >> "$MEDIA/manifest.jsonl"
  fi
else
  printf '{"label":"before","kind":"none","file":"","note":"no base SHA to compare against","ok":false}\n' >> "$MEDIA/manifest.jsonl"
fi

MANIFEST_JSON="[]"
[ -f "$MEDIA/manifest.jsonl" ] && MANIFEST_JSON="$(jq -s '.' "$MEDIA/manifest.jsonl" 2>/dev/null || echo '[]')"

FINDINGS_JSON="$(findings_json "$IDIR" "$(cat "$IDIR/run-id" 2>/dev/null || true)")"

EVIDENCE_JSON="null"
[ -f "$EVID_DIR/evidence.json" ] && EVIDENCE_JSON="$(cat "$EVID_DIR/evidence.json")"

OUTCOME_RESULT=""; OUTCOME_SUMMARY=""
if [ -f "$IDIR/outcome.json" ]; then
  OUTCOME_RESULT="$(jq -r '.result // ""' "$IDIR/outcome.json" 2>/dev/null)"
  OUTCOME_SUMMARY="$(jq -r '.summary // ""' "$IDIR/outcome.json" 2>/dev/null)"
fi
REVIEW_STATE=""; REVIEW_DISP=""; REVIEW_WHY=""
_rj="$IDIR/reports/review.json"
if [ -f "$_rj" ]; then
  REVIEW_STATE="$(jq -r '.state // ""' "$_rj" 2>/dev/null)"
  REVIEW_DISP="$(jq -r '.disposition // ""' "$_rj" 2>/dev/null)"
  REVIEW_WHY="$(jq -r '.findings // ""' "$_rj" 2>/dev/null | clip_utf8 800)"
fi
CRITERIA_TEXT=""
_dfile="$SUP_STATE/runs/$(cat "$IDIR/run-id" 2>/dev/null)/criteria-decisions.jsonl"
[ -s "$_dfile" ] && CRITERIA_TEXT="$(jq -r '"- \(.criterion): \(.decision)"' "$_dfile" 2>/dev/null)"

WRITER="${SUPERVISOR_REPORT_WRITER:-codex}"
SUBJECTS="$(printf '%s' "$COMMITS_JSON" | jq -r '.[].subject' 2>/dev/null)"
HAS_BEFORE=0; HAS_AFTER=0; HAS_VIDEO=0
printf '%s' "$MANIFEST_JSON" | jq -e 'any(.[]; .kind=="screenshot" and .label=="before" and (.file|length>0))' >/dev/null 2>&1 && HAS_BEFORE=1
printf '%s' "$MANIFEST_JSON" | jq -e 'any(.[]; .kind=="screenshot" and .label=="after"  and (.file|length>0))' >/dev/null 2>&1 && HAS_AFTER=1
printf '%s' "$MANIFEST_JSON" | jq -e 'any(.[]; .kind=="video" and (.file|length>0))' >/dev/null 2>&1 && HAS_VIDEO=1

AVAILABLE="$(
  { [ "$HAS_BEFORE" = 1 ] && echo "- a BEFORE screenshot exists"; }
  { [ "$HAS_AFTER" = 1 ] && echo "- an AFTER screenshot exists"; }
  { [ "$HAS_VIDEO" = 1 ] && echo "- a screen recording exists"; }
  { [ -n "$SUBJECTS" ] && echo "- commits exist"; }
  { [ -n "$EVIDENCE_JSON" ] && [ "$EVIDENCE_JSON" != null ] && echo "- machine evidence (checks with exit codes) exists"; }
  { printf '%s' "${FINDINGS_JSON:-[]}" | jq -e 'length > 0' >/dev/null 2>&1 && echo "- findings from outside the task exist"; }
  true
)"

BLOCK_SPEC='Return ONLY a JSON array of blocks, no prose around it. Allowed blocks:
{"type":"prose","heading":"...","text":"..."}                      free text, 1-3 short paragraphs
{"type":"bullets","heading":"...","items":["...","..."]}           an unordered list
{"type":"steps","heading":"...","items":["...","..."]}             a numbered sequence
{"type":"table","heading":"...","columns":["..."],"rows":[["..."]]} a small comparison or scheme
{"type":"code","heading":"...","text":"..."}                       a short excerpt, monospaced
{"type":"beforeAfter","caption":"..."}                             ONLY if both before and after exist
{"type":"media","label":"after","caption":"..."}                   ONLY if that file exists
{"type":"video","caption":"..."}                                   ONLY if a recording exists
{"type":"commits"}    {"type":"evidence"}    {"type":"findings"}    the recorded facts, placed by you

Rules: choose the blocks THIS run actually has something for — a backend change may be prose plus
commits plus evidence and nothing visual; a UI change may lead with beforeAfter. Never include a
media, video or beforeAfter block for a file that does not exist. Ground every word in the facts
given; invent nothing. 3 to 6 blocks is usually right.

ORDER, and it is not negotiable — he reads the top and stops:
1. FIRST block: what the result is and what changed for him, in plain words. Not what remains
   unproven, not what was hard, not the process.
2. Then how it was verified.
3. Then what (if anything) is needed FROM HIM — one line, concrete.
4. Only then the detail: corrections to the plan, findings, caveats.
A caveat is never the opening. If the work was done, say so first — a summary that leads with what is
still imperfect reads as failure over work that succeeded, and that is the single most common
complaint about these reports.'

NARRATIVE=""
BLOCKS="[]"
if [ -n "$SUBJECTS" ] || [ "$HAS_AFTER" = 1 ]; then
  PROMPT="You are composing an honest run report for a software task, written in $LANG_NAME.
The reader is the person who asked for the work. He is not going to read a log.

Task: ${TASK:-（not recorded — infer from the commits）}

HOW IT ENDED (this is the truth of the run — do not soften it and do not contradict it):
result: ${OUTCOME_RESULT:-(not declared)}
the run's own words: ${OUTCOME_SUMMARY:-(none)}
review: ${REVIEW_STATE:-(not reviewed)} / ${REVIEW_DISP:-—}
${REVIEW_WHY:+why: $REVIEW_WHY}
${CRITERIA_TEXT:+
Criteria the reviewer ruled on (a superseded one is NOT an unmet criterion — never present it as
one; if it matters, say in one line that the plan was corrected and what replaced it):
$CRITERIA_TEXT}

Commits on this branch:
$SUBJECTS

Files changed: $FILES_CHANGED (+$INS / -$DEL). $DIFFSTAT

What this run actually produced:
$AVAILABLE

Findings it filed (kind + text — a blocker that was later retracted is NOT an open blocker):
$(printf '%s' "$FINDINGS_JSON" | jq -r '.[] | "- [\(.kind)] \(.text)"' 2>/dev/null | clip_utf8 1500)

Machine evidence:
$(printf '%s' "$EVIDENCE_JSON" | jq -r 'if .==null then "(the verifier did not run)" else "overall: \(.overall_status // "?") — " + ((.criteria // []) | map("\(.criterion)=\(.status)") | join(", ")) end' 2>/dev/null | clip_utf8 900)

$BLOCK_SPEC"
  case "$WRITER" in
    claude)
      log "composing the report via claude (in $LANG_NAME)"
      RAW_DOC="$(printf '%s' "$PROMPT" | perl -e 'alarm shift; exec @ARGV' 240 \
        env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude -p --tools '' --strict-mcp-config \
        $(claude_effort_args) \
        ${SUPERVISOR_CLAUDE_MODEL:+--model "$SUPERVISOR_CLAUDE_MODEL"} 2>/dev/null)"
      ;;
    *)
      log "composing the report via codex (in $LANG_NAME)"
      RAW_DOC="$(perl -e 'alarm shift; exec @ARGV' 240 codex exec $(codex_effort_flags) \
        --sandbox read-only --skip-git-repo-check "$PROMPT" 2>/dev/null)"
      ;;
  esac
  CAND="$(printf '%s' "$RAW_DOC" | perl -0ne 'print $1 if /(\[.*\])/s')"
  if printf '%s' "$CAND" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
    BLOCKS="$CAND"
  else
    NARRATIVE="$(printf '%s' "$RAW_DOC" | perl -0pe 's/\A\s+//; s/\s+\z//')"
  fi
fi

if [ "$BLOCKS" = "[]" ] && [ -z "$NARRATIVE" ]; then
  NARRATIVE="$(printf '%s' "$COMMITS_JSON" | jq -r 'if length>0 then (map("• "+.subject)|join("\n")) else "No commits recorded on this branch relative to its base." end' 2>/dev/null)"
fi

GEN_TS="$(date +%s)"
GEN_HUMAN="$(date '+%Y-%m-%d %H:%M')"

jq -n \
  --arg ts "$GEN_TS" --arg human "$GEN_HUMAN" \
  --arg proj "$PROJ" --arg name "$PROJ_NAME" --arg sid "$SID" \
  --arg base "$BASE_SHA" --arg head "$HEAD_SHA" --arg branch "$BRANCH" \
  --arg lang "$LANG_NAME" --arg task "$TASK" --arg narrative "$NARRATIVE" \
  --arg diffstat "$DIFFSTAT" --argjson fc "${FILES_CHANGED:-0}" \
  --argjson ins "${INS:-0}" --argjson del "${DEL:-0}" \
  --argjson commits "$COMMITS_JSON" --argjson media "$MANIFEST_JSON" \
  --argjson evidence "$EVIDENCE_JSON" \
  --argjson findings "$FINDINGS_JSON" \
  --argjson blocks "$BLOCKS" \
  --arg writer "$WRITER" \
  --arg stacks "$STACKS" \
  '($media | map(select(.kind=="video" and (.file|length>0))) | .[0].file) as $vid
   | ($media | map(select(.kind=="screenshot" and (.file|length>0)))) as $shots
   | ($shots | map(select(.label=="before")) | .[0].file) as $bef
   | ($shots | map(select(.label=="after"))  | .[0].file) as $aft
   | {generated_ts:($ts|tonumber),generated_human:$human,project_dir:$proj,project_name:$name,
      session_id:$sid,base_sha:$base,head_sha:$head,branch:$branch,language:$lang,
      task:$task,narrative:$narrative,diffstat:$diffstat,files_changed:$fc,insertions:$ins,
      deletions:$del,commits:$commits,media:$media,evidence:$evidence,findings:$findings,
      blocks:$blocks,writer:$writer,
      stacks:($stacks|split(" ")|map(select(.!=""))),
      format:(if $vid then "video" elif ($shots|length>0) then "photos" else "notes" end),
      video:$vid, summary:$narrative,
      items:(if ($shots|length>0)
             then [{before:(if $bef then "media/"+$bef else null end),
                    after:(if $aft then "media/"+$aft else null end)}]
             else [] end)}' \
  > "$REPORT_DIR/report.json" 2>/dev/null

NS_REPORT_DIR="$REPORT_DIR" NS_MEDIA_DIR="$MEDIA" python3 "$BIN_DIR/report-render.py" \
  && echo "$REPORT_DIR/report.html" \
  || { log "html render failed"; echo "$REPORT_DIR/report.json"; }
