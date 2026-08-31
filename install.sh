#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
source lib/common.sh
start_log
banner
require_root
require_os

info "Installing ${PROJECT} v${VERSION}..."

apt update
apt install -y curl ca-certificates iputils-ping python3 jq coreutils

if ! command -v sing-box >/dev/null 2>&1; then
  ARCH=$(dpkg --print-architecture)
  case "$ARCH" in
    armhf) RELEASE_ARCH="arm"; DEB_ARCH="armhf" ;;
    arm64) RELEASE_ARCH="arm64"; DEB_ARCH="arm64" ;;
    amd64) RELEASE_ARCH="amd64"; DEB_ARCH="amd64" ;;
    *) fatal "Unsupported Debian architecture: $ARCH" ;;
  esac

  info "Installing sing-box for $ARCH..."
  RELEASE_JSON=$(curl -fsSL --retry 3 --connect-timeout 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest) || fatal "Unable to query latest sing-box release."
  RELEASE_TAG=$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name // empty')
  [ -n "$RELEASE_TAG" ] || fatal "Unable to determine latest sing-box version."

  ASSET_URL=$(printf '%s' "$RELEASE_JSON" | jq -r --arg arch "$DEB_ARCH" '.assets[] | select(.name | endswith("_linux_" + $arch + ".deb")) | .browser_download_url' | head -n1)
  if [ -z "$ASSET_URL" ]; then
    TARBALL_URL=$(printf '%s' "$RELEASE_JSON" | jq -r --arg arch "$RELEASE_ARCH" --arg tag "$RELEASE_TAG" '.assets[] | select(.name == ("sing-box-" + $tag + "-linux-" + $arch + ".tar.gz")) | .browser_download_url' | head -n1)
    [ -n "$TARBALL_URL" ] || fatal "No sing-box asset found for $ARCH ($RELEASE_ARCH)."
    TARBALL="/tmp/sing-box.tar.gz"; TMP_DIR="/tmp/sing-box-install"
    rm -rf "$TMP_DIR" "$TARBALL"; mkdir -p "$TMP_DIR"
    curl -fL --retry 3 --connect-timeout 15 -o "$TARBALL" "$TARBALL_URL" || fatal "Failed to download sing-box archive."
    tar -tzf "$TARBALL" >/dev/null || fatal "Downloaded sing-box archive is corrupted."
    tar -xzf "$TARBALL" -C "$TMP_DIR"
    SING_BOX_BIN=$(find "$TMP_DIR" -type f -name sing-box -perm -u+x -print -quit)
    [ -n "$SING_BOX_BIN" ] || fatal "sing-box binary not found in archive."
    install -m 755 "$SING_BOX_BIN" /usr/local/bin/sing-box
    rm -rf "$TMP_DIR" "$TARBALL"
  else
    DEB="/tmp/sing-box.deb"; rm -f "$DEB"
    curl -fL --retry 3 --connect-timeout 15 -o "$DEB" "$ASSET_URL" || fatal "Failed to download sing-box Debian package."
    dpkg-deb --info "$DEB" >/dev/null 2>&1 || fatal "Downloaded sing-box Debian package is corrupted."
    dpkg -i "$DEB" || fatal "Failed to install sing-box Debian package."
    rm -f "$DEB"
  fi
fi

install -d -m 755 /opt/smart-proxy /etc/sing-box /etc/sing-box/profiles /var/log/smartproxy
rm -rf /opt/smart-proxy
cp -a . /opt/smart-proxy
install -m 644 config/defaults.conf /etc/sing-box/defaults.conf
install -m 644 config/state.json /etc/sing-box/proxy-state.json
rm -f /etc/sing-box/profiles/*.txt
cp -f profiles/*.txt /etc/sing-box/profiles/
chmod 600 /etc/sing-box/profiles/*.txt
install -m 755 lib/*.sh /opt/smart-proxy/lib/
install -m 755 reload.sh /opt/smart-proxy/reload.sh
install -m 644 systemd/sing-box.service /etc/systemd/system/sing-box.service
install -m 644 systemd/reload.service /etc/systemd/system/reload.service
install -m 644 systemd/reload.timer /etc/systemd/system/reload.timer
ln -sf /etc/sing-box/defaults.conf /opt/smart-proxy/config/defaults.conf
ln -sf /etc/sing-box/proxy-state.json /opt/smart-proxy/config/state.json
rm -f /etc/sing-box/config.json
systemctl stop sing-box 2>/dev/null || true
systemctl daemon-reload

# Render timer interval from defaults.conf (for example 1h, 2h, 30m).
HEALTH_INTERVAL="$(config_get HEALTH_INTERVAL)"
[[ "$HEALTH_INTERVAL" =~ ^[0-9]+([smhdw])$ ]] || fatal "Invalid HEALTH_INTERVAL: $HEALTH_INTERVAL"
cat > /etc/systemd/system/reload.timer <<EOF
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
systemctl disable --now proxy-rearm.timer 2>/dev/null || true
systemctl disable --now rearm.timer 2>/dev/null || true
systemctl enable --now sing-box
systemctl enable --now reload.timer

if /opt/smart-proxy/lib/race.sh; then
  sing-box check -c /etc/sing-box/config.json || fatal "Generated sing-box configuration is invalid."
else
  fatal "At least one valid profile is required for initial installation."
fi

success "${PROJECT} v${VERSION} installation completed."
