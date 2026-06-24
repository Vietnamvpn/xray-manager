#!/bin/bash
# Module cập nhật mã nguồn (Git Pull)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

log_info "Bắt đầu kiểm tra cập nhật..."

cd "$XRAY_ROOT" || exit

# Kiểm tra xem có phải là git repository không
if [ -d ".git" ]; then
    log_info "Đang lấy dữ liệu từ Git repository..."
    git fetch --all
    git reset --hard origin/main
    git pull origin main
    
    # Cấp quyền thực thi lại cho các file script
    chmod +x install.sh main.sh
    chmod +x scripts/*.sh
    
    log_info "Cập nhật mã nguồn thành công!"
else
    log_error "Thư mục $XRAY_ROOT không phải là một Git repository hợp lệ."
    log_warn "Nếu bạn cài đặt từ ZIP, vui lòng tải bản ZIP mới và ghi đè."
fi

read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."