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
    echo -e "${BLUE}======= CẤU HÌNH KẾT NỐI API ========${NC}"
    echo -e "${RED}Lưu ý:${NC} Nếu để trống, sẽ giữ nguyên giá trị cũ."
    echo -e "Domain mẫu: https://example.com/api/node_sync.php"
    echo -e ""
    
    # 1. Lấy cấu hình hiện tại đang có (nếu chưa có thì bỏ trống hoặc dùng mặc định)
    local current_domain="${API_DOMAIN:-}"
    local current_port="${API_PORT:-10085}"
    local current_token="${API_TOKEN:-}"
    # Giữ nguyên trạng thái Bật/Tắt hiện tại, nếu file mới tinh thì mặc định là true (Bật)
    local current_enabled="${API_ENABLED:-true}"

    # [BỔ SUNG] Kiểm tra và thông báo nếu chưa có cấu hình
    if [ -z "$current_domain" ] || [ -z "$current_token" ]; then
        echo -e "${YELLOW}Thông báo: Hiện tại chưa có cấu hình kết nối API nào! Vui lòng thiết lập ngay bên dưới.${NC}"
        echo -e ""
    fi

    # 2. Hiển thị lựa chọn sửa, nếu nhấn Enter sẽ tự lấy lại giá trị cũ
    echo -e "Hiện tại: ${YELLOW}${current_domain}${NC}"
    read -p "Nhập URL File PHP: " input_domain

    input_domain="${input_domain:-$current_domain}"

    echo -e "Hiện tại: ${YELLOW}${current_port}${NC}"
    read -p "Nhập API_PORT Của VPS Này: " input_port
    input_port="${input_port:-$current_port}"

    echo -e "Hiện tại: ${YELLOW}${current_token}${NC}"
    read -p "Nhập API_TOKEN Của VPS Này: " input_token
    input_token="${input_token:-$current_token}"

    # 3. Lưu lại vào file api.conf mà không làm mất trạng thái Bật/Tắt
    mkdir -p "${CURRENT_DIR}/data"
    cat <<EOF > "${CURRENT_DIR}/data/api.conf"
API_DOMAIN="$input_domain"
API_PORT="$input_port"
API_TOKEN="$input_token"
API_ENABLED="$current_enabled"
EOF

    # 4. Load lại cấu hình mới vào script ngay lập tức
    source "${CURRENT_DIR}/data/api.conf"

    echo -e "Đã cập nhật cấu hình API thành công!"
    sleep 2
}

