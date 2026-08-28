#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$BASE_DIR/config/defaults.conf"

# Runtime profiles are deployed to PROFILE_DIR. Keep source-tree fallback
# for direct development runs before installation.
PROFILE_ROOT="$PROFILE_DIR"
if [[ ! -d "$PROFILE_ROOT" ]]; then
  PROFILE_ROOT="$BASE_DIR/profile"
fi

current="${1:-}"; candidate="${2:-}"; now="${3:-$(date +%s)}"; last_switch="${4:-0}"
[[ "$current" =~ ^[0-9]+$ ]] && [[ "$candidate" =~ ^[0-9]+$ ]] || { echo keep; exit 0; }
(( candidate - current >= HYSTERESIS )) || { echo keep; exit 0; }
(( now - last_switch >= COOLDOWN )) && echo switch || echo cooldown
