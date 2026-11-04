# What the reviewer sees besides the diff — sourced by hooks/review-gate.sh.
#
# The review read code and nothing else. On a 3D scene that meant a model floating sideways with no
# hand holding it passed review, because nothing in the diff says "sideways". Tried on the real
# frames: given the frames alone, Codex found one missing model and missed the sideways one and
# the missing hand; given the same frames with the contract's own questions it
# answered NOT MET to all three. So the reviewer gets both: the frames, attached to its message, and
# a rule that every criterion about what a person sees is answered from them.
#
# Two sources of frames, in this order:
#   1. what the worker showed it (`show-reviewer`), a clip as a few frames taken from it;
#   2. images the change itself added or changed (evidence/, screenshots/ …).
# And, when the work is visual, a browser of its own (`review_browser`): headless, a throwaway
# profile, and only the tools a tester needs to look — open, click, press a key, take a picture.
# No script evaluation, so what it sees is reached the way a person reaches it.

: "${SUPERVISOR_REVIEW_FRAMES_MAX:=10}"      # frames attached to one review
: "${SUPERVISOR_REVIEW_CLIP_FRAMES:=4}"      # frames taken from one clip
: "${SUPERVISOR_REVIEW_BROWSER:=1}"          # 0 = the reviewer gets no browser of its own

REVIEW_BROWSER_TOOLS="new_page navigate_page list_pages select_page close_page take_screenshot take_snapshot wait_for click hover drag press_key fill resize_page list_console_messages"

# Frames from a clip, evenly spaced and never the very first or last instant (a fade or a black
# frame says nothing). Prints one path per line; nothing when ffmpeg cannot read it.
review_clip_frames() {   # $1=clip $2=out dir $3=prefix
  local clip="$1" out="$2" pre="$3" n="${SUPERVISOR_REVIEW_CLIP_FRAMES:-4}" dur i at f
  command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 || return 0
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$clip" 2>/dev/null)"
  case "$dur" in ''|*[!0-9.]*) return 0 ;; esac
  for i in $(seq 1 "$n"); do
    at="$(awk -v d="$dur" -v i="$i" -v n="$n" 'BEGIN{printf "%.2f", d*i/(n+1)}')"
    f="$out/$pre-$i.jpg"
    ffmpeg -nostdin -loglevel error -y -ss "$at" -i "$clip" -frames:v 1 -q:v 3 "$f" </dev/null 2>/dev/null \
      && [ -s "$f" ] && printf '%s\t%s\n' "$f" "$at"
  done
}

