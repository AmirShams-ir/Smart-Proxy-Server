#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$BASE_DIR/config/defaults.conf"
mkdir -p "$LOG_DIR"
STATE="$STATE_FILE"
[[ -f "$STATE" ]] || printf '{"active":"","last_switch":0,"profiles":{}}\n' > "$STATE"
PROFILE_ROOT="$PROFILE_DIR"
[[ -d "$PROFILE_ROOT" ]] || PROFILE_ROOT="$BASE_DIR/profile"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
set_state(){ python3 - "$STATE" "$1" "$2" <<'PY'
import json,sys
p,active,last=sys.argv[1],sys.argv[2],int(sys.argv[3])
with open(p,encoding='utf-8') as f: d=json.load(f)
d['active']=active; d['last_switch']=last
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

best_name=""; best_score=-1
shopt -s nullglob
for file in "$PROFILE_ROOT"/*.txt; do
  name="$(basename "$file" .txt)"
  health="$($BASE_DIR/lib/health.sh "$file" 2>/dev/null || true)"
  [[ -n "$health" ]] || { log "$name health=error"; continue; }
  scored="$(printf '%s\n' "$health" | "$BASE_DIR/lib/score.sh")"
  score="$(printf '%s\n' "$scored" | sed -n 's/.*score=\([0-9]*\).*/\1/p')"
  [[ "$score" =~ ^[0-9]+$ ]] || { log "$name score=invalid"; continue; }
  log "$name $health $scored"
  if (( score > best_score )); then best_score=$score; best_name=$name; fi
done
shopt -u nullglob

if [[ "$MODE" == "manual" ]]; then
  [[ -n "$ACTIVE_PROFILE" ]] || { log "manual mode requires ACTIVE_PROFILE"; exit 1; }
  [[ -f "$PROFILE_ROOT/$ACTIVE_PROFILE.txt" ]] || { log "manual profile not found: $ACTIVE_PROFILE"; exit 1; }
  best_name="$ACTIVE_PROFILE"
  log "manual mode active=$best_name"
fi

[[ -n "$best_name" ]] || { log "no usable profiles"; exit 1; }
read -r current last_switch < <(get_state)
if [[ "$MODE" != "manual" && -n "$current" && "$current" != "$best_name" ]]; then
  current_file="$PROFILE_ROOT/$current.txt"
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
    if systemctl is-active --quiet sing-box; then
      systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
    fi
  else
    log "keep $current; candidate=$best_name ($current_score -> $best_score), decision=$decision"
    best_name="$current"
  fi
else
  if [[ "$current" != "$best_name" ]]; then
    set_state "$best_name" "$(date +%s)"
    "$BASE_DIR/lib/generator.sh" "$best_name"
    if systemctl is-active --quiet sing-box; then
      systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
    fi
    log "activate $best_name score=$best_score"
  fi
fi
printf '%s %s\n' "$best_name" "$best_score"
