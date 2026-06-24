#!/bin/bash
# Module quản lý Node (Inbounds) - Bản sửa lỗi khớp cấu trúc templates/

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.conf"
source "${SCRIPTS_DIR}/utils.sh"

check_root

# =================================================================
# HÀM CỐT LÕI: GỘP CONFIG VÀO LÕI XRAY VÀ KÍCH HOẠT CHẠY MẠNG
# =================================================================
apply_config() {
    local active_config="${XRAY_CONFIG_DIR}/config.json"
    
    if [ ! -f "${TEMPLATES_DIR}/base.json" ]; then
        echo -e "${RED}[LỖI] Không tìm thấy file mẫu base.json tại đường dẫn templates/.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Đang đồng bộ và biên dịch cấu hình hệ thống mạng...${NC}"
    
    # Sử dụng jq để bơm toàn bộ mảng dữ liệu từ nodes.json vào thuộc tính "inbounds" của file base.json
    if ! jq --slurpfile nodes "$NODE_DB" '.inbounds = $nodes[0]' "${TEMPLATES_DIR}/base.json" > "${active_config}.tmp"; then
        echo -e "${RED}[LỖI] Cú pháp cấu hình JSON không hợp lệ. Vui lòng kiểm tra lại các file template.${NC}"
        rm -f "${active_config}.tmp"
        return 1
    fi

    # Thay thế an toàn file cấu hình đang chạy của Xray-core
    mv "${active_config}.tmp" "$active_config"

    # Ra lệnh cho hệ thống nạp lại cấu hình và khởi chạy luồng mạng
    echo -e "${YELLOW}Đang tái khởi động tiến trình dịch vụ Xray...${NC}"
    if systemctl restart xray; then
        echo -e "${GREEN}[THÀNH CÔNG] Đồng bộ hoàn tất! Hệ thống mạng hiện đã hoạt động ổn định.${NC}"
        return 0
    else
        echo -e "${RED}[LỖI] Tiến trình Xray thất bại khi chạy cấu hình mới. Vui lòng kiểm tra lại.${NC}"
        return 1
    fi
}

