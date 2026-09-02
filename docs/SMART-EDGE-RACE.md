# Smart Edge Race

Smart Edge Race is an edge-discovery layer for Smart Proxy Server. It is intentionally separate from the existing Health/Score/Race pipeline.

## Goal

A proxy profile is treated as a template. The engine can discover candidate Cloudflare IPv4 edges and rank them before deeper proxy validation.

## Pipeline

```text
Cloudflare CIDRs
      |
      v
Random edge sampling
      |
      v
TCP/RTT/Jitter/Loss filter
      |
      v
Top edge candidates
      |
      v
Future: real VLESS/Trojan validation
      |
      v
Future: download/upload benchmark
      |
      v
Best edge per profile/worker
```

## Important design rule

Do not run a full VLESS/Trojan validation against every Cloudflare address. Discovery should be broad and cheap; application-layer proxy validation should be narrow and expensive.

## Current implementation

`lib/edge-race.sh` samples IPv4 addresses from `config/cloudflare-ips-v4.txt`, tests candidate ports, computes a lightweight score from RTT, jitter, packet loss and TCP timing, and stores the top candidates in:

```text
/var/lib/smartproxy/edge-cache.json
```

The profile's original URI remains the source of truth. The current implementation does not yet modify the production active profile automatically. This keeps the feature safe while the real proxy validation stage is developed.

## Recommended next phase

1. Parse a profile into a reusable template.
2. Substitute only the connect address while preserving SNI, Host, Path and credentials.
3. Validate the candidate with the real sing-box/VLESS/Trojan transport.
4. Speed-test only the top candidates.
5. Persist the best edge per worker/profile.
6. Integrate the result into the existing Race Engine with hysteresis and cooldown.
