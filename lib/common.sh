#!/usr/bin/env bash
set -euo pipefail

PROJECT="Smart Proxy Server"
VERSION="2.0.1"
INSTALL_DIR="/opt/smart-proxy"
CONFIG_DIR="/etc/sing-box"
PROFILE_DIR="$CONFIG_DIR/profiles"
LOG_DIR="/var/log/smartproxy"
LOG_FILE="$LOG_DIR/install.log"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
mkdir -p "$LOG_DIR"
log(){ echo -e "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"; }
info(){ log "${GREEN}[INFO]${NC} $1"; }
warn(){ log "${YELLOW}[WARN]${NC} $1"; }
error(){ log "${RED}[ERROR]${NC} $1"; exit 1; }
require_root(){ [ "$EUID" -eq 0 ] || error "Run as root"; }
