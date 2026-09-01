#!/usr/bin/env bash
# ==============================================================================
# Smart Proxy Server - Diagnostic Test Suite
# https://github.com/AmirShams-ir/Smart-Proxy-Server
# Copyright (c) 2026 Amir Shams
# Licensed under Apache-2.0
# ==============================================================================
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/sing-box/config.json"
STATE_FILE="/etc/sing-box/proxy-state.json"
DEFAULTS_FILE="$BASE_DIR/config/defaults.conf"
LOG_DIR="/var/log/smartproxy"

PASS=0
WARN=0
FAIL=0
TMP_DIR="$(mktemp -d /tmp/smartproxy-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

info(){ printf '[*] %s\n' "$*"; }
ok(){ printf '[✓] %s\n' "$*"; PASS=$((PASS+1)); }
warn(){ printf '[!] %s\n' "$*"; WARN=$((WARN+1)); }
fail(){ printf '[✗] %s\n' "$*"; FAIL=$((FAIL+1)); }
section(){ printf '\n============================================================\n%s\n============================================================\n' "$*"; }

get_default(){
    local key="$1"
    [[ -f "$DEFAULTS_FILE" ]] || return 1
    awk -F= -v k="$key" '$1==k {v=$0; sub(/^[^=]*=/,"",v); gsub(/^ +| +$/,"",v); print v; exit}' "$DEFAULTS_FILE"
}

require_cmd(){ command -v "$1" >/dev/null 2>&1; }

http_test(){
    local url="$1" label="$2" code
    code="$(curl -4 -L --max-time 10 --connect-timeout 5 -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        ok "$label: HTTP $code"
    else
        fail "$label: HTTP test failed (code=${code:-error})"
    fi
}

socks_http_test(){
    local proxy="$1" url="$2" label="$3" code
    code="$(curl -4 -L --max-time 15 --connect-timeout 5 --socks5-hostname "$proxy" -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        ok "$label: HTTP $code through SOCKS"
    else
        fail "$label: SOCKS HTTP test failed (code=${code:-error})"
    fi
}

measure_download(){
    local proxy="$1" url="$2" out="$TMP_DIR/download.out" bytes seconds mbps http_code
    local start_ns end_ns
    start_ns="$(date +%s%N)"
    http_code="$(curl -4 -L --max-time 30 --connect-timeout 5 --socks5-hostname "$proxy" \
        -sS -o "$out" -w '%{http_code}' "$url" 2>"$TMP_DIR/download.err" || true)"
    end_ns="$(date +%s%N)"

    if [[ "$http_code" =~ ^[23][0-9][0-9]$ ]] && [[ -s "$out" ]]; then
        bytes="$(wc -c < "$out")"
        seconds="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{print (b-a)/1000000000}')"
        mbps="$(awk -v b="$bytes" -v s="$seconds" 'BEGIN{if(s>0) printf "%.2f", (b*8/1000000)/s; else print "0"}')"
        ok "Download test: ${bytes} bytes in ${seconds}s (~${mbps} Mbit/s, HTTP ${http_code})"
    else
        warn "Download test unavailable/failed (HTTP ${http_code:-error}); proxy connectivity remains independently tested"
        if [[ -s "$TMP_DIR/download.err" ]]; then
            sed 's/^/    /' "$TMP_DIR/download.err" | tail -n 3
        fi
    fi
}

