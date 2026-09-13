#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Smart Proxy Server
# Intelligence Proxy Engine
# Stage 2 : Maker
# Author : Amir Shams
# ============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$BASE_DIR/templates"
CACHE_DIR="$BASE_DIR/cache"
EDGE_FILE="$CACHE_DIR/edges.csv"
OUTPUT_DIR="$CACHE_DIR/generated"

fatal(){ printf '[✗] %s\n' "$*" >&2; exit 1; }
success(){ printf '[✓] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR"/*.json

python3 - "$TEMPLATE_DIR" "$EDGE_FILE" "$OUTPUT_DIR" <<'PY'
import csv, json, itertools, re, sys
from pathlib import Path

TEMPLATE_DIR=Path(sys.argv[1])
EDGE_FILE=Path(sys.argv[2])
OUT=Path(sys.argv[3])

HTTP_PORTS={80,8080,8880,2052,2082,2086,2095}
HTTPS_PORTS={443,2053,2083,2087,2096,8443}


def split(v):
    return [x.strip() for x in v.split(",") if x.strip()]


def get(sec,key,default=""):
    return sec.get(key,default).strip()


def load_ini(path):
    sec={}
    cur=None
    for raw in path.read_text(encoding="utf8").splitlines():
        line=raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            cur=line[1:-1].lower()
            sec.setdefault(cur,{})
            continue
        if "=" in line and cur:
            k,v=line.split("=",1)
            sec[cur][k.strip()]=v.strip()
    return sec


def bool_value(v, default=False):
    if v == "":
        return default
    return v.strip().lower() in {"1","true","yes","on"}


def add_tls(outbound, local, sec, sni):
    if sec != "tls":
        return

    tls = {
        "enabled": True,
        "server_name": sni,
        "insecure": bool_value(get(local,"AllowInsecure"), False),
    }

    alpn = split(get(local,"ALPN"))
    if alpn:
        tls["alpn"] = alpn

    fingerprint = get(local,"Fingerprint","chrome")
    if fingerprint:
        tls["utls"] = {
            "enabled": True,
            "fingerprint": fingerprint,
        }

    outbound["tls"] = tls


def add_ws_transport(outbound, local, host):
    path = get(local,"WSPath")
    if not path:
        return False

    transport = {
        "type": "ws",
        "path": path,
        "headers": {
            "Host": get(local,"WSHost") or host,
        },
    }

    max_early_data = get(local,"MaxEarlyData")
    if max_early_data:
        try:
            transport["max_early_data"] = int(max_early_data)
        except ValueError:
            pass

    early_data_header_name = get(local,"EarlyDataHeaderName")
    if early_data_header_name:
        transport["early_data_header_name"] = early_data_header_name

    outbound["transport"] = transport
    return True


def add_grpc_transport(outbound, local):
    svc = get(local,"GRPCServiceName")
    if not svc:
        return False
    outbound["transport"] = {
        "type": "grpc",
        "service_name": svc,
    }
    return True


def load_edges(path):
    edges=[]
    with path.open() as f:
        for row in csv.DictReader(f):
            ip=row.get("ip","").strip()
            if ip:
                edges.append(ip)
    return edges


def build_full_config(outbound):
    tag = outbound["tag"]
    return {
        "log": {
            "level": "error",
        },
        "inbounds": [{
            "type": "socks",
            "tag": "socks-in",
            "listen": "0.0.0.0",
            "listen_port": 1080,
        }],
        "outbounds": [
            outbound,
            {"type": "direct", "tag": "direct"},
            {"type": "block", "tag": "block"},
        ],
        "route": {
            "auto_detect_interface": True,
            "rules": [{
                "inbound": ["socks-in"],
                "action": "sniff",
            }],
            "final": tag,
        },
    }

edges=load_edges(EDGE_FILE)

created=0
workers=0

for tpl in sorted(TEMPLATE_DIR.glob("*.conf")):
    cfg=load_ini(tpl)
    if "worker" not in cfg:
        continue

    workers += 1
    worker = cfg["worker"]

    NAME = get(worker,"Name")
    HOST = get(worker,"Host")
    SNI = get(worker,"SNI") or HOST
    PORTS = [int(x) for x in split(get(worker,"Ports"))]

    summary=[]

    for proto in ("vless","trojan"):
        if proto not in cfg:
            continue

        local=dict(worker)
        local.update(cfg[proto])

        transports=split(get(local,"Transport"))
        securitys=split(get(local,"Security"))
        count=0

        for edge,port,transport,sec in itertools.product(edges,PORTS,transports,securitys):
            if port in HTTPS_PORTS and sec != "tls":
                continue
            if port in HTTP_PORTS and sec != "none":
                continue
            if port not in HTTP_PORTS and port not in HTTPS_PORTS:
                continue

            outbound={
                "tag": f"{NAME}_{proto}",
                "type": proto,
                "server": edge,
                "server_port": port,
            }

            if proto == "vless":
                outbound["uuid"] = get(local,"UUID")
                flow = get(local,"Flow")
                if flow:
                    outbound["flow"] = flow

                packet_encoding = get(local,"PacketEncoding") or get(local,"Packet_Encoding")
                if packet_encoding:
                    outbound["packet_encoding"] = packet_encoding
            else:
                outbound["password"] = get(local,"Password") or get(local,"TrojanPassword")

            add_tls(outbound, local, sec, SNI)

            transport = transport.lower()
            if transport == "ws":
                if not add_ws_transport(outbound, local, HOST):
                    continue
            elif transport == "grpc":
                if not add_grpc_transport(outbound, local):
                    continue
            elif transport != "tcp":
                continue

            # Each candidate is a complete, directly usable sing-box config.
            fname = f"{NAME}_{proto}_{edge}_{port}_{transport}_{sec}.json"
            fname = re.sub(r'[^A-Za-z0-9._-]', '_', fname)

            full_config = build_full_config(outbound)
            (OUT / fname).write_text(
                json.dumps(full_config, indent=2, ensure_ascii=False),
                encoding="utf8",
            )

            created += 1
            count += 1

        summary.append(f"{proto}={count}")

    print(f"[*] {tpl.name}: " + ", ".join(summary), file=sys.stderr)

print(f"Generated {created} JSON candidates from {workers} worker templates and {len(edges)} edge IPs.")
PY

COUNT=$(find "$OUTPUT_DIR" -name '*.json' | wc -l | tr -d ' ')

success "Maker complete: $COUNT JSON candidates written to $OUTPUT_DIR"

echo "------------------------------------------------------------"
printf "%-12s %s\n" "Candidates" "$COUNT"
printf "%-12s %s\n" "Templates" "$(find "$TEMPLATE_DIR" -name '*.conf'|wc -l|tr -d ' ')"
printf "%-12s %s\n" "Edges" "$(tail -n +2 "$EDGE_FILE"|wc -l|tr -d ' ')"
echo "------------------------------------------------------------"