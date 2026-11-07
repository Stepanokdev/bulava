# A long project, one piece at a time — sourced by bin/piece.sh and hooks/review-gate.sh.
#
# A big task done in one go comes out thin: a night built a whole product, every gate ticked, and
# every part half-finished. Done by hand it goes better: "make the sign-in", and only when the
# sign-in is good, "now the screens behind it".
# This is that, without a person cutting the work up.
#
# The worker keeps a plan of pieces and works on exactly one. A piece has its own acceptance
# criteria, written before its code, and its own base: the commit it started from. The review judges
# the open piece against its criteria and its diff only. A PASS accepts the piece and the gate sends
# the worker on to the next planned one, with a fresh review budget; the job is finished when no
# planned piece is left. Opening a piece while another is open is refused, so nothing is built on
# top of work the review has not accepted.
#
# State: $idir/pieces.json
#   {"pieces": [{"n", "title", "state": planned|open|accepted, "criteria": [...],
#                "base_sha", "reviewed_sha", "started_at", "accepted_at"}]}

# Where the plan lives: with the task when the run is an attempt of one (a server's follow-up starts a
# fresh instance, and a plan kept there would be forgotten with it), otherwise with the run.
pieces_home() {   # $1=instance dir
  local tid; tid="$(cat "$1/task-id" 2>/dev/null || true)"
  if [ -n "$tid" ] && declare -F task_exists >/dev/null && task_exists "$tid"; then
    printf '%s' "$(task_dir "$tid")"
  else
    printf '%s' "$1"
  fi
}
pieces_file() { printf '%s/pieces.json' "$(pieces_home "$1")"; }
# The frames shown to the reviewer belong to the open piece, so they live beside the plan.
review_frames_file() { printf '%s/review-frames.jsonl' "$(pieces_home "$1")"; }

pieces_present() { [ -s "$(pieces_file "$1")" ] && jq -e '(.pieces // []) | length > 0' "$(pieces_file "$1")" >/dev/null 2>&1; }

# Writes the file through a temporary one: a half-written plan is worse than the old one.
pieces_write() {   # $1=idir, stdin=json
  local f; f="$(pieces_file "$1")"
  cat > "$f.tmp.$$" && jq -e '.pieces | type == "array"' "$f.tmp.$$" >/dev/null 2>&1 \
    && mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
}

pieces_json() { [ -s "$(pieces_file "$1")" ] && cat "$(pieces_file "$1")" || printf '{"pieces":[]}'; }

# The open piece as one JSON object, or nothing.
piece_open() { pieces_json "$1" | jq -c 'first(.pieces[] | select(.state == "open")) // empty' 2>/dev/null; }

pieces_planned_count() { pieces_json "$1" | jq '[.pieces[] | select(.state == "planned")] | length' 2>/dev/null || echo 0; }

piece_next_planned_title() { pieces_json "$1" | jq -r 'first(.pieces[] | select(.state == "planned") | .title) // empty' 2>/dev/null; }

# The ladder as lines a person and a reviewer can read.
pieces_ladder() {   # $1=idir
  pieces_json "$1" | jq -r '.pieces[] |
    (if .state == "accepted" then "✓" elif .state == "open" then "▶" else "·" end)
    + " \(.n). \(.title)"
    + (if .state == "accepted" then " — прийнято\(if .reviewed_sha then " (" + (.reviewed_sha[0:9]) + ")" else "" end)"
       elif .state == "open" then " — у роботі" else "" end)' 2>/dev/null
}

# The text the job was given, from wherever this run keeps it: the RunSpec, the dispatch, the task.
piece_job_text() {   # $1=idir
  local tid
  runspec_present "$1" 2>/dev/null && runspec_objective "$1" 2>/dev/null
  jq -r '.task // empty' "$1/dispatch.json" 2>/dev/null
  tid="$(cat "$1/task-id" 2>/dev/null || true)"
  [ -n "$tid" ] && declare -F task_get >/dev/null && task_get "$tid" .objective 2>/dev/null
  return 0
}

