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
    echo -e "3. Cập nhật thông tin Node"
    echo -e "0. Quay lại Menu chính"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn của bạn: "
}

# =================================================================
# 2. HÀM THÊM NODE: THÔNG MINH, TỰ ĐỘNG VÀ BẪY LỖI KHẮT KHE
# =================================================================
add_node() {
    # Khởi tạo phiên làm việc mới
    mkdir -p /tmp
    echo "[]" > /tmp/session_nodes.json
    
    # --- PHẦN 1: TẠO NODE ---
    while true; do
        clear
        echo -e "${GREEN}--- THÊM NODE MỚI ---${NC}"
        echo -e "1. vless | 2. vmess | 3. trojan | 4. hy2"
        read -p "Chọn giao thức (1-4): " proto_choice
        
        local protocol=""
        case $proto_choice in
            1) protocol="vless" ;; 2) protocol="vmess" ;; 3) protocol="trojan" ;; 4) protocol="hy2" ;;
            *) echo -e "${RED}[LỖI] Chọn lại!${NC}"; sleep 1; continue ;;
        esac

        # Chọn template
        local tpl_file=""
        if [ "$protocol" != "hy2" ]; then
            local template_path="${TEMPLATES_DIR}/${protocol}"
            local options=($(ls "$template_path"/*.json 2>/dev/null | xargs -n 1 basename | sed 's/\.json//'))
            [ ${#options[@]} -eq 0 ] && { echo -e "${RED}Lỗi template!${NC}"; sleep 1; continue; }
            
            PS3="Chọn transport: "
            select transport in "${options[@]}"; do
                if [ -n "$transport" ]; then
                    tpl_file="${template_path}/${transport}.json"
                    break
                fi
            done
        else
            tpl_file="${TEMPLATES_DIR}/hy2.json"
        fi

        # Cấu hình node
        read -p "Domain (để trống lấy IP): " input_domain
        local domain_or_ip="${input_domain:-$(curl -s https://api.ipify.org || echo "127.0.0.1")}"
        
        read -p "Port (để trống random): " input_port
        local port="${input_port:-$((RANDOM % 55000 + 10000))}"
        
        # Tạo node tạm
        local tag="${protocol}-${port}"
        jq --arg p "$port" --arg t "$tag" --arg dom "$domain_or_ip" '
            .port = ($p|tonumber) | .tag = $t | .domain = $dom
        ' "$tpl_file" > /tmp/single_node.json
        
        jq --slurpfile n /tmp/single_node.json '. += $n' /tmp/session_nodes.json > /tmp/session_nodes.tmp && mv /tmp/session_nodes.tmp /tmp/session_nodes.json
        
        read -p "Thêm tiếp node nữa? (y/n): " confirm
        [[ "$confirm" != "y" ]] && break
    done

    # --- PHẦN 2: GÁN USER ---
    USER_DB="${INSTALL_DIR}/data/users.json"
    local users_json=$(cat "$USER_DB")
    
    echo -e "${YELLOW}Nhập Tên User (hoặc để trống để gán tất cả):${NC}"
    read -p "> " username

    # Lọc filter jq
    local jq_filter=''
    if [ -z "$username" ]; then
        jq_filter='$session[0] | map(
            if .protocol == "vless" or .protocol == "vmess" then .settings.clients = ($us | map({id: .uuid, email: .email}))
            elif .protocol == "trojan" then .settings.clients = ($us | map({password: .uuid, email: .email}))
            elif .protocol == "hy2" or .protocol == "hysteria2" then .settings.users = ($us | map({password: .uuid, email: .email}))
            else . end
        )'
    else
        local user_uuid=$(echo "$users_json" | jq -r --arg e "$username" '.[] | select(.email == $e) | .uuid')
        [ -z "$user_uuid" ] && { echo -e "${RED}User không tồn tại!${NC}"; return; }
        jq_filter='$session[0] | map(
            if .protocol == "vless" or .protocol == "vmess" then .settings.clients += [{"id": "'$user_uuid'", "email": "'$username'"}]
            elif .protocol == "trojan" then .settings.clients += [{"password": "'$user_uuid'", "email": "'$username'"}]
            elif .protocol == "hy2" or .protocol == "hysteria2" then .settings.users += [{"password": "'$user_uuid'", "email": "'$username'"}]
            else . end
        )'
    fi

    # Thực thi lưu file
    if jq --slurpfile session /tmp/session_nodes.json --argjson us "$users_json" "$jq_filter" /tmp/session_nodes.json > /tmp/session_nodes_final.json 2> /tmp/jq_error.log; then
        if mv /tmp/session_nodes_final.json "$NODE_DB"; then
            echo -e "${GREEN}[THÀNH CÔNG] Đã cập nhật xong!${NC}"
            apply_config
        else
            echo -e "${RED}[LỖI] Không thể lưu file!${NC}"
        fi
    else
        echo -e "${RED}[LỖI] Xử lý JSON thất bại:${NC}"
        cat /tmp/jq_error.log
    fi
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
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