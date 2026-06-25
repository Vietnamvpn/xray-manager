#!/bin/bash
# Module quản lý Node - Bản Tự Động Hóa Thông Minh & Bẫy Lỗi Khắt Khe

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/etc/xray-manager"

if [ -f "${BASE_DIR}/config.conf" ]; then
    source "${BASE_DIR}/config.conf"
fi

if [ -d "${BASE_DIR}/layouts" ]; then
    TEMPLATES_DIR="${BASE_DIR}/layouts"
else
    TEMPLATES_DIR="${BASE_DIR}/templates"
fi

NODE_DB="${NODE_DB:-$INSTALL_DIR/data/nodes.json}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$INSTALL_DIR/scripts}"

if [ ! -f "$NODE_DB" ] || [ ! -s "$NODE_DB" ] || ! jq . "$NODE_DB" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$NODE_DB")"
    echo "[]" > "$NODE_DB"
fi

# =================================================================
# 1. HÀM APPLY CONFIG: HIỂN THỊ TRẠNG THÁI XRAY RÕ RÀNG
# =================================================================
apply_config() {
    local active_config="${XRAY_CONFIG_DIR}/config.json"
    local base_tpl="${TEMPLATES_DIR}/base.json"
    
    if [ ! -f "$base_tpl" ]; then
        echo -e "${RED}[LỖI] Không tìm thấy file mẫu gốc tại: $base_tpl${NC}"
        return 1
    fi

    if ! jq --slurpfile nodes "$NODE_DB" '.inbounds += $nodes[0]' "$base_tpl" > "${active_config}.tmp" 2>/dev/null; then
        echo -e "${RED}[LỖI] Lỗi cú pháp JSON khi trộn dữ liệu vào cấu hình chính.${NC}"
        rm -f "${active_config}.tmp"
        return 1
    fi

    mv "${active_config}.tmp" "$active_config"
    echo -e "${YELLOW}Đang khởi động lại dịch vụ Xray Core...${NC}"
    systemctl restart xray 2>/dev/null
    
    # KIỂM TRA TRẠNG THÁI SỐNG/CHẾT THỰC TẾ CỦA TIẾN TRÌNH
    sleep 1
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}[THÀNH CÔNG] XRAY ĐANG CHẠY BÌNH THƯỜNG!${NC}"
        echo -e "${GREEN}==============================================${NC}"
        return 0
    else
        echo -e "${RED}==============================================${NC}"
        echo -e "${RED}[THẤT BẠI] XRAY ĐÃ BỊ CRASH HOẶC TỪ CHỐI CHẠY!${NC}"
        echo -e "${YELLOW}Nguyên nhân có thể do file mẫu sai cú pháp hoặc trùng Port hệ thống.${NC}"
        echo -e "${YELLOW}Dùng lệnh sau để xem lỗi chi tiết: ${NC}journalctl -u xray --no-pager -n 20"
        echo -e "${RED}==============================================${NC}"
        return 1
    fi
}

show_node_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}             NODE MANAGER              ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Thêm Node (Hỗ trợ theo lô - Batching)"
    echo -e "2. Xóa Node khỏi hệ thống"
    echo -e "0. Quay lại Menu chính"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn của bạn: "
}

