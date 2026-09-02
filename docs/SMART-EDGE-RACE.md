# Smart Edge Race

Smart Edge Race is a staged Cloudflare edge selection layer for Smart Proxy Server.

## Pipeline

```text
Profile template
      |
      v
Phase 1: Edge Discovery
Cloudflare IPv4 CIDRs -> TCP candidates on the profile port
      |
      v
Phase 2: Edge Verification
Top candidates -> TLS verification (or TCP for HTTP endpoints)
      |
      v
Phase 3: Real Proxy Probe
VLESS/Trojan + original SNI/Host/WS/gRPC -> SOCKS -> HTTPS 204
      |
      v
Phase 4: Smart Score
Real proxy latency + verification latency + edge RTT -> Top winners
```

## Design rules

1. The endpoint port comes from the profile. Discovery does not scan all Cloudflare ports for every profile.
2. The original profile remains a template. During probing only the connect address is changed to a candidate IP; credentials, SNI, Host and transport settings remain tied to the profile.
3. Cheap network filtering happens before expensive real-proxy probing.
4. A candidate that fails the real proxy probe cannot become a winner.
5. Each phase writes inspectable JSON so debugging does not require running the full pipeline repeatedly.

## Cache files

```text
cache/candidates.json
cache/verified.json
cache/probed.json
cache/winners.json
```

Runtime deployments may override these with `/var/lib/smartproxy/*.json` through `config/defaults.conf`.

## Sources

The repository contains the official Cloudflare IPv4 CIDR source in `config/cf-ipv4.txt` and an AS13335 metadata file in `config/cf-asn13335.txt`. ASN-backed synchronization can be added later without changing the pipeline.

## Safety / rollout

The edge pipeline is currently opt-in and separate from the production `reload.sh` / `race.sh` selection flow. Dynamic Edge rewriting should be enabled only after field testing across the supported VLESS/Trojan profile families.
