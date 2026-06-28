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

push_admin_nodes() {
    if [ -n "$API_DOMAIN" ] && [ -n "$API_KEY" ]; then
        local admin_nodes=$(jq -c 'map(select(.name == "admin"))' "$NODE_DB")
        curl -s -X POST "${API_DOMAIN}:${API_PORT}/api/node/sync-admin" \
             -H "Authorization: Bearer ${API_KEY}" \
             -H "Content-Type: application/json" \
             -d "$admin_nodes" > /dev/null
    fi
}

sync_process() {
    # 1. Thu thập dữ liệu hệ thống
    local cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    local mem=$(free -m | awk 'NR==2{printf "%.0f", $3*100/$2}')
    local stats=$(xray api statsquery --server=127.0.0.1:${XRAY_API_PORT} 2>/dev/null || echo "{}")

    # 2. Lọc IP User đang online từ access.log (Logic từ file cũ)
    online_connections=$(tail -n 500 "$LOG_FILE" | grep "accepted" | grep -v "127.0.0.1" | grep "email:" | while read -r line; do
        ip=$(echo "$line" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n1)
        user=$(echo "$line" | grep -oP 'email: \K\S+')
        if [ -n "$ip" ] && [ -n "$user" ]; then
            printf '{"ip": "%s", "user": "%s"}' "$ip" "$user"
        fi
    done | jq -s -c 'unique')
    [ -z "$online_connections" ] && online_connections="[]"

    local payload=$(jq -n \
        --arg cpu "$cpu" \
        --arg mem "$mem" \
        --argjson stats "$stats" \
        --argjson connections "$online_connections" \
        '{status: "online", cpu: $cpu, ram: $mem, traffic: $stats, active_connections: $connections}')

    # Ghi log test đầy đủ
    echo "$payload" | jq . > "$TEST_LOG"

    # 3. Đẩy Admin Nodes và Payload lên Web
    push_admin_nodes
    
    if [ -n "$API_DOMAIN" ] && [ -n "$API_KEY" ]; then
        curl -s -X POST "${API_DOMAIN}:${API_PORT}/api/node/sync-push" \
             -H "Authorization: Bearer ${API_KEY}" \
             -H "Content-Type: application/json" \
             -d "$payload" > /dev/null

        # 4. Pull lệnh từ web
        local response=$(curl -s -X GET "${API_DOMAIN}:${API_PORT}/api/node/users-pull" \
             -H "Authorization: Bearer ${API_KEY}")

        if echo "$response" | jq -e . >/dev/null 2>&1; then
            local action=$(echo "$response" | jq -r '.action')
            local email=$(echo "$response" | jq -r '.email')
            local uuid=$(echo "$response" | jq -r '.uuid')
            local status=$(echo "$response" | jq -r '.status // "active"')

            case "$action" in
                "ADD")
                    jq --arg e "$email" --arg u "$uuid" '. += [{"email": $e, "uuid": $u, "quota_gb": "0", "status": "active"}]' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
                    jq --arg e "$email" --arg u "$uuid" 'map(if .settings.clients != null then if .protocol == "vless" or .protocol == "vmess" then .settings.clients += [{"id": $u, "email": $e}] elif .protocol == "hysteria" or .protocol == "hy2" or .protocol == "hysteria2" then .settings.clients += [{"auth": $u, "email": $e}] else .settings.clients += [{"password": $u, "email": $e}] end elif .settings.users != null then .settings.users += [{"password": $u, "email": $e}] elif .users != null then .users += [{"password": $u, "email": $e}] else . end)' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    apply_config
                    ;;
                "DELETE")
                    jq --arg e "$email" 'del(.[] | select(.email == $e))' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
                    jq --arg e "$email" 'map(if .settings.clients != null then .settings.clients |= map(select(.email != $e)) elif .settings.users != null then .settings.users |= map(select(.email != $e)) else . end)' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    apply_config
                    ;;
                "TOGGLE")
                    jq --arg e "$email" --arg s "$status" 'map(if .email == $e then .status = $s else . end)' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
                    if [ "$status" == "active" ]; then
                        jq --arg e "$email" --arg u "$uuid" 'map(if .settings.clients != null then if .protocol == "vless" or .protocol == "vmess" then .settings.clients += [{"id": $u, "email": $e}] elif .protocol == "hysteria" or .protocol == "hy2" or .protocol == "hysteria2" then .settings.clients += [{"auth": $u, "email": $e}] else .settings.clients += [{"password": $u, "email": $e}] end elif .settings.users != null then .settings.users += [{"password": $u, "email": $e}] elif .users != null then .users += [{"password": $u, "email": $e}] else . end)' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    else
                        jq --arg e "$email" 'map(if .settings.clients != null then .settings.clients |= map(select(.email != $e)) elif .settings.users != null then .settings.users |= map(select(.email != $e)) else . end)' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    fi
                    apply_config
                    ;;
            esac
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
               echo "Đã đồng bộ admin nodes và kiểm tra lệnh từ Web thành công!"
           else
               echo "(Chưa cấu hình API, chỉ ghi file log test)"
           fi
           sleep 2
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