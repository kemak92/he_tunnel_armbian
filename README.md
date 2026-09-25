# HE Tunnel FRP for Armbian (Standalone Service)

Dự án chuyển đổi Home Assistant Add-on (`hass_addon_frp`) thành một **Standalone Service** chạy độc lập trên hệ điều hành **Armbian / Debian / Ubuntu** mà không cần cài đặt Home Assistant OS.

Ứng dụng đi kèm giao diện **Web UI** quản lý đơn giản giúp bạn dễ dàng cấu hình thông số kết nối FRP Server trực tiếp trên trình duyệt.

---

## ⚡ Cài đặt nhanh (Quick Install)

Chạy lệnh duy nhất sau trên Terminal của Armbian bằng quyền `root` hoặc `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/kemak92/he_tunnel_armbian/main/install.sh | sudo bash