measure_upload(){
    local proxy="$1" url="$2" payload="$TMP_DIR/upload.bin" bytes=1048576 start_ns end_ns seconds mbps http_code
    if ! head -c "$bytes" /dev/zero > "$payload"; then
        warn "Upload test: could not create payload"
        return
    fi
    start_ns="$(date +%s%N)"
    http_code="$(curl -4 --max-time 30 --connect-timeout 5 --socks5-hostname "$proxy" \
        -sS -o /dev/null -w '%{http_code}' -X POST --data-binary "@$payload" "$url" 2>"$TMP_DIR/upload.err" || true)"
    end_ns="$(date +%s%N)"
    if [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
        seconds="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{print (b-a)/1000000000}')"
        mbps="$(awk -v b="$bytes" -v s="$seconds" 'BEGIN{if(s>0) printf "%.2f", (b*8/1000000)/s; else print "0"}')"
        ok "Upload test: ${bytes} bytes in ${seconds}s (~${mbps} Mbit/s, HTTP ${http_code})"
    else
        warn "Upload test unavailable/failed (HTTP ${http_code:-error}); endpoint limitation does not imply proxy failure"
        if [[ -s "$TMP_DIR/upload.err" ]]; then
            sed 's/^/    /' "$TMP_DIR/upload.err" | tail -n 3
        fi
    fi
}

section "Smart Proxy Server Diagnostics"
printf 'Project : %s\n' "$BASE_DIR"
printf 'Date    : %s\n' "$(date '+%F %T %Z')"
printf 'Host    : %s\n' "$(hostname)"

section "1. Dependencies"
for cmd in sing-box curl jq ss systemctl awk sed grep; do
    if require_cmd "$cmd"; then ok "Command available: $cmd"; else fail "Missing command: $cmd"; fi
done

section "2. Service Status"
if systemctl is-enabled --quiet sing-box 2>/dev/null; then ok "sing-box.service enabled"; else warn "sing-box.service is not enabled"; fi
if systemctl is-active --quiet sing-box 2>/dev/null; then ok "sing-box.service active"; else fail "sing-box.service is not active"; fi
if systemctl is-enabled --quiet reload.timer 2>/dev/null; then ok "reload.timer enabled"; else warn "reload.timer is not enabled"; fi
if systemctl is-active --quiet reload.timer 2>/dev/null; then ok "reload.timer active"; else warn "reload.timer is not active"; fi

section "3. sing-box Configuration"
if [[ -f "$CONFIG_FILE" ]]; then
    ok "Config exists: $CONFIG_FILE"
else
    fail "Config missing: $CONFIG_FILE"
fi
if [[ -f "$CONFIG_FILE" ]] && sing-box check -c "$CONFIG_FILE" >/tmp/smartproxy-singbox-check.$$ 2>&1; then
    ok "sing-box config validation passed"
else
    fail "sing-box config validation failed"
    [[ -f /tmp/smartproxy-singbox-check.$$ ]] && sed 's/^/    /' /tmp/smartproxy-singbox-check.$$
fi
rm -f /tmp/smartproxy-singbox-check.$$

if [[ -f "$CONFIG_FILE" ]] && require_cmd jq; then
    active_tag="$(jq -r '.route.final // .outbounds[0].tag // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$active_tag" ]]; then ok "Active outbound: $active_tag"; else warn "Could not determine active outbound"; fi
    socks_listen="$(jq -r '.inbounds[] | select(.type=="socks" or .type=="mixed") | "\(.listen):\(.listen_port)"' "$CONFIG_FILE" 2>/dev/null | head -n1 || true)"
    [[ -n "$socks_listen" ]] && info "SOCKS inbound: $socks_listen"
fi

section "4. Listening Ports"
SOCKS_PORT="$(jq -r 'first(.inbounds[]? | select(.type=="socks" or .type=="mixed") | .listen_port) // 1080' "$CONFIG_FILE" 2>/dev/null || echo 1080)"
if ss -lnt 2>/dev/null | grep -Eq "[:.]${SOCKS_PORT}[[:space:]]"; then
    ok "SOCKS port $SOCKS_PORT is listening"
else
    warn "SOCKS port $SOCKS_PORT is not listening"
fi
if [[ -f "$CONFIG_FILE" ]] && require_cmd jq; then
    while read -r listen_port; do
        [[ -n "$listen_port" ]] || continue
        if ss -lnt 2>/dev/null | grep -Eq "[:.]${listen_port}[[:space:]]"; then ok "Configured TCP port $listen_port is listening"; else warn "Configured TCP port $listen_port is not listening"; fi
    done < <(jq -r '.inbounds[]? | .listen_port? // empty' "$CONFIG_FILE" 2>/dev/null | sort -nu)
fi

section "5. Basic Network Connectivity"
http_test "https://cp.cloudflare.com/generate_204" "Direct Internet connectivity"
if require_cmd dig; then
    if dig +short +time=3 +tries=1 cloudflare.com | grep -q .; then ok "DNS resolution works"; else warn "DNS resolution failed"; fi
else
    warn "dig not installed; DNS test skipped"
fi

