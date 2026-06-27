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
    echo -e "${BLUE}||${NC}           ${YELLOW}USER MANAGER${NC}            ${BLUE}||${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. ${CYAN}Xem Danh Sách Users & Link Node${NC}"
    echo -e "2. ${CYAN}Thêm User Mới${NC}"
    echo -e "3. ${CYAN}Xóa User${NC}"
    echo -e "4. ${CYAN}Tắt/Mở Mạng User${NC}"
    echo -e "5. ${CYAN}Reset Token User${NC}"
    echo -e "0. ${RED}Quay Lại${NC}"
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

    # [BƯỚC 1]: Gọi API lấy IP và Quốc gia đúng 1 lần duy nhất trên cùng
    local vps_ip=$(curl -sS --max-time 2 ifconfig.me 2>/dev/null || echo "127.0.0.1")
    local country=""
    
    if [ "$vps_ip" != "127.0.0.1" ]; then
        country=$(curl -sS --max-time 2 "http://ip-api.com/line/$vps_ip?fields=country" 2>/dev/null | tr -d ' ' | tr -d '\r')
    fi
    
    # Cứu hộ nếu API lỗi hoặc không có mạng
    if [ -z "$country" ] || [ "$country" == "fail" ] || [[ "$country" == *"<!DOCTYPE"* ]]; then
        country="Unknown"
    fi

    # [BƯỚC 2]: Tiền xử lý (Pre-process) toàn bộ Node để gán Tag và lưu vào RAM
    declare -A precalc_tags
    local node_idx=1
    
    if [ -s "$NODE_DB" ]; then
        # Quét lấy toàn bộ Port của các Inbound/Node để làm khoá nhận diện và đánh số thứ tự
        while read -r n_port; do
            if [ -n "$n_port" ] && [ "$n_port" != "null" ]; then
                local count_fmt=$(printf "%02d" $node_idx)
                precalc_tags["$n_port"]="${country}-${count_fmt}"
                ((node_idx++))
            fi
        done < <(jq -r '.[].port // empty' "$NODE_DB" 2>/dev/null)
    fi

    # [BƯỚC 3]: Lặp qua từng user trong Database
    while read -r user_row; do
        local email=$(echo "$user_row" | jq -r '.email')
        local uuid=$(echo "$user_row" | jq -r '.uuid')
        local quota=$(echo "$user_row" | jq -r '.quota_gb')
        local status=$(echo "$user_row" | jq -r '.status')
        
        echo -e "${BLUE}====================================================${NC}"
        echo -e " ${YELLOW}User:${NC} $email | ${YELLOW}Quota:${NC} ${quota}GB | ${YELLOW}Trạng thái:${NC} $status"
        echo -e "${BLUE}----------------------------------------------------${NC}"
        echo -e " ${GREEN}Các liên kết Node kết nối:${NC}"
        
        local found_link=false
        
        # Quét chéo Database Node để đối chiếu Email và xuất link
        if [ -s "$NODE_DB" ]; then
            while read -r node_row; do
                # Lấy UUID/Password/Auth thực tế (Tự động quét cả clients hoặc users)
                local user_cred=$(echo "$node_row" | jq -r --arg e "$email" '
                    (.settings.clients // .settings.users // [])[] 
                    | select(.email == $e) 
                    | (.id // .password // .auth) // empty
                ')
                
                # Nếu User có tồn tại trong Node này thì tiến hành build link
                if [ -n "$user_cred" ]; then
                    found_link=true
                    local protocol=$(echo "$node_row" | jq -r '.protocol')
                    local port=$(echo "$node_row" | jq -r '.port')
                    
                    # [XUẤT TAG]: Lấy trực tiếp từ mảng đã tính toán sẵn ở Bước 2 dựa vào Port
                    local tag="${precalc_tags["$port"]}"
                    [ -z "$tag" ] && tag="${country}-00" # Fallback phòng hờ lỗi
                    
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

                    # [XỬ LÝ ĐỘNG ĐỊA CHỈ ĐƯỜNG TRUYỀN] 
                    local domain=$(echo "$node_row" | jq -r '.domain // ""')
                    if [ -z "$domain" ] || [ "$domain" == "null" ]; then
                        # Trực tiếp sử dụng biến $vps_ip đã lấy ở BƯỚC 1 thay vì gọi lại curl
                        if [[ "$protocol" == "hy2" || "$protocol" == "hysteria2" || "$protocol" == "hysteria" ]]; then
                            domain="$vps_ip"
                        elif [ "$tls_type" == "tls" ] && [ -n "$sni" ] && [ "$sni" != "null" ]; then
                            domain="$sni"
                        elif [ "$net" == "ws" ] && [ -n "$host" ] && [ "$host" != "null" ]; then
                            domain="$host"
                        else
                            domain="$vps_ip"
                        fi
                    fi
                    
                    # Ghép chuỗi URI dựa trên Protocol chuẩn Xray Client
                    local link=""
                    case $protocol in
                        vless|trojan)
                            link="${protocol}://${user_cred}@${domain}:${port}?type=${net}&allowInsecure=1"
                            
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
                        hy2|hysteria2|hysteria)
                            # Bốc mật khẩu Salamander (nếu có)
                            local obfs_pass=$(echo "$node_row" | jq -r '.streamSettings.finalmask.udp[0].settings.password // empty')
                            
                            link="hysteria2://${user_cred}@${domain}:${port}/?sni=${sni}&insecure=1"
                            
                            # Nếu có mật khẩu obfs thì mới thêm vào link
                            [ -n "$obfs_pass" ] && link="${link}&obfs=salamander&obfs-password=${obfs_pass}"
                            
                            link="${link}#${tag}"
                            ;;
                    esac
                    echo -e " $link"
                fi
            done < <(jq -c '.[]' "$NODE_DB" 2>/dev/null)
        fi
        
        if [ "$found_link" = false ]; then
            echo "    (User này chưa được gán vào Node nào để tạo link)"
        fi
    done < <(jq -c '.[]' "$USER_DB" 2>/dev/null)
    
    echo -e "${BLUE}----------------------------------------------------${NC}"
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

add_user() {
    local email=""
    
    # Vòng lặp bắt buộc nhập tên và kiểm tra trùng lặp
    while true; do
        echo -n "Nhập Email/Tên User: "
        read email
        
        # 1. Kiểm tra trống
        if [ -z "$email" ]; then
            echo -e "${RED}[LỖI] Tên User không được để trống! Vui lòng nhập lại.${NC}"
            continue
        fi
        
        # 2. Kiểm tra tồn tại
        if jq -e --arg e "$email" '.[] | select(.email == $e)' "$USER_DB" >/dev/null 2>&1; then
            echo -e "${RED}[LỖI] User '$email' đã tồn tại! Vui lòng nhập tên khác.${NC}"
            continue
        fi
        
        # Nếu đã qua 2 bước trên thì thoát vòng lặp
        break
    done

    uuid=$(uuidgen)
    
    # 1. Cập nhật vào users.json
    jq --arg email "$email" --arg uuid "$uuid" --arg quota "0" \
       '. += [{"email": $email, "uuid": $uuid, "quota_gb": $quota, "status": "active"}]' \
       "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
       
    # 2. Vòng lặp chọn Node (Bắt nhập lại nếu sai)
    local target_port=""
    while true; do
        echo -e "\n${YELLOW}--- THÊM USER VÀO NODE CỦA BẠN ---${NC}"
        echo -e "Nhập Port của Node muốn thêm user này vào."
        echo -e "Để trống sẽ thêm vào TẤT CẢ các Node."
        echo -e ""
        read -p "${GREEN}Nhập Port: ${NC}" target_port

        if [ -z "$target_port" ]; then
            echo -e "${BLUE}-> Đang thêm user vào TẤT CẢ các node...${NC}"
            break
        fi

        if jq -e --arg p "$target_port" '.[] | select(.port == ($p|tonumber))' "$NODE_DB" >/dev/null 2>&1; then
            echo -e "${BLUE}-> Đã tìm thấy Node cổng $target_port. Đang xử lý...${NC}"
            break
        else
            echo -e "${RED}[LỖI] Cổng $target_port không tồn tại trong hệ thống! Vui lòng nhập lại.${NC}"
            sleep 1
        fi
    done

    # 3. Cập nhật vào nodes.json (Tự động nhận diện cấu trúc mảng & Protocol)
    if [ -z "$target_port" ]; then
        jq --arg e "$email" --arg u "$uuid" '
            map(
                if .settings.clients != null then 
                    if .protocol == "vless" or .protocol == "vmess" then
                        .settings.clients += [{"id": $u, "email": $e}]
                    elif .protocol == "hysteria" or .protocol == "hy2" or .protocol == "hysteria2" then
                        .settings.clients += [{"auth": $u, "email": $e}]
                    else
                        .settings.clients += [{"password": $u, "email": $e}]
                    end
                elif .settings.users != null then 
                    .settings.users += [{"password": $u, "email": $e}]
                elif .users != null then
                    .users += [{"password": $u, "email": $e}]
                else . end
            )' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    else
        jq --arg e "$email" --arg u "$uuid" --arg p "$target_port" '
            map(
                if .port == ($p|tonumber) then
                    if .settings.clients != null then 
                        if .protocol == "vless" or .protocol == "vmess" then
                            .settings.clients += [{"id": $u, "email": $e}]
                        elif .protocol == "hysteria" or .protocol == "hy2" or .protocol == "hysteria2" then
                            .settings.clients += [{"auth": $u, "email": $e}]
                        else
                            .settings.clients += [{"password": $u, "email": $e}]
                        end
                    elif .settings.users != null then 
                        .settings.users += [{"password": $u, "email": $e}]
                    elif .users != null then
                        .users += [{"password": $u, "email": $e}]
                    else . end
                else . end
            )' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    fi

    # 4. Áp dụng
    log_info "Đang áp dụng thay đổi và khởi động lại Xray..."
    apply_config 
    log_info "Đã thêm user: $email thành công."
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

delete_user() {
    echo -e "\n${YELLOW}--- XÓA USER ---${NC}"
    echo -n "Nhập Tên User cần xóa để trống sẽ xóa TẤT CẢ: "
    read email
    
    # TRƯỜNG HỢP 1: XÓA TẤT CẢ
    if [ -z "$email" ]; then
        echo -e "${RED}=====================================================${NC}"
        echo -e "${RED}CẢNH BÁO: BẠN ĐANG CHỌN XÓA TẤT CẢ USER TRONG HỆ THỐNG!${NC}"
        echo -e "${RED}Hành động này không thể hoàn tác.${NC}"
        echo -e "${RED}=====================================================${NC}"
        read -p "Bạn có chắc chắn muốn xóa TẤT CẢ không? (y/n): " confirm
        
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            # Reset users.json về rỗng
            echo "[]" > "$USER_DB"
            
            # Reset clients/users trong nodes.json (Tự động dọn dẹp theo mảng có sẵn)
            jq 'map(
                if .settings.clients != null then .settings.clients = []
                elif .settings.users != null then .settings.users = []
                else . end
            )' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
            
            log_info "Đã xóa TẤT CẢ user khỏi hệ thống."
            apply_config
        else
            echo -e "${YELLOW}Đã hủy lệnh xóa tất cả.${NC}"
        fi

    # TRƯỜNG HỢP 2: XÓA 1 USER CỤ THỂ
    else
        # Kiểm tra user có tồn tại không
        if ! jq -e --arg e "$email" '.[] | select(.email == $e)' "$USER_DB" >/dev/null 2>&1; then
            echo -e "${RED}[LỖI] User '$email' không tồn tại!${NC}"
        else
            # 1. Xóa trong users.json
            jq --arg email "$email" 'del(.[] | select(.email == $email))' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
            
            # 2. Xóa trong nodes.json (Tự động lọc xóa theo mảng)
            jq --arg e "$email" '
                map(
                    if .settings.clients != null then .settings.clients |= map(select(.email != $e))
                    elif .settings.users != null then .settings.users |= map(select(.email != $e))
                    else . end
                )' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"

            log_info "Đã xóa user: $email khỏi hệ thống."
            apply_config
        fi
    fi
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

toggle_user_status() {
    echo -e "\n${YELLOW}--- TẮT/MỞ MẠNG USER ---${NC}"
    echo -n "Nhập Email/Tên User: "
    read email
    
    # 1. Kiểm tra user có tồn tại không
    if ! jq -e --arg e "$email" '.[] | select(.email == $e)' "$USER_DB" >/dev/null 2>&1; then
        echo -e "${RED}[LỖI] User '$email' không tồn tại!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
        return
    fi

    # 2. Lấy thông tin trạng thái và UUID của user
    local status=$(jq -r --arg e "$email" '.[] | select(.email == $e) | .status' "$USER_DB")
    local uuid=$(jq -r --arg e "$email" '.[] | select(.email == $e) | .uuid' "$USER_DB")

    if [ "$status" == "active" ]; then
        # HÀNH ĐỘNG: TẮT MẠNG (Xóa khỏi nodes.json)
        echo -e "${YELLOW}Đang tắt mạng cho user: $email...${NC}"
        
        # Cập nhật status trong users.json
        jq --arg e "$email" 'map(if .email == $e then .status = "disabled" else . end)' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
        
        # Xóa khỏi nodes.json (Tự động lọc tắt mạng theo mảng)
        jq --arg e "$email" '
            map(
                if .settings.clients != null then .settings.clients |= map(select(.email != $e))
                elif .settings.users != null then .settings.users |= map(select(.email != $e))
                else . end
            )' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
            
        log_info "Đã tắt mạng user: $email."

    else
        # HÀNH ĐỘNG: MỞ MẠNG (Thêm vào tất cả nodes.json)
        echo -e "${GREEN}Đang mở mạng cho user: $email...${NC}"
        
        # Cập nhật status trong users.json
        jq --arg e "$email" 'map(if .email == $e then .status = "active" else . end)' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
        
        # Thêm vào tất cả nodes.json (Tự động chọn mảng clients hoặc users)
        jq --arg e "$email" --arg u "$uuid" '\
            map(
                if .settings.clients != null then .settings.clients += [{"id": $u, "email": $e, "password": $u}]
                elif .settings.users != null then .settings.users += [{"password": $u, "email": $e}]
                else . end
            )' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
            
        log_info "Đã mở mạng user: $email."
    fi

    # 3. Áp dụng thay đổi
    apply_config
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

reset_user_token() {
    echo -e "\n${YELLOW}--- RESET TOKEN (UUID/PASSWORD) USER ---${NC}"
    echo -n "Nhập Email/Tên User cần reset token: "
    read email
    
    # Kiểm tra user có tồn tại không
    if ! jq -e --arg e "$email" '.[] | select(.email == $e)' "$USER_DB" >/dev/null 2>&1; then
        echo -e "${RED}[LỖI] User '$email' không tồn tại!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
        return
    fi

    local new_uuid=$(uuidgen)
    
    # Cập nhật UUID mới trong users.json
    jq --arg e "$email" --arg u "$new_uuid" '
        map(if .email == $e then .uuid = $u else . end)
    ' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
    
    # Cập nhật ID/Password/Auth mới trong nodes.json theo chuẩn Protocol
    jq --arg e "$email" --arg u "$new_uuid" '
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
        
    log_info "Đã reset token cho user: $email thành công."
    apply_config
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

while true; do
    show_user_menu
    read -r choice
    case $choice in
        1) list_users ;;
        2) add_user ;;
        3) delete_user ;;
        4) toggle_user_status ;;
        5) reset_user_token ;;
        0) break ;;
        *) log_error "Lựa chọn không hợp lệ!" ; sleep 1 ;;
    esac
done