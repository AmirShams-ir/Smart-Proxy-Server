#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source lib/common.sh
require_root
info "Installing Smart Proxy Server v2.0..."
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
sed -i 's#/opt/smart-proxy/lib/race.sh#/opt/smart-proxy/lib/race.sh#' /etc/systemd/system/proxy-rearm.service

# The engine reads operational settings from the deployed config.
ln -sf /etc/sing-box/defaults.conf /opt/smart-proxy/config/defaults.conf
ln -sf /etc/sing-box/proxy-state.json /opt/smart-proxy/config/state.json

systemctl daemon-reload
if ! /opt/smart-proxy/lib/race.sh; then
  warn "No healthy profile was selected during install; sing-box will be configured when a profile becomes healthy."
fi
if [ -f /etc/sing-box/config.json ] && sing-box check -c /etc/sing-box/config.json; then
  systemctl enable --now sing-box
else
  error "No valid generated sing-box configuration is available. Check profile files."
fi
systemctl enable --now proxy-rearm.timer
info "Smart Proxy Server v2.0 installation completed."
