#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config/defaults.conf"

PASS=0
WARN=0
FAIL=0
START_TIME=$(date +%s)

pass(){ PASS=$((PASS+1)); printf '[✓] %s\n' "$*"; }
warn(){ WARN=$((WARN+1)); printf '[!] %s\n' "$*"; }
fail(){ FAIL=$((FAIL+1)); printf '[✗] %s\n' "$*"; }
section(){ printf '\n=== %s ===\n' "$*"; }

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || { fail "Missing command: $1"; return 1; }
  pass "Command available: $1"
}

section "Smart Proxy Diagnostic"
printf 'Base directory : %s\n' "$BASE_DIR"
printf 'Config file    : %s\n' "$CONFIG_FILE"
printf 'SOCKS endpoint : %s:%s\n' "$SOCKS_LISTEN" "$SOCKS_PORT"

section "Required Commands"
for cmd in sing-box jq curl ss systemctl awk sed; do need_cmd "$cmd" || true; done

section "Config File"
if [[ -f "$CONFIG_FILE" ]]; then
  pass "Config exists: $CONFIG_FILE"
else
  fail "Config missing: $CONFIG_FILE"
fi

if [[ -f "$CONFIG_FILE" ]] && sing-box check -c "$CONFIG_FILE" >/tmp/smart-proxy-singbox-check.out 2>&1; then
  pass "sing-box configuration is valid"
else
  fail "sing-box configuration check failed"
  [[ -s /tmp/smart-proxy-singbox-check.out ]] && sed 's/^/    /' /tmp/smart-proxy-singbox-check.out
fi

section "sing-box Service"
if systemctl is-active --quiet sing-box; then
  pass "sing-box.service is active"
else
  fail "sing-box.service is not active"
fi

if systemctl is-enabled --quiet sing-box 2>/dev/null; then
  pass "sing-box.service is enabled"
else
  warn "sing-box.service is not enabled"
fi

if systemctl is-active --quiet sing-box; then
  sb_pid=$(systemctl show -p MainPID --value sing-box)
  sb_mem=$(systemctl show -p MemoryCurrent --value sing-box 2>/dev/null || true)
  printf '    PID: %s\n' "$sb_pid"
  [[ -n "$sb_mem" && "$sb_mem" != "[not set]" ]] && printf '    MemoryCurrent: %s bytes\n' "$sb_mem"
fi

section "SOCKS Listener"
if ss -lnt 2>/dev/null | awk -v p=":$SOCKS_PORT" '$4 ~ p"$" {found=1} END{exit !found}'; then
  pass "SOCKS TCP listener is listening on port $SOCKS_PORT"
else
  fail "SOCKS TCP listener not found on port $SOCKS_PORT"
fi

section "Active Profile"
active_profile=""
if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
  active_profile=$(jq -r '.active // empty' "$STATE_FILE")
fi
if [[ -n "$active_profile" ]]; then
  pass "State file active profile: $active_profile"
else
  warn "No active profile found in state file"
fi

outbound_tag=""
outbound_server=""
outbound_port=""
outbound_type=""
if [[ -f "$CONFIG_FILE" ]] && jq -e '.outbounds[0]' "$CONFIG_FILE" >/dev/null 2>&1; then
  outbound_tag=$(jq -r '.outbounds[0].tag // empty' "$CONFIG_FILE")
  outbound_type=$(jq -r '.outbounds[0].type // empty' "$CONFIG_FILE")
  outbound_server=$(jq -r '.outbounds[0].server // empty' "$CONFIG_FILE")
  outbound_port=$(jq -r '.outbounds[0].server_port // empty' "$CONFIG_FILE")
  printf '    Type   : %s\n' "$outbound_type"
  printf '    Tag    : %s\n' "$outbound_tag"
  printf '    Server : %s\n' "$outbound_server"
  printf '    Port   : %s\n' "$outbound_port"
  if [[ -n "$active_profile" && "$active_profile" == "$outbound_tag" ]]; then
    pass "State active profile matches generated outbound"
  elif [[ -n "$active_profile" ]]; then
    warn "State active profile ($active_profile) differs from generated outbound ($outbound_tag)"
  fi
fi

section "Outbound TLS / Transport"
if [[ -n "$outbound_port" ]]; then
  tls_enabled=$(jq -r '.outbounds[0].tls.enabled // false' "$CONFIG_FILE")
  transport_type=$(jq -r '.outbounds[0].transport.type // empty' "$CONFIG_FILE")
  printf '    TLS       : %s\n' "$tls_enabled"
  printf '    Transport : %s\n' "${transport_type:-none}"
  printf '    Server    : %s\n' "$outbound_server"
  printf '    Port      : %s\n' "$outbound_port"

  case "$outbound_port" in
    80|8080|8880|2052|2082|2086|2095)
      [[ "$tls_enabled" == "false" ]] && pass "HTTP port $outbound_port has TLS disabled" || fail "HTTP port $outbound_port unexpectedly has TLS enabled"
      ;;
    443|2053|2083|2087|2096|8443)
      [[ "$tls_enabled" == "true" ]] && pass "HTTPS port $outbound_port has TLS enabled" || fail "HTTPS port $outbound_port unexpectedly has TLS disabled"
      ;;
  esac

  if [[ "$transport_type" == "ws" ]]; then
    ws_path=$(jq -r '.outbounds[0].transport.path // empty' "$CONFIG_FILE")
    ed=$(jq -r '.outbounds[0].transport.max_early_data // empty' "$CONFIG_FILE")
    ehn=$(jq -r '.outbounds[0].transport.early_data_header_name // empty' "$CONFIG_FILE")
    host=$(jq -r '.outbounds[0].transport.headers.Host // empty' "$CONFIG_FILE")
    printf '    WS path   : %s\n' "$ws_path"
    printf '    WS Host   : %s\n' "$host"
    printf '    EarlyData : %s\n' "${ed:-none}"
    printf '    ED header : %s\n' "${ehn:-none}"
    if [[ "$ws_path" == *'?ed='* ]]; then
      fail "WebSocket path still contains ?ed=; generator parsing is incorrect"
    elif [[ -n "$ed" ]]; then
      pass "WebSocket Early Data is represented by sing-box transport fields"
    else
      pass "WebSocket path has no embedded ?ed= parameter"
    fi
  fi
