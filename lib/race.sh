#!/bin/bash
BASE="$(dirname "$0")/.."
source "$BASE/config/defaults.conf"
best=""; bestScore=0
for f in "$BASE"/profile/*.txt; do
  [ -f "$f" ] || continue
  IFS=, read rtt loss <<< "$("$BASE/lib/health.sh" "$f")"
  s=$("$BASE/lib/score.sh" "$rtt" "$loss")
  name=$(basename "$f" .txt)
  echo "$name score=$s"
  if [ $s -gt $bestScore ]; then bestScore=$s; best=$name; fi
done
echo "BEST=$best ($bestScore)"
