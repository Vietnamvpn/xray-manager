# Xray Manager

Một bộ script nhỏ để cài đặt, cấu hình và quản lý Xray (VLESS / VMESS / TROJAN) trên server Linux. Bao gồm các template cấu hình, script quản lý node, SSL và đồng bộ API.

**Yêu cầu hệ thống**
- Hệ điều hành: Debian/Ubuntu/CentOS (Linux)
- Quyền: root hoặc sudo
- Công cụ: bash, curl, systemd

**Cách cài đặt nhanh**
Chạy script cài đặt chính (từ file local):

```bash
sudo bash install.sh
```

Hoặc dùng lệnh 1 dòng tải và chạy trực tiếp từ Github (nhanh nhưng cẩn trọng):

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Vietnamvpn/xray-manager/main/install.sh)
```

Hoặc cập nhật/thực thi script từng phần:

```bash
bash scripts/update.sh
bash scripts/api_sync.sh
```

**Cấu trúc dự án**
- [install.sh](install.sh): Script cài đặt chính
- [main.sh](main.sh): Tập lệnh chính (entrypoint)
- [config.conf](config.conf): Cấu hình chung
- [catruc.txt](catruc.txt): Ví dụ/ghi chú lịch ca
- Thư mục [scripts](scripts): Các script trợ giúp
	- [scripts/api_sync.sh](scripts/api_sync.sh): Đồng bộ API
	- [scripts/node_manager.sh](scripts/node_manager.sh): Quản lý node
	- [scripts/ssl_manager.sh](scripts/ssl_manager.sh): Quản lý SSL/Chứng chỉ
	- [scripts/update.sh](scripts/update.sh): Cập nhật hệ thống/script
	- [scripts/user_manager.sh](scripts/user_manager.sh): Quản lý người dùng
	- [scripts/utils.sh](scripts/utils.sh): Hàm tiện ích chung
- Thư mục [templates](templates): Mẫu cấu hình Xray
	- [templates/xray.service](templates/xray.service)
	- [templates/vmess/vmess-ws-tls.json](templates/vmess/vmess-ws-tls.json)
	- [templates/vless/vless-ws-tls.json](templates/vless/vless-ws-tls.json)
	- [templates/trojan/trojan-ws-tls.json](templates/trojan/trojan-ws-tls.json)

**Hướng dẫn sử dụng nhanh**
- Cài đặt: `sudo bash install.sh`
- Cập nhật script: `bash scripts/update.sh`
- Đồng bộ API: `bash scripts/api_sync.sh`
- Quản lý node: `bash scripts/node_manager.sh` (xem help trong script)
- Quản lý user: `bash scripts/user_manager.sh` (xem help trong script)
- Cấu hình dịch vụ systemd: copy mẫu từ [templates/xray.service](templates/xray.service) và reload systemd

**Hướng dẫn thao tác Menu**
- Mở menu quản lý bằng lệnh `vvc-xr` (hoặc `bash main.sh`).
- Nhập số tương ứng rồi nhấn Enter để chọn mục.
- Sau mỗi thao tác, thường nhấn một phím bất kỳ để quay về menu chính.

- `1. Quản Lý Người Dùng`: chạy `scripts/user_manager.sh` (thêm/sửa/xóa tài khoản).
- `2. Quản Lý Node Sever`: chạy `scripts/node_manager.sh` để quản lý các node Xray.
- `3. Quản Lý SSL`: chạy `scripts/ssl_manager.sh` để cấp/đổi/chỉnh sửa chứng chỉ.
- `4. Đồng Bộ API`: chạy `scripts/api_sync.sh` để đồng bộ dữ liệu với API từ xa.
- `5. Cập Nhật Mã Nguồn`: chạy `scripts/update.sh` để cập nhật repository và script.
- `6. Xóa Tất Cả Mã Nguồn`: hành động nguy hiểm, sẽ xóa toàn bộ dữ liệu và mã nguồn (yêu cầu xác nhận).
- `7. Điều Khiển Xray`: có menu con để Khởi chạy / Tắt / Khởi động lại / Xóa Xray core.
- `8. Bật/Tắt BBR`: bật hoặc tắt BBR (sửa `sysctl.conf`).
- `9. Tạo Bộ Nhớ Ảo Swap`: nhập kích thước (ví dụ `1G`) để tạo swapfile.
- `10. Xem Trạng Thái VPS`: hiển thị `free -h`, `df -h`, `uptime`.
- `11. Xem Log Xray Trực Tiếp`: mở `journalctl -u xray -f` (dùng Ctrl+C để thoát).
- `0. Thoát`: đóng menu.

Lưu ý: một số mục sẽ gọi script trong thư mục `scripts/`; nếu module tương ứng chưa tồn tại, menu sẽ báo và quay lại.

**Mẹo**
- Kiểm tra log khi gặp lỗi: `journalctl -u xray -f`
- Kiểm tra quyền và SELinux nếu gặp vấn đề trên CentOS

---

Tập tin trong repository này là tập lệnh tiện ích; sử dụng thận trọng trên server production và luôn sao lưu cấu hình trước khi thay đổi.

