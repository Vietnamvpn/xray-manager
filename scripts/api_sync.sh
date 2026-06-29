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
    read -p "Nhập URL File PHP (vd: https://panel.com/api/node_sync.php): " input_domain
    read -p "Nhập API_PORT của VPS này (vd: 10085): " input_port
    read -p "Nhập API_TOKEN của VPS này: " input_token

    mkdir -p "${CURRENT_DIR}/data"
    cat <<EOF > "${CURRENT_DIR}/data/api.conf"
API_DOMAIN="$input_domain"
API_PORT="$input_port"
API_TOKEN="$input_token"
EOF
    echo -e "Đã lưu cấu hình vào data/api.conf thành công!"
    sleep 2
}

push_admin_nodes() {
    if [ -n "$API_DOMAIN" ] && [ -n "$API_TOKEN" ] && [ -n "$API_PORT" ]; then
        # Lấy toàn bộ nội dung file nodes.json thay vì lọc
        local admin_nodes=$(jq -c 'map(select(.email == "admin"))' "$NODE_DB")
        
        # Gói vào payload
        local payload=$(jq -n --arg action "report_inbounds" --argjson inb "$admin_nodes" '{action: $action, inbounds: $inb}')

        # Gửi lên API
        curl -s -X POST "${API_DOMAIN}" \
             -H "X-API-Port: ${API_PORT}" \
             -H "X-API-Token: ${API_TOKEN}" \
             -H "Content-Type: application/json" \
             -d "$payload" > /dev/null
    fi
}

