#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$BASE_DIR/config/defaults.conf"

current="${1:-}"; candidate="${2:-}"; now="${3:-$(date +%s)}"; last_switch="${4:-0}"
[[ "$current" =~ ^[0-9]+$ ]] && [[ "$candidate" =~ ^[0-9]+$ ]] || { echo keep; exit 0; }
(( candidate - current >= HYSTERESIS )) || { echo keep; exit 0; }
(( now - last_switch >= COOLDOWN )) && echo switch || echo cooldown
