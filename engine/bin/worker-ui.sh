#!/bin/bash
#
# Drive another app's interface — through Bulava, never directly.
#
# WHY IT WORKS THIS WAY. macOS grants Accessibility to the code identity of the process it sees. A
# worker runs under a tmux daemon that holds no grant and whose identity changes with every
# rebuild, so "let the worker click" would mean granting Accessibility to `node`, or to a terminal
# — which hands those rights to everything else that ever runs through the same binary. So this
# script contains no Accessibility code at all. It writes a request; Bulava performs it, because
# Bulava is the one signed process macOS trusts. One grant, given once, covers every project.
#
# Same protocol as `capture`: a JSON file in a watched directory, a `.done` file with the answer.
# If Bulava is not running there is nobody to ask, and this says so instead of pretending.
#
# USAGE
#   ui apps                             what is running, with pids
#   ui status                           whether Bulava may drive anything yet
#   ui tree <pid> [--depth N]           the window tree, with a ref on every row
#   ui click <pid> <ref>                press the element at that ref
#   ui click <pid> --at x,y             click a screen point
#   ui type <pid> <ref> <text…>         put text into that element
#   ui type <pid> - <text…>             type into whatever has focus
#   ui key <pid> <keys>                 return · escape · tab · cmd+s · cmd+shift+k
#   ui menu <pid> <Menu/Item>           choose a menu item
#
# A ref is a PATH from the tree — `w0.c4.c1` — resolved again at the moment of the action. If the
# layout moved, it fails loudly rather than clicking whatever now sits there.
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"
  case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac
done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh" 2>/dev/null || SUP_STATE="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}"

REQ_DIR="$SUP_STATE/ui-requests"
SERVICE="$REQ_DIR/service.json"
TIMEOUT="${NS_UI_TIMEOUT:-25}"          # tenths handled below; whole seconds here

usage() { sed -n '/^# USAGE/,/^set -u/p' "$SELF" | sed 's/^# \{0,1\}//; $d'; }

action="${1:-}"
case "$action" in
  ""|-h|--help|help) usage; exit 0 ;;
esac

mkdir -p "$REQ_DIR" 2>/dev/null || true

if [ ! -f "$SERVICE" ]; then
  echo "ui: додаток Bulava не запущений — керувати інтерфейсом нікому." >&2
  exit 3
fi
svc_pid="$(jq -r '.pid // empty' "$SERVICE" 2>/dev/null)"
if [ -n "$svc_pid" ] && ! kill -0 "$svc_pid" 2>/dev/null; then
  echo "ui: Bulava більше не працює (pid $svc_pid) — керувати інтерфейсом нікому." >&2
  exit 3
fi

# Build the request. Every action carries only the fields it needs, so a malformed call is refused
# by the app rather than half-performed.
pid=""; ref=""; at=""; text=""; keys=""; mpath=""; depth=""
shift 2>/dev/null || true

case "$action" in
  apps|status) : ;;
  tree)
    pid="${1:?usage: ui tree <pid> [--depth N]}"; shift || true
    while [ $# -gt 0 ]; do
      case "$1" in --depth) depth="${2:-12}"; shift 2 ;; *) shift ;; esac
    done ;;
  click)
    pid="${1:?usage: ui click <pid> <ref> | ui click <pid> --at x,y}"; shift || true
    case "${1:-}" in
      --at) at="${2:?--at needs x,y}" ;;
      "")   echo "ui: потрібен ref із дерева або --at x,y" >&2; exit 1 ;;
      *)    ref="$1" ;;
    esac ;;
  type)
    pid="${1:?usage: ui type <pid> <ref|-> <text…>}"; shift || true
    ref="${1:?usage: ui type <pid> <ref|-> <text…>}"; shift || true
    [ "$ref" = "-" ] && ref=""
    text="$*"
    [ -n "$text" ] || { echo "ui: нема що вводити" >&2; exit 1; } ;;
  key)
    pid="${1:?usage: ui key <pid> <keys>}"; shift || true
    keys="${1:?usage: ui key <pid> <keys>}" ;;
  menu)
    pid="${1:?usage: ui menu <pid> <Menu/Item>}"; shift || true
    mpath="$*"
    [ -n "$mpath" ] || { echo "ui: нема шляху меню" >&2; exit 1; } ;;
  *)
    echo "ui: невідома дія «${action}»" >&2; usage >&2; exit 1 ;;
esac

if [ -n "$pid" ]; then
  case "$pid" in
    ''|*[!0-9]*) echo "ui: pid має бути числом, а не «${pid}»" >&2; exit 1 ;;
  esac
fi

ID="ui-$$-$(date +%s%N 2>/dev/null || date +%s)"
REQ="$REQ_DIR/$ID.json"
DONE="$REQ_DIR/$ID.done"
rm -f "$DONE" 2>/dev/null

jq -nc --arg action "$action" --arg ref "$ref" --arg at "$at" --arg text "$text" \
       --arg keys "$keys" --arg path "$mpath" \
       --argjson pid "${pid:-null}" --argjson depth "${depth:-null}" '
  {action: $action}
  + (if $pid   == null then {} else {pid: $pid}     end)
  + (if $depth == null then {} else {depth: $depth} end)
  + (if $ref   == ""   then {} else {ref: $ref}     end)
  + (if $at    == ""   then {} else {at: $at}       end)
  + (if $text  == ""   then {} else {text: $text}   end)
  + (if $keys  == ""   then {} else {keys: $keys}   end)
  + (if $path  == ""   then {} else {path: $path}   end)' \
  > "$REQ.tmp" 2>/dev/null && mv -f "$REQ.tmp" "$REQ" || {
    echo "ui: не змогли записати запит у $REQ_DIR" >&2; exit 1; }

# Poll in tenths so a click feels immediate; give up after NS_UI_TIMEOUT seconds and say so.
ticks=$(( TIMEOUT * 10 ))
i=0
while [ "$i" -lt "$ticks" ]; do
  if [ -f "$DONE" ]; then
    ok="$(jq -r '.ok // false' "$DONE" 2>/dev/null)"
    if [ "$ok" = "true" ]; then
      jq -r '.result // ""' "$DONE" 2>/dev/null
      rm -f "$REQ" "$DONE" 2>/dev/null
      exit 0
    fi
    echo "ui: $(jq -r '.error // "відмовлено без причини"' "$DONE" 2>/dev/null)" >&2
    rm -f "$REQ" "$DONE" 2>/dev/null
    exit 4
  fi
  sleep 0.1
  i=$((i + 1))
done

rm -f "$REQ" 2>/dev/null
echo "ui: Bulava не відповіла за ${TIMEOUT}с — можливо, вона зайнята або дозвіл не наданий." >&2
exit 5
