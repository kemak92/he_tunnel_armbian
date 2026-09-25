#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# HE Tunnel FRP Standalone Installer for Armbian / Debian
# - Clone mã nguồn từ kemak92/hass_addon_frp
# - Copy agent.mjs + agent_router.mjs
# - Tải binary frpc (fatedier/frp 0.69.0)
# - Tạo Web UI có Login (user/root) tại :8080
# - Cài systemd service + khởi chạy
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

# --- 1. Cài dependency hệ thống ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl jq ca-certificates nodejs npm tar gzip netcat-openbsd dnsutils 2>/dev/null \
  || apt-get install -y git curl jq ca-certificates nodejs npm tar gzip netcat-traditional dnsutils

# Node tối thiểu 18
NODE_VER=$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo 0)
if [ "$NODE_VER" -lt 18 ] 2>/dev/null; then
  echo "[WARN] Node.js < 18. Cài Node 20 từ NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

# --- 2. Tạo thư mục làm việc ---
mkdir -p "$WORK_DIR"
chown -R "$TARGET_USER:$TARGET_GROUP" "$WORK_DIR"

# --- 3. Clone add-on repo và copy file cần thiết ---
echo "[*] Clone mã nguồn từ $ADDON_REPO ..."
rm -rf "$TMP_CLONE"
git clone --depth 1 "$ADDON_REPO" "$TMP_CLONE"

# Copy agent + router
cp -f "$TMP_CLONE/he_tunnel_frp/agent.mjs"        "$WORK_DIR/agent.mjs"
cp -f "$TMP_CLONE/he_tunnel_frp/agent_router.mjs" "$WORK_DIR/agent_router.mjs"
# (tuỳ chọn) giữ run.sh gốc để tham khảo
cp -f "$TMP_CLONE/he_tunnel_frp/run.sh"           "$WORK_DIR/run.sh.addon" 2>/dev/null || true

rm -rf "$TMP_CLONE"
echo "[+] Đã copy agent.mjs + agent_router.mjs"

# --- 4. Tải binary frpc theo kiến trúc ---
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  FRP_ARCH=amd64 ;;
  aarch64) FRP_ARCH=arm64 ;;
  armv7l)  FRP_ARCH=arm   ;;
  *) echo "[ERROR] Kiến trúc không hỗ trợ: $ARCH"; exit 1 ;;
esac

FRPC_BIN="$WORK_DIR/frpc"
if [ ! -x "$FRPC_BIN" ] && [ ! -x /usr/local/bin/frpc ]; then
  echo "[*] Tải frpc v${FRP_VERSION} (${FRP_ARCH}) ..."
  FRP_ASSET="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
  FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_ASSET}"
  curl -fsSL -o /tmp/frp.tar.gz "$FRP_URL"
  mkdir -p /tmp/frp_extract
  tar -xzf /tmp/frp.tar.gz -C /tmp/frp_extract --strip-components=1
  install -m 0755 /tmp/frp_extract/frpc "$FRPC_BIN"
  # cũng cài global cho tiện
  install -m 0755 /tmp/frp_extract/frpc /usr/local/bin/frpc
  rm -rf /tmp/frp.tar.gz /tmp/frp_extract
  echo "[+] frpc đã sẵn sàng: $FRPC_BIN"
else
  echo "[+] frpc đã tồn tại, bỏ qua tải lại"
  [ -x /usr/local/bin/frpc ] || ln -sf "$FRPC_BIN" /usr/local/bin/frpc 2>/dev/null || true
fi

# --- 5. Tạo options.json mặc định (có web_ui login) ---
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
  echo "[+] Tạo options.json mặc định (user=root / pass=admin)"
else
  # Đảm bảo có field login nếu file cũ thiếu
  if ! jq -e '.web_ui_user' "$WORK_DIR/options.json" >/dev/null 2>&1; then
    jq '. + {web_ui_user:"root", web_ui_password:"admin"}' "$WORK_DIR/options.json" > /tmp/opts.json
    mv /tmp/opts.json "$WORK_DIR/options.json"
  fi
fi

# --- 6. Tạo Web UI có Login (thuần Node.js, không express) ---
cat > "$WORK_DIR/web_ui.mjs" << 'WEBUI_EOF'
import http from "http";
import fs from "fs";
import path from "path";
import crypto from "crypto";
import { fileURLToPath } from "url";
import { exec } from "child_process";

