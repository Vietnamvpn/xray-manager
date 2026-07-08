#!/bin/bash
# Module quản lý Node - Bản Tự Động Hóa Thông Minh & Bẫy Lỗi Khắt Khe

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/etc/xray-manager"

# 1. ĐỊNH NGHĨA ĐƯỜNG DẪN TRƯỚC ĐỂ TRÁNH LỖI BIẾN TRỐNG KHI NẠP UTILS
NODE_DB="${NODE_DB:-$INSTALL_DIR/data/nodes.json}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$INSTALL_DIR/scripts}"

if [ -f "${BASE_DIR}/config.conf" ]; then
    source "${BASE_DIR}/config.conf"
fi

if [ -d "${BASE_DIR}/layouts" ]; then
    TEMPLATES_DIR="${BASE_DIR}/layouts"
else
    TEMPLATES_DIR="${BASE_DIR}/templates"
fi

# 2. NẠP THƯ VIỆN UTILS.SH (Đã có đầy đủ biến SCRIPTS_DIR để tìm file)
if [ -f "${SCRIPTS_DIR}/utils.sh" ]; then
    source "${SCRIPTS_DIR}/utils.sh"
elif [ -f "${BASE_DIR}/scripts/utils.sh" ]; then
    source "${BASE_DIR}/scripts/utils.sh"
else
    echo -e "${RED}[LỖI] Không thể tìm thấy thư viện dùng chung utils.sh!${NC}"
    exit 1
fi

if [ ! -f "$NODE_DB" ] || [ ! -s "$NODE_DB" ] || ! jq . "$NODE_DB" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$NODE_DB")"
    echo "[]" > "$NODE_DB"
fi


show_node_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}||${NC}           ${YELLOW}NODE MANAGER${NC}            ${BLUE}||${NC}"
    echo -e "${BLUE}             -------------             ${NC}"
    echo -e "${YELLOW}1.${NC} ${CYAN}Thêm Node Sever${NC}"
    echo -e "${YELLOW}2.${NC} ${CYAN}Xóa Node Khỏi Hệ Thống${NC}"
    echo -e "${YELLOW}3.${NC} ${CYAN}Cập Nhật Thông Tin Node${NC}"
    echo -e "0. ${RED}Quay Lại${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn của bạn: "
}

