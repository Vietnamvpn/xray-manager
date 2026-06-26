#!/bin/bash
# Utilities and helpers for xray-manager

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

apply_config() {
    local active_config="${XRAY_CONFIG_DIR}/config.json"
    local base_tpl="${TEMPLATES_DIR}/base.json"
    
    if [ ! -f "$base_tpl" ]; then
        echo -e "${RED}[LỖI] Không tìm thấy file mẫu gốc tại: $base_tpl${NC}"
        return 1
    fi

    if ! jq --slurpfile nodes "$NODE_DB" '.inbounds += $nodes[0]' "$base_tpl" > "${active_config}.tmp" 2>/dev/null; then
        echo -e "${RED}[LỖI] Lỗi cú pháp JSON khi trộn dữ liệu vào cấu hình chính.${NC}"
        rm -f "${active_config}.tmp"
        return 1
    fi

    mv "${active_config}.tmp" "$active_config"
    echo -e "${YELLOW}Đang khởi động lại dịch vụ Xray Core...${NC}"
    systemctl restart xray 2>/dev/null
    
    # KIỂM TRA TRẠNG THÁI SỐNG/CHẾT THỰC TẾ CỦA TIẾN TRÌNH
    sleep 1
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}[THÀNH CÔNG] XRAY ĐANG CHẠY BÌNH THƯỜNG!${NC}"
        echo -e "${GREEN}==============================================${NC}"
        return 0
    else
        echo -e "${RED}==============================================${NC}"
        echo -e "${RED}[THẤT BẠI] XRAY ĐÃ BỊ CRASH HOẶC TỪ CHỐI CHẠY!${NC}"
        echo -e "${YELLOW}Nguyên nhân có thể do file mẫu sai cú pháp hoặc trùng Port hệ thống.${NC}"
        echo -e "${YELLOW}Dùng lệnh sau để xem lỗi chi tiết: ${NC}journalctl -u xray --no-pager -n 20"
        echo -e "${RED}==============================================${NC}"
        return 1
    fi
}