fi

section "DNS / Name Resolution"
if [[ -n "$outbound_server" ]]; then
  if getent ahosts "$outbound_server" >/tmp/smart-proxy-dns.out 2>/dev/null; then
    first_ip=$(awk 'NR==1{print $1}' /tmp/smart-proxy-dns.out)
    pass "Outbound server resolves: $outbound_server -> $first_ip"
  else
    fail "Outbound server does not resolve: $outbound_server"
  fi
fi

section "Direct Connectivity"
if [[ -n "$outbound_server" && -n "$outbound_port" ]]; then
  if timeout 5 bash -c "</dev/tcp/$outbound_server/$outbound_port" >/dev/null 2>&1; then
    pass "TCP connectivity to $outbound_server:$outbound_port succeeded"
  else
    fail "TCP connectivity to $outbound_server:$outbound_port failed"
  fi
fi

section "SOCKS HTTP Test"
if curl --silent --show-error --fail --max-time 15 --socks5-hostname "127.0.0.1:$SOCKS_PORT" -o /tmp/smart-proxy-ip.txt https://ip.sb; then
  ip=$(tr -d '\r\n ' < /tmp/smart-proxy-ip.txt)
  pass "SOCKS HTTPS request succeeded (ip.sb)"
  printf '    Exit IP: %s\n' "$ip"
else
  fail "SOCKS HTTPS request failed"
fi

section "SOCKS Headers / HTTP Reachability"
if curl --silent --show-error --max-time 15 -I --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://www.cloudflare.com >/tmp/smart-proxy-headers.out 2>&1; then
  code=$(awk 'toupper($1) ~ /^HTTP\// {print $2; exit}' /tmp/smart-proxy-headers.out)
  pass "SOCKS HTTPS HEAD request succeeded${code:+ (HTTP $code)}"
else
  fail "SOCKS HTTPS HEAD request failed"
fi

section "Download Test"
url="https://speed.hetzner.de/100MB.bin"
if curl --silent --show-error --fail --max-time 20 --connect-timeout 10 --socks5-hostname "127.0.0.1:$SOCKS_PORT" -r 0-1048575 -o /tmp/smart-proxy-download.bin "$url"; then
  bytes=$(wc -c < /tmp/smart-proxy-download.bin)
  pass "Download test succeeded: ${bytes} bytes received"
else
  warn "Download test could not complete (remote test object may be unavailable)"
fi

section "Upload Test"
tmp_upload=$(mktemp)
trap 'rm -f "$tmp_upload" /tmp/smart-proxy-singbox-check.out /tmp/smart-proxy-ip.txt /tmp/smart-proxy-dns.out /tmp/smart-proxy-headers.out /tmp/smart-proxy-download.bin' EXIT
head -c 262144 /dev/urandom > "$tmp_upload"
if curl --silent --show-error --fail --max-time 20 --connect-timeout 10 --socks5-hostname "127.0.0.1:$SOCKS_PORT" -X POST --data-binary "@$tmp_upload" https://httpbin.org/post -o /tmp/smart-proxy-upload.out 2>/dev/null; then
  uploaded=$(wc -c < "$tmp_upload")
  pass "Upload test succeeded: ${uploaded} bytes sent"
else
  warn "Upload test failed or remote endpoint rejected the request"
fi

section "Recent sing-box Errors"
if journalctl -u sing-box -n 120 --no-pager 2>/dev/null | grep -E 'ERROR|FATAL|panic|unexpected EOF|bad handshake|first record' | tail -n 12; then
  warn "Recent sing-box errors found above"
else
  pass "No recent sing-box error lines matched common failure patterns"
fi

section "Timer / Reload Service"
if systemctl is-active --quiet reload.timer; then
  pass "reload.timer is active"
  systemctl list-timers reload.timer --no-pager 2>/dev/null | sed 's/^/    /'
else
  warn "reload.timer is not active"
fi
if systemctl is-active --quiet reload.service; then
  warn "reload.service is currently running"
else
  pass "reload.service is not currently running"
fi

section "Result"
elapsed=$(( $(date +%s) - START_TIME ))
printf 'Passed : %d\n' "$PASS"
printf 'Warnings: %d\n' "$WARN"
printf 'Failed : %d\n' "$FAIL"
printf 'Time   : %ss\n' "$elapsed"

if (( FAIL > 0 )); then
  printf '\nDIAGNOSTIC RESULT: FAIL\n'
  exit 1
elif (( WARN > 0 )); then
  printf '\nDIAGNOSTIC RESULT: PASS WITH WARNINGS\n'
  exit 0
else
  printf '\nDIAGNOSTIC RESULT: PASS\n'
  exit 0
fi
