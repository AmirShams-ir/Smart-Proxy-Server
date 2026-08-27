#!/bin/bash
BASE="$(dirname "$0")/.."
name=$1
file="$BASE/profile/$name.txt"
uri=$(cat "$file")
cat > "$BASE/config/config.json" <<EOF
{
  "generated_by":"Smarty Proxy",
  "active_profile":"$name",
  "upstream":"$uri"
}
EOF
echo "config.json generated"
