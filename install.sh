#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HE Tunnel FRP Standalone – 1 lệnh cài
# Clone hass_addon_frp → copy agent → tải frpc →
# Web UI dark + Login + đổi pass → systemd → chạy
# ============================================================

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
WORK_DIR="/opt/he_tunnel_frp"
ADDON_REPO="https://github.com/kemak92/hass_addon_frp.git"
FRP_VERSION="0.69.0"
TMP_CLONE="/tmp/hass_addon_frp_clone_$$"

echo "=================================================="
echo " HE Tunnel FRP Standalone Installer"
echo " User: $TARGET_USER ($TARGET_GROUP)"
echo " Dir : $WORK_DIR"
echo "=================================================="

# --- 1. Dependency ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl jq ca-certificates nodejs npm tar gzip \
  netcat-openbsd dnsutils 2>/dev/null \
  || apt-get install -y git curl jq ca-certificates nodejs npm tar gzip \
       netcat-traditional dnsutils

NODE_VER=$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo 0)
if [ "$NODE_VER" -lt 18 ] 2>/dev/null; then
  echo "[WARN] Node < 18 → cài Node 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

# --- 2. Thư mục ---
mkdir -p "$WORK_DIR"
chown -R "$TARGET_USER:$TARGET_GROUP" "$WORK_DIR"

# --- 3. Clone add-on + copy ---
echo "[*] Clone $ADDON_REPO ..."
rm -rf "$TMP_CLONE"
git clone --depth 1 "$ADDON_REPO" "$TMP_CLONE"
cp -f "$TMP_CLONE/he_tunnel_frp/agent.mjs"        "$WORK_DIR/agent.mjs"
cp -f "$TMP_CLONE/he_tunnel_frp/agent_router.mjs" "$WORK_DIR/agent_router.mjs"
cp -f "$TMP_CLONE/he_tunnel_frp/run.sh"           "$WORK_DIR/run.sh.addon" 2>/dev/null || true
rm -rf "$TMP_CLONE"
echo "[+] agent.mjs + agent_router.mjs"

# --- 4. frpc ---
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  FRP_ARCH=amd64 ;;
  aarch64) FRP_ARCH=arm64 ;;
  armv7l)  FRP_ARCH=arm   ;;
  *) echo "[ERROR] Arch không hỗ trợ: $ARCH"; exit 1 ;;
esac

FRPC_BIN="$WORK_DIR/frpc"
if [ ! -x "$FRPC_BIN" ] && [ ! -x /usr/local/bin/frpc ]; then
  echo "[*] Tải frpc v${FRP_VERSION} (${FRP_ARCH})..."
  FRP_ASSET="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
  curl -fsSL -o /tmp/frp.tar.gz \
    "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_ASSET}"
  mkdir -p /tmp/frp_extract
  tar -xzf /tmp/frp.tar.gz -C /tmp/frp_extract --strip-components=1
  install -m 0755 /tmp/frp_extract/frpc "$FRPC_BIN"
  install -m 0755 /tmp/frp_extract/frpc /usr/local/bin/frpc
  rm -rf /tmp/frp.tar.gz /tmp/frp_extract
  echo "[+] frpc sẵn sàng"
else
  echo "[+] frpc đã có"
  [ -x /usr/local/bin/frpc ] || ln -sf "$FRPC_BIN" /usr/local/bin/frpc 2>/dev/null || true
fi

# --- 5. options.json ---
if [ ! -f "$WORK_DIR/options.json" ]; then
  cat > "$WORK_DIR/options.json" << 'EOF'
{
  "api_base": "https://heungelectric.com",
  "email": "",
  "otp": "",
  "subdomain": "",
  "local_host": "127.0.0.1",
  "local_port": 8123,
  "force_reset": false,
  "agent_enabled": false,
  "agent_port": 8787,
  "agent_allow_restart": false,
  "web_ui_user": "root",
  "web_ui_password": "admin"
}
EOF
  echo "[+] options.json (root / admin)"
