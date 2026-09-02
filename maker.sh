#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Smart Proxy Server - Proxy Maker
# Stage 2 of the Intelligence Proxy Engine.
#
# Input:
#   templates/*.conf  - [worker] + [vless] + [trojan]
#   cache/edges.csv   - scanner output containing ONLY an `ip` column
#
# Output:
#   cache/generated/*.json
#
# The maker expands only protocol-local combinations. It performs no network
# tests and never benchmarks traffic.
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
require_cmd wc

[[ -d "$TEMPLATE_DIR" ]] || fatal "Missing template directory: $TEMPLATE_DIR"
[[ -f "$EDGE_FILE" ]] || fatal "Missing scanner output: $EDGE_FILE"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

python3 - "$TEMPLATE_DIR" "$EDGE_FILE" "$OUTPUT_DIR" <<'PY'
import csv
import itertools
import ipaddress
import json
import re
import sys
from pathlib import Path

TEMPLATE_DIR = Path(sys.argv[1])
EDGE_FILE = Path(sys.argv[2])
OUTPUT_DIR = Path(sys.argv[3])

BOOLS = {"true": True, "false": False}


def split_values(value: str):
    return [x.strip() for x in value.split(',') if x.strip()]


def get(cfg, key, default=""):
    return cfg.get(key, default).strip()


def bool_value(v, default=False):
    return BOOLS.get(v.strip().lower(), default)


def load_template(path: Path):
    sections = {}
    section = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or line.startswith(';'):
            continue
        m = re.fullmatch(r'\[([^]]+)\]', line)
        if m:
            section = m.group(1).strip().lower()
            sections.setdefault(section, {})
            continue
        if '=' not in line or section is None:
            continue
        key, value = line.split('=', 1)
        sections[section][key.strip()] = value.strip()
    return sections


def load_edges():
    ips = []
    with EDGE_FILE.open(newline='', encoding='utf-8') as fh:
        reader = csv.DictReader(fh)
        if 'ip' not in (reader.fieldnames or []):
            raise ValueError('cache/edges.csv must contain an `ip` column')
        for row in reader:
            raw = (row.get('ip') or '').strip()
            if not raw:
                continue
            try:
                ipaddress.ip_address(raw)
            except ValueError:
                continue
            ips.append(raw)
    return list(dict.fromkeys(ips))


def tls_block(cfg, security):
    if security != 'tls':
        return None
    tls = {'enabled': True}
    sni = get(cfg, 'SNI') or get(cfg, 'Host')
    if sni:
        tls['server_name'] = sni
    fingerprint = get(cfg, 'Fingerprint')
    if fingerprint:
        tls['utls'] = {'enabled': True, 'fingerprint': fingerprint}
    alpn = split_values(get(cfg, 'ALPN'))
    if alpn:
        tls['alpn'] = alpn
    tls['insecure'] = bool_value(get(cfg, 'AllowInsecure'), False)
    return tls


def transport_block(cfg, transport):
    if transport == 'tcp':
        return None
    if transport == 'ws':
        path = split_values(get(cfg, 'WSPath'))
        host = split_values(get(cfg, 'WSHost'))
        out = {'type': 'ws'}
        if path:
            out['path'] = path[0]
        if host:
            out['headers'] = {'Host': host[0]}
        else:
            worker_host = get(cfg, 'Host')
            if worker_host:
                out['headers'] = {'Host': worker_host}
        return out
    if transport == 'grpc':
        names = split_values(get(cfg, 'GRPCServiceName'))
        out = {'type': 'grpc'}
        if names:
            out['service_name'] = names[0]
        return out
    raise ValueError(f'Unsupported transport: {transport}')


def make_vless(cfg, edge, port, transport, security):
    uuid = get(cfg, 'UUID')
    if not uuid:
        return None
    out = {
        'type': 'vless',
        'tag': f"{get(cfg,'Name') or 'worker'}-vless-{edge.replace(':','_')}-{port}-{transport}-{security}",
        'server': edge,
        'server_port': port,
        'uuid': uuid,
        'network': transport,
    }
    flow = get(cfg, 'Flow')
    if flow:
        out['flow'] = flow
    tls = tls_block(cfg, security)
    if tls:
        out['tls'] = tls
    tr = transport_block(cfg, transport)
    if tr:
        out['transport'] = tr
    return out


