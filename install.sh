#!/bin/bash
# Script cài đặt Xray-core và khởi tạo môi trường

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CURRENT_DIR}/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

log_info "Bắt đầu cài đặt Xray-core..."

# Cài đặt các gói phụ thuộc
apt-get update -y
apt-get install -y curl wget unzip jq uuid-runtime

# Tải và cài đặt Xray-core thông qua script chính thức
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version latest

# Thiết lập thư mục cấu hình
mkdir -p "${XRAY_CONFIG_DIR}"
cp "${TEMPLATES_DIR}/base.json" "${XRAY_CONFIG_DIR}/config.json"

# Thiết lập systemd service
cp "${TEMPLATES_DIR}/xray.service" /etc/systemd/system/xray.service
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

log_info "Cài đặt Xray-core hoàn tất. Tiến trình đang chạy."