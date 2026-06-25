#!/bin/bash
# Module quản lý Người dùng (Users) - Tích hợp Database

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

# Thông số kết nối Database (Nên được định nghĩa trong config.conf)
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-your_password}"
DB_NAME="${DB_NAME:-panel_db}"

INSTALL_DIR="${INSTALL_DIR:-/etc/xray-manager}"
NODE_DB="${INSTALL_DIR}/data/nodes.json" # Tạm giữ lại JSON cho Node nếu chưa có yêu cầu đổi

# Hàm hỗ trợ thực thi SQL query trả về định dạng text thuần
run_sql() {
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -sNe "$1" 2>/dev/null
}

show_user_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}             USER MANAGER              ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Xem danh sách Users & Link Node"
    echo -e "2. Thêm User mới"
    echo -e "3. Xóa User"
    echo -e "0. Quay lại Menu chính"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn: "
}

list_users() {
    clear
    echo -e "${GREEN}--- Danh Sách Users & Liên Kết Node ---${NC}"
    
    # Lấy danh sách user từ Database
    local users_data=$(run_sql "SELECT email, uuid, quota_gb, status FROM users;")
    
    if [ -z "$users_data" ]; then
        echo "Không có User nào trong Database."
        echo ""
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
        return
    fi

    # Lặp qua từng user lấy từ DB
    echo "$users_data" | while IFS=$'\t' read -r email uuid quota status; do
        
        echo -e "${BLUE}====================================================${NC}"
        echo -e " 👤 ${YELLOW}User:${NC} $email | ${YELLOW}Quota:${NC} ${quota}GB | ${YELLOW}Trạng thái:${NC} $status"
        echo -e "${BLUE}----------------------------------------------------${NC}"
        echo -e " 🔗 ${GREEN}Các liên kết Node kết nối:${NC}"
        
        local found_link=false
        
        # Quét chéo Database Node để đối chiếu Email và xuất link (Vẫn giữ logic đọc từ JSON file của bạn)
        if [ -s "$NODE_DB" ]; then
            while read -r node_row; do
                local user_cred=$(echo "$node_row" | jq -r --arg e "$email" '
                    if .protocol == "vless" or .protocol == "vmess" then
                        (.settings.clients[]? | select(.email == $e) | .id) // empty
                    elif .protocol == "trojan" then
                        (.settings.clients[]? | select(.email == $e) | .password) // empty
                    elif .protocol == "hysteria2" or .protocol == "hysteria" or .protocol == "hy2" then
                        (.settings.users[]? | select(.email == $e) | .password) // empty
                    else empty end
                ')
                
                if [ -n "$user_cred" ]; then
                    found_link=true
                    local protocol=$(echo "$node_row" | jq -r '.protocol')
                    local port=$(echo "$node_row" | jq -r '.port')
                    local domain=$(echo "$node_row" | jq -r '.domain // ""')
                    local tag=$(echo "$node_row" | jq -r '.tag // ""')
                    
                    local net=$(echo "$node_row" | jq -r '.streamSettings.network // "tcp"')
                    local tls_type=""
                    local sni=""
                    local pbk=""
                    local path=""
                    local host=""
                    
                    if [ "$(echo "$node_row" | jq -e '.streamSettings.security == "reality" or .streamSettings.realitySettings != null' 2>/dev/null)" == "true" ]; then
                        tls_type="reality"
                        sni=$(echo "$node_row" | jq -r '.streamSettings.realitySettings.serverName // ""')
                        pbk=$(echo "$node_row" | jq -r '.publicKey // .streamSettings.realitySettings.publicKey // ""')
                    elif [ "$(echo "$node_row" | jq -e '.streamSettings.security == "tls" or .streamSettings.tlsSettings != null' 2>/dev/null)" == "true" ]; then
                        tls_type="tls"
                        sni=$(echo "$node_row" | jq -r '.streamSettings.tlsSettings.serverName // ""')
                    fi
                    
                    if [ "$net" == "ws" ]; then
                        path=$(echo "$node_row" | jq -r '.streamSettings.wsSettings.path // "/"')
                        host=$(echo "$node_row" | jq -r '.streamSettings.wsSettings.headers.Host // ""')
                    elif [ "$net" == "grpc" ]; then
                        path=$(echo "$node_row" | jq -r '.streamSettings.grpcSettings.serviceName // ""')
                    fi
                    
                    local link=""
                    case $protocol in
                        vless|trojan)
                            link="${protocol}://${user_cred}@${domain}:${port}?type=${net}"
                            [ -n "$tls_type" ] && link="${link}&security=${tls_type}"
                            [ -n "$sni" ] && link="${link}&sni=${sni}"
                            [ -n "$pbk" ] && link="${link}&pbk=${pbk}"
                            [ -n "$path" ] && link="${link}&path=${path}"
                            [ -n "$host" ] && link="${link}&host=${host}"
                            link="${link}#${tag}"
                            ;;
                        vmess)
                            local vmess_json="{\"v\":\"2\",\"ps\":\"${tag}\",\"add\":\"${domain}\",\"port\":${port},\"id\":\"${user_cred}\",\"aid\":\"0\",\"net\":\"${net}\",\"type\":\"none\",\"host\":\"${host}\",\"path\":\"${path}\",\"tls\":\"${tls_type}\",\"sni\":\"${sni}\"}"
                            local b64=$(echo -n "$vmess_json" | base64 -w 0)
                            link="vmess://${b64}"
                            ;;
                        hy2|hysteria2)
                            link="hysteria2://${user_cred}@${domain}:${port}/?sni=${sni}&insecure=1#${tag}"
                            ;;
                    esac
                    echo -e "    - ${YELLOW}[${protocol^^}]${NC} $link"
                fi
            done < <(jq -c '.[]' "$NODE_DB" 2>/dev/null)
        fi
        
        if [ "$found_link" = false ]; then
            echo "    (User này chưa được gán vào Node nào để tạo link)"
        fi
    done
    
    echo ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

add_user() {
    echo -n "Nhập Email/Tên User: "
    read email
    uuid=$(uuidgen)
    
    # Thực thi lệnh INSERT vào DB
    run_sql "INSERT INTO users (email, uuid, quota_gb, status) VALUES ('$email', '$uuid', 0, 'active');"
    
    if [ $? -eq 0 ]; then
        log_info "Đã thêm user: $email với UUID: $uuid vào Database"
    else
        log_error "Lỗi khi thêm user vào Database. Vui lòng kiểm tra lại kết nối hoặc trùng lặp Email."
    fi
    
    log_info "Ghi chú: Sẽ cần kết nối API của Core để thêm user trực tiếp vào Inbound."
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

delete_user() {
    echo -n "Nhập Email/Tên User cần xóa: "
    read email
    
    # Thực thi lệnh DELETE từ DB
    run_sql "DELETE FROM users WHERE email = '$email';"
    
    if [ $? -eq 0 ]; then
        log_info "Đã xóa user: $email khỏi Database."
    else
        log_error "Lỗi khi xóa user."
    fi
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

while true; do
    show_user_menu
    read -r choice
    case $choice in
        1) list_users ;;
        2) add_user ;;
        3) delete_user ;;
        0) break ;;
        *) log_error "Lựa chọn không hợp lệ!" ; sleep 1 ;;
    esac
done