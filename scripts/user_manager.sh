#!/bin/bash
# Module quản lý Người dùng (Users)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

INSTALL_DIR="${INSTALL_DIR:-/etc/xray-manager}"
NODE_DB="${INSTALL_DIR}/data/nodes.json"
USER_DB="${INSTALL_DIR}/data/users.json"

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
    
    if [ ! -s "$USER_DB" ] || [ "$(jq '. | length' "$USER_DB" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo "Không có User nào trong hệ thống."
        echo ""
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
        return
    fi

    # Lặp qua từng user trong Database
    while read -r user_row; do
        local email=$(echo "$user_row" | jq -r '.email')
        local uuid=$(echo "$user_row" | jq -r '.uuid')
        local quota=$(echo "$user_row" | jq -r '.quota_gb')
        local status=$(echo "$user_row" | jq -r '.status')
        
        echo -e "${BLUE}====================================================${NC}"
        echo -e " 👤 ${YELLOW}User:${NC} $email | ${YELLOW}Quota:${NC} ${quota}GB | ${YELLOW}Trạng thái:${NC} $status"
        echo -e "${BLUE}----------------------------------------------------${NC}"
        echo -e " 🔗 ${GREEN}Các liên kết Node kết nối:${NC}"
        
        local found_link=false
        
        # Quét chéo Database Node để đối chiếu Email và xuất link
        if [ -s "$NODE_DB" ]; then
            while read -r node_row; do
                # Lấy UUID/Password thực tế của user trong Node này
                local user_cred=$(echo "$node_row" | jq -r --arg e "$email" '
                    if .protocol == "vless" or .protocol == "vmess" then
                        (.settings.clients[]? | select(.email == $e) | .id) // empty
                    elif .protocol == "trojan" then
                        (.settings.clients[]? | select(.email == $e) | .password) // empty
                    elif .protocol == "hysteria2" or .protocol == "hysteria" or .protocol == "hy2" then
                        (.settings.users[]? | select(.email == $e) | .password) // empty
                    else empty end
                ')
                
                # Nếu User có tồn tại trong Node này thì tiến hành build link
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
                    
                    # Đọc thông số TLS hoặc Reality
                    local sid=""
                    local fp="chrome"
                    
                    if [ "$(echo "$node_row" | jq -e '.streamSettings.security == "reality" or .streamSettings.realitySettings != null' 2>/dev/null)" == "true" ]; then
                        tls_type="reality"
                        sni=$(echo "$node_row" | jq -r '.streamSettings.realitySettings.serverName // ""')
                        pbk=$(echo "$node_row" | jq -r '.publicKey // .streamSettings.realitySettings.publicKey // ""')
                        sid=$(echo "$node_row" | jq -r '.streamSettings.realitySettings.shortIds[0] // ""')
                        fp=$(echo "$node_row" | jq -r '.streamSettings.realitySettings.fingerprint // "chrome"')
                    elif [ "$(echo "$node_row" | jq -e '.streamSettings.security == "tls" or .streamSettings.tlsSettings != null' 2>/dev/null)" == "true" ]; then
                        tls_type="tls"
                        sni=$(echo "$node_row" | jq -r '.streamSettings.tlsSettings.serverName // ""')
                        fp=$(echo "$node_row" | jq -r '.streamSettings.tlsSettings.fingerprint // "chrome"')
                    fi
                    
                    # Đọc thông số Transport (WebSocket, gRPC, v.v.)
                    if [ "$net" == "ws" ]; then
                        path=$(echo "$node_row" | jq -r '.streamSettings.wsSettings.path // "/"')
                        host=$(echo "$node_row" | jq -r '.streamSettings.wsSettings.headers.Host // ""')
                    elif [ "$net" == "grpc" ]; then
                        path=$(echo "$node_row" | jq -r '.streamSettings.grpcSettings.serviceName // ""')
                    fi
                    
                    # Ghép chuỗi URI dựa trên Protocol chuẩn Xray Client
                    local link=""
                    case $protocol in
                        vless|trojan)
                            link="${protocol}://${user_cred}@${domain}:${port}?type=${net}"
                            
                            # [QUAN TRỌNG] VLESS bắt buộc phải khai báo encryption=none
                            if [ "$protocol" == "vless" ]; then
                                link="${link}&encryption=none"
                            fi
                            
                            [ -n "$tls_type" ] && link="${link}&security=${tls_type}"
                            [ -n "$sni" ] && link="${link}&sni=${sni}"
                            
                            # Xử lý tham số Reality / TLS
                            if [ "$tls_type" == "reality" ]; then
                                [ -n "$pbk" ] && [ "$pbk" != "null" ] && link="${link}&pbk=${pbk}"
                                [ -n "$sid" ] && [ "$sid" != "null" ] && link="${link}&sid=${sid}"
                                [ -n "$fp" ] && [ "$fp" != "null" ] && link="${link}&fp=${fp}"
                            elif [ "$tls_type" == "tls" ]; then
                                [ -n "$fp" ] && [ "$fp" != "null" ] && link="${link}&fp=${fp}"
                            fi
                            
                            # Phân biệt chuẩn cho gRPC (serviceName) và WS/xHTTP (path)
                            if [ "$net" == "grpc" ] && [ -n "$path" ]; then
                                link="${link}&serviceName=$(echo -n "$path" | jq -sRr @uri)"
                            elif [ -n "$path" ]; then
                                local enc_path=$(echo -n "$path" | jq -sRr @uri)
                                [ "$enc_path" != "%2F" ] && link="${link}&path=${enc_path}" || link="${link}&path=/"
                            fi
                            
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
                    echo -e "    - $link"
                fi
            done < <(jq -c '.[]' "$NODE_DB" 2>/dev/null)
        fi
        
        if [ "$found_link" = false ]; then
            echo "    (User này chưa được gán vào Node nào để tạo link)"
        fi
    done < <(jq -c '.[]' "$USER_DB" 2>/dev/null)
    
    echo ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

add_user() {
    echo -n "Nhập Email/Tên User: "
    read email
    uuid=$(uuidgen)
    
    # Cập nhật vào users.json
    jq --arg email "$email" --arg uuid "$uuid" --arg quota "0" \
       '. += [{"email": $email, "uuid": $uuid, "quota_gb": $quota, "status": "active"}]' \
       "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
       
    log_info "Đã thêm user: $email với UUID: $uuid"
    
    log_info "Ghi chú: Sẽ cần kết nối API của Xray để thêm user trực tiếp vào Inbound."
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

delete_user() {
    echo -n "Nhập Email/Tên User cần xóa: "
    read email
    
    jq --arg email "$email" 'del(.[] | select(.email == $email))' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
    
    log_info "Đã xóa user: $email khỏi database."
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