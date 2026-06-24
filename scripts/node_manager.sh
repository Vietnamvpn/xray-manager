#!/bin/bash
# Module quản lý Node - Bản Vá Xử Lý Đường Dẫn & Chặn Dữ Liệu Rỗng Tuyệt Đối

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/etc/xray-manager"

if [ -f "${BASE_DIR}/config.conf" ]; then
    source "${BASE_DIR}/config.conf"
fi

# Định vị đường dẫn tuyệt đối
NODE_DB="${NODE_DB:-$INSTALL_DIR/data/nodes.json}"
TEMPLATES_DIR="${TEMPLATES_DIR:-$INSTALL_DIR/templates}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$INSTALL_DIR/scripts}"

source "${SCRIPTS_DIR}/utils.sh"
check_root

# Khởi tạo kích hoạt Database nếu chưa có hoặc bị lỗi
if [ ! -f "$NODE_DB" ] || [ ! -s "$NODE_DB" ] || ! jq . "$NODE_DB" < /dev/null >/dev/null 2>&1; then
    mkdir -p "$(dirname "$NODE_DB")"
    echo "[]" > "$NODE_DB"
fi

apply_config() {
    local active_config="${XRAY_CONFIG_DIR}/config.json"
    
    if [ ! -f "${TEMPLATES_DIR}/base.json" ]; then
        echo -e "${RED}[LỖI] Không tìm thấy file mẫu gốc tại: ${TEMPLATES_DIR}/base.json${NC}"
        return 1
    fi

    # Kiểm tra an toàn trước khi trộn vào file config chính thức
    if [ ! -s "$NODE_DB" ] || [ "$(cat "$NODE_DB")" = "null" ] || [ "$(cat "$NODE_DB")" = "" ]; then
        echo -e "${YELLOW}[CẢNH BÁO] Database hiện tại đang trống. Tiến hành đưa cấu hình Xray về mặc định.${NC}"
        cp "${TEMPLATES_DIR}/base.json" "$active_config"
        systemctl restart xray
        return 0
    fi

    if ! jq --slurpfile nodes "$NODE_DB" '.inbounds += $nodes[0]' "${TEMPLATES_DIR}/base.json" < /dev/null > "${active_config}.tmp"; then
        echo -e "${RED}[LỖI] Cú pháp JSON lỗi khi trộn vào config.json thực tế.${NC}"
        rm -f "${active_config}.tmp"
        return 1
    fi

    # CHẶN BIẾN THÀNH FILE RỖNG
    if [ ! -s "${active_config}.tmp" ]; then
        echo -e "${RED}[LỖI NGHIÊM TRỌNG] File cấu hình sau xử lý bị rỗng! Hủy bỏ thao tác ghi đè để bảo vệ hệ thống.${NC}"
        rm -f "${active_config}.tmp"
        return 1
    fi

    mv "${active_config}.tmp" "$active_config"
    echo -e "${YELLOW}Đang khởi động lại dịch vụ Xray Core...${NC}"
    if systemctl restart xray; then
        echo -e "${GREEN}[THÀNH CÔNG] Đồng bộ cấu hình hoạt động thành công!${NC}"
        echo -e "${BLUE}-> File cấu hình Xray thực tế nằm tại: $active_config${NC}"
        return 0
    else
        echo -e "${RED}[LỖI] Xray không thể khởi chạy với cấu hình mới.${NC}"
        return 1
    fi
}

show_node_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}             NODE MANAGER              ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${YELLOW}[ĐƯỜNG DẪN DATABASE HIỆN TẠI]:${NC}"
    echo -e "${GREEN}$NODE_DB${NC}"
    echo -e "${BLUE}--------------------------------------=${NC}"
    echo -e "1. Xem danh sách Node đang chạy"
    echo -e "2. Thêm chuỗi Node mới (Interactive)"
    echo -e "3. Xóa Node khỏi hệ thống"
    echo -e "0. Quay lại Menu chính"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn: "
}

list_nodes() {
    clear
    echo -e "${GREEN}--- Kiểm tra nội dung file: $NODE_DB ---${NC}"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    printf "%-18s | %-10s | %-12s | %-15s\n" "TAG ĐỊNH DANH" "PORT" "GIAO THỨC" "TRANSPORT"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    
    if [ "$(jq '. | length' "$NODE_DB" < /dev/null 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "          (Hiện tại file Database đang trống rỗng hoặc chỉ có [])"
    else
        jq -r '.[] | "\(.tag) \(.port) \(.protocol) \(.streamSettings.network // "udp")"' "$NODE_DB" < /dev/null 2>/dev/null | while read -r tag port proto net; do
            printf "%-18s | %-10s | %-12s | %-15s\n" "$tag" "$port" "$proto" "$net"
        done
    fi
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    echo ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

add_node() {
    echo "[]" > /tmp/session_nodes.json
    
    while true; do
        clear
        echo -e "${GREEN}--- Cấu Hình Thực Thể Node Mạng Mới ---${NC}"
        echo -e "Chọn giao thức mạng: 1. vless | 2. vmess | 3. trojan | 4. hy2"
        read -p "Nhập số lựa chọn (1-4): " proto_choice
        
        local protocol=""
        case $proto_choice in
            1) protocol="vless" ;; 2) protocol="vmess" ;; 3) protocol="trojan" ;; 4) protocol="hy2" ;;
            *) echo -e "${RED}[LỖI] Lựa chọn không hợp lệ!${NC}"; sleep 1; continue ;;
        esac

        local tpl_file=""
        if [ "$protocol" != "hy2" ]; then
            local transport=""
            echo -e "\nChọn mạng truyền tải (Transport) cho $protocol: 1. ws | 2. tcp | 3. grpc | 4. xhttp"
            read -p "Nhập số lựa chọn: " trans_choice
            case $trans_choice in 1) transport="ws";; 2) transport="tcp";; 3) transport="grpc";; 4) transport="xhttp";; *) echo -e "${RED}Lỗi nhập số!${NC}"; sleep 1; continue;; esac
            tpl_file="${TEMPLATES_DIR}/${protocol}/${transport}.json"
        else
            tpl_file="${TEMPLATES_DIR}/hy2.json"
        fi

        if [ ! -f "$tpl_file" ]; then
            echo -e "${RED}[LỖI THƯ MỤC MẪU] Không tồn tại file cấu hình mẫu tại: $tpl_file${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để cấu hình lại..."
            continue