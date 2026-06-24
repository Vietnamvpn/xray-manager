#!/bin/bash
# Module quản lý Node (Inbounds) - Bản nâng cấp tối ưu hóa tương tác tự động
# Tách biệt hoàn toàn Agent độc lập, cấu hình chuỗi mạng linh hoạt cục bộ.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

# =================================================================
# HÀM CỐT LÕI: BIÊN DỊCH VÀ RESTART LÕI MẠNG XRAY
# =================================================================
apply_config() {
    local active_config="${XRAY_CONFIG_DIR}/config.json"
    
    if [ ! -f "${TEMPLATES_DIR}/base.json" ]; then
        echo -e "${RED}[LỖI] Không tìm thấy file mẫu base.json tại templates/.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Đang đồng bộ cấu hình hệ thống mạng...${NC}"
    if ! jq --slurpfile nodes "$NODE_DB" '.inbounds = $nodes[0]' "${TEMPLATES_DIR}/base.json" > "${active_config}.tmp"; then
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
    
    if [ "$(jq '. | length' "$NODE_DB")" -eq 0 ]; then
        echo -e "          (Hiện tại hệ thống Agent chưa khởi tạo Node mạng nào)"
    else
        jq -r '.[] | "\(.tag) \(.port) \(.protocol) \(.streamSettings.network // "udp")"' "$NODE_DB" | while read -r tag port proto net; do
            printf "%-18s | %-10s | %-12s | %-15s\n" "$tag" "$port" "$proto" "$net"
        done
    fi
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    echo ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# =================================================================
# XỬ LÝ CHỨC NĂNG 2: THÊM HÀNG LOẠT NODE RỒI TẠO USER (NÂNG CẤP MỚI)
# =================================================================
add_node() {
    # Khởi tạo file tạm chứa danh sách các Node chuẩn bị thêm trong phiên này
    echo "[]" > /tmp/session_nodes.json
    
    while true; do
        clear
        echo -e "${GREEN}--- Cấu Hình Thực Thể Node Mạng Mới ---${NC}"
        
        # Bước 1: Chọn giao thức bằng số thay vì gõ chữ
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

        # Bước 2: Chọn Transport bằng số (Nếu không phải hy2)
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

        # Kiểm tra sự tồn tại của file cấu hình mẫu
        if [ ! -f "$tpl_file" ]; then
            echo -e "${RED}[LỖI] Không tồn tại file mẫu: $tpl_file${NC}"
            read -n 1 -s -r -p "Bấm phím bất kỳ để cấu hình lại node này..."
            continue
        fi

        # Bước 3: Nhập Domain thay thế cho tên Tag (Bỏ trống lấy IP của VPS)
        echo ""
        read -p "Nhập Domain quản lý Node (Để trống mặc định lấy IP VPS): " input_domain
        local domain_or_ip=""
        if [ -z "$input_domain" ]; then
            # Tự động quét IP WAN của VPS thông qua API công cộng uy tín
            domain_or_ip=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "127.0.0.1")
            echo -e "${YELLOW}-> Hệ thống tự gán IP VPS: $domain_or_ip${NC}"
        else
            domain_or_ip="$input_domain"
        fi

        # Bước 4: Nhập Port kết nối (Bỏ trống tự gán ngẫu nhiên không trùng lặp)
        read -p "Nhập cổng kết nối Port (Để trống hệ thống tự gán ngẫu nhiên): " input_port
        local port=0
        if [ -z "$input_port" ]; then
            while true; do
                # Sinh port ngẫu nhiên trong vùng an toàn từ 10000 đến 65000
                port=$((RANDOM % 55000 + 10000))
                # Quét kiểm tra xem port này đã bị chiếm dụng trong DB chưa
                if ! jq -e --argjson p "$port" '.[] | select(.port == $p)' "$NODE_DB" >/dev/null; then
                    break
                fi
            done
            echo -e "${YELLOW}-> Hệ thống cấp Port ngẫu nhiên: $port${NC}"
        else
            port="$input_port"
            if jq -e --argjson p "$port" '.[] | select(.port == $p)' "$NODE_DB" >/dev/null; then
                echo -e "${RED}[LỖI] Cổng kết nối Port $port đã tồn tại trong DB hệ thống! Hãy cấu hình lại.${NC}"
                sleep 2; continue
            fi
        fi

        # Bước 5: Nhập SNI giả lập (Bỏ trống tự gán ngẫu nhiên giúp mạng thông suốt)
        read -p "Nhập SNI SNI/ServerName (Để trống hệ thống tự gán ngẫu nhiên): " input_sni
        local sni=""
        if [ -z "$input_sni" ]; then
            local sni_list=("www.cloudflare.com" "images.apple.com" "www.microsoft.com" "www.google.com" "www.speedtest.net")
            sni=${sni_list[$RANDOM % ${#sni_list[@]}]}
            echo -e "${YELLOW}-> Hệ thống cấp SNI ngẫu nhiên: $sni${NC}"
        else
            sni="$input_sni"
        fi

        # Tự động biên dịch chuỗi Tag định danh duy nhất dựa theo giao thức và cổng
        local tag="${protocol}-${port}"

        # Bước 6: Sử dụng JQ tạo cấu hình Node thô tạm thời, tự động chèn SNI vào đúng khối mạng TLS nếu có
        jq --arg p "$port" --arg t "$tag" --arg sni "$sni" '
            .port = ($p|tonumber) | .tag = $t |
            if .streamSettings.tlsSettings then .streamSettings.tlsSettings.serverName = $sni else . end |
            if .streamSettings.realitySettings then .streamSettings.realitySettings.serverName = $sni else . end
        ' "$tpl_file" > /tmp/single_node.json

        # Đẩy Node thô này vào danh sách mảng phiên hiện tại
        jq --slurpfile n /tmp/single_node.json '. += $n' /tmp/session_nodes.json > /tmp/session_nodes.tmp && mv /tmp/session_nodes.tmp /tmp/session_nodes.json

        echo -e "${GREEN}[OK] Đã lưu thông số thiết lập Node [$tag] vào hàng đợi.${NC}"
        
        # Bước 7: Hỏi tiếp tục Thêm Node nữa hay kết thúc để chuyển sang nhập User
        echo ""
        read -p "Bạn có muốn thêm tiếp Node mạng khác nữa không? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            break
        fi
    done

    # =================================================================
    # GIAI ĐOẠN 2: THIẾT LẬP USER ĐỒNG LOẠT CHO CÁC NODE VỪA TẠO
    # =================================================================
    local count=$(jq '. | length' /tmp/session_nodes.json)
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}Không có Node mạng nào được thêm vào hệ thống.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi

    clear
    echo -e "${GREEN}--- Đồng Bộ Hóa Cấu Hình User Tiêu Chuẩn ---${NC}"
    echo -e "${BLUE}Hệ thống ghi nhận bạn đã tạo xong [ $count ] Node mạng. Tiến hành gán User đồng loạt:${NC}\n"
    
    read -p "Nhập tên/Email đại diện định danh cho User (Để trống tự sinh): " username
    username=${username:-"client_$((RANDOM%900+100))"}
    
    read -p "Nhập ID/Password kết nối cho User (Để trống hệ thống tự sinh UUID): " user_cred
    if [ -z "$user_cred" ]; then
        # Sử dụng UUID hệ thống hoặc chuỗi bảo mật ngẫu nhiên
        user_cred=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "pass_$((RANDOM%90000+10000))")
        echo -e "${YELLOW}-> Hệ thống tự sinh ID/Password bảo mật: $user_cred${NC}"
    fi

    # Sử dụng JQ duyệt mảng map để tự nhận diện kiểu giao thức và chèn thông tin User tương thích cấu trúc lõi
    jq --arg cred "$user_cred" --arg email "$username" '
      map(
        if .protocol == "vless" or .protocol == "vmess" then
          .settings.clients = (.settings.clients // []) + [{"id": $cred, "email": $email}]
        elif .protocol == "trojan" then
          .settings.clients = (.settings.clients // []) + [{"password": $cred, "email": $email}]
        elif .protocol == "hysteria2" or .protocol == "hysteria" then
          .settings.users = (.settings.users // []) + [{"password": $cred}]
        else
          .
        fi
      )
    ' /tmp/session_nodes.json > /tmp/session_nodes_final.json

    # Nối toàn bộ chuỗi Node kèm User mới này vào Database nodes.json gốc của Agent
    jq --slurpfile new_nodes /tmp/session_nodes_final.json '. += $new_nodes[0]' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    
    # Dọn dẹp tàn dư file rác trong thư mục tạm /tmp
    rm -f /tmp/session_nodes.json /tmp/single_node.json /tmp/session_nodes_final.json
    
    echo -e "\n${GREEN}[THÀNH CÔNG] Đã ghi nhận đồng loạt thông tin cấu hình vào DB Agent Cục Bộ.${NC}"
    
    # Đồng bộ cấu hình ra tệp tổng và khởi động luồng mạng thực tế
    apply_config
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# =================================================================
# XỬ LÝ CHỨC NĂNG 3: XÓA NODE KHỎI HỆ THỐNG
# =================================================================
delete_node() {
    clear
    echo -e "${RED}--- Gỡ Bỏ Cấu Hình Node Hệ Thống ---${NC}"
    
    if [ "$(jq '. | length' "$NODE_DB")" -eq 0 ]; then
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

    if ! jq -e --arg t "$tag" '.[] | select(.tag == $t)' "$NODE_DB" >/dev/null; then
        echo -e "${RED}[LỖI] Không tìm thấy thực thể Node nào khớp với chuỗi định danh '$tag'.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi
    
    jq --arg t "$tag" 'del(.[] | select(.tag == $t))' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    echo -e "${GREEN}Đã xóa thực thể Node '$tag' khỏi Database thành công.${NC}"
    
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# =================================================================
# VÒNG LẶP ĐIỀU KHIỂN MENU CHÍNH
# =================================================================
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