push_admin_nodes() {
    if [ -n "$API_DOMAIN" ] && [ -n "$API_TOKEN" ] && [ -n "$API_PORT" ]; then
        # 1. Lấy IP Public của VPS (Để kiểm tra kết nối từ ngoài vào)
        local pub_ip=$(curl -s https://ifconfig.me)
        
        # Lấy tên quốc gia dựa trên IP Public (Xóa khoảng trắng nếu có)
        local country=$(curl -s "http://ip-api.com/line/$pub_ip?fields=country" | sed 's/ //g')
        [ -z "$country" ] && country="Unknown"
        # Lấy mã quốc gia từ API gốc để chuyển thành cờ emoji
        local c_code=$(curl -s "http://ip-api.com/line/$pub_ip?fields=countryCode")

        # 2. Khởi tạo cấu trúc dữ liệu trạng thái trống
        local status_json="{}"

        # 3. Quét từng port dựa theo giao thức tương ứng (Phân tách TCP và UDP)
        while read -r p proto; do
            [ -z "$p" ] && continue
            
            # Mặc định sử dụng cờ quét cổng chế độ TCP (-z)
            local nc_flags="-z"
            
            # Nếu là nhóm giao thức chạy trên nền UDP (Hysteria 1/2) thì chuyển sang cờ -zu
            if [[ "$proto" == "hysteria" || "$proto" == "hy2" || "$proto" == "hysteria2" ]]; then
                nc_flags="-zu"
            fi

            # Thực hiện kiểm tra cổng với timeout 1 giây
            if timeout 1 nc $nc_flags -w 1 "$pub_ip" "$p" >/dev/null 2>&1; then
                status_json=$(echo "$status_json" | jq --arg p "$p" '. + {($p): "online"}')
            else
                # Tránh ghi đè trạng thái offline nếu port đó đã được xác nhận online trước đó
                status_json=$(echo "$status_json" | jq --arg p "$p" 'if .[$p] == "online" then . else . + {($p): "offline"} end')
            fi
        done < <(jq -r '.[] | select(.port != null) | "\(.port) \(.protocol)"' "$NODE_DB" | sort -u)

        # 4. Gắn status vào JSON, lọc client "admin" và thay thế HOÀN TOÀN tag thành TênQuốcGia-01, 02...
        local admin_nodes=$(jq -c --argjson statuses "$status_json" --arg country "$country" --arg cc "$c_code" '
            map(.settings.clients |= map(select(.email == "admin"))) | 
            map(. as $inb | $inb + {inbound_status: ($statuses[.port|tostring] // "offline")}) |
            to_entries | 
            map(.value + {tag: ($country + "-" + (if (.key + 1) < 10 then "0" else "" end) + (.key + 1 | tostring) + (if $cc != "" then " " + ($cc | explode | map(. + 127397) | implode) else "" end))})
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
    # [BỔ SUNG: Kiểm tra nếu API đang tắt thì dừng luôn]
    if [ "${API_ENABLED:-true}" = "false" ]; then
        echo "Thông báo: Liên kết API hiện đang TẮT. Không thể đồng bộ dữ liệu!"
        return
    fi

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
    
    # Dùng > ở dòng đầu tiên để xóa file cũ và ghi tiêu đề vào
echo "========================= REPORT TRAFFIC ========================" > "$TEST_LOG"
# Dùng >> ở các dòng sau để ghi tiếp ngày giờ và nội dung dữ liệu
echo "[$(date '+%Y-%m-%d %H:%M:%S')]" >> "$TEST_LOG"
echo "$traffic_payload" >> "$TEST_LOG"
echo "-----------------------------------------------------------------" >> "$TEST_LOG"

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
        local needs_apply=false
        
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
    # 1. Cập nhật USER_DB: Lọc bỏ record cũ bằng map(select(.email != $e)) sau đó thêm mới
    jq --arg e "$username" --arg u "$uuid" 'map(select(.email != $e)) + [{"email": $e, "uuid": $u, "quota_gb": "0", "status": "active"}]' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
    
    # 2. Cập nhật NODE_DB: Thay thế += bằng |= (map(select(.email != $e)) + [...]) để lọc trùng trước khi gán
    jq --arg e "$username" --arg u "$uuid" '
        map(
            if .settings.clients != null then
                if .protocol == "vless" or .protocol == "vmess" then 
                    .settings.clients |= (map(select(.email != $e)) + [{"id": $u, "email": $e}])
                elif .protocol == "hysteria" or .protocol == "hy2" or .protocol == "hysteria2" then 
                    .settings.clients |= (map(select(.email != $e)) + [{"auth": $u, "email": $e}])
                else 
                    .settings.clients |= (map(select(.email != $e)) + [{"password": $u, "email": $e}])
                end
            elif .settings.users != null then 
                .settings.users |= (map(select(.email != $e)) + [{"password": $u, "email": $e}])
            elif .users != null then 
                .users |= (map(select(.email != $e)) + [{"password": $u, "email": $e}])
            else . end
        )' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    
    needs_apply=true
    ;;
                "delete_user")
                    # Lệnh jq gốc từ file cũ của ông
                    jq --arg e "$username" 'del(.[] | select(.email == $e))' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
                    jq --arg e "$username" 'map(if .settings.clients != null then .settings.clients |= map(select(.email != $e)) elif .settings.users != null then .settings.users |= map(select(.email != $e)) else . end)' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    needs_apply=true
                    ;;
                "toggle_user")
                    # 1. Cập nhật trạng thái trong USER_DB
                    local status=$(echo "$payload_str" | jq -r '.status // "active"')
                    jq --arg e "$username" --arg s "$status" 'map(if .email == $e then .status = $s else . end)' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
                    
                    # 2. Cập nhật NODE_DB với logic Xóa cũ - Thêm mới (cho active)
                    if [ "$status" == "active" ]; then
                        jq --arg e "$username" --arg u "$uuid" '
                            map(
                                if .settings.clients != null then
                                    if .protocol == "vless" or .protocol == "vmess" then
                                        .settings.clients |= (map(select(.email != $e)) + [{"id": $u, "email": $e}])
                                    elif .protocol == "hysteria" or .protocol == "hy2" or .protocol == "hysteria2" then
                                        .settings.clients |= (map(select(.email != $e)) + [{"auth": $u, "email": $e}])
                                    else
                                        .settings.clients |= (map(select(.email != $e)) + [{"password": $u, "email": $e}])
                                    end
                                elif .settings.users != null then
                                    .settings.users |= (map(select(.email != $e)) + [{"password": $u, "email": $e}])
                                elif .users != null then
                                    .users |= (map(select(.email != $e)) + [{"password": $u, "email": $e}])
                                else . end
                            )' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    else
                        # Trạng thái disabled: Chỉ xóa (giữ nguyên logic gốc của bạn)
                        jq --arg e "$username" 'map(if .settings.clients != null then .settings.clients |= map(select(.email != $e)) elif .settings.users != null then .settings.users |= map(select(.email != $e)) else . end)' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    fi
                    needs_apply=true
                    ;;
                "reset_token")
                    # Cập nhật UUID mới trong users.json
                    jq --arg e "$username" --arg u "$uuid" 'map(if .email == $e then .uuid = $u else . end)' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
                    
                    # Cập nhật ID/Password/Auth mới trong nodes.json theo chuẩn Protocol (logic lấy từ user_manager.sh)
                    jq --arg e "$username" --arg u "$uuid" '
                        map(
                            . as $node |
                            if .settings.clients != null then 
                                .settings.clients |= map(
                                    if .email == $e then 
                                        if $node.protocol == "vless" or $node.protocol == "vmess" then
                                            {"id": $u, "email": $e}
                                        elif $node.protocol == "hysteria" or $node.protocol == "hy2" or $node.protocol == "hysteria2" then
                                            {"auth": $u, "email": $e}
                                        else
                                            {"password": $u, "email": $e}
                                        end
                                    else . end
                                )
                            elif .settings.users != null then 
                                .settings.users |= map(if .email == $e then {"password": $u, "email": $e} else . end)
                            elif .users != null then
                                .users |= map(if .email == $e then {"password": $u, "email": $e} else . end)
                            else . end
                        )' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
                    needs_apply=true
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
    if [ "$needs_apply" = true ]; then
            apply_config
        fi
    fi
}

check_install_netcat() {
    clear
    echo -e "\n--- KIỂM TRA & CÀI ĐẶT NETCAT (NC) ---"
    
    # Kiểm tra xem lệnh nc đã tồn tại chưa
    if command -v nc >/dev/null 2>&1; then
        echo -e "${GREEN}Netcat (nc) đã được cài đặt sẵn trên hệ thống!${NC}"
    else
        echo -e "${YELLOW}Netcat (nc) chưa được cài đặt. Tiến hành tự động cài đặt...${NC}"
        
        # Tự động nhận diện trình quản lý gói của hệ điều hành để cài đặt
        if command -v apt >/dev/null 2>&1; then
            apt-get update -y && apt-get install netcat-openbsd -y
        elif command -v yum >/dev/null 2>&1; then
            yum install nc -y
        else
            echo -e "${RED}Không tìm thấy trình quản lý gói phù hợp (apt/yum). Vui lòng cài đặt gói 'nc' thủ công!${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
            return
        fi

        # Kiểm tra lại một lần nữa sau khi cài đặt
        if command -v nc >/dev/null 2>&1; then
            echo -e "${GREEN}Cài đặt Netcat (nc) thành công! Chức năng quét port inbound đã sẵn sàng.${NC}"
        else
            echo -e "${RED}Cài đặt Netcat (nc) thất bại! Vui lòng kiểm tra lại kết nối mạng hoặc kho phần mềm.${NC}"
        fi
    fi
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

show_menu() {
    clear

    # Xác định trạng thái hiển thị kèm màu sắc hệ thống tương ứng
    local status_text="${GREEN}Đang Bật${NC}"
    if [ "${API_ENABLED:-true}" = "false" ]; then
        status_text="${RED}Đang Tắt${NC}"
    fi

    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}||${NC}         ${YELLOW}API SYNC MANAGER${NC}          ${BLUE}||${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "Hiện tại: ${CYAN}$status_text${NC}"
    echo -e ""
    echo -e " ${GREEN}1.${NC} Cấu hình / Sửa API"
    echo -e " ${GREEN}2.${NC} Đồng bộ dữ liệu thủ công"
    echo -e " ${GREEN}3.${NC} Bật/Tắt kết nối API"
    echo -e " ${GREEN}4.${NC} Kiểm tra & Cài đặt Netcat"
    echo -e " 0. ${RED}Quay lại${NC}"
    echo -e "${BLUE}---------------------------------------${NC}"
    echo -ne "${YELLOW}Nhập lựa chọn: ${NC}"
    read -r choice
    case $choice in
        1) setup_api ;;
        2) 
           # [BỔ SUNG] Kiểm tra trạng thái và cấu hình API trước khi đồng bộ
           if [ "${API_ENABLED:-true}" = "false" ]; then
               echo -e "${RED}Thông báo: Liên kết API hiện đang TẮT. Vui lòng bật (Phím 3) trước khi đồng bộ!${NC}"
               sleep 2
               return
           fi
           if [ -z "$API_DOMAIN" ] || [ -z "$API_TOKEN" ] || [ -z "$API_PORT" ]; then
               echo -e "${YELLOW}Thông báo: Chưa có cấu hình API. Vui lòng chọn phím 1 để thiết lập trước!${NC}"
               sleep 2
               return
           fi

           echo -e "${BLUE}Đang đồng bộ...${NC}"
           sync_process 
           echo -e "${GREEN}Đã chạy xong quy trình đồng bộ.${NC}"
           if [ -s "$NODE_DB" ]; then
               echo -e "${GREEN}Trạng thái: Đã gửi dữ liệu từ $NODE_DB lên server.${NC}"
           else
               echo -e "${RED}CẢNH BÁO: File $NODE_DB trống hoặc không tồn tại!${NC}"
           fi
           echo -ne "${YELLOW}Nhấn phím bất kỳ để tiếp tục...${NC}"
           read -r
           ;;
        3)
           # Đảo trạng thái liên kết
           if [ "${API_ENABLED:-true}" = "true" ]; then
               API_ENABLED="false"
           else
               API_ENABLED="true"
           fi
           
           # Ghi đè trạng thái mới vào file cấu hình mà không làm mất thông tin cũ
           mkdir -p "${CURRENT_DIR}/data"
           cat <<EOF > "${CURRENT_DIR}/data/api.conf"
API_DOMAIN="$API_DOMAIN"
API_PORT="$API_PORT"
API_TOKEN="$API_TOKEN"
API_ENABLED="$API_ENABLED"
EOF
           echo -e "${GREEN}Đã cập nhật trạng thái kết nối API thành công!${NC}"
           sleep 1
           ;;
        4)
           check_install_netcat
           ;;
        0) exit 0 ;;
        *) echo -e "${RED}Sai lựa chọn!${NC}"; sleep 1 ;;
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