#!/bin/bash
# Utilities and helpers for xray-manager

# Colors - ANSI-C Quoting
RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
BLUE=$'\e[34m'
CYAN=$'\e[36m'
NC=$'\e[0m'  # No Color (Reset)

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
    local active_config="${XRAY_CONFIG_DIR}/config.json"[cite: 5]
    local base_tpl="${TEMPLATES_DIR}/base.json"[cite: 5]
    
    if [ ! -f "$base_tpl" ]; then[cite: 5]
        echo -e "${RED}[LỖI] Không tìm thấy file mẫu gốc tại: $base_tpl${NC}"[cite: 5]
        return 1[cite: 5]
    fi[cite: 5]

    if ! jq --slurpfile nodes "$NODE_DB" \
            --slurpfile outbounds "${DATA_DIR}/outbounds.json" \
            --slurpfile routing "${DATA_DIR}/routing.json" \
            '.inbounds += $nodes[0] | .outbounds += $outbounds[0] | .routing.rules = $routing[0] + .routing.rules' \
            "$base_tpl" > "${active_config}.tmp" 2>/dev/null; then
        echo -e "${RED}[LỖI] Lỗi cú pháp JSON khi trộn dữ liệu vào cấu hình chính.${NC}"[cite: 5]
        rm -f "${active_config}.tmp"[cite: 5]
        return 1[cite: 5]
    fi[cite: 5]

    mv "${active_config}.tmp" "$active_config"[cite: 5]
    echo -e "${YELLOW}Đang khởi động lại dịch vụ Xray Core...${NC}"[cite: 5]
    systemctl restart xray 2>/dev/null[cite: 5]
    
    # KIỂM TRA TRẠNG THÁI SỐNG/CHẾT THỰC TẾ CỦA TIẾN TRÌNH[cite: 5]
    sleep 1[cite: 5]
    if systemctl is-active --quiet xray; then[cite: 5]
        echo -e ""[cite: 5]
        echo -e "${GREEN}[THÀNH CÔNG] XRAY ĐANG CHẠY BÌNH THƯỜNG!${NC}"[cite: 5]
        echo -e "${GREEN}----------------------------------------${NC}"[cite: 5]
        return 0[cite: 5]
    else[cite: 5]
        echo -e ""[cite: 5]
        echo -e "${RED}[THẤT BẠI] XRAY ĐÃ BỊ CRASH HOẶC TỪ CHỐI CHẠY!${NC}"[cite: 5]
        echo -e "${YELLOW}Nguyên nhân có thể do file mẫu sai cú pháp hoặc trùng Port hệ thống.${NC}"[cite: 5]
        echo -e "${YELLOW}Dùng lệnh sau để xem lỗi chi tiết: ${NC}journalctl -u xray --no-pager -n 20"[cite: 5]
        echo -e "${RED}-----------------------------------------------${NC}"[cite: 5]
        return 1[cite: 5]
    fi[cite: 5]
}