# The product's specification, as paths relative to the project: the documents the job names
# ("за специфікацією SPEC.md") and the ones a specification is conventionally called. The worker
# writes a piece's criteria itself, so they can quietly drop what the specification requires — a
# product whose SPEC says "ready-made models first, not primitives" got a criterion "a procedural model",
# and a review held only to the criteria passed it. The review reads the specification itself.
# A file the job merely mentions is not a specification ("see KNOWN_ISSUES.md"): only one named
# right after a word that says it is — a specification, ТЗ, requirements — counts.
piece_spec_files() {   # $1=idir $2=project dir
  local proj="$2" f
  [ -d "$proj" ] || return 0
  {
    piece_job_text "$1" | python3 -c '
import re, sys
word = re.compile(r"(специфікац|спецификац|\bspec|\bТЗ\b|технічн\w* завдан|техническ\w* задан|вимог|требован|requirement|\bPRD\b)", re.I)
name = re.compile(r"[A-Za-z0-9_./-]*[A-Za-z0-9_-]\.(?:md|MD|txt)\b")
for line in sys.stdin:
    for m in word.finditer(line):
        for f in name.findall(line[m.end():m.end() + 80]):
            print(f[2:] if f.startswith("./") else f)
' 2>/dev/null
    ( cd "$proj" && find . -maxdepth 2 -type f 2>/dev/null | sed 's#^\./##' \
        | grep -E '^(docs/)?([Ss][Pp][Ee][Cc]|[Ss][Pp][Ee][Cc][Ii][Ff][Ii][Cc][Aa][Tt][Ii][Oo][Nn]|[Pp][Rr][Dd]|[Rr][Ee][Qq][Uu][Ii][Rr][Ee][Mm][Ee][Nn][Tt][Ss]|ТЗ|тз)\.(md|txt)$' )
  } | while IFS= read -r f; do
    case "$f" in /*|*..*) continue ;; esac
    [ -f "$proj/$f" ] && printf '%s\n' "$f"
  done | awk '!seen[$0]++' | head -5
}

# The block the review is given while a piece is open. Empty without one.
piece_contract_block() {   # $1=idir [$2=project dir]
  local p; p="$(piece_open "$1")"; [ -n "$p" ] || return 0
  local total; total="$(pieces_json "$1" | jq '.pieces | length')"
  local proj="${2:-$(cat "$1/project" 2>/dev/null || true)}" spec
  spec="$(piece_spec_files "$1" "$proj")"
  printf 'LONG PROJECT — ONE PIECE AT A TIME. This review is about the open piece ONLY.\n'
  printf 'CURRENT PIECE %s of %s: %s\n' "$(jq -r .n <<<"$p")" "$total" "$(jq -r .title <<<"$p")"
  printf 'ACCEPTANCE FOR THIS PIECE (written by the worker before its code — judge against THESE):\n'
  jq -r '.criteria | to_entries[] | "P\(.key + 1). \(.value)"' <<<"$p"
  if [ -n "$spec" ]; then
    printf '\nTHE PRODUCT SPECIFICATION (in the repository — open it and read the parts that govern what this piece builds):\n'
    printf '%s\n' "$spec" | sed 's/^/  /'
  fi
  printf '\nTHE PLAN (✓ accepted earlier, ▶ this piece, · later):\n'
  pieces_ladder "$1"
  cat <<'EOF'

Rules for a piece review:
- The diff and the frames are measured from the commit this piece started at. Later pieces are not
  owed now: their absence is never a defect.
- Hold THIS piece to a finished standard. "Works" is not "done": every criterion above, every state
  it names, seen working — not a first pass to polish later. A thin piece passed now is the defect
  this mode exists to prevent.
- A piece accepted earlier that this change broke is [regression_from_patch].
EOF
  [ -n "$spec" ] && cat <<'EOF'
- The criteria above are the worker's own reading of the specification, not a replacement for it.
  What the specification requires of the things THIS piece builds binds this piece as much as the
  criteria do: what it must be built from or with, how, how it must look or behave, what must not
  be done, the quality bar. A piece that departs from such a requirement — or a criterion that
  writes a weaker version of it in — is [acceptance_failure]. Name the section or quote the line.
  Only a requirement that clearly applies to what this piece builds counts; features the
  specification places in later pieces are still not owed. An alternative the specification
  itself allows counts only when it was really tried: "where possible" means attempted, and a
  free tool the specification or the job lets the worker install is possible — its absence on the
  machine is not a reason. A departure is excused only by the director's own words, or by an
  attempt the evidence shows (what was tried, what failed, the blocker filed); the worker's own say-so in a report or a criterion excuses nothing.
EOF
  return 0
}

# What the open piece is judged by besides its criteria: its number and the specification it is held
# to. Recorded at each review; 0 when it differs from the last review's — the rules moved under the
# piece (a spec appeared, the engine began holding pieces to it), so the next round's findings are
# counted against a new bar and must not be compared with the old count as "no progress".
# Raised whenever the rules piece_contract_block gives the review change in substance.
PIECE_REVIEW_RULES=2
piece_contract_changed() {   # $1=idir $2=project dir
  local p f cur
  p="$(piece_open "$1")"; [ -n "$p" ] || return 1
  f="$(pieces_home "$1")/piece-review-contract"
  cur="$(jq -r .n <<<"$p")|$PIECE_REVIEW_RULES|$(piece_spec_files "$1" "$2" | paste -sd ',' -)"
  [ "$(cat "$f" 2>/dev/null)" = "$cur" ] && return 1
  printf '%s\n' "$cur" > "$f" 2>/dev/null || true
  return 0
}

# The specification, for the worker: printed when a piece opens and when the gate sends it to the
# next one. Empty when the project has none.
piece_spec_note() {   # $1=idir $2=project dir
  local spec; spec="$(piece_spec_files "$1" "$2")"; [ -n "$spec" ] || return 0
  printf 'Специфікація продукту: %s. Рев'"'"'ю звіряє шматок і з нею, не лише з твоїми критеріями: з чого й як має бути зроблено, як має виглядати й поводитися, що заборонено. Критерії не можуть її послаблювати. Якщо вимогу специфікації не виконати — спершу спробуй те, що вона сама пропонує; не вийшло — це рішення директора: report-finding blocker «що саме і чому», а не рядок у звіті й не спрощений критерій.\n' \
    "$(printf '%s' "$spec" | paste -sd ',' - | sed 's/,/, /g')"
}

# The commit the open piece is measured from, if it is still in the history; else nothing. Not while
# the run protects uncommitted work it started on (base-snapshot): the scope gate restores files
# outside the fence from the run's base, and a piece's HEAD in its place would overwrite his edits.
piece_base_sha() {   # $1=idir $2=project dir
  local p b; p="$(piece_open "$1")"; [ -n "$p" ] || return 0
  [ -e "$1/base-snapshot" ] && return 0
  # Only an object id: a plan written before piece.sh refused unborn repositories may hold the word
  # HEAD, which "is an ancestor of HEAD" forever and so measured every piece from the latest commit.
  b="$(only_object_id "$(jq -r '.base_sha // empty' <<<"$p")")"; [ -n "$b" ] || return 0
  git -C "$2" merge-base --is-ancestor "$b" HEAD 2>/dev/null && printf '%s\n' "$b"
}

# The review passed. With a piece open: accept it at this commit. Prints what is next —
#   "next<TAB>title"  another planned piece is waiting
#   "plan-done"       that was the last one: the job is finished
#   "dirty"           uncommitted work: a piece is accepted only as a commit, or the next one
#                     would start from a HEAD without it
#   "write-failed"    the acceptance could not be recorded — nothing may be finished on it
#   ""                no piece was open (not a long project, or nothing to accept)
piece_accept_open() {   # $1=idir $2=project dir
  local idir="$1" cwd="$2" p n head next
  p="$(piece_open "$idir")"; [ -n "$p" ] || return 0
  if [ -n "$(git -C "$cwd" status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
    printf 'dirty\n'; return 0
  fi
  n="$(jq -r .n <<<"$p")"; head="$(git -C "$cwd" rev-parse HEAD 2>/dev/null || true)"
  pieces_json "$idir" | jq --argjson n "$n" --arg sha "$head" --arg ts "$(date '+%F %T')" \
    '.pieces |= map(if .n == $n then .state = "accepted" | .reviewed_sha = $sha | .accepted_at = $ts else . end)' \
    | pieces_write "$idir" || { printf 'write-failed\n'; return 0; }
  next="$(piece_next_planned_title "$idir")"
  if [ -n "$next" ]; then printf 'next\t%s\n' "$next"; else printf 'plan-done\n'; fi
}

# A piece is reviewed when the worker says it is done, not every time it stops. A piece takes hours,
# and a worker waiting on a forty-minute browser run ends its turn: each such stop used to be a
# review of half-made, uncommitted work, and two of them in a row are the stall that parks the job.
# When a review of the open piece begins, the declaration it answered is fingerprinted; a stop counts
# as "done" only with a declaration other than that one. (A fingerprint, not a file time: the gate
# usually starts within the same second the worker declared, and some shells compare whole seconds.)
piece_review_mark() { printf '%s/piece-reviewed-declaration' "$(pieces_home "$1")"; }
piece_declaration_print() { cksum < "$1/outcome.json" 2>/dev/null | awk '{print $1 "-" $2}'; }
piece_mark_reviewed() { piece_declaration_print "$1" > "$(piece_review_mark "$1")" 2>/dev/null || true; }

piece_declared_since_review() {   # $1=instance dir → 0 when a review of the open piece is due
  local idir="$1" f r rid cur m
  f="$idir/outcome.json"; [ -s "$f" ] || return 1
  r="$(jq -r '.result // empty' "$f" 2>/dev/null)"
  case "$r" in succeeded_*) ;; *) return 1 ;; esac
  rid="$(jq -r '.run_id // empty' "$f" 2>/dev/null)"; cur="$(cat "$idir/run-id" 2>/dev/null || true)"
  [ -n "$rid" ] && [ "$rid" = "$cur" ] || return 1
  m="$(piece_review_mark "$idir")"
  [ "$(cat "$m" 2>/dev/null)" != "$(piece_declaration_print "$idir")" ]
}

# A new request in the same run is not the next piece of the last one: its plan, kept with the run,
# is set aside under the dispatch it belonged to. A plan kept with a task is left alone — a new task
# is a new record.
pieces_set_aside() {   # $1=instance dir
  local idir="$1" did
  [ -s "$idir/pieces.json" ] && [ ! -s "$idir/task-id" ] || return 0
  did="$(jq -r '.id // empty' "$idir/dispatch.json" 2>/dev/null || true)"
  mkdir -p "$idir/dispatches" 2>/dev/null || true
  mv -f "$idir/pieces.json" "$idir/dispatches/${did:-previous}.pieces.json" 2>/dev/null \
    || rm -f "$idir/pieces.json" 2>/dev/null || true
}
