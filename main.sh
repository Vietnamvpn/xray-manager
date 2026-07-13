#!/bin/bash
# Main execution entry menu for xray-manager

# SỬA LỖI: Xác định chính xác thư mục gốc kể cả khi chạy qua liên kết biểu tượng (Symlink)
CURRENT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
cd "$CURRENT_DIR"

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

# =================================================================
# CÁC HÀM XỬ LÝ MỚI
# =================================================================

# 6. Xóa tất cả mã nguồn
# Hàm phụ kiểm tra kết quả lệnh vừa chạy
status_check() {
    if [ $1 -eq 0 ]; then
        echo -e "[${GREEN}THÀNH CÔNG${NC}] $2"
    else
        echo -e "[${RED}THẤT BẠI${NC}] $2 - Vui lòng kiểm tra lại quyền hạn hoặc tệp tin!"
    fi
}

delete_all_source() {
    echo -e "${RED}==============================================================================${NC}"
    echo -e "${RED}CẢNH BÁO NGUY HIỂM: HÀNH ĐỘNG NÀY SẼ XÓA SẠCH MỌI DỮ LIỆU!${NC}"
    echo -e "${YELLOW}Bao gồm: Xray Service, Xray Core, SSL, User Data, Swap và chính script này.${NC}"
    echo -e "${RED}==============================================================================${NC}"
    read -p "Bạn có chắc chắn muốn xóa tất cả không? (y/n): " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "\n${YELLOW}--- ĐANG THỰC HIỆN GỠ BỎ ---${NC}"
        
        # 1. Xóa Xray Service
        systemctl stop xray >/dev/null 2>&1
        systemctl disable xray >/dev/null 2>&1
        rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload >/dev/null 2>&1
        status_check $? "Gỡ bỏ Xray Service"
        
        # 2. Xóa Core & Config
        rm -rf /usr/local/bin/xray
        rm -rf /usr/local/etc/xray
        status_check $? "Xóa Xray Core và cấu hình"
        
        # 3. Xóa Dữ liệu Manager & SSL
        rm -rf /etc/xray-manager
        rm -rf "$HOME/.acme.sh"
        status_check $? "Xóa dữ liệu quản lý và SSL"
        
        # 4. Xóa Swap
        if [ -f "/swapfile" ]; then
            swapoff /swapfile >/dev/null 2>&1
            rm -f /swapfile
            sed -i '/\/swapfile/d' /etc/fstab >/dev/null 2>&1
            status_check $? "Gỡ bỏ Swap file"
        else
            echo -e "[${BLUE}THÔNG TIN${NC}] Không tìm thấy Swap file để xóa."
        fi

        echo -e "${YELLOW}Đang tự hủy thư mục mã nguồn...${NC}"
        # 5. Xóa thư mục script cuối cùng
        # Lưu ý: Lệnh này sẽ kết thúc script ngay lập tức
        rm -rf "$CURRENT_DIR"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}===========================================================${NC}"
            echo -e "${GREEN}ĐÃ XÓA SẠCH MỌI DỮ LIỆU. HỆ THỐNG ĐÃ TRỞ VỀ TRẠNG THÁI GỐC.${NC}"
            echo -e "${YELLOW}Cài lại bất cứ khi nào bạn muốn bằng link dưới đây:${NC}"
            echo -e "${CYAN}bash <(curl -Ls https://raw.githubusercontent.com/Vietnamvpn/xray-manager/main/install.sh)${NC}"
            echo -e "${GREEN}===========================================================${NC}"
            exit 0
        else
            echo -e "${RED}Lỗi khi xóa thư mục mã nguồn!${NC}"
            exit 1
        fi
        
    else
        echo -e "${BLUE}Đã hủy lệnh xóa. Hệ thống an toàn.${NC}"
    fi
}

