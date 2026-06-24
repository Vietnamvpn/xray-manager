#!/bin/bash
# Module quản lý Node - Bản Cập Nhật Hoàn Chỉnh (Chống Lỗi JQ & Xử Lý Đường Dẫn)

# Khai báo màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/etc/xray-manager"

if [ -f "${BASE_DIR}/config.conf" ]; then
    source "${BASE_DIR}/config.conf"
fi

# Tự động nhận diện thư mục chứa file cấu hình mẫu 
if [ -d "${BASE_DIR}/layouts" ]; then
    TEMPLATES_DIR="${BASE_DIR}/layouts"
elif [ -d "${BASE_DIR}/templates" ]; then
    TEMPLATES_DIR="${BASE_DIR}/templates"
else
    TEMPLATES_DIR="${INSTALL_DIR}/templates"
fi

# Cấu hình các đường dẫn hệ thống chính xác
NODE_DB="${NODE_DB:-$INSTALL_DIR/data/nodes.json}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$INSTALL_DIR/scripts}"

if [ -f "${SCRIPTS_DIR}/utils.sh" ]; then
    source "${SCRIPTS_DIR}/utils.sh"
fi

# Khởi tạo file database lưu trữ Node nếu chưa có
if [ ! -f "$NODE_DB" ] || [ ! -s "$NODE_DB" ] || ! jq . "$NODE_DB" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$NODE_DB")"
    echo "[]" > "$NODE_DB"
fi

