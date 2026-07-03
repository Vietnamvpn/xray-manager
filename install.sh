#!/bin/bash
# Script cài đặt Xray-core và khởi tạo môi trường
# bash <(curl -Ls https://raw.githubusercontent.com/Vietnamvpn/xray-manager/main/install.sh)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' 

# =================================================================
# TRÌNH KÍCH HOẠT TẢI TỪ XA QUA URL (KHÔNG SỬA ĐOẠN NÀY)
# =================================================================
INSTALL_DIR="/etc/xray-manager"
REPO_URL="https://github.com/Vietnamvpn/xray-manager.git"

if [ ! -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.conf" ]; then
    clear
    echo -e "${BLUE}=================================================================${NC}"
    echo -e "${BLUE}||            CHÀO MỪNG ĐẾN VỚI LINKSUB24H-XR 2026             ||${NC}"
    echo -e ""
    echo -e "${CYAN}Tác giả:${NC} Vietnamvpn | ${CYAN}Website:${NC} https://linksub24h.com"
    echo -e "Fanpage: ${CYAN}https://www.facebook.com/vpn2s${NC}"
    echo -e "Mã nguồn đang trong quá trình phát triển và thử nghiệm."
    echo -e "Vui lòng kiểm tra kỹ trước khi cài đặt trên hệ thống chính thức."
    echo -e "${BLUE}=================================================================${NC}"
    echo ""
    
    read -p " Nhấn [Enter] để bắt đầu cài đặt hoặc nhập '0' để hủy bỏ: " choice
    if [ "$choice" == "0" ]; then
        echo -e "Đã hủy bỏ quá trình cài đặt."
        exit 0
    fi

    echo -e ""
    echo -e "${BLUE}=== Đang kiểm tra hệ điều hành và quyền quản trị ===${NC}"
    
    # Kiểm tra quyền root
    if [ "$EUID" -ne 0 ]; then
        echo -e "[LỖI] Vui lòng chạy lệnh bằng quyền root (sudo su)."
        exit 1
    fi

    # Kiểm tra và tải môi trường phụ thuộc
    if [ -f /etc/debian_version ]; then
        echo -e "[INFO] Hệ điều hành: Debian/Ubuntu. Đang tải môi trường..."
        apt-get update -y && apt-get install -y git curl wget unzip jq uuid-runtime openssl
        if [ $? -ne 0 ]; then echo -e "[LỖI] Không thể cài đặt các gói phụ thuộc."; exit 1; fi
    elif [ -f /etc/redhat-release ]; then
        echo -e "[INFO] Hệ điều hành: CentOS/RedHat. Đang tải môi trường..."
        yum install -y epel-release
        yum install -y git curl wget unzip jq util-linux openssl
        if [ $? -ne 0 ]; then echo -e "[LỖI] Không thể cài đặt các gói phụ thuộc."; exit 1; fi
    else
        echo -e "[LỖI] Hệ điều hành không được hỗ trợ. Vui lòng sử dụng Ubuntu, Debian hoặc CentOS."
        exit 1
    fi
    
    echo -e "${BLUE}=== Đang tải mã nguồn từ GitHub ===${NC}"
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

# Nhận diện kiến trúc hệ thống
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="64" ;;
    aarch64) ARCH="arm64-v8a" ;;
    *) log_info "[LỖI] Kiến trúc $ARCH không được hỗ trợ."; exit 1 ;;
esac

# Lấy tag phiên bản mới nhất từ kho lưu trữ Vietnamvpn/Xray-core
LATEST_VERSION=$(curl -s https://api.github.com/repos/Vietnamvpn/Xray-core/releases/latest | jq -r .tag_name)
if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" == "null" ]; then
    log_info "[LỖI] Không thể lấy thông tin phiên bản Xray-core mới nhất từ GitHub."
    exit 1
fi

log_info "Tìm thấy phiên bản mới nhất: ${LATEST_VERSION}. Đang tiến hành tải về..."
if ! wget -O /tmp/xray.zip "https://github.com/Vietnamvpn/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${ARCH}.zip"; then
    log_info "[LỖI] Quá trình tải lõi Xray-core thất bại. Vui lòng kiểm tra lại kết nối mạng hệ thống."
    exit 1
fi

# Giải nén và cấu hình tệp thực thi
unzip -o /tmp/xray.zip -d /usr/local/bin/ xray
chmod +x /usr/local/bin/xray
rm -f /tmp/xray.zip

# BỔ SUNG VÀO ĐÂY:
log_info "Đang tải dữ liệu định tuyến (geosite/geoip)..."
wget -O /usr/local/bin/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
wget -O /usr/local/bin/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat

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

# =================================================================
# TỰ ĐỘNG TẠO FILE api.conf VÀ SERVICE xray-sync (THÊM MỚI VÀO ĐÂY)
# =================================================================
log_info "Đang thiết lập cấu hình API và dịch vụ đồng bộ..."

# 1. Tạo file api.conf mặc định (nếu chưa có)
mkdir -p "${CURRENT_DIR}/data"
if [ ! -f "${CURRENT_DIR}/data/api.conf" ]; then
    cat <<EOF > "${CURRENT_DIR}/data/api.conf"
API_DOMAIN=""
API_PORT=""
API_KEY=""
EOF
    chmod 600 "${CURRENT_DIR}/data/api.conf"
    log_info "Đã tạo file cấu hình API tại: ${CURRENT_DIR}/data/api.conf"
fi

# 2. Tạo file systemd service xray-sync.service
cat <<EOF > /etc/systemd/system/xray-sync.service
[Unit]
Description=Xray API Sync Service
After=network.target xray.service

[Service]
Type=simple
ExecStart=/bin/bash ${CURRENT_DIR}/scripts/api_sync.sh sync
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

# 3. Kích hoạt dịch vụ chạy ngầm
systemctl daemon-reload
systemctl enable xray-sync
systemctl restart xray-sync
log_info "Đã thiết lập và khởi chạy xray-sync.service thành công."
# =================================================================

# Tạo liên kết biểu tượng (Symlink) làm phím tắt mở Menu quản lý
ln -sf "${CURRENT_DIR}/main.sh" /usr/local/bin/vvc-xr
chmod +x /usr/local/bin/xray-manager

echo -e "${BLUE}==========================================================${NC}"
echo -e "[${GREEN} CÀI ĐẶT THÀNH CÔNG!${NC}]"
echo -e " Hệ thống Xray-core và Xray-Manager đã được thiết lập."
echo -e " Chứng chỉ TLS Node đã sẵn sàng tại: ${XRAY_CONFIG_DIR}/certs/"
echo -e "${BLUE}===========================================================${NC}"
echo -e "${YELLOW} Vui lòng gõ lệnh dưới đây bất cứ lúc nào để vào Menu quản lý:${NC}"
echo " => vvc-xr"
echo -e "${BLUE}============================================================${NC}"