const WORK_DIR = "/opt/he_tunnel_frp";
const CONFIG_FILE = path.join(WORK_DIR, "options.json");
const PORT = 8080;
const sessions = new Map();

function parseCookies(req) {
  const list = {};
  const rc = req.headers.cookie;
  if (rc) {
    rc.split(";").forEach(c => {
      const parts = c.split("=");
      list[parts.shift().trim()] = decodeURI(parts.join("="));
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
  const cookies = parseCookies(req);
  const sid = cookies.session_id;
  if (!sid || !sessions.has(sid)) return false;
  const session = sessions.get(sid);
  if (Date.now() > session.expires) {
    sessions.delete(sid);
    return false;
  }
  return true;
}

function parseBody(req) {
  return new Promise(resolve => {
    let body = "";
    req.on("data", chunk => { body += chunk.toString(); });
    req.on("end", () => {
      const params = new URLSearchParams(body);
      const result = {};
      for (const [k, v] of params.entries()) result[k] = v;
      resolve(result);
    });
  });
}

function renderLoginPage(error = "") {
  return `<!DOCTYPE html>
<html lang="vi"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HE Tunnel - Đăng nhập</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
body{background:#f4f6f8;display:flex;align-items:center;justify-content:center;min-height:100vh}
.card{background:#fff;padding:32px;border-radius:12px;box-shadow:0 4px 20px rgba(0,0,0,.08);width:100%;max-width:400px}
.logo{text-align:center;margin-bottom:24px;font-weight:800;font-size:24px;color:#0f172a}
.logo span{color:#2563eb}
.form-group{margin-bottom:16px}
label{display:block;margin-bottom:6px;font-size:14px;color:#475569;font-weight:600}
input{width:100%;padding:10px 12px;border:1px solid #cbd5e1;border-radius:6px;font-size:14px;outline:none}
input:focus{border-color:#2563eb;box-shadow:0 0 0 3px rgba(37,99,235,.1)}
button{width:100%;padding:12px;background:#2563eb;color:#fff;border:none;border-radius:6px;font-weight:600;cursor:pointer;margin-top:8px}
button:hover{background:#1d4ed8}
.error{background:#fef2f2;border:1px solid #fca5a5;color:#991b1b;padding:10px;border-radius:6px;font-size:13px;margin-bottom:16px;text-align:center}
</style></head><body>
<div class="card">
  <div class="logo">HE <span>Tunnel</span></div>
  ${error ? `<div class="error">${error}</div>` : ""}
  <form action="/login" method="POST">
    <div class="form-group"><label>Tài khoản (User/Root)</label>
      <input type="text" name="username" placeholder="root hoặc admin" required autofocus></div>
    <div class="form-group"><label>Mật khẩu</label>
      <input type="password" name="password" placeholder="••••••••" required></div>
    <button type="submit">Đăng nhập</button>
  </form>
</div></body></html>`;
}

function renderDashboardPage(config, msg = "") {
  return `<!DOCTYPE html>
<html lang="vi"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HE Tunnel - Cấu hình</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
body{background:#f8fafc;color:#1e293b;padding:20px}
.container{max-width:650px;margin:0 auto;background:#fff;border-radius:12px;padding:28px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.header{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px;padding-bottom:16px;border-bottom:1px solid #e2e8f0}
.header h2{font-size:20px;font-weight:700;color:#0f172a}
.btn-logout{font-size:13px;color:#ef4444;text-decoration:none;font-weight:600;padding:6px 12px;border:1px solid #fca5a5;border-radius:6px}
.btn-logout:hover{background:#fef2f2}
.section-title{font-size:15px;font-weight:700;margin:20px 0 12px;color:#334155;border-left:3px solid #2563eb;padding-left:8px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.form-group{margin-bottom:14px}
label{display:block;margin-bottom:4px;font-size:13px;font-weight:600;color:#475569}
input,select{width:100%;padding:8px 12px;border:1px solid #cbd5e1;border-radius:6px;font-size:14px}
input:focus{border-color:#2563eb;outline:none}
.btn-submit{width:100%;padding:12px;background:#2563eb;color:#fff;border:none;border-radius:6px;font-weight:600;cursor:pointer;margin-top:16px}
.btn-submit:hover{background:#1d4ed8}
.alert{background:#f0fdf4;border:1px solid #86efac;color:#166534;padding:12px;border-radius:6px;margin-bottom:16px;font-size:13px}
</style></head><body>
<div class="container">
  <div class="header">
    <h2>Cấu hình HE Tunnel Standalone</h2>
    <a href="/logout" class="btn-logout">Đăng xuất</a>
  </div>
  ${msg ? `<div class="alert">${msg}</div>` : ""}
  <form action="/save" method="POST">
    <div class="section-title">1. Thông tin tài khoản Cloud</div>
    <div class="form-group"><label>API Base</label>
      <input type="text" name="api_base" value="${config.api_base || "https://heungelectric.com"}"></div>
    <div class="grid">
      <div class="form-group"><label>Email đăng ký (Gmail)</label>
        <input type="email" name="email" value="${config.email || ""}" required></div>
      <div class="form-group"><label>Mã OTP / Token</label>
        <input type="text" name="otp" value="${config.otp || ""}"></div>
    </div>
    <div class="grid">
      <div class="form-group"><label>Subdomain đăng ký</label>
        <input type="text" name="subdomain" value="${config.subdomain || ""}" required></div>
      <div class="form-group"><label>Force Reset Config</label>
        <select name="force_reset">
          <option value="false" ${(config.force_reset === false || config.force_reset === "false") ? "selected" : ""}>Không</option>
          <option value="true" ${(config.force_reset === true || config.force_reset === "true") ? "selected" : ""}>Có (Reset OTP)</option>
        </select></div>
    </div>
    <div class="section-title">2. Cấu hình Local Target</div>
    <div class="grid">
      <div class="form-group"><label>Local Host IP</label>
        <input type="text" name="local_host" value="${config.local_host || "127.0.0.1"}"></div>
      <div class="form-group"><label>Local Port</label>
        <input type="number" name="local_port" value="${config.local_port || 8123}"></div>
    </div>
    <div class="section-title">3. Bảo mật Web UI (User/Root Login)</div>
    <div class="grid">
      <div class="form-group"><label>Tài khoản Web UI</label>
        <input type="text" name="web_ui_user" value="${config.web_ui_user || "root"}"></div>
      <div class="form-group"><label>Mật khẩu Web UI</label>
        <input type="password" name="web_ui_password" value="${config.web_ui_password || "admin"}" placeholder="Nhập mật khẩu mới"></div>
    </div>
    <button type="submit" class="btn-submit">Lưu cấu hình & Khởi động lại Service</button>
  </form>
</div></body></html>`;
}

const server = http.createServer(async (req, res) => {
  const url = (req.url || "/").split("?")[0];

  if (url === "/login") {
    if (req.method === "GET") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(renderLoginPage());
    }
    if (req.method === "POST") {
      const body = await parseBody(req);
      const config = readConfig();
      const validUser = config.web_ui_user || "root";
      const validPass = config.web_ui_password || "admin";
      const isUserValid = (body.username === validUser || body.username === "root" || body.username === "admin");
      const isPassValid = (body.password === validPass);
      if (isUserValid && isPassValid) {
        const sessionId = crypto.randomBytes(24).toString("hex");
        sessions.set(sessionId, { expires: Date.now() + 7200000 });
        res.writeHead(302, {
          "Set-Cookie": `session_id=${sessionId}; HttpOnly; Path=/; Max-Age=7200`,
          "Location": "/"
        });
        return res.end();
      }
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(renderLoginPage("Sai tên tài khoản hoặc mật khẩu!"));
    }
  }

  if (url === "/logout") {
    const cookies = parseCookies(req);
    if (cookies.session_id) sessions.delete(cookies.session_id);
    res.writeHead(302, {
      "Set-Cookie": "session_id=; HttpOnly; Path=/; Max-Age=0",
      "Location": "/login"
    });
    return res.end();
  }

  if (!isAuthenticated(req)) {
    res.writeHead(302, { "Location": "/login" });
    return res.end();
  }

  if (url === "/" && req.method === "GET") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(renderDashboardPage(readConfig()));
  }

  if (url === "/save" && req.method === "POST") {
    const body = await parseBody(req);
    const current = readConfig();
    const newConfig = {
      ...current,
      api_base: body.api_base || "https://heungelectric.com",
      email: (body.email || "").trim().toLowerCase(),
      otp: body.otp ? body.otp.trim() : "",
      subdomain: (body.subdomain || "").trim().toLowerCase(),
      local_host: body.local_host || "127.0.0.1",
      local_port: parseInt(body.local_port, 10) || 8123,
      force_reset: body.force_reset === "true",
      web_ui_user: body.web_ui_user ? body.web_ui_user.trim() : "root",
      web_ui_password: body.web_ui_password ? body.web_ui_password.trim() : "admin"
    };
    writeConfig(newConfig);
    exec("systemctl restart he-tunnel-frp", () => {});
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(renderDashboardPage(newConfig, "Lưu cấu hình thành công! Service đang khởi động lại..."));
  }

  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("Not Found");
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[INFO] Web UI đang chạy tại http://0.0.0.0:${PORT}`);
});
WEBUI_EOF

echo "[+] Đã tạo web_ui.mjs (có Login Session)"

# --- 7. Tạo run_standalone.sh ---
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

log() { echo "[$(date -Is)] [INFO] $*"; echo "$(date -Is) INFO $*" >> "$LOG_FILE"; }
err() { echo "[$(date -Is)] [ERROR] $*"; echo "$(date -Is) ERROR $*" >> "$LOG_FILE"; }

# 0. Khởi chạy Web UI port 8080 (nếu chưa chạy)
if ! pgrep -f "web_ui.mjs" >/dev/null 2>&1; then
  if [ -f "$WORK_DIR/web_ui.mjs" ]; then
    log "Đang khởi chạy Web UI port 8080..."
    node "$WORK_DIR/web_ui.mjs" >> "$LOG_FILE" 2>&1 &
  fi
fi

redact() {
  sed -E 's/(auth\.token[[:space:]]*=[[:space:]]*")[^"]+/\1***REDACTED***/Ig; s/(metadatas\.token[[:space:]]*=[[:space:]]*")[^"]+/\1***REDACTED***/Ig; s/[A-Fa-f0-9]{32,}/***REDACTED***/g; s/[A-Za-z0-9_-]{40,}/***REDACTED***/g'
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
if [ ! -x "$FRPC_BIN" ]; then
  err "Không tìm thấy frpc. Chạy lại install.sh"
  exit 1
fi

# Chưa cấu hình → chỉ giữ Web UI, chờ user điền form
if [ -z "$email" ] || [ -z "$subdomain" ]; then
  log "Chưa có email/subdomain trong options.json. Mở http://IP:8080 để cấu hình."
  # Giữ process sống để systemd không restart liên tục
  while true; do sleep 60; done
fi

# Device identity
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
  log "Sync-config HTTP status $http_code"
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
    log "Sync cấu hình từ Cloud cho subdomain: $subdomain"
    if sync_runtime_config "$cached_session"; then
      jq -r '.frpc_toml' "$WORK_DIR/sync-config.tmp.json" > "$TMP_FRPC"
      jq --arg session_token "$cached_session" --arg email "$email" --arg subdomain "$subdomain" \
         --arg local_host "$local_host" --argjson local_port "$local_port" \
         '. + {session_token:$session_token,requested:{email:$email,subdomain:$subdomain,local_host:$local_host,local_port:$local_port}}' \
         "$WORK_DIR/sync-config.tmp.json" > "$DATA_FILE"
      rm -f "$WORK_DIR/sync-config.tmp.json"
    else
      if [ -z "$otp" ]; then err "Sync thất bại và thiếu OTP"; exit 1; fi
      needs_provision="true"
    fi
  fi
fi

if [ "$needs_provision" = "true" ]; then
  if [ -z "$otp" ]; then err "Cần OTP cho lần kích hoạt đầu tiên hoặc force_reset"; exit 1; fi
  log "Đang Provision Tunnel tới $api_base ..."
  body=$(jq -nc \
    --arg email "$email" --arg otp "$otp" --arg subdomain "$subdomain" \
    --arg local_host "$local_host" --arg client_type "ha_addon" \
    --arg client_instance_id "$addon_instance_id" --arg client_name "$addon_client_name" \
    --argjson local_port "$local_port" --argjson force_reset false \
    '{email:$email,otp:$otp,subdomain:$subdomain,local_host:$local_host,local_port:$local_port,force_reset:$force_reset,client_type:$client_type,client_instance_id:$client_instance_id,client_name:$client_name}')
  http_code=$(curl -sS -w '%{http_code}' -o "$WORK_DIR/provision.tmp.json" -X POST \
    "$api_base/api/v1/addon/provision" -H 'content-type: application/json' --data "$body" || true)
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
     --arg local_host "$local_host" --argjson local_port "$local_port" \
     '. + {session_token:$session_token,requested:{email:$email,subdomain:$subdomain,local_host:$local_host,local_port:$local_port}}' \
     "$WORK_DIR/provision.tmp.json" > "$DATA_FILE"
  rm -f "$WORK_DIR/provision.tmp.json"
  # Tắt force_reset sau khi provision thành công
  jq '.force_reset = false' "$CONFIG_FILE" > "$WORK_DIR/options.json.tmp" && mv "$WORK_DIR/options.json.tmp" "$CONFIG_FILE"
fi

# Agent (tuỳ chọn)
server_agent_route_enabled=$(jq -r '.runtime.agent_route_enabled // "false"' "$DATA_FILE" 2>/dev/null || echo "false")
server_agent_key=$(jq -r '.agent_config.verify_public_key_base64 // ""' "$DATA_FILE" 2>/dev/null || echo "")
agent_started="false"
if [ "$agent_enabled" = "true" ] || [ -n "$server_agent_key" ]; then
  if command -v node >/dev/null 2>&1 && [ -f "$WORK_DIR/agent.mjs" ]; then
    log "Khởi chạy HE HA Agent port $agent_port"
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
  server_agent_router_port=$(jq -r '.runtime.agent_router_port // "18080"' "$DATA_FILE")
  log "Khởi chạy Agent Router port $server_agent_router_port"
  HE_AGENT_ROUTER_HOST="127.0.0.1" HE_AGENT_ROUTER_PORT="$server_agent_router_port" \
  HE_AGENT_ROUTER_HA_HOST="$local_host" HE_AGENT_ROUTER_HA_PORT="$local_port" \
  HE_AGENT_ROUTER_AGENT_HOST="127.0.0.1" HE_AGENT_ROUTER_AGENT_PORT="$agent_port" \
  HE_AGENT_ROUTER_PATH_PREFIX="/agent/v1" HE_AGENT_ROUTER_FORWARDED_PROTO="https" \
    node "$WORK_DIR/agent_router.mjs" >> "$LOG_FILE" 2>&1 &
  sleep 1
  sed -i -E 's/^localIP = ".*"/localIP = "127.0.0.1"/' "$TMP_FRPC"
  sed -i -E "s/^localPort = [0-9]+/localPort = $server_agent_router_port/" "$TMP_FRPC"
fi

# FRPC loop
log "Bắt đầu frpc..."
chmod +x "$FRPC_BIN" 2>/dev/null || true
while :; do
  set +e
  "$FRPC_BIN" -c "$TMP_FRPC" 2>&1 | redact | while IFS= read -r line; do
    echo "[FRPC] $line"
    echo "$(date -Is) [FRPC] $line" >> "$LOG_FILE"
  done
  set -e
  log "FRPC ngắt. Thử lại sau 5s..."
  sleep 5
done
RUN_EOF

chmod +x "$WORK_DIR/run_standalone.sh"
chown -R "$TARGET_USER:$TARGET_GROUP" "$WORK_DIR"

# --- 8. Systemd service ---
cat > /etc/systemd/system/he-tunnel-frp.service << EOF
[Unit]
Description=HE Tunnel FRP Client Standalone Service
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

# --- 9. Kết thúc ---
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "IP_ARMBIAN")
echo ""
echo "=================================================="
echo " CÀI ĐẶT HOÀN TẤT!"
echo "=================================================="
echo " Web UI (có Login):  http://${IP}:8080"
echo " User mặc định:      root"
echo " Password mặc định:  admin"
echo ""
echo " Kiểm tra log:"
echo "   sudo journalctl -u he-tunnel-frp -f"
echo "   tail -f $WORK_DIR/he_tunnel_frp.log"
echo "=================================================="
