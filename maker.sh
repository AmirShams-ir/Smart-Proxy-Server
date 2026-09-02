#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Smart Proxy Server - Proxy Maker
# ------------------------------------------------------------------------------
# Stage 2 of the Intelligence Proxy Engine.
#
# Input:
#   templates/*.conf  - one template per Worker
#   cache/edges.csv   - scanner output containing ONLY an `ip` column
#
# Output:
#   cache/generated/*.json
#
# The maker does not test connectivity and does not benchmark traffic. It only
# expands Worker templates into valid sing-box outbound JSON candidates.
# ============================================================================== 

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${BASE_DIR}/templates"
CACHE_DIR="${BASE_DIR}/cache"
EDGE_FILE="${CACHE_DIR}/edges.csv"
OUTPUT_DIR="${CACHE_DIR}/generated"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
info(){ printf '[*] %s\n' "$*"; }
success(){ printf '[✓] %s\n' "$*"; }
warning(){ printf '[!] %s\n' "$*" >&2; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"; }

require_cmd python3
require_cmd find
require_cmd sort
require_cmd mktemp

[[ -d "$TEMPLATE_DIR" ]] || fatal "Missing template directory: $TEMPLATE_DIR"
[[ -f "$EDGE_FILE" ]] || fatal "Missing scanner output: $EDGE_FILE"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

python3 - "$TEMPLATE_DIR" "$EDGE_FILE" "$OUTPUT_DIR" <<'PY'
import csv
import itertools
import json
import re
import sys
from pathlib import Path

TEMPLATE_DIR = Path(sys.argv[1])
EDGE_FILE = Path(sys.argv[2])
OUTPUT_DIR = Path(sys.argv[3])

BOOLS = {"true": True, "false": False}

# sing-box current outbound protocol names relevant to this maker. The official
# outbound list includes vless, vmess, trojan, shadowsocks, tuic, hysteria2,
# shadowtls, anytls, snell and naive among others.
SUPPORTED_TYPES = {
    "vless", "vmess", "trojan", "shadowsocks", "tuic", "hysteria2",
    "shadowtls", "anytls", "snell", "naive"
}

TRANSPORTS = {"tcp", "ws", "grpc", "http", "httpupgrade", "quic"}


def split_values(value: str):
    return [x.strip() for x in value.split(',') if x.strip()]


def get(cfg, key, default=""):
    return cfg.get(key, default).strip()


def bool_value(v, default=False):
    x = v.strip().lower()
    if x in BOOLS:
        return BOOLS[x]
    return default


def int_value(v, default=0):
    try:
        return int(v.strip())
    except Exception:
        return default


def load_template(path: Path):
    cfg = {}
    section = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        m = re.fullmatch(r'\[([^]]+)\]', line)
        if m:
            section = m.group(1).strip().lower()
            continue
        if '=' not in line:
            continue
        k, v = line.split('=', 1)
        key = k.strip()
        cfg[key] = v.strip()
    return cfg


def load_edges():
    ips = []
    with EDGE_FILE.open(newline='', encoding='utf-8') as fh:
        reader = csv.DictReader(fh)
        if 'ip' not in (reader.fieldnames or []):
            raise ValueError('cache/edges.csv must contain an `ip` column')
        for row in reader:
            ip = (row.get('ip') or '').strip()
            if not ip:
                continue
            # The scanner produces IPv4/IPv6 literals. Do not accept arbitrary
            # strings because they would later become invalid sing-box servers.
            import ipaddress
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                continue
            ips.append(ip)
    return list(dict.fromkeys(ips))


def tls_block(cfg):
    security = get(cfg, 'Security').lower()
    if security not in ('tls', 'reality'):
        return None
    tls = {"enabled": True}
    sni = get(cfg, 'SNI') or get(cfg, 'Host')
    if sni:
        tls['server_name'] = sni
    fp = get(cfg, 'Fingerprint')
    if fp:
        tls['utls'] = {"enabled": True, "fingerprint": fp}
    alpn = split_values(get(cfg, 'ALPN'))
    if alpn:
        tls['alpn'] = alpn
    tls['insecure'] = bool_value(get(cfg, 'AllowInsecure'), False)
    if security == 'reality':
        reality = {}
        reality_cfg = get(cfg, 'RealityPublicKey')
        reality_short = get(cfg, 'RealityShortID')
        reality_server = get(cfg, 'RealityServerName')
        if reality_cfg:
            reality['public_key'] = reality_cfg
        if reality_short:
            reality['short_id'] = reality_short
        if reality_server:
            reality['server_name'] = reality_server
        if reality:
            tls['reality'] = reality
    return tls


def transport_block(cfg, transport):
    t = transport.lower()
    if t == 'tcp':
        return None
    if t == 'ws':
        out = {"type": "ws"}
        path = get(cfg, 'WSPath')
        host = get(cfg, 'WSHost') or get(cfg, 'Host')
        if path:
            out['path'] = split_values(path)[0]
        if host:
            out['headers'] = {"Host": split_values(host)[0]}
        return out
    if t == 'grpc':
        name = get(cfg, 'GRPCServiceName')
        out = {"type": "grpc"}
        if name:
            out['service_name'] = split_values(name)[0]
        return out
    if t == 'http':
        out = {"type": "http"}
        host = get(cfg, 'HTTPHost') or get(cfg, 'Host')
        path = get(cfg, 'HTTPPath')
        if host:
            out['host'] = split_values(host)
        if path:
            out['path'] = split_values(path)[0]
        return out
    if t == 'httpupgrade':
        out = {"type": "httpupgrade"}
        host = get(cfg, 'HTTPUpgradeHost') or get(cfg, 'Host')
        path = get(cfg, 'HTTPUpgradePath')
        if host:
            out['host'] = split_values(host)[0]
        if path:
            out['path'] = split_values(path)[0]
        return out
    if t == 'quic':
        return {"type": "quic"}
    raise ValueError(f'Unsupported transport: {transport}')


def dial_fields(cfg):
    # Keep the maker deliberately conservative. Extra dial fields can be added
    # later without changing the scanner/validator contract.
    detour = get(cfg, 'Detour')
    return ({"detour": detour} if detour else {})


def make_outbound(cfg, protocol, edge, port, transport, security, flow):
    host = get(cfg, 'Host')
    uuid = get(cfg, 'UUID')
    sni = get(cfg, 'SNI') or host
    tag = f"{get(cfg,'Name') or 'worker'}-{protocol}-{edge.replace(':','_')}-{port}-{transport}-{security}"

    out = {
        "type": protocol,
        "tag": tag,
        "server": edge,
        "server_port": port,
    }

    if protocol in {'vless', 'vmess', 'tuic'} and uuid:
        out['uuid'] = uuid
    if protocol == 'vless' and flow:
        out['flow'] = flow
    if protocol == 'trojan':
        password = get(cfg, 'TrojanPassword') or get(cfg, 'Password')
        if password:
            out['password'] = password
    if protocol == 'vmess':
        out['security'] = get(cfg, 'VMessSecurity') or 'auto'
        out['alter_id'] = int_value(get(cfg, 'VMessAlterID'), 0)
        out['global_padding'] = bool_value(get(cfg, 'VMessGlobalPadding'), False)
        out['authenticated_length'] = bool_value(get(cfg, 'VMessAuthenticatedLength'), True)
    if protocol == 'shadowsocks':
        method = get(cfg, 'SSMethod')
        password = get(cfg, 'SSPassword') or get(cfg, 'Password')
        if method: out['method'] = method
        if password: out['password'] = password
        plugin = get(cfg, 'SSPlugin')
        if plugin:
            out['plugin'] = plugin
            opts = get(cfg, 'SSPluginOpts')
            if opts: out['plugin_opts'] = opts
    if protocol == 'tuic':
        password = get(cfg, 'TUICPassword') or get(cfg, 'Password')
        if password: out['password'] = password
        out['congestion_control'] = split_values(get(cfg, 'TUICCongestionControl'))[:1][0] if get(cfg, 'TUICCongestionControl') else 'cubic'
        out['udp_relay_mode'] = split_values(get(cfg, 'TUICUDPRelayMode'))[:1][0] if get(cfg, 'TUICUDPRelayMode') else 'native'
        out['udp_over_stream'] = bool_value(get(cfg, 'TUICUDPOverStream'), False)
        out['zero_rtt_handshake'] = bool_value(get(cfg, 'TUICZeroRTT'), False)
        heartbeat = get(cfg, 'TUICHeartbeat')
        if heartbeat: out['heartbeat'] = heartbeat
    if protocol == 'hysteria2':
        password = get(cfg, 'Hysteria2Password') or get(cfg, 'Password')
        if password: out['password'] = password
        out['up_mbps'] = int_value(get(cfg, 'Hysteria2UpMbps'), 100)
        out['down_mbps'] = int_value(get(cfg, 'Hysteria2DownMbps'), 100)
        obfs_type = get(cfg, 'Hysteria2ObfsType')
        obfs_password = get(cfg, 'Hysteria2ObfsPassword')
        if obfs_type:
            obfs = {"type": obfs_type}
            if obfs_password: obfs['password'] = obfs_password
            out['obfs'] = obfs

    network = transport if transport in {'tcp', 'ws', 'grpc', 'http', 'httpupgrade', 'quic'} else None
    if protocol in {'vless', 'vmess', 'trojan', 'shadowsocks', 'tuic', 'hysteria2'} and network:
        # sing-box's protocol-specific fields use network where applicable.
        if protocol not in {'tuic', 'hysteria2'} or network in {'tcp', 'quic'}:
            out['network'] = network

    tls = tls_block({**cfg, 'Security': security, 'SNI': sni})
    if tls:
        out['tls'] = tls

    tr = transport_block(cfg, transport)
    if tr:
        out['transport'] = tr

    pe = get(cfg, 'PacketEncoding')
    if pe and protocol in {'vless', 'vmess'}:
        out['packet_encoding'] = pe

    multiplex = get(cfg, 'Multiplex')
    if bool_value(multiplex, False):
        out['multiplex'] = {"enabled": True}

    out.update(dial_fields(cfg))
    return out


edges = load_edges()
if not edges:
    raise SystemExit('No valid IP addresses found in cache/edges.csv')

templates = sorted(TEMPLATE_DIR.glob('worker*.conf'))
if not templates:
    templates = sorted(TEMPLATE_DIR.glob('*.conf'))
if not templates:
    raise SystemExit(f'No templates found in {TEMPLATE_DIR}')

created = 0
worker_count = 0

for tpl in templates:
    cfg = load_template(tpl)
    name = get(cfg, 'Name') or tpl.stem
    ports = []
    for p in split_values(get(cfg, 'Ports')):
        try:
            n = int(p)
            if 1 <= n <= 65535:
                ports.append(n)
        except ValueError:
            continue
    if not ports:
        print(f'[!] {tpl.name}: no valid Ports; skipped', file=sys.stderr)
        continue

    protocols = [p.lower() for p in split_values(get(cfg, 'Types')) if p.lower() in SUPPORTED_TYPES]
    transports = [t.lower() for t in split_values(get(cfg, 'Transport')) if t.lower() in TRANSPORTS]
    securities = [s.lower() for s in split_values(get(cfg, 'Security')) if s.lower() in {'tls','none','reality'}]
    flows = split_values(get(cfg, 'Flow'))
    if not flows:
        flows = ['']
    if not protocols or not transports or not securities:
        print(f'[!] {tpl.name}: missing valid Types/Transport/Security; skipped', file=sys.stderr)
        continue

    # Empty flow is represented by the literal empty alternative in the config.
    combinations = itertools.product(edges, ports, protocols, transports, securities, flows)
    worker_count += 1
    for edge, port, protocol, transport, security, flow in combinations:
        try:
            outbound = make_outbound(cfg, protocol, edge, port, transport, security, flow)
        except ValueError as exc:
            print(f'[!] {tpl.name}: {exc}', file=sys.stderr)
            continue

        # sing-box requires UUID/password-like fields for several protocols. Do
        # not emit obviously unusable candidates when mandatory credentials are absent.
        if protocol in {'vless', 'vmess', 'tuic'} and not outbound.get('uuid'):
            continue
        if protocol == 'trojan' and not outbound.get('password'):
            continue
        if protocol == 'shadowsocks' and not outbound.get('password'):
            continue
        if protocol == 'hysteria2' and not outbound.get('password'):
            continue

        filename = f"{worker_count:02d}_{protocol}_{edge.replace(':','_')}_{port}_{transport}_{security}"
        if flow:
            filename += f"_{re.sub(r'[^A-Za-z0-9._-]+','_',flow)}"
        path = OUTPUT_DIR / f"{filename}.json"
        path.write_text(json.dumps(outbound, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        created += 1

print(f'Generated {created} JSON candidates from {worker_count} worker templates and {len(edges)} edge IPs.')
PY

COUNT="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
success "Maker complete: ${COUNT} JSON candidates written to ${OUTPUT_DIR}"
printf '%s\n' '------------------------------------------------------------'
printf '%-12s %s\n' "Candidates" "$COUNT"
printf '%-12s %s\n' "Templates" "$(find "$TEMPLATE_DIR" -maxdepth 1 -type f -name '*.conf' | wc -l | tr -d ' ')"
printf '%-12s %s\n' "Edges" "$(tail -n +2 "$EDGE_FILE" | grep -c . || true)"
printf '%s\n' '------------------------------------------------------------'
