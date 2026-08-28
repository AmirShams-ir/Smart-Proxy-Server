#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source lib/common.sh
require_root
info "Installing Smart Proxy Server v2.0.1..."
apt update
apt install -y curl ca-certificates iputils-ping python3 jq

if ! command -v sing-box >/dev/null 2>&1; then
  ARCH=$(dpkg --print-architecture)

  case "$ARCH" in
    armhf)  PKG_ARCH="armv7" ;;
    arm64)  PKG_ARCH="arm64" ;;
    amd64)  PKG_ARCH="amd64" ;;
    *)
      error "Unsupported architecture: $ARCH"
      ;;
  esac

  info "Installing sing-box for $ARCH..."

  VERSION=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)

  DEB="/tmp/sing-box.deb"
  URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${PKG_ARCH}.deb"

  curl -fL --retry 3 --connect-timeout 15 -o "$DEB" "$URL"

  dpkg-deb --info "$DEB" >/dev/null 2>&1 || error "Downloaded sing-box package is corrupted."

  dpkg -i "$DEB"
  rm -f "$DEB"
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