def make_trojan(cfg, edge, port, transport, security):
    password = get(cfg, 'Password') or get(cfg, 'TrojanPassword')
    if not password:
        return None
    out = {
        'type': 'trojan',
        'tag': f"{get(cfg,'Name') or 'worker'}-trojan-{edge.replace(':','_')}-{port}-{transport}-{security}",
        'server': edge,
        'server_port': port,
        'password': password,
        'network': transport,
    }
    tls = tls_block(cfg, security)
    if tls:
        out['tls'] = tls
    tr = transport_block(cfg, transport)
    if tr:
        out['transport'] = tr
    return out


edges = load_edges()
if not edges:
    raise SystemExit('No valid IP addresses found in cache/edges.csv')

templates = sorted(TEMPLATE_DIR.glob('worker*.conf'))
if not templates:
    templates = sorted(TEMPLATE_DIR.glob('*.conf'))
if not templates:
    raise SystemExit(f'No worker templates found in {TEMPLATE_DIR}')

created = 0
workers_used = 0

for tpl in templates:
    sections = load_template(tpl)
    worker = sections.get('worker', {})
    name = get(worker, 'Name') or tpl.stem

    ports = []
    for raw in split_values(get(worker, 'Ports')):
        try:
            port = int(raw)
            if 1 <= port <= 65535 and port not in ports:
                ports.append(port)
        except ValueError:
            continue
    if not ports:
        warning(f'{tpl.name}: no valid Ports; skipped')
        continue

    protocol_sections = []
    for proto in ('vless', 'trojan'):
        cfg = sections.get(proto)
        if cfg is not None:
            protocol_sections.append((proto, cfg))

    if not protocol_sections:
        warning(f'{tpl.name}: no [vless] or [trojan] section; skipped')
        continue

    workers_used += 1
    info_text = []

    for proto, cfg in protocol_sections:
        transports = list(dict.fromkeys(t.lower() for t in split_values(get(cfg, 'Transport')) if t.lower() in {'tcp', 'ws', 'grpc'}))
        securities = list(dict.fromkeys(s.lower() for s in split_values(get(cfg, 'Security')) if s.lower() in {'tls', 'none'}))

        if not transports or not securities:
            warning(f'{tpl.name} [{proto}]: no valid Transport/Security; skipped')
            continue

        candidates = 0
        skipped_credential = 0
        skipped_invalid = 0

        for edge, port, transport, security in itertools.product(edges, ports, transports, securities):
            if proto == 'trojan' and security != 'tls':
                skipped_invalid += 1
                continue

            if transport == 'ws' and not split_values(get(cfg, 'WSPath')):
                skipped_invalid += 1
                continue
            if transport == 'grpc' and not split_values(get(cfg, 'GRPCServiceName')):
                skipped_invalid += 1
                continue

            outbound = make_vless(cfg, edge, port, transport, security) if proto == 'vless' else make_trojan(cfg, edge, port, transport, security)
            if outbound is None:
                skipped_credential += 1
                continue

            safe = re.sub(r'[^A-Za-z0-9._-]+', '_', str(edge).replace(':', '_'))
            filename = f"{name}_{proto}_{safe}_{port}_{transport}_{security}.json"
            (OUTPUT_DIR / filename).write_text(json.dumps(outbound, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
            created += 1
            candidates += 1

        info_text.append(f'{proto}={candidates}')
        if skipped_credential:
            print(f'[!] {tpl.name} [{proto}]: skipped {skipped_credential} candidates (missing credential)', file=sys.stderr)
        if skipped_invalid:
            print(f'[!] {tpl.name} [{proto}]: skipped {skipped_invalid} unsupported/missing protocol-local parameters', file=sys.stderr)

    info(f'{tpl.name}: ' + ', '.join(info_text) if info_text else f'{tpl.name}: no candidates')

print(f'Generated {created} JSON candidates from {workers_used} worker templates and {len(edges)} edge IPs.')
PY

COUNT="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
success "Maker complete: ${COUNT} JSON candidates written to ${OUTPUT_DIR}"
printf '%s\n' '------------------------------------------------------------'
printf '%-12s %s\n' "Candidates" "$COUNT"
printf '%-12s %s\n' "Templates" "$(find "$TEMPLATE_DIR" -maxdepth 1 -type f -name 'worker*.conf' | wc -l | tr -d ' ')"
printf '%-12s %s\n' "Edges" "$(tail -n +2 "$EDGE_FILE" | grep -c . || true)"
printf '%s\n' '------------------------------------------------------------'
