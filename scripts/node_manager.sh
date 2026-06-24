#!/bin/bash
# Module quản lý Node (Inbounds) - Bản Vá Lỗi Treo Đơ & Khởi Tạo DB Tự Động
# Thiết kế cô lập chạy trực tiếp trên VPS Node Agent.

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/etc/xray-manager"

if [ -f "${BASE_DIR}/config.conf" ]; then
    source "${BASE_DIR}/config.conf"
fi

# Thiết lập đường dẫn fallback an toàn chống trống biến
NODE_DB="${NODE_DB:-$INSTALL_DIR/data/nodes.json}"
TEMPLATES_DIR="${TEMPLATES_DIR:-$INSTALL_DIR/templates}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$INSTALL_DIR/scripts}"

source "${SCRIPTS_DIR}/utils.sh"
check_root

# =================================================================
# LỚP BẢO VỆ ĐẶC BIỆT: TỰ KHỞI TẠO VÀ SỬA LỖI ĐỊNH DẠNG FILE DATABASE
# =================================================================
if [ ! -f "$NODE_DB" ] || [ ! -s "$NODE_DB" ] || ! jq . "$NODE_DB" < /dev/null >/dev/null 2>&1; then
    mkdir -p "$(dirname "$NODE_DB")"
    echo "[]" > "$NODE_DB"
fi

# =================================================================
# HÀM CỐT LÕI: BIÊN DỊCH VÀ RESTART LÕI MẠNG XRAY (FIX GIỮ LẠI API CŨ)
# =================================================================
apply_config() {
    local active_config="${XRAY_CONFIG_DIR}/config.json"
    
    if [ ! -f "${TEMPLATES_DIR}/base.json" ]; then
        echo -e "${RED}[LỖI] Không tìm thấy file mẫu base.json tại templates/.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Đang đồng bộ cấu hình hệ thống mạng...${NC}"
    
    # Sử dụng += để xếp chồng các Node mới ra sau Node API cổng 10085 sẵn có
    if ! jq --slurpfile nodes "$NODE_DB" '.inbounds += $nodes[0]' "${TEMPLATES_DIR}/base.json" < /dev/null > "${active_config}.tmp"; then
        echo -e "${RED}[LỖI] Cú pháp JSON lỗi. Vui lòng kiểm tra lại file templates.${NC}"
        rm -f "${active_config}.tmp"
        return 1
    fi

    mv "${active_config}.tmp" "$active_config"
    echo -e "${YELLOW}Đang khởi động lại dịch vụ mạng Xray...${NC}"
    if systemctl restart xray; then
        echo -e "${GREEN}[THÀNH CÔNG] Hệ thống mạng lõi hiện đã trực tuyến và hoạt động ổn định!${NC}"
        return 0
    else
        echo -e "${RED}[LỖI] Xray không thể chạy với cấu hình mới. Vui lòng kiểm tra log hệ thống.${NC}"
        return 1
    fi
}

show_node_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}             NODE MANAGER              ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Xem danh sách Node đang chạy"
    echo -e "2. Thêm chuỗi Node mới (Interactive)"
    echo -e "3. Xóa Node khỏi hệ thống"
    echo -e "0. Quay lại Menu chính"
    echo -e "${BLUE}=======================================${NC}"
    echo -n "Nhập lựa chọn: "
}

