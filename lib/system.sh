#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
SERVICE=sing-box
check_singbox(){ sing-box check -c /etc/sing-box/config.json; }
restart_singbox(){ systemctl restart $SERVICE; }
enable_singbox(){ systemctl enable --now $SERVICE; }
status_singbox(){ systemctl --no-pager status $SERVICE; }
