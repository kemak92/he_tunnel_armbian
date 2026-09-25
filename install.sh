#!/usr/bin/env bash
set -euo pipefail

# 1. Xác định User thực tế thực thi lệnh (tránh gán nhầm cho root nếu dùng sudo)
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
WORK_DIR="/opt/he_tunnel_frp"

echo "=================================================="
echo " HE Tunnel FRP Standalone Installer"
echo " User cài đặt: $TARGET_USER ($TARGET_GROUP)"
echo " Thư mục: $WORK_DIR"
echo "=================================================="

# 2. Tạo thư mục và cấp quyền cho User
sudo mkdir -p "$WORK_DIR"
sudo chown -R "$TARGET_USER:$TARGET_GROUP" "$WORK_DIR"

# 3. Tải/Khởi tạo các file cấu hình cơ bản (nếu chưa có)
if [ ! -f "$WORK_DIR/options.json" ]; then
  cat << 'EOF' > "$WORK_DIR/options.json"
{
  "api_base": "https://heungelectric.com",
  "email": "user@example.com",
  "otp": "123456",
  "subdomain": "mysubdomain",
  "local_host": "127.0.0.1",
  "local_port": 8123,
  "force_reset": false,
  "agent_enabled": false,
  "agent_port": 8787,
  "agent_allow_restart": false
}
EOF
  chown "$TARGET_USER:$TARGET_GROUP" "$WORK_DIR/options.json"
fi

# 4. Tải/Cập nhật script thực thi run_standalone.sh
cat << 'EOF' > "$WORK_DIR/run_standalone.sh"
#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="/opt/he_tunnel_frp"
CONFIG_FILE="$WORK_DIR/options.json"
DATA_FILE="$WORK_DIR/tunnel_credentials.json"
DEVICE_FILE="$WORK_DIR/device.json"
LOG_FILE="$WORK_DIR/he_tunnel_frp.log"
TMP_FRPC="$WORK_DIR/frpc.toml"

mkdir -p "$WORK_DIR"

log() { echo "[$(date -Is)] [INFO] $*"; echo "$(date -Is) INFO $*" >> "$LOG_FILE"; }
err() { echo "[$(date -Is)] [ERROR] $*"; echo "$(date -Is) ERROR $*" >> "$LOG_FILE"; }

# 0. Khởi chạy Web UI port 8080
if ! pgrep -f "web_ui.mjs" > /dev/null 2>&1; then
  if [ -f "$WORK_DIR/web_ui.mjs" ]; then
    log "Đang khởi chạy Web UI port 8080..."
    node "$WORK_DIR/web_ui.mjs" >> "$LOG_FILE" 2>&1 &
  fi
fi

redact() { 
  sed -E 's/(auth\.token[[:space:]]*=[[:space:]]*")[^"]+/\1***REDACTED***/Ig; s/(metadatas\.token[[:space:]]*=[[:space:]]*")[^"]+/\1***REDACTED***/Ig; s/[A-Fa-f0-9]{32,}/***REDACTED***/g; s/[A-Za-z0-9_-]{40,}/***REDACTED***/g'; 
}

cfg() {
  key="$1"
  default="${2:-}"
  if [ -f "$CONFIG_FILE" ]; then
    val=$(jq -r ".$key // empty" "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$val" ] && [ "$val" != "null" ]; then echo "$val"; return; fi
  fi
  echo "$default"
}

# 1. Đọc Cấu hình
api_base=$(cfg 'api_base' 'https://heungelectric.com')
email=$(cfg 'email' | tr '[:upper:]' '[:lower:]')
otp=$(cfg 'otp')
subdomain=$(cfg 'subdomain' | tr '[:upper:]' '[:lower:]')
local_host=$(cfg 'local_host' '127.0.0.1')
local_port=$(cfg 'local_port' '8123')
force_reset=$(cfg 'force_reset' 'false')
agent_enabled=$(cfg 'agent_enabled' 'false')
agent_port=$(cfg 'agent_port' '8787')
agent_allow_restart=$(cfg 'agent_allow_restart' 'false')

FRPC_BIN="/usr/local/bin/frpc"
if [ ! -f "$FRPC_BIN" ]; then FRPC_BIN="$WORK_DIR/frpc"; fi
if [ ! -f "$FRPC_BIN" ]; then err "Không tìm thấy file thực thi frpc"; exit 1; fi

if [ -z "$api_base" ] || [ -z "$email" ] || [ -z "$subdomain" ]; then
  err "api_base, email và subdomain là bắt buộc trong options.json"
  exit 1
fi