apply_config() {
    local active_config="${XRAY_CONFIG_DIR}/config.json"
    local base_tpl="${TEMPLATES_DIR}/base.json"
    
    if [ ! -f "$base_tpl" ]; then
        echo -e "${RED}[LỖI] Không tìm thấy file mẫu gốc tại: $base_tpl${NC}"
        return 1
    fi

    if [ ! -s "$NODE_DB" ] || [ "$(cat "$NODE_DB")" = "null" ] || [ "$(cat "$NODE_DB")" = "[]" ]; then
        echo -e "${YELLOW}[CẢNH BÁO] Database trống. Đang đưa cấu hình Xray về mặc định...${NC}"
        cp "$base_tpl" "$active_config"
        systemctl restart xray 2>/dev/null
        return 0
    fi

    if ! jq --slurpfile nodes "$NODE_DB" '.inbounds += $nodes[0]' "$base_tpl" > "${active_config}.tmp" 2>/dev/null; then
        echo -e "${RED}[LỖI] Lỗi cú pháp JSON khi trộn dữ liệu vào cấu hình chính.${NC}"
        rm -f "${active_config}.tmp"
        return 1
    fi

    if [ ! -s "${active_config}.tmp" ]; then
        echo -e "${RED}[LỖI NGHIÊM TRỌNG] File cấu hình xử lý bị rỗng! Hủy bỏ ghi đè.${NC}"
        rm -f "${active_config}.tmp"
        return 1
    fi

    mv "${active_config}.tmp" "$active_config"
    echo -e "${YELLOW}Đang khởi động lại dịch vụ Xray Core...${NC}"
    if systemctl restart xray 2>/dev/null; then
        echo -e "${GREEN}[THÀNH CÔNG] Kích hoạt cấu hình hệ thống thành công!${NC}"
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
    echo -e "${YELLOW}[ĐƯỜNG DẪN DATABASE]:${NC} $NODE_DB"
    echo -e "${YELLOW}[THƯ MỤC MẪU]:${NC} $TEMPLATES_DIR"
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
    echo -e "${GREEN}--- Danh Sách Node Hệ Thống ---${NC}"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    printf "%-18s | %-10s | %-12s | %-15s\n" "TAG ĐỊNH DANH" "PORT" "GIAO THỨC" "TRANSPORT"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    
    if [ "$(jq '. | length' "$NODE_DB" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "          (Hiện tại không có Node nào trong file Database)"
    else
        jq -r '.[] | "\(.tag) \(.port) \(.protocol) \(.streamSettings.network // "tcp")"' "$NODE_DB" 2>/dev/null | while read -r tag port proto net; do
            printf "%-18s | %-10s | %-12s | %-15s\n" "$tag" "$port" "$proto" "$net"
        done
    fi
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    echo ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

add_node() {
    mkdir -p /tmp
    echo "[]" > /tmp/session_nodes.json
    
    while true; do
        clear
        echo -e "${GREEN}--- Thêm Node Mạng Mới ---${NC}"
        echo -e "Chọn giao thức mạng: 1. vless | 2. vmess | 3. trojan | 4. hy2"
        read -p "Nhập số lựa chọn (1-4): " proto_choice
        
        local protocol=""
        case $proto_choice in
            1) protocol="vless" ;;
            2) protocol="vmess" ;;
            3) protocol="trojan" ;;
            4) protocol="hy2" ;;
            *) echo -e "${RED}[LỖI] Lựa chọn không hợp lệ!${NC}"; sleep 1; continue ;;
        esac

        local tpl_file=""
        if [ "$protocol" != "hy2" ]; then
            echo -e "\nChọn mạng truyền tải (Transport): 1. ws | 2. tcp | 3. grpc | 4. xhttp"
            read -p "Nhập số lựa chọn (1-4): " trans_choice
            local transport=""
            case $trans_choice in
                1) transport="ws" ;;
                2) transport="tcp" ;;
                3) transport="grpc" ;;
                4) transport="xhttp" ;;
                *) echo -e "${RED}[LỖI] Lựa chọn không hợp lệ!${NC}"; sleep 1; continue ;;
            esac
            tpl_file="${TEMPLATES_DIR}/${protocol}/${transport}.json"
        else
            tpl_file="${TEMPLATES_DIR}/hy2.json"
        fi

        if [ ! -f "$tpl_file" ]; then
            echo -e "${RED}[LỖI CHẶN] Không tồn tại file mẫu tại: $tpl_file${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để cấu hình lại..."
            continue
        fi

        echo ""
        read -p "Nhập Domain quản lý Node (Bỏ trống lấy IP VPS): " input_domain
        local domain_or_ip=""
        if [ -z "$input_domain" ]; then
            domain_or_ip=$(curl -s --max-time 3 https://api.ipify.org || echo "127.0.0.1")
        else
            domain_or_ip="$input_domain"
        fi

        read -p "Nhập cổng kết nối Port (Bỏ trống tự cấp ngẫu nhiên): " input_port
        local port=0
        if [ -z "$input_port" ]; then
            while true; do
                port=$((RANDOM % 55000 + 10000))
                if ! jq -e --argjson p "$port" '.[] | select(.port == $p)' "$NODE_DB" >/dev/null 2>&1; then break; fi
            done
            echo -e "${YELLOW}-> Cấp Port tự động: $port${NC}"
        else
            port="$input_port"
            if jq -e --argjson p "$port" '.[] | select(.port == $p)' "$NODE_DB" >/dev/null 2>&1; then
                echo -e "${RED}[LỖI] Port $port đã tồn tại trong hệ thống!${NC}"; sleep 2; continue
            fi
        fi

        read -p "Nhập SNI / ServerName (Bỏ trống mặc định www.cloudflare.com): " input_sni
        local sni="${input_sni:-"www.cloudflare.com"}"
        local tag="${protocol}-${port}"

        if ! jq --arg p "$port" --arg t "$tag" --arg sni "$sni" '
            .port = ($p|tonumber) | 
            .tag = $t | 
            (if .streamSettings.tlsSettings then .streamSettings.tlsSettings.serverName = $sni else . end) | 
            (if .streamSettings.realitySettings then .streamSettings.realitySettings.serverName = $sni else . end)
        ' "$tpl_file" > /tmp/single_node.json 2>/dev/null; then
            echo -e "${RED}[LỖI CÚ PHÁP] Không thể biên dịch file JSON mẫu thông qua JQ.${NC}"
            sleep 3
            continue
        fi

        jq --slurpfile n /tmp/single_node.json '. += $n' /tmp/session_nodes.json > /tmp/session_nodes.tmp && mv /tmp/session_nodes.tmp /tmp/session_nodes.json

        echo -e "${GREEN}[OK] Đã đưa Node [$tag] vào hàng đợi phiên thành công.${NC}"
        read -p "Bạn có muốn thêm tiếp Node khác vào chuỗi không? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then break; fi
    done

    local count=$(jq '. | length' /tmp/session_nodes.json 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}Hàng đợi trống. Hủy lưu.${NC}"
        return
    fi

    clear
    echo -e "${GREEN}--- Thiết lập tài khoản User kết nối ---${NC}"
    read -p "Nhập tên/Email User (Bỏ trống tự gán): " username
    username=${username:-"client_$((RANDOM%900+100))"}
    
    read -p "Nhập ID/Password kết nối (Bỏ trống tự tạo UUID): " user_cred
    user_cred=${user_cred:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "pass_$((RANDOM%90000+10000))")}

    jq --arg cred "$user_cred" --arg email "$username" '
      map(
        if .protocol == "vless" or .protocol == "vmess" then .settings.clients = [{"id": $cred, "email": $email}]
        elif .protocol == "trojan" then .settings.clients = [{"password": $cred, "email": $email}]
        elif .protocol == "hysteria2" or .protocol == "hysteria" or .protocol == "hy2" then .settings.users = [{"password": $cred}]
        else . end
      )
    ' /tmp/session_nodes.json > /tmp/session_nodes_final.json 2>/dev/null

    if [ ! -s /tmp/session_nodes_final.json ]; then
        echo -e "${RED}[LỖI] Quá trình đóng gói User bị rỗng. Hủy bỏ!${NC}"
        rm -f /tmp/session_nodes.json /tmp/single_node.json /tmp/session_nodes_final.json
        read -n 1 -s -r -p "Bấm phím bất kỳ..."
        return
    fi

    if ! jq --slurpfile new_nodes /tmp/session_nodes_final.json '. += $new_nodes[0]' "$NODE_DB" > "${NODE_DB}.tmp" 2>/dev/null; then
        echo -e "${RED}[LỖI] Không thể nạp dữ liệu vào database tổng.${NC}"
        rm -f "${NODE_DB}.tmp"
    else
        mv "${NODE_DB}.tmp" "$NODE_DB"
        echo -e "\n${GREEN}[THÀNH CÔNG RỰC RỠ] Đã ghi dữ liệu vào file cứng thành công!${NC}"
        echo -e "${BLUE}-> Đường dẫn Database: $NODE_DB${NC}"
    fi
    
    rm -f /tmp/session_nodes.json /tmp/single_node.json /tmp/session_nodes_final.json
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại menu..."
}

delete_node() {
    clear
    echo -e "${RED}--- Gỡ Bỏ Cấu Hình Node ---${NC}"
    read -p "Nhập chính xác chuỗi Tag của Node muốn xóa: " tag
    if [ -z "$tag" ]; then return; fi
    
    jq --arg t "$tag" 'del(.[] | select(.tag == $t))' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    echo -e "${GREEN}Đã gỡ bỏ cấu hình Node khỏi Database.${NC}"
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

while true; do
    show_node_menu
    read -r choice
    case $choice in
        1) list_nodes ;;
        2) add_node ;;
        3) delete_node ;;
        0) break ;;
        *) echo -e "${RED}Lựa chọn không hợp lệ!${NC}" ; sleep 1 ;;
    esac
done