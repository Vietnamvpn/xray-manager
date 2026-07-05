#!/bin/bash
# Module quản lý tự động Outbounds Relay và Routing Rules cho xray-manager

# 1. Khai báo thẳng đường dẫn gốc tuyệt đối
BASE_DIR="/etc/xray-manager"

# 2. Nạp các file cần thiết theo đúng cấu trúc chuẩn
source "${BASE_DIR}/config.conf"
source "${BASE_DIR}/scripts/utils.sh"

# Khai báo biến đường dẫn dữ liệu (nếu config.conf chưa có)
DATA_DIR="${BASE_DIR}/data"
OUTBOUND_DB="${DATA_DIR}/outbounds.json"
ROUTING_DB="${DATA_DIR}/routing.json"

# Đảm bảo file dữ liệu luôn tồn tại ở dạng mảng JSON hợp lệ
[ -f "$OUTBOUND_DB" ] || echo "[]" > "$OUTBOUND_DB"
[ -f "$ROUTING_DB" ] || echo "[]" > "$ROUTING_DB"

# Hàm bóc tách liên kết proxy thành cấu trúc JSON của Xray-core Outbound
parse_proxy_link() {
    local link="$1"
    local custom_tag="$2"
    
    local proto=$(echo "$link" | grep -o '^[a-zA-Z0-9]*')
    if [[ "$proto" != "vless" && "$proto" != "trojan" ]]; then
        echo "ERR_PROTO"
        return 1
    fi
    
    # Trích xuất thông tin thô từ link
    local user_info_host_port=$(echo "$link" | sed -e 's/^.*:\/\///' -e 's/\?.*$//' -e 's/#.*$//')
    local credential=$(echo "$user_info_host_port" | cut -d'@' -f1)
    local host_port=$(echo "$user_info_host_port" | cut -d'@' -f2)
    local host=$(echo "$host_port" | cut -d':' -f1)
    local port=$(echo "$host_port" | cut -d':' -f2)
    
    if [[ -z "$credential" || -z "$host" || -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
        echo "ERR_FORMAT"
        return 1
    fi
    
    # Tạo nhãn định danh (Tag)
    local tag="$custom_tag"
    if [ -z "$tag" ]; then
        tag=$(echo "$link" | grep -o '#.*$' | sed 's/#//')
        [ -z "$tag" ] && tag="relay-${proto}-${port}"
    fi

    # Xây dựng chuỗi JSON tương ứng với từng giao thức cấu hình
    if [ "$proto" == "vless" ]; then
        cat <<EOF
{
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$host",
      "port": $port,
      "users": [{
        "id": "$credential",
        "encryption": "none",
        "level": 0
      }]
    }]
  },
  "streamSettings": { "network": "tcp" },
  "tag": "$tag"
}
EOF
    elif [ "$proto" == "trojan" ]; then
        cat <<EOF
{
  "protocol": "trojan",
  "settings": {
    "servers": [{
      "address": "$host",
      "port": $port,
      "password": "$credential",
      "level": 0
    }]
  },
  "streamSettings": { "network": "tcp" },
  "tag": "$tag"
}
EOF
    fi
}

# =================================================================
# PHẦN 1: QUẢN LÝ OUTBOUNDS
# =================================================================

list_outbounds() {
    local count=$(jq '. | length' "$OUTBOUND_DB")
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}(Danh sách Outbound hiện tại đang trống)${NC}"
        return 1
    fi
    echo -e "${CYAN}STT | Nhãn (Tag) | Giao thức | Máy chủ đích${NC}"
    echo -e "------------------------------------------------"
    jq -r 'keys[] as $i | "\($i+1)) [\(.[$i].tag)] | Giao thức: \(.[$i].protocol) -> \(.[$i].settings.vnext[0].address // .[$i].settings.servers[0].address):\(.[$i].settings.vnext[0].port // .[$i].settings.servers[0].port)"' "$OUTBOUND_DB"
    return 0
}