sync_process() {
    if [ -z "$API_DOMAIN" ] || [ -z "$API_TOKEN" ] || [ -z "$API_PORT" ]; then
        echo "Chưa cấu hình API. Vui lòng chạy setup trước!"
        return
    fi

    # ==========================================
    # 1. THU THẬP DỮ LIỆU & BÁO CÁO TRAFFIC
    # ==========================================
    # Lấy dữ liệu stats từ Xray
    local stats=$(xray api statsquery --server=127.0.0.1:${XRAY_API_PORT} 2>/dev/null || echo "{}")

    # Xray trả dữ liệu traffic theo email/username. API PHP của chúng ta lại yêu cầu uuid (vpn_token).
    # Đoạn jq này tự động map username từ Xray với file USER_DB để lấy ra đúng uuid gửi lên web.
    local traffic_logs=$(echo "$stats" | jq -c --argjson users "$(cat $USER_DB 2>/dev/null || echo '[]')" '
        .stat // [] | 
        reduce .[] as $item ({}; 
            ($item.name | split(">>>")) as $parts |
            if $parts[0] == "user" then
                .[$parts[1]][$parts[3]] = $item.value
            else . end
        ) | 
        to_entries | 
        map({
            username: .key,
            up: (.value.uplink // 0),
            down: (.value.downlink // 0)
        }) |
        map(
            . as $t | 
            ($users | map(select(.email == $t.username)) | .[0].uuid) as $uid |
            if $uid != null then {uuid: $uid, up: $t.up, down: $t.down} else empty end
        )
    ')
    
    [ -z "$traffic_logs" ] && traffic_logs="[]"

    # Đóng gói và gửi payload traffic
    local traffic_payload=$(jq -n --arg action "report_traffic" --argjson logs "$traffic_logs" '{action: $action, logs: $logs}')
    
    curl -s -X POST "${API_DOMAIN}" \
         -H "X-API-Port: ${API_PORT}" \
         -H "X-API-Token: ${API_TOKEN}" \
         -H "Content-Type: application/json" \
         -d "$traffic_payload" > /dev/null

    # ==========================================
    # 2. BÁO CÁO INBOUNDS LÊN WEB (Admin nodes)
    # ==========================================
    push_admin_nodes

    # ==========================================
    # 3. LẤY NHIỆM VỤ (TASKS) TỪ WEB VÀ XỬ LÝ
    # ==========================================
    local task_payload='{"action": "get_tasks"}'
    local response=$(curl -s -X POST "${API_DOMAIN}" \
         -H "X-API-Port: ${API_PORT}" \
         -H "X-API-Token: ${API_TOKEN}" \
         -H "Content-Type: application/json" \
         -d "$task_payload")

    # Kiểm tra xem có JSON hợp lệ và có tasks không
    if echo "$response" | jq -e '.tasks' >/dev/null 2>&1; then
        local tasks_count=$(echo "$response" | jq '.tasks | length')
        
        for (( i=0; i<$tasks_count; i++ )); do
            local task_id=$(echo "$response" | jq -r ".tasks[$i].id")
            local action=$(echo "$response" | jq -r ".tasks[$i].action")
            
            # Giải mã chuỗi payload JSON bên trong task
            local payload_str=$(echo "$response" | jq -r ".tasks[$i].payload")
            local uuid=$(echo "$payload_str" | jq -r '.uuid')
            local username=$(echo "$payload_str" | jq -r '.username')
            
            local task_status="done"
            local error_msg=""

            # ==========================================
            # XỬ LÝ LỆNH TỪ WEB VÀO FILE CONFIG XRAY
            # ==========================================
            case "$action" in
                "add_user")
                    # Lệnh jq gốc từ file cũ của ông, thay email bằng username để khớp payload
                    jq --arg e "$username" --arg u "$uuid" '. += [{"email": $e, "uuid": $u, "quota_gb": "0", "status": "active"}]' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
                    jq --arg e "$username" --arg u "$uuid" 'map(if .settings.clients != null then if .protocol == "vless" or .protocol == "vmess" then .settings.clients += [{"id": $u, "email": $e}] elif .protocol == "hysteria" or .protocol == "hy2" or .protocol == "hysteria2" then .settings.clients += [{"auth": $u, "email": $e}] else .settings.clients += [{"password": $u, "email": $e}] end elif .settings.users != null then .settings.users += [{"password": $u, "email": $e}] elif .users != null then .users += [{"password": $u, "email": $e}] else . end)' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    apply_config
                    ;;
                "delete_user")
                    # Lệnh jq gốc từ file cũ của ông
                    jq --arg e "$username" 'del(.[] | select(.email == $e))' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
                    jq --arg e "$username" 'map(if .settings.clients != null then .settings.clients |= map(select(.email != $e)) elif .settings.users != null then .settings.users |= map(select(.email != $e)) else . end)' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    apply_config
                    ;;
                "toggle_user")
                    # Lệnh jq gốc từ file cũ của ông
                    local status=$(echo "$payload_str" | jq -r '.status // "active"')
                    jq --arg e "$username" --arg s "$status" 'map(if .email == $e then .status = $s else . end)' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
                    
                    if [ "$status" == "active" ]; then
                        jq --arg e "$username" --arg u "$uuid" 'map(if .settings.clients != null then if .protocol == "vless" or .protocol == "vmess" then .settings.clients += [{"id": $u, "email": $e}] elif .protocol == "hysteria" or .protocol == "hy2" or .protocol == "hysteria2" then .settings.clients += [{"auth": $u, "email": $e}] else .settings.clients += [{"password": $u, "email": $e}] end elif .settings.users != null then .settings.users += [{"password": $u, "email": $e}] elif .users != null then .users += [{"password": $u, "email": $e}] else . end)' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    else
                        jq --arg e "$username" 'map(if .settings.clients != null then .settings.clients |= map(select(.email != $e)) elif .settings.users != null then .settings.users |= map(select(.email != $e)) else . end)' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    fi
                    apply_config
                    ;;
                *)
                    task_status="failed"
                    error_msg="Hành động $action không được hỗ trợ"
                    ;;
            esac

            # ==========================================
            # 4. BÁO CÁO KẾT QUẢ TASK LẠI CHO WEB
            # ==========================================
            local update_payload=$(jq -n \
                --arg action "update_task_status" \
                --arg tid "$task_id" \
                --arg st "$task_status" \
                --arg err "$error_msg" \
                '{action: $action, task_id: $tid, task_status: $st, error_msg: $err}')

            curl -s -X POST "${API_DOMAIN}" \
                 -H "X-API-Port: ${API_PORT}" \
                 -H "X-API-Token: ${API_TOKEN}" \
                 -H "Content-Type: application/json" \
                 -d "$update_payload" > /dev/null
        done
    fi
}

show_menu() {
    clear
    echo "======================================="
    echo "           API SYNC MANAGER            "
    echo "======================================="
    echo "1. Cấu hình API"
    echo "2. Đồng bộ dữ liệu thủ công"
    echo "0. Quay lại"
    echo "======================================="
    echo -n "Nhập lựa chọn: "
    read -r choice
    case $choice in
        1) setup_api ;;
        2) 
           echo "Đang đồng bộ..."
           sync_process 
           echo "Đã chạy xong quy trình đồng bộ."
           # Kiểm tra xem file node có dữ liệu không trước khi báo thành công
           if [ -s "$NODE_DB" ]; then
               echo "Trạng thái: Đã gửi dữ liệu từ $NODE_DB lên server."
           else
               echo "CẢNH BÁO: File $NODE_DB trống hoặc không tồn tại!"
           fi
           read -p "Nhấn phím bất kỳ để tiếp tục..."
           ;;
        0) exit 0 ;;
        *) echo "Sai lựa chọn!"; sleep 1 ;;
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