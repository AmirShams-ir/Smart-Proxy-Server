# Smart Proxy Server 🍊

Tiny, adaptive, file-based smart proxy for Orange Pi / Debian.

## Architecture

- **Health Engine** — measures lightweight endpoint reachability (RTT, jitter, loss, success rate).
- **Score Engine** — converts reachability metrics into a weighted 0–100 score.
- **Race Engine** — selects the active profile in `auto` mode, supports `manual` mode, hysteresis and cooldown.
- **Profiles** — one VLESS or Trojan URI per `profile/*.txt` file during development; deployed runtime copies live in `/etc/sing-box/profiles/`.
- **State** — JSON only; no database.
- **sing-box** — execution layer; the engine generates `/etc/sing-box/config.json`.

## Configuration

Edit `config/defaults.conf` (deployed as `/etc/sing-box/defaults.conf`). Important values:

```ini
MODE=auto
ACTIVE_PROFILE=
HEALTH_INTERVAL=15
HYSTERESIS=8
COOLDOWN=120
MOVING_AVERAGE=5
FAIL_THRESHOLD=3
RECOVERY_THRESHOLD=2
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

For production, profile files are copied to `/etc/sing-box/profiles/` by the installer. Keep credentials out of public Git repositories whenever possible.

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

Automatic rearm is provided by `proxy-rearm.timer` every 15 seconds after an initial 30-second boot delay.

> Note: endpoint health is deliberately lightweight. ICMP can be blocked by an upstream; TCP timing is used as a fallback. Full end-to-end proxy health is not equivalent to raw endpoint reachability health and should be validated separately during deployment testing.
