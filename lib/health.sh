#!/bin/bash
source "$(dirname "$0")/../config/defaults.conf"
profile="$1"
host=$(grep -o '@[^:]*' "$profile" | tr -d '@')
rtt=$(ping -c ${PING_COUNT} -W ${TIMEOUT} "$host" 2>/dev/null|awk -F'/' '/rtt/{print int($5)}')
loss=$(ping -c ${PING_COUNT} -W ${TIMEOUT} "$host" 2>/dev/null|awk -F', ' '/packet loss/{gsub("%","");print int($3)}')
echo "${rtt:-999},${loss:-100}"
