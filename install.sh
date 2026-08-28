#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=/dev/null
source lib/common.sh

start_log
banner
require_root
require_os

info "Installing Smart Proxy Server v${VERSION}..."

apt update
apt install -y curl ca-certificates iputils-ping python3 jq

if ! command -v sing-box >/dev/null 2>&1; then
  ARCH=$(dpkg --print-architecture)

  case "$ARCH" in
    armhf)  RELEASE_ARCH="arm"; DEB_ARCH="armhf" ;;
    arm64)  RELEASE_ARCH="arm64"; DEB_ARCH="arm64" ;;
    amd64)  RELEASE_ARCH="amd64"; DEB_ARCH="amd64" ;;
    *)
      error "Unsupported Debian architecture: $ARCH"
      ;;
  esac

  info "Installing sing-box for $ARCH..."

  RELEASE_JSON=$(curl -fsSL --retry 3 --connect-timeout 15 \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest) \
    || error "Unable to query latest sing-box release."

  VERSION=$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name // empty')
  [ -n "$VERSION" ] || error "Unable to determine latest sing-box version."

  ASSET_URL=$(printf '%s' "$RELEASE_JSON" | jq -r --arg arch "$DEB_ARCH" '
    .assets[]
    | select(.name | endswith("_linux_" + $arch + ".deb"))
    | .browser_download_url
  ' | head -n1)

  if [ -z "$ASSET_URL" ]; then
    # Fall back to the official tarball when no Debian package is published.
    TARBALL_URL=$(printf '%s' "$RELEASE_JSON" | jq -r --arg arch "$RELEASE_ARCH" '
      .assets[]
      | select(.name == ("sing-box-" + (.tag_name // "") + "-linux-" + $arch + ".tar.gz"))
      | .browser_download_url
    ' | head -n1)

    [ -n "$TARBALL_URL" ] || error "No sing-box asset found for $ARCH ($RELEASE_ARCH)."

    TARBALL="/tmp/sing-box.tar.gz"
    TMP_DIR="/tmp/sing-box-install"
    rm -rf "$TMP_DIR" "$TARBALL"
    mkdir -p "$TMP_DIR"

    curl -fL --retry 3 --connect-timeout 15 -o "$TARBALL" "$TARBALL_URL" \
      || error "Failed to download sing-box archive."
    tar -tzf "$TARBALL" >/dev/null \
      || error "Downloaded sing-box archive is corrupted."
    tar -xzf "$TARBALL" -C "$TMP_DIR"

    SING_BOX_BIN=$(find "$TMP_DIR" -type f -name sing-box -perm -u+x -print -quit)
    [ -n "$SING_BOX_BIN" ] || error "sing-box binary not found in archive."

    install -m 755 "$SING_BOX_BIN" /usr/local/bin/sing-box
    rm -rf "$TMP_DIR" "$TARBALL"
  else
    DEB="/tmp/sing-box.deb"
    rm -f "$DEB"

    curl -fL --retry 3 --connect-timeout 15 -o "$DEB" "$ASSET_URL" \
      || error "Failed to download sing-box Debian package."

    dpkg-deb --info "$DEB" >/dev/null 2>&1 \
      || error "Downloaded sing-box Debian package is corrupted."

    dpkg -i "$DEB" \
      || error "Failed to install sing-box Debian package."
    rm -f "$DEB"
  fi
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
info "Smart Proxy Server v2.0.2 installation completed."