# 7. Điều khiển Xray
manage_xray() {
    echo -e "1. Khởi chạy Xray"
    echo -e "2. Tắt Xray"
    echo -e "3. Khởi động lại Xray"
    echo -e "4. Xóa Xray Core"
    read -p "Chọn: " sub_choice
    
    echo -e "\n${YELLOW}Đang thực hiện lệnh...${NC}"
    
    case $sub_choice in
        1)
            systemctl start xray
            status_check $? "Khởi chạy Xray"
            ;;
        2)
            systemctl stop xray
            status_check $? "Tắt Xray"
            ;;
        3)
            systemctl restart xray
            status_check $? "Khởi động lại Xray"
            ;;
        4)
            systemctl stop xray >/dev/null 2>&1
            rm -f /usr/local/bin/xray
            status_check $? "Xóa Xray core"
            ;;
        *)
            echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
            ;;
    esac
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# 8. Bật/Tắt BBR
toggle_bbr() {
    echo -e "1. Bật BBR"
    echo -e "2. Tắt BBR"
    read -p "Chọn: " sub_choice
    
    # Lấy thuật toán kiểm soát nghẽn hiện tại của hệ thống
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    
    case $sub_choice in
        1)
            if [ "$current_cc" == "bbr" ]; then
                echo -e "\n${YELLOW}[THÔNG BÁO] BBR đã được bật từ trước đó rồi, không cần bật lại!${NC}"
            else
                echo -e "\n${YELLOW}Đang áp dụng cấu hình kernel...${NC}"
                # Dọn dẹp cấu hình cũ trước khi thêm để tránh trùng lặp
                sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
                sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
                
                # Ghi cấu hình mới
                echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
                echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
                
                # Áp dụng
                sysctl -p >/dev/null 2>&1
                local exit_code=$?
                if [ $exit_code -ne 0 ]; then
                    echo -e "${RED}[LỖI] Hệ thống không thể áp dụng cấu hình sysctl mới. Vui lòng kiểm tra quyền root!${NC}"
                fi
                status_check $exit_code "Bật BBR"
            fi
            ;;
        2)
            if [ "$current_cc" != "bbr" ]; then
                echo -e "\n${YELLOW}[THÔNG BÁO] BBR hiện đang ở trạng thái tắt (Hệ thống đang dùng: $current_cc).${NC}"
            else
                echo -e "\n${YELLOW}Đang áp dụng cấu hình kernel...${NC}"
                # Dọn dẹp cấu hình
                sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
                sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
                
                # Áp dụng
                sysctl -p >/dev/null 2>&1
                local exit_code=$?
                if [ $exit_code -ne 0 ]; then
                    echo -e "${RED}[LỖI] Không thể khôi phục cấu hình sysctl về mặc định.${NC}"
                fi
                status_check $exit_code "Tắt BBR"
            fi
            ;;
        *)
            echo -e "\n${RED}Lựa chọn không hợp lệ.${NC}"
            ;;
    esac
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# 9. Tạo bộ nhớ ảo Swap
setup_swap() {
    # Kiểm tra xem swap đã tồn tại chưa
    if swapon --show | grep -q "/swapfile"; then
        echo -e "${RED}[CẢNH BÁO] Swap đã tồn tại và đang hoạt động!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
        return
    fi

    read -p "Nhập dung lượng Swap (ví dụ: 1G, 2G, 512M): " size
    echo -e "\n${YELLOW}Đang thiết lập Swap dung lượng $size...${NC}"

    # 1. Tạo file swap
    fallocate -l "$size" /swapfile >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}[THẤT BẠI] Không thể tạo file swap. Vui lòng kiểm tra dung lượng ổ cứng còn trống.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
        return
    fi
    echo -e "[${GREEN}THÀNH CÔNG${NC}] Tạo file swap"

    # 2. Phân quyền và định dạng
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    status_check $? "Định dạng Swap (mkswap)"

    # 3. Kích hoạt
    swapon /swapfile >/dev/null 2>&1
    status_check $? "Kích hoạt Swap"

    # 4. Lưu vào fstab để tự động kích hoạt khi khởi động lại
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        status_check $? "Ghi cấu hình vào fstab (tự động bật khi khởi động)"
    else
        echo -e "[${BLUE}THÔNG TIN${NC}] Cấu hình Swap đã tồn tại trong fstab."
    fi

    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# 10. Trạng thái VPS
