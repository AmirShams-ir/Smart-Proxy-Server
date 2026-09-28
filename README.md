<div align="center">

# 🚀 Smart Proxy Server

### ⚡ Lightweight • Intelligent • Adaptive Proxy Gateway
### powered by **sing-box + Cloudflare Edge Discovery + Smart Scoring Engine**

![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20Ubuntu%20%7C%20Armbian-blue?logo=linux)
![Bash](https://img.shields.io/badge/Bash-100%25-green?logo=gnubash)
![Python](https://img.shields.io/badge/Python-3.x-yellow?logo=python)
![sing-box](https://img.shields.io/badge/sing--box-powered-orange)
![Proxy](https://img.shields.io/badge/Proxy-SOCKS5-purple)
![Cloudflare](https://img.shields.io/badge/Cloudflare-Edge%20Discovery-f38020?logo=cloudflare)
![License](https://img.shields.io/badge/License-Apache%202-red)
![Version](https://img.shields.io/badge/version-2.0.3-blueviolet)

**Fast • Adaptive • Lightweight • Deterministic • Privacy First**

</div>

---

# ⭐ Highlights

- 🚀 **Five-stage intelligent proxy pipeline**
- 🌐 **Cloudflare edge IP discovery and ranking**
- 🧩 **Automatic VLESS & Trojan candidate generation**
- 🩺 **Protocol-aware sing-box validation**
- 📶 **Cheap-to-expensive testing strategy**
- 📊 **Weighted Download + Upload + RTT scoring**
- 🏆 **Automatic Top-4 winner selection**
- 🔄 **Automatic proxy pool rebuild**
- ⚡ **Independent sing-box forwarder instances**
- ⏱️ **Systemd timer driven by a single configuration value**
- 🧠 **Optimized for Orange Pi, Raspberry Pi and low-RAM systems**
- 🔐 **TLS / SNI / ALPN / uTLS / WebSocket / gRPC support**
- 📝 **Journal-friendly operational logging**
- 💾 **File-based runtime — no database required**
- ❤️ **No telemetry or tracking**

---

# 🧠 Architecture

Smart Proxy Server is designed as a **cheap → expensive** pipeline.

Instead of performing an expensive bandwidth test on every candidate, the system progressively reduces the candidate set.

```text
                         ┌──────────────────────┐
                         │     Smart Proxy      │
                         │       Server         │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │     reload.sh        │
                         │   Orchestration       │
                         └──────────┬───────────┘
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          │                         │                         │
          ▼                         ▼                         ▼
   ┌─────────────┐           ┌─────────────┐          ┌─────────────┐
   │  1. Scanner │           │ 2. Maker    │          │ 3. Validator│
   │   🌐 Edge   │──────────▶│ 🧩 Config   │─────────▶│ 🩺 Connect  │
   └─────────────┘           └─────────────┘          └──────┬──────┘
                                                              │
                                                              ▼
                                                       ┌─────────────┐
                                                       │ 4. Score    │
                                                       │ 📊 Speed    │
                                                       └──────┬──────┘
                                                              │
                                                              ▼
                                                       ┌─────────────┐
                                                       │ 5. Forwarder│
                                                       │ 🚀 Runtime  │
                                                       └──────┬──────┘
                                                              │
                                            ┌─────────────────┼─────────────────┐
                                            ▼                 ▼                 ▼
                                         :1080             :1081             :1082
                                                                                 │
                                                                                 ▼
                                                                              :1083
```

## 🔁 Full data flow

```text
Cloudflare CIDRs
      │
      ▼
 scanner.sh
      │
      └──► cache/edge.csv
                │
                ▼
             maker.sh
                │
                └──► cache/generated/*.json
                               │
                               ▼
                         validator.sh
                               │
                               └──► singtest.sh
                               │
                               ├──► cache/valid.csv
                               └──► cache/validated/*.json
                                             │
                                             ▼
                                           score.sh
                                             │
                                             └──► speedtest.sh
                                             │
                                             ├──► cache/winner.csv
                                             └──► cache/winner/*.json
                                                          │
                                                          ▼
                                                     forwarder.sh
                                                          │
                                                          ▼
                                                     SOCKS5 pool
```

---

# ⚡ Pipeline Philosophy

The pipeline is intentionally optimized for small machines.

| Stage | Purpose | Relative Cost |
|---|---|---:|
| 🌐 Scanner | Find promising Cloudflare edges | Very Low |
| 🧩 Maker | Generate protocol candidates | Very Low |
| 🩺 Validator | Verify real sing-box connectivity | Low |
| 📊 Score | Measure throughput of survivors | High |
| 🚀 Forwarder | Run the winners | Runtime |

This prevents bandwidth testing from being wasted on candidates that already fail basic connectivity.

---

# 🌐 1. Edge Scanner

`scanner.sh` is the first stage.

It reads the Cloudflare IPv4/IPv6 CIDR sources:

```text
config/cf-ipv4.txt
config/cf-ipv6.txt
config/cf-asn13335.txt
```

It then:

- 🔎 Builds a bounded deterministic set of candidate IPs
- 📡 Performs ICMP probing
- 📶 Measures RTT, jitter and packet loss
- 🌍 Attempts Cloudflare colo detection
- 🧮 Calculates an edge quality score
- 🏆 Selects the best edges

The output contract is intentionally small:

```text
cache/edge.csv
```

Only the selected edge IPs are passed to the next stage.

---

# 🧩 2. Candidate Maker

`maker.sh` combines the selected Cloudflare edges with Worker definitions from:

```text
templates/*.conf
```

Each Worker can define:

- 🔐 VLESS credentials
- 🔑 Trojan credentials
- 🌐 WebSocket
- 🛰 gRPC
- 🔒 TLS / SNI
- 🧬 uTLS fingerprint
- 📡 ALPN
- ⚙️ Transport-specific settings

The Maker generates complete sing-box JSON configurations:

```text
cache/generated/
```

Invalid protocol/transport/security combinations are skipped instead of generating unusable candidates.

---

# 🩺 3. Protocol-Aware Validator

`validator.sh` is the cheap application-layer filter.

It calls:

```text
singtest.sh
```

for each generated candidate.

`singtest.sh`:

- launches an isolated sing-box test instance
- selects the real proxy outbound
- exposes a private local SOCKS listener
- tests actual proxy connectivity
- measures the response time
- returns PASS/FAIL

It does **not** perform download/upload benchmarks.

This stage keeps the expensive throughput tests limited to the fastest validated candidates.

Outputs:

```text
cache/valid.csv
cache/validated/
```

By default only the fastest `VALIDATOR_TOP` successful candidates are retained.

---

# 📊 4. Smart Score Engine

`score.sh` receives only the validated candidates.

For each surviving profile it calls:

```text
speedtest.sh
```

The current scoring model is:

```text
Download   55%
Upload     30%
RTT        15%
```

The final score is normalized to a 0–100 style ranking scale.

### 🏆 Winner set

The default configuration keeps the top:

```text
4 profiles
```

Outputs:

```text
cache/winner.csv
cache/winner/
```

This makes the system practical on low-power hardware by avoiding unnecessary speed tests.

---

# 🚀 5. Forwarder

`forwarder.sh` converts the winner set into the active runtime proxy pool.

Each winner gets its own sing-box instance.

Default mapping:

```text
Winner #1  → 0.0.0.0:1080
Winner #2  → 0.0.0.0:1081
Winner #3  → 0.0.0.0:1082
Winner #4  → 0.0.0.0:1083
```

Runtime files are deliberately stored outside the repository:

```text
/run/smartproxy-forwarder/
/var/log/smartproxy-forwarder/
```

This keeps generated runtime state separate from source code.

---

# 🔄 Automatic Rebuild

The entire pipeline is orchestrated by `reload.sh`:

```text
scanner
   ↓
maker
   ↓
validator
   ↓
score
   ↓
forwarder
```

A failed stage stops that rebuild before replacing the current working proxy pool.

This means the running forwarder is not intentionally replaced by an incomplete pipeline result.

---

# ⏱️ Systemd Timer

Automatic rebuilds use:

```text
reload.timer
      ↓
reload.service
      ↓
reload.sh
```

There is a **single source of truth** for the rebuild interval:

```text
config/defaults.conf
```

Example:

```ini
RELOAD_INTERVAL=24h
```

Synchronize the installed timer after changing it:

```bash
sudo bash lib/timer.sh
```

Useful commands:

```bash
systemctl status reload.timer
systemctl list-timers --all | grep reload
sudo systemctl start reload.service
```

---

# ⚙️ Configuration

Main runtime configuration:

```text
config/defaults.conf
```

Current structure:

```ini
RELOAD_INTERVAL=24h

SCANNER_PARALLEL=${SCANNER_PARALLEL:-8}
SCANNER_TOP=${SCANNER_TOP:-10}

VALIDATOR_PARALLEL=${VALIDATOR_PARALLEL:-4}
VALIDATOR_TOP=${VALIDATOR_TOP:-10}

SCORE_DOWNLOAD_WEIGHT=${SCORE_DOWNLOAD_WEIGHT:-55}
SCORE_UPLOAD_WEIGHT=${SCORE_UPLOAD_WEIGHT:-30}
SCORE_RTT_WEIGHT=${SCORE_RTT_WEIGHT:-15}

SCORE_TOP=${SCORE_TOP:-4}
```

Environment variables can override many runtime values without changing source files.

---

# 📂 Project Structure

```text
Smart-Proxy-Server/
│
├── config/
│   ├── cf-asn13335.txt
│   ├── cf-ipv4.txt
│   ├── cf-ipv6.txt
│   └── defaults.conf
│
├── docs/
│   └── SMART-EDGE-RACE.md
│
├── lib/
│   ├── common.sh
│   └── timer.sh
│
├── systemd/
│   ├── sing-box.service
│   ├── reload.service
│   └── reload.timer
│
├── templates/
│   ├── worker.temp
│   └── worker1.conf
│
├── scanner.sh
├── maker.sh
├── singtest.sh
├── validator.sh
├── speedtest.sh
├── score.sh
├── forwarder.sh
├── reload.sh
├── install.sh
├── uninstall.sh
└── README.md
```

Generated data is intentionally runtime-only:

```text
cache/
├── edge.csv
├── generated/
├── valid.csv
├── validated/
├── winner.csv
└── winner/
```

The `cache/` directory is not part of the source architecture.

---

# 🧪 Manual Testing

### Run the complete pipeline

```bash
sudo bash reload.sh
```

### Run the stages individually

```bash
bash scanner.sh
bash maker.sh
bash validator.sh
bash score.sh
sudo bash forwarder.sh
```

### Test one generated candidate

```bash
bash singtest.sh cache/generated/<profile>.json
```

### Run throughput testing on one validated candidate

```bash
bash speedtest.sh cache/validated/<profile>.json
```

### Synchronize the timer

```bash
sudo bash lib/timer.sh
```

---

# 📈 Scoring Strategy

The project intentionally separates **validation** from **performance scoring**.

### Stage 3 — Validation

```text
Connectivity
   +
Response time
   ↓
Fastest VALIDATOR_TOP
```

### Stage 4 — Performance

```text
Download
   +
Upload
   +
Validated RTT
   ↓
Weighted Score
   ↓
Top SCORE_TOP winners
```

This design reduces CPU usage, bandwidth consumption, and unnecessary sing-box startup overhead.

---

# 🔐 Supported Proxy Features

### VLESS

- UUID
- Flow
- Packet encoding
- TLS
- SNI
- ALPN
- uTLS fingerprint
- WebSocket
- gRPC

### Trojan

- Password
- TLS
- SNI
- ALPN
- uTLS fingerprint
- WebSocket
- gRPC

The Worker template controls which combinations are generated.

---

# 🖥 Designed For

Smart Proxy Server is especially suitable for:

- 🍊 Orange Pi
- 🍓 Raspberry Pi
- 🖥️ Thin clients
- 💻 Mini PCs
- ☁️ Small Debian VPS
- 🏠 Home Linux gateways
- 🧠 Low-RAM systems

The architecture avoids a database and avoids keeping a heavyweight application framework running continuously.

---

# 📦 Installation

```bash
git clone https://github.com/AmirShams-ir/Smart-Proxy-Server.git
cd Smart-Proxy-Server
sudo bash install.sh
```

The installer:

1. installs required base packages
2. installs sing-box when needed
3. installs systemd units
4. synchronizes the timer
5. enables sing-box
6. enables the automatic rebuild timer
7. performs an initial full rebuild

Installed runtime locations:

```text
/etc/sing-box/
/etc/systemd/system/
/var/log/smartproxy/
/run/smartproxy-forwarder/
```

---

# 🗑️ Removal

```bash
sudo bash uninstall.sh
```

The system services and installed runtime configuration are removed.

The Git repository checkout is intentionally preserved.

---

# 🛡️ Operational Notes

### Edge discovery ≠ proxy validation

The scanner uses cheap network-level measurements to identify promising Cloudflare edges.

The actual proxy connectivity test happens later through `singtest.sh`.

### Validation ≠ bandwidth benchmark

A candidate that passes validation has demonstrated protocol-level connectivity, but it is not necessarily the fastest candidate.

That is why throughput testing is deferred to `score.sh`.

### Runtime state stays outside Git

Generated candidate files, winner files, PID files, logs and temporary runtime state are not source-controlled.

---

# 🧭 Roadmap

- [x] 🌐 Cloudflare edge discovery
- [x] 🧩 Automatic candidate generation
- [x] 🔐 VLESS support
- [x] 🔑 Trojan support
- [x] 🌊 WebSocket support
- [x] 🛰 gRPC support
- [x] 🩺 Protocol-aware validation
- [x] 📊 Throughput scoring
- [x] 🏆 Top-winner selection
- [x] 🚀 Multi-instance forwarding
- [x] ⏱️ Configuration-driven systemd timer
- [x] 🔒 Runtime separation from source tree
- [ ] 📈 Historical performance statistics
- [ ] 🌐 Web dashboard
- [ ] 🧠 Adaptive scoring based on history
- [ ] 🔁 Advanced failover policies

---

# ❤️ Philosophy

Smart Proxy Server is built around a simple idea:

> **Discover → Generate → Validate → Measure → Forward**

No database.

No telemetry.

No tracking.

No unnecessary daemon.

Just:

**Cloudflare edges + sing-box + intelligent filtering + lightweight scoring + automatic forwarding.**

<div align="center">

### 🚀 Smart Proxy Server

**Fast • Smart • Lightweight • Adaptive**

❤️ Built for small Linux gateways.

</div>
