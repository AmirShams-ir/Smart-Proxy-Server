#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
source lib/common.sh
require_root
info "Installing Smart Proxy Server..."
apt update
apt install -y curl wget ca-certificates
if ! command -v sing-box >/dev/null; then
  bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi
mkdir -p /etc/sing-box
install -m 644 /config/config.json /etc/sing-box/config.json
install -m 644 /systemd/sing-box.service /etc/systemd/system/sing-box.service
systemctl daemon-reload
systemctl enable sing-box
if sing-box check -c /etc/sing-box/config.json; then
  systemctl restart sing-box
  info "Installation completed."
else
  error "Configuration validation failed."
fi
