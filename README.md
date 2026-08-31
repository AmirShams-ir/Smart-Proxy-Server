<div align="center">

# 🚀 Smart Proxy Server

### ⚡ A Lightweight, Fast and Intelligent Proxy Server
### powered by **sing-box + Health + Score + Smart Race Engine**

![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20Ubuntu%20%7C%20Armbian-blue?logo=linux)
![Bash](https://img.shields.io/badge/Bash-100%25-green?logo=gnubash)
![sing-box](https://img.shields.io/badge/sing--box-powered-orange)
![Proxy](https://img.shields.io/badge/Proxy-SOCKS5-purple)
![License](https://img.shields.io/badge/License-Apache-red)
![Version](https://img.shields.io/badge/version-2.0.3-blueviolet)

Fast • Adaptive • Lightweight • Privacy First

</div>

---

# ⭐ Highlights

- ⚡ Intelligent Proxy Race Engine
- 🩺 Lightweight Health Engine
- 📊 Weighted 0–100 Score Engine
- 🏆 Automatic Best Profile Selection
- 🔄 Hysteresis + Cooldown Protection
- 🌐 SOCKS5 Proxy on the LAN
- 🔐 VLESS and Trojan Profile Support
- 🧩 TLS / SNI / ALPN / uTLS Fingerprint Support
- 🌐 WebSocket and gRPC Transport Support
- 📈 Human-readable Race Reports
- 📝 Full `journalctl` Reporting
- 💾 JSON State — No Database
- 🪶 Extremely Lightweight
- 🚀 Optimized for Orange Pi & Raspberry Pi
- ❤️ Privacy First
- 🔧 Designed for Debian-based systems

---

# ✨ Features

- ⚡ Health testing of every configured proxy profile
- 🏎 RTT measurement
- 📶 Jitter measurement
- ❌ Packet-loss measurement
- ✅ Success-rate calculation
- 📈 Weighted proxy scoring
- 🏆 Deterministic ranking and winner selection
- 🔄 Automatic profile switching
- 🛡 Hysteresis to prevent unnecessary switching
- ⏳ Cooldown protection between switches
- 🧠 Automatic and manual selection modes
- 🧾 Persistent active-profile state
- 🔌 Automatic sing-box configuration generation
- 🔁 Automatic sing-box reload/restart when the active profile changes
- 📡 SOCKS5 listener for local clients
- 🔒 TLS with SNI, ALPN and fingerprint parameters
- 🌐 WebSocket transport
- 🛰 gRPC transport
- 📊 Terminal race report
- 📝 systemd journal race report
- 🗂 File-based profiles
- 🪶 Low CPU and RAM footprint
- ❤️ No telemetry or tracking

---

# 🧠 Architecture

Smart Proxy Server follows the same philosophy as Smart DNS Server: measure first, score objectively, race candidates, then apply one deterministic decision.

```text
                              Smart Proxy Server
                                      │
                                      ▼
                              ┌───────────────┐
                              │  reload.sh    │
                              │ Report Engine  │
                              └───────┬───────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
             ┌────────────┐   ┌────────────┐   ┌────────────┐
             │ Health     │   │ Score      │   │ Profiles   │
             │ Engine     │   │ Engine     │   │ *.txt      │
             └─────┬──────┘   └─────┬──────┘   └────────────┘
                   │                │
                   └───────┬────────┘
                           ▼
                    ┌──────────────┐
                    │ Smart Race   │
                    │ Engine       │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
         Hysteresis     State      Generator
              │            │            │
              └────────────┼────────────┘
                           ▼
                    ┌──────────────┐
                    │   sing-box   │
                    │ Active Proxy │
                    └──────────────┘
```

### Design principle

`reload.sh` performs one health/score pass and stores the result set. `race.sh` consumes that same result set for the actual decision, so the displayed **Winner** and the selected **Active Profile** are based on the same measurements.

---

# 📊 Race Report

Run a complete race manually:

```bash
sudo bash reload.sh
```

Example output:

```text
[*] Testing proxy profiles...

Profile                  Host                                RTT    Jitter    Loss   Success   Score
----------------------------------------------------------------------------------------------------------------
Config X
Config Y
Config Z
----------------------------------------------------------------------------------------------------------------

[*] Ranking proxy profiles...

Profile                  Host                                RTT    Jitter    Loss   Success   Score
----------------------------------------------------------------------------------------------------------------
Config X
Config Z
Config Y
----------------------------------------------------------------------------------------------------------------

Winner
----------------------------------------------------------------------------------------------------------------
Profile : Config X
Score   : 86/100
RTT     : 30.006ms
Jitter  : 0ms
Loss    : 0%
Success : 100%
----------------------------------------------------------------------------------------------------------------

[*] Applying race decision...
[ACTIVE] Config X  score=86

Active Profile
Profile : Config X
Score   : 86/100
```

The testing table and ranking table use the same result set, and the final active profile is selected through the Race Engine.

---

# 🩺 Health Engine

Each profile is tested independently.

The Health Engine measures:

| Metric | Meaning |
|---|---|
| RTT | Endpoint round-trip/connectivity latency |
| Jitter | Difference between observed latency samples |
| Loss | Packet loss percentage |
| Success | `100 - Loss` |

The engine uses ICMP when available and falls back to TCP connection timing when ICMP is unavailable.

> Endpoint health is intentionally lightweight. It is an indication of endpoint reachability and latency, not a full end-to-end application-layer proxy benchmark.

---

# 📈 Score Engine

The Score Engine converts Health metrics into a weighted score from `0` to `100`.

Current weights:

```text
RTT      = 35%
Jitter   = 25%
Loss     = 25%
Success  = 15%
```

Configured in:

```text
config/defaults.conf
```

Current scoring uses smooth RTT and jitter curves so a 30 ms endpoint can rank meaningfully above a 100 ms endpoint instead of all healthy endpoints collapsing to the same rounded score.

---

# 🏆 Smart Race Engine

The Race Engine compares all usable profiles and applies deterministic tie-breaking.

Selection order:

```text
1. Higher Score
2. Higher Success Rate
3. Lower RTT
4. Lower Jitter
5. Lexicographically smaller profile name
```

This means a race can consistently choose the same winner when several profiles have identical scores.

---

# 🛡 Hysteresis & Cooldown

Automatic mode does not switch profiles every time a small measurement fluctuation occurs.

A candidate must exceed the active profile by at least:

```ini
HYSTERESIS=8
```

and the configured cooldown must have elapsed:

```ini
COOLDOWN=120
```

This reduces profile flapping and unnecessary sing-box reloads.

---

# ⚙️ Configuration

Main configuration:

```text
config/defaults.conf
```

Current defaults:

```ini
MODE=auto
ACTIVE_PROFILE=
HEALTH_INTERVAL=1h
PING_COUNT=3
TIMEOUT=2
MOVING_AVERAGE=5
HYSTERESIS=8
COOLDOWN=120
FAIL_THRESHOLD=3
RECOVERY_THRESHOLD=2
RTT_WEIGHT=35
JITTER_WEIGHT=25
LOSS_WEIGHT=25
SUCCESS_WEIGHT=15
TEST_URL=https://cp.cloudflare.com/generate_204
SOCKS_LISTEN=0.0.0.0
SOCKS_PORT=1080
CONFIG_FILE=/etc/sing-box/config.json
STATE_FILE=/etc/sing-box/proxy-state.json
PROFILE_DIR=/etc/sing-box/profiles
LOG_DIR=/var/log/smartproxy
LOG_FILE=/var/log/smartproxy/proxy.log
```

---

# 🔀 Selection Modes

### Automatic mode

```ini
MODE=auto
```

The Race Engine selects and maintains the best profile using score, hysteresis and cooldown.

### Manual mode

```ini
MODE=manual
ACTIVE_PROFILE=vless1
```

Manual mode prevents automatic profile competition and keeps the configured selection policy.

---

# 📂 Profiles

Each profile is stored as one text file containing one URI.

Example:

```text
profiles/01_Nova_443.txt
profiles/02_Zeus_443.txt
profiles/19_Nahan_8443.txt
```

Supported schemes:

```text
vless://
trojan://
```

The generator supports common URI parameters including:

- TLS
- SNI
- ALPN
- uTLS fingerprint
- WebSocket
- gRPC

Example:

```text
vless://UUID@host:443?encryption=none&security=tls&sni=host&type=ws&host=host&path=%2F#Nova
```

For production use, keep private credentials out of public repositories whenever possible.

---

# 🔌 SOCKS5 Proxy

The generated sing-box configuration exposes a SOCKS5 listener.

Default:

```ini
SOCKS_LISTEN=0.0.0.0
SOCKS_PORT=1080
```

Clients on the LAN can therefore use:

```text
SOCKS5 → <Orange Pi IP>:1080
```

Applications do not need to know which VLESS or Trojan profile is currently active; sing-box and the Race Engine handle the active outbound profile.

---

# 🧩 sing-box

sing-box is the execution layer.

The Race Engine generates:

```text
/etc/sing-box/config.json
```

The generator creates the active outbound and reloads or restarts sing-box after a profile switch.

Validate the generated configuration with:

```bash
sing-box check -c /etc/sing-box/config.json
```

The systemd service is:

```text
sing-box.service
```

---

# 🔄 Automatic Reload

The automatic race is driven by systemd.

The timer reads `HEALTH_INTERVAL` from configuration.

Example:

```ini
HEALTH_INTERVAL=1h
```

The installer renders the real systemd timer from this value.

Initial boot execution is configured with a short boot delay, followed by the recurring health/race interval.

Check the timer:

```bash
systemctl status reload.timer
systemctl list-timers --all | grep reload
```

Run one race immediately:

```bash
systemctl start reload.service
```

---

# 📝 Journal Reporting

The reload service writes the complete race report to systemd journal.

View it with:

```bash
journalctl -u reload.service -n 200 --no-pager
```

A dedicated tag is also available:

```bash
journalctl -t smart-proxy-reload -n 200 --no-pager
```

The journal report contains:

```text
Health table
Ranking table
Winner
Race decision
Active Profile
Completion summary
```

This keeps Smart Proxy Server operationally consistent with Smart DNS Server's journal reporting style.

---

# 📝 Logs

Runtime logs are stored under:

```text
/var/log/smartproxy/
```

The primary proxy log is:

```text
/var/log/smartproxy/proxy.log
```

---

# 🚀 Installation

```bash
git clone https://github.com/AmirShams-ir/Smart-Proxy-Server.git
cd Smart-Proxy-Server
sudo bash install.sh
```

The installer prepares sing-box, runtime directories, profile files, systemd units and the automatic reload timer.

---

# 🔄 Update

```bash
cd Smart-Proxy-Server
git pull
```

After changing systemd units manually:

```bash
sudo cp systemd/reload.service /etc/systemd/system/reload.service
sudo systemctl daemon-reload
```

---

# 🧪 Manual Testing

Test a single profile:

```bash
bash lib/health.sh profiles/01_Nova_443.txt
```

Score a health result:

```bash
printf 'host=example.com port=443 rtt=40 jitter=2 loss=0 success=100\n' | bash lib/score.sh
```

Run the complete report and race:

```bash
bash reload.sh
```

Inspect the current state:

```bash
cat /etc/sing-box/proxy-state.json
```

Inspect the generated sing-box configuration:

```bash
cat /etc/sing-box/config.json
```

---

# 🖥 Systemd Services

Main service:

```text
sing-box.service
```

Automatic race:

```text
reload.service
reload.timer
```

Useful commands:

```bash
systemctl status sing-box
systemctl status reload.service
systemctl status reload.timer
```

---

# ⚠️ Health vs Real Proxy Performance

The Health Engine intentionally performs lightweight endpoint measurements.

Therefore:

```text
Endpoint RTT ≠ full proxy RTT
Endpoint TCP reachability ≠ successful application traffic
```

A profile can have an excellent endpoint score while its real proxy traffic experiences TLS, transport, routing or application-layer problems.

For deployment validation, test actual SOCKS5 traffic separately.

---

# 💡 Why File-Based?

Smart Proxy Server is designed for small systems where simplicity matters.

There is:

- No database
- No daemonized application framework
- No telemetry backend
- No cloud dependency

Profiles are plain text files, state is JSON, and orchestration is Bash + systemd + sing-box.

---

# 🖥 Suitable OS

- Debian 12 or 13
- Ubuntu 24 or 26
- Armbian

The project is especially suited to:

- Orange Pi
- Raspberry Pi
- Mini PCs
- Thin clients
- Home servers
- Debian VPS / dedicated servers

---

# 🎯 Designed For

- Home networks
- LAN proxy gateways
- Orange Pi
- Raspberry Pi
- Small Linux gateways
- Low-RAM embedded systems
- Multi-profile VLESS/Trojan environments

---

# 🧭 Project Structure

```text
Smart-Proxy-Server
│
├── config/
│   └── defaults.conf
│
├── lib/
│   ├── common.sh
│   ├── health.sh
│   ├── score.sh
│   ├── hysteresis.sh
│   ├── generator.sh
│   └── race.sh
│
├── profiles/
│   ├── 01_Nova_443.txt
│   ├── 02_Zeus_443.txt
│   ├── ...
│   └── 24_BPB_80.txt
│
├── systemd/
│   ├── sing-box.service
│   ├── reload.service
│   └── reload.timer
│
├── reload.sh
├── install.sh
├── uninstall.sh
└── README.md
```

---

# ❤️ Philosophy

Smart Proxy Server is designed around four principles:

- ⚡ Adaptive performance
- 🪶 Lightweight operation
- 🧠 Deterministic decisions
- 🔐 Privacy first

No telemetry.

No tracking.

No database.

Just profiles, measurements, smart selection and sing-box.

---

# 🛣 Roadmap

- [x] File-based proxy profiles
- [x] Health Engine
- [x] Score Engine
- [x] Race Engine
- [x] Automatic profile selection
- [x] Manual mode
- [x] Hysteresis
- [x] Cooldown
- [x] JSON state
- [x] sing-box configuration generation
- [x] SOCKS5 listener
- [x] TLS / SNI / ALPN support
- [x] WebSocket support
- [x] gRPC support
- [x] Terminal race report
- [x] systemd journal report
- [ ] Full end-to-end proxy health probing
- [ ] Historical performance statistics
- [ ] Web dashboard
- [ ] Multi-outbound failover groups
- [ ] OpenWRT integration

---

# 🤝 Contributions

Pull requests are welcome.

For bugs, reproducible logs and a minimal test case are highly appreciated.

---

# 📜 License

Apache 2.0 License

---

<div align="center">

### Designed for Orange Pi, Raspberry Pi and Every Debian Server

Made with ❤️ by **AmirShams-ir**

**Smart Gateway • Smart DNS • Smart Proxy**

⭐ Don't forget to Star this project!

</div>
