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
        # 1. Lấy IP Public của VPS (Để kiểm tra kết nối từ ngoài vào)
        local pub_ip=$(curl -s https://ifconfig.me)

        # 2. Lấy danh sách các port cần kiểm tra
        local ports=$(jq -r '.[].port' "$NODE_DB" | sort -u)
        local status_json="{}"

        # 3. Kiểm tra từng port bằng Netcat (nc)
        for p in $ports; do
            # Dùng nc để thử kết nối tới IP Public của chính nó
            # -z: scan mode, -w 1: timeout 1 giây
            if timeout 1 nc -z -w 1 "$pub_ip" "$p" >/dev/null 2>&1; then
                status_json=$(echo "$status_json" | jq --arg p "$p" '. + {($p): "online"}')
            else
                status_json=$(echo "$status_json" | jq --arg p "$p" '. + {($p): "offline"}')
            fi
        done

        # 4. Gắn status vào JSON và lọc client "admin"
        local admin_nodes=$(jq -c --argjson statuses "$status_json" '
            map(.settings.clients |= map(select(.email == "admin"))) | 
            map(. as $inb | $inb + {inbound_status: ($statuses[.port|tostring] // "offline")})
        ' "$NODE_DB")
        
        # 5. Gói payload
        local payload=$(jq -n --arg action "report_inbounds" --argjson inb "$admin_nodes" '{action: $action, inbounds: $inb}')
        
        # 6. Gửi lên API
        local response=$(curl -s -X POST "${API_DOMAIN}" \
             -H "X-API-Port: ${API_PORT}" \
             -H "X-API-Token: ${API_TOKEN}" \
             -H "Content-Type: application/json" \
             -d "$payload")

        # 7. Kiểm tra lỗi
        if echo "$response" | grep -q "error"; then
            local error_msg=$(echo "$response" | jq -r '.message // "Lỗi không xác định"')
            echo "Lỗi đồng bộ Node: $error_msg"
        fi
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
    # Giữ lại 'username' trong object cho đến khi merge xong
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
            # --- CHỖ NÀY: Giữ lại username để merge ---
            if $uid != null then {uuid: $uid, username: $t.username, up: $t.up, down: $t.down} else empty end
        )
    ')
    
    [ -z "$traffic_logs" ] && traffic_logs="[]"

    # [ĐOẠN CẦN CHÈN VÀO]
    local ip_data="[]"
    if [ -s "$LOG_FILE" ]; then
        # 1. Đọc toàn bộ log hiện tại vào biến tạm
        local log_content=$(cat "$LOG_FILE")
        # 2. Xóa trắng file log ngay lập tức để Xray ghi tiếp log mới (Giải quyết vụ tắt VPN vẫn gửi IP cũ)
        > "$LOG_FILE"

        # 3. Lọc IP và Email bằng sed từ biến tạm vừa lưu
        ip_data=$(echo "$log_content" | sed -n 's/.*from \([0-9.]*\):.*email: \([^ ]*\).*/\1 \2/p' | \
            jq -R 'split(" ") | {ip: .[0], email: .[1]}' | \
            jq -s 'group_by(.email) | map({username: .[0].email, ips: map(.ip) | unique})' 2>/dev/null || echo "[]")
    fi

    # 4. Merge IP vào mảng traffic_logs (Dùng INDEX để sửa lỗi nhân đôi dữ liệu của jq)
    traffic_logs=$(echo "$traffic_logs" | jq -c --argjson ips "$ip_data" '
        ($ips | INDEX(.username)) as $ip_map |
        map(. + {ips: ($ip_map[.username].ips // [])}) | 
        map(del(.username))
    ')

    # Đóng gói và gửi payload traffic
    local traffic_payload=$(jq -n --arg action "report_traffic" --argjson logs "$traffic_logs" '{action: $action, logs: $logs}')
    
    # Dùng > ở dòng đầu tiên để xóa file cũ và ghi nội dung mới vào
echo "[$(date '+%Y-%m-%d %H:%M:%S')] --- REPORT TRAFFIC ---" > "$TEST_LOG"

# Các dòng sau dùng >> để ghi nối tiếp vào file đã được làm sạch
echo "$traffic_payload" >> "$TEST_LOG"
echo "-----------------------------------" >> "$TEST_LOG"

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