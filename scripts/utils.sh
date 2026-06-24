#!/bin/bash
# Utilities and helpers for xray-manager

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0;37m' # No Color

log_info() {
    echo -e "${GREEN}[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1${NC}" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1${NC}" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1${NC}" | tee -a "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Vui lòng chạy script với quyền root (sudo).${NC}"
        exit 1
    fi
}

init_dirs() {
    mkdir -p "$DATA_DIR" "$SCRIPTS_DIR" "$TEMPLATES_DIR"
    if [ ! -f "$USER_DB" ]; then
        echo "[]" > "$USER_DB"
    fi
    if [ ! -f "$NODE_DB" ]; then
        echo "[]" > "$NODE_DB"
    fi
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
    fi
}