section "6. Current Proxy Connectivity"
SOCKS_PROXY="127.0.0.1:${SOCKS_PORT}"
if ss -lnt 2>/dev/null | grep -Eq "[:.]${SOCKS_PORT}[[:space:]]"; then
    if curl -4 --max-time 10 --connect-timeout 5 --socks5-hostname "$SOCKS_PROXY" -sS -o "$TMP_DIR/ip.txt" https://ip.sb; then
        ip="$(tr -d '\r\n ' < "$TMP_DIR/ip.txt")"
        [[ -n "$ip" ]] && ok "SOCKS connectivity works (public IP: $ip)" || warn "SOCKS request succeeded but returned no IP"
    else
        fail "SOCKS connectivity test failed"
    fi
    socks_http_test "$SOCKS_PROXY" "https://cp.cloudflare.com/generate_204" "Proxy HTTPS"
else
    warn "SOCKS tests skipped because port $SOCKS_PORT is not listening"
fi

section "7. Active Outbound Diagnostics"
if [[ -f "$CONFIG_FILE" ]] && require_cmd jq; then
    if [[ -n "${active_tag:-}" ]]; then
        jq --arg tag "$active_tag" '.outbounds[] | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null | sed 's/^/    /' || true
    else
        warn "Active outbound details unavailable"
    fi
fi

section "8. Download / Upload"
if ss -lnt 2>/dev/null | grep -Eq "[:.]${SOCKS_PORT}[[:space:]]"; then
    # Prefer Cloudflare's dedicated speed endpoint. If unavailable, report WARN only.
    if curl -4 -L --max-time 15 --connect-timeout 5 --socks5-hostname "$SOCKS_PROXY" \
        -sS -o /dev/null -w '%{http_code}' https://speed.cloudflare.com/__down?bytes=1048576 2>"$TMP_DIR/speed-probe.err" | grep -Eq '^2[0-9][0-9]$'; then
        measure_download "$SOCKS_PROXY" "https://speed.cloudflare.com/__down?bytes=1048576"
    else
        warn "Cloudflare speed download endpoint unavailable; download throughput test skipped"
    fi
    if require_cmd curl; then
        measure_upload "$SOCKS_PROXY" "https://httpbin.org/post"
    fi
else
    warn "Transfer tests skipped because SOCKS is unavailable"
fi

section "9. Logs"
if systemctl is-active --quiet sing-box 2>/dev/null; then
    info "Recent sing-box issues (last 5 minutes):"
    recent_errors="$(journalctl -u sing-box --since '5 min ago' --no-pager 2>/dev/null | grep -Ei 'error|warn|fail|eof|handshake|400|timeout' | tail -n 15 || true)"
    if [[ -n "$recent_errors" ]]; then
        sed 's/^/    /' <<< "$recent_errors"
        warn "Recent sing-box warnings/errors detected"
    else
        ok "No matching recent sing-box errors"
    fi
fi
if [[ -f "$LOG_DIR/proxy.log" ]]; then
    info "Recent Smart Proxy issues (last 50 lines):"
    recent_proxy="$(tail -n 50 "$LOG_DIR/proxy.log" 2>/dev/null | grep -Ei 'error|fail|eof|handshake|400|timeout' || true)"
    if [[ -n "$recent_proxy" ]]; then
        sed 's/^/    /' <<< "$recent_proxy"
        warn "Matching entries found in recent Smart Proxy log"
    else
        ok "No matching recent Smart Proxy log errors"
    fi
fi

section "10. State"
if [[ -f "$STATE_FILE" ]] && require_cmd jq; then
    if jq empty "$STATE_FILE" >/dev/null 2>&1; then
        ok "State JSON is valid"
        jq . "$STATE_FILE" 2>/dev/null | sed 's/^/    /'
    else
        fail "State JSON is invalid"
    fi
else
    warn "State file unavailable"
fi

section "Summary"
printf 'PASS : %d\nWARN : %d\nFAIL : %d\n' "$PASS" "$WARN" "$FAIL"
if (( FAIL > 0 )); then
    printf '\nResult: FAIL — inspect the sections above.\n'
    exit 1
elif (( WARN > 0 )); then
    printf '\nResult: PASS WITH WARNINGS — inspect the sections above.\n'
    exit 0
else
    printf '\nResult: ALL TESTS PASSED.\n'
    exit 0
fi
