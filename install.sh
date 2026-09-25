sudo bash -c '
# 1. Cài đặt các gói phụ thuộc hệ thống
apt update && apt install -y git nodejs npm

# 2. Xóa thư mục cũ (nếu có) và clone repo từ GitHub
rm -rf /opt/he_tunnel_frp
git clone https://github.com/kemak92/hass_addon_frp.git /opt/he_tunnel_frp
cd /opt/he_tunnel_frp

# 3. Tạo package.json với các dependency cần thiết
cat << "EOF" > package.json
{
  "name": "he-tunnel-frp",
  "version": "1.0.0",
  "type": "module",
  "main": "agent.mjs",
  "dependencies": {
    "express": "^4.18.2",
    "ws": "^8.13.0",
    "yaml": "^2.3.1"
  }
}
EOF

# 4. Tạo file cấu hình mặc định options.json
cat << "EOF" > options.json
{
  "server_addr": "127.0.0.1",
  "server_port": 7000,
  "token": "",
  "client_id": "armbian_node",
  "target_ip": "127.0.0.1",
  "target_port": 80,
  "log_level": "info"
}
EOF

# 5. Tạo file Web UI phục vụ giao diện cấu hình
cat << "EOF" > web_ui.mjs
import express from "express";
import fs from "fs";
import { exec } from "child_process";

const app = express();
const PORT = 8080;
const CONFIG_PATH = "/opt/he_tunnel_frp/options.json";

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

app.get("/", (req, res) => {
  let config = {};
  if (fs.existsSync(CONFIG_PATH)) {
    try { config = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8")); } catch(e){}
  }

  res.send(`
    <!DOCTYPE html>
    <html>
    <head>
      <title>FRP Tunnel Config</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f4f6f9; }
        .card { max-width: 480px; margin: 0 auto; padding: 20px; background: #fff; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        h2 { text-align: center; color: #333; margin-top: 0; }
        label { font-weight: bold; display: block; margin-top: 12px; font-size: 14px; }
        input { width: 100%; padding: 8px; margin-top: 4px; box-sizing: border-box; border: 1px solid #ccc; border-radius: 4px; }
        button { margin-top: 20px; width: 100%; padding: 10px; background: #007bff; color: #fff; border: none; border-radius: 4px; font-size: 16px; cursor: pointer; font-weight: bold; }
        button:hover { background: #0056b3; }
      </style>
    </head>
    <body>
      <div class="card">
        <h2>Cấu hình FRP Tunnel</h2>
        <form action="/save" method="POST">
          <label>FRP Server Address:</label>
          <input type="text" name="server_addr" value="${config.server_addr || ""}" required>

          <label>FRP Server Port:</label>
          <input type="number" name="server_port" value="${config.server_port || 7000}" required>

          <label>Token / Key:</label>
          <input type="password" name="token" value="${config.token || ""}">

          <label>Client ID:</label>
          <input type="text" name="client_id" value="${config.client_id || "armbian_node"}" required>

          <label>Target IP (Local):</label>
          <input type="text" name="target_ip" value="${config.target_ip || "127.0.0.1"}" required>

          <label>Target Port (Local):</label>
          <input type="number" name="target_port" value="${config.target_port || 80}" required>

          <button type="submit">Lưu & Khởi động lại Service</button>
        </form>
      </div>
    </body>
    </html>
  `);
});

app.post("/save", (req, res) => {
  const newConfig = {
    server_addr: req.body.server_addr,
    server_port: parseInt(req.body.server_port),
    token: req.body.token,
    client_id: req.body.client_id,
    target_ip: req.body.target_ip,
    target_port: parseInt(req.body.target_port),
    log_level: "info"
  };

  fs.writeFileSync(CONFIG_PATH, JSON.stringify(newConfig, null, 2));

  exec("systemctl restart he-tunnel-frp", (error) => {
    if (error) {
      return res.send(`<h3>Đã lưu file nhưng lỗi khi restart: ${error.message}</h3><a href="/">Quay lại</a>`);
    }
    res.send(`<h3>Lưu thành công! Service đang khởi động lại...</h3><script>setTimeout(() => location.href="/", 3000);</script>`);
  });
});

app.listen(PORT, () => {
  console.log("Web UI running on port " + PORT);
});
EOF

# 6. Nhúng Web UI vào file agent.mjs
if [ -f "agent.mjs" ]; then
  if ! grep -q "web_ui.mjs" agent.mjs; then
    sed -i '1s/^/import ".\/web_ui.mjs";\n/' agent.mjs
  fi
fi

# 7. Cài đặt các gói Node.js
npm install

# 8. Tạo systemd service
cat << "EOF" > /etc/systemd/system/he-tunnel-frp.service
[Unit]
Description=HE Tunnel FRP Client Standalone Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/he_tunnel_frp
ExecStart=/usr/bin/node /opt/he_tunnel_frp/agent.mjs --config /opt/he_tunnel_frp/options.json
Restart=always
RestartSec=5s
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# 9. Kích hoạt và chạy service
systemctl daemon-reload
systemctl enable he-tunnel-frp
systemctl restart he-tunnel-frp

echo "=========================================="
echo " CÀI ĐẶT THÀNH CÔNG TỪ GITHUB!"
echo " Mở trình duyệt truy cập Web UI tại: http://$(hostname -I | awk "{print \$1}"):8080"
echo "=========================================="
'