# =================================================================
# 2. HÀM THÊM NODE: THÔNG MINH, TỰ ĐỘNG VÀ BẪY LỖI KHẮT KHE
# =================================================================
add_node() {
    mkdir -p /tmp
    echo "[]" > /tmp/session_nodes.json
    
    while true; do
        clear
        echo -e "${GREEN}--- THÊM NODE MẠNG MỚI ---${NC}"
        echo -e "1. vless   2. vmess   3. trojan   4. hy2"
        read -p "Chọn giao thức (1-4): " proto_choice
        
        local protocol=""
        case $proto_choice in
            1) protocol="vless" ;; 2) protocol="vmess" ;; 3) protocol="trojan" ;; 4) protocol="hy2" ;;
            *) echo -e "${RED}[LỖI] Lựa chọn không hợp lệ!${NC}"; sleep 1; continue ;;
        esac

        local tpl_file=""
        if [ "$protocol" != "hy2" ]; then
            echo -e "\nChọn Transport: 1. ws   2. tcp   3. grpc   4. xhttp"
            read -p "Nhập số (1-4): " trans_choice
            local transport=""
            case $trans_choice in
                1) transport="ws" ;; 2) transport="tcp" ;; 3) transport="grpc" ;; 4) transport="xhttp" ;;
                *) echo -e "${RED}[LỖI] Lựa chọn không hợp lệ!${NC}"; sleep 1; continue ;;
            esac
            tpl_file="${TEMPLATES_DIR}/${protocol}/${transport}.json"
        else
            tpl_file="${TEMPLATES_DIR}/hy2.json"
        fi

        if [ ! -f "$tpl_file" ]; then
            echo -e "${RED}[LỖI] Không tồn tại file mẫu: $tpl_file${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để làm lại..."
            continue
        fi

        echo -e "\n${YELLOW}--- THÔNG SỐ NODE ---${NC}"
        
        # 2.1 - TỰ ĐỘNG ĐIỀN DOMAIN/IP
        read -p "Nhập Domain (Bỏ trống mặc định lấy IP VPS): " input_domain
        local domain_or_ip=""
        if [ -z "$input_domain" ]; then
            domain_or_ip=$(curl -s --max-time 3 https://api.ipify.org || echo "127.0.0.1")
            echo -e "${BLUE}-> Đã tự điền IP: $domain_or_ip${NC}"
        else
            domain_or_ip="$input_domain"
        fi

        # 2.2 - TỰ ĐỘNG ĐIỀN & QUÉT TRÙNG PORT
        read -p "Nhập Port (Bỏ trống hệ thống tự random & check trùng): " input_port
        local port=0
        if [ -z "$input_port" ]; then
            while true; do
                port=$((RANDOM % 55000 + 10000))
                local dup_db=$(jq -e --argjson p "$port" '.[] | select(.port == $p)' "$NODE_DB" >/dev/null 2>&1 && echo "yes" || echo "no")
                local dup_tmp=$(jq -e --argjson p "$port" '.[] | select(.port == $p)' /tmp/session_nodes.json >/dev/null 2>&1 && echo "yes" || echo "no")
                if [ "$dup_db" == "no" ] && [ "$dup_tmp" == "no" ]; then break; fi
            done
            echo -e "${BLUE}-> Đã tự điền Port: $port${NC}"
        else
            port="$input_port"
            local dup_db=$(jq -e --argjson p "$port" '.[] | select(.port == $p)' "$NODE_DB" >/dev/null 2>&1 && echo "yes" || echo "no")
            if [ "$dup_db" == "yes" ]; then
                echo -e "${RED}[LỖI NGHIÊM TRỌNG] Port $port đã có Node khác sử dụng trong hệ thống! Vui lòng chọn Port khác.${NC}"
                sleep 2; continue
            fi
        fi

        # 2.3 - TỰ ĐỘNG ĐIỀN SNI DÀNH CHO TLS/REALITY
        read -p "Nhập SNI (Bỏ trống hệ thống lấy ngẫu nhiên tên miền sạch): " input_sni
        local sni=""
        if [ -z "$input_sni" ]; then
            local sni_list=("www.cloudflare.com" "images.apple.com" "www.microsoft.com" "www.google.com" "www.amazon.com")
            sni=${sni_list[$RANDOM % ${#sni_list[@]}]}
            echo -e "${BLUE}-> Đã tự điền SNI: $sni${NC}"
        else
            sni="$input_sni"
        fi

        # 2.4 - TỰ ĐỘNG PHÁT HIỆN VÀ TẠO CẶP KHÓA X25519 CHO REALITY
        local private_key=""
        local public_key=""
        if jq -e '.streamSettings.realitySettings' "$tpl_file" >/dev/null 2>&1; then
            echo -e "${YELLOW}Phát hiện cấu hình Reality. Đang tự động tạo cặp khóa x25519...${NC}"
            local xray_bin="/usr/local/bin/xray"
            
            if [ -f "$xray_bin" ]; then
                local keys=$($xray_bin x25519 2>/dev/null)
                # Cập nhật logic lọc theo format thực tế:
                # PrivateKey: <key>
                # Password (PublicKey): <key>
                private_key=$(echo "$keys" | grep "PrivateKey:" | awk '{print $2}')
                public_key=$(echo "$keys" | grep "PublicKey" | awk '{print $NF}')
            fi

            if [ -z "$private_key" ] || [ -z "$public_key" ]; then
                echo -e "${RED}[CẢNH BÁO] Không thể trích xuất khóa x25519. Lõi Xray không trả về định dạng mong đợi.${NC}"
            else
                echo -e "${GREEN}-> Đã trích xuất thành công Private Key và Public Key.${NC}"
            fi
        fi

        local tag="${protocol}-${port}"

        # Đóng gói Node kèm xử lý logic Khóa nâng cao
        if ! jq --arg p "$port" --arg t "$tag" --arg sni "$sni" --arg dom "$domain_or_ip" --arg priv "$private_key" --arg pub "$public_key" '
            .port = ($p|tonumber) | 
            .tag = $t | 
            .domain = $dom |
            (if $pub != "" then .publicKey = $pub else . end) |
            (if .streamSettings.tlsSettings then .streamSettings.tlsSettings.serverName = $sni else . end) | 
            (if .streamSettings.realitySettings then 
                .streamSettings.realitySettings.serverName = $sni |
                .streamSettings.realitySettings.serverNames = [$sni] |
                (if $priv != "" then .streamSettings.realitySettings.privateKey = $priv else . end)
             else . end)
        ' "$tpl_file" > /tmp/single_node.json 2>/dev/null; then
            echo -e "${RED}[LỖI CÚ PHÁP] Không thể biên dịch JSON. Template bị lỗi!${NC}"
            sleep 3
            continue
        fi

        jq --slurpfile n /tmp/single_node.json '. += $n' /tmp/session_nodes.json > /tmp/session_nodes.tmp && mv /tmp/session_nodes.tmp /tmp/session_nodes.json

        echo -e "${GREEN}[OK] Đã cấu hình xong Node: $tag${NC}"
        echo ""
        read -p "Bạn có muốn thêm tiếp 1 Node nữa không? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then break; fi
    done

    # =================================================================
    # BƯỚC 3: GÁN USER & KIỂM TRA TRÙNG LẶP USER
    # =================================================================
    local count=$(jq '. | length' /tmp/session_nodes.json 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        return
    fi

    clear
    echo -e "${GREEN}--- THIẾT LẬP USER CHO $count NODE VỪA TẠO ---${NC}"
    local username=""
    
    while true; do
        read -p "Nhập Tên User (Bắt buộc nhập): " username
        if [ -z "$username" ]; then
            echo -e "${RED}[LỖI] Tên User không được để trống!${NC}"
            continue
        fi
        
        local is_duplicate=$(jq --arg u "$username" '
            [ .[] | (.settings.clients // []) + (.settings.users // []) | .[]? | select(.email == $u) ] | length > 0
        ' "$NODE_DB")
        
        if [ "$is_duplicate" == "true" ]; then
            echo -e "${RED}[LỖI NGHIÊM TRỌNG] User '$username' đã tồn tại trong hệ thống! Vui lòng chọn tên khác.${NC}"
        else
            break
        fi
    done
    
    # HỆ THỐNG TỰ ĐỘNG TẠO MẬT KHẨU (UUID)
    local user_cred=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
    echo -e "${BLUE}-> Hệ thống đã tự động tạo Mật Khẩu (UUID): $user_cred${NC}"

    # Bơm User vào tất cả các Node trong phiên
    jq --arg cred "$user_cred" --arg email "$username" '
      map(
        if .protocol == "vless" or .protocol == "vmess" then .settings.clients = [{"id": $cred, "email": $email}]
        elif .protocol == "trojan" then .settings.clients = [{"password": $cred, "email": $email}]
        elif .protocol == "hysteria2" or .protocol == "hysteria" or .protocol == "hy2" then .settings.users = [{"password": $cred, "email": $email}]
        else . end
      )
    ' /tmp/session_nodes.json > /tmp/session_nodes_final.json 2>/dev/null

    if ! jq --slurpfile new_nodes /tmp/session_nodes_final.json '. += $new_nodes[0]' "$NODE_DB" > "${NODE_DB}.tmp" 2>/dev/null; then
        echo -e "${RED}[LỖI] Không thể lưu vào Database.${NC}"
        rm -f "${NODE_DB}.tmp" /tmp/session_nodes* /tmp/single_node*
        return
    else
        mv "${NODE_DB}.tmp" "$NODE_DB"
        
        # =================================================================
        # THÊM ĐOẠN NÀY ĐỂ ĐỒNG BỘ SANG DATA USER
        # =================================================================
        USER_DB="${INSTALL_DIR}/data/users.json"
        
        # Tạo file users.json nếu chưa tồn tại
        if [ ! -f "$USER_DB" ] || [ ! -s "$USER_DB" ]; then
            echo "[]" > "$USER_DB"
        fi
        
        # Kiểm tra xem user đã có trong users.json chưa, nếu chưa thì thêm vào
        local user_exists=$(jq -e --arg e "$username" '.[] | select(.email == $e)' "$USER_DB" >/dev/null 2>&1 && echo "yes" || echo "no")
        
        if [ "$user_exists" == "no" ]; then
            jq --arg email "$username" --arg uuid "$user_cred" --arg quota "0" \
               '. += [{"email": $email, "uuid": $uuid, "quota_gb": $quota, "status": "active"}]' \
               "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
            echo -e "${BLUE}-> Đã đồng bộ User '$username' sang Cơ sở dữ liệu User.${NC}"
        fi
        # =================================================================
    fi
    
    rm -f /tmp/session_nodes.json /tmp/single_node.json /tmp/session_nodes_final.json
    
    # GỌI HÀM KHỞI ĐỘNG XRAY
    apply_config
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại menu..."
}

delete_node() {
    clear
    echo -e "${RED}--- GỠ BỎ CẤU HÌNH NODE ---${NC}"
    read -p "Nhập chính xác TAG của Node muốn xóa: " tag
    if [ -z "$tag" ]; then return; fi
    
    jq --arg t "$tag" 'del(.[] | select(.tag == $t))' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    echo -e "${GREEN}Đã gỡ bỏ cấu hình Node khỏi Database.${NC}"
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

while true; do
    show_node_menu
    read -r choice
    case $choice in
        1) add_node ;;
        2) delete_node ;;
        0) break ;;
        *) echo -e "${RED}Lựa chọn không hợp lệ!${NC}" ; sleep 1 ;;
    esac
done