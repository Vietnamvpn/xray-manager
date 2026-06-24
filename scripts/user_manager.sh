#!/bin/bash
# Module quản lý Người dùng (Users)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

show_user_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}             USER MANAGER              ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Xem danh sách Users"
    echo -e "2. Thêm User mới"
    echo -e "3. Xóa User"
    echo -e "0. Quay lại Menu chính"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn: "
}

list_users() {
    echo -e "${GREEN}--- Danh sách Users ---${NC}"
    cat "$USER_DB" | jq -r '.[] | "Email: \(.email) | UUID: \(.uuid) | Quota: \(.quota_gb)GB"'
    echo ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

add_user() {
    echo -n "Nhập Email/Tên User: "
    read email
    uuid=$(uuidgen)
    
    # Cập nhật vào users.json
    jq --arg email "$email" --arg uuid "$uuid" --arg quota "0" \
       '. += [{"email": $email, "uuid": $uuid, "quota_gb": $quota, "status": "active"}]' \
       "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
       
    log_info "Đã thêm user: $email với UUID: $uuid"
    
    log_info "Ghi chú: Sẽ cần kết nối API của Xray để thêm user trực tiếp vào Inbound."
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

delete_user() {
    echo -n "Nhập Email/Tên User cần xóa: "
    read email
    
    jq --arg email "$email" 'del(.[] | select(.email == $email))' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
    
    log_info "Đã xóa user: $email khỏi database."
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

while true; do
    show_user_menu
    read -r choice
    case $choice in
        1) list_users ;;
        2) add_user ;;
        3) delete_user ;;
        0) break ;;
        *) log_error "Lựa chọn không hợp lệ!" ; sleep 1 ;;
    esac
done