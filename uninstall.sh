#!/usr/bin/env bash
set -e
systemctl disable --now sing-box 2>/dev/null || true
rm -f /etc/systemd/system/sing-box.service
rm -rf /etc/sing-box
systemctl daemon-reload
echo "Smart Proxy Server removed."
