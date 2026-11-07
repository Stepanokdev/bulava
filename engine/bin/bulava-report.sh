#!/bin/bash
# Bulava Report from the shell: the same store as the MCP server (lib/bulava_report.py says what it
# is), for what has no MCP — a worker started with --strict-mcp-config, an older Claude Code, a
# person — and for the weekly pass that reads the store.
#
#   bulava-report submit --title "…" --observed "…" [--expected "…"] [--severity low|medium|high|critical]
#                        [--component "…"] [--evidence "…"]… [--key "…"]      → prints the id
#   bulava-report list [--status new|done|all] [--json]
#   bulava-report show <id>
#   bulava-report pull <source-name> [--as <user>] -- <ssh arguments…>
#                        copy the reports of another machine into this store; prints how many were
#                        new. A machine that cannot be reached is an error, never "no reports".
#   bulava-report ack --review <file> <id>…
#                        mark reports read — only once the review that read them is on disk
#   bulava-report mcp-config                                                  → --mcp-config JSON
#   bulava-report chats --out DIR [--from ISO] [--to ISO] [--data-dir DIR]
#                        the week's Bulava chats as Markdown, messages chosen by their own time
#                        (lib/chat_export.py says why); default: the week ending this Tuesday 00:00 Kyiv
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
LIB="$BIN_DIR/lib"

py() { PYTHONPATH="$LIB${PYTHONPATH:+:$PYTHONPATH}" python3 - "$@"; }

usage() { sed -n '6,19p' "$SELF" | sed 's/^# \{0,1\}//'; exit 2; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
submit)
  args=(); while [ $# -gt 0 ]; do
    case "$1" in
      --title|--observed|--expected|--severity|--component|--evidence|--key|--session|--project)
        [ $# -ge 2 ] || { echo "❌ $1 needs a value" >&2; exit 2; }; args+=("$1" "$2"); shift 2 ;;
      *) echo "❌ unknown option: $1" >&2; exit 2 ;;
    esac
  done
  py "${args[@]+"${args[@]}"}" <<'PY'
import sys, bulava_report as br
f = {"evidence": [], "reporter": "cli"}
names = {"--title": "title", "--observed": "observed", "--expected": "expected", "--severity": "severity",
         "--component": "component", "--key": "idempotency_key", "--session": "session_id", "--project": "project"}
a = sys.argv[1:]
for i in range(0, len(a), 2):
    if a[i] == "--evidence":
        f["evidence"].append(a[i + 1])
    else:
        f[names[a[i]]] = a[i + 1]
try:
    rep, created = br.submit(f)
except br.ReportError as e:
    print(f"❌ not stored: {e}", file=sys.stderr); sys.exit(2)
except OSError as e:
    print(f"❌ not stored: the report store could not be written ({e})", file=sys.stderr); sys.exit(1)
print(rep["id"])
print(("stored" if created else "already stored") + f" on {rep['host']}, project {rep['project']}", file=sys.stderr)
PY
  ;;
list)
  status=new; json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status="${2:-}"; shift 2 ;;
      --json) json=1; shift ;;
      *) echo "❌ unknown option: $1" >&2; exit 2 ;;
    esac
  done
  case "$status" in new|done|all) ;; *) echo "❌ --status is new, done or all" >&2; exit 2 ;; esac
  py "$status" "$json" <<'PY'
import json, sys, bulava_report as br
reps = br.listing(sys.argv[1])
if sys.argv[2] == "1":
    print(json.dumps(reps, ensure_ascii=False, indent=2))
else:
    for r in reps:
        src = r.get("pulled_from") or r.get("host", "")
        print(f"{r['id']}  {r.get('created_at','')[:16]}  {r.get('severity',''):8} {r.get('project',''):24.24} {src:18.18} {r.get('title','')}")
    print(f"{len(reps)} report(s)", file=sys.stderr)
PY
  ;;
show)
  [ $# -eq 1 ] || usage
  py "$1" <<'PY'
import json, sys, bulava_report as br
p = br.find(sys.argv[1])
if not p:
    print(f"❌ no report {sys.argv[1]}", file=sys.stderr); sys.exit(1)
print(json.dumps(br.load(p), ensure_ascii=False, indent=2))
PY
  ;;
pull)
  src="${1:-}"; [ -n "$src" ] && shift || usage
  as=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in --as) as="${2:-}"; shift 2 ;; *) echo "❌ unknown option: $1" >&2; exit 2 ;; esac
  done
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || { echo "❌ pull needs ssh arguments after --" >&2; exit 2; }
  printf '%s' "$src" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || { echo "❌ source name: letters, digits, . _ -" >&2; exit 2; }
  if [ -n "$as" ]; then
    printf '%s' "$as" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || { echo "❌ --as: a user name" >&2; exit 2; }
  fi
  # The remote side prints a tar of its store, or an empty one when it has none — so "nothing there"
  # and "could not ask" are different exits here.
  remote='d="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}/bulava-reports"; if [ -d "$d" ]; then cd "$d" && find new done -maxdepth 1 -name "br-*.json" 2>/dev/null | tar -cf - -T -; else tar -cf - -T /dev/null; fi'
  [ -n "$as" ] && remote="sudo -n -H -u $as sh -c '$(printf '%s' "$remote" | sed "s/'/'\\\\''/g")'"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  if ! ssh -o BatchMode=yes -o ConnectTimeout=15 "$@" "$remote" > "$tmp/store.tar" 2> "$tmp/err"; then
    echo "❌ $src: NOT CHECKED — $(tail -1 "$tmp/err" 2>/dev/null)" >&2; exit 1
  fi
  mkdir -p "$tmp/x" && tar -xf "$tmp/store.tar" -C "$tmp/x" 2>/dev/null \
    || { echo "❌ $src: NOT CHECKED — the answer was not a report archive" >&2; exit 1; }
  py "$tmp/x" "$src" <<'PY'
import glob, os, sys, bulava_report as br
root, src = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(root, "new", "br-*.json")) + glob.glob(os.path.join(root, "done", "br-*.json")))
new = [rid for rid in (br.adopt(f, src) for f in files) if rid]
print(f"{src}: {len(files)} report(s) there, {len(new)} new here")
for rid in new:
    print(f"  {rid}")
PY
  ;;
ack)
  review=""; ids=()
  while [ $# -gt 0 ]; do
    case "$1" in --review) review="${2:-}"; shift 2 ;; *) ids+=("$1"); shift ;; esac
  done
  [ ${#ids[@]} -gt 0 ] || { echo "❌ ack: which reports?" >&2; exit 2; }
  py "$review" "${ids[@]}" <<'PY'
import sys, bulava_report as br
try:
    done = br.ack(sys.argv[2:], sys.argv[1])
except br.ReportError as e:
    print(f"❌ {e}", file=sys.stderr); sys.exit(2)
print(f"{len(done)} report(s) marked read")
PY
  ;;
chats)
  python3 "$LIB/chat_export.py" "$@"
  ;;
mcp-config)
  jq -n --arg py "$(command -v python3 || echo python3)" --arg srv "$BIN_DIR/bulava-report-mcp.py" \
    '{mcpServers: {"bulava-report": {command: $py, args: [$srv]}}}'
  ;;
*) usage ;;
esac