else
  if ! jq -e '.web_ui_user' "$WORK_DIR/options.json" >/dev/null 2>&1; then
    jq '. + {web_ui_user:"root",web_ui_password:"admin"}' "$WORK_DIR/options.json" > /tmp/o.json
    mv /tmp/o.json "$WORK_DIR/options.json"
  fi
fi

# --- 6. Web UI dark + login + đổi pass ---
cat > "$WORK_DIR/web_ui.mjs" << 'WEBUI_EOF'
import http from "http";
import fs from "fs";
import path from "path";
import crypto from "crypto";
import { exec } from "child_process";

const WORK_DIR = "/opt/he_tunnel_frp";
const CONFIG_FILE = path.join(WORK_DIR, "options.json");
const PORT = 8080;
const sessions = new Map();

function parseCookies(req) {
  const list = {};
  const rc = req.headers.cookie;
  if (rc) {
    rc.split(";").forEach((c) => {
      const p = c.split("=");
      list[p.shift().trim()] = decodeURI(p.join("="));
    });
  }
  return list;
}
function readConfig() {
  try {
    if (fs.existsSync(CONFIG_FILE)) return JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
  } catch (e) {}
  return {};
}
function writeConfig(data) {
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(data, null, 2), "utf8");
}
function isAuthenticated(req) {
  const sid = parseCookies(req).session_id;
  if (!sid || !sessions.has(sid)) return false;
  const s = sessions.get(sid);
  if (Date.now() > s.expires) { sessions.delete(sid); return false; }
  return true;
}
function parseBody(req) {
  return new Promise((resolve) => {
    let body = "";
    req.on("data", (c) => (body += c.toString()));
    req.on("end", () => {
      const params = new URLSearchParams(body);
      const r = {};
      for (const [k, v] of params.entries()) r[k] = v;
      resolve(r);
    });
  });
}

const CSS = `
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
body{background:#0f0f0f;color:#e5e5e5;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.card{background:#1a1a1a;border-radius:16px;padding:28px 24px;width:100%;max-width:440px;box-shadow:0 8px 32px rgba(0,0,0,.5)}
h1{font-size:18px;font-weight:700;color:#fff}
label{display:block;font-size:13px;color:#a3a3a3;margin-bottom:6px;margin-top:14px}
label .req{color:#f87171}
input,select{width:100%;padding:12px 14px;background:#262626;border:1px solid #333;border-radius:10px;color:#fff;font-size:14px;outline:none}
input:focus,select:focus{border-color:#3b82f6}
button{width:100%;margin-top:24px;padding:14px;background:#2563eb;color:#fff;border:none;border-radius:10px;font-size:15px;font-weight:700;cursor:pointer}
button:hover{background:#1d4ed8}
.error{background:#450a0a;border:1px solid #7f1d1d;color:#fca5a5;padding:10px;border-radius:8px;font-size:13px;text-align:center;margin-bottom:12px}
.ok{background:#052e16;border:1px solid #14532d;color:#86efac;padding:10px;border-radius:8px;font-size:13px;text-align:center;margin-bottom:12px}
.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}
.logout{font-size:12px;color:#f87171;text-decoration:none;border:1px solid #7f1d1d;padding:4px 10px;border-radius:6px}
.logout:hover{background:#450a0a}
.sec{margin-top:20px;padding-top:16px;border-top:1px solid #333;font-size:12px;color:#737373;text-transform:uppercase;letter-spacing:.5px}
`;

function loginPage(err = "") {
  return `<!DOCTYPE html><html lang="vi"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HE Tunnel - Đăng nhập</title><style>${CSS}</style></head><body>
<div class="card">
  <h1 style="text-align:center;margin-bottom:24px">HE Tunnel FRP</h1>
  ${err ? `<div class="error">${err}</div>` : ""}
  <form method="POST" action="/login">
    <label>Tài khoản</label>
    <input name="username" placeholder="root" required autofocus>
    <label>Mật khẩu</label>
    <input type="password" name="password" placeholder="••••••••" required>
    <button type="submit">ĐĂNG NHẬP</button>
  </form>
</div></body></html>`;
}

