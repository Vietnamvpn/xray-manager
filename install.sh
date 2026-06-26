#!/bin/bash
# Script cài đặt Xray-core và khởi tạo môi trường
# bash <(curl -Ls https://raw.githubusercontent.com/Vietnamvpn/xray-manager/main/install.sh)

# =================================================================
# TRÌNH KÍCH HOẠT TẢI TỪ XA QUA URL (KHÔNG SỬA ĐOẠN NÀY)
# =================================================================
INSTALL_DIR="/etc/xray-manager"
REPO_URL="https://github.com/Vietnamvpn/xray-manager.git"

if [ ! -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.conf" ]; then
    clear
    echo "================================================================="
    echo "            CHÀO MỪNG ĐẾN VỚI XRAY-MANAGER                       "
    echo "================================================================="
    echo " Tác giả     : Vietnamvpn"
    echo -e "${CYAN}  → Tác giả:${NC} Vietnamvpn | ${CYAN}Website:${NC} https://linksub24h.com"
    echo " Xray-core   : Phiên bản Mới nhất (Latest Release)"
    echo "================================================================="
    echo ""
    
    read -p " Nhấn [Enter] để bắt đầu cài đặt hoặc nhập '0' để hủy bỏ: " choice
    if [ "$choice" == "0" ]; then
        echo "Đã hủy bỏ quá trình cài đặt."
        exit 0
    fi

    echo ""
    echo "=== Kiểm tra hệ điều hành và quyền quản trị ==="
    
    # Kiểm tra quyền root
    if [ "$EUID" -ne 0 ]; then
        echo "[LỖI] Vui lòng chạy lệnh bằng quyền root (sudo su)."
        exit 1
    fi

    # Kiểm tra và tải môi trường phụ thuộc
    if [ -f /etc/debian_version ]; then
        echo "[INFO] Hệ điều hành: Debian/Ubuntu. Đang tải môi trường..."
        apt-get update -y && apt-get install -y git curl wget unzip jq uuid-runtime openssl
        if [ $? -ne 0 ]; then echo "[LỖI] Không thể cài đặt các gói phụ thuộc."; exit 1; fi
    elif [ -f /etc/redhat-release ]; then
        echo "[INFO] Hệ điều hành: CentOS/RedHat. Đang tải môi trường..."
        yum install -y epel-release
        yum install -y git curl wget unzip jq util-linux openssl
        if [ $? -ne 0 ]; then echo "[LỖI] Không thể cài đặt các gói phụ thuộc."; exit 1; fi
    else
        echo "[LỖI] Hệ điều hành không được hỗ trợ. Vui lòng sử dụng Ubuntu, Debian hoặc CentOS."
        exit 1
    fi
    
    echo "=== Tải mã nguồn từ GitHub ==="
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR" && git reset --hard HEAD && git pull
    else
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
    
    # Tạo thư mục lưu data gốc nếu chưa có
    mkdir -p "$INSTALL_DIR/data"
    [ -f "$INSTALL_DIR/data/users.json" ] || echo "[]" > "$INSTALL_DIR/data/users.json"
    [ -f "$INSTALL_DIR/data/nodes.json" ] || echo "[]" > "$INSTALL_DIR/data/nodes.json"

    # Phân quyền thực thi
    chmod +x "$INSTALL_DIR/main.sh"
    chmod +x "$INSTALL_DIR/install.sh"
    if ls "$INSTALL_DIR/scripts/"*.sh 1> /dev/null 2>&1; then
        chmod +x "$INSTALL_DIR/scripts/"*.sh
    fi
    
    # Chuyển tiếp thực thi sang file install.sh vừa tải về để chạy code gốc bên dưới
    cd "$INSTALL_DIR"
    exec bash "$INSTALL_DIR/install.sh" "$@"
    exit 0
fi
# =================================================================

# GIỮ NGUYÊN TOÀN BỘ MÃ NGUỒN GỐC CỦA BẠN DƯỚI ĐÂY (ĐÃ BỔ SUNG CÁC TÍNH NĂNG THEO YÊU CẦU)
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CURRENT_DIR}/config.conf"