# 2. Định danh thiết bị
if [ ! -f "$DEVICE_FILE" ]; then
  addon_instance_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "standalone-$(date +%s)")
  addon_client_name=$(hostname)
  jq -n \
    --arg client_type "ha_addon" \
    --arg client_instance_id "$addon_instance_id" \
    --arg client_name "$addon_client_name" \
    --arg created_at "$(date -Is)" \
    '{client_type:$client_type,client_instance_id:$client_instance_id,client_name:$client_name,created_at:$created_at}' > "$DEVICE_FILE"
fi
addon_instance_id=$(jq -r '.client_instance_id // ""' "$DEVICE_FILE")
addon_client_name=$(jq -r '.client_name // ""' "$DEVICE_FILE")

urlenc() { jq -nr --arg v "$1" '$v|@uri'; }

sync_runtime_config() {
  session_token="$1"
  [ -z "$session_token" ] && return 1
  encoded_id=$(urlenc "$addon_instance_id")
  encoded_name=$(urlenc "$addon_client_name")
  http_code=$(curl -sS -w '%{http_code}' -o "$WORK_DIR/sync-config.tmp.json" \
    -H "authorization: Bearer $session_token" \
    "$api_base/api/v1/addon/sync-config?client_instance_id=$encoded_id&client_name=$encoded_name" || true)
  log "Sync-config HTTP status $http_code"
  [ "$http_code" = "200" ] && jq -e '.frpc_toml' "$WORK_DIR/sync-config.tmp.json" >/dev/null
}

# 3. Đồng bộ & Provision
needs_provision="true"
if [ -f "$DATA_FILE" ] && [ "$force_reset" != "true" ]; then
  cached_email=$(jq -r '.requested.email // ""' "$DATA_FILE" 2>/dev/null || true)
  cached_subdomain=$(jq -r '.requested.subdomain // ""' "$DATA_FILE" 2>/dev/null || true)
  cached_session=$(jq -r '.session_token // ""' "$DATA_FILE" 2>/dev/null || true)
  cached_toml=$(jq -r '.frpc_toml // ""' "$DATA_FILE" 2>/dev/null || true)

  if [ "$cached_email" = "$email" ] && [ "$cached_subdomain" = "$subdomain" ] && [ -n "$cached_toml" ]; then
    needs_provision="false"
    log "Thực hiện Sync cấu hình từ Cloud cho subdomain: $subdomain"
    if sync_runtime_config "$cached_session"; then
      jq -r '.frpc_toml' "$WORK_DIR/sync-config.tmp.json" > "$TMP_FRPC"
      jq --arg session_token "$cached_session" --arg email "$email" --arg subdomain "$subdomain" \
         ' . + {session_token:$session_token,requested:{email:$email,subdomain:$subdomain}}' \
         "$WORK_DIR/sync-config.tmp.json" > "$DATA_FILE"
      rm -f "$WORK_DIR/sync-config.tmp.json"
    else
      if [ -z "$otp" ]; then err "Sync thất bại và thiếu OTP để provision lại"; exit 1; fi
      needs_provision="true"
    fi
  fi
fi

if [ "$needs_provision" = "true" ]; then
  if [ -z "$otp" ]; then err "Cần OTP cho lần kích hoạt đầu tiên hoặc khi force_reset"; exit 1; fi
  log "Đang gửi yêu cầu Provision Tunnel tới $api_base..."
  body=$(jq -nc \
    --arg email "$email" \
    --arg otp "$otp" \
    --arg subdomain "$subdomain" \
    --arg local_host "$local_host" \
    --arg client_type "ha_addon" \
    --arg client_instance_id "$addon_instance_id" \
    --arg client_name "$addon_client_name" \
    --argjson local_port "$local_port" \
    --argjson force_reset false \
    '{email:$email,otp:$otp,subdomain:$subdomain,local_host:$local_host,local_port:$local_port,force_reset:$force_reset,client_type:$client_type,client_instance_id:$client_instance_id,client_name:$client_name}')
  
  http_code=$(curl -sS -w '%{http_code}' -o "$WORK_DIR/provision.tmp.json" -X POST "$api_base/api/v1/addon/provision" \
    -H 'content-type: application/json' --data "$body" || true)
  
  log "Provision HTTP status $http_code"
  if [ "$http_code" != "200" ]; then err "Provision thất bại (HTTP $http_code)"; exit 1; fi
  
  provision_session=$(jq -r '.session_token // ""' "$WORK_DIR/provision.tmp.json")
  if sync_runtime_config "$provision_session"; then
    jq -r '.frpc_toml' "$WORK_DIR/sync-config.tmp.json" > "$TMP_FRPC"
    cp "$WORK_DIR/sync-config.tmp.json" "$WORK_DIR/provision.tmp.json"
    rm -f "$WORK_DIR/sync-config.tmp.json"
  else
    jq -r '.frpc_toml' "$WORK_DIR/provision.tmp.json" > "$TMP_FRPC"
  fi
  
  jq --arg session_token "$provision_session" --arg email "$email" --arg subdomain "$subdomain" \
     '. + {session_token:$session_token,requested:{email:$email,subdomain:$subdomain}}' \
     "$WORK_DIR/provision.tmp.json" > "$DATA_FILE"
  rm -f "$WORK_DIR/provision.tmp.json"

  if [ -f "$CONFIG_FILE" ]; then
    jq '.force_reset = false' "$CONFIG_FILE" > "$WORK_DIR/options.json.tmp" && mv "$WORK_DIR/options.json.tmp" "$CONFIG_FILE"
  fi
