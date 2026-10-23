#!/bin/bash
# Jev — TypeSafe's "System One" classifier — for the one decision measurement showed it pays for:
# whether a message that reaches a task after a pause, or as the first one after the run was
# restarted, starts a different task or continues the one the conversation is on.
#
# Before it, that decision was structural. A restarted run has no record of its task (the record
# lived in the run folder, which stop and the idle teardown take away), so the next message was a
# new task by definition — and "the ticket was updated, check it" paid for a whole preparation: two
# positions, an alignment, Codex research. Over three weeks of real chats that was 13 messages and
# 4.4M Codex tokens. Jev reads the task, what Claude last said and the message, and answers in a
# quarter of a second; on 16 real pairs it was right 15 times and unsure once, never wrong.
#
# Off unless the director turns it on (Settings → Jev, or `jev.sh mode on`), and nothing happens
# without a key in the Keychain. When it is off, has no key, is unsure or cannot be reached, the
# engine decides exactly as it did before Jev. The message, the task's goal and Claude's last reply
# go to TypeSafe's API in the US — a separate paid account, which is why it is never on by default.
#
# Modes: off (default) · shadow (Jev is asked and its answer logged; the old rule decides) · on.
#
# Sourced by supervisor-lib.sh. The defaults are in supervisor/config.sh.

JEV_KEYCHAIN_SERVICE="TypeSafe Jev"
JEV_P=""; JEV_VERDICT=""; JEV_MODEL=""; JEV_TOKENS=0; JEV_SECONDS=""; JEV_ERR=""; JEV_HTTP=""
JEV_KEYCHAIN_ACCOUNT="api-key"
JEV_POINTS_ALL="relation"

_jev_setting() {   # $1 = state file name  $2 = environment value  $3 = default
  local v
  v="$(tr -d '[:space:]' 2>/dev/null < "$SUP_STATE/$1")"
  [ -n "$v" ] || v="${2:-}"
  [ -n "$v" ] || v="$3"
  printf '%s' "$v"
}

jev_mode() {
  local m; m="$(_jev_setting jev-mode "${SUPERVISOR_JEV_MODE:-}" off)"
  case "$m" in off|shadow|on) printf '%s' "$m" ;; *) printf 'off' ;; esac
}

jev_points() { _jev_setting jev-points "${SUPERVISOR_JEV_POINTS:-}" "$JEV_POINTS_ALL"; }

# The key is read from the Keychain on demand and kept in this process only. It is never an
# environment variable of anything the engine starts — TYPESAFE_API_KEY is on the list of paid-API
# variables stripped from every child — and never an argument: curl gets its header on stdin.
JEV_KEY=""
jev_key() {
  [ -n "$JEV_KEY" ] && { printf '%s' "$JEV_KEY"; return 0; }
  local k
  if [ -n "${SUPERVISOR_JEV_KEY_CMD:-}" ]; then
    k="$("$SUPERVISOR_JEV_KEY_CMD" 2>/dev/null)"
  else
    # Bounded: a Keychain that wants a click from nobody must not hold a message up.
    k="$(perl -e 'alarm shift; exec @ARGV' 5 security find-generic-password \
          -s "$JEV_KEYCHAIN_SERVICE" -a "$JEV_KEYCHAIN_ACCOUNT" -w 2>/dev/null)"
  fi
  jev_key_valid "$k" || return 1
  JEV_KEY="$k"
  printf '%s' "$k"
}

jev_key_valid() {   # BSD grep caps a repetition count at 255, so the length is checked apart
  [ "${#1}" -ge 16 ] && [ "${#1}" -le 512 ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._~+/=-]+$'
}

# 0 when this point is to ask Jev at all: a mode other than off, the point listed, a key present.
jev_wants() {   # $1 = point
  [ "$(jev_mode)" != off ] || return 1
  case ",$(jev_points)," in *",$1,"*) ;; *) return 1 ;; esac
  jev_key >/dev/null || return 1
}

