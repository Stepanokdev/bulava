#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"

cmd="${1:-list}"; shift 2>/dev/null || true
case "$cmd" in
  list) exec python3 "$BIN_DIR/lib/mcp-inventory.py" "$@" ;;
  *)    echo "usage: mcp.sh list [--json] [--fast] [--timeout=SECONDS]" >&2; exit 1 ;;
esac