# =================================================================
# 2. HÀM THÊM NODE: THÔNG MINH, TỰ ĐỘNG VÀ BẪY LỖI KHẮT KHE
# =================================================================
add_node() {
    mkdir -p /tmp
    local sess_file="/tmp/session_nodes_${$}.json"
    local single_file="/tmp/single_node_${$}.json"
    local final_file="/tmp/session_nodes_final_${$}.json"
    echo "[]" > "$sess_file"
    
    while true; do
        clear
        echo -e "${GREEN}==== THÊM NODE MỚI BẠN MUỐN ====${NC}"
        echo -e ""
        echo -e "${YELLOW}1.${NC} Thêm vless"
        echo -e "${YELLOW}2.${NC} Thêm vmess"
        echo -e "${YELLOW}3.${NC} Thêm trojan"
        echo -e "${YELLOW}4.${NC} Thêm hysteria2"
        echo -e "0. ${RED}Hủy bỏ${NC}"
        echo -e "${GREEN}--------------------------------${NC}"   
        read -p "Chọn giao thức (1-4): " proto_choice
        
        local protocol=""
        case $proto_choice in
            1) protocol="vless" ;; 2) protocol="vmess" ;; 3) protocol="trojan" ;; 4) protocol="hysteria2" ;; 0) return 0 ;;
            *) echo -e "${RED}[LỖI] Lựa chọn không hợp lệ!${NC}"; sleep 1; continue ;;
        esac

        local tpl_file=""
        local transport=""
        # Chỉ quét và hiển thị menu cho vless
        if [ "$protocol" == "vless" ]; then
            local template_path="${TEMPLATES_DIR}/${protocol}"
            
            # Kiểm tra thư mục có tồn tại không
            if [ ! -d "$template_path" ]; then
                echo -e "${RED}[LỖI] Không tìm thấy thư mục cấu hình: $template_path${NC}"
                sleep 2; continue
            fi

            echo -e "\n${GREEN}Các Transport Khả Dụng Cho $protocol :${NC}"
            
            # Tự động quét file .json trong thư mục tương ứng
            local options=($(ls "$template_path"/*.json 2>/dev/null | xargs -n 1 basename | sed 's/\.json//'))
            
            if [ ${#options[@]} -eq 0 ]; then
                echo -e "${RED}[LỖI] Thư mục $template_path không có file .json nào!${NC}"
                sleep 2; continue
            fi

            # Hiển thị menu số tự động (1, 2, 3...)
            PS3=$(echo -e "${YELLOW}Nhập số tương ứng để chọn Transport: ${NC}")
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
            # Các giao thức khác bỏ qua menu, trỏ thẳng tới file cấu hình mặc định
            if [ "$protocol" == "hysteria2" ]; then
                tpl_file="${TEMPLATES_DIR}/hy2.json"
            elif [ "$protocol" == "vmess" ]; then
                tpl_file="${TEMPLATES_DIR}/vmess/vmess-ws-tls.json"
            elif [ "$protocol" == "trojan" ]; then
                tpl_file="${TEMPLATES_DIR}/trojan/trojan-ws-tls.json"
            fi
        fi

        if [ ! -f "$tpl_file" ]; then
            echo -e "${RED}[LỖI] Không tồn tại file mẫu: $tpl_file${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để làm lại..."
            continue
        fi

        echo -e "\n${YELLOW}Nhập Thông Số Node:${NC}"
        
        # 2.1 - TỰ ĐỘNG ĐIỀN DOMAIN/IP (Đã cập nhật tính năng chọn IPv4 hoặc IPv6)
        local domain_or_ip=""
        while true; do
            read -p "Nhập domain để trống sẽ là ip vps: " input_domain
            if [ -z "$input_domain" ]; then
                if [[ "$transport" == *"ws"* || "$tpl_file" == *"ws"* ]]; then
                    echo -e "${RED}[LỖI] Đối với Node WS, Domain là BẮT BUỘC và không được để trống!${NC}"
                    continue
                fi
                
                read -p "$(echo -e "${CYAN}Chọn loại IP VPS (1: IPv4, 2: IPv6) [Mặc định: 1]: ${NC}")" ip_choice
                if [ "$ip_choice" == "2" ]; then
                    domain_or_ip=$(curl -s -6 --max-time 3 https://api64.ipify.org || echo "::1")
                    echo -e "${BLUE}-> Đã tự điền IPv6: $domain_or_ip${NC}"
                else
                    domain_or_ip=$(curl -s -4 --max-time 3 https://api.ipify.org || echo "127.0.0.1")
                    echo -e "${BLUE}-> Đã tự điền IPv4: $domain_or_ip${NC}"
                fi
                break
            else
                domain_or_ip="$input_domain"
                break
            fi
        done

        # 2.2 - TỰ ĐỘNG ĐIỀN & QUÉT TRÙNG PORT
        read -p "Nhập Port, để trống hệ thống tự random: " input_port
        local port=0
        if [ -z "$input_port" ]; then
            while true; do
                port=$((RANDOM % 55000 + 10000))
                local dup_db=$(jq -e --argjson p "$port" '.[] | select(.port == $p)' "$NODE_DB" >/dev/null 2>&1 && echo "yes" || echo "no")
                local dup_tmp=$(jq -e --argjson p "$port" '.[] | select(.port == $p)' "$sess_file" >/dev/null 2>&1 && echo "yes" || echo "no")
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
        local sni=""
        while true; do
            read -p "Nhập sni để trống hệ thống lấy ngẫu nhiên: " input_sni
            if [ -z "$input_sni" ]; then
                local sni_list=("www.cloudflare.com" "images.apple.com" "www.microsoft.com" "s0.awsstatic.com" "www.amazon.com")
                sni=${sni_list[$RANDOM % ${#sni_list[@]}]}
                echo -e "${BLUE}-> Đã tự điền sni: $sni${NC}"
            else
                sni="$input_sni"
            fi

            # Kiểm tra riêng cho WS: domain/ip và sni phải giống hệt nhau
            if [[ "$transport" == *"ws"* || "$tpl_file" == *"ws"* ]]; then
                if [ "$domain_or_ip" != "$sni" ]; then
                    echo -e "${RED}[LỖI] Đối với node WS (WebSocket), Domain và SNI phải giống hệt nhau!${NC}"
                    echo -e "${YELLOW}Domain hiện tại bạn đã cung cấp là: $domain_or_ip${NC}"
                    continue
                fi
            fi
            break
        done

        # 2.4 - TỰ ĐỘNG PHÁT HIỆN VÀ TẠO CẶP KHÓA X25519 CHO REALITY
        local private_key=""
        local public_key=""
        if jq -e '.streamSettings.realitySettings' "$tpl_file" >/dev/null 2>&1; then
            echo -e "${YELLOW}Phát hiện cấu hình Reality. Đang tự động tạo cặp khóa x25519...${NC}"
            local xray_bin="/usr/local/bin/xray"
            
            if [ -f "$xray_bin" ]; then
                local keys=$($xray_bin x25519 2>/dev/null)
                private_key=$(echo "$keys" | grep "PrivateKey:" | awk '{print $2}')
                public_key=$(echo "$keys" | grep "PublicKey" | awk '{print $NF}')
            fi

            if [ -z "$private_key" ] || [ -z "$public_key" ]; then
                echo -e "${RED}[CẢNH BÁO] Không thể trích xuất khóa x25519. Lõi Xray không trả về định dạng mong đợi.${NC}"
            else
                echo -e "${GREEN}-> Đã trích xuất thành công Private Key và Public Key.${NC}"
            fi
        fi

        read -p "$(echo -e "${CYAN}Nhập tên Tag cho node (để trống sẽ là ${protocol}-${port}): ${NC}")" input_tag
        local tag="${input_tag:-${protocol}-${port}}"

        read -p "$(echo -e "${CYAN}Nhập tên file chứng chỉ (.crt) để trống mặc định là server.crt: ${NC}")" input_cert
        read -p "$(echo -e "${CYAN}Nhập tên file key (.key) để trống mặc định là server.key: ${NC}")" input_key

        # 1. Tự động tạo mật khẩu OBFS và đường dẫn chứng chỉ
        local obfs_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
        local cert_file="${XRAY_CONFIG_DIR}/certs/${input_cert:-server.crt}"
        local key_file="${XRAY_CONFIG_DIR}/certs/${input_key:-server.key}"

        # 2. Đóng gói Node
        if ! jq --arg p "$port" --arg t "$tag" --arg sni "$sni" \
                 --arg priv "$private_key" --arg pub "$public_key" \
                 --arg obfs "$obfs_pass" \
                 --arg cert "$cert_file" --arg key "$key_file" \
                 --arg domain "$domain_or_ip" '
                (if has("domain") then .domain = $domain else . end) |
                .port = ($p|tonumber) | 
                .tag = $t | 
                (if $pub != "" then .publicKey = $pub else . end) |
                
                (if (.streamSettings.security == "tls") or (.streamSettings.tlsSettings != null) then 
                    .streamSettings.tlsSettings.certificates = [{
                        "certificateFile": $cert,
                        "keyFile": $key
                    }] |
                    
                    (if .protocol == "vmess" then
                        del(.streamSettings.tlsSettings.serverName)
                    else
                        .streamSettings.tlsSettings.serverName = $sni
                    end)
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
            ' "$tpl_file" > "$single_file" 2>/dev/null; then
                echo -e "${RED}[LỖI CÚ PHÁP] Không thể biên dịch JSON. Template bị lỗi!${NC}"
                sleep 3
                continue
        fi
        jq --slurpfile n "$single_file" '. += $n' "$sess_file" > "${sess_file}.tmp" && mv "${sess_file}.tmp" "$sess_file"

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
    
    local count=$(jq '. | length' "$sess_file" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then return; fi

    clear
    echo -e "${BLUE}=================================== THIẾT LẬP USER CHO $count NODE ================================${NC}"
    echo -e "${BLUE}                                     ------------------------                                      ${NC}"
    echo -e "${YELLOW}Lưu ý: Nếu bạn muốn gán tất cả user hiện có vào các node mới, hãy để trống khi được hỏi tên user.${NC}"
    read -p "Nhập Tên User Bạn Muốn Thêm: " username

    local users_json=$(cat "$USER_DB")
    local user_count=$(echo "$users_json" | jq '. | length')

    if [ -z "$username" ]; then
        if [ "$user_count" -eq 0 ]; then
            echo -e "${YELLOW}-> Hệ thống chưa có User. Node sẽ được lưu với cấu hình mặc định (chưa gán user).${NC}"
            cp "$sess_file" "$final_file"
        else
            echo -e "${BLUE}-> Đang gán TẤT CẢ $user_count user vào các node...${NC}"
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
            ' "$sess_file" > "$final_file"
        fi
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
        ' "$sess_file" > "$final_file"
    fi

    (
        flock -x 200
        if ! jq --slurpfile new_nodes "$final_file" '. += $new_nodes[0]' "$NODE_DB" > "${NODE_DB}.tmp" 2>/dev/null; then
            exit 1
        else
            mv "${NODE_DB}.tmp" "$NODE_DB"
        fi
    ) 200>/var/lock/node_manager.lock

    if [ $? -ne 0 ]; then
        echo -e "${RED}[LỖI] Không thể lưu vào Database.${NC}"
        rm -f "${NODE_DB}.tmp" "$sess_file" "$single_file" "$final_file"
        return
    fi
    
    rm -f "$sess_file" "$single_file" "$final_file"
    
    apply_config
    
    if [ -z "$username" ] && [ "$user_count" -eq 0 ]; then
        echo -e "\n${YELLOW}[THÔNG BÁO] Node đã được tạo thành công, nhưng hệ thống vẫn chưa có User nào để kết nối!${NC}"
        read -p "Bạn có muốn chuyển sang Menu Quản Lý User để thêm mới không? (y/n - để trống sẽ quay lại menu Node): " ask_user_menu
        if [[ "$ask_user_menu" == "y" || "$ask_user_menu" == "Y" ]]; then
            if [ -f "${SCRIPTS_DIR}/user_manager.sh" ]; then
                bash "${SCRIPTS_DIR}/user_manager.sh"
            else
                bash "${BASE_DIR}/user_manager.sh"
            fi
        fi
        return
    fi

    read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại menu..."
}

update_node() {
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BLUE}||${NC}             ${YELLOW}CẬP NHẬT NODE${NC}                ${BLUE}||${NC}"
    echo -e "${BLUE}               --------------                 ${NC}"
    echo -e ""
    read -p "Nhập Port của Node muốn cập nhật: " target_port

    # Kiểm tra tồn tại
    local node_exists=$(jq -e --arg p "$target_port" '.[] | select(.port|tostring == $p)' "$NODE_DB" >/dev/null 2>&1 && echo "yes" || echo "no")
    
    if [ "$node_exists" == "no" ]; then
        echo -e "${RED}[LỖI] Không tìm thấy Node nào có Port $target_port (Kiểm tra lại dữ liệu file nodes.json)${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi

    # Lấy thông tin hiện tại
    local current_node=$(jq -c --arg p "$target_port" '.[] | select(.port|tostring == $p)' "$NODE_DB")
    local old_domain=$(echo "$current_node" | jq -r '.domain // .streamSettings.wsSettings.headers.Host // .streamSettings.tlsSettings.serverName // "N/A"')
    local old_sni=$(echo "$current_node" | jq -r '.streamSettings.tlsSettings.serverName // .streamSettings.realitySettings.serverName // "N/A"')
    local is_ws=$(echo "$current_node" | jq -e '.streamSettings.wsSettings != null' >/dev/null 2>&1 && echo "true" || echo "false")
    local old_tag=$(echo "$current_node" | jq -r '.tag')

    echo -e "${BLUE}Đang cập nhật Node Port:${NC}${YELLOW} $target_port${NC}"
    echo -e "Domain hiện tại: ${YELLOW}$old_domain${NC}"
    echo -e "SNI hiện tại: ${YELLOW}$old_sni${NC}"
    echo -e "Tag hiện tại: ${YELLOW}$old_tag${NC}"
    echo -e "(Để trống nếu không muốn đổi giá trị cũ)"

    read -p "Nhập Domain mới: " new_domain
    read -p "Nhập Port mới: " new_port
    read -p "Nhập SNI mới: " new_sni
    read -p "$(echo -e "${CYAN}Nhập Tag mới:${NC}")" new_tag

    local final_domain="${new_domain:-$old_domain}"
    local final_port="${new_port:-$target_port}"
    local final_sni="${new_sni:-$old_sni}"
    local final_tag="${new_tag:-$old_tag}"

    # Kiểm tra điều kiện bắt buộc đối với WS
    if [ "$is_ws" == "true" ] && [ "$final_domain" != "$final_sni" ]; then
        echo -e "${RED}[LỖI] Đây là node WS (WebSocket). Domain và SNI bắt buộc phải giống hệt nhau!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để làm lại..."
        return
    fi

    # Kiểm tra trùng port
    if [ "$final_port" != "$target_port" ]; then
        local dup_db=$(jq -e --arg p "$final_port" '.[] | select(.port|tostring == $p)' "$NODE_DB" >/dev/null 2>&1 && echo "yes" || echo "no")
        if [ "$dup_db" == "yes" ]; then
            echo -e "${RED}[LỖI] Port $final_port đã có Node khác sử dụng!${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
            return
        fi
    fi

    # Thực hiện Update (Chỉ update các trường cần thiết, KHÔNG thêm .domain nếu không tồn tại)
    if jq --arg p "$target_port" \
          --arg np "$final_port" \
          --arg s "$final_sni" \
          --arg d "$final_domain" \
          --arg t "$final_tag" '
        map(if .port|tostring == $p then
            (if has("domain") then .domain = $d else . end) |
            .port = ($np|tonumber) |
            .tag = $t |
            (if .streamSettings.tlsSettings then .streamSettings.tlsSettings.serverName = $s else . end) |
            (if .streamSettings.wsSettings then .streamSettings.wsSettings.headers.Host = $s else . end) |
            (if .streamSettings.realitySettings then 
                .streamSettings.realitySettings.dest = ($s + ":443") |
                .streamSettings.realitySettings.serverName = $s |
                .streamSettings.realitySettings.serverNames = [$s] 
             else . end)
        else . end)
    ' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"; then
        echo -e "${GREEN}Đã cập nhật Node $target_port -> $final_port${NC}"
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
    echo -e "${RED}======================== GỠ BỎ CẤU HÌNH NODE =========================${NC}"
    echo -e "${BLUE}                           --------------                            ${NC}"
    echo -e "${YELLOW}Lưu ý: Nếu để trống và nhấn Enter, TOÀN BỘ danh sách Node sẽ bị xóa!${NC}"
    echo -e "${YELLOW}(Nhập 0 và nhấn Enter nếu muốn hủy bỏ và quay lại)${NC}"
    read -p "Nhập Port của Node muốn xóa: " target_port
    
    # TRƯỜNG HỢP KHÔNG MUỐN XÓA: Nhập 0 để thoát
    if [ "$target_port" == "0" ]; then
        echo -e "${YELLOW}Đã hủy lệnh xóa. Đang quay lại...${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
        return
    fi
    
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
        # Kiểm tra Port nhập vào có tồn tại trong Database hay không
        local node_exists=$(jq -e --arg p "$target_port" '.[] | select(.port|tostring == $p)' "$NODE_DB" >/dev/null 2>&1 && echo "yes" || echo "no")
        
        if [ "$node_exists" == "no" ]; then
            echo -e "${RED}[LỖI] Không tìm thấy Node nào có Port $target_port trong hệ thống!${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
            return
        fi

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