# One request. Sets JEV_HTTP, JEV_SECONDS, JEV_MODEL, JEV_TOKENS and, on failure, JEV_ERR.
jev_call() {   # $1 = request body file  $2 = response file  [$3 = seconds]  → 0 with usable answers
  local req="$1" out="$2" t="${3:-$SUPERVISOR_JEV_TIMEOUT}" key w try=0
  JEV_HTTP=""; JEV_SECONDS=""; JEV_MODEL=""; JEV_TOKENS=0; JEV_ERR=""
  jev_key >/dev/null || { JEV_ERR=no-key; return 2; }
  key="$JEV_KEY"
  case "$t" in ''|*[!0-9]*) t="$SUPERVISOR_JEV_TIMEOUT" ;; esac
  [ "$t" -ge 1 ] || { JEV_ERR=no-time; return 1; }
  while :; do
    rm -f "$out" 2>/dev/null || true
    w="$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
         | "${SUPERVISOR_JEV_CURL:-curl}" -sS -K - --max-time "$t" -H 'Content-Type: application/json' \
             --data-binary @"$req" -o "$out" -w '%{http_code} %{time_total}' "$SUPERVISOR_JEV_URL" 2>/dev/null)"
    JEV_HTTP="${w%% *}"; JEV_SECONDS="${w##* }"
    # Rate limited or overloaded: one more try, once, and only inside the time it was given.
    case "$JEV_HTTP" in
      429|529)
        try=$((try + 1))
        t="$(LC_ALL=C awk -v t="$t" -v s="${JEV_SECONDS:-0}" 'BEGIN { r = int(t - s - 1); print (r > 0 ? r : 0) }')"
        [ "$try" -le 1 ] && [ "$t" -ge 1 ] && { sleep 1; continue; } ;;
    esac
    break
  done
  [ "$JEV_HTTP" = 200 ] || { JEV_ERR="http-${JEV_HTTP:-000}"; return 1; }
  jq -e '(.answers | type) == "object"' "$out" >/dev/null 2>&1 || { JEV_ERR=bad-json; return 1; }
  JEV_MODEL="$(jq -r '.model // ""' "$out" 2>/dev/null)"
  JEV_TOKENS="$(jq -r '.usage.input_tokens // 0' "$out" 2>/dev/null)"
  return 0
}

# A probability is a number in [0, 1] — jq may print a small one as 1.2e-05. Anything else is
# "unsure": a malformed answer must never read as a confident one.
jev_prob() { LC_ALL=C awk -v p="${1:-}" 'BEGIN { exit !(p ~ /^([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/ && p + 0 <= 1) }'; }

jev_noul() {   # $1 = probability → yes | no | unsure
  jev_prob "${1:-}" || { echo unsure; return 0; }
  LC_ALL=C awk -v p="$1" -v y="$SUPERVISOR_JEV_YES" -v n="$SUPERVISOR_JEV_NO" \
    'BEGIN { if (p + 0 >= y) print "yes"; else if (p + 0 <= n) print "no"; else print "unsure" }'
}

# ---------------------------------------------------------------------------------------- relation
#
# "Does the new message start a different task?" — one Noul, against the task's goal, the last
# thing Claude said to the director and the message itself. Sets JEV_VERDICT (new | continue |
# unsure) and JEV_P — in this shell, not echoed, so the call's model, tokens and time stay readable.
# On any failure it is "unsure", and the caller keeps the old rule.
jev_relation() {   # $1=task goal  $2=Claude's last reply  $3=message  [$4=seconds]
  local tmp req res p
  JEV_P=""; JEV_VERDICT=unsure
  tmp="$(mktemp -d 2>/dev/null)" || return 0
  req="$tmp/req.json"; res="$tmp/res.json"
  jq -n --arg model "$SUPERVISOR_JEV_MODEL" \
     --arg task "$(printf '%s' "${1:-}" | clip_utf8 "$SUPERVISOR_JEV_STATE_BYTES")" \
     --arg reply "$(printf '%s' "${2:-}" | clip_utf8 "$SUPERVISOR_JEV_STATE_BYTES")" \
     --arg msg "$(printf '%s' "${3:-}" | clip_utf8 "$SUPERVISOR_JEV_STATE_BYTES")" \
     '{model:$model,
       state:{task:$task, last_reply_from_the_agent:$reply, new_message:$msg},
       questions:{new_task:{type:"noul",
         instructions:"The new message starts a different task (a different ticket or feature) instead of continuing, checking, fixing, testing or updating the current task."}}}' \
     > "$req" 2>/dev/null
  if ! jev_call "$req" "$res" "${4:-$SUPERVISOR_JEV_RELATION_TIMEOUT}"; then
    rm -rf "$tmp"; return 0
  fi
  p="$(jq -r '.answers.new_task.noul // ""' "$res" 2>/dev/null)"
  rm -rf "$tmp"
  JEV_P="$p"
  case "$(jev_noul "$p")" in yes) JEV_VERDICT=new ;; no) JEV_VERDICT=continue ;; esac
  return 0
}

