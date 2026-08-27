#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$BASE_DIR/config/defaults.conf"
SERVICE=sing-box
check_singbox(){ sing-box check -c "$CONFIG_FILE"; }
reload_singbox(){ systemctl reload "$SERVICE" 2>/dev/null || systemctl restart "$SERVICE"; }
restart_singbox(){ systemctl restart "$SERVICE"; }
enable_singbox(){ systemctl enable --now "$SERVICE"; }
status_singbox(){ systemctl --no-pager status "$SERVICE"; }