add_outbound() {
    clear
    echo -e "${BLUE}=== THÊM NODE TRUNG GIAN (OUTBOUND RELAY) ===${NC}"
    echo -e "Hỗ trợ các liên kết chuẩn: vless:// hoặc trojan://"
    echo -e "Nhập ${RED}0${NC} để quay lại."
    echo ""
    read -p "Nhập liên kết Node của bạn: " proxy_link
    [ "$proxy_link" == "0" ] && return

    read -p "Đặt tên nhãn gợi nhớ (Tag) [Bỏ trống tự nhận diện]: " custom_tag
    [ "$custom_tag" == "0" ] && return

    echo -e "\n${YELLOW}Đang kiểm tra dữ liệu cấu hình liên kết...${NC}"
    local parsed_json=$(parse_proxy_link "$proxy_link" "$custom_tag")
    
    if [[ "$parsed_json" == "ERR_PROTO" ]]; then
        echo -e "${RED}[LỖI] Hệ thống hiện tại chỉ hỗ trợ xử lý tự động liên kết định dạng VLESS hoặc TROJAN!${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để thực hiện lại..." && return
    elif [[ "$parsed_json" == "ERR_FORMAT" ]]; then
        echo -e "${RED}[LỖI] Cú pháp chuỗi liên kết không đúng định dạng. Vui lòng kiểm tra lại IP/Cổng/UUID.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để thực hiện lại..." && return
    fi

    local check_tag=$(echo "$parsed_json" | jq -r '.tag')
    local duplicate=$(jq --arg t "$check_tag" '.[] | select(.tag == $t)' "$OUTBOUND_DB")
    if [ ! -z "$duplicate" ]; then
        echo -e "${RED}[LỖI] Tên nhãn (Tag) '$check_tag' đã tồn tại trên một Node khác trong cơ sở dữ liệu.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để thực hiện lại..." && return
    fi

    jq --argjson new_node "$parsed_json" '. += [$new_node]' "$OUTBOUND_DB" > "${OUTBOUND_DB}.tmp" && mv "${OUTBOUND_DB}.tmp" "$OUTBOUND_DB"
    echo -e "${GREEN}[THÀNH CÔNG] Đã thêm Node trung gian vào hệ thống dữ liệu.${NC}"
    
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

edit_outbound() {
    clear
    echo -e "${BLUE}=== CHỈNH SỬA NODE TRUNG GIAN ===${NC}"
    if ! list_outbounds; then
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..." && return
    fi
    echo ""
    read -p "Chọn số thứ tự Node cần sửa (Hoặc gõ 0 để quay lại): " index
    [[ "$index" == "0" || -z "$index" ]] && return
    
    local real_idx=$((index - 1))
    local exist_check=$(jq --argjson idx "$real_idx" '.[$idx]' "$OUTBOUND_DB")
    if [ "$exist_check" == "null" ]; then
        echo -e "${RED}[LỖI] Số thứ tự lựa chọn không hợp lệ.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ để thực hiện lại..." && return
    fi

    read -p "Nhập liên kết cấu hình Node mới thay thế: " new_link
    [ "$new_link" == "0" ] && return
    
    if [ -z "$new_link" ]; then
        echo -e "${RED}[LỖI] Liên kết proxy không được phép để trống.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ..." && return
    fi

    local current_tag=$(jq -r --argjson idx "$real_idx" '.[$idx].tag' "$OUTBOUND_DB")
    local parsed_json=$(parse_proxy_link "$new_link" "$current_tag")
    
    if [[ "$parsed_json" == "ERR_PROTO" || "$parsed_json" == "ERR_FORMAT" ]]; then
        echo -e "${RED}[LỖI] Cấu trúc đường liên kết mới không hợp lệ.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ..." && return
    fi

    jq --argjson idx "$real_idx" --argjson obj "$parsed_json" '.[$idx] = $obj' "$OUTBOUND_DB" > "${OUTBOUND_DB}.tmp" && mv "${OUTBOUND_DB}.tmp" "$OUTBOUND_DB"
    echo -e "${GREEN}[THÀNH CÔNG] Cập nhật thông tin Node hoàn tất.${NC}"
    
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

delete_outbound() {
    clear
    echo -e "${BLUE}=== XÓA BỎ NODE TRUNG GIAN ===${NC}"
    if ! list_outbounds; then
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..." && return
    fi
    echo ""
    read -p "Chọn số thứ tự Node muốn xóa (Hoặc gõ 0 để quay lại): " index
    [[ "$index" == "0" || -z "$index" ]] && return

    local real_idx=$((index - 1))
    local target_tag=$(jq -r --argjson idx "$real_idx" '.[$idx].tag' "$OUTBOUND_DB" 2>/dev/null)
    
    if [ -z "$target_tag" || "$target_tag" == "null" ]; then
        echo -e "${RED}[LỖI] Lựa chọn không tồn tại.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ..." && return
    fi

    jq --argjson idx "$real_idx" 'del(.[$idx])' "$OUTBOUND_DB" > "${OUTBOUND_DB}.tmp" && mv "${OUTBOUND_DB}.tmp" "$OUTBOUND_DB"
    echo -e "${GREEN}[THÀNH CÔNG] Đã gỡ bỏ dữ liệu Node trung gian khỏi hàng đợi.${NC}"
    
    # Tự động dọn dẹp các quy tắc định tuyến mồ côi liên quan đến tag vừa xóa
    jq --arg t "$target_tag" 'del(.[] | select(.outboundTag == $t))' "$ROUTING_DB" > "${ROUTING_DB}.tmp" && mv "${ROUTING_DB}.tmp" "$ROUTING_DB"
    
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

menu_outbounds() {
    while true; do
        clear
        echo -e "${BLUE}=======================================${NC}"
        echo -e "${YELLOW}      MỤC CHỈNH SỬA NODE OUTBOUNDS     ${NC}"
        echo -e "${BLUE}=======================================${NC}"
        echo -e "1. Thêm Node trung gian mới"
        echo -e "2. Sửa thông tin Node sẵn có"
        echo -e "3. Xóa bỏ Node trung gian"
        echo -e "0. Quay lại Menu chính"
        echo -e "${BLUE}=======================================${NC}"
        echo ""
        read -p "Nhập thao tác: " opt
        case $opt in
            1) add_outbound ;;
            2) edit_outbound ;;
            3) delete_outbound ;;
            0) break ;;
            *) echo -e "${RED}Lựa chọn không hợp lệ.${NC}" && sleep 1 ;;
        esac
    done
}

