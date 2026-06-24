#!/bin/bash
# Script cài đặt Xray-core và khởi tạo môi trường
# bash <(curl -Ls https://raw.githubusercontent.com/Vietnamvpn/xray-manager/main/install.sh)

# =================================================================
# TRÌNH KÍCH HOẠT TẢI TỪ XA QUA URL (KHÔNG SỬA ĐOẠN NÀY)
# =================================================================
INSTALL_DIR="/etc/xray-manager"
REPO_URL="https://github.com/Vietnamvpn/xray-manager.git"

if [ ! -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.conf" ]; then
    echo "=== Khởi tạo môi trường và tải mã nguồn từ GitHub ==="
    
    # Kiểm tra quyền root trước khi cài gói phụ thuộc hệ thống
    if [ "$EUID" -ne 0 ]; then
        echo "Lỗi: Vui lòng chạy lệnh bằng quyền root (sudo su)."
        exit 1
    fi

    # Cài đặt git và curl để chuẩn bị kéo mã nguồn
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install git curl -y
    elif [ -f /etc/redhat-release ]; then
        yum install git curl -y
    fi
    
    # Tiến hành clone hoặc cập nhật repo
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR" && git reset --hard HEAD && git pull
    else
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
    
    # Tạo thư mục lưu data gốc nếu chưa có
    mkdir -p "$INSTALL_DIR/data"
    [ -f "$INSTALL_DIR/data/users.json" ] || echo "[]" > "$INSTALL_DIR/data/users.json"
    [ -f "$INSTALL_DIR/data/nodes.json" ] || echo "[]" > "$INSTALL_DIR/data/nodes.json"
    [ -f "$INSTALL_DIR/data/system.log" ] || touch "$INSTALL_DIR/data/system.log"

    # Phân quyền thực thi
    chmod +x "$INSTALL_DIR/main.sh"
    chmod +x "$INSTALL_DIR/install.sh"
    chmod +x "$INSTALL_DIR/scripts/"*.sh
    
    # Chuyển tiếp thực thi sang file install.sh vừa tải về để chạy code gốc bên dưới
    cd "$INSTALL_DIR"
    exec bash "$INSTALL_DIR/install.sh" "$@"
    exit 0
fi
# =================================================================

# GIỮ NGUYÊN TOÀN BỘ MÃ NGUỒN GỐC CỦA BẠN DƯỚI ĐÂY (ĐÃ SỬA LỖI NHẬN NHẦM FILE)
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CURRENT_DIR}/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

log_info "Bắt đầu cài đặt Xray-core..."

# Cài đặt các gói phụ thuộc
apt-get update -y
apt-get install -y curl wget unzip jq uuid-runtime

# XÓA BỎ FILE PHÍM TẮT LỖI CŨ (Để tránh script XTLS nhận diện nhầm file main.sh thành lõi xray)
if [ -L /usr/local/bin/xray ] || [ -f /usr/local/bin/xray ]; then
    rm -f /usr/local/bin/xray
fi

# Tải và cài đặt Xray-core thông qua script chính thức (Kiểm tra lỗi tải/cài đặt)
if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
    log_info "[LỖI] Quá trình cài đặt lõi Xray-core thất bại. Vui lòng kiểm tra lại kết nối mạng hệ thống."
    exit 1
fi

# Thiết lập thư mục cấu hình
mkdir -p "${XRAY_CONFIG_DIR}" || { log_info "[LỖI] Không thể tạo thư mục cấu hình ${XRAY_CONFIG_DIR}"; exit 1; }
cp "${TEMPLATES_DIR}/base.json" "${XRAY_CONFIG_DIR}/config.json" || { log_info "[LỖI] Không tìm thấy hoặc không thể sao chép file base.json"; exit 1; }

# Thiết lập systemd service
if [ -f "${TEMPLATES_DIR}/xray.service" ]; then
    cp "${TEMPLATES_DIR}/xray.service" /etc/systemd/system/xray.service
    systemctl daemon-reload
    systemctl enable xray
    if ! systemctl restart xray; then
        log_info "[LỖI] Không thể khởi động dịch vụ Xray hệ thống."
        exit 1
    fi
else
    log_info "[LỖI] Không tìm thấy tệp mẫu xray.service tại đường dẫn templates/."
    exit 1
fi

# Tạo liên kết biểu tượng (Symlink) làm phím tắt mở Menu quản lý (Chỉ tạo khi mọi bước trên đã xong)
ln -sf "${CURRENT_DIR}/main.sh" /usr/local/bin/xray-manager

log_info "Cài đặt Xray-core hoàn tất. Tiến trình đang chạy."