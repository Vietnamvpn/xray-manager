#!/bin/bash
# Module quản lý chứng chỉ SSL (Tích hợp ACME + Cloudflare DNS)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

# Đường dẫn và tên file SSL cố định cho Xray
CERT_DIR="/usr/local/etc/xray/certs"
CERT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"

show_ssl_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}              SSL MANAGER              ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Cài đặt ACME.sh"
    echo -e "2. Cấp phát SSL (Standalone - Port 80)"
    echo -e "3. Cấp phát Wildcard SSL (Cloudflare DNS)"
    echo -e "4. Gia hạn tất cả chứng chỉ"
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

issue_wildcard_cf() {
    echo -e "${YELLOW}--- CẤP PHÁT SSL WILDCARD QUA CLOUDFLARE ---${NC}"
    read -p "Nhập Cloudflare Global API Key: " cf_key
    read -p "Nhập Email tài khoản Cloudflare: " cf_email
    read -p "Nhập Domain chính (ví dụ: example.com): " domain
    
    # Xuất biến cho acme.sh sử dụng Global API Key
    export CF_Key="$cf_key"
    export CF_Email="$cf_email"
    
    log_info "Đang xin chứng chỉ Wildcard cho *.$domain và $domain..."
    
    # Thực hiện xin chứng chỉ với DNS-01 challenge
    "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$domain" -d "*.$domain"
    
    if [ $? -eq 0 ]; then
        mkdir -p "$CERT_DIR"
        
        # Cài đặt file vào đường dẫn cố định
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
            --key-file       "$KEY_FILE" \
            --fullchain-file "$CERT_FILE" \
            --reloadcmd      "systemctl restart xray"
            
        log_info "Cấp phát SSL thành công. File đã ghi đè tại: $CERT_DIR"
    else
        log_error "Cấp phát SSL thất bại. Kiểm tra lại Global API Key và tên miền."
    fi
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

issue_standalone() {
    echo -n "Nhập tên miền (Domain) cần cấp SSL: "
    read domain
    
    if [ -z "$domain" ]; then
        log_error "Tên miền không được để trống!"
        sleep 1
        return
    fi
    
    # Dừng Xray để giải phóng cổng 80 (yêu cầu của mode standalone)
    systemctl stop xray
    
    log_info "Đang cấp phát SSL cho $domain..."
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone
    
    if [ $? -eq 0 ]; then
        mkdir -p "$CERT_DIR"
        
        # Cài đặt file vào cùng đường dẫn cố định với Wildcard
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
            --key-file       "$KEY_FILE"  \
            --fullchain-file "$CERT_FILE"
            
        log_info "Cấp phát SSL thành công. Đường dẫn: $CERT_DIR"
    else
        log_error "Cấp phát SSL thất bại. Vui lòng kiểm tra lại DNS trỏ về IP máy chủ."
    fi
    
    systemctl start xray
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

while true; do
    show_ssl_menu
    read -r choice
    case $choice in
        1) install_acme ;;
        2) issue_standalone ;;
        3) issue_wildcard_cf ;;
        4) "$HOME/.acme.sh/acme.sh" --cron --home "$HOME/.acme.sh"; systemctl restart xray ;;
        0) break ;;
        *) log_error "Lựa chọn không hợp lệ!" ; sleep 1 ;;
    esac
done