# =================================================================
# PHẦN 2: QUẢN LÝ ROUTING (BẢNG ĐỊNH TUYẾN)
# =================================================================

list_routings() {
    local count=$(jq '. | length' "$ROUTING_DB")
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}(Bảng định tuyến rỗng - tất cả các cổng đang đi thẳng mặc định)${NC}"
        return 1
    fi
    echo -e "${CYAN}STT | Nhóm cổng nhận (Inbound) ---> Cổng xuất trung gian (Outbound)${NC}"
    echo -e "------------------------------------------------------------------"
    jq -r 'keys[] as $i | "\($i+1)) Inbound: [\(.[$i].inboundTag | join(","))] =======> Đi qua Outbound: [\(.[$i].outboundTag)]"' "$ROUTING_DB"
    return 0
}

add_routing() {
    clear
    echo -e "${BLUE}=== TẠO QUY TẮC ĐỊNH TUYẾN BẮC CẦU ===${NC}"
    echo -e "Nhập 0 ở bất kỳ trường nào để hủy bỏ thao tác."
    echo ""
    
    read -p "Nhập chính xác tên nhãn nhận khách (Inbound Tag ví dụ: inbound-can-relay): " in_tag
    [[ "$in_tag" == "0" || -z "$in_tag" ]] && return

    echo -e "\n--- Danh sách các cổng ra trung gian hợp lệ đang chạy ---"
    if ! list_outbounds; then
        echo -e "${RED}[LỖI] Vui lòng thêm ít nhất một cấu hình Node Outbound trước khi cài đặt định tuyến.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ..." && return
    fi
    echo ""
    read -p "Nhập chính xác tên nhãn đích ra (Outbound Tag tương ứng): " out_tag
    [[ "$out_tag" == "0" || -z "$out_tag" ]] && return

    # Kiểm tra tính tồn tại thực tế của Outbound Tag vừa gõ
    local check_out=$(jq --arg t "$out_tag" '.[] | select(.tag == $t)' "$OUTBOUND_DB")
    if [ -z "$check_out" ]; then
        echo -e "${RED}[LỖI] Tên nhãn Outbound không tồn tại trong hệ thống lưu trữ. Không thể gán quy tắc.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ..." && return
    fi

    local rule_json=$(cat <<EOF
{
  "type": "field",
  "inboundTag": ["$in_tag"],
  "outboundTag": "$out_tag"
}
EOF
    )

    jq --argjson r "$rule_json" '. += [$r]' "$ROUTING_DB" > "${ROUTING_DB}.tmp" && mv "${ROUTING_DB}.tmp" "$ROUTING_DB"
    echo -e "${GREEN}[THÀNH CÔNG] Đã lưu liên kết định tuyến vào hệ thống.${NC}"
    
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

edit_routing() {
    clear
    echo -e "${BLUE}=== SỬA ĐỔI QUY TẮC ĐỊNH TUYẾN ===${NC}"
    if ! list_routings; then
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..." && return
    fi
    echo ""
    read -p "Chọn số thứ tự dòng định tuyến cần sửa (Nhập 0 để dừng): " index
    [[ "$index" == "0" || -z "$index" ]] && return

    local real_idx=$((index - 1))
    local exist_check=$(jq --argjson idx "$real_idx" '.[$idx]' "$ROUTING_DB")
    if [ "$exist_check" == "null" ]; then
        echo -e "${RED}[LỖI] Số thứ tự lựa chọn không hợp lệ.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ..." && return
    fi

    read -p "Nhập lại tên nhãn nhận khách (Inbound Tag mới): " in_tag
    [ "$in_tag" == "0" ] && return
    read -p "Nhập lại tên nhãn đích ra (Outbound Tag mới): " out_tag
    [ "$out_tag" == "0" ] && return

    if [[ -z "$in_tag" || -z "$out_tag" ]]; then
        echo -e "${RED}[LỖI] Các trường dữ liệu định tuyến không được để trống.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ..." && return
    fi

    local check_out=$(jq --arg t "$out_tag" '.[] | select(.tag == $t)' "$OUTBOUND_DB")
    if [ -z "$check_out" ]; then
        echo -e "${RED}[LỖI] Nhãn Outbound '$out_tag' không hợp lệ.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ..." && return
    fi

    local rule_json=$(cat <<EOF
{
  "type": "field",
  "inboundTag": ["$in_tag"],
  "outboundTag": "$out_tag"
}
EOF
    )

    jq --argjson idx "$real_idx" --argjson r "$rule_json" '.[$idx] = $r' "$ROUTING_DB" > "${ROUTING_DB}.tmp" && mv "${ROUTING_DB}.tmp" "$ROUTING_DB"
    echo -e "${GREEN}[THÀNH CÔNG] Đã cập nhật bảng chuyển tiếp dữ liệu.${NC}"
    
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

delete_routing() {
    clear
    echo -e "${BLUE}=== XÓA QUY TẮC ĐỊNH TUYẾN ===${NC}"
    if ! list_routings; then
        read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..." && return
    fi
    echo ""
    read -p "Chọn số thứ tự dòng định tuyến muốn xóa (Nhập 0 để dừng): " index
    [[ "$index" == "0" || -z "$index" ]] && return

    local real_idx=$((index - 1))
    local exist_check=$(jq --argjson idx "$real_idx" '.[$idx]' "$ROUTING_DB")
    if [ "$exist_check" == "null" ]; then
        echo -e "${RED}[LỖI] Chỉ mục chọn nằm ngoài phạm vi danh sách.${NC}"
        read -n 1 -s -r -p "Bấm phím bất kỳ..." && return
    fi

    jq --argjson idx "$real_idx" 'del(.[$idx])' "$ROUTING_DB" > "${ROUTING_DB}.tmp" && mv "${ROUTING_DB}.tmp" "$ROUTING_DB"
    echo -e "${GREEN}[THÀNH CÔNG] Đã loại bỏ quy tắc định tuyến khỏi hàng đợi.${NC}"
    
    apply_config
    read -n 1 -s -r -p "Bấm phím bất kỳ để tiếp tục..."
}

menu_routing() {
    while true; do
        clear
        echo -e "${BLUE}=======================================${NC}"
        echo -e "${YELLOW}      MỤC CHỈNH SỬA ROUTING RULES      ${NC}"
        echo -e "${BLUE}=======================================${NC}"
        echo -e "1. Thêm quy tắc định tuyến mới"
        echo -e "2. Sửa quy tắc định tuyến sẵn có"
        echo -e "3. Xóa bỏ quy tắc định tuyến"
        echo -e "0. Quay lại Menu chính"
        echo -e "${BLUE}=======================================${NC}"
        echo ""
        read -p "Nhập thao tác: " opt
        case $opt in
            1) add_routing ;;
            2) edit_routing ;;
            3) delete_routing ;;
            0) break ;;
            *) echo -e "${RED}Lựa chọn không hợp lệ.${NC}" && sleep 1 ;;
        esac
    done
}

# =================================================================
# TRÌNH ĐIỀU HƯỚNG GIAO DIỆN GỐC (MAIN ENTRY)
# =================================================================
while true; do
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${CYAN}    HỆ THỐNG QUẢN LÝ ĐỊNH TUYẾN ĐA NODE   ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo -e "1. Cài đặt liên kết kết nối Node ra (Outbounds)"
    echo -e "2. Cài đặt bảng định tuyến bắc cầu (Routing)"
    echo -e "0. Thoát ra ngoài Menu điều khiển hệ thống"
    echo -e "${BLUE}=======================================${NC}"
    echo ""
    read -p "Vui lòng nhập số lựa chọn của bạn: " main_opt
    case $main_opt in
        1) menu_outbounds ;;
        2) menu_routing ;;
        0) echo "Đang quay trở về hệ thống chính..." && exit 0 ;;
        *) echo -e "${RED}Lựa chọn không hợp lệ.${NC}" && sleep 1 ;;
    esac
done