# Nếu utils.sh có tồn tại thì source, tránh báo lỗi nếu file chưa được tạo kịp
if [ -f "${SCRIPTS_DIR}/utils.sh" ]; then
    source "${SCRIPTS_DIR}/utils.sh"
fi

# Hàm log tạm trong trường hợp chưa có utils.sh
log_info() {
    echo "[INFO] $1"
}

# Xóa bỏ phím tắt lỗi cũ (Nếu có)
if [ -L /usr/local/bin/xray ] || [ -f /usr/local/bin/xray ]; then
    rm -f /usr/local/bin/xray
fi

log_info "Bắt đầu tải và cài đặt Xray-core..."

# Tải và cài đặt Xray-core thông qua script chính thức
if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
    log_info "[LỖI] Quá trình cài đặt lõi Xray-core thất bại. Vui lòng kiểm tra lại kết nối mạng hệ thống."
    exit 1
fi

# Thiết lập thư mục cấu hình Xray
mkdir -p "${XRAY_CONFIG_DIR}" || { log_info "[LỖI] Không thể tạo thư mục cấu hình ${XRAY_CONFIG_DIR}"; exit 1; }

# Thiết lập thư mục và quyền cho log Xray
mkdir -p /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log
chmod 777 /var/log/xray
chmod 666 /var/log/xray/*.log

# Tự động tạo Chứng chỉ (Certificate) để chạy Node
mkdir -p "${XRAY_CONFIG_DIR}/certs"
if [ ! -f "${XRAY_CONFIG_DIR}/certs/server.crt" ]; then
    log_info "Đang tạo chứng chỉ tự ký (Self-signed) cho Node..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${XRAY_CONFIG_DIR}/certs/server.key" \
        -out "${XRAY_CONFIG_DIR}/certs/server.crt" \
        -subj "/C=VN/ST=Hanoi/L=Hanoi/O=Vietnamvpn/OU=XrayManager/CN=xray.manager.local" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_info "Đã tạo chứng chỉ thành công tại: ${XRAY_CONFIG_DIR}/certs/"
    else
        log_info "[LỖI] Không thể tạo chứng chỉ tự ký. Các Node có thể không hoạt động với TLS."
    fi
fi

# Chép cấu hình mẫu
if [ -f "${TEMPLATES_DIR}/base.json" ]; then
    cp "${TEMPLATES_DIR}/base.json" "${XRAY_CONFIG_DIR}/config.json"
else
    log_info "[CẢNH BÁO] Không tìm thấy file ${TEMPLATES_DIR}/base.json. Vui lòng cấu hình sau."
fi

# Thiết lập systemd service
if [ -f "${TEMPLATES_DIR}/xray.service" ]; then
    cp "${TEMPLATES_DIR}/xray.service" /etc/systemd/system/xray.service
    systemctl daemon-reload
    systemctl enable xray
    if ! systemctl restart xray; then
        log_info "[LỖI] Không thể khởi động dịch vụ Xray. Vui lòng kiểm tra lại file config."
    fi
else
    log_info "[CẢNH BÁO] Không tìm thấy tệp mẫu xray.service tại đường dẫn templates/. Bỏ qua bước setup SystemD."
fi

# Tạo liên kết biểu tượng (Symlink) làm phím tắt mở Menu quản lý
ln -sf "${CURRENT_DIR}/main.sh" /usr/local/bin/linksub24h-xr
chmod +x /usr/local/bin/xray-manager

echo "================================================================="
echo " CÀI ĐẶT THÀNH CÔNG!"
echo " Hệ thống Xray-core và Xray-Manager đã được thiết lập."
echo " Chứng chỉ TLS Node đã sẵn sàng tại: ${XRAY_CONFIG_DIR}/certs/"
echo "================================================================="
echo " Vui lòng gõ lệnh dưới đây bất cứ lúc nào để vào Menu quản lý:"
echo " => xray-manager "
echo "================================================================="