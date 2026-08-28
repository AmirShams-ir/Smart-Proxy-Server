#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$BASE_DIR/config/defaults.conf"

profile="$1"
file="$PROFILE_DIR/$profile.txt"
[ -f "$file" ] || file="$BASE_DIR/profile/$profile.txt"
[ -f "$file" ] || { echo "profile not found: $profile" >&2; exit 2; }
uri="$(head -n1 "$file" | tr -d '\r')"
python3 - "$uri" "$CONFIG_FILE" "$profile" "$SOCKS_LISTEN" "$SOCKS_PORT" <<'PY'
import json
import sys
from urllib.parse import urlparse, parse_qs, unquote

uri, out, name, socks_listen, socks_port = sys.argv[1:]
p = urlparse(uri)
q = parse_qs(p.query)
server = p.hostname
port = p.port or 443
user = unquote(p.username or '')

def first(key, default=''):
    return q.get(key, [default])[0]

if not server:
    raise SystemExit('invalid profile: missing server')

if p.scheme == 'vless':
    ob = {"type": "vless", "tag": name, "server": server, "server_port": port, "uuid": user}
    if first('encryption') == 'none':
        ob['packet_encoding'] = 'xudp'
elif p.scheme == 'trojan':
    ob = {"type": "trojan", "tag": name, "server": server, "server_port": port, "password": user}
else:
    raise SystemExit(f'unsupported scheme: {p.scheme}')

if first('security') == 'tls' or first('sni') or first('alpn'):
    tls = {"enabled": True}
    tls['server_name'] = first('sni') or first('host') or server
    if first('alpn'):
        tls['alpn'] = [x for x in first('alpn').split(',') if x]
    if first('fp'):
        tls['utls'] = {"enabled": True, "fingerprint": first('fp')}
    ob['tls'] = tls

transport = first('type')
if transport == 'ws':
    tr = {"type": "ws", "path": unquote(first('path', '/'))}
    host = first('host')
    if host:
        tr['headers'] = {"Host": host}
    ob['transport'] = tr
elif transport == 'grpc':
    tr = {"type": "grpc"}
    service_name = first('serviceName')
    if service_name:
        tr['service_name'] = service_name
    ob['transport'] = tr

cfg = {
  "log": {
    "level": "info",
    "timestamp": True
  },

  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "network": {
        "listen": "0.0.0.0",
        "listen_port": 1080
      }
    }
  ],

  "outbounds": [
    ob,
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],

  "route": {
    "auto_detect_interface": True,
    "rules": [
      {
        "action": "sniff"
      }
    ],
    "final": name
  }
}
with open(out, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PY
chmod 600 "$CONFIG_FILE"
