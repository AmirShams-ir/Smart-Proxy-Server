#!/usr/bin/env bash
# ==============================================================================
# Smart Proxy Server - Common Script
# https://github.com/AmirShams-ir/Smart-Proxy-Server
# Copyright (c) 2026 Amir Shams
# Licensed under Apache-2.0
# ==============================================================================
set -Eeuo pipefail

VERSION="2.0.3"
PROJECT="Smart Proxy Server"
SUPPORTED_OS=("debian" "ubuntu")
readonly BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SYSTEM_CONFIG_DIR="/etc/smartproxy"
readonly CONFIG_DIR="${BASE_DIR}/config"
readonly LIB_DIR="${BASE_DIR}/lib"
readonly PROFILE_DIR="${BASE_DIR}/profiles"
readonly LOG_DIR="/var/log/smartproxy"
readonly LOG_FILE="${LOG_DIR}/install.log"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
info(){ printf "${BLUE}[*] %s${RESET}\n" "$1"; }
success(){ printf "${GREEN}[✓] %s${RESET}\n" "$1"; }
warning(){ printf "${YELLOW}[!] %s${RESET}\n" "$1"; }
fatal(){ printf "${RED}[✗] %s${RESET}\n" "$1"; exit 1; }
banner(){ cat <<EOF

==============================================================
                Smart Proxy Server
                  Version ${VERSION}
==============================================================
Repository
https://github.com/AmirShams-ir/Smart-Proxy-Server
==============================================================

EOF
}
require_root(){ [[ "$EUID" -eq 0 ]] || fatal "Please run as root."; }
require_os(){ [[ -f /etc/os-release ]] || fatal "Cannot detect operating system."; local ID PRETTY_NAME; source /etc/os-release; case "$ID" in debian|ubuntu) success "$PRETTY_NAME";; *) fatal "Unsupported operating system.";; esac; }
start_log(){ mkdir -p "$LOG_DIR"; touch "$LOG_FILE"; exec > >(tee -a "$LOG_FILE"); exec 2>&1; }
run_script(){ local script="$1"; [[ -f "$script" ]] || fatal "Missing $(basename "$script")"; info "Executing $(basename "$script")"; source "$script"; }
config_get(){ local KEY="$1" FILE="${CONFIG_DIR}/defaults.conf"; [[ -f "$FILE" ]] || return 1; awk -F= -v key="$KEY" '$1 == key { value=$0; sub(/^[^=]*=/,"",value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); if (value ~ /^".*"$/) { sub(/^"/,"",value); sub(/"$/,"",value); } print value; exit }' "$FILE"; }
