#!/bin/bash
# Module quản lý Node (Inbounds)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

show_node_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}             NODE MANAGER              ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Xem danh sách Node đang chạy"
    echo -e "2. Thêm Node mới (Inbound)"
    echo -e "3. Xóa Node"
    echo -e "0. Quay lại Menu chính"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn: "
}

list_nodes() {
    echo -e "${GREEN}--- Danh sách Nodes ---${NC}"
    cat "$NODE_DB" | jq -r '.[] | "Tag: \(.tag) | Port: \(.port) | Protocol: \(.protocol)"'
    echo ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

add_node() {
    echo -e "${YELLOW}Chức năng thêm Node cần kết hợp với các file mẫu cấu hình (vless/ws.json v.v.) trong thư mục templates.${NC}"
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

delete_node() {
    echo -e "${YELLOW}Chức năng xóa Node đang đợi kết nối với DB.${NC}"
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
        *) log_error "Lựa chọn không hợp lệ!" ; sleep 1 ;;
    esac
done