#!/bin/bash
# Module quản lý Node (Inbounds) - Bản hoàn chỉnh chạy thực tế
# Đảm bảo nguyên tắc Agent độc lập, tự xử lý cấu hình mạng cục bộ trên VPS node.

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
        echo -e "${RED}[LỖI] Tiến trình Xray thất bại khi chạy cấu hình mới. Vui lòng kiểm tra log hệ thống bằng lệnh 'journalctl -u xray'.${NC}"
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
# XỬ LÝ CHỨC NĂNG 1: XEM DANH SÁCH NODE (PARSE TABLE)
# =================================================================
list_nodes() {
    clear
    echo -e "${GREEN}--- Danh sách Nodes Đang Hoạt Động Cục Bộ ---${NC}"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    printf "%-15s | %-10s | %-12s | %-15s\n" "TAG (ĐỊNH DANH)" "CỔNG PORT" "GIAO THỨC" "MẠNG TRUYỀN TẢI"
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    
    # Kiểm tra xem cơ sở dữ liệu mảng có rỗng hay không
    if [ "$(jq '. | length' "$NODE_DB")" -eq 0 ]; then
        echo -e "          (Hiện tại hệ thống Agent chưa khởi tạo Node mạng nào)"
    else
        # Đọc dữ liệu JSON, phân tách các trường để hiển thị dạng bảng scannable rõ ràng
        jq -r '.[] | "\(.tag) \(.port) \(.protocol) \(.streamSettings.network // "tcp")"' "$NODE_DB" | while read -r tag port proto net; do
            printf "%-15s | %-10s | %-12s | %-15s\n" "$tag" "$port" "$proto" "$net"
        done
    fi
    echo -e "${BLUE}----------------------------------------------------------------------${NC}"
    echo ""
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# =================================================================
# XỬ LÝ CHỨC NĂNG 2: THÊM NODE (BƠM DATA JSON & RESTART NETWORK)
# =================================================================
add_node() {
    clear
    echo -e "${GREEN}--- Tạo Thiết Lập Node Mới (Inbound) ---${NC}"
    
    # 1. Thu thập dữ liệu cấu hình đầu vào từ người quản trị
    read -p "Nhập giao thức mạng (vless / vmess / trojan / hy2): " protocol
    read -p "Nhập Transport truyền tải (ws / tcp / grpc): " transport
    read -p "Nhập cổng kết nối Port (Ví dụ: 443, 8443): " port
    read -p "Nhập chuỗi Tag định danh (Phải là duy nhất, Ví dụ: vless-ws-in): " tag
    
    # Kiểm tra chặn lỗi để trống thông tin
    if [ -z "$protocol" ] || [ -z "$transport" ] || [ -z "$port" ] || [ -z "$tag" ]; then
        echo -e "${RED}[LỖI] Bạn không được bỏ trống bất kỳ trường thông tin thiết lập nào!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi

    # Kiểm tra chặn trùng lặp trường dữ liệu duy nhất (Tag) trong DB
    if jq -e --arg t "$tag" '.[] | select(.tag == $t)' "$NODE_DB" >/dev/null; then
        echo -e "${RED}[LỖI] Chuỗi định danh Tag '$tag' đã tồn tại. Hãy đặt tên khác để phân biệt!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi

    # Định vị file cấu hình thô theo cấu trúc thư mục phân cấp
    local tpl_file="${TEMPLATES_DIR}/${protocol}/${transport}.json"
    
    if [ ! -f "$tpl_file" ]; then
        echo -e "${RED}[LỖI] Không tồn tại file cấu hình mẫu tại: $tpl_file${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi
    
    # 2. Xử lý logic JSON: Bơm Port (ép kiểu thành số nguyên) và Tag định danh vào file tạm
    if ! jq --arg p "$port" --arg t "$tag" '.port = ($p|tonumber) | .tag = $t' "$tpl_file" > /tmp/new_node.json; then
        echo -e "${RED}[LỖI] Thao tác xử lý dữ liệu JSON thất bại. Định dạng file mẫu có thể sai cú pháp.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để quay lại..."
        return
    fi
    
    # 3. Đẩy node vừa tạo vào mảng lưu trữ database cục bộ của Agent
    jq --slurpfile new_node /tmp/new_node.json '. += $new_node' "$NODE_DB" > "${NODE_DB}.tmp" && mv "${NODE_DB}.tmp" "$NODE_DB"
    rm -f /tmp/new_node.json
    
    echo -e "${GREEN}Đã ghi nhận cấu hình Node mới vào Database Agent cục bộ.${NC}"
    
    # 4. Áp dụng đồng bộ trực tiếp ra hệ thống mạng thực tế
    apply_config
    
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

# =================================================================
# XỬ LÝ CHỨC NĂNG 3: XÓA NODE VÀ GỘP LẠI MẠNG
# =================================================================
delete_node() {
    clear
    echo -e "${RED}--- Gỡ Bỏ Cấu Hình Node Hệ Thống ---${NC}"
    
    # Kiểm tra nếu DB trống thì không cần xử lý tiếp
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
    
    # Cập nhật và khởi chạy lại mạng để áp dụng thay đổi
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