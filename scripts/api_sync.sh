#!/bin/bash
# Module đồng bộ API: Đẩy dữ liệu & Nhận lệnh User (api_sync.sh)

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${CURRENT_DIR}/config.conf"

if [ -f "${CURRENT_DIR}/data/api.conf" ]; then
    source "${CURRENT_DIR}/data/api.conf"
fi

if [ -f "${CURRENT_DIR}/scripts/utils.sh" ]; then
    source "${CURRENT_DIR}/scripts/utils.sh"
fi

XRAY_API_PORT="10085"
LOG_FILE="/var/log/xray/access.log"
NODE_DB="${CURRENT_DIR}/data/nodes.json"
USER_DB="${CURRENT_DIR}/data/users.json"
TEST_LOG="${CURRENT_DIR}/data/sync_test.log"

setup_api() {
    clear
    echo -e "\n--- CẤU HÌNH KẾT NỐI API ---"
    read -p "Nhập Domain (vd: https://panel.com): " input_domain
    read -p "Nhập Port (vd: 8080): " input_port
    read -p "Nhập Secret Key: " input_key

    mkdir -p "${CURRENT_DIR}/data"
    cat <<EOF > "${CURRENT_DIR}/data/api.conf"
API_DOMAIN="$input_domain"
API_PORT="$input_port"
API_KEY="$input_key"
EOF
    echo -e "Đã lưu cấu hình vào data/api.conf thành công!"
    sleep 2
}

sync_process() {
    # 1. Thu thập trạng thái hệ thống (Tín hiệu sống, CPU, RAM)
    local cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    local mem=$(free -m | awk 'NR==2{printf "%.0f", $3*100/$2}')
    
    # 2. Lấy dữ liệu lưu lượng User (Uplink/Downlink) từ Core Xray
    local stats=$(xray api statsquery --server=127.0.0.1:${XRAY_API_PORT} 2>/dev/null || echo "{}")

    # 3. Lọc IP User đang online thời gian thực từ access.log
    local online_ips="[]"
    if [ -f "$LOG_FILE" ]; then
        online_ips=$(tail -n 500 "$LOG_FILE" | grep "accepted" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -v '127.0.0.1' | sort -u | jq -R . | jq -s . || echo "[]")
    fi

    local payload=$(jq -n \
        --arg cpu "$cpu" \
        --arg mem "$mem" \
        --argjson stats "$stats" \
        --argjson ips "$online_ips" \
        '{status: "online", cpu: $cpu, ram: $mem, traffic: $stats, active_ips: $ips}')

    # Ghi xuất dữ liệu ra file log để kiểm tra (Test Output)
    echo "$payload" | jq . > "$TEST_LOG"

    # Nếu chưa cấu hình API Domain/Key thì dừng ở đây, không gửi request HTTP
    if [ -z "$API_DOMAIN" ] || [ -z "$API_KEY" ]; then
        return 0
    fi

    # 4. Push dữ liệu (Đẩy log và trạng thái lên web trung tâm)
    curl -s -X POST "${API_DOMAIN}:${API_PORT}/api/node/sync-push" \
         -H "Authorization: Bearer ${API_KEY}" \
         -H "Content-Type: application/json" \
         -d "$payload" > /dev/null

    # 5. Pull dữ liệu (Nhận lệnh tạo/xóa/sửa user từ web)
    local response=$(curl -s -X GET "${API_DOMAIN}:${API_PORT}/api/node/users-pull" \
         -H "Authorization: Bearer ${API_KEY}")

    if echo "$response" | jq -e . >/dev/null 2>&1; then
        local current_md5=$(md5sum "$USER_DB" 2>/dev/null | awk '{print $1}')
        echo "$response" > "${USER_DB}.tmp"
        local new_md5=$(md5sum "${USER_DB}.tmp" | awk '{print $1}')

        # Chỉ áp dụng và khởi động lại Xray nếu danh sách user từ web có sự thay đổi
        if [ "$current_md5" != "$new_md5" ]; then
            mv "${USER_DB}.tmp" "$USER_DB"
            
            # Lọc các user có trạng thái hoạt động
            local active_users=$(jq '[.[] | select(.status == "active" or .status == "on" or .status == "true" or .status == "1")]' "$USER_DB")
            
            # Đồng bộ cấu trúc dữ liệu user vào nodes.json theo chuẩn giao thức
            jq --argjson users "$active_users" '
                map(
                    . as $node |
                    if .settings.clients != null then 
                        .settings.clients = [
                            $users[] | 
                            if $node.protocol == "vless" or $node.protocol == "vmess" then {"id": .uuid, "email": .email}
                            elif $node.protocol == "hysteria" or $node.protocol == "hy2" or $node.protocol == "hysteria2" then {"auth": .uuid, "email": .email}
                            else {"password": .uuid, "email": .email} end
                        ]
                    elif .settings.users != null then 
                        .settings.users = [ $users[] | {"password": .uuid, "email": .email} ]
                    elif .users != null then
                        .users = [ $users[] | {"password": .uuid, "email": .email} ]
                    else . end
                )
            ' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"

            if command -v apply_config >/dev/null 2>&1; then
                apply_config
            fi
        else
            rm -f "${USER_DB}.tmp"
        fi
    fi
}

show_menu() {
    clear
    echo "======================================="
    echo "           API SYNC MANAGER            "
    echo "======================================="
    echo "1. Cấu hình API (Domain, Port, Key)"
    echo "2. Đồng bộ dữ liệu thủ công ngay lập tức"
    echo "0. Quay lại Menu chính"
    echo "======================================="
    echo -n "Nhập lựa chọn: "
    read -r choice
    case $choice in
        1) setup_api ;;
        2) 
           echo "Đang lấy dữ liệu..."
           sync_process 
           echo "Đã ghi dữ liệu test vào: $TEST_LOG"
           if [ -n "$API_DOMAIN" ] && [ -n "$API_KEY" ]; then
               echo "Đã hoàn tất đồng bộ với Web!"
           else
               echo "(Chưa cấu hình API nên chỉ xuất file log test, không gửi lên Web)"
           fi
           sleep 3
           ;;
        0) exit 0 ;;
        *) echo "Lựa chọn không hợp lệ!" ; sleep 1 ;;
    esac
}

case "$1" in
    sync) 
        sync_process 
        ;;
    menu|*)
        while true; do
            show_menu
        done
        ;;
esac