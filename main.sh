#!/bin/bash
# Main execution entry menu for xray-manager
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CURRENT_DIR"

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${CURRENT_DIR}/config.conf" ]; then
    source "${CURRENT_DIR}/config.conf"
else
    echo "Không tìm thấy file config.conf!"
    exit 1
fi

if [ -f "${CURRENT_DIR}/scripts/utils.sh" ]; then
    source "${CURRENT_DIR}/scripts/utils.sh"
else
    echo "Không tìm thấy file scripts/utils.sh!"
    exit 1
fi

check_root
init_dirs

show_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}      XRAY MANAGER MANAGEMENT CLI      ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Quản lý người dùng (User Manager)"
    echo -e "2. Quản lý Node (Node Manager)"
    echo -e "3. Quản lý SSL (SSL Manager)"
    echo -e "4. Đồng bộ API (API Sync)"
    echo -e "5. Cập nhật mã nguồn (Update)"
    echo -e "0. Thoát"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn của bạn [0-5]: "
}

while true; do
    show_menu
    read -r choice
    case $choice in
        1)
            if [ -f "${SCRIPTS_DIR}/user_manager.sh" ]; then
                bash "${SCRIPTS_DIR}/user_manager.sh"
            else
                log_warn "Module User Manager chưa được cài đặt."
                read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
            fi
            ;;
        2)
            if [ -f "${SCRIPTS_DIR}/node_manager.sh" ]; then
                bash "${SCRIPTS_DIR}/node_manager.sh"
            else
                log_warn "Module Node Manager chưa được cài đặt."
                read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
            fi
            ;;
        3)
            if [ -f "${SCRIPTS_DIR}/ssl_manager.sh" ]; then
                bash "${SCRIPTS_DIR}/ssl_manager.sh"
            else
                log_warn "Module SSL Manager chưa được cài đặt."
                read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
            fi
            ;;
        4)
            if [ -f "${SCRIPTS_DIR}/api_sync.sh" ]; then
                bash "${SCRIPTS_DIR}/api_sync.sh"
            else
                log_warn "Module API Sync chưa được cài đặt."
                read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
            fi
            ;;
        5)
            if [ -f "${SCRIPTS_DIR}/update.sh" ]; then
                bash "${SCRIPTS_DIR}/update.sh"
            else
                log_warn "Module Update chưa được cài đặt."
                read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
            fi
            ;;
        0)
            log_info "Thoát chương trình."
            exit 0
            ;;
        *)
            log_error "Lựa chọn không hợp lệ!"
            sleep 1
            ;;
    esac
done