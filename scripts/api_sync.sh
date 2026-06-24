#!/bin/bash
# Module đồng bộ dữ liệu với web trung tâm (Singbox-Manager Panel)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

# Các biến API (thực tế sẽ đọc từ config.conf hoặc biến môi trường)
API_URL="https://panel.example.com/api/v1"
API_TOKEN="YOUR_SECRET_TOKEN_HERE"

show_sync_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}               API SYNC                ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Đẩy (Push) trạng thái Node lên Server"
    echo -e "2. Kéo (Pull) danh sách User từ Server"
    echo -e "0. Quay lại Menu chính"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn: "
}

push_node_status() {
    log_info "Đang lấy thông tin trạng thái..."
    
    # Ví dụ lấy thông tin server
    cpu_usage=$(top -bn1 | grep load | awk '{printf "%.2f", $(NF-2)}')
    mem_usage=$(free -m | awk 'NR==2{printf "%.2f", $3*100/$2 }')
    
    payload="{\"cpu\": \"$cpu_usage\", \"ram\": \"$mem_usage\"}"
    
    log_info "Đang đẩy dữ liệu lên: $API_URL/node/status"
    # curl -s -X POST "$API_URL/node/status" -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" -d "$payload"
    
    log_info "Giả lập Push thành công (Cần cấu hình API thực tế)."
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

pull_users() {
    log_info "Đang kết nối API để kéo danh sách User..."
    # Lệnh thực tế:
    # response=$(curl -s -X GET "$API_URL/node/users" -H "Authorization: Bearer $API_TOKEN")
    # echo "$response" > "$USER_DB"
    
    log_info "Giả lập Pull thành công (Cần cấu hình API thực tế)."
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

while true; do
    show_sync_menu
    read -r choice
    case $choice in
        1) push_node_status ;;
        2) pull_users ;;
        0) break ;;
        *) log_error "Lựa chọn không hợp lệ!" ; sleep 1 ;;
    esac
done