function formPage(cfg, msg = "") {
  const frFalse = cfg.force_reset === false || cfg.force_reset === "false" || !cfg.force_reset;
  return `<!DOCTYPE html><html lang="vi"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HE Tunnel FRP - Tùy chọn</title><style>${CSS}</style></head><body>
<div class="card">
  <div class="top">
    <h1>HE Tunnel FRP - Tùy chọn</h1>
    <a class="logout" href="/logout">Thoát</a>
  </div>
  ${msg ? `<div class="ok">${msg}</div>` : ""}
  <form method="POST" action="/save">
    <label>api_base <span class="req">*</span></label>
    <input name="api_base" value="${cfg.api_base || "https://heungelectric.com"}" required>
    <label>email <span class="req">*</span></label>
    <input type="email" name="email" value="${cfg.email || ""}" required>
    <label>otp <span class="req">*</span></label>
    <input name="otp" value="${cfg.otp || ""}" required>
    <label>subdomain <span class="req">*</span></label>
    <input name="subdomain" value="${cfg.subdomain || ""}" required>
    <label>local_host <span class="req">*</span></label>
    <input name="local_host" value="${cfg.local_host || "127.0.0.1"}" required>
    <label>local_port <span class="req">*</span></label>
    <input type="number" name="local_port" value="${cfg.local_port || 8123}" required>
    <label>force_reset</label>
    <select name="force_reset">
      <option value="false" ${frFalse ? "selected" : ""}>Không</option>
      <option value="true" ${!frFalse ? "selected" : ""}>Có (Reset OTP)</option>
    </select>
    <div class="sec">Bảo mật Web UI (đổi mật khẩu đăng nhập)</div>
    <label>web_ui_user</label>
    <input name="web_ui_user" value="${cfg.web_ui_user || "root"}">
    <label>web_ui_password</label>
    <input type="password" name="web_ui_password" value="${cfg.web_ui_password || "admin"}" placeholder="Mật khẩu mới">
    <button type="submit">LƯU CẤU HÌNH</button>
  </form>
</div></body></html>`;
}

const server = http.createServer(async (req, res) => {
  const url = (req.url || "/").split("?")[0];

  if (url === "/login") {
    if (req.method === "GET") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(loginPage());
    }
    if (req.method === "POST") {
      const body = await parseBody(req);
      const cfg = readConfig();
      const user = cfg.web_ui_user || "root";
      const pass = cfg.web_ui_password || "admin";
      const okU = body.username === user || body.username === "root" || body.username === "admin";
      if (okU && body.password === pass) {
        const sid = crypto.randomBytes(24).toString("hex");
        sessions.set(sid, { expires: Date.now() + 7200000 });
        res.writeHead(302, {
          "Set-Cookie": `session_id=${sid}; HttpOnly; Path=/; Max-Age=7200`,
          Location: "/",
        });
        return res.end();
      }
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(loginPage("Sai tài khoản hoặc mật khẩu"));
    }
  }

  if (url === "/logout") {
    const sid = parseCookies(req).session_id;
    if (sid) sessions.delete(sid);
    res.writeHead(302, {
      "Set-Cookie": "session_id=; HttpOnly; Path=/; Max-Age=0",
      Location: "/login",
    });
    return res.end();
  }

  if (!isAuthenticated(req)) {
    res.writeHead(302, { Location: "/login" });
    return res.end();
  }

  if (url === "/" && req.method === "GET") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(formPage(readConfig()));
  }

  if (url === "/save" && req.method === "POST") {
    const body = await parseBody(req);
    const cur = readConfig();
    const next = {
      ...cur,
      api_base: (body.api_base || "https://heungelectric.com").trim(),
      email: (body.email || "").trim().toLowerCase(),
      otp: (body.otp || "").trim(),
      subdomain: (body.subdomain || "").trim().toLowerCase(),
      local_host: (body.local_host || "127.0.0.1").trim(),
      local_port: parseInt(body.local_port, 10) || 8123,
      force_reset: body.force_reset === "true",
      web_ui_user: (body.web_ui_user || "root").trim() || "root",
      web_ui_password: (body.web_ui_password || "admin").trim() || "admin",
    };
    writeConfig(next);
    exec("systemctl restart he-tunnel-frp", () => {});
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(formPage(next, "Đã lưu. Service đang khởi động lại…"));
  }

  res.writeHead(404);
  res.end("Not Found");
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[INFO] Web UI http://0.0.0.0:${PORT}`);
});
WEBUI_EOF
echo "[+] web_ui.mjs (dark + login + đổi pass)"

