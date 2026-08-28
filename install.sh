#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source lib/common.sh
require_root
info "Installing Smart Proxy Server v2.0.1..."
apt update
apt install -y curl ca-certificates iputils-ping python3
if ! command -v sing-box >/dev/null 2>&1; then
  bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

install -d -m 755 /opt/smart-proxy /etc/sing-box /etc/sing-box/profiles /var/log/smartproxy
cp -a . /opt/smart-proxy
install -m 644 config/defaults.conf /etc/sing-box/defaults.conf
install -m 644 config/state.json /etc/sing-box/proxy-state.json
cp -a profile/. /etc/sing-box/profiles/
install -m 755 lib/*.sh /opt/smart-proxy/lib/
install -m 644 systemd/sing-box.service /etc/systemd/system/sing-box.service
install -m 644 systemd/rearm.service /etc/systemd/system/proxy-rearm.service
install -m 644 systemd/rearm.timer /etc/systemd/system/proxy-rearm.timer
ln -sf /etc/sing-box/defaults.conf /opt/smart-proxy/config/defaults.conf
ln -sf /etc/sing-box/proxy-state.json /opt/smart-proxy/config/state.json

systemctl daemon-reload
if /opt/smart-proxy/lib/race.sh; then
  if ! sing-box check -c /etc/sing-box/config.json; then
    error "Generated sing-box configuration is invalid."
  fi
else
  warn "No usable profile was selected during install."
  error "At least one valid profile is required for initial installation."
fi

systemctl enable --now sing-box
systemctl enable --now proxy-rearm.timer
info "Smart Proxy Server v2.0.1 installation completed."