show_node_menu() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}             NODE MANAGER              ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Xem danh sách Node đang chạy"
    echo -e "2. Thêm Node mới (Inbound)"
    echo -e "3. Xóa Node"
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
    printf "%-15s | %-10s | %-12s | %-15s\n" "TAG (ĐỊNH DANH)" "CỔNG PORT" "GIAO THỨC" "MẠNG TRUYỀN TẢI"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    
    if [ "$(jq '. | length' "$NODE_DB")" -eq 0 ]; then
        echo -e "          (Hiện tại hệ thống Agent chưa khởi tạo Node mạng nào)"
    else
        # Đọc dữ liệu JSON, phân tách các trường để hiển thị. Nếu không có streamSettings (như hy2) thì để mặc định là udp
        jq -r '.[] | "\(.tag) \(.port) \(.protocol) \(.streamSettings.network // "udp")"' "$NODE_DB" | while read -r tag port proto net; do
            printf "%-15s | %-10s | %-12s | %-15s\n" "$tag" "$port" "$proto" "$net"
        done
    fi
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    echo ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# =================================================================
# XỬ LÝ CHỨC NĂNG 2: THÊM NODE (ĐÃ FIX KHỚP CẤU TRÚC THƯ MỤC)
# =================================================================
add_node() {
    clear
    echo -e "${GREEN}--- Tạo Thiết Lập Node Mới (Inbound) ---${NC}"
    
    # 1. Nhập giao thức mạng trước
    read -p "Nhập giao thức mạng (vless / vmess / trojan / hy2): " protocol
    protocol=$(echo "$protocol" | tr '[:upper:]' '[:lower:]') # Chuyển về chữ thường để tránh lỗi gõ hoa
    
    local tpl_file=""
    
    # 2. Kiểm tra cấu trúc rẽ nhánh dựa theo file mẫu của bạn
    if [ "$protocol" = "hy2" ]; then
        # Hysteria 2 lấy trực tiếp file hy2.json ở thư mục gốc templates
        tpl_file="${TEMPLATES_DIR}/hy2.json"
    elif [ "$protocol" = "vless" ] || [ "$protocol" = "vmess" ] || [ "$protocol" = "trojan" ]; then
        # Hiển thị gợi ý transport dựa theo đúng các file bạn đang có trong thư mục
        if [ "$protocol" = "vless" ]; then
            echo -e "Các transport khả dụng trong templates/vless/: ${CYAN}ws, xhttp, grpc${NC}"
        elif [ "$protocol" = "vmess" ]; then
            echo -e "Các transport khả dụng trong templates/vmess/: ${CYAN}ws, tcp${NC}"
        elif [ "$protocol" = "trojan" ]; then
            echo -e "Các transport khả dụng trong templates/trojan/: ${CYAN}ws, tcp${NC}"
        fi
        
        read -p "Nhập Transport truyền tải: " transport
        transport=$(echo "$transport" | tr '[:upper:]' '[:lower:]')
        
        # Đường dẫn đến thư mục con tương ứng
        tpl_file="${TEMPLATES_DIR}/${protocol}/${transport}.json"
    else
        echo -e "${RED}[LỖI] Giao thức '$protocol' không nằm trong danh sách hỗ trợ!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi
    
    # Kiểm tra xem file template cấu hình có tồn tại thực tế hay không
    if [ ! -f "$tpl_file" ]; then
        echo -e "${RED}[LỖI] Không tồn tại file cấu hình mẫu tại: $tpl_file${NC}"
        echo -e "${YELLOW}Vui lòng kiểm tra lại kho file trong thư mục templates/.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi

    # 3. Thu thập nốt các thông tin vận hành
    read -p "Nhập cổng kết nối Port (Ví dụ: 443, 8443): " port
    read -p "Nhập chuỗi Tag định danh (Phải là duy nhất, Ví dụ: node-hy2-443): " tag
    
    if [ -z "$port" ] || [ -z "$tag" ]; then
        echo -e "${RED}[LỖI] Bạn không được bỏ trống Port hoặc Tag định danh!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi

    # Kiểm tra trùng lặp Tag trong DB cục bộ
    if jq -e --arg t "$tag" '.[] | select(.tag == $t)' "$NODE_DB" >/dev/null; then
        echo -e "${RED}[LỖI] Chuỗi định danh Tag '$tag' đã tồn tại trên VPS này. Hãy chọn tên khác!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi
    
    # 4. Xử lý logic JSON: Bơm Port (ép kiểu thành số) và Tag định danh vào file tạm
    if ! jq --arg p "$port" --arg t "$tag" '.port = ($p|tonumber) | .tag = $t' "$tpl_file" > /tmp/new_node.json; then
        echo -e "${RED}[LỖI] Thao tác xử lý dữ liệu JSON thất bại. File mẫu cấu hình có thể bị sai cú pháp.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi
    
    # 5. Đẩy dữ liệu vào DB nodes.json cục bộ
    jq --slurpfile new_node /tmp/new_node.json '. += $new_node' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    rm -f /tmp/new_node.json
    
    echo -e "${GREEN}Đã ghi nhận cấu hình Node mới vào Database Agent cục bộ.${NC}"
    
    # 6. Biên dịch lại cấu hình tổng và khởi chạy mạng thực tế
    apply_config
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# =================================================================
# XỬ LÝ CHỨC NĂNG 3: XÓA NODE VÀ GỘP LẠI MẠNG
# =================================================================
delete_node() {
    clear
    echo -e "${RED}--- Gỡ Bỏ Cấu Hình Node Hệ Thống ---${NC}"
    
    if [ "$(jq '. | length' "$NODE_DB")" -eq 0 ]; then
        echo -e "${YELLOW}Hệ thống đang trống, không có Node nào khả dụng để tiến hành xóa.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi
    
    read -p "Nhập chính xác chuỗi Tag của Node bạn muốn gỡ bỏ: " tag
    
    if [ -z "$tag" ]; then
        echo -e "${RED}[LỖI] Bạn không được để trống chuỗi Tag định danh!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi

    # Xác thực sự tồn tại của Node trong DB trước khi xóa
    if ! jq -e --arg t "$tag" '.[] | select(.tag == $t)' "$NODE_DB" >/dev/null; then
        echo -e "${RED}[LỖI] Không tìm thấy bất kỳ Node nào khớp với chuỗi Tag định danh '$tag'.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi
    
    # Sử dụng hàm 'del' của jq để lọc bỏ Object có chứa Tag được chọn ra khỏi mảng JSON
    jq --arg t "$tag" 'del(.[] | select(.tag == $t))' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    echo -e "${GREEN}Đã xóa thực thể Node '$tag' khỏi Database Agent cục bộ.${NC}"
    
    # Cập nhật lại cấu hình lõi mạng
    apply_config
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# =================================================================
# VÒNG LẶP MENU ĐIỀU KHIỂN CHÍNH
# =================================================================
while true; do
    show_node_menu
    read -r choice
    case $choice in
        1) list_nodes ;;
        2) add_node ;;
        3) delete_node ;;
        0) break ;;
        *) echo -e "${RED}Lựa chọn của bạn không hợp lệ! Vui lòng thử lại.${NC}" ; sleep 1 ;;
    esac
done