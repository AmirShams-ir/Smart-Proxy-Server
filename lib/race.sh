#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$BASE_DIR/config/defaults.conf"
mkdir -p "$LOG_DIR"
STATE="$STATE_FILE"
[[ -f "$STATE" ]] || printf '{"active":"","last_switch":0,"profiles":{}}\n' > "$STATE"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
set_state(){ python3 - "$STATE" "$1" "$2" <<'PY'
import json,sys
p,active,last=sys.argv[1],sys.argv[2],int(sys.argv[3]); d=json.load(open(p))
d['active']=active; d['last_switch']=last
json.dump(d,open(p,'w'),indent=2); open(p,'a').write('\n')
PY
}
get_state(){ python3 - "$STATE" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1])); print(d.get('active',''), d.get('last_switch',0))
except Exception: print('',0)
PY
}

best_name=""; best_score=-1
for file in "$BASE_DIR"/profile/*.txt; do
  [[ -f "$file" ]] || continue
  name="$(basename "$file" .txt)"
  health="$($BASE_DIR/lib/health.sh "$file" 2>/dev/null || true)"
  [[ -n "$health" ]] || { log "$name health=error"; continue; }
  scored="$(printf '%s\n' "$health" | "$BASE_DIR/lib/score.sh")"
  score="$(printf '%s\n' "$scored" | sed -n 's/.*score=\([0-9]*\).*/\1/p')"
  [[ "$score" =~ ^[0-9]+$ ]] || { log "$name score=invalid"; continue; }
  log "$name $health $scored"
  if (( score > best_score )); then best_score=$score; best_name=$name; fi
done

[[ -n "$best_name" ]] || { log "no healthy profiles"; exit 1; }
read -r current last_switch < <(get_state)
if [[ "$MODE" == "manual" && -n "$ACTIVE_PROFILE" ]]; then
  best_name="$ACTIVE_PROFILE"; log "manual mode active=$best_name"
elif [[ -n "$current" && "$current" != "$best_name" ]]; then
  # Compare the current profile score to the candidate score before switching.
  current_file="$BASE_DIR/profile/$current.txt"
  current_score=0
  if [[ -f "$current_file" ]]; then
    h="$($BASE_DIR/lib/health.sh "$current_file" 2>/dev/null || true)"
    if [[ -n "$h" ]]; then current_score="$(printf '%s\n' "$h" | "$BASE_DIR/lib/score.sh" | sed -n 's/.*score=\([0-9]*\).*/\1/p')"; fi
  fi
  decision="$($BASE_DIR/lib/hysteresis.sh "$current_score" "$best_score" "$(date +%s)" "$last_switch")"
  if [[ "$decision" == switch ]]; then
    log "switch $current -> $best_name ($current_score -> $best_score)"
    set_state "$best_name" "$(date +%s)"
    "$BASE_DIR/lib/generator.sh" "$best_name"
    systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
  else
    log "keep $current; candidate=$best_name ($current_score -> $best_score), decision=$decision"
    best_name="$current"
  fi
else
  if [[ "$current" != "$best_name" ]]; then
    set_state "$best_name" "$(date +%s)"
    "$BASE_DIR/lib/generator.sh" "$best_name"
    systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
    log "activate $best_name score=$best_score"
  fi
fi
printf '%s %s\n' "$best_name" "$best_score"