# Collects the frames for this review into $idir/review-eyes/: `frames.tsv` (path TAB caption) for
# the attachment list and the prompt. Always succeeds; an unreadable source is skipped.
review_eyes_collect() {   # $1=instance dir $2=project dir $3=base sha
  local idir="$1" cwd="$2" base="${3:-}" out max n=0 path kind caption line at f rel size
  out="$idir/review-eyes"; max="${SUPERVISOR_REVIEW_FRAMES_MAX:-10}"
  rm -rf "$out" 2>/dev/null; mkdir -p "$out" 2>/dev/null || return 0
  : > "$out/frames.tsv"
  _eyes_add() {   # $1=path $2=caption
    [ "$n" -lt "$max" ] || return 1
    size="$(wc -c < "$1" 2>/dev/null | tr -d ' ')"
    [ "${size:-0}" -gt 0 ] && [ "${size:-0}" -le 15000000 ] || return 0
    cut -f1 "$out/frames.tsv" | grep -qxF "$1" && return 0
    printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" >> "$out/frames.tsv"; n=$((n + 1))
  }
  local frames; frames="$(review_frames_file "$idir")"
  if [ -s "$frames" ]; then
    local k=0
    while IFS=$'\t' read -r path kind caption; do
      [ -f "$path" ] || continue
      k=$((k + 1))
      if [ "$kind" = video ]; then
        while IFS=$'\t' read -r f at; do
          _eyes_add "$f" "кадр на ${at} с з кліпу $(basename "$path")${caption:+: $caption}" || break
        done < <(review_clip_frames "$path" "$out" "clip$k")
      else
        _eyes_add "$path" "$caption" || break
      fi
    done < <(jq -r '[.path, (.kind // "image"), (.caption // "")] | @tsv' "$frames" 2>/dev/null)
  fi
  if [ -n "$base" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r rel; do
      [ -n "$rel" ] && [ -f "$cwd/$rel" ] || continue
      _eyes_add "$cwd/$rel" "зображення, яке ця зміна додала або змінила: $rel" || break
    done < <( { git -C "$cwd" diff --name-only --diff-filter=AM "$base" -- 2>/dev/null
                git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null; } \
              | grep -iE '\.(png|jpe?g|webp)$' | review_eyes_not_material | sort -u)
  fi
  unset -f _eyes_add
  return 0
}

# A texture is an image the change added, and no picture of the product: a game's first piece once
# spent four of ten frames on ground/diff.jpg and nor.jpg. Material folders and map-named files
# (diff, nor, rough, ao, disp…) stay out; a screenshot shown on purpose is never filtered.
review_eyes_not_material() {
  grep -viE '(^|/)(textures?|materials?|hdri|skybox|fonts?|node_modules)/|(^|/)[^/]*(^|[_.-])(diff|diffuse|albedo|nor|normal|nrm|rough|roughness|ao|disp|displacement|arm|metal|metallic|metalness|height|bump|spec|specular|mask|opacity)([_.-][^/]*)?\.[a-z]+$' || true
}

# One argument per line, read into an array by the gate: the -i flags that attach the collected frames.
review_eyes_image_args() {   # $1=instance dir
  local f="$1/review-eyes/frames.tsv" p
  [ -s "$f" ] || return 0
  while IFS=$'\t' read -r p _; do [ -f "$p" ] && printf -- '-i\n%s\n' "$p"; done < "$f"
}

# Whether this review is about something a person sees: the RunSpec says so, or there are frames.
review_eyes_visual() {   # $1=instance dir
  [ "$(runspec_get "$1" '.surface.visual' 2>/dev/null)" = true ] && return 0
  [ "$(runspec_get "$1" '.surface.ui' 2>/dev/null)" = true ] && return 0
  [ -s "$1/review-eyes/frames.tsv" ]
}

# One argument per line, read into an array by the gate: the -c overrides that give Codex its own browser. Codex runs
# MCP servers outside its sandbox, so read-only still holds for the workspace while the browser can
# reach a game on 127.0.0.1. `exec` approves nothing by itself, hence each look-only tool approved by
# name, and `enabled_tools` so nothing else is even offered.
review_browser_args() {   # $1=instance dir
  local tools t exe
  [ "${SUPERVISOR_REVIEW_BROWSER:-1}" = 1 ] || return 0
  review_eyes_visual "$1" || return 0
  command -v npx >/dev/null 2>&1 || return 0
  exe="$(browser_executable_args 2>/dev/null || echo '[]')"
  tools="$(printf '%s\n' $REVIEW_BROWSER_TOOLS | jq -R . | jq -sc .)"
  printf -- '-c\nmcp_servers.review_browser.command="npx"\n'
  printf -- '-c\nmcp_servers.review_browser.args=%s\n' \
    "$(jq -nc --argjson x "$exe" '["-y","chrome-devtools-mcp@1.10.1","--headless","--isolated","--viewport","1280x720"] + $x')"
  printf -- '-c\nmcp_servers.review_browser.startup_timeout_sec=90\n'
  printf -- '-c\nmcp_servers.review_browser.enabled_tools=%s\n' "$tools"
  for t in $REVIEW_BROWSER_TOOLS; do
    printf -- '-c\nmcp_servers.review_browser.tools.%s.approval_mode="approve"\n' "$t"
  done
}

# The part of the review prompt that says what was attached and how to judge by it.
review_eyes_block() {   # $1=instance dir $2=browser offered (1/0)
  local idir="$1" browser="${2:-0}" f="$1/review-eyes/frames.tsv" i=0 p c
  if [ -s "$f" ]; then
    echo "WHAT A PERSON SEES — FRAMES ATTACHED TO THIS MESSAGE, in this order:"
    while IFS=$'\t' read -r p c; do i=$((i + 1)); echo " $i. $p${c:+ — $c}"; done < "$f"
    cat <<'EOF'
(If the attachments did not reach you, open these paths with your file reader.)
Use these frames to judge what a person sees: is it held, facing the right way, inside its collider,
readable, where the contract says it is. For a criterion you judge by a frame, say which frame shows
it. The worker chose these frames; where a state that matters is missing and neither the code nor
your own look settles it, say what you could not see.

LOOK PAST THE CRITERIA FIRST: before checking any criterion, look at every frame the way a player
would and name what is plainly broken in it, whether or not a criterion mentions it — a texture
upside down, mirrored or stretched; an object floating, sunk into the ground or passing through
another; a hard polygon edge or seam where two surfaces should blend; flicker; a wrong scale; a held
object facing the wrong way; placeholder art or text. Say which frame and where in it. Criteria
are written before anyone saw the result, so they never list everything a person will notice.
EOF
    # A long project is one product built piece by piece: a broken thing on screen that an earlier,
    # accepted piece made is still broken in the product being handed over. Classed pre_existing it
    # can never reopen work, and that is how an upside-down texture passed five reviews of one long run.
    if declare -F pieces_present >/dev/null && pieces_present "$idir"; then
      cat <<'EOF'
This is one piece of a long project, and its earlier pieces are the same product: a plainly broken
thing you see in these frames is [acceptance_failure] even when an earlier, accepted piece made it,
never [pre_existing]. What is only a matter of taste ("could look nicer") is [related_improvement].
EOF
    fi
  elif review_eyes_visual "$idir"; then
    cat <<'EOF'
WHAT A PERSON SEES — NO FRAMES: this change alters what a person sees, and the worker attached no
frame of it. Frames are a tool, not a condition of acceptance. Judge the visual part by the code and,
if you have a browser of your own and the product runs, by looking yourself. Only when the whole
point of the task is how something looks and nothing you can read or open settles it, return that
criterion as UNPROVEN [acceptance_failure] and suggest the worker show it with
  $IDIR/show-reviewer <frame.png or clip.mp4> "what it shows"
EOF
  fi
  if [ "$browser" = 1 ]; then
    cat <<'EOF'
YOUR OWN BROWSER: if review_browser tools are available to you (headless, a clean profile, look-only
tools) and the product runs locally — a URL such as http://127.0.0.1:… in the report or the
project's README — open it and check the visual criteria yourself, with ordinary controls (click,
keys), and take your own screenshots, looking past the criteria in them too. What you see yourself outranks the worker's frames. A product that is not running is
not a defect of the work: say so and judge by the frames.
EOF
  fi
}
