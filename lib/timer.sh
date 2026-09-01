#!/usr/bin/env bash
# ==============================================================================
# Smart Proxy Server - Systemd Timer Synchronizer
# https://github.com/AmirShams-ir/Smart-Proxy-Server
# Copyright (c) 2026 Amir Shams
# Licensed under Apache-2.0
# ==============================================================================
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_DIR}/lib/common.sh"

require_root

HEALTH_INTERVAL="$(config_get HEALTH_INTERVAL)"
[[ "$HEALTH_INTERVAL" =~ ^[0-9]+([smhdw])$ ]] || fatal "Invalid HEALTH_INTERVAL: ${HEALTH_INTERVAL:-empty}"

TIMER_FILE="/etc/systemd/system/reload.timer"

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Automatic Smart Proxy Reload
After=network-online.target
Wants=network-online.target

[Timer]
OnBootSec=30s
OnUnitActiveSec=${HEALTH_INTERVAL}
AccuracySec=1s
Unit=reload.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable reload.timer >/dev/null
systemctl restart reload.timer

success "reload.timer synchronized to HEALTH_INTERVAL=${HEALTH_INTERVAL}"