# --- 7. run_standalone.sh ---
cat > "$WORK_DIR/run_standalone.sh" << 'RUN_EOF'
#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="/opt/he_tunnel_frp"
CONFIG_FILE="$WORK_DIR/options.json"
DATA_FILE="$WORK_DIR/tunnel_credentials.json"
DEVICE_FILE="$WORK_DIR/device.json"
LOG_FILE="$WORK_DIR/he_tunnel_frp.log"
TMP_FRPC="$WORK_DIR/frpc.toml"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

log() { echo "[$(date -Is)] [INFO] $*"; echo "$(date -Is) INFO $*" >> "$LOG_FILE" 2>/dev/null || true; }
err() { echo "[$(date -Is)] [ERROR] $*"; echo "$(date -Is) ERROR $*" >> "$LOG_FILE" 2>/dev/null || true; }

if ! pgrep -f "web_ui.mjs" >/dev/null 2>&1; then
  [ -f "$WORK_DIR/web_ui.mjs" ] && {
    log "Web UI :8080"
    node "$WORK_DIR/web_ui.mjs" >> "$LOG_FILE" 2>&1 &
  }
fi

redact() {
  sed -E 's/(auth\.token[[:space:]]*=[[:space:]]*")[^"]+/\1***REDACTED***/Ig; s/(metadatas\.token[[:space:]]*=[[:space:]]*")[^"]+/\1***REDACTED***/Ig; s/[A-Fa-f0-9]{32,}/***REDACTED***/g; s/[A-Za-z0-9_-]{40,}/***REDACTED***/g'
}

cfg() {
  key="$1"; default="${2:-}"
  if [ -f "$CONFIG_FILE" ]; then
    val=$(jq -r ".$key // empty" "$CONFIG_FILE" 2>/dev/null || true)
    [ -n "$val" ] && [ "$val" != "null" ] && { echo "$val"; return; }
  fi
  echo "$default"
}

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
[ -x "$FRPC_BIN" ] || FRPC_BIN="$WORK_DIR/frpc"
[ -x "$FRPC_BIN" ] || { err "Thiếu frpc"; exit 1; }

if [ -z "$email" ] || [ -z "$subdomain" ]; then
  log "Chưa cấu hình. Mở http://IP:8080 (root/admin)"
  while true; do sleep 60; done
fi

if [ ! -f "$DEVICE_FILE" ]; then
  addon_instance_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "standalone-$(date +%s)")
  addon_client_name=$(hostname)
  jq -n --arg client_type "ha_addon" --arg client_instance_id "$addon_instance_id" \
    --arg client_name "$addon_client_name" --arg created_at "$(date -Is)" \
    '{client_type:$client_type,client_instance_id:$client_instance_id,client_name:$client_name,created_at:$created_at}' > "$DEVICE_FILE"
fi
addon_instance_id=$(jq -r '.client_instance_id // ""' "$DEVICE_FILE")
addon_client_name=$(jq -r '.client_name // ""' "$DEVICE_FILE")
[ -z "$addon_client_name" ] && addon_client_name=$(hostname)

urlenc() { jq -nr --arg v "$1" '$v|@uri'; }

sync_runtime_config() {
  session_token="$1"
  [ -z "$session_token" ] && return 1
  encoded_id=$(urlenc "$addon_instance_id")
  encoded_name=$(urlenc "$addon_client_name")
  http_code=$(curl -sS -w '%{http_code}' -o "$WORK_DIR/sync-config.tmp.json" \
    -H "authorization: Bearer $session_token" \
    "$api_base/api/v1/addon/sync-config?client_instance_id=$encoded_id&client_name=$encoded_name" || true)
  log "Sync-config HTTP $http_code"
  [ "$http_code" = "200" ] && jq -e '.frpc_toml' "$WORK_DIR/sync-config.tmp.json" >/dev/null
}

