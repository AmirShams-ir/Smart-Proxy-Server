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

edges=[]
with EDGE_FILE.open() as f:
    r=csv.DictReader(f)
    for row in r:
        edges.append(row["ip"])

created=0
workers=0

for tpl in sorted(TEMPLATE_DIR.glob("*.conf")):

    cfg=load_ini(tpl)

    if "worker" not in cfg:
        continue

    workers+=1

    worker=cfg["worker"]

    NAME=get(worker,"Name")
    HOST=get(worker,"Host")
    SNI=get(worker,"SNI") or HOST

    PORTS=[int(x) for x in split(get(worker,"Ports"))]

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

            # ------------------------------------------------------
            # Cloudflare Port Policy
            # ------------------------------------------------------
            if port in HTTPS_PORTS and sec!="tls":
                continue

            if port in HTTP_PORTS and sec!="none":
                continue

            if port not in HTTP_PORTS and port not in HTTPS_PORTS:
                continue

            outbound={
                "tag":f"{NAME}_{proto}",
                "type":proto,
                "server":edge,
                "server_port":port
            }

            if proto=="vless":
                outbound["uuid"]=get(local,"UUID")
                flow=get(local,"Flow")
                if flow:
                    outbound["flow"]=flow
            else:
                outbound["password"]=get(local,"Password") or get(local,"TrojanPassword")

            # TLS
            if sec=="tls":
                outbound["tls"]={
                    "enabled":True,
                    "server_name":SNI,
                    "utls":{
                        "enabled":True,
                        "fingerprint":get(local,"Fingerprint","chrome")
                    }
                }

            # Transport
            transport=transport.lower()

            if transport=="ws":

                path=get(local,"WSPath")
                if not path:
                    continue

                outbound["transport"]={
                    "type":"ws",
                    "path":path,
                    "headers":{"Host":HOST}
                }

            elif transport=="grpc":

                svc=get(local,"GRPCServiceName")
                if not svc:
                    continue

                outbound["transport"]={
                    "type":"grpc",
                    "service_name":svc
                }

            elif transport!="tcp":
                continue

            fname=f"{NAME}_{proto}_{edge}_{port}_{transport}_{sec}.json"
            fname=re.sub(r'[^A-Za-z0-9._-]','_',fname)

            (OUT/fname).write_text(
                json.dumps(outbound,indent=2,ensure_ascii=False),
                encoding="utf8"
            )

            created+=1
            count+=1

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