# =================================================================
# XỬ LÝ CHỨC NĂNG 1: XEM DANH SÁCH NODE
# =================================================================
list_nodes() {
    clear
    echo -e "${GREEN}--- Danh sách Nodes Đang Hoạt Động Cục Bộ ---${NC}"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    printf "%-18s | %-10s | %-12s | %-15s\n" "TAG ĐỊNH DANH" "PORT" "GIAO THỨC" "TRANSPORT"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    
    if [ "$(jq '. | length' "$NODE_DB" < /dev/null 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "          (Hiện tại hệ thống Agent chưa khởi tạo Node mạng nào)"
    else
        jq -r '.[] | "\(.tag) \(.port) \(.protocol) \(.streamSettings.network // "udp")"' "$NODE_DB" < /dev/null 2>/dev/null | while read -r tag port proto net; do
            printf "%-18s | %-10s | %-12s | %-15s\n" "$tag" "$port" "$proto" "$net"
        done
    fi
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    echo ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# =================================================================
# XỬ LÝ CHỨC NĂNG 2: THÊM HÀNG LOẠT NODE RỒI TẠO USER (BẢN AN TOÀN TUYỆT ĐỐI)
# =================================================================
add_node() {
    echo "[]" > /tmp/session_nodes.json
    
    while true; do
        clear
        echo -e "${GREEN}--- Cấu Hình Thực Thể Node Mạng Mới ---${NC}"
        
        echo -e "Chọn giao thức mạng:"
        echo -e "1. vless"
        echo -e "2. vmess"
        echo -e "3. trojan"
        echo -e "4. hy2"
        read -p "Nhập số lựa chọn (1-4): " proto_choice
        
        local protocol=""
        case $proto_choice in
            1) protocol="vless" ;;
            2) protocol="vmess" ;;
            3) protocol="trojan" ;;
            4) protocol="hy2" ;;
            *) echo -e "${RED}[LỖI] Lựa chọn không hợp lệ! Thử lại.${NC}"; sleep 1; continue ;;
        esac

        local tpl_file=""
        if [ "$protocol" != "hy2" ]; then
            local transport=""
            echo -e "\nChọn mạng truyền tải (Transport) cho $protocol:"
            if [ "$protocol" = "vless" ]; then
                echo -e "1. ws\n2. tcp\n3. grpc\n4. xhttp"
                read -p "Nhập số lựa chọn (1-4): " trans_choice
                case $trans_choice in 1) transport="ws";; 2) transport="tcp";; 3) transport="grpc";; 4) transport="xhttp";; *) echo -e "${RED}Lỗi nhập số!${NC}"; sleep 1; continue;; esac
            else
                echo -e "1. ws\n2. tcp"
                read -p "Nhập số lựa chọn (1-2): " trans_choice
                case $trans_choice in 1) transport="ws";; 2) transport="tcp";; *) echo -e "${RED}Lỗi nhập số!${NC}"; sleep 1; continue;; esac
            fi
            tpl_file="${TEMPLATES_DIR}/${protocol}/${transport}.json"
        else
            tpl_file="${TEMPLATES_DIR}/hy2.json"
        fi

        if [ ! -f "$tpl_file" ]; then
            echo -e "${RED}[LỖI] Không tồn tại file mẫu cấu hình tại: $tpl_file${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để cấu hình lại node này..."
            continue
        fi

        echo ""
        read -p "Nhập Domain quản lý Node (Để trống mặc định lấy IP VPS): " input_domain
        local domain_or_ip=""
        if [ -z "$input_domain" ]; then
            domain_or_ip=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ifconfig.me || echo "127.0.0.1")
            echo -e "${YELLOW}-> Hệ thống tự gán IP VPS: $domain_or_ip${NC}"
        else
            domain_or_ip="$input_domain"
        fi

        # KHẮC PHỤC LỖI TREO: Bổ sung '< /dev/null' đảm bảo JQ luôn chạy tuột, không bị kẹt STDIN
        read -p "Nhập cổng kết nối Port (Để trống hệ thống tự gán ngẫu nhiên): " input_port
        local port=0
        if [ -z "$input_port" ]; then
            while true; do
                port=$((RANDOM % 55000 + 10000))
                if ! jq -e --argjson p "$port" '.[] | select(.port == $p)' "$NODE_DB" < /dev/null >/dev/null 2>&1; then
                    break
                fi
            done
            echo -e "${YELLOW}-> Hệ thống cấp Port ngẫu nhiên: $port${NC}"
        else
            port="$input_port"
            if jq -e --argjson p "$port" '.[] | select(.port == $p)' "$NODE_DB" < /dev/null >/dev/null 2>&1; then
                echo -e "${RED}[LỖI] Cổng kết nối Port $port đã tồn tại trong hệ thống!${NC}"
                sleep 2; continue
            fi
        fi

        read -p "Nhập SNI / ServerName (Để trống hệ thống tự gán ngẫu nhiên): " input_sni
        local sni=""
        if [ -z "$input_sni" ]; then
            local sni_list=("www.cloudflare.com" "images.apple.com" "www.microsoft.com" "www.google.com")
            sni=${sni_list[$RANDOM % ${#sni_list[@]}]}
            echo -e "${YELLOW}-> Hệ thống cấp SNI ngẫu nhiên: $sni${NC}"
        else
            sni="$input_sni"
        fi

        local tag="${protocol}-${port}"

        # Xử lý cấu trúc an toàn không lo crash kể cả file hy2 không có streamSettings
        jq --arg p "$port" --arg t "$tag" --arg sni "$sni" '
            .port = ($p|tonumber) | .tag = $t |
            if .streamSettings then
                if .streamSettings.tlsSettings then .streamSettings.tlsSettings.serverName = $sni else . end |
                if .streamSettings.realitySettings then .streamSettings.realitySettings.serverName = $sni else . end
            else
                .
            fi
        ' "$tpl_file" < /dev/null > /tmp/single_node.json

        jq --slurpfile n /tmp/single_node.json '. += $n' /tmp/session_nodes.json < /dev/null > /tmp/session_nodes.tmp && mv /tmp/session_nodes.tmp /tmp/session_nodes.json

        echo -e "${GREEN}[OK] Đã lưu thông số thiết lập Node [$tag] vào hàng đợi.${NC}"
        
        echo ""
        read -p "Bạn có muốn thêm tiếp Node mạng khác nữa không? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            break
        fi
    done

    # =================================================================
    # GIAI ĐOẠN 2: THIẾT LẬP USER ĐỒNG LOẠT
    # =================================================================
    local count=$(jq '. | length' /tmp/session_nodes.json < /dev/null)
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}Không có Node mạng nào được thêm vào hệ thống.${NC}"
        rm -f /tmp/session_nodes.json
        return
    fi

    clear
    echo -e "${GREEN}--- Đồng Bộ Hóa Cấu Hình User Tiêu Chuẩn ---${NC}"
    echo -e "${BLUE}Hệ thống ghi nhận bạn đã tạo xong [ $count ] Node mạng. Tiến hành gán User đồng loạt:${NC}\n"
    
    read -p "Nhập tên/Email đại diện định danh cho User (Để trống tự sinh): " username
    username=${username:-"client_$((RANDOM%900+100))"}
    
    read -p "Nhập ID/Password kết nối cho User (Để trống hệ thống tự sinh UUID): " user_cred
    if [ -z "$user_cred" ]; then
        user_cred=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "pass_$((RANDOM%90000+10000))")
        echo -e "${YELLOW}-> Hệ thống tự sinh ID/Password bảo mật: $user_cred${NC}"
    fi

    # Bản đồ map tài khoản thông minh đa giao thức
    jq --arg cred "$user_cred" --arg email "$username" '
      map(
        if .protocol == "vless" or .protocol == "vmess" then
          .settings.clients = (.settings.clients // []) + [{"id": $cred, "email": $email}]
        elif .protocol == "trojan" then
          .settings.clients = (.settings.clients // []) + [{"password": $cred, "email": $email}]
        elif .protocol == "hysteria2" or .protocol == "hysteria" or .protocol == "hy2" then
          .settings.users = (.settings.users // []) + [{"password": $cred}]
        else
          .
        fi
      )
    ' /tmp/session_nodes.json < /dev/null > /tmp/session_nodes_final.json

    # Trộn dữ liệu vào DB gốc
    jq --slurpfile new_nodes /tmp/session_nodes_final.json '. += $new_nodes[0]' "$NODE_DB" < /dev/null > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    
    rm -f /tmp/session_nodes.json /tmp/single_node.json /tmp/session_nodes_final.json
    echo -e "\n${GREEN}[THÀNH CÔNG] Đã ghi nhận đồng loạt thông tin cấu hình vào DB Agent Cục Bộ.${NC}"
    
    # Nạp cấu hình ra file config thực tế và kích hoạt Xray
    apply_config
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# =================================================================
# XỬ LÝ CHỨC NĂNG 3: XÓA NODE KHỎI HỆ THỐNG
# =================================================================
delete_node() {
    clear
    echo -e "${RED}--- Gỡ Bỏ Cấu Hình Node Hệ Thống ---${NC}"
    
    if [ "$(jq '. | length' "$NODE_DB" < /dev/null 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}Hệ thống đang trống, không có dữ liệu Node mạng để gỡ bỏ.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi
    
    read -p "Nhập chính xác chuỗi Tag của Node bạn muốn xóa: " tag
    
    if [ -z "$tag" ]; then
        echo -e "${RED}[LỖI] Chuỗi định danh Tag không được bỏ trống!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi

    if [ "$(jq --arg t "$tag" 'any(.[]; .tag == $t)' "$NODE_DB" < /dev/null 2>/dev/null)" != "true" ]; then
        echo -e "${RED}[LỖI] Không tìm thấy thực thể Node nào khớp với chuỗi định danh '$tag'.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi
    
    jq --arg t "$tag" 'del(.[] | select(.tag == $t))' "$NODE_DB" < /dev/null > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    echo -e "${GREEN}Đã xóa thực thể Node '$tag' khỏi Database thành công.${NC}"
    
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# VÒNG LẶP ĐIỀU KHIỂN MENU CHÍNH
while true; do
    show_node_menu
    read -r choice
    case $choice in
        1) list_nodes ;;
        2) add_node ;;
        3) delete_node ;;
        0) break ;;
        *) echo -e "${RED}Lựa chọn không hợp lệ! Vui lòng chọn lại.${NC}" ; sleep 1 ;;
    esac
done