#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/defaults.conf"
mkdir -p "$LOG_DIR"
STATE="$STATE_FILE"
[[ -f "$STATE" ]] || printf '{"active":"","last_switch":0,"profiles":{}}\n' > "$STATE"
PROFILE_ROOT="$PROFILE_DIR"
if [[ ! -d "$PROFILE_ROOT" || -z "$(find "$PROFILE_ROOT" -maxdepth 1 -type f -name '*.txt' -print -quit 2>/dev/null)" ]]; then
  if [[ -d "$BASE_DIR/profiles" ]]; then
    PROFILE_ROOT="$BASE_DIR/profiles"
  elif [[ -d "$BASE_DIR/profile" ]]; then
    PROFILE_ROOT="$BASE_DIR/profile"
  fi
fi

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
set_state(){ python3 - "$STATE" "$1" "$2" <<'PY'
import json,sys
p,active,last=sys.argv[1],sys.argv[2],int(sys.argv[3])
try:
    with open(p,encoding='utf-8') as f: d=json.load(f)
except Exception:
    d={"active":"","last_switch":0,"profiles":{}}
d.setdefault('profiles',{})
d['active']=active
d['last_switch']=last
with open(p,'w',encoding='utf-8') as f:
    json.dump(d,f,indent=2); f.write('\n')
PY
}
get_state(){ python3 - "$STATE" <<'PY'
import json,sys
try:
    with open(sys.argv[1],encoding='utf-8') as f: d=json.load(f)
    print(d.get('active',''), d.get('last_switch',0))
except Exception:
    print('',0)
PY
}

RESULT_FILE="${RACE_RESULT_FILE:-}"
best_name=""; best_score=-1; best_rtt=999999; best_jitter=999999; best_success=-1

is_better(){
  awk -v s="$1" -v bs="$2" -v suc="$3" -v bsuc="$4" \
      -v r="$5" -v br="$6" -v j="$7" -v bj="$8" \
      -v n="$9" -v bn="${10}" 'BEGIN {
    if (s != bs) exit !(s > bs)
    if (suc != bsuc) exit !(suc > bsuc)
    if (r != br) exit !(r < br)
    if (j != bj) exit !(j < bj)
    if (bn == "") exit 0
    exit !(n < bn)
  }'
}

if [[ -n "$RESULT_FILE" && -f "$RESULT_FILE" ]]; then
  while IFS='|' read -r name host port rtt jitter loss success score; do
    [[ -n "${name:-}" ]] || continue
    [[ "$score" =~ ^[0-9]+$ ]] || continue
    [[ "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || rtt=999999
    [[ "$jitter" =~ ^[0-9]+([.][0-9]+)?$ ]] || jitter=999999
    [[ "$success" =~ ^[0-9]+([.][0-9]+)?$ ]] || success=-1
    log "$name host=$host port=$port rtt=$rtt jitter=$jitter loss=$loss success=$success score=$score (reused-result)"
    if is_better "$score" "$best_score" "$success" "$best_success" "$rtt" "$best_rtt" "$jitter" "$best_jitter" "$name" "$best_name"; then
      best_score="$score"; best_name="$name"; best_rtt="$rtt"; best_jitter="$jitter"; best_success="$success"
    fi
  done < "$RESULT_FILE"
else
  shopt -s nullglob
  mapfile -t profiles < <(find "$PROFILE_ROOT" -maxdepth 1 -type f -name '*.txt' | sort)
  shopt -u nullglob
  for file in "${profiles[@]}"; do
    name="$(basename "$file" .txt)"
    health="$($BASE_DIR/lib/health.sh "$file" 2>/dev/null || true)"
    [[ -n "$health" ]] || { log "$name health=error"; continue; }
    scored="$(printf '%s\n' "$health" | "$BASE_DIR/lib/score.sh")"
    score="$(printf '%s\n' "$scored" | sed -n 's/.*score=\([0-9]*\).*/\1/p')"
    rtt="$(printf '%s\n' "$health" | sed -n 's/.* rtt=\([^ ]*\).*/\1/p')"
    jitter="$(printf '%s\n' "$health" | sed -n 's/.* jitter=\([^ ]*\).*/\1/p')"
    success="$(printf '%s\n' "$health" | sed -n 's/.* success=\([^ ]*\).*/\1/p')"
    [[ "$score" =~ ^[0-9]+$ ]] || continue
    log "$name $health $scored"
    if is_better "$score" "$best_score" "$success" "$best_success" "$rtt" "$best_rtt" "$jitter" "$best_jitter" "$name" "$best_name"; then
      best_score="$score"; best_name="$name"; best_rtt="$rtt"; best_jitter="$jitter"; best_success="$success"
    fi
  done
fi

if [[ "$MODE" == "manual" ]]; then
  manual_file="$(find "$PROFILE_ROOT" -maxdepth 1 -type f -name '*.txt' | sort | head -n1)"
  [[ -n "$manual_file" ]] || { log "manual mode: no profile found"; exit 1; }
  best_name="$(basename "$manual_file" .txt)"
  log "manual mode active=$best_name"
fi

[[ -n "$best_name" ]] || { log "no usable profiles in $PROFILE_ROOT"; exit 1; }
read -r current last_switch < <(get_state)

if [[ "$MODE" != "manual" && -n "$current" && "$current" != "$best_name" ]]; then
  current_score=0
  if [[ -n "$RESULT_FILE" && -f "$RESULT_FILE" ]]; then
    current_score="$(awk -F'|' -v n="$current" '$1==n {print $8; exit}' "$RESULT_FILE")"
  else
    current_file="$PROFILE_ROOT/$current.txt"
    if [[ -f "$current_file" ]]; then
      h="$($BASE_DIR/lib/health.sh "$current_file" 2>/dev/null || true)"
      if [[ -n "$h" ]]; then current_score="$(printf '%s\n' "$h" | "$BASE_DIR/lib/score.sh" | sed -n 's/.*score=\([0-9]*\).*/\1/p')"; fi
    fi
  fi
  [[ "$current_score" =~ ^[0-9]+$ ]] || current_score=0
  decision="$($BASE_DIR/lib/hysteresis.sh "$current_score" "$best_score" "$(date +%s)" "$last_switch")"
  if [[ "$decision" == switch ]]; then
    log "switch $current -> $best_name ($current_score -> $best_score)"
    set_state "$best_name" "$(date +%s)"
    "$BASE_DIR/lib/generator.sh" "$best_name"
    if systemctl is-active --quiet sing-box; then systemctl reload sing-box 2>/dev/null || systemctl restart sing-box; fi
  else
    log "keep $current; candidate=$best_name ($current_score -> $best_score), decision=$decision"
    best_name="$current"; best_score="$current_score"
  fi
else
  if [[ "$current" != "$best_name" ]]; then
    set_state "$best_name" "$(date +%s)"
    "$BASE_DIR/lib/generator.sh" "$best_name"
    if systemctl is-active --quiet sing-box; then systemctl reload sing-box 2>/dev/null || systemctl restart sing-box; fi
    log "activate $best_name score=$best_score"
  fi
fi
printf '[ACTIVE] %s  score=%s\n' "$best_name" "$best_score"
