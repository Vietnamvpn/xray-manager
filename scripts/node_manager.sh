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
    echo -e "1. Thêm Node Sever"
    echo -e "2. Xóa Node Khỏi Hệ Thống"
    echo -e "3. Cập Nhật Thông Tin Node"
    echo -e "0. Quay Lại Menu Chính"
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
        echo -e "${GREEN}==== THÊM NODE MỚI BẠN MUỐN ====${NC}"
        echo -e ""
        echo -e "1. Thêm vless  ${GREEN}|${NC} 2. Thêm vmess"
        echo -e "3. Thêm trojan ${GREEN}|${NC} 4. Thêm hy2"
        echo -e "0. ${RED}Hủy bỏ${NC}"
        echo -e "${GREEN}--------------------------------${NC}"   
        read -p "Chọn giao thức (1-4): " proto_choice
        
        local protocol=""
        case $proto_choice in
            1) protocol="vless" ;; 2) protocol="vmess" ;; 3) protocol="trojan" ;; 4) protocol="hy2" ;; 0) return 0 ;;
            *) echo -e "${RED}[LỖI] Lựa chọn không hợp lệ!${NC}"; sleep 1; continue ;;
        esac

        local tpl_file=""
        if [ "$protocol" != "hy2" ]; then
            local template_path="${TEMPLATES_DIR}/${protocol}"
            
            # Kiểm tra thư mục có tồn tại không
            if [ ! -d "$template_path" ]; then
                echo -e "${RED}[LỖI] Không tìm thấy thư mục cấu hình: $template_path${NC}"
                sleep 2; continue
            fi

            echo -e "\n${GREEN}Các Transport Khả Dụng Cho $protocol :${NC}"
            
            # Tự động quét file .json trong thư mục tương ứng
            # Ví dụ: templates/vless/ws.json -> ['ws']
            local options=($(ls "$template_path"/*.json 2>/dev/null | xargs -n 1 basename | sed 's/\.json//'))
            
            if [ ${#options[@]} -eq 0 ]; then
                echo -e "${RED}[LỖI] Thư mục $template_path không có file .json nào!${NC}"
                sleep 2; continue
            fi

            # Hiển thị menu số tự động (1, 2, 3...)
            PS3="Nhập số tương ứng để chọn Transport: "
            select transport in "${options[@]}"; do
                if [ -n "$transport" ]; then
                    tpl_file="${template_path}/${transport}.json"
                    echo -e "${BLUE}-> Đã chọn: $transport${NC}"
                    break
                else
                    echo -e "${RED}[LỖI] Lựa chọn không hợp lệ, vui lòng chọn lại.${NC}"
                fi
            done
        else
            tpl_file="${TEMPLATES_DIR}/hy2.json"
        fi

        if [ ! -f "$tpl_file" ]; then
            echo -e "${RED}[LỖI] Không tồn tại file mẫu: $tpl_file${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để làm lại..."
            continue
        fi

        echo -e "\n${YELLOW}Nhập Thông Số Node:${NC}"
        
        # 2.1 - TỰ ĐỘNG ĐIỀN DOMAIN/IP
        read -p "Nhập domain để trống sẽ là ip vps: " input_domain
        local domain_or_ip=""
        if [ -z "$input_domain" ]; then
            domain_or_ip=$(curl -s --max-time 3 https://api.ipify.org || echo "127.0.0.1")
            echo -e "${BLUE}-> Đã tự điền ip: $domain_or_ip${NC}"
        else
            domain_or_ip="$input_domain"
        fi

        # 2.2 - TỰ ĐỘNG ĐIỀN & QUÉT TRÙNG PORT
        read -p "Nhập Port, để trống hệ thống tự random: " input_port
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
        read -p "Nhập sni để trống hệ thống lấy ngẫu nhiên: " input_sni
        local sni=""
        if [ -z "$input_sni" ]; then
            local sni_list=("www.cloudflare.com" "images.apple.com" "www.microsoft.com" "s0.awsstatic.com" "www.amazon.com")
            sni=${sni_list[$RANDOM % ${#sni_list[@]}]}
            echo -e "${BLUE}-> Đã tự điền sni: $sni${NC}"
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


    # 1. Tự động tạo mật khẩu OBFS và đường dẫn chứng chỉ
    local obfs_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    local cert_file="${XRAY_CONFIG_DIR}/certs/server.crt"
    local key_file="${XRAY_CONFIG_DIR}/certs/server.key"

    # 2. Đóng gói Node (Tích hợp động theo từng giao thức: TLS, WS, Reality, Hysteria)
    if ! jq --arg p "$port" --arg t "$tag" --arg sni "$sni" \
             --arg priv "$private_key" --arg pub "$public_key" \
             --arg obfs "$obfs_pass" \
             --arg cert "$cert_file" --arg key "$key_file" '
            .port = ($p|tonumber) | 
            .tag = $t | 
            (if $pub != "" then .publicKey = $pub else . end) |
            
            (if (.streamSettings.security == "tls") or (.streamSettings.tlsSettings != null) then 
                .streamSettings.tlsSettings.serverName = $sni |
                .streamSettings.tlsSettings.certificates = [{
                    "certificateFile": $cert,
                    "keyFile": $key
                }]
             else . end) | 
             
            (if .streamSettings.wsSettings != null then 
                .streamSettings.wsSettings.headers.Host = $sni
             else . end) |
             
            (if .streamSettings.realitySettings then 
                .streamSettings.realitySettings.dest = ($sni + ":443") |
                .streamSettings.realitySettings.serverName = $sni |
                .streamSettings.realitySettings.serverNames = [$sni] | 
                (if $priv != "" then .streamSettings.realitySettings.privateKey = $priv else . end)
             else . end) |
             
            (if (.protocol == "hysteria2" or .protocol == "hy2" or .protocol == "hysteria") and .streamSettings.finalmask then
                .streamSettings.finalmask.udp[0].settings.password = $obfs
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
    # BƯỚC 3: GÁN USER (TỰ ĐỘNG LẤY HẾT HOẶC CHỌN USER CỤ THỂ)
    # =================================================================
    USER_DB="${INSTALL_DIR}/data/users.json"
    [ ! -f "$USER_DB" ] && echo "[]" > "$USER_DB"
    
    # Kiểm tra xem có node nào trong phiên tạo không
    local count=$(jq '. | length' /tmp/session_nodes.json 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then return; fi

    clear
    echo -e "${GREEN}==== THIẾT LẬP USER CHO $count NODE ====${NC}"
    echo -e "${YELLOW}Lưu ý: Để trống để gán TẤT CẢ user hiện có vào Node.${NC}"
    read -p "Nhập Tên User: " username

    local users_json=$(cat "$USER_DB")
    local user_count=$(echo "$users_json" | jq '. | length')

    # TRƯỜNG HỢP 1: ĐỂ TRỐNG -> GÁN TẤT CẢ USER
    if [ -z "$username" ]; then
        if [ "$user_count" -eq 0 ]; then
            echo -e "${RED}[LỖI] Hệ thống chưa có User nào! Vui lòng nhập tên để tạo mới.${NC}"
            read -n 1 -s -r -p "Bấm phím để nhập tên..."
            add_node 
            return
        fi
        
        echo -e "${BLUE}-> Đang gán TẤT CẢ $user_count user vào các node...${NC}"
        
    # Tự động nhận diện cấu trúc mảng trong template để map dữ liệu chuẩn
jq --argjson us "$users_json" '
    map(
        if .settings.users != null then
            .settings.users = ($us | map({password: .uuid, email: .email}))
        elif .settings.clients != null then
            if .protocol == "vless" or .protocol == "vmess" then
                .settings.clients = ($us | map({id: .uuid, email: .email}))
            elif .protocol == "hysteria" or .protocol == "hy2" or .protocol == "hysteria2" then
                .settings.clients = ($us | map({auth: .uuid, email: .email}))
            else
                .settings.clients = ($us | map({password: .uuid, email: .email}))
            end
        elif .users != null then
            .users = ($us | map({password: .uuid, email: .email}))
        else . end
    )
' /tmp/session_nodes.json > /tmp/session_nodes_final.json

    # TRƯỜNG HỢP 2: NHẬP TÊN -> GÁN CỤ THỂ
    else
        local user_data=$(echo "$users_json" | jq -c --arg e "$username" '.[] | select(.email == $e)')
        local user_cred=""

        if [ -z "$user_data" ]; then
            echo -e "${YELLOW}-> User '\''$username'\'' chưa tồn tại. Đang tạo mới...${NC}"
            user_cred=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
            jq --arg email "$username" --arg uuid "$user_cred" '. += [{"email": $email, "uuid": $uuid, "quota_gb": "0", "status": "active"}]' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
        else
            user_cred=$(echo "$user_data" | jq -r '.uuid')
            echo -e "${BLUE}-> Đang sử dụng User '\''$username'\''.${NC}"
        fi

        # Tự động nhận diện cấu trúc mảng trong template để gán 1 user cụ thể
        jq --arg cred "$user_cred" --arg email "$username" '
            map(
                if .settings.users != null then
                    .settings.users = [{"password": $cred, "email": $email}]
                elif .settings.clients != null then
                    if .protocol == "vless" or .protocol == "vmess" then
                        .settings.clients = [{"id": $cred, "email": $email}]
                    elif .protocol == "hysteria" or .protocol == "hy2" or .protocol == "hysteria2" then
                        .settings.clients = [{"auth": $cred, "email": $email}]
                    else
                        .settings.clients = [{"password": $cred, "email": $email}]
                    end
                elif .users != null then
                    .users = [{"password": $cred, "email": $email}]
                else . end
            )
        ' /tmp/session_nodes.json > /tmp/session_nodes_final.json
    fi

    # LƯU VÀO DATABASE CHÍNH
    if ! jq --slurpfile new_nodes /tmp/session_nodes_final.json '. += $new_nodes[0]' "$NODE_DB" > "${NODE_DB}.tmp" 2>/dev/null; then
        echo -e "${RED}[LỖI] Không thể lưu vào Database.${NC}"
        rm -f "${NODE_DB}.tmp" /tmp/session_nodes* /tmp/single_node*
        return
    else
        mv "${NODE_DB}.tmp" "$NODE_DB"
    fi
    
    rm -f /tmp/session_nodes.json /tmp/single_node.json /tmp/session_nodes_final.json
    
    # KÍCH HOẠT CẤU HÌNH
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại menu..."
}

update_node() {
    clear
    echo -e "${YELLOW}--- CẬP NHẬT NODE ---${NC}"
    read -p "Nhập Port của Node muốn cập nhật: " target_port

    # CẬP NHẬT TẠI ĐÂY: Dùng (.port|tostring) để so sánh bất chấp kiểu dữ liệu
    local node_exists=$(jq -e --arg p "$target_port" '.[] | select(.port|tostring == $p)' "$NODE_DB" >/dev/null 2>&1 && echo "yes" || echo "no")
    
    if [ "$node_exists" == "no" ]; then
        echo -e "${RED}[LỖI] Không tìm thấy Node nào có Port $target_port (Kiểm tra lại dữ liệu file nodes.json)${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi

    # Lấy thông tin hiện tại
    local current_node=$(jq -c --arg p "$target_port" '.[] | select(.port|tostring == $p)' "$NODE_DB")
    local old_domain=$(echo "$current_node" | jq -r '.domain')
    local old_sni=$(echo "$current_node" | jq -r '.streamSettings.tlsSettings.serverName // .streamSettings.realitySettings.serverName // "N/A"')

    echo -e "${BLUE}Đang cập nhật Node Port: $target_port${NC}"
    echo -e "(Để trống nếu không muốn đổi giá trị cũ)"

    read -p "Nhập Domain mới (Cũ: $old_domain): " new_domain
    read -p "Nhập Port mới (Cũ: $target_port): " new_port
    read -p "Nhập SNI mới (Cũ: $old_sni): " new_sni

    local final_domain="${new_domain:-$old_domain}"
    local final_port="${new_port:-$target_port}"
    local final_sni="${new_sni:-$old_sni}"

    # Kiểm tra trùng port (ép kiểu khi so sánh)
    if [ "$final_port" != "$target_port" ]; then
        local dup_db=$(jq -e --arg p "$final_port" '.[] | select(.port|tostring == $p)' "$NODE_DB" >/dev/null 2>&1 && echo "yes" || echo "no")
        if [ "$dup_db" == "yes" ]; then
            echo -e "${RED}[LỖI] Port $final_port đã có Node khác sử dụng!${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
            return
        fi
    fi

    # Thực hiện Update (Đảm bảo giá trị Port mới được gán đúng là số)
    if jq --arg p "$target_port" \
          --arg np "$final_port" \
          --arg d "$final_domain" \
          --arg s "$final_sni" '
        map(if .port|tostring == $p then
            .domain = $d |
            .port = ($np|tonumber) |
            .tag = (.protocol + "-" + $np) |
            (if .streamSettings.tlsSettings then .streamSettings.tlsSettings.serverName = $s else . end) |
            (if .streamSettings.realitySettings then 
                .streamSettings.realitySettings.dest = ($s + ":443") |
                .streamSettings.realitySettings.serverName = $s |
                .streamSettings.realitySettings.serverNames = [$s] 
             else . end)
        else . end)
    ' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"; then
        echo -e "${GREEN}[THÀNH CÔNG] Đã cập nhật Node $target_port -> $final_port${NC}"
    else
        echo -e "${RED}[LỖI] Cập nhật file JSON thất bại.${NC}"
        rm -f "${NODE_DB}.tmp"
        return
    fi

    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

delete_node() {
    clear
    echo -e "${RED}--- GỠ BỎ CẤU HÌNH NODE ---${NC}"
    echo -e "${YELLOW}Lưu ý: Nếu để trống và nhấn Enter, TOÀN BỘ danh sách Node sẽ bị xóa!${NC}"
    read -p "Nhập Port của Node muốn xóa (Để trống để xóa TẤT CẢ): " target_port
    
    # TRƯỜNG HỢP 1: Để trống -> Xóa tất cả
    if [ -z "$target_port" ]; then
        read -p "Bạn có THỰC SỰ muốn xóa TẤT CẢ Node không? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            echo "[]" > "$NODE_DB"
            echo -e "${GREEN}Đã xóa TẤT CẢ các Node.${NC}"
        else
            echo -e "${YELLOW}Đã hủy lệnh xóa.${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
            return
        fi
    
    # TRƯỜNG HỢP 2: Có nhập Port -> Xóa Node cụ thể
    else
        # Sử dụng --argjson để jq hiểu $target_port là số (number)
        jq --argjson p "$target_port" 'del(.[] | select(.port == $p))' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
        echo -e "${GREEN}Đã gỡ bỏ cấu hình Node có Port $target_port khỏi Database.${NC}"
    fi
    
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

while true; do
    show_node_menu
    read -r choice
    case $choice in
        1) add_node ;;
        2) delete_node ;;
        3) update_node ;;
        0) break ;;
        *) echo -e "${RED}Lựa chọn không hợp lệ!${NC}" ; sleep 1 ;;
    esac
done