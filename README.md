# Smart Proxy Server

Lightweight Cloudflare edge discovery, sing-box candidate generation, protocol-aware validation, throughput scoring, and automatic SOCKS5 forwarding.

## Pipeline

```text
scanner.sh
   │
   ▼
cache/edge.csv
   │
   ▼
maker.sh
   │
   ▼
cache/generated/*.json
   │
   ▼
validator.sh ──► singtest.sh
   │
   ▼
cache/valid.csv
cache/validated/*.json
   │
   ▼
score.sh ──► speedtest.sh
   │
   ▼
cache/winner.csv
cache/winner/*.json
   │
   ▼
forwarder.sh
   │
   ▼
SOCKS5 :1080-1083
```

`reload.sh` runs the five stages in order and keeps the currently running forwarder untouched until a complete new winner set has been produced.

## Repository layout

```text
Smart-Proxy-Server/
├── config/
│   ├── cf-asn13335.txt
│   ├── cf-ipv4.txt
│   ├── cf-ipv6.txt
│   └── defaults.conf
├── docs/
│   └── SMART-EDGE-RACE.md
├── lib/
│   ├── common.sh
│   └── timer.sh
├── systemd/
│   ├── sing-box.service
│   ├── reload.service
│   └── reload.timer
├── templates/
│   ├── worker.temp
│   └── worker1.conf
├── scanner.sh
├── maker.sh
├── singtest.sh
├── validator.sh
├── speedtest.sh
├── score.sh
├── forwarder.sh
├── reload.sh
├── install.sh
└── uninstall.sh
```

Runtime artefacts are generated under `cache/` and are intentionally not part of the source tree.

## Requirements

Debian/Ubuntu/Armbian with:

- Bash
- curl
- Python 3
- jq
- iputils-ping
- coreutils
- systemd
- sing-box

The installer installs the missing base packages and installs the latest sing-box release when sing-box is not already present.

## Configure

Edit `config/defaults.conf` for pipeline limits, scoring weights, and the automatic rebuild interval.

Example:

```ini
RELOAD_INTERVAL=24h

SCANNER_PARALLEL=${SCANNER_PARALLEL:-8}
SCANNER_TOP=${SCANNER_TOP:-10}

VALIDATOR_PARALLEL=${VALIDATOR_PARALLEL:-4}
VALIDATOR_TOP=${VALIDATOR_TOP:-10}

SCORE_DOWNLOAD_WEIGHT=${SCORE_DOWNLOAD_WEIGHT:-55}
SCORE_UPLOAD_WEIGHT=${SCORE_UPLOAD_WEIGHT:-30}
SCORE_RTT_WEIGHT=${SCORE_RTT_WEIGHT:-15}
```

The timer reads `RELOAD_INTERVAL` from this file through `lib/timer.sh`. There is one source of truth for the rebuild interval.

## Worker templates

`maker.sh` reads every `*.conf` file in `templates/` that contains a `[worker]` section.

Copy `templates/worker.temp` to a new worker file and set the Worker host, credentials, transports, and security modes.

Keep private credentials out of public repositories. The included `templates/worker1.conf` is the active example configuration used by the project.

## Run the pipeline

Run one complete rebuild:

```bash
sudo bash reload.sh
```

Run individual stages when debugging:

```bash
bash scanner.sh
bash maker.sh
bash validator.sh
bash score.sh
sudo bash forwarder.sh
```

Test one generated configuration:

```bash
bash singtest.sh cache/generated/<profile>.json
```

Test one validated configuration with throughput measurement:

```bash
bash speedtest.sh cache/validated/<profile>.json
```

## Scanning

`scanner.sh` reads the Cloudflare IPv4/IPv6 CIDR lists, creates a bounded deterministic target set, probes candidates with ICMP, optionally resolves the Cloudflare colo, and writes only the selected IP addresses to:

```text
cache/edge.csv
```

The console output still includes RTT, jitter, loss, colo, and score for diagnostics.

## Candidate generation

`maker.sh` combines:

- Cloudflare edge IPs from `cache/edge.csv`
- Worker definitions from `templates/*.conf`
- VLESS and Trojan protocol settings

It writes complete sing-box JSON candidates to `cache/generated/`.

Unsupported transport/security combinations are skipped instead of generating invalid candidates.

## Validation

`validator.sh` is deliberately cheap. It calls `singtest.sh` and keeps only the fastest `VALIDATOR_TOP` successful candidates.

Outputs:

```text
cache/valid.csv
cache/validated/
```

`singtest.sh` performs the protocol-aware sing-box connectivity test and measures the response time to Cloudflare's lightweight endpoint. It does not perform throughput testing.

## Scoring

`score.sh` measures only the validated candidates with `speedtest.sh` and combines:

```text
Download = 55%
Upload   = 30%
RTT      = 15%
```

The default winner set is the top four profiles.

Outputs:

```text
cache/winner.csv
cache/winner/
```

Throughput tests use small transfer sizes to keep the pipeline practical on low-power devices.

## Forwarder

`forwarder.sh` starts one independent sing-box instance per winner.

Defaults:

```text
0.0.0.0:1080  winner #1
0.0.0.0:1081  winner #2
0.0.0.0:1082  winner #3
0.0.0.0:1083  winner #4
```

Change the bind address, base port, or instance limit with environment variables:

```bash
FORWARDER_BIND=0.0.0.0
FORWARDER_BASE_PORT=1080
FORWARDER_MAX=4
```

Runtime configurations, PID files, and logs stay outside the repository.

## Automatic rebuilds

Systemd runs:

```text
reload.timer
   └── reload.service
          └── reload.sh
               └── scanner → maker → validator → score → forwarder
```

Change `RELOAD_INTERVAL` in `config/defaults.conf`, then synchronize the installed timer:

```bash
sudo bash lib/timer.sh
```

Check it with:

```bash
systemctl status reload.timer
systemctl list-timers --all | grep reload
```

Run a rebuild immediately:

```sudo systemctl start reload.service
```

## Installation

```bash
git clone https://github.com/AmirShams-ir/Smart-Proxy-Server.git
cd Smart-Proxy-Server
sudo bash install.sh
```

The repository itself remains the working tree. Installed system files live under:

```text
/etc/sing-box/
/etc/systemd/system/
/var/log/smartproxy/
/run/smartproxy-forwarder/
```

## Removal

```bash
sudo bash uninstall.sh
```

The repository checkout is intentionally preserved.

## Notes

This project is optimized for small Debian-based systems such as Orange Pi, Raspberry Pi, thin clients, and small VPS instances.

The scanner's ICMP metrics are used for edge discovery. The actual protocol-aware connectivity decision is performed later by `singtest.sh`, and throughput is measured only for the validated set. This keeps the expensive part of the pipeline small.

No database, telemetry backend, or external control plane is required.