fi

# 4. Agent & Router
server_agent_route_enabled=$(jq -r '.runtime.agent_route_enabled // "false"' "$DATA_FILE" 2>/dev/null || echo "false")
server_agent_key=$(jq -r '.agent_config.verify_public_key_base64 // ""' "$DATA_FILE" 2>/dev/null || echo "")

agent_started="false"
if [ "$agent_enabled" = "true" ] || [ -n "$server_agent_key" ]; then
  if command -v node >/dev/null 2>&1 && [ -f "$WORK_DIR/agent.mjs" ]; then
    log "Đang khởi chạy HE HA Agent trên port $agent_port..."
    HE_AGENT_HOST="127.0.0.1" \
    HE_AGENT_PORT="$agent_port" \
    HE_AGENT_VERIFY_PUBLIC_KEY_BASE64="$server_agent_key" \
    HE_AGENT_ALLOW_AUTO_RESTART="$agent_allow_restart" \
    HE_AGENT_CONFIG_DIR="$WORK_DIR" \
    HE_AGENT_DATA_DIR="$WORK_DIR" \
      node "$WORK_DIR/agent.mjs" >> "$LOG_FILE" 2>&1 &
    sleep 1
    agent_started="true"
  fi
fi

if [ "$agent_started" = "true" ] && [ "$server_agent_route_enabled" = "true" ] && [ -f "$WORK_DIR/agent_router.mjs" ]; then
  server_agent_router_port=$(jq -r '.runtime.agent_router_port // "18080"' "$DATA_FILE")
  log "Đang khởi chạy HE Agent Router trên port $server_agent_router_port..."
  HE_AGENT_ROUTER_HOST="127.0.0.1" \
  HE_AGENT_ROUTER_PORT="$server_agent_router_port" \
  HE_AGENT_ROUTER_HA_HOST="$local_host" \
  HE_AGENT_ROUTER_HA_PORT="$local_port" \
  HE_AGENT_ROUTER_AGENT_HOST="127.0.0.1" \
  HE_AGENT_ROUTER_AGENT_PORT="$agent_port" \
  HE_AGENT_ROUTER_PATH_PREFIX="/agent/v1" \
  HE_AGENT_ROUTER_FORWARDED_PROTO="https" \
    node "$WORK_DIR/agent_router.mjs" >> "$LOG_FILE" 2>&1 &
  sleep 1
  
  sed -i -E 's/^localIP = ".*"/localIP = "127.0.0.1"/' "$TMP_FRPC"
  sed -i -E "s/^localPort = [0-9]+/localPort = $server_agent_router_port/" "$TMP_FRPC"
  log "Agent Router đã kích hoạt; FRPC target đổi thành 127.0.0.1:$server_agent_router_port"
fi

# 5. Khởi chạy FRPC Loop
log "Đang bắt đầu tiến trình FRPC..."
chmod +x "$FRPC_BIN" 2>/dev/null || true

while :; do
  set +e
  "$FRPC_BIN" run -c "$TMP_FRPC" 2>&1 | redact | while IFS= read -r line; do
    echo "[FRPC] $line"
    echo "$(date -Is) [FRPC] $line" >> "$LOG_FILE"
  done
  set -e
  log "FRPC ngắt kết nối. Đang thử lại sau 5 giây..."
  sleep 5
done
EOF

chmod +x "$WORK_DIR/run_standalone.sh"
chown -R "$TARGET_USER:$TARGET_GROUP" "$WORK_DIR"

# 5. Tạo Service Systemd cấu hình động theo User
cat << EOF | sudo tee /etc/systemd/system/he-tunnel-frp.service > /dev/null
[Unit]
Description=HE Tunnel FRP Client Standalone Service
After=network.target

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_GROUP
WorkingDirectory=$WORK_DIR
ExecStart=/bin/bash $WORK_DIR/run_standalone.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 6. Kích hoạt và khởi động Dịch vụ
sudo systemctl daemon-reload
sudo systemctl enable he-tunnel-frp
sudo systemctl restart he-tunnel-frp

echo "=================================================="
echo " Cài đặt hoàn tất! Service đã được kích hoạt."
echo " Kiểm tra log bằng lệnh: sudo journalctl -u he-tunnel-frp -f"
echo "=================================================="
