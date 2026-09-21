#!/bin/bash
# Stage: turn the director's message into the prompt the worker actually receives.
#
# Composition reads the artifacts of THIS message — never the instance's shared copies — so a
# second message cannot be handed the first one's reasoning while it waits its turn.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

ART=""
while [ $# -gt 0 ]; do
  case "${1:-}" in --art) ART="${2:-}"; shift 2 ;; *) break ;; esac
done
PROJ="${1:?usage: pipeline-compose.sh --art DIR <project> <task...>}"; shift
TASK="$*"
IDIR="${PIPE_IDIR:?pipeline-compose.sh runs as a pipeline stage}"
[ -n "$ART" ] || ART="${PIPE_ART:-$IDIR}"
run_env_load "$IDIR"

compose_task_prompt "$IDIR" "$TASK" "$ART" > "$ART/composed.txt.tmp" 2>/dev/null \
  && mv -f "$ART/composed.txt.tmp" "$ART/composed.txt" \
  || { rm -f "$ART/composed.txt.tmp" 2>/dev/null
       printf '%s\n' "$TASK" > "$ART/composed.txt"
       echo "$(date '+%F %T') [pipeline] compose failed — falling back to the original message" >> "$SUP_STATE/supervisor.log"; }
[ -s "$ART/composed.txt" ] || printf '%s\n' "$TASK" > "$ART/composed.txt"
exit 0