# One line per decision, kept beside the state rather than in a run folder that will be taken away:
# this is what shadow mode is read from. Never the key, never the text of the message or the task.
jev_relation_note() {   # $1=case  $2=verdict  $3=applied  $4=thread id  $5=message id
  local d="$SUP_STATE/jev"
  mkdir -p "$d" 2>/dev/null || return 0
  jq -nc --arg ts "$(date '+%F %T')" --arg case "$1" --arg mode "$(jev_mode)" --arg verdict "$2" \
     --arg applied "$3" --arg p "${JEV_P:-}" --arg model "${JEV_MODEL:-}" --arg err "${JEV_ERR:-}" \
     --arg s "${JEV_SECONDS:-}" --argjson tok "${JEV_TOKENS:-0}" --arg tid "$4" --arg mid "$5" \
     '{ts:$ts, point:"relation", case:$case, mode:$mode, verdict:$verdict, applied:$applied,
       p:($p | tonumber? // null), model:$model, error:$err, seconds:($s | tonumber? // null),
       input_tokens:$tok, thread_id:$tid}
      + (if $mid == "" then {} else {message_id:$mid} end)' >> "$d/relation.jsonl" 2>/dev/null || true
  rotate_log "$d/relation.jsonl" 2>/dev/null || true
}

# The relation a message gets when the old rule would have guessed — after a restart, after a
# settled task, after hours of silence — or nothing, when the old rule is to stand. Printed as
# "<relation> <thread id it was decided against>". Called before the task record is locked: the
# network must not hold the lock other senders break after ten seconds. thread_bind applies it only
# if the record still holds that task when it takes the lock; otherwise the old rule decides there.
#
#   carried   the record came back with a resumed run (thread-carry.sh); the old engine had no
#             record here and opened a new task — so unsure means "new", as before
#   settled   the task has a declared result; the old rule was the regex — unsure leaves it to it
#   idle      open, but nobody has written to it for SUPERVISOR_TASK_IDLE_NEW_SECS; same
jev_relation_for() {   # $1=instance dir  $2=message  [$3=message id] → "new|continue <thread id>" | (nothing)
  local idir="${1:-}" msg="${2:-}" mid="${3:-}" state case tid obj reply verdict out="" last idle mode
  state="$(thread_state "$idir")"
  case "$state" in open|settled) ;; *) return 0 ;; esac
  if ! jev_wants relation; then
    # Switched off, or the key went, after the record came back: the old engine had no record here.
    [ -n "$(thread_get "$idir" '.carried_at')" ] && printf 'new %s' "$(thread_get "$idir" '.thread_id')"
    return 0
  fi
  if [ -n "$(thread_get "$idir" '.carried_at')" ]; then
    case=carried
  elif [ "$state" = settled ]; then
    case=settled
  else
    last="$(thread_get "$idir" '.last_message_at')"
    case "$last" in ''|*[!0-9]*) return 0 ;; esac
    idle=$(( $(date +%s) - last ))
    [ "$idle" -ge "${SUPERVISOR_TASK_IDLE_NEW_SECS:-21600}" ] || return 0
    case=idle
  fi
  tid="$(thread_get "$idir" '.thread_id')"
  obj="$(thread_get "$idir" '.objective')"
  # What Claude said last, from its own transcript; the copy kept with a carried task only when the
  # transcript cannot be found — it is a snapshot, and stale the moment the conversation moves on.
  reply="$(claude_last_reply "$idir" 2>/dev/null || true)"
  [ -n "$reply" ] || reply="$(cat "$idir/carried-last-reply.txt" 2>/dev/null)"
  jev_relation "$obj" "$reply" "$msg"; verdict="$JEV_VERDICT"
  mode="$(jev_mode)"
  case "$mode:$verdict" in
    on:new)      out=new ;;
    on:continue) out=continue ;;
    *)           [ "$case" = carried ] && out=new ;;
  esac
  jev_relation_note "$case" "$verdict" "${out:-old-rule}" "$tid" "$mid"
  [ -n "$out" ] && printf '%s %s' "$out" "$tid"
  return 0
}