check_vps() {
    clear
    echo -e "${BLUE}========TRẠNG THÁI VPS HIỆN TẠI:========${NC}"
    echo -e "----------------------------------------"
    uname -a
    echo -e ""
    free -h
    df -h
    uptime
    echo -e ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# 11. Xem log Xray trực tiếp
view_xray_logs() {
    echo -e "${YELLOW}Chọn loại log Xray bạn muốn xem:${NC}"
    echo "1) Log service của hệ thống (journalctl)"
    echo "2) Log truy cập (access.log)"
    echo "3) Log lỗi (error.log)"
    echo "0) Thoát"
    read -p "Nhập lựa chọn của bạn (0-3): " log_choice

    case $log_choice in
        1)
            echo -e "${YELLOW}Đang hiển thị log service Xray... (Nhấn Ctrl+C để thoát)${NC}"
            journalctl -u xray -f
            ;;
        2)
            echo -e "${YELLOW}Đang hiển thị log truy cập Xray... (Nhấn Ctrl+C để thoát)${NC}"
            tail -f /var/log/xray/access.log
            ;;
        3)
            echo -e "${YELLOW}Đang hiển thị log lỗi Xray... (Nhấn Ctrl+C để thoát)${NC}"
            tail -f /var/log/xray/error.log
            ;;
        0)
            echo "Đã thoát xem log."
            ;;
        *)
            echo "Lựa chọn không hợp lệ."
            ;;
    esac
}

show_menu() {
    clear
    # Kiểm tra trạng thái Xray
    local xray_status=$(systemctl is-active xray)
    local status_color=$RED
    if [ "$xray_status" == "active" ]; then status_color=$GREEN; fi
    # Lấy phiên bản Xray-core
    local xray_ver="Chưa cài đặt"
    if [ -f "/usr/local/bin/xray" ]; then
        # Lấy dòng đầu tiên của lệnh 'xray version' và cắt lấy số phiên bản
        xray_ver=$(/usr/local/bin/xray version | head -n 1 | awk '{print $2}')
    fi

    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${BLUE}||${NC}${YELLOW}                 MENU QUẢN LÝ LINKSUB24H-XR 2026                  ${NC}${BLUE}||${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${CYAN}Tác giả:${NC} Vietnamvpn | ${CYAN}Website:${NC} https://linksub24h.com"
    echo -e " Phiên bản Xray-core: ${YELLOW}${xray_ver}${NC} | Trạng thái: ${status_color}${xray_status^^}${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "1. ${CYAN}Quản Lý Người Dùng${NC}   |   7. ${CYAN}Điều Khiển Xray${NC}"
    echo -e "2. ${CYAN}Quản Lý Node Sever${NC}   |   8. ${CYAN}Bật/Tắt BBR${NC}"
    echo -e "3. ${CYAN}Quản Lý SSL${NC}          |   9. ${CYAN}Tạo Bộ Nhớ Ảo Swap${NC}"
    echo -e "4. ${CYAN}Đồng Bộ API${NC}          |   10. ${CYAN}Xem Trạng Thái VPS${NC}"
    echo -e "5. ${CYAN}Cập Nhật Mã Nguồn${NC}    |   11. ${CYAN}Xem Log Xray Trực Tiếp${NC}"
    echo -e "6. ${RED}Xóa Tất Cả Mã Nguồn${NC}  |   12. ${CYAN}Quản Lý Định Tuyến${NC}"
    echo -e "0. Thoát                |"
    echo -e "${BLUE}======================================================================${NC}"
    echo -e ""
    echo -n "Nhập lựa chọn của bạn: "
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
        6) delete_all_source ;;
        7) manage_xray ;;
        8) toggle_bbr ;;
        9) setup_swap ;;
        10) check_vps ;;
        11) view_xray_logs ;;
        12)
            if [ -f "${SCRIPTS_DIR}/relay_manager.sh" ]; then
                bash "${SCRIPTS_DIR}/relay_manager.sh"
            else
                log_warn "Module Relay Manager chưa được cài đặt."
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