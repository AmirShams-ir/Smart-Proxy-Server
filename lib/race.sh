#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/defaults.conf"
mkdir -p "$LOG_DIR"
STATE="$STATE_FILE"
[[ -f "$STATE" ]] || printf '{"active":"","last_switch":0,"profiles":{}}\n' > "$STATE"
PROFILE_ROOT="$PROFILE_DIR"
if [[ ! -d "$PROFILE_ROOT" || -z "$(find "$PROFILE_ROOT" -maxdepth 1 -type f -name '*.txt' -print -quit)" ]]; then
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

# When called from reload.sh, consume its already-tested result set. This keeps
# reporting and the actual race decision on exactly the same measurements.
RESULT_FILE="${RACE_RESULT_FILE:-}"
best_name=""; best_score=-1; best_rtt=999999; best_jitter=999999; best_success=-1

if [[ -n "$RESULT_FILE" && -f "$RESULT_FILE" ]]; then
  while IFS='|' read -r name host rtt jitter loss success score; do
    [[ -n "${name:-}" ]] || continue
    [[ "$score" =~ ^[0-9]+$ ]] || continue
    [[ "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || rtt=999999
    [[ "$jitter" =~ ^[0-9]+([.][0-9]+)?$ ]] || jitter=999999
    [[ "$success" =~ ^[0-9]+([.][0-9]+)?$ ]] || success=-1
    log "$name host=$host rtt=$rtt jitter=$jitter loss=$loss success=$success score=$score (reused-result)"
    is_better="$(awk -v s="$score" -v bs="$best_score" \
      -v suc="$success" -v bsuc="$best_success" \
      -v r="$rtt" -v br="$best_rtt" \
      -v j="$jitter" -v bj="$best_jitter" 'BEGIN {
        if (s > bs) { print 1; exit }
        if (s < bs) { print 0; exit }
        if (suc > bsuc) { print 1; exit }
        if (suc < bsuc) { print 0; exit }
        if (r < br) { print 1; exit }
        if (r > br) { print 0; exit }
        if (j < bj) { print 1; exit }
        print 0
      }')"
    if [[ "$is_better" == "1" ]]; then
      best_score=$score; best_name=$name; best_rtt=$rtt; best_jitter=$jitter; best_success=$success
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
    is_better="$(awk -v s="$score" -v bs="$best_score" -v suc="$success" -v bsuc="$best_success" -v r="$rtt" -v br="$best_rtt" -v j="$jitter" -v bj="$best_jitter" 'BEGIN {if(s>bs)exit 0;if(s<bs)exit 1;if(suc>bsuc)exit 0;if(suc<bsuc)exit 1;if(r<br)exit 0;if(r>br)exit 1;if(j<bj)exit 0;exit 1}')"
    if [[ "$is_better" == "1" ]]; then best_score=$score; best_name=$name; best_rtt=$rtt; best_jitter=$jitter; best_success=$success; fi
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
    current_score="$(awk -F'|' -v n="$current" '$1==n {print $7; exit}' "$RESULT_FILE")"
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
    best_name="$current"
    best_score="$current_score"
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
