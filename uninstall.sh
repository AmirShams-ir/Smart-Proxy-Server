#!/usr/bin/env bash
# ==============================================================================
# Smart Proxy Server - Uninstaller
# https://github.com/AmirShams-ir/Smart-Proxy-Server
# Copyright (c) 2026 Amir Shams
# Licensed under Apache-2.0
# ==============================================================================
set -Eeuo pipefail

systemctl disable --now reload.timer 2>/dev/null || true
systemctl disable --now reload.service 2>/dev/null || true
systemctl disable --now sing-box 2>/dev/null || true

rm -f /etc/systemd/system/reload.timer
rm -f /etc/systemd/system/reload.service
rm -f /etc/systemd/system/sing-box.service

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

rm -rf /etc/sing-box
rm -rf /opt/smart-proxy

printf 'Smart Proxy Server removed.\n'
printf 'Repository checkout was not removed.\n'
