#!/bin/bash
# Module quản lý chứng chỉ SSL (Tích hợp ACME)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

show_ssl_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}              SSL MANAGER              ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Cài đặt ACME.sh"
    echo -e "2. Cấp phát chứng chỉ SSL (Standalone)"
    echo -e "3. Gia hạn chứng chỉ SSL"
    echo -e "0. Quay lại Menu chính"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn: "
}

install_acme() {
    if [ -d "$HOME/.acme.sh" ]; then
        log_info "ACME.sh đã được cài đặt."
    else
        log_info "Bắt đầu cài đặt ACME.sh..."
        curl https://get.acme.sh | sh
        log_info "Cài đặt ACME.sh hoàn tất."
    fi
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

issue_cert() {
    echo -n "Nhập tên miền (Domain) cần cấp SSL: "
    read domain
    
    if [ -z "$domain" ]; then
        log_error "Tên miền không được để trống!"
        sleep 1
        return
    fi
    
    # Dừng Xray nếu đang dùng port 80 (để acme.sh standalone chạy)
    systemctl stop xray
    
    log_info "Đang cấp phát SSL cho $domain..."
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone
    
    if [ $? -eq 0 ]; then
        mkdir -p "${XRAY_CONFIG_DIR}/ssl"
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
            --key-file       "${XRAY_CONFIG_DIR}/ssl/${domain}.key"  \
            --fullchain-file "${XRAY_CONFIG_DIR}/ssl/${domain}.crt"
            
        log_info "Cấp phát SSL thành công. Đường dẫn: ${XRAY_CONFIG_DIR}/ssl/"
    else
        log_error "Cấp phát SSL thất bại. Vui lòng kiểm tra lại DNS trỏ về IP máy chủ."
    fi
    
    systemctl start xray
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

renew_cert() {
    log_info "Đang tiến hành gia hạn tất cả chứng chỉ..."
    "$HOME/.acme.sh/acme.sh" --cron --home "$HOME/.acme.sh"
    systemctl restart xray
    log_info "Hoàn tất gia hạn."
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

while true; do
    show_ssl_menu
    read -r choice
    case $choice in
        1) install_acme ;;
        2) issue_cert ;;
        3) renew_cert ;;
        0) break ;;
        *) log_error "Lựa chọn không hợp lệ!" ; sleep 1 ;;
    esac
done