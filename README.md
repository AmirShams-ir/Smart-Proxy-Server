# Smart Proxy Server 🍊

Tiny, adaptive, file-based smart proxy for Orange Pi / Debian.

## Architecture

- **Health Engine** — measures lightweight endpoint health (RTT, jitter, loss, success rate).
- **Score Engine** — converts health metrics into a weighted 0–100 score.
- **Race Engine** — selects the active profile in `auto` mode, supports `manual` mode, hysteresis and cooldown.
- **Profiles** — one VLESS or Trojan URI per `profile/*.txt` file.
- **State** — JSON only; no database.
- **sing-box** — execution layer; the engine generates `/etc/sing-box/config.json`.

## Configuration

Edit `config/defaults.conf` (deployed as `/etc/sing-box/defaults.conf`). Important values:

```ini
MODE=auto
HEALTH_INTERVAL=15
HYSTERESIS=8
COOLDOWN=120
MOVING_AVERAGE=5
FAIL_THRESHOLD=3
```

Manual selection:

```ini
MODE=manual
ACTIVE_PROFILE=vless1
```

Automatic selection uses the best score and switches only when the candidate exceeds the active profile by at least `HYSTERESIS` and the `COOLDOWN` has elapsed.

## Profiles

Put a single URI in each text file, for example:

```text
profile/vless1.txt
profile/trojan1.txt
```

Supported schemes: `vless://` and `trojan://`. The generator parses common TLS, SNI, ALPN, fingerprint, WebSocket and gRPC URI parameters.

## Commands

Race once:

```bash
/opt/smart-proxy/lib/race.sh
```

Generate a configuration manually:

```bash
/opt/smart-proxy/lib/generator.sh vless1
```

Check sing-box:

```bash
sing-box check -c /etc/sing-box/config.json
```

Automatic rearm is provided by `smarty-proxy-rearm.timer`.

> Note: endpoint health is deliberately lightweight. ICMP can be blocked by an upstream; TCP timing is used as a fallback. Full end-to-end proxy health should be treated separately from reachability health.