needs_provision="true"
if [ -f "$DATA_FILE" ] && [ "$force_reset" != "true" ]; then
  cached_email=$(jq -r '.requested.email // ""' "$DATA_FILE" 2>/dev/null || true)
  cached_subdomain=$(jq -r '.requested.subdomain // ""' "$DATA_FILE" 2>/dev/null || true)
  cached_session=$(jq -r '.session_token // ""' "$DATA_FILE" 2>/dev/null || true)
  cached_toml=$(jq -r '.frpc_toml // ""' "$DATA_FILE" 2>/dev/null || true)
  if [ "$cached_email" = "$email" ] && [ "$cached_subdomain" = "$subdomain" ] && [ -n "$cached_toml" ]; then
    needs_provision="false"
    log "Sync: $subdomain"
    if sync_runtime_config "$cached_session"; then
      jq -r '.frpc_toml' "$WORK_DIR/sync-config.tmp.json" > "$TMP_FRPC"
      jq --arg session_token "$cached_session" --arg email "$email" --arg subdomain "$subdomain" \
         --arg local_host "$local_host" --argjson local_port "$local_port" \
         '. + {session_token:$session_token,requested:{email:$email,subdomain:$subdomain,local_host:$local_host,local_port:$local_port}}' \
         "$WORK_DIR/sync-config.tmp.json" > "$DATA_FILE"
      rm -f "$WORK_DIR/sync-config.tmp.json"
    else
      [ -z "$otp" ] && { err "Sync fail + thiếu OTP"; exit 1; }
      needs_provision="true"
    fi
  fi
fi

if [ "$needs_provision" = "true" ]; then
  [ -z "$otp" ] && { err "Cần OTP lần đầu / force_reset"; exit 1; }
  log "Provision → $api_base"
  FR=$( [ "$force_reset" = "true" ] && echo true || echo false )
  body=$(jq -nc \
    --arg email "$email" --arg otp "$otp" --arg subdomain "$subdomain" \
    --arg local_host "$local_host" --arg client_type "ha_addon" \
    --arg client_instance_id "$addon_instance_id" --arg client_name "$addon_client_name" \
    --argjson local_port "$local_port" --argjson force_reset "$FR" \
    '{email:$email,otp:$otp,subdomain:$subdomain,local_host:$local_host,local_port:$local_port,force_reset:$force_reset,client_type:$client_type,client_instance_id:$client_instance_id,client_name:$client_name}')
  http_code=$(curl -sS -w '%{http_code}' -o "$WORK_DIR/provision.tmp.json" -X POST \
    "$api_base/api/v1/addon/provision" -H 'content-type: application/json' --data "$body" || true)
  log "Provision HTTP $http_code"
  [ "$http_code" != "200" ] && { err "Provision fail HTTP $http_code"; exit 1; }
  provision_session=$(jq -r '.session_token // ""' "$WORK_DIR/provision.tmp.json")
  if sync_runtime_config "$provision_session"; then
    jq -r '.frpc_toml' "$WORK_DIR/sync-config.tmp.json" > "$TMP_FRPC"
    cp "$WORK_DIR/sync-config.tmp.json" "$WORK_DIR/provision.tmp.json"
    rm -f "$WORK_DIR/sync-config.tmp.json"
  else
    jq -r '.frpc_toml' "$WORK_DIR/provision.tmp.json" > "$TMP_FRPC"
  fi
  jq --arg session_token "$provision_session" --arg email "$email" --arg subdomain "$subdomain" \
     --arg local_host "$local_host" --argjson local_port "$local_port" \
     '. + {session_token:$session_token,requested:{email:$email,subdomain:$subdomain,local_host:$local_host,local_port:$local_port}}' \
     "$WORK_DIR/provision.tmp.json" > "$DATA_FILE"
  rm -f "$WORK_DIR/provision.tmp.json"
  jq '.force_reset = false' "$CONFIG_FILE" > "$WORK_DIR/options.json.tmp" && mv "$WORK_DIR/options.json.tmp" "$CONFIG_FILE"
fi

server_agent_route_enabled=$(jq -r '.runtime.agent_route_enabled // "false"' "$DATA_FILE" 2>/dev/null || echo "false")
server_agent_key=$(jq -r '.agent_config.verify_public_key_base64 // ""' "$DATA_FILE" 2>/dev/null || echo "")
agent_started="false"
if [ "$agent_enabled" = "true" ] || [ -n "$server_agent_key" ]; then
  if command -v node >/dev/null && [ -f "$WORK_DIR/agent.mjs" ]; then
    log "Agent :$agent_port"
    HE_AGENT_HOST="127.0.0.1" HE_AGENT_PORT="$agent_port" \
    HE_AGENT_VERIFY_PUBLIC_KEY_BASE64="$server_agent_key" \
    HE_AGENT_ALLOW_AUTO_RESTART="$agent_allow_restart" \
    HE_AGENT_CONFIG_DIR="$WORK_DIR" HE_AGENT_DATA_DIR="$WORK_DIR" \
      node "$WORK_DIR/agent.mjs" >> "$LOG_FILE" 2>&1 &
    sleep 1
    agent_started="true"
  fi
fi

if [ "$agent_started" = "true" ] && [ "$server_agent_route_enabled" = "true" ] && [ -f "$WORK_DIR/agent_router.mjs" ]; then
  rp=$(jq -r '.runtime.agent_router_port // "18080"' "$DATA_FILE")
  log "Router :$rp"
  HE_AGENT_ROUTER_HOST="127.0.0.1" HE_AGENT_ROUTER_PORT="$rp" \
  HE_AGENT_ROUTER_HA_HOST="$local_host" HE_AGENT_ROUTER_HA_PORT="$local_port" \
  HE_AGENT_ROUTER_AGENT_HOST="127.0.0.1" HE_AGENT_ROUTER_AGENT_PORT="$agent_port" \
  HE_AGENT_ROUTER_PATH_PREFIX="/agent/v1" HE_AGENT_ROUTER_FORWARDED_PROTO="https" \
    node "$WORK_DIR/agent_router.mjs" >> "$LOG_FILE" 2>&1 &
  sleep 1
  sed -i -E 's/^localIP = ".*"/localIP = "127.0.0.1"/' "$TMP_FRPC"
  sed -i -E "s/^localPort = [0-9]+/localPort = $rp/" "$TMP_FRPC"
fi

log "frpc start..."
chmod +x "$FRPC_BIN" 2>/dev/null || true
while :; do
  set +e
  "$FRPC_BIN" -c "$TMP_FRPC" 2>&1 | redact | while IFS= read -r line; do
    echo "[FRPC] $line"
    echo "$(date -Is) [FRPC] $line" >> "$LOG_FILE" 2>/dev/null || true
  done
  set -e
  log "FRPC ngắt → 5s"
  sleep 5
done
RUN_EOF

chmod +x "$WORK_DIR/run_standalone.sh"
chown -R "$TARGET_USER:$TARGET_GROUP" "$WORK_DIR"

# --- 8. systemd ---
cat > /etc/systemd/system/he-tunnel-frp.service << EOF
[Unit]
Description=HE Tunnel FRP Client Standalone
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_GROUP
WorkingDirectory=$WORK_DIR
ExecStart=/bin/bash $WORK_DIR/run_standalone.sh
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable he-tunnel-frp
systemctl restart he-tunnel-frp

IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "IP")
echo ""
echo "=================================================="
echo " CÀI XONG"
echo " Web UI:  http://${IP}:8080"
echo " Login:   root / admin"
echo " (đổi pass ngay trên form sau khi đăng nhập)"
echo " Log:     sudo journalctl -u he-tunnel-frp -f"
echo "=================================================="
